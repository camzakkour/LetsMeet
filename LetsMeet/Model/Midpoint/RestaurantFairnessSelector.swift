//
//  RestaurantFairnessSelector.swift
//  LetsMeet
//

import Foundation
import CoreLocation
import MapKit
import os.log

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

    #if DEBUG
    private static let logger = Logger(subsystem: "com.letsmeet.app", category: "Session9")
    #endif

    func findFairRestaurants(
        in region: MeetingRegion,
        userLocation: CLLocation,
        friendLocation: CLLocation,
        diagnostics: MidpointDiagnostics?,
        cancellationToken: SearchCancellationToken,
        onProgress: @escaping ([Restaurant]) -> Void,
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
            distanceCache: [:],
            verifiedSoFar: [],
            verifiedUnfairSoFar: [],
            yelpOrderIndex: [:],
            yelpEverReturnedResults: false,
            yelpEverSucceeded: false,
            lastEvidenceRoundWasReliable: true,
            radiusExpansionsUsed: 0,
            corridorShiftsUsed: 0,
            searchedCenters: [(fraction: seedFraction, coordinate: region.center)],
            diagnostics: diagnostics,
            cancellationToken: cancellationToken,
            onProgress: onProgress,
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
        distanceCache: [String: (userDistance: Double, friendDistance: Double)],
        verifiedSoFar: [Restaurant],
        verifiedUnfairSoFar: [Restaurant],
        yelpOrderIndex: [String: Int],
        yelpEverReturnedResults: Bool,
        yelpEverSucceeded: Bool,
        lastEvidenceRoundWasReliable: Bool,
        radiusExpansionsUsed: Int,
        corridorShiftsUsed: Int,
        searchedCenters: [(fraction: Double, coordinate: CLLocationCoordinate2D)],
        diagnostics: MidpointDiagnostics?,
        cancellationToken: SearchCancellationToken,
        onProgress: @escaping ([Restaurant]) -> Void,
        completion: @escaping (MeetingPlaceOutcome) -> Void
    ) {
        // A cancelled search ends silently here - this is the one point every
        // round (the first and each radius-expansion / corridor-shift
        // recursion) passes through before issuing its Yelp request.
        guard SearchCancellationGate.shouldContinue(cancellationToken) else { return }

        #if DEBUG
        Self.logger.log("""
        [S9][\(diagnostics?.searchID ?? "?")] round \(roundIndex) (\(reason.rawValue)) Yelp search START: \
        center=(\(center.latitude), \(center.longitude)) radiusMeters=\(radiusMeters)
        """)
        #endif

        #if DEBUG
        let yelpCallStart = CFAbsoluteTimeGetCurrent()
        #endif

        YelpManager.shared.searchRestaurants(near: center, radiusMeters: radiusMeters) { [weak self] result in
            guard let self = self else { return }
            // The request itself may have been in flight at cancellation and
            // is left to finish; but its result must not start shortlist/ETA
            // work, and a failure here must not surface as `.searchFailed`.
            guard SearchCancellationGate.shouldContinue(cancellationToken) else { return }

            #if DEBUG
            let yelpCallDuration = CFAbsoluteTimeGetCurrent() - yelpCallStart
            diagnostics?.yelpTotalDuration += yelpCallDuration
            Self.logger.log("""
            [S9][\(diagnostics?.searchID ?? "?")] round \(roundIndex) Yelp completion thread: \
            isMainThread=\(Thread.isMainThread)
            """)
            Self.logger.log("[Timing][S9][\(diagnostics?.searchID ?? "?")] round \(roundIndex) Yelp request took \(yelpCallDuration)s")
            #endif

            switch result {
            case .failure(let error):
                #if DEBUG
                Self.logger.log("[S9][\(diagnostics?.searchID ?? "?")] round \(roundIndex) Yelp search FAILED: \(error)")
                #endif
                // A failure only escalates to a hard search failure when no
                // prior round has ever successfully completed a Yelp search -
                // a transient failure in a later expansion/shift round should
                // stop remediation and finalize whatever earlier rounds
                // already established, not discard it.
                if !yelpEverSucceeded {
                    completion(.searchFailed(error))
                } else {
                    // The Yelp failure itself says nothing about ETA
                    // reliability, so use the reliability from the most
                    // recent earlier round that actually attempted ETA
                    // verification. It only matters when nothing has
                    // accumulated: an empty verifiedSoFar after an
                    // unreliable earlier round must stay
                    // etaVerificationUnavailable, not become
                    // noFairRestaurants.
                    self.finalize(
                        verifiedSoFar: verifiedSoFar,
                        verifiedUnfair: verifiedUnfairSoFar,
                        etaCache: etaCache,
                        distanceCache: distanceCache,
                        yelpOrderIndex: yelpOrderIndex,
                        yelpEverReturnedResults: yelpEverReturnedResults,
                        roundWasReliable: lastEvidenceRoundWasReliable,
                        diagnostics: diagnostics,
                        completion: completion
                    )
                }

            case .success(let restaurants):
                #if DEBUG
                Self.logger.log("""
                [S9][\(diagnostics?.searchID ?? "?")] round \(roundIndex) Yelp returned \(restaurants.count) businesses. \
                Ordered IDs: \(restaurants.map(\.id))
                """)
                #endif

                let sawResults = yelpEverReturnedResults || !restaurants.isEmpty

                let unverified = restaurants.filter { $0.coordinate != nil && etaCache[$0.id] == nil }
                let reusedIDs = restaurants.compactMap { etaCache[$0.id] != nil ? $0.id : nil }
                #if DEBUG
                let shortlistStart = CFAbsoluteTimeGetCurrent()
                #endif
                let shortlist = self.selectShortlist(
                    from: unverified,
                    radiusMeters: radiusMeters,
                    targetSize: MidpointFairnessConfig.restaurantShortlistSize
                )
                #if DEBUG
                let shortlistDuration = CFAbsoluteTimeGetCurrent() - shortlistStart
                diagnostics?.shortlistTotalDuration += shortlistDuration
                Self.logger.log("[Timing][S9][\(diagnostics?.searchID ?? "?")] round \(roundIndex) shortlist selection took \(shortlistDuration)s")
                #endif

                #if DEBUG
                let shortlistDescription = shortlist.enumerated().map { shortlistIndex, restaurant -> String in
                    let originalIndex = restaurants.firstIndex(where: { $0.id == restaurant.id }) ?? -1
                    return "[\(shortlistIndex)] id=\(restaurant.id) name=\(restaurant.name) yelpIndex=\(originalIndex) " +
                        "rating=\(restaurant.rating) reviewCount=\(restaurant.reviewCount ?? 0) distance=\(restaurant.distance ?? -1)"
                }.joined(separator: " || ")
                Self.logger.log("""
                [S9][\(diagnostics?.searchID ?? "?")] round \(roundIndex) shortlist selected for ETA verification \
                (\(shortlist.count) of \(restaurants.count)): \(shortlistDescription)
                """)
                #endif

                #if DEBUG
                let etaVerificationStart = CFAbsoluteTimeGetCurrent()
                #endif
                self.verifyBatched(
                    shortlist,
                    userLocation: userLocation,
                    friendLocation: friendLocation,
                    diagnostics: diagnostics,
                    cancellationToken: cancellationToken,
                    onBatchProgress: { partialResults, partialDistances in
                        // Cumulative snapshot of everything resolved so far in
                        // THIS round's verification, merged on top of
                        // whatever prior rounds already established - never a
                        // separate ranking pass, just an earlier read of the
                        // same fair/unfair classification and
                        // `buildDisplayList` call `finalize` uses at the end.
                        var progressCache = etaCache
                        partialResults.forEach { progressCache[$0.key] = $0.value }
                        var progressDistanceCache = distanceCache
                        partialDistances.forEach { progressDistanceCache[$0.key] = $0.value }

                        let consideredSoFar = restaurants.filter { progressCache[$0.id] != nil }
                        let fairSoFar = consideredSoFar.filter { self.isFair($0, cache: progressCache) }

                        var progressVerified = verifiedSoFar
                        for restaurant in fairSoFar where !progressVerified.contains(where: { $0.id == restaurant.id }) {
                            progressVerified.append(restaurant)
                        }

                        let unfairSoFar = consideredSoFar.filter { candidate in
                            !fairSoFar.contains(where: { $0.id == candidate.id })
                        }
                        var progressUnfair = verifiedUnfairSoFar
                        for restaurant in unfairSoFar
                        where !progressUnfair.contains(where: { $0.id == restaurant.id })
                            && !progressVerified.contains(where: { $0.id == restaurant.id }) {
                            progressUnfair.append(restaurant)
                        }

                        // Nothing displayable yet this batch - wait for a
                        // later one rather than presenting an empty sheet.
                        guard !progressVerified.isEmpty || !progressUnfair.isEmpty else { return }

                        var progressYelpOrderIndex = yelpOrderIndex
                        for (index, restaurant) in restaurants.enumerated() where progressYelpOrderIndex[restaurant.id] == nil {
                            progressYelpOrderIndex[restaurant.id] = index
                        }

                        let displaySoFar = ETAVerificationDecision.buildDisplayList(
                            fair: progressVerified,
                            verifiedUnfair: progressUnfair,
                            etaCache: progressCache,
                            yelpOrderIndex: progressYelpOrderIndex,
                            distanceCache: progressDistanceCache
                        )
                        onProgress(displaySoFar)
                    }
                ) { newResults, newDistances, requestCount in
                    #if DEBUG
                    let etaVerificationDuration = CFAbsoluteTimeGetCurrent() - etaVerificationStart
                    diagnostics?.etaVerificationTotalDuration += etaVerificationDuration
                    Self.logger.log("""
                    [S9][\(diagnostics?.searchID ?? "?")] round \(roundIndex) verifyBatched completion thread: \
                    isMainThread=\(Thread.isMainThread) requestCount=\(requestCount)
                    """)
                    Self.logger.log("[Timing][S9][\(diagnostics?.searchID ?? "?")] round \(roundIndex) ETA verification took \(etaVerificationDuration)s")
                    #endif

                    diagnostics?.mapKitRequestCount += requestCount

                    var mergedCache = etaCache
                    newResults.forEach { mergedCache[$0.key] = $0.value }
                    newResults.forEach { diagnostics?.restaurantETAComparisons[$0.key] = $0.value }

                    var mergedDistanceCache = distanceCache
                    newDistances.forEach { mergedDistanceCache[$0.key] = $0.value }

                    let consideredThisRound = restaurants.filter { mergedCache[$0.id] != nil }
                    let fairThisRound = consideredThisRound.filter { self.isFair($0, cache: mergedCache) }

                    #if DEBUG
                    for restaurant in consideredThisRound {
                        guard let comparison = mergedCache[restaurant.id] else { continue }
                        let tolerance = MidpointFairnessConfig.fairnessTolerance(forLongerETA: max(comparison.userETA, comparison.friendETA))
                        let delta = abs(comparison.userETA - comparison.friendETA)
                        let passed = delta <= tolerance
                        Self.logger.log("""
                        [S9][\(diagnostics?.searchID ?? "?")] round \(roundIndex) ETA result id=\(restaurant.id) \
                        name=\(restaurant.name) coordinate=\(String(describing: restaurant.coordinate)) \
                        userETA=\(comparison.userETA) friendETA=\(comparison.friendETA) delta=\(delta) \
                        tolerance=\(tolerance) result=\(passed ? "PASS" : "FAIL")
                        """)
                    }
                    for restaurant in shortlist where mergedCache[restaurant.id] == nil {
                        Self.logger.log("""
                        [S9][\(diagnostics?.searchID ?? "?")] round \(roundIndex) ETA verification FAILED (no ETA pair) \
                        for id=\(restaurant.id) name=\(restaurant.name)
                        """)
                    }
                    #endif

                    var mergedVerified = verifiedSoFar
                    for restaurant in fairThisRound where !mergedVerified.contains(where: { $0.id == restaurant.id }) {
                        mergedVerified.append(restaurant)
                    }

                    // Restaurants that verified (a real bidirectional ETA
                    // pair) but did not pass the fairness rule - accumulated
                    // across rounds the same way `mergedVerified` is, so
                    // they're available as fallback "additional options" at
                    // finalize time even if a later round is what pushes the
                    // search past `minViableRestaurants` fair results.
                    // Excludes anything already in `mergedVerified` as a
                    // safety net, though a restaurant's fairness verdict is
                    // deterministic for a given cached ETA pair and never
                    // actually flips between rounds.
                    var mergedUnfair = verifiedUnfairSoFar
                    let unfairThisRound = consideredThisRound.filter { candidate in
                        !fairThisRound.contains(where: { $0.id == candidate.id })
                    }
                    for restaurant in unfairThisRound
                    where !mergedUnfair.contains(where: { $0.id == restaurant.id })
                        && !mergedVerified.contains(where: { $0.id == restaurant.id }) {
                        mergedUnfair.append(restaurant)
                    }

                    // First-seen-round Yelp result-order index per
                    // restaurant ID, used only as a secondary (tie-break)
                    // ranking signal for "additional options" at finalize
                    // time - Yelp's own best-match relevance ordering is
                    // `restaurants`' input order, so a lower index means
                    // more relevant.
                    var mergedYelpOrderIndex = yelpOrderIndex
                    for (index, restaurant) in restaurants.enumerated() where mergedYelpOrderIndex[restaurant.id] == nil {
                        mergedYelpOrderIndex[restaurant.id] = index
                    }

                    // Distinguishes "0 restaurants were fair" from "0
                    // restaurants could be verified" - both collapse to the
                    // same passingFairnessCount otherwise.
                    let etaAttemptedCount = shortlist.count
                    let etaVerifiedCount = newResults.count
                    let etaFailedCount = etaAttemptedCount - etaVerifiedCount
                    // Computed against `consideredThisRound` (same base as
                    // `fairThisRound`/`passingFairnessCount`, which includes
                    // reused cached ETAs, not just this round's new
                    // fetches) so the two numbers always sum correctly.
                    let verifiedUnfairCount = consideredThisRound.count - fairThisRound.count

                    // A round is only trusted as evidence of genuine
                    // unfairness when enough of its shortlist actually
                    // produced an ETA pair. When attemptedCount is 0 (every
                    // shortlisted candidate was already cached from a prior
                    // round), there's nothing new to distrust, so treat it
                    // as reliable.
                    let verificationRatio = etaAttemptedCount == 0 ? 1.0 : Double(etaVerifiedCount) / Double(etaAttemptedCount)
                    let roundReliable = ETAVerificationDecision.isRoundReliable(
                        etaAttemptedCount: etaAttemptedCount,
                        etaVerifiedCount: etaVerifiedCount
                    )
                    // Carried into any following round so a later Yelp
                    // failure can classify an empty result; a round that
                    // attempted no ETAs leaves the earlier value untouched.
                    let carriedReliability = ETAVerificationDecision.carriedReliability(
                        previous: lastEvidenceRoundWasReliable,
                        etaAttemptedCount: etaAttemptedCount,
                        roundWasReliable: roundReliable
                    )

                    #if DEBUG
                    let shortlistIDSet = Set(shortlist.map(\.id))
                    let roundRetryCount = diagnostics?.etaRetries.filter { shortlistIDSet.contains($0.restaurantID) }.count ?? 0
                    Self.logger.log("""
                    [S9][\(diagnostics?.searchID ?? "?")] round \(roundIndex) summary: yelpReturned=\(restaurants.count) \
                    shortlisted=\(shortlist.count) etaAttempted=\(etaAttemptedCount) etaVerified=\(etaVerifiedCount) \
                    etaFailed=\(etaFailedCount) verificationRatio=\(verificationRatio) passingFairness=\(fairThisRound.count) \
                    verifiedUnfair=\(verifiedUnfairCount) reliable=\(roundReliable) retriesThisRound=\(roundRetryCount) \
                    mapKitRequestsSoFar=\(diagnostics?.mapKitRequestCount ?? 0) \
                    fairAccumulated=\(mergedVerified.count) verifiedUnfairAccumulated=\(mergedUnfair.count)
                    """)
                    #endif

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
                            passingFairnessCount: fairThisRound.count,
                            verifiedUnfairCount: verifiedUnfairCount,
                            reliable: roundReliable
                        )
                    )

                    // See ETAVerificationDecision.shouldStopRounds's doc
                    // comment: stopping is based on unique displayable
                    // restaurant IDs (never raw/duplicate-prone counts, never
                    // unverified candidates), OR'd with the original
                    // strictly-fair threshold.
                    let uniqueDisplayableCount = ETAVerificationDecision.uniqueDisplayableCount(fair: mergedVerified, verifiedUnfair: mergedUnfair)
                    let shouldStopRounds = ETAVerificationDecision.shouldStopRounds(
                        verifiedCount: mergedVerified.count,
                        uniqueDisplayableCount: uniqueDisplayableCount
                    )

                    if shouldStopRounds {
                        #if DEBUG
                        Self.logger.log("""
                        [S9][\(diagnostics?.searchID ?? "?")] round \(roundIndex) stopping: \
                        (fair=\(mergedVerified.count) unfair=\(mergedUnfair.count) uniqueDisplayable=\(uniqueDisplayableCount))
                        """)
                        #endif
                        self.finalize(
                            verifiedSoFar: mergedVerified,
                            verifiedUnfair: mergedUnfair,
                            etaCache: mergedCache,
                            distanceCache: mergedDistanceCache,
                            yelpOrderIndex: mergedYelpOrderIndex,
                            yelpEverReturnedResults: sawResults,
                            roundWasReliable: roundReliable,
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
                    // shift along (e.g. geographic-midpoint fallback). This
                    // is driven by the raw Yelp result count, so it's
                    // unaffected by ETA reliability.
                    // Unfairness: prefer expanding first - a bounded
                    // corridor shift is only a last resort. This branch is
                    // ONLY trustworthy when the round was reliable - a round
                    // dominated by ETA failures must not be read as
                    // evidence that the area itself is unfair, so no
                    // expansion/shift is attempted on that basis; whatever
                    // has already been verified is finalized instead.
                    let nextActionKind = ETAVerificationDecision.nextActionKind(
                        isSparse: isSparse,
                        roundWasReliable: roundReliable,
                        canExpandRadius: canExpandRadius,
                        canShiftCorridor: canShiftCorridor
                    )
                    let nextAction: NextAction?
                    switch nextActionKind {
                    case .expandRadius:
                        nextAction = .expandRadius(reason: isSparse ? .sparsityRadiusExpansion : .unfairnessRadiusExpansion)
                    case .shiftCorridor:
                        nextAction = .shiftCorridor(reason: isSparse ? .sparsityCorridorShift : .unfairnessCorridorShift)
                    case .finalize:
                        nextAction = nil
                    }

                    #if DEBUG
                    let nextActionDescription: String
                    switch nextAction {
                    case .expandRadius(let r): nextActionDescription = "expandRadius(\(r.rawValue))"
                    case .shiftCorridor(let r): nextActionDescription = "shiftCorridor(\(r.rawValue))"
                    case nil: nextActionDescription = "finalize"
                    }
                    Self.logger.log("""
                    [S9][\(diagnostics?.searchID ?? "?")] round \(roundIndex) next-action decision: \
                    isSparse=\(isSparse) roundReliable=\(roundReliable) canExpandRadius=\(canExpandRadius) \
                    canShiftCorridor=\(canShiftCorridor) chosen=\(nextActionDescription)\
                    \(!isSparse && !roundReliable ? " (unfairness signal distrusted - not expanding/shifting on it)" : "")
                    """)
                    #endif

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
                            distanceCache: mergedDistanceCache,
                            verifiedSoFar: mergedVerified,
                            verifiedUnfairSoFar: mergedUnfair,
                            yelpOrderIndex: mergedYelpOrderIndex,
                            yelpEverReturnedResults: sawResults,
                            yelpEverSucceeded: true,
                            lastEvidenceRoundWasReliable: carriedReliability,
                            radiusExpansionsUsed: radiusExpansionsUsed + 1,
                            corridorShiftsUsed: corridorShiftsUsed,
                            searchedCenters: searchedCenters,
                            diagnostics: diagnostics,
                            cancellationToken: cancellationToken,
                            onProgress: onProgress,
                            completion: completion
                        )

                    case .shiftCorridor(let nextReason):
                        guard let corridor = corridor else {
                            self.finalize(
                                verifiedSoFar: mergedVerified,
                                verifiedUnfair: mergedUnfair,
                                etaCache: mergedCache,
                                distanceCache: mergedDistanceCache,
                                yelpOrderIndex: mergedYelpOrderIndex,
                                yelpEverReturnedResults: sawResults,
                                roundWasReliable: roundReliable,
                                diagnostics: diagnostics,
                                completion: completion
                            )
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
                            self.finalize(
                                verifiedSoFar: mergedVerified,
                                verifiedUnfair: mergedUnfair,
                                etaCache: mergedCache,
                                distanceCache: mergedDistanceCache,
                                yelpOrderIndex: mergedYelpOrderIndex,
                                yelpEverReturnedResults: sawResults,
                                roundWasReliable: roundReliable,
                                diagnostics: diagnostics,
                                completion: completion
                            )
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
                            distanceCache: mergedDistanceCache,
                            verifiedSoFar: mergedVerified,
                            verifiedUnfairSoFar: mergedUnfair,
                            yelpOrderIndex: mergedYelpOrderIndex,
                            yelpEverReturnedResults: sawResults,
                            yelpEverSucceeded: true,
                            lastEvidenceRoundWasReliable: carriedReliability,
                            radiusExpansionsUsed: radiusExpansionsUsed,
                            corridorShiftsUsed: corridorShiftsUsed + 1,
                            searchedCenters: searchedCenters + [(fraction: shift.fraction, coordinate: shift.coordinate)],
                            diagnostics: diagnostics,
                            cancellationToken: cancellationToken,
                            onProgress: onProgress,
                            completion: completion
                        )

                    case nil:
                        self.finalize(
                            verifiedSoFar: mergedVerified,
                            verifiedUnfair: mergedUnfair,
                            etaCache: mergedCache,
                            distanceCache: mergedDistanceCache,
                            yelpOrderIndex: mergedYelpOrderIndex,
                            yelpEverReturnedResults: sawResults,
                            roundWasReliable: roundReliable,
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
        verifiedUnfair: [Restaurant],
        etaCache: [String: (userETA: TimeInterval, friendETA: TimeInterval)],
        distanceCache: [String: (userDistance: Double, friendDistance: Double)],
        yelpOrderIndex: [String: Int],
        yelpEverReturnedResults: Bool,
        roundWasReliable: Bool,
        diagnostics: MidpointDiagnostics?,
        completion: @escaping (MeetingPlaceOutcome) -> Void
    ) {
        diagnostics?.finalRestaurantIDs = verifiedSoFar.map(\.id)

        // See ETAVerificationDecision.finalOutcomeCase's doc comment for the
        // full reasoning: a full success stands regardless of reliability;
        // below that, any already-accumulated usable restaurant (fair or
        // additional) is shown regardless of the ending round's reliability,
        // since a real ETA pair from an earlier reliable round stays
        // trustworthy even if a later round hits a MapKit outage.
        // `roundWasReliable` only gates the case where nothing usable has
        // been accumulated at all.
        let outcomeCase = ETAVerificationDecision.finalOutcomeCase(
            verifiedCount: verifiedSoFar.count,
            additionalVerifiedCount: verifiedUnfair.count,
            roundWasReliable: roundWasReliable,
            yelpEverReturnedResults: yelpEverReturnedResults
        )
        let outcome: MeetingPlaceOutcome
        switch outcomeCase {
        case .success:
            let displayRestaurants = ETAVerificationDecision.buildDisplayList(
                fair: verifiedSoFar,
                verifiedUnfair: verifiedUnfair,
                etaCache: etaCache,
                yelpOrderIndex: yelpOrderIndex,
                distanceCache: distanceCache
            )
            outcome = .success(restaurants: displayRestaurants)
        case .limitedFairOptions:
            let displayRestaurants = ETAVerificationDecision.buildDisplayList(
                fair: verifiedSoFar,
                verifiedUnfair: verifiedUnfair,
                etaCache: etaCache,
                yelpOrderIndex: yelpOrderIndex,
                distanceCache: distanceCache
            )
            outcome = .limitedFairOptions(restaurants: displayRestaurants)
        case .noFairRestaurants:
            outcome = .noFairRestaurants
        case .noRestaurantsNearby:
            outcome = .noRestaurantsNearby
        case .etaVerificationUnavailable:
            outcome = .etaVerificationUnavailable
        }

        #if DEBUG
        let outcomeCaseName: String
        switch outcome {
        case .success: outcomeCaseName = "success"
        case .limitedFairOptions: outcomeCaseName = "limitedFairOptions"
        case .noFairRestaurants: outcomeCaseName = "noFairRestaurants"
        case .noRestaurantsNearby: outcomeCaseName = "noRestaurantsNearby"
        case .searchFailed: outcomeCaseName = "searchFailed"
        case .etaVerificationUnavailable: outcomeCaseName = "etaVerificationUnavailable"
        }
        Self.logger.log("""
        [S9][\(diagnostics?.searchID ?? "?")] FINALIZE outcome=\(outcomeCaseName) roundWasReliable=\(roundWasReliable) \
        fairCount=\(verifiedSoFar.count) verifiedUnfairCount=\(verifiedUnfair.count) \
        finalRestaurantIDs=\(verifiedSoFar.map(\.id)) finalRestaurantNames=\(verifiedSoFar.map(\.name)) \
        finalCenter=\(String(describing: diagnostics?.selectedCenter)) \
        finalRadiusMeters=\(String(describing: diagnostics?.searchRadiusMeters)) \
        totalETARetries=\(diagnostics?.etaRetries.count ?? 0) totalMapKitRequests=\(diagnostics?.mapKitRequestCount ?? 0)
        """)
        #endif

        completion(outcome)
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
    //
    // Per-search, per-restaurant leg attempt-budget/concurrency bookkeeping
    // now lives in the standalone `LegSchedulerState` (pure Foundation, no
    // MapKit/CoreLocation dependency) so it can be exercised directly by
    // deterministic tests in `Scripts/decision_logic_tests.swift` without a
    // live MapKit call. See that file for full documentation.

    /// Verifies a shortlist by running one bounded, paced primary pass (see
    /// `runPass`) and, if anything is still pending a leg afterward,
    /// exactly ONE additional bounded recovery pass over just those
    /// restaurants after a longer backoff
    /// (`MidpointFairnessConfig.batchRecoveryDelaySeconds`). Every leg's
    /// total attempt count - across BOTH passes - is tracked by a single
    /// `LegSchedulerState` shared for the whole call, so a leg that already
    /// exhausted `maxAttemptsPerLeg` in the primary pass does not silently
    /// receive a fresh budget just by entering recovery, and a leg that
    /// already succeeded is never re-requested because its sibling leg is
    /// still pending.
    private func verifyBatched(
        _ restaurants: [Restaurant],
        userLocation: CLLocation,
        friendLocation: CLLocation,
        diagnostics: MidpointDiagnostics?,
        cancellationToken: SearchCancellationToken,
        onBatchProgress: @escaping ([String: (userETA: TimeInterval, friendETA: TimeInterval)], [String: (userDistance: Double, friendDistance: Double)]) -> Void,
        completion: @escaping ([String: (userETA: TimeInterval, friendETA: TimeInterval)], [String: (userDistance: Double, friendDistance: Double)], Int) -> Void
    ) {
        guard !restaurants.isEmpty else {
            completion([:], [:], 0)
            return
        }

        let state = LegSchedulerState(ids: restaurants.map(\.id))
        // Shared by both passes below (they share `state`), so a batch
        // completing in EITHER the primary or the one bounded recovery pass
        // reports the same cumulative "everything resolved so far" snapshot.
        let reportProgress = { onBatchProgress(state.verifiedResults(), state.verifiedDistances()) }

        runPass(restaurants, passName: "primary", state: state, userLocation: userLocation, friendLocation: friendLocation, diagnostics: diagnostics, cancellationToken: cancellationToken, onBatchProgress: reportProgress) {
            let pending = restaurants.filter { state.isPending($0.id) }
            guard !pending.isEmpty else {
                #if DEBUG
                Self.logger.log("""
                [S9][\(diagnostics?.searchID ?? "?")] verifyBatched: no recovery pass needed - \
                totalRequests=\(state.totalRequests) maxObservedConcurrency=\(state.maxObservedConcurrency)
                """)
                #endif
                completion(state.verifiedResults(), state.verifiedDistances(), state.totalRequests)
                return
            }

            #if DEBUG
            Self.logger.log("""
            [S9][\(diagnostics?.searchID ?? "?")] verifyBatched: \(pending.count) of \(restaurants.count) restaurants \
            still have a pending leg after the primary pass - scheduling ONE bounded recovery pass in \
            \(MidpointFairnessConfig.batchRecoveryDelaySeconds)s for ids=\(pending.map(\.id))
            """)
            #endif

            DispatchQueue.main.asyncAfter(deadline: .now() + MidpointFairnessConfig.batchRecoveryDelaySeconds) {
                self.runPass(pending, passName: "recovery", state: state, userLocation: userLocation, friendLocation: friendLocation, diagnostics: diagnostics, cancellationToken: cancellationToken, onBatchProgress: reportProgress) {
                    #if DEBUG
                    let recoveredCount = pending.filter { state.userLegPending($0.id) == false && state.friendLegPending($0.id) == false }.count
                    Self.logger.log("""
                    [S9][\(diagnostics?.searchID ?? "?")] verifyBatched: recovery pass finished - \
                    \(recoveredCount) of \(pending.count) previously-pending restaurants now have no pending leg \
                    (totalRequests=\(state.totalRequests), maxObservedConcurrency=\(state.maxObservedConcurrency))
                    """)
                    #endif
                    completion(state.verifiedResults(), state.verifiedDistances(), state.totalRequests)
                }
            }
        }
    }

    /// One bounded-concurrency, lightly-paced verification pass over
    /// `candidates`: split into `restaurantVerificationConcurrency`-sized
    /// batches (currently 1, i.e. one restaurant candidate verified at a
    /// time - see the CONTROLLED EXPERIMENT note on that constant), batches
    /// run sequentially with a fixed pause between them
    /// (`interCandidatePacingSeconds`). Each leg attempt consumes one slot
    /// of its restaurant's shared, cross-pass budget in `state` - a leg
    /// that's already succeeded, already exhausted its budget, or already
    /// failed non-transiently is skipped entirely.
    ///
    /// After every batch, checks whether this pass's own failure rate has
    /// already crossed the same bar used for the final round-reliability
    /// decision (`ETAVerificationDecision.shouldTripCircuitBreaker`). If it
    /// has, no further not-yet-started batches in this pass are dispatched
    /// - already in-flight requests are left to finish, but there is no
    /// point sending fresh requests into a MapKit outage this pass has
    /// already shown is unhealthy. This is what keeps a systemic failure
    /// bounded rather than working through the entire shortlist before
    /// giving up.
    private func runPass(
        _ candidates: [Restaurant],
        passName: String,
        state: LegSchedulerState,
        userLocation: CLLocation,
        friendLocation: CLLocation,
        diagnostics: MidpointDiagnostics?,
        cancellationToken: SearchCancellationToken,
        onBatchProgress: @escaping () -> Void,
        passCompletion: @escaping () -> Void
    ) {
        guard !candidates.isEmpty else {
            passCompletion()
            return
        }

        let batchSize = max(MidpointFairnessConfig.restaurantVerificationConcurrency, 1)
        let batches = stride(from: 0, to: candidates.count, by: batchSize).map {
            Array(candidates[$0..<min($0 + batchSize, candidates.count)])
        }
        let expectedMaxConcurrentRequests = batchSize * 2

        #if DEBUG
        Self.logger.log("""
        [S9][\(diagnostics?.searchID ?? "?")] \(passName) pass starting: \(candidates.count) candidate(s), \
        restaurantVerificationConcurrency=\(batchSize) (max \(expectedMaxConcurrentRequests) concurrent MKDirections calls), \
        interCandidatePacingSeconds=\(MidpointFairnessConfig.interCandidatePacingSeconds)
        """)
        #endif

        // Serializes this pass's own running failure-fraction counters,
        // which are otherwise mutated from inside `requestRoute` completion
        // closures - MKDirections.calculate does not guarantee those
        // land on any single thread, so two legs completing at the same
        // moment (even just the 2 legs of one candidate) could otherwise
        // race on these plain captured `var`s.
        let passCounterQueue = DispatchQueue(label: "com.letsmeet.runPass.\(passName)")
        var legsAttemptedThisPass = 0
        var legsFailedThisPass = 0
        var circuitTripped = false

        func runBatch(_ index: Int) {
            // Every batch start funnels through here: the first batch of the
            // primary pass, each batch resumed after the pacing delay, and
            // the first batch of the recovery pass once its backoff elapses.
            // Returning without `passCompletion()` ends the whole chain
            // silently - no later batch, no recovery pass, no round
            // continuation - and is not counted as a leg failure or a
            // circuit-breaker event. Already in-flight legs finish untouched.
            guard SearchCancellationGate.shouldContinue(cancellationToken) else { return }

            guard !circuitTripped, index < batches.count else {
                #if DEBUG
                if circuitTripped {
                    Self.logger.log("""
                    [S9][\(diagnostics?.searchID ?? "?")] \(passName) pass: circuit breaker tripped - skipping \
                    \(batches.count - index) of \(batches.count) remaining candidate(s)
                    """)
                }
                #endif
                passCompletion()
                return
            }

            let group = DispatchGroup()
            for restaurant in batches[index] {
                guard let coordinate = restaurant.coordinate else { continue }
                let destination = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
                let candidateNumber = index * batchSize + 1

                if state.userLegPending(restaurant.id) {
                    group.enter()
                    let (attemptNumber, inFlight) = state.beginUserAttempt(restaurant.id)
                    #if DEBUG
                    assert(
                        inFlight <= expectedMaxConcurrentRequests,
                        "restaurant ETA concurrency (\(inFlight)) exceeded the intended experimental maximum (\(expectedMaxConcurrentRequests))"
                    )
                    Self.logger.log("""
                    [S9][\(diagnostics?.searchID ?? "?")] \(passName) pass: candidate \(candidateNumber)/\(candidates.count) \
                    id=\(restaurant.id) name=\(restaurant.name) - user leg STARTED attempt \(attemptNumber) (inFlight=\(inFlight))
                    """)
                    #endif
                    requestRoute(from: userLocation, to: destination) { result in
                        let inFlightAfter = state.endAttempt()
                        passCounterQueue.sync { legsAttemptedThisPass += 1 }
                        switch result {
                        case .success(let route):
                            state.recordUserSuccess(restaurant.id, eta: route.eta, distance: route.distance)
                            #if DEBUG
                            Self.logger.log("""
                            [S9][\(diagnostics?.searchID ?? "?")] \(passName) pass: candidate \(candidateNumber)/\(candidates.count) \
                            id=\(restaurant.id) - user leg COMPLETED attempt \(attemptNumber) eta=\(route.eta)s \
                            distance=\(route.distance)m (inFlight=\(inFlightAfter))
                            """)
                            #endif
                        case .failure(let error):
                            passCounterQueue.sync { legsFailedThisPass += 1 }
                            let transient = Self.isTransientMapKitFailure(error)
                            state.recordUserFailure(restaurant.id, transient: transient)
                            self.recordLegFailureDiagnostics(
                                restaurantID: restaurant.id, side: .user, error: error, transient: transient,
                                attemptNumber: attemptNumber, budgetRemaining: state.userBudgetRemaining(restaurant.id),
                                passName: passName, diagnostics: diagnostics
                            )
                        }
                        group.leave()
                    }
                }

                if state.friendLegPending(restaurant.id) {
                    group.enter()
                    let (attemptNumber, inFlight) = state.beginFriendAttempt(restaurant.id)
                    #if DEBUG
                    assert(
                        inFlight <= expectedMaxConcurrentRequests,
                        "restaurant ETA concurrency (\(inFlight)) exceeded the intended experimental maximum (\(expectedMaxConcurrentRequests))"
                    )
                    Self.logger.log("""
                    [S9][\(diagnostics?.searchID ?? "?")] \(passName) pass: candidate \(candidateNumber)/\(candidates.count) \
                    id=\(restaurant.id) name=\(restaurant.name) - friend leg STARTED attempt \(attemptNumber) (inFlight=\(inFlight))
                    """)
                    #endif
                    requestRoute(from: friendLocation, to: destination) { result in
                        let inFlightAfter = state.endAttempt()
                        passCounterQueue.sync { legsAttemptedThisPass += 1 }
                        switch result {
                        case .success(let route):
                            state.recordFriendSuccess(restaurant.id, eta: route.eta, distance: route.distance)
                            #if DEBUG
                            Self.logger.log("""
                            [S9][\(diagnostics?.searchID ?? "?")] \(passName) pass: candidate \(candidateNumber)/\(candidates.count) \
                            id=\(restaurant.id) - friend leg COMPLETED attempt \(attemptNumber) eta=\(route.eta)s \
                            distance=\(route.distance)m (inFlight=\(inFlightAfter))
                            """)
                            #endif
                        case .failure(let error):
                            passCounterQueue.sync { legsFailedThisPass += 1 }
                            let transient = Self.isTransientMapKitFailure(error)
                            state.recordFriendFailure(restaurant.id, transient: transient)
                            self.recordLegFailureDiagnostics(
                                restaurantID: restaurant.id, side: .friend, error: error, transient: transient,
                                attemptNumber: attemptNumber, budgetRemaining: state.friendBudgetRemaining(restaurant.id),
                                passName: passName, diagnostics: diagnostics
                            )
                        }
                        group.leave()
                    }
                }
            }

            group.notify(queue: .main) {
                let (attempted, failed) = passCounterQueue.sync { (legsAttemptedThisPass, legsFailedThisPass) }
                if ETAVerificationDecision.shouldTripCircuitBreaker(legsAttempted: attempted, legsFailed: failed) {
                    circuitTripped = true
                    #if DEBUG
                    Self.logger.log("""
                    [S9][\(diagnostics?.searchID ?? "?")] \(passName) pass: circuit breaker TRIPPED after candidate(s) up to \
                    index \(index) - \(failed) of \(attempted) attempted legs have failed so far this pass
                    """)
                    #endif
                }

                onBatchProgress()

                guard index + 1 < batches.count, !circuitTripped else {
                    runBatch(index + 1)
                    return
                }
                // Deliberate pacing between candidates, on top of the
                // bounded concurrency within one - consecutive candidates
                // don't start back-to-back the instant the previous one's
                // last request lands.
                DispatchQueue.main.asyncAfter(deadline: .now() + MidpointFairnessConfig.interCandidatePacingSeconds) {
                    runBatch(index + 1)
                }
            }
        }

        runBatch(0)
    }

    /// Records one failed leg attempt to the appropriate S9 diagnostics
    /// list. A failure is "terminal" (recorded to `mapKitFailures`) when
    /// this leg will not get another attempt: it's already in the recovery
    /// pass (there is no third pass), it wasn't transient, or its shared
    /// budget is exhausted. Otherwise it's recorded to `etaRetries` as
    /// "deferred to the one bounded recovery pass" - preserves the existing
    /// distinction between a leg that eventually succeeds and one that
    /// truly never resolves.
    private func recordLegFailureDiagnostics(
        restaurantID: String,
        side: MapKitFailureRecord.Side,
        error: Error,
        transient: Bool,
        attemptNumber: Int,
        budgetRemaining: Bool,
        passName: String,
        diagnostics: MidpointDiagnostics?
    ) {
        let willGetAnotherChance = passName == "primary" && transient && budgetRemaining

        if willGetAnotherChance {
            let nsError = error as NSError
            diagnostics?.etaRetries.append(
                ETARetryDiagnostics(
                    restaurantID: restaurantID,
                    side: side,
                    retryAttemptNumber: attemptNumber,
                    delaySeconds: MidpointFairnessConfig.batchRecoveryDelaySeconds,
                    priorErrorDomain: nsError.domain,
                    priorErrorCode: nsError.code,
                    priorErrorDescription: error.localizedDescription
                )
            )
            #if DEBUG
            Self.logger.log("""
            [S9] \(side.rawValue) leg for restaurantID=\(restaurantID) failed transiently on the \(passName) pass \
            (attempt \(attemptNumber)) - deferred to the one bounded recovery pass: \(error)
            """)
            #endif
        } else {
            diagnostics?.mapKitFailures.append(
                MapKitFailureRecord(stage: .restaurantETA, side: side, restaurantID: restaurantID, error: error)
            )
            #if DEBUG
            Self.logger.log("""
            [S9] \(side.rawValue) leg for restaurantID=\(restaurantID) failed TERMINALLY on the \(passName) pass \
            (attempt \(attemptNumber), transient=\(transient), budgetRemaining=\(budgetRemaining)): \(error)
            """)
            #endif
        }
    }

    /// Whether an `MKDirections` failure is reasonable to treat as
    /// transient (a server/throttling hiccup) rather than a genuine,
    /// stable "no route exists" condition. Reproduced production
    /// diagnostics showed `MKErrorDomain` failures (observed as code 4,
    /// "Directions Not Available") hitting candidates that had
    /// successfully routed moments earlier in an adjacent search, for both
    /// legs and many different restaurants - strong evidence that any
    /// `MKErrorDomain` failure from this call is plausibly transient here,
    /// since every destination is a real, Yelp-geocoded business coordinate
    /// reachable by car within the search radius, not an inherently
    /// unroutable point. Retries are bounded (see
    /// `MidpointFairnessConfig.maxAttemptsPerLeg`), so retrying an occasional
    /// genuine failure costs at most one extra request rather than looping
    /// indefinitely.
    private static func isTransientMapKitFailure(_ error: Error) -> Bool {
        (error as NSError).domain == MKErrorDomain
    }

    /// Same two per-restaurant-leg MapKit requests the fairness pipeline has
    /// always made, now using `calculate()` instead of `calculateETA()` so
    /// the resulting `MKRoute` also carries `distance` - needed for the
    /// decision card's travel block - without any additional MKDirections
    /// request. `calculate()` is heavier per-request than `calculateETA()`
    /// since it also computes route geometry; request COUNT is unchanged.
    private func requestRoute(
        from origin: CLLocation,
        to destination: CLLocation,
        completion: @escaping (Result<(eta: TimeInterval, distance: Double), Error>) -> Void
    ) {
        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: MKPlacemark(coordinate: origin.coordinate))
        request.destination = MKMapItem(placemark: MKPlacemark(coordinate: destination.coordinate))
        request.transportType = .automobile

        MKDirections(request: request).calculate { response, error in
            #if DEBUG
            Self.logger.log("[S9] RestaurantFairnessSelector.requestRoute completion thread: isMainThread=\(Thread.isMainThread)")
            #endif
            if let route = response?.routes.first {
                completion(.success((eta: route.expectedTravelTime, distance: route.distance)))
            } else {
                completion(.failure(error ?? YelpManagerError.failedToUnwrapMidpoint))
            }
        }
    }
}
