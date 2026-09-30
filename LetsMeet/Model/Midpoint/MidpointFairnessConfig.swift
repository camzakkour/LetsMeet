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

    /// Number of restaurant candidates verified concurrently during
    /// restaurant ETA verification. Each candidate consumes up to 2
    /// simultaneous `MKDirections` calls (user leg + friend leg), so the
    /// real concurrent-request ceiling is `restaurantVerificationConcurrency
    /// * 2`.
    ///
    /// Restored to 3 candidates (6 concurrent calls) after a controlled
    /// low-concurrency experiment (1 candidate/2 concurrent calls) and a
    /// separate quiet-interval recovery experiment both showed that the
    /// intermittent, broad `MKErrorDomain` code 4 "Directions Not Available"
    /// failure bursts observed in production are not caused or prevented by
    /// request concurrency: the same broad-failure signature recurred at
    /// concurrency 1, and recovered after a quiet interval with no
    /// concurrency change at all. Running verification one candidate at a
    /// time only added user-visible search latency without measurably
    /// improving reliability, so this reverts to the pre-experiment
    /// production value. (5 candidates/10 concurrent calls, tried earlier
    /// still, reliably triggered failures under load and was reduced from
    /// for the same reason.)
    static let restaurantVerificationConcurrency: Int = 3

    /// The total number of attempts a single ETA leg (user->candidate or
    /// friend->candidate) may consume across an ENTIRE search - the primary
    /// verification pass and the one bounded recovery pass in
    /// `verifyBatched` combined. This is a single, shared, cross-pass budget
    /// by design: a leg that already spent an attempt in the primary pass
    /// and failed transiently gets exactly one more attempt, in recovery -
    /// never a fresh, independently-reset budget just for entering
    /// recovery. (Previously the primary pass had its own internal retry on
    /// top of a *separate* recovery-pass retry, which could give a single
    /// leg up to 4 total attempts and was the actual cause of a ~71-request
    /// failed search versus a ~23-request healthy one for the same
    /// 10-restaurant shortlist - see `RestaurantFairnessSelector`'s
    /// `LegSchedulerState`.)
    static let maxAttemptsPerLeg: Int = 2

    /// Fixed pause inserted between consecutive restaurant-verification
    /// batches (on top of the bounded `restaurantVerificationConcurrency`
    /// ceiling within a single batch), so verification doesn't fire the next
    /// batch the instant the previous one's last request lands. This is the
    /// "deliberate pacing" complement to bounded concurrency - it spreads a
    /// shortlist's total request volume out over time rather than only
    /// capping how many requests are in flight at once. Unchanged from its
    /// value throughout the concurrency experiment above: with
    /// `restaurantVerificationConcurrency` restored to 3, this is once again
    /// an inter-BATCH pause (roughly once per 3 restaurants) rather than the
    /// inter-CANDIDATE pause it became at concurrency 1.
    static let interCandidatePacingSeconds: Double = 0.3

    /// After a full primary verification pass still leaves some legs
    /// pending (see `maxAttemptsPerLeg`), exactly ONE additional batch-level
    /// recovery pass is attempted over just those restaurants, after this
    /// longer backoff. A longer pause than the primary pass's own
    /// inter-batch pacing gives a broader/correlated MapKit failure window
    /// more of a chance to clear before the leg's final attempt. Bounded to
    /// a single pass (never recursive) so a systemic outage still
    /// terminates in a fixed, small number of requests rather than
    /// retrying forever.
    static let batchRecoveryDelaySeconds: Double = 1.5

    /// A search round's ETA-verification sample is only trusted as evidence
    /// of genuine unfairness when at least this fraction of its shortlist
    /// produced a full bidirectional ETA pair (after retries). Below this
    /// fraction, failed ETA requests - not real unfairness - are assumed to
    /// explain a low pass count, so the round must not trigger an
    /// unfairness-driven radius expansion or corridor shift.
    static let minReliableETAVerificationFraction: Double = 0.5

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

    /// Maximum number of restaurants ever attached to a `.success` or
    /// `.limitedFairOptions` outcome for display. Deliberately a distinct
    /// constant from `restaurantShortlistSize`, even though both are
    /// currently 10 - one bounds how many candidates are sent to ETA
    /// verification per round, the other bounds how many already-verified
    /// results are shown to the user across all rounds combined. Fairness-
    /// verified restaurants always fill these slots first; any remaining
    /// slots are filled with successfully-ETA-verified-but-unfair
    /// restaurants, ranked by closeness to passing the fairness rule. Never
    /// filled with unverified restaurants.
    static let maxDisplayedRestaurants: Int = 10
}
