//
//  MeetingPlaceFinder.swift
//  LetsMeet
//

import Foundation
import CoreLocation
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
        completion: @escaping (MeetingPlaceOutcome) -> Void
    ) {
        #if DEBUG
        Self.logger.log("🔍 [Midpoint] MeetingPlaceFinder search started")
        #endif

        midpointStrategy.findMeetingRegion(userLocation: userLocation, friendLocation: friendLocation) { [weak self] region in
            guard let self = self else { return }

            // Kept in sync for HomeMapView, which reads this directly when
            // fitting the map to the current results.
            YelpManager.shared.midPoint = CLLocation(latitude: region.center.latitude, longitude: region.center.longitude)

            self.restaurantSelector.findFairRestaurants(
                in: region,
                userLocation: userLocation,
                friendLocation: friendLocation,
                diagnostics: region.diagnostics
            ) { outcome in
                self.logDiagnosticsIfNeeded(region.diagnostics, outcome: outcome)
                completion(outcome)
            }
        }
    }

    private func logDiagnosticsIfNeeded(_ diagnostics: MidpointDiagnostics?, outcome: MeetingPlaceOutcome) {
        #if DEBUG
        guard let diagnostics = diagnostics else { return }

        Self.logger.log("[Midpoint] original geographic midpoint: \(String(describing: diagnostics.originalGeographicMidpoint))")
        Self.logger.log("[Midpoint] route seed succeeded: \(diagnostics.routeSeedSucceeded)")
        Self.logger.log("[Midpoint] route distance (m): \(diagnostics.routeDistanceMeters ?? -1)")
        Self.logger.log("[Midpoint] initial seed coordinate: \(String(describing: diagnostics.initialSeedCoordinate))")
        Self.logger.log("[Midpoint] initial seed ETA pair: \(String(describing: diagnostics.initialSeedETAs))")
        Self.logger.log("[Midpoint] seed correction occurred: \(diagnostics.correctionOccurred)")

        for candidate in diagnostics.seedCandidates {
            Self.logger.log("""
            [Midpoint] seed candidate \(candidate.attemptIndex): fraction=\(candidate.fraction) \
            coordinate=\(String(describing: candidate.coordinate)) \
            movementFromPrevious(m)=\(candidate.movementFromPreviousMeters.map { String($0) } ?? "n/a") \
            userETA=\(candidate.userETA.map { String($0) } ?? "n/a") friendETA=\(candidate.friendETA.map { String($0) } ?? "n/a") \
            etaDifference=\(candidate.etaDifference.map { String($0) } ?? "n/a") \
            tolerance=\(candidate.fairnessTolerance.map { String($0) } ?? "n/a") \
            becameBest=\(candidate.becameBest)
            """)
        }
        Self.logger.log("[Midpoint] seed correction stop reason: \(diagnostics.seedCorrectionStopReason?.rawValue ?? "n/a")")
        Self.logger.log("[Midpoint] traffic-aware seed used: \(diagnostics.usedTrafficAwareRouting)")
        Self.logger.log("[Midpoint] selected search center: \(String(describing: diagnostics.selectedCenter))")
        Self.logger.log("[Midpoint] initial search radius (m): \(diagnostics.searchRadiusMeters ?? -1)")

        for round in diagnostics.searchRounds {
            Self.logger.log("""
            [Midpoint] round \(round.roundIndex) (\(round.reason.rawValue)): \
            center=\(String(describing: round.center)) radius=\(round.radiusMeters) \
            yelpResults=\(round.yelpResultCount) shortlist=\(round.shortlistIDs) \
            reusedETAs=\(round.reusedETAIDs) etaAttempted=\(round.etaAttemptedCount) \
            etaVerified=\(round.etaVerifiedCount) etaFailed=\(round.etaFailedCount) \
            passingFairness=\(round.passingFairnessCount)
            """)
        }

        for decision in diagnostics.corridorDirectionDecisions {
            Self.logger.log("""
            [Midpoint] corridor direction decision: sampleCount=\(decision.sampleCount) \
            medianSignedImbalance(s)=\(decision.medianSignedImbalance.map { String($0) } ?? "n/a") \
            interpretation=\(decision.interpretation.rawValue) direction=\(decision.direction) \
            usedRestaurantEvidence=\(decision.usedRestaurantEvidence)
            """)
        }

        for shift in diagnostics.corridorShiftAttempts {
            Self.logger.log("""
            [Midpoint] corridor shift attempt: oldFraction=\(shift.oldFraction) proposedFraction=\(shift.proposedFraction) \
            oldCoordinate=\(String(describing: shift.oldCoordinate)) proposedCoordinate=\(String(describing: shift.proposedCoordinate)) \
            movement(m)=\(shift.movementMeters) accepted=\(shift.accepted) reason=\(shift.reason)
            """)
        }

        Self.logger.log("[Midpoint] restaurant ETA comparisons: \(String(describing: diagnostics.restaurantETAComparisons))")
        Self.logger.log("[Midpoint] MapKit request count: \(diagnostics.mapKitRequestCount)")
        for failure in diagnostics.mapKitFailures {
            Self.logger.log("""
            [Midpoint] MapKit failure: stage=\(failure.stage.rawValue) \
            side=\(failure.side?.rawValue ?? "n/a") restaurantID=\(failure.restaurantID ?? "n/a") \
            errorDomain=\(failure.errorDomain ?? "n/a") errorCode=\(failure.errorCode.map(String.init) ?? "n/a") \
            description=\(failure.localizedDescription)
            """)
        }
        Self.logger.log("[Midpoint] final restaurants: \(String(describing: diagnostics.finalRestaurantIDs))")
        Self.logger.log("[Midpoint] final outcome: \(Self.describe(outcome))")
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
        }
    }
    #endif
}
