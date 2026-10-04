//
//  RouteSeededMidpointStrategy.swift
//  LetsMeet
//

import Foundation
import CoreLocation
import MapKit
import os.log

/// V2 "fair region" strategy: rather than searching for one mathematically
/// perfect midpoint, this derives an approximate road-corridor seed from a
/// single A(user)->B(friend) MapKit route, optionally nudges that seed via a
/// small number of bounded ETA-based corrections, and hands the result to
/// `RestaurantFairnessSelector` - which does the real fairness work by
/// verifying actual restaurants with real bidirectional ETAs. The seed only
/// determines *where to search*; it is never itself the fairness decision.
///
/// This replaces the earlier iterative-bisection strategy, which searched
/// along the straight geographic line between the two travelers and assumed
/// travel-time difference changes monotonically along it - an assumption
/// mountainous or sparse-road terrain violates, producing large
/// non-monotonic ETA swings and a search that could silently revert to the
/// plain geographic midpoint while still reporting success.
///
/// The seed is a distance-fraction point along the route's real road
/// geometry, not a true 50%-travel-time midpoint - `MKRoute.Step` exposes no
/// per-step time, only per-step distance, so a genuine time-based split
/// isn't derivable from route geometry alone without extra ETA calls.
///
/// Never fabricates an ETA from straight-line distance and an assumed speed.
/// If the route request fails (after one retry), this falls back to
/// `GeographicMidpointStrategy`'s pure geometry ONLY as the search seed -
/// every restaurant returned downstream still gets a real bidirectional ETA
/// check before being called fair.
final class RouteSeededMidpointStrategy: MidpointStrategy {

    #if DEBUG
    private static let logger = Logger(subsystem: "com.letsmeet.app", category: "Session9")
    #endif

    private let maxRouteRetries = 1

    /// One route-seed candidate evaluated during the correction loop -
    /// local working state, not the diagnostics record (see
    /// `SeedCandidateDiagnostics` for the DEBUG-only mirror of this).
    private struct SeedCandidate {
        let fraction: Double
        let coordinate: CLLocationCoordinate2D
        let userETA: TimeInterval
        let friendETA: TimeInterval
        var diff: TimeInterval { abs(userETA - friendETA) }
    }

    func findMeetingRegion(
        userLocation: CLLocation,
        friendLocation: CLLocation,
        searchID: String,
        cancellationToken: SearchCancellationToken,
        completion: @escaping (MeetingRegion) -> Void
    ) {
        let originalMidpoint = LocationUtility.shared.geographicMidpoint(
            betweenCoordinates: [userLocation.coordinate, friendLocation.coordinate]
        )
        let diagnostics = MidpointDiagnostics(searchID: searchID, originalGeographicMidpoint: originalMidpoint)

        #if DEBUG
        Self.logger.log("""
        [S9][\(searchID)] route request START: \
        user=(\(userLocation.coordinate.latitude), \(userLocation.coordinate.longitude)) \
        friend=(\(friendLocation.coordinate.latitude), \(friendLocation.coordinate.longitude))
        """)
        #endif

        #if DEBUG
        let routeStageStart = CFAbsoluteTimeGetCurrent()
        #endif

        requestRoute(from: userLocation, to: friendLocation, cancellationToken: cancellationToken) { [weak self] route, error in
            guard let self = self else { return }
            // The route request was in flight at cancellation and is left to
            // finish; its result must not start seed ETA work (or fall back
            // to the geographic seed and go on to Yelp).
            guard SearchCancellationGate.shouldContinue(cancellationToken) else { return }
            diagnostics.mapKitRequestCount += 1
            #if DEBUG
            diagnostics.routeDuration = CFAbsoluteTimeGetCurrent() - routeStageStart
            let correctionsStageStart = CFAbsoluteTimeGetCurrent()
            #endif

            guard let route = route else {
                #if DEBUG
                Self.logger.log("[S9][\(searchID)] route request FAILED: \(error?.localizedDescription ?? "unknown error")")
                Self.logger.log("[Timing][S9][\(searchID)] route request took \(diagnostics.routeDuration ?? -1)s (failed)")
                #endif
                diagnostics.routeSeedSucceeded = false
                diagnostics.mapKitFailures.append(
                    MapKitFailureRecord(stage: .route, side: nil, restaurantID: nil, error: error)
                )
                self.finishWithGeographicFallback(
                    userLocation: userLocation,
                    friendLocation: friendLocation,
                    diagnostics: diagnostics,
                    completion: completion
                )
                return
            }

            #if DEBUG
            Self.logger.log("""
            [S9][\(searchID)] route request COMPLETED: distanceMeters=\(route.distance) \
            expectedTravelTimeSeconds=\(route.expectedTravelTime)
            """)
            Self.logger.log("[Timing][S9][\(searchID)] route request took \(diagnostics.routeDuration ?? -1)s")
            #endif

            diagnostics.routeSeedSucceeded = true
            diagnostics.routeDistanceMeters = route.distance

            self.runSeedSearch(
                route: route,
                userLocation: userLocation,
                friendLocation: friendLocation,
                diagnostics: diagnostics,
                cancellationToken: cancellationToken
            ) { finalFraction, finalCoordinate in
                #if DEBUG
                diagnostics.midpointCorrectionDuration = CFAbsoluteTimeGetCurrent() - correctionsStageStart
                Self.logger.log("[Timing][S9][\(searchID)] midpoint corrections took \(diagnostics.midpointCorrectionDuration ?? -1)s")
                #endif
                self.finish(
                    center: finalCoordinate,
                    seedFraction: finalFraction,
                    route: route,
                    diagnostics: diagnostics,
                    completion: completion
                )
            }
        }
    }

