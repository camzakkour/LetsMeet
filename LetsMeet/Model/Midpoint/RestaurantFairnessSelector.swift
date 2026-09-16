//
//  RestaurantFairnessSelector.swift
//  LetsMeet
//

import Foundation
import CoreLocation
import MapKit

/// Does the actual fairness work for the restaurant-first pipeline: Yelp is
/// asked for restaurants near a search region, a shortlist is built by
/// relevance + geographic diversity (not simply "closest N"), and only
/// shortlisted restaurants get bounded, batched, deduplicated bidirectional
/// ETA verification. A meeting-region seed coordinate is never itself
/// sufficient to call a restaurant fair - only a real MapKit ETA pair is.
///
/// If too few restaurants verify fair, the search adapts: sparse results
/// (few/no Yelp results at all) shift the search region along the route
/// corridor and/or expand the radius; plentiful-but-unfair results expand
/// the radius first, falling back to a bounded corridor shift only as a
/// last resort. All attempts are bounded - this never substitutes the raw,
/// unverified shortlist for a fairness result; if nothing verifies, that is
/// reported explicitly.
final class RestaurantFairnessSelector {

    func findFairRestaurants(
        in region: MeetingRegion,
        userLocation: CLLocation,
        friendLocation: CLLocation,
        diagnostics: MidpointDiagnostics?,
        completion: @escaping (MeetingPlaceOutcome) -> Void
    ) {
        let seedFraction = region.corridor?.seedFraction ?? 0.5
        runRound(
            roundIndex: 0,
            reason: .initial,
            center: region.center,
            radiusMeters: region.searchRadiusMeters,
            corridor: region.corridor,
            seedFraction: seedFraction,
            userLocation: userLocation,
            friendLocation: friendLocation,
            etaCache: [:],
            verifiedSoFar: [],
            yelpEverReturnedResults: false,
            yelpEverSucceeded: false,
            radiusExpansionsUsed: 0,
            corridorShiftsUsed: 0,
            searchedCenters: [(fraction: seedFraction, coordinate: region.center)],
            diagnostics: diagnostics,
            completion: completion
        )
    }

    // MARK: - Round loop

