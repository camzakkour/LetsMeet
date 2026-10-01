//
//  ETAVerificationDecision.swift
//  LetsMeet
//

import Foundation

/// Pure, value-only decision logic for the restaurant search round loop:
/// whether an ETA-verification round's evidence can be trusted, whether an
/// unfairness-driven expansion/shift is warranted, and what a search's
/// final outcome should be once no further rounds will run. Deliberately
/// has zero dependency on MapKit, CoreLocation, Yelp, or any live
/// network/service type - every input is a plain count or flag - so this
/// logic can be exercised directly by deterministic tests without live
/// MapKit calls. `RestaurantFairnessSelector` is the only production
/// caller; it supplies the real counts and consumes the results.
enum ETAVerificationDecision {

    enum NextActionKind: Equatable {
        case expandRadius
        case shiftCorridor
        case finalize
    }

    enum FinalOutcomeCase: Equatable {
        case success
        case limitedFairOptions
        case noFairRestaurants
        case noRestaurantsNearby
        case etaVerificationUnavailable
    }

    /// A round's ETA-verification sample is only trusted as evidence of
    /// genuine unfairness once at least `minReliableFraction` of its
    /// shortlist produced a full bidirectional ETA pair. An attempted count
    /// of 0 (every shortlisted candidate was already cached from an earlier
    /// round) has nothing new to distrust, so it's treated as reliable.
    static func isRoundReliable(
        etaAttemptedCount: Int,
        etaVerifiedCount: Int,
        minReliableFraction: Double = MidpointFairnessConfig.minReliableETAVerificationFraction
    ) -> Bool {
        guard etaAttemptedCount > 0 else { return true }
        return Double(etaVerifiedCount) / Double(etaAttemptedCount) >= minReliableFraction
    }

    /// Whether an ETA-verification pass should stop dispatching further,
    /// not-yet-started batches because the evidence gathered *so far this
    /// pass* already shows a broad/systemic failure rather than isolated
    /// blips. Deliberately reuses `minReliableFraction` - the same bar
    /// `isRoundReliable` uses for the final round decision - rather than a
    /// separate, newly-invented threshold: once more than half of the legs
    /// attempted so far have failed, continuing to dispatch fresh requests
    /// at the same rate is very unlikely to produce a reliable round, so
    /// it's better to stop burning requests, let in-flight ones finish, and
    /// fall back to the one bounded recovery pass instead. `legsAttempted`
    /// of 0 never trips (nothing to judge yet).
    static func shouldTripCircuitBreaker(
        legsAttempted: Int,
        legsFailed: Int,
        minReliableFraction: Double = MidpointFairnessConfig.minReliableETAVerificationFraction
    ) -> Bool {
        guard legsAttempted > 0 else { return false }
        let failureFraction = Double(legsFailed) / Double(legsAttempted)
        return failureFraction > (1 - minReliableFraction)
    }

    /// What a round should do next. Sparsity (few/no raw Yelp results) is
    /// driven purely by result count and is unaffected by ETA reliability -
    /// prefer shifting to a different spot over expanding around one with
    /// little nearby. Outside of sparsity, an unreliable round must not be
    /// read as evidence that the area itself is unfair, so no
    /// expansion/shift is attempted on that basis - `.finalize` reports
    /// whatever has already been verified instead.
    static func nextActionKind(
        isSparse: Bool,
        roundWasReliable: Bool,
        canExpandRadius: Bool,
        canShiftCorridor: Bool
    ) -> NextActionKind {
        if isSparse {
            if canShiftCorridor { return .shiftCorridor }
            if canExpandRadius { return .expandRadius }
            return .finalize
        } else if !roundWasReliable {
            return .finalize
        } else {
            if canExpandRadius { return .expandRadius }
            if canShiftCorridor { return .shiftCorridor }
            return .finalize
        }
    }