    // MARK: - Bounded seed-correction search

    /// Evaluates the initial 50% route seed, then - only if it's outside
    /// fairness tolerance - a small, bounded number of ETA-based
    /// corrections along the route (see `attemptCorrection`). Every
    /// candidate coordinate comes from `RoutePolylineMath.nearestVertexPoint`
    /// over the already-fetched route polyline; never an arbitrary 2D
    /// search or straight-line bisection.
    private func runSeedSearch(
        route: MKRoute,
        userLocation: CLLocation,
        friendLocation: CLLocation,
        diagnostics: MidpointDiagnostics,
        cancellationToken: SearchCancellationToken,
        completion: @escaping (Double, CLLocationCoordinate2D) -> Void
    ) {
        let initialFraction = 0.5
        let initialCoordinate = RoutePolylineMath.nearestVertexPoint(atFraction: initialFraction, along: route.polyline)
        diagnostics.initialSeedCoordinate = initialCoordinate

        #if DEBUG
        Self.logger.log("""
        [S9][\(diagnostics.searchID)] initial 50% route seed: \
        coordinate=(\(initialCoordinate.latitude), \(initialCoordinate.longitude))
        """)
        #endif

        etaPair(for: initialCoordinate, userLocation: userLocation, friendLocation: friendLocation, diagnostics: diagnostics) { [weak self] pair in
            guard let self = self else { return }
            // The initial seed ETA pair finished; don't go on to corrections
            // (or the hand-off to Yelp) for a cancelled search.
            guard SearchCancellationGate.shouldContinue(cancellationToken) else { return }
            diagnostics.mapKitRequestCount += 2

            guard let (userETA, friendETA) = pair else {
                #if DEBUG
                Self.logger.log("[S9][\(diagnostics.searchID)] initial seed ETA check FAILED (both legs)")
                #endif
                // Seed ETA check failed - the seed is still usable as a
                // search origin (restaurant-level ETAs are what actually
                // matter), it just can't be judged or corrected.
                diagnostics.seedCandidates.append(
                    SeedCandidateDiagnostics(
                        attemptIndex: 0, fraction: initialFraction, coordinate: initialCoordinate,
                        movementFromPreviousMeters: nil, userETA: nil, friendETA: nil,
                        etaDifference: nil, fairnessTolerance: nil, becameBest: true
                    )
                )
                completion(initialFraction, initialCoordinate)
                return
            }

            diagnostics.initialSeedETAs = (userETA, friendETA)
            let initialCandidate = SeedCandidate(fraction: initialFraction, coordinate: initialCoordinate, userETA: userETA, friendETA: friendETA)
            let tolerance = MidpointFairnessConfig.fairnessTolerance(forLongerETA: max(userETA, friendETA))

            #if DEBUG
            Self.logger.log("""
            [S9][\(diagnostics.searchID)] initial seed ETA: userToSeed=\(userETA)s friendToSeed=\(friendETA)s \
            diff=\(initialCandidate.diff)s tolerance=\(tolerance)s \
            \(initialCandidate.diff <= tolerance ? "WITHIN TOLERANCE" : "OUTSIDE TOLERANCE - correction will be attempted")
            """)
            #endif

            diagnostics.seedCandidates.append(
                SeedCandidateDiagnostics(
                    attemptIndex: 0, fraction: initialFraction, coordinate: initialCoordinate,
                    movementFromPreviousMeters: nil, userETA: userETA, friendETA: friendETA,
                    etaDifference: initialCandidate.diff, fairnessTolerance: tolerance, becameBest: true
                )
            )

            guard initialCandidate.diff > tolerance, MidpointFairnessConfig.maxSeedCorrections > 0 else {
                diagnostics.seedCorrectionStopReason = .fairnessMet
                completion(initialFraction, initialCoordinate)
                return
            }

            // Nudge toward whichever traveler has the longer ETA, along the
            // already-fetched route geometry.
            let direction: Double = userETA > friendETA ? -1 : 1
            self.attemptCorrection(
                attemptIndex: 1,
                direction: direction,
                route: route,
                previous: initialCandidate,
                best: initialCandidate,
                userLocation: userLocation,
                friendLocation: friendLocation,
                diagnostics: diagnostics,
                cancellationToken: cancellationToken,
                completion: completion
            )
        }
    }