    private func runRound(
        roundIndex: Int,
        reason: SearchRoundReason,
        center: CLLocationCoordinate2D,
        radiusMeters: Double,
        corridor: SearchCorridor?,
        seedFraction: Double,
        userLocation: CLLocation,
        friendLocation: CLLocation,
        etaCache: [String: (userETA: TimeInterval, friendETA: TimeInterval)],
        verifiedSoFar: [Restaurant],
        yelpEverReturnedResults: Bool,
        yelpEverSucceeded: Bool,
        radiusExpansionsUsed: Int,
        corridorShiftsUsed: Int,
        searchedCenters: [(fraction: Double, coordinate: CLLocationCoordinate2D)],
        diagnostics: MidpointDiagnostics?,
        completion: @escaping (MeetingPlaceOutcome) -> Void
    ) {
        YelpManager.shared.searchRestaurants(near: center, radiusMeters: radiusMeters) { [weak self] result in
            guard let self = self else { return }

            switch result {
            case .failure(let error):
                // A failure only escalates to a hard search failure when no
                // prior round has ever successfully completed a Yelp search -
                // a transient failure in a later expansion/shift round should
                // stop remediation and finalize whatever earlier rounds
                // already established, not discard it.
                if !yelpEverSucceeded {
                    completion(.searchFailed(error))
                } else {
                    self.finalize(
                        verifiedSoFar: verifiedSoFar,
                        yelpEverReturnedResults: yelpEverReturnedResults,
                        diagnostics: diagnostics,
                        completion: completion
                    )
                }

            case .success(let restaurants):
                let sawResults = yelpEverReturnedResults || !restaurants.isEmpty

                let unverified = restaurants.filter { $0.coordinate != nil && etaCache[$0.id] == nil }
                let reusedIDs = restaurants.compactMap { etaCache[$0.id] != nil ? $0.id : nil }
                let shortlist = self.selectShortlist(
                    from: unverified,
                    radiusMeters: radiusMeters,
                    targetSize: MidpointFairnessConfig.restaurantShortlistSize
                )

                self.verifyBatched(shortlist, userLocation: userLocation, friendLocation: friendLocation, diagnostics: diagnostics) { newResults, requestCount in
                    diagnostics?.mapKitRequestCount += requestCount

                    var mergedCache = etaCache
                    newResults.forEach { mergedCache[$0.key] = $0.value }
                    newResults.forEach { diagnostics?.restaurantETAComparisons[$0.key] = $0.value }

                    let consideredThisRound = restaurants.filter { mergedCache[$0.id] != nil }
                    let fairThisRound = consideredThisRound.filter { self.isFair($0, cache: mergedCache) }

                    var mergedVerified = verifiedSoFar
                    for restaurant in fairThisRound where !mergedVerified.contains(where: { $0.id == restaurant.id }) {
                        mergedVerified.append(restaurant)
                    }

                    // Distinguishes "0 restaurants were fair" from "0
                    // restaurants could be verified" - both collapse to the
                    // same passingFairnessCount otherwise.
                    let etaAttemptedCount = shortlist.count
                    let etaVerifiedCount = newResults.count
                    let etaFailedCount = etaAttemptedCount - etaVerifiedCount

                    diagnostics?.searchRounds.append(
                        SearchRoundDiagnostics(
                            roundIndex: roundIndex,
                            reason: reason,
                            center: center,
                            radiusMeters: radiusMeters,
                            yelpResultCount: restaurants.count,
                            shortlistIDs: shortlist.map(\.id),
                            reusedETAIDs: reusedIDs,
                            etaAttemptedCount: etaAttemptedCount,
                            etaVerifiedCount: etaVerifiedCount,
                            etaFailedCount: etaFailedCount,
                            passingFairnessCount: fairThisRound.count
                        )
                    )

                    if mergedVerified.count >= MidpointFairnessConfig.minViableRestaurants {
                        self.finalize(
                            verifiedSoFar: mergedVerified,
                            yelpEverReturnedResults: sawResults,
                            diagnostics: diagnostics,
                            completion: completion
                        )
                        return
                    }

                    let isSparse = restaurants.count < MidpointFairnessConfig.sparsityThreshold
                    let canExpandRadius = radiusExpansionsUsed < MidpointFairnessConfig.maxRadiusExpansionRounds
                        && radiusMeters < MidpointFairnessConfig.maxSearchRadiusMeters
                    let canShiftCorridor = corridor != nil && corridorShiftsUsed < MidpointFairnessConfig.maxCorridorShiftAttempts

                    // Sparsity: prefer moving to a different spot over
                    // expanding around one that has little nearby - fall
                    // back to expansion only if there's no corridor to
                    // shift along (e.g. geographic-midpoint fallback).
                    // Unfairness: prefer expanding first - a bounded
                    // corridor shift is only a last resort.
                    let nextAction: NextAction?
                    if isSparse {
                        if canShiftCorridor {
                            nextAction = .shiftCorridor(reason: .sparsityCorridorShift)
                        } else if canExpandRadius {
                            nextAction = .expandRadius(reason: .sparsityRadiusExpansion)
                        } else {
                            nextAction = nil
                        }
                    } else {
                        if canExpandRadius {
                            nextAction = .expandRadius(reason: .unfairnessRadiusExpansion)
                        } else if canShiftCorridor {
                            nextAction = .shiftCorridor(reason: .unfairnessCorridorShift)
                        } else {
                            nextAction = nil
                        }
                    }

                    switch nextAction {
                    case .expandRadius(let nextReason):
                        let expandedRadius = min(
                            radiusMeters * MidpointFairnessConfig.radiusExpansionMultiplier,
                            MidpointFairnessConfig.maxSearchRadiusMeters
                        )
                        self.runRound(
                            roundIndex: roundIndex + 1,
                            reason: nextReason,
                            center: center,
                            radiusMeters: expandedRadius,
                            corridor: corridor,
                            seedFraction: seedFraction,
                            userLocation: userLocation,
                            friendLocation: friendLocation,
                            etaCache: mergedCache,
                            verifiedSoFar: mergedVerified,
                            yelpEverReturnedResults: sawResults,
                            yelpEverSucceeded: true,
                            radiusExpansionsUsed: radiusExpansionsUsed + 1,
                            corridorShiftsUsed: corridorShiftsUsed,
                            searchedCenters: searchedCenters,
                            diagnostics: diagnostics,
                            completion: completion
                        )

                    case .shiftCorridor(let nextReason):
                        guard let corridor = corridor else {
                            self.finalize(verifiedSoFar: mergedVerified, yelpEverReturnedResults: sawResults, diagnostics: diagnostics, completion: completion)
                            return
                        }
                        let bias = self.corridorShiftDirectionBias(diagnostics: diagnostics, corridorShiftsUsed: corridorShiftsUsed)
                        guard let shift = self.pickUnsearchedShift(
                            corridor: corridor,
                            seedFraction: seedFraction,
                            bias: bias,
                            searchedCenters: searchedCenters,
                            diagnostics: diagnostics
                        ) else {
                            // No unsearched, meaningfully-different fraction
                            // available within the shift budget - finalize
                            // rather than spending another round on a
                            // duplicate search center.
                            self.finalize(verifiedSoFar: mergedVerified, yelpEverReturnedResults: sawResults, diagnostics: diagnostics, completion: completion)
                            return
                        }
                        self.runRound(
                            roundIndex: roundIndex + 1,
                            reason: nextReason,
                            center: shift.coordinate,
                            radiusMeters: radiusMeters,
                            corridor: corridor,
                            seedFraction: shift.fraction,
                            userLocation: userLocation,
                            friendLocation: friendLocation,
                            etaCache: mergedCache,
                            verifiedSoFar: mergedVerified,
                            yelpEverReturnedResults: sawResults,
                            yelpEverSucceeded: true,
                            radiusExpansionsUsed: radiusExpansionsUsed,
                            corridorShiftsUsed: corridorShiftsUsed + 1,
                            searchedCenters: searchedCenters + [(fraction: shift.fraction, coordinate: shift.coordinate)],
                            diagnostics: diagnostics,
                            completion: completion
                        )

                    case nil:
                        self.finalize(
                            verifiedSoFar: mergedVerified,
                            yelpEverReturnedResults: sawResults,
                            diagnostics: diagnostics,
                            completion: completion
                        )
                    }
                }
            }
        }
    }

