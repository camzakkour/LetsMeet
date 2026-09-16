//
//  MeetingRegion.swift
//  LetsMeet
//

import Foundation
import CoreLocation
import MapKit

/// Why one restaurant-search round ran, kept for diagnostics.
enum SearchRoundReason: String {
    case initial
    case sparsityRadiusExpansion
    case sparsityCorridorShift
    case unfairnessRadiusExpansion
    case unfairnessCorridorShift
}

/// Debug-only record of one restaurant-search round, kept regardless of
/// whether it produced fair results.
struct SearchRoundDiagnostics {
    let roundIndex: Int
    let reason: SearchRoundReason
    let center: CLLocationCoordinate2D
    let radiusMeters: Double
    let yelpResultCount: Int
    let shortlistIDs: [String]
    let reusedETAIDs: [String]
    /// Shortlisted restaurants a bidirectional ETA fetch was attempted for
    /// this round (new fetches only - excludes `reusedETAIDs`).
    let etaAttemptedCount: Int
    /// Of `etaAttemptedCount`, how many resolved a full user+friend ETA pair.
    let etaVerifiedCount: Int
    /// Of `etaAttemptedCount`, how many failed/couldn't be verified - kept
    /// distinct from `passingFairnessCount` so "0 restaurants were fair" and
    /// "0 restaurants could be verified" never collapse into one number.
    let etaFailedCount: Int
    let passingFairnessCount: Int
}

/// Debug-only record of one MapKit (MKDirections) request that failed,
/// captured instead of silently discarded via `try?` so a run's diagnostics
/// can explain *why* an ETA or route was unavailable.
struct MapKitFailureRecord {
    enum Stage: String {
        case route
        case seedETA
        case restaurantETA
    }

    enum Side: String {
        case user
        case friend
    }

    let stage: Stage
    /// Which traveler's leg failed, when applicable (route requests don't
    /// have a "side").
    let side: Side?
    /// The restaurant this ETA request was for, when applicable.
    let restaurantID: String?
    let errorCode: Int?
    let errorDomain: String?
    let localizedDescription: String

    init(stage: Stage, side: Side?, restaurantID: String?, error: Error?) {
        self.stage = stage
        self.side = side
        self.restaurantID = restaurantID
        let nsError = error as NSError?
        self.errorCode = nsError?.code
        self.errorDomain = nsError?.domain
        self.localizedDescription = error?.localizedDescription ?? "unknown error"
    }
}

/// Why a bounded seed-correction loop stopped attempting further
/// corrections.
enum SeedCorrectionStopReason: String {
    /// A candidate (the initial seed or a correction) met fairness
    /// tolerance, so no further corrections were attempted.
    case fairnessMet
    /// `maxSeedCorrections` attempts were used without meeting tolerance;
    /// the best-evaluated candidate was used as the search center.
    case budgetExhausted
    /// The next candidate's coordinate was within
    /// `minMeaningfulMovementMeters` of the previous one (a polyline-
    /// vertex-spacing artifact, not a real move), so it was skipped.
    case movementTooSmall
    /// The previous correction either made the imbalance worse or crossed
    /// over to the opposite side - continuing in the same direction
    /// wouldn't be a sound bounded-step move, so the loop stopped early.
    case wouldWorsenOrCrossOver
}

/// One evaluated route-seed candidate: the initial 50% seed (attemptIndex
/// 0) or a bounded correction attempt (attemptIndex 1...maxSeedCorrections).
/// Kept even for candidates that didn't become the best, so a run's full
/// correction path is inspectable after the fact.
struct SeedCandidateDiagnostics {
    let attemptIndex: Int
    let fraction: Double
    let coordinate: CLLocationCoordinate2D
    /// Distance from the previous candidate's coordinate, in meters. Nil
    /// for the initial seed (attemptIndex 0), which has no previous.
    let movementFromPreviousMeters: Double?
    /// Nil when the seed ETA check itself failed - the candidate is still
    /// usable as a search center, it just couldn't be judged.
    let userETA: TimeInterval?
    let friendETA: TimeInterval?
    let etaDifference: TimeInterval?
    let fairnessTolerance: TimeInterval?
    let becameBest: Bool
}

/// One corridor-shift candidate the restaurant-search stage considered,
/// whether or not it was actually used as a search round's center.
struct CorridorShiftDiagnostics {
    let oldFraction: Double
    let proposedFraction: Double
    let oldCoordinate: CLLocationCoordinate2D
    let proposedCoordinate: CLLocationCoordinate2D
    let movementMeters: Double
    let accepted: Bool
    let reason: String
}

/// What a corridor-shift direction decision concluded, given the median
/// signed ETA imbalance (`userETA - friendETA`) across verified restaurants
/// so far.
enum CorridorDirectionInterpretation: String {
    /// Verified restaurants are collectively too favorable to the user -
    /// shift toward the friend.
    case towardFriend
    /// Verified restaurants are collectively too favorable to the friend -
    /// shift toward the user.
    case towardUser
    /// Restaurant evidence exists but the median imbalance is within
    /// `MidpointFairnessConfig.minTolerance` of zero - too ambiguous to act
    /// on, fell back to the seed-based/alternating direction logic.
    case ambiguousFallback
    /// No verified restaurant ETA comparisons exist yet - fell back to the
    /// seed-based/alternating direction logic.
    case noRestaurantEvidenceFallback
}