    /// Evaluates one bounded correction attempt (1...`maxSeedCorrections`).
    /// Continues to the next attempt only when there's budget remaining,
    /// the previous move was large enough to matter, and the previous
    /// attempt both improved the ETA imbalance and didn't cross over to
    /// the opposite side - otherwise it stops and hands back the best
    /// candidate evaluated so far. This intentionally isn't a bisection
    /// solver: each step is the same fixed `seedCorrectionStep`, just
    /// applied only while it's still plausibly making things better.
    private func attemptCorrection(
        attemptIndex: Int,
        direction: Double,
        route: MKRoute,
        previous: SeedCandidate,
        best: SeedCandidate,
        userLocation: CLLocation,
        friendLocation: CLLocation,
        diagnostics: MidpointDiagnostics,
        cancellationToken: SearchCancellationToken,
        completion: @escaping (Double, CLLocationCoordinate2D) -> Void
    ) {
        guard attemptIndex <= MidpointFairnessConfig.maxSeedCorrections else {
            diagnostics.seedCorrectionStopReason = .budgetExhausted
            completion(best.fraction, best.coordinate)
            return
        }

        let candidateFraction = min(max(previous.fraction + direction * MidpointFairnessConfig.seedCorrectionStep, 0), 1)
        let candidateCoordinate = RoutePolylineMath.nearestVertexPoint(atFraction: candidateFraction, along: route.polyline)
        let movement = RoutePolylineMath.metersBetween(candidateCoordinate, previous.coordinate)

        #if DEBUG
        Self.logger.log("""
        [S9][\(diagnostics.searchID)] seed correction attempt \(attemptIndex): fraction=\(candidateFraction) \
        coordinate=(\(candidateCoordinate.latitude), \(candidateCoordinate.longitude)) movementFromPreviousMeters=\(movement)
        """)
        #endif

        guard movement >= MidpointFairnessConfig.minMeaningfulMovementMeters else {
            diagnostics.seedCandidates.append(
                SeedCandidateDiagnostics(
                    attemptIndex: attemptIndex, fraction: candidateFraction, coordinate: candidateCoordinate,
                    movementFromPreviousMeters: movement, userETA: nil, friendETA: nil,
                    etaDifference: nil, fairnessTolerance: nil, becameBest: false
                )
            )
            diagnostics.seedCorrectionStopReason = .movementTooSmall
            completion(best.fraction, best.coordinate)
            return
        }

        diagnostics.correctionOccurred = true

        etaPair(for: candidateCoordinate, userLocation: userLocation, friendLocation: friendLocation, diagnostics: diagnostics) { [weak self] pair in
            guard let self = self else { return }
            // This correction's ETA pair finished; don't chain another
            // correction (or hand off to Yelp) for a cancelled search.
            guard SearchCancellationGate.shouldContinue(cancellationToken) else { return }
            diagnostics.mapKitRequestCount += 2

            guard let (userETA, friendETA) = pair else {
                #if DEBUG
                Self.logger.log("[S9][\(diagnostics.searchID)] seed correction attempt \(attemptIndex) ETA check FAILED")
                #endif
                diagnostics.seedCandidates.append(
                    SeedCandidateDiagnostics(
                        attemptIndex: attemptIndex, fraction: candidateFraction, coordinate: candidateCoordinate,
                        movementFromPreviousMeters: movement, userETA: nil, friendETA: nil,
                        etaDifference: nil, fairnessTolerance: nil, becameBest: false
                    )
                )
                diagnostics.seedCorrectionStopReason = .budgetExhausted
                completion(best.fraction, best.coordinate)
                return
            }

            let candidate = SeedCandidate(fraction: candidateFraction, coordinate: candidateCoordinate, userETA: userETA, friendETA: friendETA)
            let tolerance = MidpointFairnessConfig.fairnessTolerance(forLongerETA: max(userETA, friendETA))
            let becameBest = candidate.diff < best.diff
            let newBest = becameBest ? candidate : best

            #if DEBUG
            Self.logger.log("""
            [S9][\(diagnostics.searchID)] seed correction attempt \(attemptIndex) result: \
            correctedSeedCoordinate=(\(candidateCoordinate.latitude), \(candidateCoordinate.longitude)) \
            userToSeed=\(userETA)s friendToSeed=\(friendETA)s diff=\(candidate.diff)s tolerance=\(tolerance)s \
            becameBest=\(becameBest)
            """)
            #endif

            diagnostics.seedCandidates.append(
                SeedCandidateDiagnostics(
                    attemptIndex: attemptIndex, fraction: candidateFraction, coordinate: candidateCoordinate,
                    movementFromPreviousMeters: movement, userETA: userETA, friendETA: friendETA,
                    etaDifference: candidate.diff, fairnessTolerance: tolerance, becameBest: becameBest
                )
            )

            if candidate.diff <= tolerance {
                diagnostics.seedCorrectionStopReason = .fairnessMet
                completion(newBest.fraction, newBest.coordinate)
                return
            }

            let improved = candidate.diff < previous.diff
            let crossedOver = (previous.userETA > previous.friendETA) != (candidate.userETA > candidate.friendETA)

            guard improved, !crossedOver else {
                diagnostics.seedCorrectionStopReason = .wouldWorsenOrCrossOver
                completion(newBest.fraction, newBest.coordinate)
                return
            }

            self.attemptCorrection(
                attemptIndex: attemptIndex + 1,
                direction: direction,
                route: route,
                previous: candidate,
                best: newBest,
                userLocation: userLocation,
                friendLocation: friendLocation,
                diagnostics: diagnostics,
                cancellationToken: cancellationToken,
                completion: completion
            )
        }
    }