    private enum NextAction {
        case expandRadius(reason: SearchRoundReason)
        case shiftCorridor(reason: SearchRoundReason)
    }

    // MARK: - Corridor shift selection

    /// Picks which direction along the route a corridor shift is most
    /// likely to help. Verified restaurant ETA evidence (already paid for
    /// in prior rounds) takes priority over the route seed: the median of
    /// `userETA - friendETA` across every restaurant in
    /// `diagnostics.restaurantETAComparisons` reflects where actual
    /// candidate destinations sit relative to both travelers, which is a
    /// stronger signal than the single seed coordinate. Falls back to the
    /// seed-based/alternating logic only when there's no restaurant
    /// evidence yet, or when the median imbalance is within
    /// `MidpointFairnessConfig.minTolerance` of zero (too ambiguous to act
    /// on). Costs zero new MapKit requests - reuses ETA pairs already
    /// gathered during `verifyBatched`.
    private func corridorShiftDirectionBias(diagnostics: MidpointDiagnostics?, corridorShiftsUsed: Int) -> Double {
        let comparisons = diagnostics?.restaurantETAComparisons ?? [:]
        let median = medianSignedImbalance(from: comparisons)

        let direction: Double
        let interpretation: CorridorDirectionInterpretation
        let usedRestaurantEvidence: Bool

        if let median = median {
            if median < -MidpointFairnessConfig.minTolerance {
                // Restaurants collectively favor the user (short userETA,
                // long friendETA) - move the search region toward the
                // friend.
                direction = 1
                interpretation = .towardFriend
                usedRestaurantEvidence = true
            } else if median > MidpointFairnessConfig.minTolerance {
                // Restaurants collectively favor the friend - move toward
                // the user.
                direction = -1
                interpretation = .towardUser
                usedRestaurantEvidence = true
            } else {
                direction = seedOrAlternatingDirectionBias(diagnostics: diagnostics, corridorShiftsUsed: corridorShiftsUsed)
                interpretation = .ambiguousFallback
                usedRestaurantEvidence = false
            }
        } else {
            direction = seedOrAlternatingDirectionBias(diagnostics: diagnostics, corridorShiftsUsed: corridorShiftsUsed)
            interpretation = .noRestaurantEvidenceFallback
            usedRestaurantEvidence = false
        }

        diagnostics?.corridorDirectionDecisions.append(
            CorridorDirectionDiagnostics(
                sampleCount: comparisons.count,
                medianSignedImbalance: median,
                interpretation: interpretation,
                direction: direction,
                usedRestaurantEvidence: usedRestaurantEvidence
            )
        )

        return direction
    }

