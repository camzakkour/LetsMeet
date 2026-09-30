//
//  MeetingPlaceFinder.swift
//  LetsMeet
//

import Foundation
import CoreLocation
import MapKit
import os.log

/// Orchestrates a full "fair meeting place" search: derives a road-corridor
/// search seed via a `MidpointStrategy`, then finds and verifies real
/// restaurant options within it via `RestaurantFairnessSelector`. The seed
/// only determines where to search - actual fairness is always decided
/// using real bidirectional restaurant ETAs, never the seed coordinate
/// alone.
///
/// This is the entry point the SwiftUI flow (`HomeViewModel`) uses. It is
/// intentionally separate from `YelpManager`, which stays a thin Yelp
/// network client, and from the legacy UIKit flow, which keeps using
/// `YelpManager`'s original geographic-only methods untouched.
final class MeetingPlaceFinder {
    static let shared = MeetingPlaceFinder()

    private static let logger = Logger(subsystem: "com.letsmeet.app", category: "Midpoint")

    private let midpointStrategy: MidpointStrategy
    private let restaurantSelector: RestaurantFairnessSelector

    init(
        midpointStrategy: MidpointStrategy = RouteSeededMidpointStrategy(),
        restaurantSelector: RestaurantFairnessSelector = RestaurantFairnessSelector()
    ) {
        self.midpointStrategy = midpointStrategy
        self.restaurantSelector = restaurantSelector
    }

    func findMeetingPlace(
        userLocation: CLLocation,
        friendLocation: CLLocation,
        searchID: String,
        onProgress: @escaping ([Restaurant]) -> Void,
        completion: @escaping (MeetingPlaceOutcome) -> Void
    ) {
        #if DEBUG
        Self.logger.log("🔍 [Midpoint][S9][\(searchID)] MeetingPlaceFinder search started")
        #endif

        midpointStrategy.findMeetingRegion(userLocation: userLocation, friendLocation: friendLocation, searchID: searchID) { [weak self] region in
            guard let self = self else { return }

            // Kept in sync for HomeMapView, which reads this directly when
            // fitting the map to the current results.
            YelpManager.shared.midPoint = CLLocation(latitude: region.center.latitude, longitude: region.center.longitude)

            self.restaurantSelector.findFairRestaurants(
                in: region,
                userLocation: userLocation,
                friendLocation: friendLocation,
                diagnostics: region.diagnostics,
                onProgress: onProgress
            ) { outcome in
                self.updateVisualizationMetadata(region: region)
                self.logDiagnosticsIfNeeded(region.diagnostics, outcome: outcome)
                self.logTimingSummaryIfNeeded(region.diagnostics)
                completion(outcome)
            }
        }
    }

    /// Exposes already-computed search metadata on `YelpManager.shared` for
    /// map visualization only - reuses the region's own route and, when
    /// available, the *final* search round's center/radius rather than the
    /// initial seed, since corridor shifts or radius expansions may have
    /// moved the search after that seed was picked. Never recomputes or
    /// refetches anything.
    private func updateVisualizationMetadata(region: MeetingRegion) {
        YelpManager.shared.route = region.corridor?.route

        if let finalRound = region.diagnostics?.searchRounds.last {
            YelpManager.shared.midPoint = CLLocation(latitude: finalRound.center.latitude, longitude: finalRound.center.longitude)
            YelpManager.shared.searchRadiusMeters = finalRound.radiusMeters
        } else {
            YelpManager.shared.searchRadiusMeters = region.searchRadiusMeters
        }
    }