    /// What a search should finally report once no further rounds will run.
    /// `verifiedCount` is the *cumulative* fairness-verified restaurant
    /// count across all rounds so far; `additionalVerifiedCount` is the
    /// cumulative count of restaurants that were successfully ETA-verified
    /// but did NOT pass the fairness rule (never unverified restaurants);
    /// `roundWasReliable` is the reliability of the round that ended the
    /// search.
    ///
    /// A full success (>= `minViableRestaurants`) stands regardless of
    /// reliability - it's a positive claim about the restaurants that were
    /// genuinely verified fair, not a claim about how much of the candidate
    /// pool was checked.
    ///
    /// Below that count, any already-accumulated usable restaurant (fair or
    /// additional) is shown regardless of whether the round that ended the
    /// search was itself reliable: a restaurant that produced a real
    /// bidirectional ETA pair is trustworthy on its own terms, independent
    /// of how many of its siblings in a later round failed to verify. A
    /// later round's broad MapKit failure says nothing about restaurants an
    /// earlier, reliable round already confirmed, so it must never erase
    /// them - this is what lets a search keep the results an earlier round
    /// already found instead of discarding them because a subsequent,
    /// unnecessary round happened to hit a MapKit outage.
    ///
    /// `roundWasReliable` only gates the one case where NOTHING usable has
    /// been accumulated at all: with zero verified restaurants of either
    /// kind, an unreliable round means there is nothing trustworthy to
    /// report, so only that case returns `.etaVerificationUnavailable`
    /// rather than `.noFairRestaurants` - the other unknowns could easily
    /// contain fair (or at least usable) options that MapKit simply failed
    /// to verify, so it would be wrong to report "no fair restaurants exist
    /// here" when verification itself couldn't be trusted.
    ///
    /// `.limitedFairOptions` covers both a reliable round with fewer than
    /// `minViableRestaurants` fair restaurants, and any fair-and/or-
    /// additional accumulation that survives from an earlier round after a
    /// later one turns out unreliable. `.noFairRestaurants` is reserved for
    /// the narrower case where a reliable round produced literally zero
    /// usable restaurants - fair or not - despite Yelp having returned some.
    static func finalOutcomeCase(
        verifiedCount: Int,
        additionalVerifiedCount: Int,
        roundWasReliable: Bool,
        yelpEverReturnedResults: Bool,
        minViableRestaurants: Int = MidpointFairnessConfig.minViableRestaurants
    ) -> FinalOutcomeCase {
        if verifiedCount >= minViableRestaurants {
            return .success
        } else if verifiedCount > 0 || additionalVerifiedCount > 0 {
            return .limitedFairOptions
        } else if !roundWasReliable {
            return .etaVerificationUnavailable
        } else if yelpEverReturnedResults {
            return .noFairRestaurants
        } else {
            return .noRestaurantsNearby
        }
    }

    /// The count of distinct restaurants (by ID) across the fair and
    /// verified-additional accumulators. `fair` and `verifiedUnfair` are
    /// expected to already be disjoint by construction (see
    /// `RestaurantFairnessSelector`'s `mergedUnfair` accumulation, which
    /// explicitly excludes anything already present in `mergedVerified`),
    /// but this is computed via a `Set` rather than leaning on that
    /// invariant, so a caller gets a correct count even if a duplicate ID
    /// ever showed up across rounds.
    static func uniqueDisplayableCount(fair: [Restaurant], verifiedUnfair: [Restaurant]) -> Int {
        Set(fair.map(\.id)).union(verifiedUnfair.map(\.id)).count
    }

    /// Whether the round loop should stop performing further radius-
    /// expansion/corridor-shift rounds because the accumulated search
    /// already has enough usable evidence to display - independent of
    /// whether that evidence is a full set of strictly-fair restaurants or a
    /// mix of fair and verified-additional ones.
    ///
    /// The round loop used to continue purely on
    /// `verifiedCount < minViableRestaurants`, which meant a search that had
    /// already accumulated, say, 1 fair + 9 verified-additional restaurants
    /// (10 genuinely displayable results) would still launch another round
    /// chasing a 3rd strictly-fair restaurant it didn't need - and if that
    /// unnecessary round then hit a broad MapKit failure, the whole search
    /// paid for it (see `finalOutcomeCase`'s doc comment for the other half
    /// of that fix). Basing the second half of this check on
    /// `uniqueDisplayableCount` rather than raw accumulator counts means
    /// duplicate IDs across rounds can never falsely trigger an early stop,
    /// and since `uniqueDisplayableCount` only ever counts restaurants that
    /// reached `fair`/`verifiedUnfair` (i.e. produced a real ETA pair), an
    /// unverified candidate can never count toward the total either.
    static func shouldStopRounds(
        verifiedCount: Int,
        uniqueDisplayableCount: Int,
        minViableRestaurants: Int = MidpointFairnessConfig.minViableRestaurants,
        maxDisplayedRestaurants: Int = MidpointFairnessConfig.maxDisplayedRestaurants
    ) -> Bool {
        verifiedCount >= minViableRestaurants || uniqueDisplayableCount >= maxDisplayedRestaurants
    }

    // MARK: - Displayed-result assembly (Part 2: up to 10 useful results)