    /// Median of `userETA - friendETA` across every verified restaurant ETA
    /// comparison so far. Nil when there are none yet.
    private func medianSignedImbalance(from comparisons: [String: (userETA: TimeInterval, friendETA: TimeInterval)]) -> TimeInterval? {
        guard !comparisons.isEmpty else { return nil }
        let signed = comparisons.values.map { $0.userETA - $0.friendETA }.sorted()
        let count = signed.count
        if count % 2 == 1 {
            return signed[count / 2]
        } else {
            return (signed[count / 2 - 1] + signed[count / 2]) / 2
        }
    }

    /// The original direction heuristic: derived from the best-evaluated
    /// route-seed candidate's ETA comparison, or alternating by shift count
    /// when no seed ETA info is available (e.g. the geographic-midpoint
    /// fallback has no seed candidates). Used only when restaurant evidence
    /// is absent or ambiguous.
    private func seedOrAlternatingDirectionBias(diagnostics: MidpointDiagnostics?, corridorShiftsUsed: Int) -> Double {
        let bestSeed = diagnostics?.seedCandidates
            .compactMap { candidate -> (diff: TimeInterval, userETA: TimeInterval, friendETA: TimeInterval)? in
                guard let userETA = candidate.userETA, let friendETA = candidate.friendETA, let diff = candidate.etaDifference else { return nil }
                return (diff, userETA, friendETA)
            }
            .min { $0.diff < $1.diff }

        if let bestSeed = bestSeed {
            return bestSeed.userETA > bestSeed.friendETA ? -1 : 1
        }
        return corridorShiftsUsed.isMultiple(of: 2) ? 1 : -1
    }

    /// Tries `bias` first, then the opposite direction, for a corridor-
    /// shift candidate that both moves meaningfully from every previously
    /// searched center (`minMeaningfulMovementMeters`) and hasn't already
    /// been searched this run. Returns nil when neither direction clears
    /// both checks, signaling the caller should finalize instead of
    /// spending another round on a duplicate center. Records every
    /// candidate considered (accepted or not) to `diagnostics.corridorShiftAttempts`.
    private func pickUnsearchedShift(
        corridor: SearchCorridor,
        seedFraction: Double,
        bias: Double,
        searchedCenters: [(fraction: Double, coordinate: CLLocationCoordinate2D)],
        diagnostics: MidpointDiagnostics?
    ) -> (fraction: Double, coordinate: CLLocationCoordinate2D)? {
        let previous = searchedCenters.last

        for direction in [bias, -bias] {
            let candidateFraction = min(max(seedFraction + direction * MidpointFairnessConfig.corridorShiftStep, 0), 1)
            let candidateCoordinate = RoutePolylineMath.nearestVertexPoint(atFraction: candidateFraction, along: corridor.route.polyline)

            let alreadySearched = searchedCenters.contains {
                RoutePolylineMath.metersBetween($0.coordinate, candidateCoordinate) < MidpointFairnessConfig.minMeaningfulMovementMeters
            }
            let movementFromPrevious = previous.map { RoutePolylineMath.metersBetween($0.coordinate, candidateCoordinate) } ?? 0
            let accepted = !alreadySearched && movementFromPrevious >= MidpointFairnessConfig.minMeaningfulMovementMeters

            diagnostics?.corridorShiftAttempts.append(
                CorridorShiftDiagnostics(
                    oldFraction: previous?.fraction ?? seedFraction,
                    proposedFraction: candidateFraction,
                    oldCoordinate: previous?.coordinate ?? candidateCoordinate,
                    proposedCoordinate: candidateCoordinate,
                    movementMeters: movementFromPrevious,
                    accepted: accepted,
                    reason: accepted ? "accepted" : (alreadySearched ? "already searched" : "movement too small")
                )
            )

            if accepted {
                return (candidateFraction, candidateCoordinate)
            }
        }
        return nil
    }

