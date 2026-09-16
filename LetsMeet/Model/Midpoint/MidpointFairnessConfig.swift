//
//  MidpointFairnessConfig.swift
//  LetsMeet
//

import Foundation

/// Centralized, tunable constants for the route-seeded meeting-region search
/// and the restaurant search/verification pipeline built around it. Every
/// number that shapes "fair" or "how far/where to search" lives here so it
/// can be tuned without touching the strategy/selector implementations.
enum MidpointFairnessConfig {

    // MARK: - Travel-time fairness (applies to restaurant ETA verification,
    // and to judging the route seed itself)

    /// A candidate (seed or restaurant) is fair when the ETA difference
    /// between the two travelers is within `clamp(toleranceFraction *
    /// longerETA, minTolerance, maxTolerance)`.
    static let toleranceFraction: Double = 0.10
    static let minTolerance: TimeInterval = 3 * 60
    static let maxTolerance: TimeInterval = 8 * 60

    static func fairnessTolerance(forLongerETA longerETA: TimeInterval) -> TimeInterval {
        min(max(toleranceFraction * longerETA, minTolerance), maxTolerance)
    }

    // MARK: - Route seed correction

    /// Maximum number of bounded ETA-based corrections applied to the road
    /// seed, beyond the initial 50% seed. Deliberately small and bounded -
    /// not a bisection loop. Each attempt only continues in the same
    /// direction as the last if that attempt both improved the ETA
    /// imbalance and didn't cross over to the opposite side (see
    /// `RouteSeededMidpointStrategy.attemptCorrection`).
    static let maxSeedCorrections: Int = 2

    /// Fraction of total route distance the seed is nudged by on a
    /// correction, toward whichever traveler had the longer ETA.
    static let seedCorrectionStep: Double = 0.15

    /// Minimum real-world movement, in meters, for a seed correction or
    /// corridor shift to be treated as meaningful. Below this the
    /// candidate is a no-op: not counted as a correction/shift, and no
    /// restaurant-search round is spent on it. 75m comfortably exceeds
    /// typical `MKRoute.polyline` vertex spacing on a straight stretch,
    /// while still catching a genuine (if modest) corridor movement.
    static let minMeaningfulMovementMeters: Double = 75

    // MARK: - Restaurant search radius

    /// Search radius scales with route distance (falling back to
    /// straight-line distance only when no route is available). Kept behind
    /// the `searchRadius(for...)` functions below so a future strategy can
    /// replace the formula without changing call sites.
    static let radiusFraction: Double = 0.15
    static let minSearchRadiusMeters: Double = 1_609.34 // 1 mile
    static let maxSearchRadiusMeters: Double = 8 * 1_609.34 // 8 miles

    /// Primary radius formula: based on the real route distance from the
    /// single A->B MapKit route request.
    static func searchRadius(forRouteDistance distanceMeters: Double) -> Double {
        clampedRadius(forDistance: distanceMeters)
    }

    /// Fallback radius formula, used only when no route is available and
    /// the search seed is the plain geographic midpoint.
    static func searchRadius(forStraightLineDistance distanceMeters: Double) -> Double {
        clampedRadius(forDistance: distanceMeters)
    }

    private static func clampedRadius(forDistance distanceMeters: Double) -> Double {
        min(max(distanceMeters * radiusFraction, minSearchRadiusMeters), maxSearchRadiusMeters)
    }

    // MARK: - Restaurant shortlist / fairness verification

    /// Target number of restaurants carried into ETA verification per
    /// search round, selected by relevance + geographic diversity - not
    /// simply the closest N.
    static let restaurantShortlistSize: Int = 10

    /// Minimum spacing enforced (greedily) between shortlisted restaurants
    /// so candidates aren't clustered in one tiny area.
    static let diversityMinSeparationMeters: Double = 250

    /// Maximum number of restaurant ETA requests in flight at once, so a
    /// 10-restaurant shortlist doesn't burst 20 simultaneous MKDirections
    /// requests.
    static let etaConcurrencyBatchSize: Int = 5

    /// Below this many raw Yelp results, a round is treated as sparse
    /// (shift the search region) rather than merely unfair (expand it).
    static let sparsityThreshold: Int = 5

    /// Maximum number of times the search radius is expanded when results
    /// exist but too few pass fairness (or too few results exist at all).
    static let maxRadiusExpansionRounds: Int = 2

    /// Multiplier applied to the search radius on each expansion round.
    static let radiusExpansionMultiplier: Double = 1.5

    /// Maximum number of times the search region is shifted along the route
    /// corridor (bounded fallback for sparsity, or last resort for
    /// persistent unfairness). No effect when no route corridor is
    /// available (geographic-midpoint fallback).
    static let maxCorridorShiftAttempts: Int = 1

    /// Fraction of total route distance the search region is shifted by on
    /// a corridor shift.
    static let corridorShiftStep: Double = 0.15

    /// Minimum number of fairness-verified restaurants required for a
    /// normal-success outcome before bounded search attempts are exhausted.
    static let minViableRestaurants: Int = 3
}