    /// How far a verified-but-unfair restaurant's ETA delta is beyond the
    /// fairness tolerance it would have needed to pass - the same math
    /// `RestaurantFairnessSelector.isFair` uses to decide fair/unfair, just
    /// kept as a continuous distance instead of a boolean so "additional
    /// options" can be ranked by closeness to fair rather than treated as an
    /// undifferentiated group. A restaurant missing from `cache` (should
    /// never happen for anything that reached verified-unfair status) sorts
    /// last rather than crashing.
    static func fairnessExcess(
        _ restaurant: Restaurant,
        cache: [String: (userETA: TimeInterval, friendETA: TimeInterval)]
    ) -> TimeInterval {
        guard let comparison = cache[restaurant.id] else { return .greatestFiniteMagnitude }
        let tolerance = MidpointFairnessConfig.fairnessTolerance(forLongerETA: max(comparison.userETA, comparison.friendETA))
        return abs(comparison.userETA - comparison.friendETA) - tolerance
    }

    /// Orders successfully-ETA-verified-but-unfair restaurants by closeness
    /// to passing the fairness rule (ascending `fairnessExcess` - the
    /// existing fairness math, not a new score), with Yelp's own best-match
    /// relevance order (`yelpOrderIndex`, lower = more relevant) as a
    /// deterministic secondary tie-break.
    static func rankAdditionalOptions(
        verifiedUnfair: [Restaurant],
        etaCache: [String: (userETA: TimeInterval, friendETA: TimeInterval)],
        yelpOrderIndex: [String: Int]
    ) -> [Restaurant] {
        verifiedUnfair.sorted { a, b in
            let excessA = fairnessExcess(a, cache: etaCache)
            let excessB = fairnessExcess(b, cache: etaCache)
            if excessA != excessB { return excessA < excessB }
            return (yelpOrderIndex[a.id] ?? Int.max) < (yelpOrderIndex[b.id] ?? Int.max)
        }
    }

    /// Assembles the final displayed restaurant list for `.success`/
    /// `.limitedFairOptions`: fairness-verified restaurants always fill the
    /// first `maxDisplayed` slots (marked `.fair`); any remaining slots are
    /// filled with successfully-ETA-verified-but-unfair restaurants (marked
    /// `.verifiedAdditional`), ranked by `rankAdditionalOptions`. Never pads
    /// with unverified restaurants - `verifiedUnfair` must only ever contain
    /// restaurants that produced a real bidirectional ETA pair.
    static func buildDisplayList(
        fair: [Restaurant],
        verifiedUnfair: [Restaurant],
        etaCache: [String: (userETA: TimeInterval, friendETA: TimeInterval)],
        yelpOrderIndex: [String: Int],
        maxDisplayed: Int = MidpointFairnessConfig.maxDisplayedRestaurants,
        distanceCache: [String: (userDistance: Double, friendDistance: Double)] = [:]
    ) -> [Restaurant] {
        var cappedFair = Array(fair.prefix(maxDisplayed))
        for index in cappedFair.indices {
            cappedFair[index].fairnessDisplayStatus = .fair
            cappedFair[index].travelInfo = travelInfo(for: cappedFair[index], etaCache: etaCache, distanceCache: distanceCache)
        }

        let remainingSlots = max(0, maxDisplayed - cappedFair.count)
        guard remainingSlots > 0 else { return cappedFair }

        let ranked = rankAdditionalOptions(verifiedUnfair: verifiedUnfair, etaCache: etaCache, yelpOrderIndex: yelpOrderIndex)
        var additionalFill = Array(ranked.prefix(remainingSlots))
        for index in additionalFill.indices {
            additionalFill[index].fairnessDisplayStatus = .verifiedAdditional
            additionalFill[index].travelInfo = travelInfo(for: additionalFill[index], etaCache: etaCache, distanceCache: distanceCache)
        }

        return cappedFair + additionalFill
    }

    /// Assembles a restaurant's display-only travel info from the ETA/
    /// distance values already gathered during fairness verification. Nil
    /// when no cached ETA pair exists, or when a distance never resolved for
    /// one of the two legs (the restaurant still displays - only the travel
    /// block is omitted).
    private static func travelInfo(
        for restaurant: Restaurant,
        etaCache: [String: (userETA: TimeInterval, friendETA: TimeInterval)],
        distanceCache: [String: (userDistance: Double, friendDistance: Double)]
    ) -> Restaurant.TravelInfo? {
        guard let etas = etaCache[restaurant.id], let distances = distanceCache[restaurant.id] else { return nil }
        return Restaurant.TravelInfo(
            userETA: etas.userETA,
            userDistanceMeters: distances.userDistance,
            friendETA: etas.friendETA,
            friendDistanceMeters: distances.friendDistance
        )
    }
}