    private func finalize(
        verifiedSoFar: [Restaurant],
        yelpEverReturnedResults: Bool,
        diagnostics: MidpointDiagnostics?,
        completion: @escaping (MeetingPlaceOutcome) -> Void
    ) {
        diagnostics?.finalRestaurantIDs = verifiedSoFar.map(\.id)

        if verifiedSoFar.count >= MidpointFairnessConfig.minViableRestaurants {
            completion(.success(restaurants: verifiedSoFar))
        } else if !verifiedSoFar.isEmpty {
            completion(.limitedFairOptions(restaurants: verifiedSoFar))
        } else if yelpEverReturnedResults {
            completion(.noFairRestaurants)
        } else {
            completion(.noRestaurantsNearby)
        }
    }

    private func isFair(_ restaurant: Restaurant, cache: [String: (userETA: TimeInterval, friendETA: TimeInterval)]) -> Bool {
        guard let comparison = cache[restaurant.id] else { return false }
        let tolerance = MidpointFairnessConfig.fairnessTolerance(forLongerETA: max(comparison.userETA, comparison.friendETA))
        return abs(comparison.userETA - comparison.friendETA) <= tolerance
    }

    // MARK: - Shortlist selection (relevance + geographic diversity)

    /// Selects up to `targetSize` restaurants using Yelp's own best-match
    /// relevance ordering (implicit in `restaurants`' input order) combined
    /// with rating and review count, then greedily skips candidates too
    /// close to ones already picked so the shortlist isn't clustered in one
    /// tiny area. Deliberately simple - not a recommendation engine.
    private func selectShortlist(from restaurants: [Restaurant], radiusMeters: Double, targetSize: Int) -> [Restaurant] {
        let scored = restaurants.enumerated().map { index, restaurant -> (Restaurant, Double) in
            (restaurant, score(restaurant, relevanceIndex: index, totalCount: restaurants.count, radiusMeters: radiusMeters))
        }.sorted { $0.1 > $1.1 }

        var selected: [Restaurant] = []
        for (restaurant, _) in scored {
            guard selected.count < targetSize, let coordinate = restaurant.coordinate else { continue }
            let tooClose = selected.contains { existing in
                guard let existingCoordinate = existing.coordinate else { return false }
                let a = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
                let b = CLLocation(latitude: existingCoordinate.latitude, longitude: existingCoordinate.longitude)
                return a.distance(from: b) < MidpointFairnessConfig.diversityMinSeparationMeters
            }
            if !tooClose {
                selected.append(restaurant)
            }
        }

        // Backfill with the next-best candidates (ignoring diversity) if the
        // diversity pass left the shortlist short - a small, nearby cluster
        // beats an artificially short list.
        if selected.count < targetSize {
            for (restaurant, _) in scored where selected.count < targetSize {
                if !selected.contains(where: { $0.id == restaurant.id }) {
                    selected.append(restaurant)
                }
            }
        }

        return selected
    }