/// Debug-only record of one corridor-shift *direction* decision - distinct
/// from `CorridorShiftDiagnostics`, which records the resulting fraction
/// candidate(s). Captures why a direction was chosen so a regression run's
/// shift direction is explainable after the fact.
struct CorridorDirectionDiagnostics {
    /// Number of restaurants in `diagnostics.restaurantETAComparisons` at
    /// decision time.
    let sampleCount: Int
    /// Median of `userETA - friendETA` across those restaurants. Nil when
    /// `sampleCount` is 0.
    let medianSignedImbalance: TimeInterval?
    let interpretation: CorridorDirectionInterpretation
    /// +1 (toward friend) or -1 (toward user).
    let direction: Double
    /// True when `direction` came from the restaurant-evidence rule; false
    /// when it came from the seed-based/alternating fallback.
    let usedRestaurantEvidence: Bool
}

/// Debug-only diagnostics for one end-to-end route-seed + restaurant-search
/// run. A reference type so each stage can append to the same instance as
/// the search progresses. Never consulted by production logic.
final class MidpointDiagnostics {
    let originalGeographicMidpoint: CLLocationCoordinate2D

    // MARK: Route seed stage
    var routeSeedSucceeded: Bool = false
    var routeDistanceMeters: Double?
    var initialSeedCoordinate: CLLocationCoordinate2D?
    var initialSeedETAs: (userETA: TimeInterval, friendETA: TimeInterval)?
    /// True once at least one correction attempt actually moved to a new
    /// coordinate and was ETA-checked - not set merely because a
    /// correction was *attempted* (see `seedCandidates` for the full path,
    /// including attempts skipped for insufficient movement).
    var correctionOccurred: Bool = false
    var seedCandidates: [SeedCandidateDiagnostics] = []
    var seedCorrectionStopReason: SeedCorrectionStopReason?
    var usedTrafficAwareRouting: Bool = false
    var selectedCenter: CLLocationCoordinate2D?
    var searchRadiusMeters: Double?

    // MARK: Restaurant search stage
    var searchRounds: [SearchRoundDiagnostics] = []
    var corridorShiftAttempts: [CorridorShiftDiagnostics] = []
    var corridorDirectionDecisions: [CorridorDirectionDiagnostics] = []
    var restaurantETAComparisons: [String: (userETA: TimeInterval, friendETA: TimeInterval)] = [:]
    var finalRestaurantIDs: [String] = []

    // MARK: Shared
    var mapKitRequestCount: Int = 0
    /// Every captured MapKit request failure across the whole run (route,
    /// seed ETA, restaurant ETA) - richer diagnostics only, never consulted
    /// by production control flow and never used to fabricate an ETA.
    var mapKitFailures: [MapKitFailureRecord] = []

    init(originalGeographicMidpoint: CLLocationCoordinate2D) {
        self.originalGeographicMidpoint = originalGeographicMidpoint
    }
}

/// The route a meeting region's seed was derived from, and where along it -
/// lets the restaurant-search stage shift its search region along the real
/// road corridor (instead of a straight line) when results are sparse or
/// persistently unfair. Nil when routing was unavailable and the region's
/// center is the geographic-midpoint fallback instead.
struct SearchCorridor {
    let route: MKRoute
    /// Fraction (0...1) along `route.polyline`, by cumulative distance, that
    /// produced this region's center.
    let seedFraction: Double
}

/// The outcome of running a midpoint strategy: a center to search
/// restaurants around, a radius to search within, and enough information for
/// the restaurant-fairness stage and diagnostics to do their jobs. This is
/// the seam future strategies plug into - nothing downstream needs to know
/// which strategy produced it.
struct MeetingRegion {
    let center: CLLocationCoordinate2D
    let searchRadiusMeters: Double
    let userETA: TimeInterval?
    let friendETA: TimeInterval?
    /// True when `center` came from a real route-derived seed; false when
    /// routing was unavailable and this is the plain geographic-midpoint
    /// fallback instead. Note this describes the *seed* only - actual
    /// fairness is always decided later, per-restaurant, using real
    /// bidirectional ETAs.
    let isTrafficAwareResult: Bool
    let corridor: SearchCorridor?
    var diagnostics: MidpointDiagnostics?
}

/// The outcome of a full meeting-place search. Distinguishes *why* there
/// aren't 3+ great options rather than collapsing every non-ideal case into
/// one generic failure. The restaurant-search stage never substitutes an
/// unverified shortlist for a fairness result - one of these cases is always
/// returned explicitly instead.
enum MeetingPlaceOutcome {
    /// 3+ restaurants verified fair for both travelers via real bidirectional ETAs.
    case success(restaurants: [Restaurant])
    /// 1-2 verified-fair restaurants after bounded search attempts were exhausted.
    case limitedFairOptions(restaurants: [Restaurant])
    /// Restaurants were found near the search region, but none verified fair.
    case noFairRestaurants
    /// Yelp returned no meaningful restaurants near the search region at all.
    case noRestaurantsNearby
    /// The Yelp request itself failed (network/decoding) - not a fairness result.
    case searchFailed(YelpManagerError)
}

/// Common seam for anything that can produce a `MeetingRegion` from two
/// travelers' locations. `RouteSeededMidpointStrategy` is the V2
/// implementation; `GeographicMidpointStrategy` both backs it as a fallback
/// and stands ready to be selected directly as a future "Distance" mode.
protocol MidpointStrategy {
    func findMeetingRegion(
        userLocation: CLLocation,
        friendLocation: CLLocation,
        completion: @escaping (MeetingRegion) -> Void
    )
}