    private func logDiagnosticsIfNeeded(_ diagnostics: MidpointDiagnostics?, outcome: MeetingPlaceOutcome) {
        #if DEBUG
        guard let diagnostics = diagnostics else { return }
        let tag = "[Midpoint][S9][\(diagnostics.searchID)]"

        Self.logger.log("\(tag) original geographic midpoint: \(String(describing: diagnostics.originalGeographicMidpoint))")
        Self.logger.log("\(tag) route seed succeeded: \(diagnostics.routeSeedSucceeded)")
        Self.logger.log("\(tag) route distance (m): \(diagnostics.routeDistanceMeters ?? -1)")
        Self.logger.log("\(tag) initial seed coordinate: \(String(describing: diagnostics.initialSeedCoordinate))")
        Self.logger.log("\(tag) initial seed ETA pair: \(String(describing: diagnostics.initialSeedETAs))")
        Self.logger.log("\(tag) seed correction occurred: \(diagnostics.correctionOccurred)")

        for candidate in diagnostics.seedCandidates {
            Self.logger.log("""
            \(tag) seed candidate \(candidate.attemptIndex): fraction=\(candidate.fraction) \
            coordinate=\(String(describing: candidate.coordinate)) \
            movementFromPrevious(m)=\(candidate.movementFromPreviousMeters.map { String($0) } ?? "n/a") \
            userETA=\(candidate.userETA.map { String($0) } ?? "n/a") friendETA=\(candidate.friendETA.map { String($0) } ?? "n/a") \
            etaDifference=\(candidate.etaDifference.map { String($0) } ?? "n/a") \
            tolerance=\(candidate.fairnessTolerance.map { String($0) } ?? "n/a") \
            becameBest=\(candidate.becameBest)
            """)
        }
        Self.logger.log("\(tag) seed correction stop reason: \(diagnostics.seedCorrectionStopReason?.rawValue ?? "n/a")")
        Self.logger.log("\(tag) traffic-aware seed used: \(diagnostics.usedTrafficAwareRouting)")
        Self.logger.log("\(tag) selected search center: \(String(describing: diagnostics.selectedCenter))")
        Self.logger.log("\(tag) initial search radius (m): \(diagnostics.searchRadiusMeters ?? -1)")

        for round in diagnostics.searchRounds {
            Self.logger.log("""
            \(tag) round \(round.roundIndex) (\(round.reason.rawValue)): \
            center=\(String(describing: round.center)) radius=\(round.radiusMeters) \
            yelpResults=\(round.yelpResultCount) shortlist=\(round.shortlistIDs) \
            reusedETAs=\(round.reusedETAIDs) etaAttempted=\(round.etaAttemptedCount) \
            etaVerified=\(round.etaVerifiedCount) etaFailed=\(round.etaFailedCount) \
            passingFairness=\(round.passingFairnessCount) verifiedUnfair=\(round.verifiedUnfairCount) \
            reliable=\(round.reliable)
            """)
        }

        for retry in diagnostics.etaRetries {
            Self.logger.log("""
            \(tag) ETA retry: restaurantID=\(retry.restaurantID) side=\(retry.side.rawValue) \
            retryAttempt=\(retry.retryAttemptNumber) delaySeconds=\(retry.delaySeconds) \
            priorErrorDomain=\(retry.priorErrorDomain ?? "n/a") priorErrorCode=\(retry.priorErrorCode.map(String.init) ?? "n/a") \
            priorErrorDescription=\(retry.priorErrorDescription)
            """)
        }

        for decision in diagnostics.corridorDirectionDecisions {
            Self.logger.log("""
            \(tag) corridor direction decision: sampleCount=\(decision.sampleCount) \
            medianSignedImbalance(s)=\(decision.medianSignedImbalance.map { String($0) } ?? "n/a") \
            interpretation=\(decision.interpretation.rawValue) direction=\(decision.direction) \
            usedRestaurantEvidence=\(decision.usedRestaurantEvidence)
            """)
        }

        for shift in diagnostics.corridorShiftAttempts {
            Self.logger.log("""
            \(tag) corridor shift attempt: oldFraction=\(shift.oldFraction) proposedFraction=\(shift.proposedFraction) \
            oldCoordinate=\(String(describing: shift.oldCoordinate)) proposedCoordinate=\(String(describing: shift.proposedCoordinate)) \
            movement(m)=\(shift.movementMeters) accepted=\(shift.accepted) reason=\(shift.reason)
            """)
        }

        Self.logger.log("\(tag) restaurant ETA comparisons: \(String(describing: diagnostics.restaurantETAComparisons))")
        Self.logger.log("\(tag) MapKit request count: \(diagnostics.mapKitRequestCount)")
        for failure in diagnostics.mapKitFailures {
            Self.logger.log("""
            \(tag) MapKit failure: stage=\(failure.stage.rawValue) \
            side=\(failure.side?.rawValue ?? "n/a") restaurantID=\(failure.restaurantID ?? "n/a") \
            errorDomain=\(failure.errorDomain ?? "n/a") errorCode=\(failure.errorCode.map(String.init) ?? "n/a") \
            description=\(failure.localizedDescription)
            """)
        }
        Self.logger.log("\(tag) final restaurants: \(String(describing: diagnostics.finalRestaurantIDs))")
        Self.logger.log("\(tag) final outcome: \(Self.describe(outcome))")
        #endif
    }

    /// One consolidated timing line per search, covering every stage that
    /// shares `MidpointDiagnostics` (route through ETA verification).
    /// `HomeViewModel` logs its own complementary line (under the same
    /// `[Timing][S9][searchID]` tag) for address resolution, total
    /// end-to-end duration, and UI presentation, since those happen outside
    /// this pipeline's visibility. Profiling only - reads timing fields that
    /// no production decision ever consults.
    private func logTimingSummaryIfNeeded(_ diagnostics: MidpointDiagnostics?) {
        #if DEBUG
        guard let diagnostics = diagnostics else { return }
        Self.logger.log("""
        [Timing][S9][\(diagnostics.searchID)] pipeline summary: \
        route=\(diagnostics.routeDuration.map { String($0) } ?? "n/a")s \
        midpointCorrections=\(diagnostics.midpointCorrectionDuration.map { String($0) } ?? "n/a")s \
        yelp=\(diagnostics.yelpTotalDuration)s shortlist=\(diagnostics.shortlistTotalDuration)s \
        etaVerification=\(diagnostics.etaVerificationTotalDuration)s \
        rounds=\(diagnostics.searchRounds.count) mapKitRequests=\(diagnostics.mapKitRequestCount)
        """)
        #endif
    }

    #if DEBUG
    private static func describe(_ outcome: MeetingPlaceOutcome) -> String {
        switch outcome {
        case .success(let restaurants):
            return "normalSuccess (\(restaurants.count) restaurants)"
        case .limitedFairOptions(let restaurants):
            return "limitedFairOptions (\(restaurants.count) restaurants)"
        case .noFairRestaurants:
            return "noFairRestaurants"
        case .noRestaurantsNearby:
            return "noRestaurantsNearby"
        case .searchFailed(let error):
            return "searchFailed (\(error))"
        case .etaVerificationUnavailable:
            return "etaVerificationUnavailable"
        }
    }
    #endif
}