    private func score(_ restaurant: Restaurant, relevanceIndex: Int, totalCount: Int, radiusMeters: Double) -> Double {
        let relevanceComponent = totalCount > 1 ? 1.0 - (Double(relevanceIndex) / Double(totalCount - 1)) : 1.0
        let ratingComponent = restaurant.rating / 5.0
        let reviewCount = Double(restaurant.reviewCount ?? 0)
        let reviewComponent = min(log(reviewCount + 1) / log(1_001), 1.0)
        let distance = restaurant.distance ?? radiusMeters
        let proximityComponent = 1.0 - min(distance / max(radiusMeters, 1), 1.0)

        return (0.40 * relevanceComponent) + (0.25 * ratingComponent) + (0.15 * reviewComponent) + (0.20 * proximityComponent)
    }

    // MARK: - Bounded, batched ETA verification

    /// Verifies restaurants in bounded batches rather than firing every
    /// ETA request at once, so a 10-restaurant shortlist doesn't burst 20
    /// simultaneous MKDirections requests.
    private func verifyBatched(
        _ restaurants: [Restaurant],
        userLocation: CLLocation,
        friendLocation: CLLocation,
        diagnostics: MidpointDiagnostics?,
        completion: @escaping ([String: (userETA: TimeInterval, friendETA: TimeInterval)], Int) -> Void
    ) {
        guard !restaurants.isEmpty else {
            completion([:], 0)
            return
        }

        let batchSize = max(MidpointFairnessConfig.etaConcurrencyBatchSize, 1)
        let batches = stride(from: 0, to: restaurants.count, by: batchSize).map {
            Array(restaurants[$0..<min($0 + batchSize, restaurants.count)])
        }

        var allResults: [String: (userETA: TimeInterval, friendETA: TimeInterval)] = [:]
        var totalRequests = 0

        func runBatch(_ index: Int) {
            guard index < batches.count else {
                completion(allResults, totalRequests)
                return
            }

            let group = DispatchGroup()
            for restaurant in batches[index] {
                guard let coordinate = restaurant.coordinate else { continue }
                let destination = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)

                group.enter()
                fetchBothETAs(
                    userLocation: userLocation,
                    friendLocation: friendLocation,
                    destination: destination,
                    restaurantID: restaurant.id,
                    diagnostics: diagnostics
                ) { userResult, friendResult in
                    totalRequests += 2
                    if let userETA = try? userResult.get(), let friendETA = try? friendResult.get() {
                        allResults[restaurant.id] = (userETA, friendETA)
                    }
                    group.leave()
                }
            }

            group.notify(queue: .main) {
                runBatch(index + 1)
            }
        }

        runBatch(0)
    }

    private func fetchBothETAs(
        userLocation: CLLocation,
        friendLocation: CLLocation,
        destination: CLLocation,
        restaurantID: String,
        diagnostics: MidpointDiagnostics?,
        completion: @escaping (Result<TimeInterval, Error>, Result<TimeInterval, Error>) -> Void
    ) {
        let innerGroup = DispatchGroup()
        var userResult: Result<TimeInterval, Error> = .failure(YelpManagerError.failedToUnwrapMidpoint)
        var friendResult: Result<TimeInterval, Error> = .failure(YelpManagerError.failedToUnwrapMidpoint)

        innerGroup.enter()
        requestETA(from: userLocation, to: destination) { result in
            if case .failure(let error) = result {
                diagnostics?.mapKitFailures.append(
                    MapKitFailureRecord(stage: .restaurantETA, side: .user, restaurantID: restaurantID, error: error)
                )
            }
            userResult = result
            innerGroup.leave()
        }

        innerGroup.enter()
        requestETA(from: friendLocation, to: destination) { result in
            if case .failure(let error) = result {
                diagnostics?.mapKitFailures.append(
                    MapKitFailureRecord(stage: .restaurantETA, side: .friend, restaurantID: restaurantID, error: error)
                )
            }
            friendResult = result
            innerGroup.leave()
        }

        innerGroup.notify(queue: .main) {
            completion(userResult, friendResult)
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
            if let response = response {
                completion(.success(response.expectedTravelTime))
            } else {
                completion(.failure(error ?? YelpManagerError.failedToUnwrapMidpoint))
            }
        }
    }
}