    // MARK: - Route request

    private func requestRoute(
        from origin: CLLocation,
        to destination: CLLocation,
        attempt: Int = 0,
        cancellationToken: SearchCancellationToken,
        completion: @escaping (MKRoute?, Error?) -> Void
    ) {
        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: MKPlacemark(coordinate: origin.coordinate))
        request.destination = MKMapItem(placemark: MKPlacemark(coordinate: destination.coordinate))
        request.transportType = .automobile
        request.requestsAlternateRoutes = false

        MKDirections(request: request).calculate { [weak self] response, error in
            #if DEBUG
            Self.logger.log("[S9] RouteSeededMidpointStrategy.requestRoute completion thread: isMainThread=\(Thread.isMainThread) attempt=\(attempt)")
            #endif
            if let route = response?.routes.first {
                completion(route, nil)
                return
            }
            guard let self = self, attempt < self.maxRouteRetries else {
                completion(nil, error)
                return
            }
            // Don't spend the one route retry on a cancelled search.
            guard SearchCancellationGate.shouldContinue(cancellationToken) else { return }
            self.requestRoute(from: origin, to: destination, attempt: attempt + 1, cancellationToken: cancellationToken, completion: completion)
        }
    }

    // MARK: - ETA check

    private func etaPair(
        for coordinate: CLLocationCoordinate2D,
        userLocation: CLLocation,
        friendLocation: CLLocation,
        diagnostics: MidpointDiagnostics,
        completion: @escaping ((userETA: TimeInterval, friendETA: TimeInterval)?) -> Void
    ) {
        let candidateLocation = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        let group = DispatchGroup()
        var userResult: Result<TimeInterval, Error>?
        var friendResult: Result<TimeInterval, Error>?

        group.enter()
        requestETA(from: userLocation, to: candidateLocation) { result in
            if case .failure(let error) = result {
                diagnostics.mapKitFailures.append(
                    MapKitFailureRecord(stage: .seedETA, side: .user, restaurantID: nil, error: error)
                )
            }
            userResult = result
            group.leave()
        }
        group.enter()
        requestETA(from: friendLocation, to: candidateLocation) { result in
            if case .failure(let error) = result {
                diagnostics.mapKitFailures.append(
                    MapKitFailureRecord(stage: .seedETA, side: .friend, restaurantID: nil, error: error)
                )
            }
            friendResult = result
            group.leave()
        }

        group.notify(queue: .main) {
            guard let userETA = try? userResult?.get(), let friendETA = try? friendResult?.get() else {
                completion(nil)
                return
            }
            completion((userETA, friendETA))
        }
    }

    private func requestETA(
        from origin: CLLocation,
        to destination: CLLocation,
        completion: @escaping (Result<TimeInterval, Error>) -> Void
    ) {
        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: MKPlacemark(coordinate: origin.coordinate))
        request.destination = MKMapItem(placemark: MKPlacemark(coordinate: destination.coordinate))
        request.transportType = .automobile

        MKDirections(request: request).calculateETA { response, error in
            #if DEBUG
            Self.logger.log("[S9] RouteSeededMidpointStrategy.requestETA completion thread: isMainThread=\(Thread.isMainThread)")
            #endif
            if let response = response {
                completion(.success(response.expectedTravelTime))
            } else {
                completion(.failure(error ?? YelpManagerError.failedToUnwrapMidpoint))
            }
        }
    }

    // MARK: - Finalization

    private func finish(
        center: CLLocationCoordinate2D,
        seedFraction: Double,
        route: MKRoute,
        diagnostics: MidpointDiagnostics,
        completion: @escaping (MeetingRegion) -> Void
    ) {
        diagnostics.usedTrafficAwareRouting = true
        diagnostics.selectedCenter = center

        let radius = MidpointFairnessConfig.searchRadius(forRouteDistance: route.distance)
        diagnostics.searchRadiusMeters = radius

        #if DEBUG
        Self.logger.log("""
        [S9][\(diagnostics.searchID)] FINAL seed used for Yelp search: \
        coordinate=(\(center.latitude), \(center.longitude)) radiusMeters=\(radius) \
        seedFraction=\(seedFraction) trafficAware=true
        """)
        #endif

        completion(
            MeetingRegion(
                center: center,
                searchRadiusMeters: radius,
                userETA: diagnostics.initialSeedETAs?.userETA,
                friendETA: diagnostics.initialSeedETAs?.friendETA,
                isTrafficAwareResult: true,
                corridor: SearchCorridor(route: route, seedFraction: seedFraction),
                diagnostics: diagnostics
            )
        )
    }

    private func finishWithGeographicFallback(
        userLocation: CLLocation,
        friendLocation: CLLocation,
        diagnostics: MidpointDiagnostics,
        completion: @escaping (MeetingRegion) -> Void
    ) {
        let (center, radius) = GeographicMidpointStrategy.centerAndRadius(
            userLocation: userLocation,
            friendLocation: friendLocation
        )
        diagnostics.usedTrafficAwareRouting = false
        diagnostics.selectedCenter = center
        diagnostics.searchRadiusMeters = radius

        #if DEBUG
        Self.logger.log("""
        [S9][\(diagnostics.searchID)] FINAL seed used for Yelp search (geographic fallback, route failed): \
        coordinate=(\(center.latitude), \(center.longitude)) radiusMeters=\(radius) trafficAware=false
        """)
        #endif

        completion(
            MeetingRegion(
                center: center,
                searchRadiusMeters: radius,
                userETA: nil,
                friendETA: nil,
                isTrafficAwareResult: false,
                corridor: nil,
                diagnostics: diagnostics
            )
        )
    }
}
