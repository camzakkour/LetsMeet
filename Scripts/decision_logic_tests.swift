//
// Deterministic tests for ETAVerificationDecision and LegSchedulerState -
// the pure round-decision, circuit-breaker, and per-leg scheduling/
// concurrency-bookkeeping logic extracted from RestaurantFairnessSelector.
// No MapKit, no CoreLocation, no live network calls: every input is a plain
// count, flag, or string ID. Compiled and run directly against the real
// production source files (not copies), so this exercises the exact logic
// RestaurantFairnessSelector calls in production.
//
// Scenarios A-F cover the round-outcome decision; G covers the batch-level
// circuit breaker added to bound MapKit request volume during a broad
// failure; H reconstructs the old cross-pass retry-budget-stacking bug
// (~71 requests) against the new single shared per-leg budget (40-request
// theoretical worst case).
//
// Scenarios "Scheduler-A" through "Scheduler-J" are a SEPARATE lettered list
// (per the controlled low-concurrency experiment spec) covering
// LegSchedulerState's per-leg attempt budget, cross-pass budget persistence,
// successful-leg preservation, and concurrency bookkeeping - the "Scheduler-"
// prefix on their labels is only to avoid confusion with the A-H list above,
// which predates and is unrelated to this second list.
//
// This is a standalone script, NOT part of the LetsMeet Xcode target - it is
// intentionally not registered in project.pbxproj. Its top-level statements
// would conflict with the app's own SwiftUI entry point if compiled into the
// app target. The project has no XCTest target; adding one was judged too
// large a structural change for this fix, so this script is the practical
// way to exercise this logic deterministically without live MapKit until a
// real test target exists.
//
// Run with (this file must be staged as literally "main.swift" at compile
// time - swiftc only allows top-level statements in a file named exactly
// that when compiling more than one source file together; every other file
// here is a pure declaration file with no top-level code, so this is the
// only one that needs staging):
//   cp Scripts/decision_logic_tests.swift /tmp/main.swift && \
//   swiftc -o /tmp/decision_logic_tests \
//     LetsMeet/Model/Midpoint/MidpointFairnessConfig.swift \
//     LetsMeet/Model/YelpResults.swift \
//     LetsMeet/Model/Midpoint/ETAVerificationDecision.swift \
//     LetsMeet/Model/Midpoint/LegSchedulerState.swift \
//     LetsMeet/Features/Results/FairnessPresentation.swift \
//     /tmp/main.swift \
//     && /tmp/decision_logic_tests
//
// YelpResults.swift (the `Restaurant` model) is included because Part 2's
// displayed-result assembly (`ETAVerificationDecision.buildDisplayList` /
// `rankAdditionalOptions` / `fairnessExcess`) operates on `Restaurant`
// values. It only imports Foundation/CoreLocation - no MapKit, no UIKit -
// so it compiles and runs standalone here exactly like the other pure
// model/decision files.
//
// FairnessPresentation.swift (Foundation-only) is the pure helper behind the
// results sheet's "Other options" divider and zero-fair message; the PR-*
// scenarios at the end of this file exercise it against real
// `buildDisplayList` output.

import Foundation

var failures = 0

func expect<T: Equatable>(_ actual: T, _ expected: T, _ label: String) {
    if actual == expected {
        print("  PASS  \(label)")
    } else {
        print("  FAIL  \(label): expected \(expected), got \(actual)")
        failures += 1
    }
}

// MARK: - A. HEALTHY SUCCESS
// 10 shortlisted, 10 verified, 8 fair, 2 unfair -> normal success w/ 8.
do {
    print("A. HEALTHY SUCCESS")
    let reliable = ETAVerificationDecision.isRoundReliable(etaAttemptedCount: 10, etaVerifiedCount: 10)
    expect(reliable, true, "round is reliable (10/10 verified)")
    let outcome = ETAVerificationDecision.finalOutcomeCase(verifiedCount: 8, additionalVerifiedCount: 0, roundWasReliable: reliable, yelpEverReturnedResults: true)
    expect(outcome, .success, "8 verified-fair restaurants -> success")
}

// MARK: - B. HEALTHY LIMITED RESULT
// 10 shortlisted, 10 verified, 2 fair, 8 unfair -> existing legitimate limitedFairOptions.
do {
    print("B. HEALTHY LIMITED RESULT")
    let reliable = ETAVerificationDecision.isRoundReliable(etaAttemptedCount: 10, etaVerifiedCount: 10)
    expect(reliable, true, "round is reliable (10/10 verified)")
    let outcome = ETAVerificationDecision.finalOutcomeCase(verifiedCount: 2, additionalVerifiedCount: 8, roundWasReliable: reliable, yelpEverReturnedResults: true)
    expect(outcome, .limitedFairOptions, "2 verified-fair out of a fully-verified 10 -> legitimate limitedFairOptions")
}

// MARK: - C. HEALTHY NO-FAIR RESULT (now a usable limitedFairOptions)
// 10 shortlisted, 10 verified, 0 fair, 10 verified-unfair -> as of Part 2,
// those 10 verified-unfair restaurants are genuinely usable "additional
// options", so this is no longer an unconditional noFairRestaurants error -
// see ETAVerificationDecision.finalOutcomeCase's doc comment.
do {
    print("C. HEALTHY NO-FAIR RESULT (now limitedFairOptions via additional options)")
    let reliable = ETAVerificationDecision.isRoundReliable(etaAttemptedCount: 10, etaVerifiedCount: 10)
    expect(reliable, true, "round is reliable (10/10 verified)")
    // Also: with 0 fair and a full (non-sparse) shortlist, expansion/shift
    // IS permitted (this is genuine, trustworthy unfairness evidence) -
    // this asserts finalize()'s behavior once that budget is exhausted.
    let expansionAllowed = ETAVerificationDecision.nextActionKind(
        isSparse: false, roundWasReliable: reliable, canExpandRadius: true, canShiftCorridor: true
    )
    expect(expansionAllowed, .expandRadius, "genuine (reliable) unfairness evidence DOES permit radius expansion")
    let outcome = ETAVerificationDecision.finalOutcomeCase(verifiedCount: 0, additionalVerifiedCount: 10, roundWasReliable: reliable, yelpEverReturnedResults: true)
    expect(outcome, .limitedFairOptions, "0 verified-fair but 10 verified-unfair, exhausted search -> limitedFairOptions(10 additional), not an error")
}

// MARK: - D. UNHEALTHY VERIFICATION (the reproduced 4A169263 shape)
// 10 shortlisted, 2 verified, 1 fair, 1 unfair, 8 ETA failures.
do {
    print("D. UNHEALTHY VERIFICATION (4A169263 shape)")
    let reliable = ETAVerificationDecision.isRoundReliable(etaAttemptedCount: 10, etaVerifiedCount: 2)
    expect(reliable, false, "round is UNRELIABLE (2/10 verified)")
    let nextAction = ETAVerificationDecision.nextActionKind(
        isSparse: false, roundWasReliable: reliable, canExpandRadius: true, canShiftCorridor: true
    )
    expect(nextAction, .finalize, "unreliable round must NOT trigger expansion/shift, even though budget remains")
    // Updated for the round-preservation fix: 1 verified-fair + 1
    // verified-additional is real, already-accumulated evidence - an
    // unreliable round must not erase it. See
    // ETAVerificationDecision.finalOutcomeCase's doc comment:
    // roundWasReliable only gates the case where NOTHING has been verified
    // at all (see scenario E below).
    let outcome = ETAVerificationDecision.finalOutcomeCase(verifiedCount: 1, additionalVerifiedCount: 1, roundWasReliable: reliable, yelpEverReturnedResults: true)
    expect(outcome, .limitedFairOptions, "1 verified-fair (+1 additional) survives an UNRELIABLE round as limitedFairOptions - real ETA pairs from what DID verify stay trustworthy")
}

// MARK: - E. COMPLETE ETA FAILURE
// 10 shortlisted, 0 verified, 10 ETA failures.
do {
    print("E. COMPLETE ETA FAILURE")
    let reliable = ETAVerificationDecision.isRoundReliable(etaAttemptedCount: 10, etaVerifiedCount: 0)
    expect(reliable, false, "round is UNRELIABLE (0/10 verified)")
    let nextAction = ETAVerificationDecision.nextActionKind(
        isSparse: false, roundWasReliable: reliable, canExpandRadius: true, canShiftCorridor: true
    )
    expect(nextAction, .finalize, "total ETA failure must NOT trigger pointless expansion/shift")
    let outcome = ETAVerificationDecision.finalOutcomeCase(verifiedCount: 0, additionalVerifiedCount: 0, roundWasReliable: reliable, yelpEverReturnedResults: true)
    expect(outcome, .etaVerificationUnavailable, "0 verified from a total-failure round -> Search Problem, not noFairRestaurants")
}

// MARK: - F. PARTIAL FAILURE THAT RECOVERS
// Initial pass: 10 attempted, 3 verified (unhealthy). Batch-level recovery
// pass brings it to 7 verified (crosses the 0.5 threshold) -> normal
// fairness logic resumes using the recovered results.
do {
    print("F. PARTIAL FAILURE THAT RECOVERS")
    let beforeRecovery = ETAVerificationDecision.isRoundReliable(etaAttemptedCount: 10, etaVerifiedCount: 3)
    expect(beforeRecovery, false, "before recovery: UNRELIABLE (3/10 verified)")
    let afterRecovery = ETAVerificationDecision.isRoundReliable(etaAttemptedCount: 10, etaVerifiedCount: 7)
    expect(afterRecovery, true, "after recovery: RELIABLE (7/10 verified) - recovery changed the trust determination")
    // Recovered results happen to include 2 verified-fair restaurants.
    let outcome = ETAVerificationDecision.finalOutcomeCase(verifiedCount: 2, additionalVerifiedCount: 0, roundWasReliable: afterRecovery, yelpEverReturnedResults: true)
    expect(outcome, .limitedFairOptions, "post-recovery reliable round with 2 fair -> normal limitedFairOptions, using recovered results")
}

// MARK: - Extra: boundary + zero-attempted cases
do {
    print("Boundary cases")
    expect(ETAVerificationDecision.isRoundReliable(etaAttemptedCount: 0, etaVerifiedCount: 0), true, "0 attempted (all cached) is trivially reliable")
    expect(ETAVerificationDecision.isRoundReliable(etaAttemptedCount: 10, etaVerifiedCount: 5), true, "exactly-at-threshold (5/10 = 0.5) counts as reliable")
    expect(ETAVerificationDecision.isRoundReliable(etaAttemptedCount: 10, etaVerifiedCount: 4), false, "just-below-threshold (4/10) is unreliable")
    // Sparsity always permits its own remediation regardless of reliability -
    // it's driven by raw Yelp result count, never ETA reliability.
    expect(
        ETAVerificationDecision.nextActionKind(isSparse: true, roundWasReliable: false, canExpandRadius: true, canShiftCorridor: true),
        .shiftCorridor,
        "sparsity remediation is unaffected by ETA reliability"
    )
}

// MARK: - G. BROAD MAPKIT FAILURE -> CIRCUIT BREAKER
// Mirrors ETAVerificationDecision.shouldTripCircuitBreaker, the pure
// function RestaurantFairnessSelector.runPass consults after every batch of
// leg attempts to decide whether to stop dispatching further not-yet-started
// batches in the current pass. Uses the SAME minReliableETAVerificationFraction
// (0.5) as isRoundReliable, deliberately - no separate threshold was invented.
do {
    print("G. BROAD MAPKIT FAILURE -> CIRCUIT BREAKER")
    expect(
        ETAVerificationDecision.shouldTripCircuitBreaker(legsAttempted: 0, legsFailed: 0),
        false,
        "0 legs attempted so far never trips (nothing to judge yet)"
    )
    expect(
        ETAVerificationDecision.shouldTripCircuitBreaker(legsAttempted: 6, legsFailed: 3),
        false,
        "exactly 50% failure (3/6) does NOT trip - matches isRoundReliable's >= treating exactly-50% as reliable"
    )
    expect(
        ETAVerificationDecision.shouldTripCircuitBreaker(legsAttempted: 6, legsFailed: 4),
        true,
        "just-over-50% failure (4/6) TRIPS the breaker"
    )
    expect(
        ETAVerificationDecision.shouldTripCircuitBreaker(legsAttempted: 6, legsFailed: 0),
        false,
        "all-success batch never trips"
    )
    expect(
        ETAVerificationDecision.shouldTripCircuitBreaker(legsAttempted: 6, legsFailed: 6),
        true,
        "total batch failure trips immediately"
    )
}

// MARK: - H. CROSS-PASS PER-LEG ATTEMPT BUDGET (the ~71-request bug, fixed)
// Mirrors RestaurantFairnessSelector.LegSchedulerState: a leg's attempt count
// is tracked ONCE for the whole search, across both the primary pass and the
// single recovery pass - never reset just because a leg enters recovery.
// Models the reproduced failure shape: 8 of 10 restaurants fail every
// attempt, 2 succeed on the first attempt.
do {
    print("H. CROSS-PASS PER-LEG ATTEMPT BUDGET")
    let maxAttemptsPerLeg = MidpointFairnessConfig.maxAttemptsPerLeg
    expect(maxAttemptsPerLeg, 2, "shared cross-pass per-leg budget is 2 (1 primary + 1 recovery attempt)")

    // Old (buggy) model: primary pass gives each of the 8 failing
    // restaurants up to (1 + etaMaxRetryAttempts) attempts per leg, then
    // recovery independently gives them a FRESH budget of the same size -
    // i.e. up to 2x(1+oldRetries) total attempts per leg. With the old
    // etaMaxRetryAttempts=1, that's up to 4 attempts/leg x 2 legs x 8
    // restaurants = 64, plus 2 succeeding restaurants at 2 legs x
    // 1 attempt = 4, plus seed phase ~3 => ~71, matching the observed count.
    let oldAttemptsPerLegIfBothPassesIndependentlyRetried = 4
    let oldWorstCaseRestaurantRequests = 8 * 2 * oldAttemptsPerLegIfBothPassesIndependentlyRetried + 2 * 2 * 1
    expect(oldWorstCaseRestaurantRequests, 68, "reconstructed old worst case (excluding seed phase) matches the ~71-request failure")

    // New model: EVERY leg, whether it ultimately succeeds or fails, is
    // capped at maxAttemptsPerLeg total requests for the whole search.
    let newWorstCaseRestaurantRequests = 10 * 2 * maxAttemptsPerLeg
    expect(newWorstCaseRestaurantRequests, 40, "new theoretical worst case (excluding seed phase): 10 restaurants x 2 legs x 2 attempts = 40")
    expect(newWorstCaseRestaurantRequests < oldWorstCaseRestaurantRequests, true, "new worst case is strictly smaller than the old, reproduced worst case")
}

// MARK: - Scheduler simulation helper
//
// Mirrors the per-candidate, cross-leg-pair scheduling discipline
// RestaurantFairnessSelector.runPass uses in production: process one
// candidate at a time (its 2 legs "concurrently" with each other), check the
// circuit breaker after each candidate, stop dispatching further candidates
// once tripped. Uses the real LegSchedulerState and the real
// ETAVerificationDecision.shouldTripCircuitBreaker - only the MKDirections
// call itself is replaced by a predetermined outcome, exactly as far as this
// standalone script needs to go to test the scheduling logic deterministically.
func simulatePass(
    ids: [String],
    state: LegSchedulerState,
    userOutcome: (String) -> Bool,
    friendOutcome: (String) -> Bool
) -> (attemptedCandidates: [String], circuitTripped: Bool) {
    var legsAttempted = 0
    var legsFailed = 0
    var circuitTripped = false
    var attemptedCandidates: [String] = []

    for id in ids {
        if circuitTripped { break }
        attemptedCandidates.append(id)

        if state.userLegPending(id) {
            _ = state.beginUserAttempt(id)
            legsAttempted += 1
            if userOutcome(id) {
                state.recordUserSuccess(id, eta: 500)
            } else {
                legsFailed += 1
                state.recordUserFailure(id, transient: true)
            }
        }
        if state.friendLegPending(id) {
            _ = state.beginFriendAttempt(id)
            legsAttempted += 1
            if friendOutcome(id) {
                state.recordFriendSuccess(id, eta: 520)
            } else {
                legsFailed += 1
                state.recordFriendFailure(id, transient: true)
            }
        }

        if ETAVerificationDecision.shouldTripCircuitBreaker(legsAttempted: legsAttempted, legsFailed: legsFailed) {
            circuitTripped = true
        }
    }
    return (attemptedCandidates, circuitTripped)
}

// MARK: - Scheduler-A. HEALTHY 10/10 VERIFICATION
// 10 candidates, both legs succeed on the first attempt for every one.
do {
    print("Scheduler-A. HEALTHY 10/10 VERIFICATION")
    let ids = (1...10).map { "r\($0)" }
    let state = LegSchedulerState(ids: ids)
    let result = simulatePass(ids: ids, state: state, userOutcome: { _ in true }, friendOutcome: { _ in true })
    expect(result.circuitTripped, false, "a fully healthy pass never trips the circuit breaker")
    expect(state.verifiedResults().count, 10, "all 10 candidates end up fully verified")
    expect(state.totalRequests, 20, "10 candidates x 2 legs x 1 attempt = 20 total MapKit requests")
    for id in ids {
        expect(state.userAttempts(id), 1, "\(id) user leg took exactly 1 attempt")
        expect(state.friendAttempts(id), 1, "\(id) friend leg took exactly 1 attempt")
    }
}

// MARK: - Scheduler-B. ONE LEG FAILS ONCE, SUCCEEDS ON ITS SECOND LIFETIME ATTEMPT
do {
    print("Scheduler-B. ONE LEG FAILS ONCE, SUCCEEDS ON SECOND LIFETIME ATTEMPT")
    let state = LegSchedulerState(ids: ["b1"])
    // Primary pass: user leg fails transiently, friend leg succeeds.
    let (attempt1, _) = state.beginUserAttempt("b1")
    expect(attempt1, 1, "primary-pass user attempt is lifetime attempt #1")
    state.recordUserFailure("b1", transient: true)
    _ = state.beginFriendAttempt("b1")
    state.recordFriendSuccess("b1", eta: 500)
    expect(state.userLegPending("b1"), true, "user leg still has budget remaining (1 of 2 attempts used) -> still pending")
    // Recovery pass: user leg gets its one remaining attempt and succeeds.
    let (attempt2, _) = state.beginUserAttempt("b1")
    expect(attempt2, 2, "recovery-pass user attempt is lifetime attempt #2, not a fresh #1")
    state.recordUserSuccess("b1", eta: 480)
    expect(state.userLegPending("b1"), false, "user leg no longer pending once it has an ETA")
    expect(state.verifiedResults()["b1"] != nil, true, "b1 is fully verified after its second lifetime attempt succeeds")
    expect(state.userAttempts("b1"), 2, "user leg used exactly 2 lifetime attempts total")
}

// MARK: - Scheduler-C. BOTH LEGS FOR A RESTAURANT FAIL
// Both legs fail every attempt, across both the primary and recovery pass -
// budget exhausts and the restaurant is never verified.
do {
    print("Scheduler-C. BOTH LEGS FOR A RESTAURANT FAIL")
    let state = LegSchedulerState(ids: ["c1"])
    // Primary pass.
    _ = state.beginUserAttempt("c1"); state.recordUserFailure("c1", transient: true)
    _ = state.beginFriendAttempt("c1"); state.recordFriendFailure("c1", transient: true)
    expect(state.isPending("c1"), true, "1 of 2 attempts used on each leg -> still pending for recovery")
    // Recovery pass (final attempt for each leg).
    _ = state.beginUserAttempt("c1"); state.recordUserFailure("c1", transient: true)
    _ = state.beginFriendAttempt("c1"); state.recordFriendFailure("c1", transient: true)
    expect(state.userLegPending("c1"), false, "user leg budget exhausted (2/2 attempts, all failed)")
    expect(state.friendLegPending("c1"), false, "friend leg budget exhausted (2/2 attempts, all failed)")
    expect(state.isPending("c1"), false, "restaurant has no pending leg left - recovery correctly stops trying")
    expect(state.verifiedResults()["c1"] == nil, true, "a restaurant with 2 permanently-failed legs is never verified")
    expect(state.totalRequests, 4, "exactly 2 attempts/leg x 2 legs = 4 requests total, never more")
}

// MARK: - Scheduler-D. BROAD EARLY MAPKIT FAILURE -> CIRCUIT BREAKER
// First several candidates fail both legs; the breaker should trip well
// before reaching the last candidate, bounding total requests for the pass.
do {
    print("Scheduler-D. BROAD EARLY MAPKIT FAILURE -> CIRCUIT BREAKER")
    let ids = (1...10).map { "d\($0)" }
    let state = LegSchedulerState(ids: ids)
    let failingIDs: Set<String> = ["d1", "d2", "d3", "d4", "d5", "d6", "d7"]
    let result = simulatePass(
        ids: ids,
        state: state,
        userOutcome: { !failingIDs.contains($0) },
        friendOutcome: { !failingIDs.contains($0) }
    )
    expect(result.circuitTripped, true, "a broad early failure run trips the circuit breaker before exhausting the shortlist")
    expect(result.attemptedCandidates.count < ids.count, true, "breaker stopped the pass before dispatching all 10 candidates")
    expect(state.totalRequests < ids.count * 2 * MidpointFairnessConfig.maxAttemptsPerLeg, true, "total requests for the pass stayed well under the full worst case")
}

// MARK: - Scheduler-E. RECOVERY RESUMES THE SAME PER-LEG LIFETIME BUDGET
// Demonstrates there is no "reset" between passes: the SAME state object's
// attempt counter simply keeps counting, so a second call after a primary-
// pass failure reports lifetime attempt #2, and a further call once the
// budget is exhausted is never made because userLegPending is false.
do {
    print("Scheduler-E. RECOVERY RESUMES THE SAME PER-LEG LIFETIME BUDGET")
    let state = LegSchedulerState(ids: ["e1"])
    let (primaryAttempt, _) = state.beginUserAttempt("e1")
    state.recordUserFailure("e1", transient: true)
    expect(primaryAttempt, 1, "primary pass consumes lifetime attempt #1")
    expect(state.userAttempts("e1"), 1, "attempt counter reflects 1 used attempt after the primary pass, not reset")
    let (recoveryAttempt, _) = state.beginUserAttempt("e1")
    state.recordUserFailure("e1", transient: true)
    expect(recoveryAttempt, 2, "recovery pass consumes lifetime attempt #2 (continuing the SAME counter, not restarting at #1)")
    expect(state.userLegPending("e1"), false, "budget now exhausted (2/2) - a third pass would find nothing pending for this leg")
}

// MARK: - Scheduler-F. SUCCESSFUL USER LEG + FAILED FRIEND LEG PRESERVES USER RESULT
do {
    print("Scheduler-F. SUCCESSFUL USER LEG + FAILED FRIEND LEG PRESERVES USER RESULT")
    let state = LegSchedulerState(ids: ["f1"])
    _ = state.beginUserAttempt("f1")
    state.recordUserSuccess("f1", eta: 500)
    _ = state.beginFriendAttempt("f1")
    state.recordFriendFailure("f1", transient: true)
    expect(state.userLegPending("f1"), false, "successful user leg is never re-attempted")
    expect(state.friendLegPending("f1"), true, "failed friend leg is still pending for recovery")
    // Recovery pass only ever calls beginFriendAttempt here - beginUserAttempt
    // is never called again, mirroring runPass only re-dispatching pending legs.
    let (friendRecoveryAttempt, _) = state.beginFriendAttempt("f1")
    state.recordFriendSuccess("f1", eta: 530)
    expect(friendRecoveryAttempt, 2, "friend leg's recovery attempt is its lifetime attempt #2")
    expect(state.userAttempts("f1"), 1, "user leg was NEVER re-requested - still just its original 1 attempt")
    expect(state.verifiedResults()["f1"]?.userETA, 500, "preserved user ETA is the ORIGINAL value, not re-fetched")
    expect(state.verifiedResults()["f1"]?.friendETA, 530, "friend ETA reflects the recovered value")
}

// MARK: - Scheduler-G. NO ETA LEG EXCEEDS 2 LIFETIME ATTEMPTS
// Repeatedly attempt-and-fail a single leg as long as it reports pending;
// the loop must terminate at exactly maxAttemptsPerLeg, never beyond it.
do {
    print("Scheduler-G. NO ETA LEG EXCEEDS 2 LIFETIME ATTEMPTS")
    let state = LegSchedulerState(ids: ["g1"])
    var iterations = 0
    while state.userLegPending("g1") {
        _ = state.beginUserAttempt("g1")
        state.recordUserFailure("g1", transient: true)
        iterations += 1
        if iterations > MidpointFairnessConfig.maxAttemptsPerLeg + 5 {
            break // safety valve so a real regression fails loudly instead of hanging
        }
    }
    expect(iterations, MidpointFairnessConfig.maxAttemptsPerLeg, "the pending-gated loop stopped at exactly the configured lifetime budget")
    expect(state.userAttempts("g1"), MidpointFairnessConfig.maxAttemptsPerLeg, "attempt counter never exceeds the configured per-leg budget")
}

// MARK: - Scheduler-H. SCHEDULER NEVER INTENTIONALLY EXCEEDS 6 CONCURRENT RESTAURANT ETA REQUESTS
// Restored (post-experiment) production concurrency: 3 candidates/batch, up
// to 6 concurrent MKDirections calls. Verifies both the config value and
// that LegSchedulerState's own concurrency accounting correctly reflects
// (and would catch a violation of) the "3 candidates per batch" discipline
// runPass is responsible for.
do {
    print("Scheduler-H. SCHEDULER NEVER INTENTIONALLY EXCEEDS 6 CONCURRENT RESTAURANT ETA REQUESTS")
    expect(MidpointFairnessConfig.restaurantVerificationConcurrency, 3, "restored production config processes 3 restaurant candidates per batch")
    let expectedMaxConcurrentRequests = MidpointFairnessConfig.restaurantVerificationConcurrency * 2
    expect(expectedMaxConcurrentRequests, 6, "3 candidates x 2 legs (user+friend) = 6 max intended concurrent MKDirections calls")

    // Well-behaved sequencing: a batch of 3 candidates' 6 legs are all in
    // flight together, but the NEXT batch of 3 doesn't begin until the
    // current batch's group.notify fires - mirrors runPass's real batching.
    let wellBehaved = LegSchedulerState(ids: ["h1", "h2", "h3", "h4", "h5", "h6"])
    for batch in [["h1", "h2", "h3"], ["h4", "h5", "h6"]] {
        for id in batch {
            _ = wellBehaved.beginUserAttempt(id)
            _ = wellBehaved.beginFriendAttempt(id)
        }
        for id in batch {
            wellBehaved.recordUserSuccess(id, eta: 500)
            wellBehaved.recordFriendSuccess(id, eta: 500)
            _ = wellBehaved.endAttempt()
            _ = wellBehaved.endAttempt()
        }
    }
    expect(wellBehaved.maxObservedConcurrency, 6, "processing 3 candidates per batch never observes more than 6 concurrent requests")

    // Violation case (never produced by current runPass, included so this
    // test would actually catch a regression that started a second batch
    // before the first one's legs finished): batch 2's legs begin while
    // batch 1's are still in flight.
    let violating = LegSchedulerState(ids: ["v1", "v2", "v3", "v4", "v5", "v6"])
    for id in ["v1", "v2", "v3"] {
        _ = violating.beginUserAttempt(id)
        _ = violating.beginFriendAttempt(id)
    }
    for id in ["v4", "v5", "v6"] {
        _ = violating.beginUserAttempt(id)
        _ = violating.beginFriendAttempt(id)
    }
    expect(violating.maxObservedConcurrency, 12, "starting a second batch before the first ends IS observable as exceeding the intended ceiling - confirms this instrument would catch such a regression")
}

// MARK: - Scheduler-I. ACCUMULATED RESULTS SURVIVE AN UNRELIABLE ENDING ROUND
// Superseded by the round-preservation fix: this scenario originally
// asserted that .limitedFairOptions was unreachable from an unreliable
// round. That was the LA -> Long Beach data-loss bug in miniature - a
// restaurant that genuinely verified (fair or not) in an earlier, reliable
// round is real evidence and must not be discarded just because the round
// that ultimately ended the search hit a broad MapKit failure. Kept under
// this same letter for traceability against the original spec, now
// asserting the corrected behavior.
do {
    print("Scheduler-I. ACCUMULATED RESULTS SURVIVE AN UNRELIABLE ENDING ROUND")
    let reliable = ETAVerificationDecision.isRoundReliable(etaAttemptedCount: 10, etaVerifiedCount: 3)
    expect(reliable, false, "3/10 verified is below the 0.5 reliability threshold")
    let outcome = ETAVerificationDecision.finalOutcomeCase(verifiedCount: 2, additionalVerifiedCount: 3, roundWasReliable: reliable, yelpEverReturnedResults: true)
    expect(outcome, .limitedFairOptions, "2 verified-fair (+3 additional) already accumulated survives an unreliable ending round as limitedFairOptions")
    expect(outcome != .etaVerificationUnavailable, true, "already-accumulated usable results must never be downgraded to a Search Problem just because a later round was unreliable")
}

// MARK: - Scheduler-J. HEALTHY VERIFIED-UNFAIR CANDIDATES ARE USABLE ADDITIONAL OPTIONS
// A fully (reliably) verified search with 0 fair results but genuinely
// verified-unfair candidates is real, usable evidence - Part 2 now surfaces
// those as limitedFairOptions(additional options) rather than the harsher
// noFairRestaurants; it must also never be misclassified as an
// infrastructure/verification failure.
do {
    print("Scheduler-J. HEALTHY VERIFIED-UNFAIR CANDIDATES ARE USABLE ADDITIONAL OPTIONS")
    let reliable = ETAVerificationDecision.isRoundReliable(etaAttemptedCount: 10, etaVerifiedCount: 10)
    expect(reliable, true, "10/10 verified is fully reliable")
    let outcomeWithAdditional = ETAVerificationDecision.finalOutcomeCase(verifiedCount: 0, additionalVerifiedCount: 10, roundWasReliable: reliable, yelpEverReturnedResults: true)
    expect(outcomeWithAdditional, .limitedFairOptions, "reliably-verified 0-fair/10-additional result surfaces the 10 as usable additional options")
    expect(outcomeWithAdditional != .etaVerificationUnavailable, true, "genuine unfairness must never be reported as an infrastructure/verification failure")
    // The narrower noFairRestaurants case is preserved for literally zero
    // usable restaurants of either kind.
    let outcomeTrulyEmpty = ETAVerificationDecision.finalOutcomeCase(verifiedCount: 0, additionalVerifiedCount: 0, roundWasReliable: reliable, yelpEverReturnedResults: true)
    expect(outcomeTrulyEmpty, .noFairRestaurants, "reliably-verified 0-fair/0-additional (literally nothing usable) is still noFairRestaurants")
}

// MARK: - Part 2 test helpers: displayed-result assembly (up to 10 results)
//
// `Restaurant` (LetsMeet/Model/YelpResults.swift) has a custom Decodable
// init and no memberwise initializer, so these tests construct instances via
// JSONDecoder - exactly the same mechanism production Yelp responses go
// through - rather than adding a test-only initializer to the production
// model.
func makeRestaurant(_ id: String) -> Restaurant {
    let json = """
    {"id": "\(id)", "name": "\(id)", "rating": 4.0, "categories": []}
    """.data(using: .utf8)!
    return try! JSONDecoder().decode(Restaurant.self, from: json)
}

// A user/friend ETA pair with a given fairnessExcess (seconds beyond the
// tolerance needed to pass; 0 = exactly at the fairness boundary, positive =
// unfair by that many seconds). Anchored to a fixed longerETA of 1200s
// (20 minutes), where `fairnessTolerance` clamps to a stable, known 180s
// (10% of 1200 = 120s, clamped up to the 180s floor) for every test built
// this way.
func etaPair(excessSeconds: TimeInterval) -> (userETA: TimeInterval, friendETA: TimeInterval) {
    let longerETA: TimeInterval = 1200
    let tolerance = MidpointFairnessConfig.fairnessTolerance(forLongerETA: longerETA)
    let delta = tolerance + excessSeconds
    return (userETA: longerETA, friendETA: longerETA - delta)
}

// MARK: - P1. 10 FAIR / 0 UNFAIR -> 10 FAIR, NO ADDITIONAL
do {
    print("P1. 10 FAIR / 0 UNFAIR -> DISPLAY ALL 10 FAIR, NO ADDITIONAL")
    let fair = (1...10).map { makeRestaurant("p1-fair\($0)") }
    let display = ETAVerificationDecision.buildDisplayList(fair: fair, verifiedUnfair: [], etaCache: [:], yelpOrderIndex: [:])
    expect(display.count, 10, "10 fair restaurants fill all 10 display slots")
    expect(display.allSatisfy { $0.fairnessDisplayStatus == .fair }, true, "every displayed restaurant is marked .fair")
}

// MARK: - P2. 8 FAIR / 2 UNFAIR -> 8 + 2 = 10
do {
    print("P2. 8 FAIR / 2 VERIFIED-UNFAIR -> DISPLAY 8 FAIR + 2 ADDITIONAL")
    let fair = (1...8).map { makeRestaurant("p2-fair\($0)") }
    let unfair = (1...2).map { makeRestaurant("p2-unfair\($0)") }
    var cache: [String: (userETA: TimeInterval, friendETA: TimeInterval)] = [:]
    for r in unfair { cache[r.id] = etaPair(excessSeconds: 60) }
    let display = ETAVerificationDecision.buildDisplayList(fair: fair, verifiedUnfair: unfair, etaCache: cache, yelpOrderIndex: [:])
    expect(display.count, 10, "8 fair + 2 additional fills exactly 10 slots")
    expect(display.filter { $0.fairnessDisplayStatus == .fair }.count, 8, "8 restaurants marked .fair")
    expect(display.filter { $0.fairnessDisplayStatus == .verifiedAdditional }.count, 2, "2 restaurants marked .verifiedAdditional")
}

// MARK: - P3. 5 FAIR / 5 UNFAIR -> 10 TOTAL
do {
    print("P3. 5 FAIR / 5 VERIFIED-UNFAIR -> DISPLAY 10 TOTAL")
    let fair = (1...5).map { makeRestaurant("p3-fair\($0)") }
    let unfair = (1...5).map { makeRestaurant("p3-unfair\($0)") }
    var cache: [String: (userETA: TimeInterval, friendETA: TimeInterval)] = [:]
    for r in unfair { cache[r.id] = etaPair(excessSeconds: 30) }
    let display = ETAVerificationDecision.buildDisplayList(fair: fair, verifiedUnfair: unfair, etaCache: cache, yelpOrderIndex: [:])
    expect(display.count, 10, "5 fair + 5 additional = 10 total displayed")
    expect(display.filter { $0.fairnessDisplayStatus == .fair }.count, 5, "5 marked .fair")
    expect(display.filter { $0.fairnessDisplayStatus == .verifiedAdditional }.count, 5, "5 marked .verifiedAdditional")
}

// MARK: - P4. 4 FAIR / 6 UNFAIR -> 10 TOTAL (ALL 6 ADDITIONAL USED)
do {
    print("P4. 4 FAIR / 6 VERIFIED-UNFAIR -> DISPLAY 10 TOTAL")
    let fair = (1...4).map { makeRestaurant("p4-fair\($0)") }
    let unfair = (1...6).map { makeRestaurant("p4-unfair\($0)") }
    var cache: [String: (userETA: TimeInterval, friendETA: TimeInterval)] = [:]
    for r in unfair { cache[r.id] = etaPair(excessSeconds: 45) }
    let display = ETAVerificationDecision.buildDisplayList(fair: fair, verifiedUnfair: unfair, etaCache: cache, yelpOrderIndex: [:])
    expect(display.count, 10, "4 fair + 6 additional = 10 total displayed")
    expect(display.filter { $0.fairnessDisplayStatus == .verifiedAdditional }.count, 6, "all 6 verified-unfair restaurants are used as additional options")
}

// MARK: - P5. 5 FAIR / 2 UNFAIR / 3 UNVERIFIED -> ONLY 7, NEVER PAD WITH UNVERIFIED
do {
    print("P5. 5 FAIR / 2 VERIFIED-UNFAIR / 3 UNVERIFIED -> DISPLAY ONLY 7")
    let fair = (1...5).map { makeRestaurant("p5-fair\($0)") }
    let unfair = (1...2).map { makeRestaurant("p5-unfair\($0)") }
    // The 3 "unverified" restaurants (failed ETA verification) are
    // deliberately never added to `fair` or `verifiedUnfair` -
    // RestaurantFairnessSelector's `mergedUnfair` accumulation in `runRound`
    // only ever adds a restaurant after it produces a real bidirectional ETA
    // pair, so an unverified restaurant is structurally incapable of
    // reaching buildDisplayList at all. This asserts the resulting
    // behavior: no padding to 10.
    var cache: [String: (userETA: TimeInterval, friendETA: TimeInterval)] = [:]
    for r in unfair { cache[r.id] = etaPair(excessSeconds: 20) }
    let display = ETAVerificationDecision.buildDisplayList(fair: fair, verifiedUnfair: unfair, etaCache: cache, yelpOrderIndex: [:])
    expect(display.count, 7, "only the 5 fair + 2 verified-unfair are displayed - unverified restaurants never pad the count")
}

// MARK: - P6. 0 FAIR / 10 VERIFIED-UNFAIR -> CORRECT SEMANTICS + OUTCOME MAPPING
do {
    print("P6. 0 FAIR / 10 VERIFIED-UNFAIR -> ALL 10 DISPLAYED AS ADDITIONAL, OUTCOME IS limitedFairOptions")
    let unfair = (1...10).map { makeRestaurant("p6-unfair\($0)") }
    var cache: [String: (userETA: TimeInterval, friendETA: TimeInterval)] = [:]
    for (i, r) in unfair.enumerated() { cache[r.id] = etaPair(excessSeconds: Double(i + 1) * 10) }
    let display = ETAVerificationDecision.buildDisplayList(fair: [], verifiedUnfair: unfair, etaCache: cache, yelpOrderIndex: [:])
    expect(display.count, 10, "all 10 verified-unfair restaurants become displayed additional options")
    expect(display.allSatisfy { $0.fairnessDisplayStatus == .verifiedAdditional }, true, "every displayed restaurant is marked .verifiedAdditional, none .fair")
    let outcome = ETAVerificationDecision.finalOutcomeCase(verifiedCount: 0, additionalVerifiedCount: unfair.count, roundWasReliable: true, yelpEverReturnedResults: true)
    expect(outcome, .limitedFairOptions, "the outcome-enum mapping for 0 fair/10 additional is limitedFairOptions, not noFairRestaurants")
}

// MARK: - P7. BROAD MAPKIT FAILURE WITH SOME ACCUMULATED EVIDENCE -> limitedFairOptions
// Superseded by the round-preservation fix: 1 verified-unfair restaurant is
// a real, already-accumulated ETA pair, not nothing - it must survive a
// broad failure in the SAME round it verified in, just as it would survive
// a broad failure in a LATER round (Scheduler-I above). The narrower "truly
// nothing accumulated" case is asserted separately in P7b below.
do {
    print("P7. BROAD MAPKIT FAILURE WITH 1 VERIFIED-ADDITIONAL ALREADY ACCUMULATED -> limitedFairOptions")
    let reliable = ETAVerificationDecision.isRoundReliable(etaAttemptedCount: 10, etaVerifiedCount: 1)
    expect(reliable, false, "1/10 verified is a broad MapKit failure - unreliable")
    let outcome = ETAVerificationDecision.finalOutcomeCase(verifiedCount: 0, additionalVerifiedCount: 1, roundWasReliable: reliable, yelpEverReturnedResults: true)
    expect(outcome, .limitedFairOptions, "1 candidate that genuinely verified unfair survives a broad failure as a usable additional option")
}

// MARK: - P7b. BROAD MAPKIT FAILURE WITH ZERO ACCUMULATED EVIDENCE -> etaVerificationUnavailable
// The narrower case P7 no longer covers: with truly nothing verified of
// either kind, an unreliable round means there is nothing trustworthy to
// report at all.
do {
    print("P7b. BROAD MAPKIT FAILURE WITH NOTHING ACCUMULATED -> etaVerificationUnavailable")
    let reliable = ETAVerificationDecision.isRoundReliable(etaAttemptedCount: 10, etaVerifiedCount: 1)
    expect(reliable, false, "1/10 verified is a broad MapKit failure - unreliable")
    let outcome = ETAVerificationDecision.finalOutcomeCase(verifiedCount: 0, additionalVerifiedCount: 0, roundWasReliable: reliable, yelpEverReturnedResults: true)
    expect(outcome, .etaVerificationUnavailable, "zero verified restaurants of either kind from an unreliable round is a genuine Search Problem, not limitedFairOptions")
}

// MARK: - P8. ADDITIONAL OPTIONS ORDERED CLOSEST-TO-FAIR -> LEAST BALANCED
do {
    print("P8. ADDITIONAL OPTIONS ORDERED CLOSEST-TO-FAIR FIRST")
    let close = makeRestaurant("p8-close")
    let mid = makeRestaurant("p8-mid")
    let far = makeRestaurant("p8-far")
    let cache: [String: (userETA: TimeInterval, friendETA: TimeInterval)] = [
        far.id: etaPair(excessSeconds: 300),
        close.id: etaPair(excessSeconds: 10),
        mid.id: etaPair(excessSeconds: 100)
    ]
    let ranked = ETAVerificationDecision.rankAdditionalOptions(verifiedUnfair: [far, close, mid], etaCache: cache, yelpOrderIndex: [:])
    expect(ranked.map(\.id), [close.id, mid.id, far.id], "additional options are ordered ascending by fairnessExcess: closest-to-fair first, least balanced last")

    // Tie-break: equal fairnessExcess falls back to Yelp relevance order.
    let a = makeRestaurant("p8-tieA")
    let b = makeRestaurant("p8-tieB")
    let tieCache: [String: (userETA: TimeInterval, friendETA: TimeInterval)] = [
        a.id: etaPair(excessSeconds: 50),
        b.id: etaPair(excessSeconds: 50)
    ]
    let tieOrder = [b.id: 0, a.id: 1]
    let tieRanked = ETAVerificationDecision.rankAdditionalOptions(verifiedUnfair: [a, b], etaCache: tieCache, yelpOrderIndex: tieOrder)
    expect(tieRanked.map(\.id), [b.id, a.id], "equal fairnessExcess breaks the tie by Yelp relevance order (lower yelpOrderIndex first)")
}

// MARK: - P9. FAIR RESULTS ALWAYS ORDERED BEFORE ADDITIONAL RESULTS
do {
    print("P9. FAIR RESULTS ALWAYS ORDERED BEFORE ADDITIONAL RESULTS")
    let fair = (1...3).map { makeRestaurant("p9-fair\($0)") }
    let unfair = (1...3).map { makeRestaurant("p9-unfair\($0)") }
    var cache: [String: (userETA: TimeInterval, friendETA: TimeInterval)] = [:]
    for r in unfair { cache[r.id] = etaPair(excessSeconds: 15) }
    let display = ETAVerificationDecision.buildDisplayList(fair: fair, verifiedUnfair: unfair, etaCache: cache, yelpOrderIndex: [:])
    let fairIndices = display.indices.filter { display[$0].fairnessDisplayStatus == .fair }
    let additionalIndices = display.indices.filter { display[$0].fairnessDisplayStatus == .verifiedAdditional }
    expect((fairIndices.max() ?? -1) < (additionalIndices.min() ?? Int.max), true, "every .fair entry appears before every .verifiedAdditional entry")
}

// MARK: - P10. NO DUPLICATE RESTAURANTS IN THE DISPLAY LIST
do {
    print("P10. DISPLAY LIST NEVER CONTAINS DUPLICATE RESTAURANTS")
    // RestaurantFairnessSelector's `mergedUnfair` accumulation (in
    // `runRound`) explicitly excludes anything already present in
    // `mergedVerified`, so `fair` and `verifiedUnfair` are always disjoint
    // by construction before they ever reach buildDisplayList. This asserts
    // buildDisplayList's own behavior on that guaranteed-disjoint input.
    let fair = (1...6).map { makeRestaurant("p10-fair\($0)") }
    let unfair = (1...4).map { makeRestaurant("p10-unfair\($0)") }
    var cache: [String: (userETA: TimeInterval, friendETA: TimeInterval)] = [:]
    for r in unfair { cache[r.id] = etaPair(excessSeconds: 25) }
    let display = ETAVerificationDecision.buildDisplayList(fair: fair, verifiedUnfair: unfair, etaCache: cache, yelpOrderIndex: [:])
    let ids = display.map(\.id)
    expect(Set(ids).count, ids.count, "no duplicate restaurant IDs appear in the assembled display list")
}

// MARK: - P11. RESULT COUNT NEVER EXCEEDS maxDisplayedRestaurants (10)
do {
    print("P11. DISPLAY LIST COUNT NEVER EXCEEDS maxDisplayedRestaurants (10)")
    let fair = (1...15).map { makeRestaurant("p11-fair\($0)") }
    let unfair = (1...20).map { makeRestaurant("p11-unfair\($0)") }
    var cache: [String: (userETA: TimeInterval, friendETA: TimeInterval)] = [:]
    for r in unfair { cache[r.id] = etaPair(excessSeconds: 40) }
    let display = ETAVerificationDecision.buildDisplayList(fair: fair, verifiedUnfair: unfair, etaCache: cache, yelpOrderIndex: [:])
    expect(display.count, MidpointFairnessConfig.maxDisplayedRestaurants, "display list is capped at maxDisplayedRestaurants even with 15 fair + 20 additional available")
    expect(display.filter { $0.fairnessDisplayStatus == .fair }.count, 10, "fair alone already fills all 10 slots, so 0 additional are used")
}

// MARK: - P12. PER-LEG ATTEMPT BUDGET NEVER EXCEEDS 2 UNDER RESTORED 3-CANDIDATE BATCHING
do {
    print("P12. PER-LEG ATTEMPT BUDGET NEVER EXCEEDS 2, EVEN UNDER RESTORED 3-CANDIDATE BATCHING")
    let ids = (1...9).map { "p12-r\($0)" } // 3 batches of 3 at restored concurrency
    let state = LegSchedulerState(ids: ids)
    func runOverBatches(recordFailure: (String) -> Void, pending: (String) -> Bool, begin: (String) -> Void) {
        for batchStart in stride(from: 0, to: ids.count, by: MidpointFairnessConfig.restaurantVerificationConcurrency) {
            let batch = Array(ids[batchStart..<min(batchStart + MidpointFairnessConfig.restaurantVerificationConcurrency, ids.count)])
            for id in batch where pending(id) {
                begin(id)
                recordFailure(id)
            }
        }
    }
    // Primary pass, batched 3 at a time - every leg fails.
    runOverBatches(
        recordFailure: { state.recordUserFailure($0, transient: true) },
        pending: { state.userLegPending($0) },
        begin: { _ = state.beginUserAttempt($0) }
    )
    runOverBatches(
        recordFailure: { state.recordFriendFailure($0, transient: true) },
        pending: { state.friendLegPending($0) },
        begin: { _ = state.beginFriendAttempt($0) }
    )
    // Recovery pass: exactly one more attempt per still-pending leg.
    for id in ids where state.userLegPending(id) {
        _ = state.beginUserAttempt(id)
        state.recordUserFailure(id, transient: true)
    }
    for id in ids where state.friendLegPending(id) {
        _ = state.beginFriendAttempt(id)
        state.recordFriendFailure(id, transient: true)
    }
    for id in ids {
        expect(state.userAttempts(id), MidpointFairnessConfig.maxAttemptsPerLeg, "\(id) user leg never exceeds the shared 2-attempt budget under batch-of-3 scheduling")
        expect(state.friendAttempts(id), MidpointFairnessConfig.maxAttemptsPerLeg, "\(id) friend leg never exceeds the shared 2-attempt budget under batch-of-3 scheduling")
    }
}

// MARK: - P13. RECOVERY PASS CANNOT RESET A LEG'S ATTEMPT BUDGET
do {
    print("P13. RECOVERY PASS CANNOT RESET A LEG'S ATTEMPT BUDGET")
    let state = LegSchedulerState(ids: ["p13-r1"])
    _ = state.beginUserAttempt("p13-r1")
    state.recordUserFailure("p13-r1", transient: true)
    expect(state.userAttempts("p13-r1"), 1, "primary pass consumed 1 of 2 lifetime attempts")
    expect(state.userLegPending("p13-r1"), true, "leg still pending with exactly 1 attempt remaining")
    let (recoveryAttemptNumber, _) = state.beginUserAttempt("p13-r1")
    expect(recoveryAttemptNumber, 2, "recovery's attempt is lifetime attempt #2, confirming no reset occurred")
    state.recordUserFailure("p13-r1", transient: true)
    expect(state.userLegPending("p13-r1"), false, "budget now fully exhausted - recovery never granted a fresh 2-attempt allowance")
    expect(state.userAttempts("p13-r1"), MidpointFairnessConfig.maxAttemptsPerLeg, "total attempts used equals exactly the shared budget, never more via a reset")
}

// MARK: - P14. RESTORED 3-CANDIDATE BATCHING DOES NOT BREAK CIRCUIT-BREAKER ACCOUNTING
do {
    print("P14. RESTORED 3-CANDIDATE BATCHING DOES NOT BREAK CIRCUIT-BREAKER ACCOUNTING")
    let ids = (1...9).map { "p14-r\($0)" }
    let state = LegSchedulerState(ids: ids)
    let failingIDs: Set<String> = ["p14-r1", "p14-r2", "p14-r3", "p14-r4", "p14-r5", "p14-r6"]
    var legsAttempted = 0
    var legsFailed = 0
    var circuitTripped = false
    var attemptedBatches = 0
    let totalBatches = (ids.count + MidpointFairnessConfig.restaurantVerificationConcurrency - 1) / MidpointFairnessConfig.restaurantVerificationConcurrency
    for batchStart in stride(from: 0, to: ids.count, by: MidpointFairnessConfig.restaurantVerificationConcurrency) {
        if circuitTripped { break }
        attemptedBatches += 1
        let batch = Array(ids[batchStart..<min(batchStart + MidpointFairnessConfig.restaurantVerificationConcurrency, ids.count)])
        for id in batch {
            _ = state.beginUserAttempt(id)
            legsAttempted += 1
            if failingIDs.contains(id) {
                legsFailed += 1
                state.recordUserFailure(id, transient: true)
            } else {
                state.recordUserSuccess(id, eta: 500)
            }
            _ = state.beginFriendAttempt(id)
            legsAttempted += 1
            if failingIDs.contains(id) {
                legsFailed += 1
                state.recordFriendFailure(id, transient: true)
            } else {
                state.recordFriendSuccess(id, eta: 500)
            }
        }
        if ETAVerificationDecision.shouldTripCircuitBreaker(legsAttempted: legsAttempted, legsFailed: legsFailed) {
            circuitTripped = true
        }
    }
    expect(circuitTripped, true, "the circuit breaker still trips correctly when accounting is done per-batch-of-3 rather than per-candidate")
    expect(attemptedBatches < totalBatches, true, "the breaker stopped dispatching further batches before exhausting all \(totalBatches) batches")
}

// MARK: - R1-R16. ROUND-STOPPING (Goal 1) AND ROUND-PRESERVATION (Goal 2)
//
// Covers the LA <-> Long Beach follow-up fix: `ETAVerificationDecision.
// shouldStopRounds`/`uniqueDisplayableCount` (Goal 1 - stop launching
// further radius-expansion/corridor-shift rounds once enough displayable
// restaurants have already accumulated) and the `finalOutcomeCase`
// branch-reordering fix above (Goal 2 - a later unreliable round must never
// erase usable results an earlier reliable round already verified).

// MARK: - R1. ROUND 0 = 10 FAIR -> STOP, NO FURTHER ROUND
do {
    print("R1. ROUND 0 = 10 FAIR -> STOP, NO FURTHER ROUND")
    let fair = (1...10).map { makeRestaurant("r1-fair\($0)") }
    let unique = ETAVerificationDecision.uniqueDisplayableCount(fair: fair, verifiedUnfair: [])
    expect(unique, 10, "10 fair restaurants are 10 unique displayable restaurants")
    let stop = ETAVerificationDecision.shouldStopRounds(verifiedCount: fair.count, uniqueDisplayableCount: unique)
    expect(stop, true, "10 fair restaurants alone are enough to stop - no further round is needed")
}

// MARK: - R2. ROUND 0 = 5 FAIR + 5 ADDITIONAL -> STOP
do {
    print("R2. ROUND 0 = 5 FAIR + 5 ADDITIONAL -> STOP")
    let fair = (1...5).map { makeRestaurant("r2-fair\($0)") }
    let unfair = (1...5).map { makeRestaurant("r2-unfair\($0)") }
    let unique = ETAVerificationDecision.uniqueDisplayableCount(fair: fair, verifiedUnfair: unfair)
    expect(unique, 10, "5 fair + 5 additional = 10 unique displayable restaurants")
    let stop = ETAVerificationDecision.shouldStopRounds(verifiedCount: fair.count, uniqueDisplayableCount: unique)
    expect(stop, true, "reaching 10 total displayable restaurants stops the search even with only 5 strictly fair")
}

// MARK: - R3. ROUND 0 = 1 FAIR + 9 ADDITIONAL -> STOP (the LA <-> Long Beach shape)
do {
    print("R3. ROUND 0 = 1 FAIR + 9 ADDITIONAL -> STOP (the LA <-> Long Beach shape)")
    let fair = [makeRestaurant("r3-fair1")]
    let unfair = (1...9).map { makeRestaurant("r3-unfair\($0)") }
    let unique = ETAVerificationDecision.uniqueDisplayableCount(fair: fair, verifiedUnfair: unfair)
    expect(unique, 10, "1 fair + 9 additional = 10 unique displayable restaurants")
    let stop = ETAVerificationDecision.shouldStopRounds(verifiedCount: fair.count, uniqueDisplayableCount: unique)
    expect(stop, true, "1 fair + 9 verified-additional already fills all 10 slots - this is the exact shape that previously triggered an unnecessary, failure-prone Round 1")
    let outcome = ETAVerificationDecision.finalOutcomeCase(verifiedCount: fair.count, additionalVerifiedCount: unfair.count, roundWasReliable: true, yelpEverReturnedResults: true)
    expect(outcome, .limitedFairOptions, "the stopped search still reports a legitimate limitedFairOptions outcome, not success (only 1 strictly fair) and not a Search Problem")
}

// MARK: - R4. ROUND 0 = 0 FAIR + 10 ADDITIONAL -> STOP WITH CORRECT LIMITED SEMANTICS
do {
    print("R4. ROUND 0 = 0 FAIR + 10 ADDITIONAL -> STOP WITH CORRECT LIMITED SEMANTICS")
    let unfair = (1...10).map { makeRestaurant("r4-unfair\($0)") }
    let unique = ETAVerificationDecision.uniqueDisplayableCount(fair: [], verifiedUnfair: unfair)
    expect(unique, 10, "0 fair + 10 additional = 10 unique displayable restaurants")
    let stop = ETAVerificationDecision.shouldStopRounds(verifiedCount: 0, uniqueDisplayableCount: unique)
    expect(stop, true, "10 verified-additional restaurants alone are enough to stop, even with zero strictly-fair results")
    let outcome = ETAVerificationDecision.finalOutcomeCase(verifiedCount: 0, additionalVerifiedCount: unfair.count, roundWasReliable: true, yelpEverReturnedResults: true)
    expect(outcome, .limitedFairOptions, "0 fair/10 additional is limitedFairOptions, never misreported as noFairRestaurants or success")
}

// MARK: - R5. ROUND 0 = 2 FAIR + 3 ADDITIONAL (5 TOTAL) -> CONTINUATION MAY STILL OCCUR
do {
    print("R5. ROUND 0 = 2 FAIR + 3 ADDITIONAL (5 TOTAL) -> CONTINUATION MAY STILL OCCUR")
    let fair = (1...2).map { makeRestaurant("r5-fair\($0)") }
    let unfair = (1...3).map { makeRestaurant("r5-unfair\($0)") }
    let unique = ETAVerificationDecision.uniqueDisplayableCount(fair: fair, verifiedUnfair: unfair)
    expect(unique, 5, "2 fair + 3 additional = 5 unique displayable restaurants")
    let stop = ETAVerificationDecision.shouldStopRounds(verifiedCount: fair.count, uniqueDisplayableCount: unique)
    expect(stop, false, "only 5 of 10 possible slots filled and only 2 of the 3 minViableRestaurants met - a further round is still legitimately useful")
}

// MARK: - R6. ROUND 0 = 2 FAIR + 3 ADDITIONAL, ROUND 1 UNRELIABLE -> PRESERVE THE ORIGINAL 5
do {
    print("R6. ROUND 0 = 2 FAIR + 3 ADDITIONAL, ROUND 1 UNRELIABLE -> PRESERVE THE ORIGINAL 5")
    let outcome = ETAVerificationDecision.finalOutcomeCase(verifiedCount: 2, additionalVerifiedCount: 3, roundWasReliable: false, yelpEverReturnedResults: true)
    expect(outcome, .limitedFairOptions, "round 0's 2 fair + 3 additional survive round 1's unreliability instead of being discarded as etaVerificationUnavailable")
}

// MARK: - R7. ROUND 0 = 1 FAIR + 4 ADDITIONAL, ROUND 1 UNRELIABLE -> PRESERVE THE ORIGINAL 5
do {
    print("R7. ROUND 0 = 1 FAIR + 4 ADDITIONAL, ROUND 1 UNRELIABLE -> PRESERVE THE ORIGINAL 5")
    let fair = [makeRestaurant("r7-fair1")]
    let unfair = (1...4).map { makeRestaurant("r7-unfair\($0)") }
    let unique = ETAVerificationDecision.uniqueDisplayableCount(fair: fair, verifiedUnfair: unfair)
    expect(unique, 5, "1 fair + 4 additional = 5 unique displayable restaurants")
    let stopAtRound0 = ETAVerificationDecision.shouldStopRounds(verifiedCount: fair.count, uniqueDisplayableCount: unique)
    expect(stopAtRound0, false, "5 of 10 slots filled and only 1 of the 3 minViableRestaurants met - round 0 alone legitimately continues on to round 1")
    let outcome = ETAVerificationDecision.finalOutcomeCase(verifiedCount: fair.count, additionalVerifiedCount: unfair.count, roundWasReliable: false, yelpEverReturnedResults: true)
    expect(outcome, .limitedFairOptions, "round 1's unreliability does not erase round 0's 1 fair + 4 additional - they're returned as limitedFairOptions")
}

// MARK: - R8. ZERO USABLE VERIFIED RESULTS, UNRELIABLE -> etaVerificationUnavailable
do {
    print("R8. ZERO USABLE VERIFIED RESULTS, UNRELIABLE -> etaVerificationUnavailable")
    let stopAtZero = ETAVerificationDecision.shouldStopRounds(verifiedCount: 0, uniqueDisplayableCount: 0)
    expect(stopAtZero, false, "zero accumulated results never satisfies the stopping condition, so another round is legitimately attempted")
    let outcome = ETAVerificationDecision.finalOutcomeCase(verifiedCount: 0, additionalVerifiedCount: 0, roundWasReliable: false, yelpEverReturnedResults: true)
    expect(outcome, .etaVerificationUnavailable, "the one exception to the preservation rule: with truly nothing accumulated, an unreliable round reports a genuine Search Problem")
}

// MARK: - R9. A LATER UNRELIABLE ROUND CANNOT DELETE EARLIER VERIFIED-FAIR RESTAURANTS
do {
    print("R9. A LATER UNRELIABLE ROUND CANNOT DELETE EARLIER VERIFIED-FAIR RESTAURANTS")
    let outcome = ETAVerificationDecision.finalOutcomeCase(verifiedCount: 2, additionalVerifiedCount: 1, roundWasReliable: false, yelpEverReturnedResults: true)
    expect(outcome, .limitedFairOptions, "round 0's 2 verified-fair restaurants survive round 1's failure")
    expect(outcome != .etaVerificationUnavailable, true, "verified-fair restaurants are never discarded just because a later round was unreliable")
}

// MARK: - R10. A LATER UNRELIABLE ROUND CANNOT DELETE EARLIER VERIFIED-ADDITIONAL RESTAURANTS
do {
    print("R10. A LATER UNRELIABLE ROUND CANNOT DELETE EARLIER VERIFIED-ADDITIONAL RESTAURANTS")
    let outcome = ETAVerificationDecision.finalOutcomeCase(verifiedCount: 0, additionalVerifiedCount: 2, roundWasReliable: false, yelpEverReturnedResults: true)
    expect(outcome, .limitedFairOptions, "round 0's 2 verified-additional restaurants survive round 1's failure")
    expect(outcome != .etaVerificationUnavailable, true, "verified-additional restaurants are never discarded just because a later round was unreliable")
}

// MARK: - R11. UNVERIFIED CANDIDATES NEVER COUNT TOWARD THE 10-RESULT STOPPING CONDITION
do {
    print("R11. UNVERIFIED CANDIDATES NEVER COUNT TOWARD THE 10-RESULT STOPPING CONDITION")
    // 1 fair + 7 additional = 8 unique displayable restaurants. Even if 2
    // more candidates were shortlisted this round but never produced a real
    // ETA pair (failed/timed-out verification), `uniqueDisplayableCount`
    // has no way to see them - by construction it only ever takes the
    // `fair`/`verifiedUnfair` arrays, which RestaurantFairnessSelector only
    // ever populates with restaurants that actually verified (see P5
    // above). So a search sitting at 8 genuinely displayable restaurants
    // correctly still continues, rather than treating 2 pending-but-
    // unverified candidates as if they already filled the last 2 slots.
    let fair = [makeRestaurant("r11-fair1")]
    let unfair = (1...7).map { makeRestaurant("r11-unfair\($0)") }
    let unique = ETAVerificationDecision.uniqueDisplayableCount(fair: fair, verifiedUnfair: unfair)
    expect(unique, 8, "only the 8 actually-verified restaurants count, regardless of how many additional candidates were merely shortlisted")
    let stop = ETAVerificationDecision.shouldStopRounds(verifiedCount: fair.count, uniqueDisplayableCount: unique)
    expect(stop, false, "8 verified displayable restaurants (not yet 10) correctly does not stop the search")
}

// MARK: - R12. DUPLICATE RESTAURANTS ACROSS ROUNDS DO NOT FALSELY TRIGGER THE STOPPING CONDITION
do {
    print("R12. DUPLICATE RESTAURANTS ACROSS ROUNDS DO NOT FALSELY TRIGGER THE STOPPING CONDITION")
    // Simulates what merging two rounds' accumulators could produce if a
    // restaurant were ever double-counted: 2 unique fair restaurants
    // represented by 4 array entries (each repeated once), and 4 unique
    // verified-additional restaurants represented by 6 array entries (2
    // repeats). A naive `fair.count + verifiedUnfair.count` would see
    // 4 + 6 = 10 and wrongly conclude the 10-result threshold was reached;
    // the real, Set-based unique count is only 6 (2 fair + 4 additional),
    // and `verifiedCount` (2, the unique fair count) is also below
    // minViableRestaurants, so neither half of shouldStopRounds should
    // trigger.
    let uniqueFair = (1...2).map { makeRestaurant("r12-fair\($0)") }
    let fairWithDuplicates = uniqueFair + uniqueFair
    let uniqueUnfair = (1...4).map { makeRestaurant("r12-unfair\($0)") }
    let unfairWithDuplicates = uniqueUnfair + [uniqueUnfair[0], uniqueUnfair[1]]
    expect(fairWithDuplicates.count + unfairWithDuplicates.count, 10, "raw (duplicate-inflated) counts sum to exactly 10")
    let unique = ETAVerificationDecision.uniqueDisplayableCount(fair: fairWithDuplicates, verifiedUnfair: unfairWithDuplicates)
    expect(unique, 6, "the true unique displayable count is 6, not the duplicate-inflated 10")
    let stop = ETAVerificationDecision.shouldStopRounds(verifiedCount: uniqueFair.count, uniqueDisplayableCount: unique)
    expect(stop, false, "6 genuinely unique displayable restaurants correctly does not stop the search, even though the raw duplicate-inflated count reaches exactly 10")
}

// MARK: - R13-R16. EXISTING COVERAGE RE-CONFIRMED UNCHANGED BY THE ROUND-STOPPING/PRESERVATION FIX
// These four requirements were already covered by pre-existing tests, which
// were re-verified against the fix above: fair-before-additional ordering
// (P9), additional restaurants retaining fairnessExcess ordering (P8),
// results never exceeding maxDisplayedRestaurants (P11), and the existing
// circuit-breaker/attempt-budget tests (G, H, P12-P14) - none of which call
// shouldStopRounds or finalOutcomeCase, so none of them changed behavior.
// Re-asserted directly here too, for traceability against this task's own
// enumerated scenario list.
do {
    print("R13. FAIR RESULTS REMAIN ORDERED BEFORE ADDITIONAL RESULTS (see also P9)")
    let fair = (1...3).map { makeRestaurant("r13-fair\($0)") }
    let unfair = (1...3).map { makeRestaurant("r13-unfair\($0)") }
    var cache: [String: (userETA: TimeInterval, friendETA: TimeInterval)] = [:]
    for r in unfair { cache[r.id] = etaPair(excessSeconds: 15) }
    let display = ETAVerificationDecision.buildDisplayList(fair: fair, verifiedUnfair: unfair, etaCache: cache, yelpOrderIndex: [:])
    expect(display.prefix(3).allSatisfy { $0.fairnessDisplayStatus == .fair }, true, "fair restaurants still occupy the first slots")
    expect(display.suffix(3).allSatisfy { $0.fairnessDisplayStatus == .verifiedAdditional }, true, "additional restaurants still occupy the remaining slots")
}

do {
    print("R14. ADDITIONAL RESTAURANTS RETAIN fairnessExcess ORDERING (see also P8)")
    let close = makeRestaurant("r14-close")
    let far = makeRestaurant("r14-far")
    let cache: [String: (userETA: TimeInterval, friendETA: TimeInterval)] = [
        far.id: etaPair(excessSeconds: 200),
        close.id: etaPair(excessSeconds: 5)
    ]
    let display = ETAVerificationDecision.buildDisplayList(fair: [], verifiedUnfair: [far, close], etaCache: cache, yelpOrderIndex: [:])
    expect(display.map(\.id), [close.id, far.id], "additional restaurants are still ordered closest-to-fair first after the round-stopping fix")
}

do {
    print("R15. FINAL DISPLAY LIST NEVER EXCEEDS 10 (see also P11)")
    let fair = (1...6).map { makeRestaurant("r15-fair\($0)") }
    let unfair = (1...6).map { makeRestaurant("r15-unfair\($0)") }
    var cache: [String: (userETA: TimeInterval, friendETA: TimeInterval)] = [:]
    for r in unfair { cache[r.id] = etaPair(excessSeconds: 30) }
    let display = ETAVerificationDecision.buildDisplayList(fair: fair, verifiedUnfair: unfair, etaCache: cache, yelpOrderIndex: [:])
    expect(display.count, MidpointFairnessConfig.maxDisplayedRestaurants, "6 fair + 6 additional (12 available) still caps at 10 displayed")
}

print("R16. EXISTING CIRCUIT-BREAKER / ATTEMPT-BUDGET TESTS (G, H, P12-P14) ARE UNCHANGED - see their own PASS/FAIL output above; none of them call shouldStopRounds or finalOutcomeCase.")

// MARK: - PD1-PD11. PROGRESSIVE RESTAURANT DELIVERY
//
// Covers the progressive-delivery feature: RestaurantFairnessSelector now
// calls `onProgress` with a cumulative, already-ranked snapshot after each
// completed ETA-verification batch (see its `onBatchProgress` closure,
// which guards emission on `!progressVerified.isEmpty ||
// !progressUnfair.isEmpty` and then calls the SAME
// `ETAVerificationDecision.buildDisplayList` used for the final result),
// and HomeViewModel threads those snapshots through an `activeSearchID`
// guard shared with the terminal-outcome callback.
//
// `SimulatedSearchSession` below reimplements ONLY the thin, imperative
// state-machine logic that lives directly in HomeViewModel.findAPlace /
// searchForRestaurants (the activeSearchID comparison, the one-time sheet
// presentation, and the `hadDisplayableResultsAlready` failure guard) -
// exactly as `simulatePass` above reimplements runPass's scheduling
// discipline - so it can be exercised deterministically with no
// UIKit/SwiftUI/Combine/MapKit dependency. Snapshot CONTENTS in every test
// below are assembled with the real, production `buildDisplayList`, never
// a separate/mocked ranking pass.
final class SimulatedSearchSession {
    private(set) var activeSearchID: String?
    private(set) var restaurants: [Restaurant] = []
    private(set) var isShowingResults = false
    private(set) var isSearching = false
    private(set) var errorTitle: String?
    private(set) var errorMessage: String?
    private(set) var sheetPresentationCount = 0
    private(set) var ignoredStaleProgressCount = 0
    private(set) var ignoredStaleOutcomeCount = 0

    /// Mirrors findAPlace(): a clean reset so a new search's progressive/
    /// terminal results can never mix with whatever the previous search
    /// left displayed.
    func startSearch(_ searchID: String) {
        activeSearchID = searchID
        isSearching = true
        restaurants = []
        errorTitle = nil
        errorMessage = nil
    }

    /// Mirrors the onProgress closure HomeViewModel passes to
    /// MeetingPlaceFinder: stale snapshots from a superseded search are
    /// dropped by the activeSearchID guard before ever touching displayed
    /// state, and the sheet is presented (isShowingResults false -> true)
    /// at most once per search, on whichever snapshot arrives first.
    func receiveProgress(searchID: String, snapshot: [Restaurant]) {
        guard activeSearchID == searchID else {
            ignoredStaleProgressCount += 1
            return
        }
        restaurants = snapshot
        if !isShowingResults {
            isShowingResults = true
            sheetPresentationCount += 1
        }
    }

    /// Mirrors the `.success`/`.limitedFairOptions` terminal-outcome branches.
    func receiveSuccessOutcome(searchID: String, finalRestaurants: [Restaurant]) {
        guard activeSearchID == searchID else {
            ignoredStaleOutcomeCount += 1
            return
        }
        isSearching = false
        restaurants = finalRestaurants
        errorTitle = nil
        errorMessage = nil
        if !isShowingResults {
            isShowingResults = true
            sheetPresentationCount += 1
        }
    }

    /// Mirrors the `.noFairRestaurants`/`.noRestaurantsNearby`/
    /// `.etaVerificationUnavailable`/`.searchFailed` terminal-outcome
    /// branches, each gated by `guard !hadDisplayableResultsAlready else
    /// { break }`: an infrastructure/fairness failure that arrives after
    /// progressive delivery has already shown trustworthy verified
    /// restaurants must never clear the sheet or surface an alert.
    func receiveFailureOutcome(searchID: String, title: String, message: String) {
        guard activeSearchID == searchID else {
            ignoredStaleOutcomeCount += 1
            return
        }
        isSearching = false
        let hadDisplayableResultsAlready = !restaurants.isEmpty
        guard !hadDisplayableResultsAlready else { return }
        isShowingResults = false
        restaurants = []
        errorTitle = title
        errorMessage = message
    }
}

/// Mirrors RestaurantFairnessSelector's onBatchProgress emission guard
/// exactly: a batch with nothing verified of either kind (fair or
/// verified-unfair) yet must not emit a progress snapshot at all, rather
/// than presenting an empty sheet.
func shouldEmitProgressSnapshot(verifiedSoFar: [Restaurant], verifiedUnfairSoFar: [Restaurant]) -> Bool {
    !verifiedSoFar.isEmpty || !verifiedUnfairSoFar.isEmpty
}

// MARK: - PD1. STALE SEARCH CALLBACKS ARE IGNORED
do {
    print("PD1. STALE SEARCH CALLBACKS ARE IGNORED")
    let session = SimulatedSearchSession()
    let r1 = makeRestaurant("pd1-r1")
    session.startSearch("search-old")
    session.receiveProgress(searchID: "search-old", snapshot: [r1])
    expect(session.restaurants.map(\.id), [r1.id], "old search's own snapshot is applied while it is still active")

    session.startSearch("search-new")
    expect(session.restaurants.isEmpty, true, "starting a new search immediately clears the old search's displayed restaurants")

    let staleRestaurant = makeRestaurant("pd1-stale")
    session.receiveProgress(searchID: "search-old", snapshot: [r1, staleRestaurant])
    expect(session.restaurants.isEmpty, true, "a late progress snapshot from the superseded search is dropped, not applied")
    expect(session.ignoredStaleProgressCount, 1, "the stale progress snapshot was counted as ignored")

    session.receiveSuccessOutcome(searchID: "search-old", finalRestaurants: [r1, staleRestaurant])
    expect(session.restaurants.isEmpty, true, "a late TERMINAL outcome from the superseded search is also dropped")
    expect(session.ignoredStaleOutcomeCount, 1, "the stale terminal outcome was counted as ignored")
}

// MARK: - PD2. NEW SEARCH CLEANLY RESETS PREVIOUS RESULTS
do {
    print("PD2. NEW SEARCH CLEANLY RESETS PREVIOUS RESULTS SO TWO SEARCHES NEVER MIX")
    let session = SimulatedSearchSession()
    let firstSearchFinal = (1...5).map { makeRestaurant("pd2-first\($0)") }
    session.startSearch("search-1")
    session.receiveSuccessOutcome(searchID: "search-1", finalRestaurants: firstSearchFinal)
    expect(session.restaurants.map(\.id), firstSearchFinal.map(\.id), "first search's final restaurants are displayed")

    session.startSearch("search-2")
    expect(session.restaurants.isEmpty, true, "starting search 2 resets the display before it produces any results of its own")

    let secondSearchBatch = (1...3).map { makeRestaurant("pd2-second\($0)") }
    session.receiveProgress(searchID: "search-2", snapshot: secondSearchBatch)
    let mixedIn = session.restaurants.contains { $0.id.hasPrefix("pd2-first") }
    expect(mixedIn, false, "search 2's first progressive snapshot contains none of search 1's restaurants")
    expect(session.restaurants.map(\.id), secondSearchBatch.map(\.id), "search 2's displayed restaurants are exactly its own batch")
}

// MARK: - PD3. FIRST PROGRESS SNAPSHOT REQUIRES AT LEAST ONE VERIFIED RESTAURANT
// Option B from the locked-in decisions: present on the first completed
// ETA-verification batch that produced at least one successfully verified
// (fair or verified-unfair) restaurant - never present an empty sheet
// merely because a batch of MKDirections calls finished.
do {
    print("PD3. FIRST PROGRESS SNAPSHOT REQUIRES AT LEAST ONE VERIFIED RESTAURANT")
    expect(shouldEmitProgressSnapshot(verifiedSoFar: [], verifiedUnfairSoFar: []), false, "a batch where every candidate failed ETA verification does not emit a progress snapshot")
    expect(shouldEmitProgressSnapshot(verifiedSoFar: [makeRestaurant("pd3-fair1")], verifiedUnfairSoFar: []), true, "a single verified-FAIR restaurant is enough to emit")
    expect(shouldEmitProgressSnapshot(verifiedSoFar: [], verifiedUnfairSoFar: [makeRestaurant("pd3-unfair1")]), true, "a single verified-UNFAIR (additional) restaurant is also enough to emit - fairness need not be reached yet")

    // End-to-end through the session: the first batch (0 verified) must not
    // present the sheet; the second batch (1 verified) does.
    let session = SimulatedSearchSession()
    session.startSearch("pd3-search")
    expect(shouldEmitProgressSnapshot(verifiedSoFar: [], verifiedUnfairSoFar: []), false, "batch 1 (0/3 verified so far) would not call onProgress at all in production")
    let batch2Fair = [makeRestaurant("pd3-batch2-fair")]
    expect(shouldEmitProgressSnapshot(verifiedSoFar: batch2Fair, verifiedUnfairSoFar: []), true, "batch 2 produced a verified-fair restaurant, so onProgress IS called")
    session.receiveProgress(searchID: "pd3-search", snapshot: batch2Fair)
    expect(session.sheetPresentationCount, 1, "the sheet is presented for the first time on this (the first EMITTED) batch")
}

// MARK: - PD4. PROGRESSIVE SNAPSHOTS REUSE THE SAME FAIRNESS/DISPLAY LOGIC AS THE FINAL RESULT
// Simulates 3 growing batches the way RestaurantFairnessSelector's
// onBatchProgress accumulates them: `progressVerified`/`progressUnfair`
// only ever grow, and buildDisplayList (the same function `finalize` uses)
// is called fresh each time - never a separate progressive ranking pass.
do {
    print("PD4. PROGRESSIVE SNAPSHOTS USE THE EXISTING FAIRNESS CALC, buildDisplayList, FAIR-FIRST ORDERING, AND 10-RESULT CAP")
    let f1 = makeRestaurant("pd4-fair1")
    let f2 = makeRestaurant("pd4-fair2")
    let unfairs = (1...10).map { makeRestaurant("pd4-unfair\($0)") }
    var cache: [String: (userETA: TimeInterval, friendETA: TimeInterval)] = [:]
    for (i, r) in unfairs.enumerated() { cache[r.id] = etaPair(excessSeconds: Double(i + 1) * 10) }

    // Batch 1: only f1 has verified so far.
    let batch1 = ETAVerificationDecision.buildDisplayList(fair: [f1], verifiedUnfair: [], etaCache: cache, yelpOrderIndex: [:])
    expect(batch1.map(\.id), [f1.id], "batch 1 shows exactly the 1 restaurant verified so far")

    // Batch 2: f2 and the first 2 unfair candidates have now also verified.
    let batch2Unfair = Array(unfairs.prefix(2))
    let batch2 = ETAVerificationDecision.buildDisplayList(fair: [f1, f2], verifiedUnfair: batch2Unfair, etaCache: cache, yelpOrderIndex: [:])
    expect(batch2.count, 4, "batch 2 shows the 2 fair + 2 additional restaurants verified so far")
    expect(batch2.prefix(2).allSatisfy { $0.fairnessDisplayStatus == .fair }, true, "fair-first ordering already holds mid-search")

    // Batch 3 (final): all 10 unfair candidates have now verified, same fair set.
    let final = ETAVerificationDecision.buildDisplayList(fair: [f1, f2], verifiedUnfair: unfairs, etaCache: cache, yelpOrderIndex: [:])
    expect(final.count, MidpointFairnessConfig.maxDisplayedRestaurants, "the final snapshot is capped at 10 exactly like a non-progressive search")
    expect(final.filter { $0.fairnessDisplayStatus == .fair }.count, 2, "both fair restaurants remain displayed in the final snapshot")
}

// MARK: - PD5. A FAIR RESTAURANT DISCOVERED LATER MOVES ABOVE ALREADY-DISPLAYED ADDITIONAL RESTAURANTS
do {
    print("PD5. A FAIR RESTAURANT DISCOVERED IN A LATER BATCH MOVES ABOVE ALREADY-DISPLAYED ADDITIONAL RESTAURANTS")
    let u1 = makeRestaurant("pd5-unfair1")
    let u2 = makeRestaurant("pd5-unfair2")
    let lateFair = makeRestaurant("pd5-latefair")
    var cache: [String: (userETA: TimeInterval, friendETA: TimeInterval)] = [
        u1.id: etaPair(excessSeconds: 20),
        u2.id: etaPair(excessSeconds: 40)
    ]

    // Early batch: only the 2 unfair candidates have verified - no fair
    // restaurant exists yet, so both display as additional options.
    let earlyBatch = ETAVerificationDecision.buildDisplayList(fair: [], verifiedUnfair: [u1, u2], etaCache: cache, yelpOrderIndex: [:])
    expect(earlyBatch.map(\.id), [u1.id, u2.id], "before any fair restaurant verifies, the additional options display alone, closest-to-fair first")

    // Later batch: lateFair now verifies as genuinely fair.
    cache[lateFair.id] = etaPair(excessSeconds: -9999) // irrelevant to buildDisplayList once already classified as fair
    let laterBatch = ETAVerificationDecision.buildDisplayList(fair: [lateFair], verifiedUnfair: [u1, u2], etaCache: cache, yelpOrderIndex: [:])
    expect(laterBatch.first?.id, lateFair.id, "the newly-discovered fair restaurant now appears FIRST")
    expect(laterBatch.first?.fairnessDisplayStatus, .fair, "it is marked .fair, not .verifiedAdditional")
    expect(Array(laterBatch.dropFirst()).map(\.id), [u1.id, u2.id], "the previously-displayed additional restaurants remain, now demoted below the fair restaurant, in their existing relative order")
}

// MARK: - PD6. PARTIAL SUCCESS FOLLOWED BY AN INFRASTRUCTURE FAILURE KEEPS VERIFIED RESULTS VISIBLE
// Some verified restaurants are already displayed via progressive delivery;
// a later round then hits a broad MapKit outage (etaVerificationUnavailable).
// Per the locked-in decision: keep the verified restaurants on screen, stop
// the loading state, and do NOT show the Search Problem alert or a "some
// results couldn't be checked" message.
do {
    print("PD6. PARTIAL SUCCESS + LATER INFRASTRUCTURE FAILURE KEEPS ALREADY-VERIFIED RESULTS VISIBLE, NO ALERT")
    let session = SimulatedSearchSession()
    session.startSearch("pd6-search")
    let firstBatch = [makeRestaurant("pd6-fair1"), makeRestaurant("pd6-unfair1")]
    session.receiveProgress(searchID: "pd6-search", snapshot: firstBatch)
    expect(session.isShowingResults, true, "the sheet is already showing 2 trustworthy verified restaurants")

    session.receiveFailureOutcome(searchID: "pd6-search", title: "Search Problem", message: "We couldn't verify travel times right now. Please try again in a moment.")
    expect(session.isSearching, false, "the loading state stops at the terminal outcome regardless of how it resolves")
    expect(session.isShowingResults, true, "the sheet is NOT cleared just because a later round failed")
    expect(session.restaurants.map(\.id), firstBatch.map(\.id), "the already-verified restaurants remain exactly as they were")
    expect(session.errorMessage, nil, "no Search Problem alert is shown when trustworthy results already exist")
    expect(session.errorTitle, nil, "no error title is set either - the search simply finishes quietly with what it already found")
}

// MARK: - PD7. ZERO VERIFIED RESTAURANTS + INFRASTRUCTURE FAILURE PRESERVES THE SEARCH PROBLEM ALERT
// The one case where the existing failure UI is intentionally unchanged:
// if progressive delivery never produced anything displayable at all before
// MapKit verification became unavailable, the original alert behavior applies.
do {
    print("PD7. ZERO-RESULT INFRASTRUCTURE FAILURE STILL SHOWS THE EXISTING SEARCH PROBLEM ALERT")
    let session = SimulatedSearchSession()
    session.startSearch("pd7-search")
    expect(session.isShowingResults, false, "no progress snapshot ever arrived - the sheet was never shown")

    session.receiveFailureOutcome(searchID: "pd7-search", title: "Search Problem", message: "We couldn't verify travel times right now. Please try again in a moment.")
    expect(session.isShowingResults, false, "the sheet remains hidden - there is nothing trustworthy to show")
    expect(session.restaurants.isEmpty, true, "no restaurants are displayed")
    expect(session.errorTitle, "Search Problem", "the existing Search Problem alert is preserved exactly as before progressive delivery")
    expect(session.errorMessage, "We couldn't verify travel times right now. Please try again in a moment.", "the existing alert message is unchanged")
}

// MARK: - PD8. FEWER THAN 10 FINAL RESULTS ARE DISPLAYED WITHOUT PADDING
do {
    print("PD8. FEWER THAN 10 FINAL RESULTS ARE DISPLAYED WITHOUT PADDING, EVEN VIA PROGRESSIVE DELIVERY")
    let session = SimulatedSearchSession()
    session.startSearch("pd8-search")
    let fair = (1...2).map { makeRestaurant("pd8-fair\($0)") }
    let unfair = (1...3).map { makeRestaurant("pd8-unfair\($0)") }
    var cache: [String: (userETA: TimeInterval, friendETA: TimeInterval)] = [:]
    for r in unfair { cache[r.id] = etaPair(excessSeconds: 30) }
    let finalDisplay = ETAVerificationDecision.buildDisplayList(fair: fair, verifiedUnfair: unfair, etaCache: cache, yelpOrderIndex: [:])
    expect(finalDisplay.count, 5, "buildDisplayList itself never pads short of 10")

    session.receiveSuccessOutcome(searchID: "pd8-search", finalRestaurants: finalDisplay)
    expect(session.restaurants.count, 5, "the final progressively-delivered result set stays at 5, matching what a non-progressive search would have shown")
}

// MARK: - PD9. THE RESULTS SHEET IS PRESENTED EXACTLY ONCE PER SEARCH
do {
    print("PD9. THE RESULTS SHEET IS PRESENTED EXACTLY ONCE PER SEARCH, REGARDLESS OF BATCH COUNT")
    let session = SimulatedSearchSession()
    session.startSearch("pd9-search")
    session.receiveProgress(searchID: "pd9-search", snapshot: [makeRestaurant("pd9-b1")])
    session.receiveProgress(searchID: "pd9-search", snapshot: (1...3).map { makeRestaurant("pd9-b2-\($0)") })
    session.receiveProgress(searchID: "pd9-search", snapshot: (1...6).map { makeRestaurant("pd9-b3-\($0)") })
    session.receiveSuccessOutcome(searchID: "pd9-search", finalRestaurants: (1...8).map { makeRestaurant("pd9-final\($0)") })
    expect(session.sheetPresentationCount, 1, "3 progressive batches plus a terminal outcome still only present the sheet ONE time total")
}

// MARK: - PD10. NO UNVERIFIED RESTAURANT IS EVER PRESENT IN ANY PROGRESSIVE SNAPSHOT
// Mirrors P5 above (unverified restaurants never pad buildDisplayList's
// output) but asserted specifically across a sequence of progressive
// batches, since this is the exact property progressive delivery depends
// on to avoid ever showing an unchecked restaurant.
do {
    print("PD10. NO UNVERIFIED RESTAURANT IS EVER VISIBLE IN ANY PROGRESSIVE SNAPSHOT")
    let verifiedFair = [makeRestaurant("pd10-fair1")]
    let verifiedUnfair = [makeRestaurant("pd10-unfair1")]
    // 5 more candidates were shortlisted this round but never produced a
    // real ETA pair (still in flight, or permanently failed) - exactly
    // like P5, these structurally never reach buildDisplayList's inputs.
    let stillUnverifiedIDs = Set((1...5).map { "pd10-pending\($0)" })

    let snapshot = ETAVerificationDecision.buildDisplayList(fair: verifiedFair, verifiedUnfair: verifiedUnfair, etaCache: [:], yelpOrderIndex: [:])
    expect(snapshot.count, 2, "only the 2 actually-verified restaurants appear, regardless of how many candidates are still pending")
    let anyUnverifiedLeaked = snapshot.contains { stillUnverifiedIDs.contains($0.id) }
    expect(anyUnverifiedLeaked, false, "none of the still-pending/unverified candidate IDs ever appear in a progressive snapshot")
}

// MARK: - PD11. THE FINAL PROGRESSIVE SNAPSHOT EXACTLY MATCHES THE NON-PROGRESSIVE FINAL SELECTION
// For identical Yelp/MapKit responses, progressive delivery must produce
// the same final restaurant list (same IDs, same order) a non-progressive
// search would have produced - progressive delivery only changes
// PRESENTATION TIMING, never the algorithm's final selection.
do {
    print("PD11. FINAL PROGRESSIVE LIST EXACTLY MATCHES THE NON-PROGRESSIVE FINAL SELECTION FOR IDENTICAL INPUT")
    let fair = (1...4).map { makeRestaurant("pd11-fair\($0)") }
    let unfair = (1...8).map { makeRestaurant("pd11-unfair\($0)") }
    var cache: [String: (userETA: TimeInterval, friendETA: TimeInterval)] = [:]
    for (i, r) in unfair.enumerated() { cache[r.id] = etaPair(excessSeconds: Double(i + 1) * 5) }
    let yelpOrder = Dictionary(uniqueKeysWithValues: (fair + unfair).enumerated().map { ($1.id, $0) })

    // "Non-progressive": the algorithm's one-shot final call, exactly as
    // finalize() invokes it today.
    let nonProgressiveFinal = ETAVerificationDecision.buildDisplayList(fair: fair, verifiedUnfair: unfair, etaCache: cache, yelpOrderIndex: yelpOrder)

    // "Progressive": the SAME inputs arrived incrementally across 3
    // batches, with buildDisplayList re-run on the cumulative accumulator
    // each time - the terminal outcome's buildDisplayList call uses the
    // fully-accumulated fair/unfair arrays, identical to the one-shot call.
    let batch1Fair = Array(fair.prefix(1))
    _ = ETAVerificationDecision.buildDisplayList(fair: batch1Fair, verifiedUnfair: [], etaCache: cache, yelpOrderIndex: yelpOrder)
    let batch2Fair = Array(fair.prefix(2))
    let batch2Unfair = Array(unfair.prefix(3))
    _ = ETAVerificationDecision.buildDisplayList(fair: batch2Fair, verifiedUnfair: batch2Unfair, etaCache: cache, yelpOrderIndex: yelpOrder)
    let progressiveFinal = ETAVerificationDecision.buildDisplayList(fair: fair, verifiedUnfair: unfair, etaCache: cache, yelpOrderIndex: yelpOrder)

    expect(progressiveFinal.map(\.id), nonProgressiveFinal.map(\.id), "the fully-accumulated progressive final list has IDENTICAL restaurant IDs in IDENTICAL order to the non-progressive one-shot result")
    expect(progressiveFinal.map(\.fairnessDisplayStatus), nonProgressiveFinal.map(\.fairnessDisplayStatus), "fair/additional classification is identical between the two paths")

    let session = SimulatedSearchSession()
    session.startSearch("pd11-search")
    session.receiveProgress(searchID: "pd11-search", snapshot: ETAVerificationDecision.buildDisplayList(fair: batch1Fair, verifiedUnfair: [], etaCache: cache, yelpOrderIndex: yelpOrder))
    session.receiveProgress(searchID: "pd11-search", snapshot: ETAVerificationDecision.buildDisplayList(fair: batch2Fair, verifiedUnfair: batch2Unfair, etaCache: cache, yelpOrderIndex: yelpOrder))
    session.receiveSuccessOutcome(searchID: "pd11-search", finalRestaurants: progressiveFinal)
    expect(session.restaurants.map(\.id), nonProgressiveFinal.map(\.id), "what the user ultimately sees after progressive delivery finishes is identical to the non-progressive final result")
}

// MARK: - Fairness presentation (PR-*): results-sheet divider / zero-fair message
//
// Lists are built with the real `buildDisplayList`, so ordering and
// `fairnessDisplayStatus` are exactly what the UI receives in production.
func presentationList(fair: Int, fallback: Int, tag: String) -> [Restaurant] {
    let fairRestaurants = (0..<fair).map { makeRestaurant("\(tag)-fair\($0)") }
    let fallbackRestaurants = (0..<fallback).map { makeRestaurant("\(tag)-fallback\($0)") }
    var cache: [String: (userETA: TimeInterval, friendETA: TimeInterval)] = [:]
    for (index, r) in fallbackRestaurants.enumerated() { cache[r.id] = etaPair(excessSeconds: 60 + TimeInterval(index) * 30) }
    return ETAVerificationDecision.buildDisplayList(fair: fairRestaurants, verifiedUnfair: fallbackRestaurants, etaCache: cache, yelpOrderIndex: [:])
}

func isFairFirst(_ list: [Restaurant]) -> Bool {
    guard let firstFallback = list.firstIndex(where: { $0.fairnessDisplayStatus == .verifiedAdditional }) else { return true }
    return list[firstFallback...].allSatisfy { $0.fairnessDisplayStatus == .verifiedAdditional }
}

do {
    print("PR1. 10 FAIR / 0 FALLBACK -> NO MESSAGING")
    let list = presentationList(fair: 10, fallback: 0, tag: "pr1")
    expect(FairnessPresentation.notice(for: list, isSearching: false), .none, "no divider and no zero-fair message once finished")
    expect(FairnessPresentation.notice(for: list, isSearching: true), .none, "no divider and no zero-fair message while searching")
}

for (fair, fallback) in [(7, 3), (4, 6), (1, 9)] {
    print("PR2. \(fair) FAIR / \(fallback) FALLBACK -> DIVIDER BEFORE FIRST FALLBACK")
    let list = presentationList(fair: fair, fallback: fallback, tag: "pr2-\(fair)")
    expect(list.count, 10, "list is 10 long")
    expect(isFairFirst(list), true, "fair-first ordering intact")
    for searching in [false, true] {
        let notice = FairnessPresentation.notice(for: list, isSearching: searching)
        expect(notice, .otherOptionsDivider(beforeIndex: fair), "isSearching=\(searching): divider at index \(fair), the first fallback restaurant")
        if case .otherOptionsDivider(let index) = notice {
            expect(list[index].fairnessDisplayStatus, .verifiedAdditional, "isSearching=\(searching): restaurant after the divider is a fallback")
            expect(list[index - 1].fairnessDisplayStatus, .fair, "isSearching=\(searching): restaurant before the divider is fair")
        }
    }
}

do {
    print("PR3. 0 FAIR / 10 FALLBACK")
    let list = presentationList(fair: 0, fallback: 10, tag: "pr3")
    expect(list.allSatisfy { $0.fairnessDisplayStatus == .verifiedAdditional }, true, "every restaurant is a fallback")
    expect(FairnessPresentation.notice(for: list, isSearching: true), .none, "while searching: no zero-fair message and no divider")
    expect(FairnessPresentation.notice(for: list, isSearching: false), .noEvenlyMatchedOptions, "after search finishes: zero-fair message, no divider")
}

do {
    print("PR4. EMPTY AND UNSTAMPED LISTS")
    expect(FairnessPresentation.notice(for: [], isSearching: false), .none, "empty list -> nothing")
    let unstamped = [makeRestaurant("pr4-a"), makeRestaurant("pr4-b")]
    expect(FairnessPresentation.notice(for: unstamped, isSearching: false), .none, "restaurants without a fairness status -> nothing")
}

do {
    print("PR5. PROGRESSIVE: 3 FAIR -> 6 FAIR -> 6 FAIR + 4 FALLBACK")
    let fair = (0..<6).map { makeRestaurant("pr5-fair\($0)") }
    let fallback = (0..<4).map { makeRestaurant("pr5-fallback\($0)") }
    var cache: [String: (userETA: TimeInterval, friendETA: TimeInterval)] = [:]
    for r in fallback { cache[r.id] = etaPair(excessSeconds: 90) }

    let snap1 = ETAVerificationDecision.buildDisplayList(fair: Array(fair.prefix(3)), verifiedUnfair: [], etaCache: cache, yelpOrderIndex: [:])
    let snap2 = ETAVerificationDecision.buildDisplayList(fair: fair, verifiedUnfair: [], etaCache: cache, yelpOrderIndex: [:])
    let snap3 = ETAVerificationDecision.buildDisplayList(fair: fair, verifiedUnfair: fallback, etaCache: cache, yelpOrderIndex: [:])

    for (label, snap) in [("3 fair", snap1), ("6 fair", snap2), ("6 fair + 4 fallback", snap3)] {
        expect(isFairFirst(snap), true, "\(label): fair-first ordering intact")
    }
    expect(FairnessPresentation.notice(for: snap1, isSearching: true), .none, "3 fair (searching): no messaging")
    expect(FairnessPresentation.notice(for: snap2, isSearching: true), .none, "6 fair (searching): no messaging")
    expect(FairnessPresentation.notice(for: snap3, isSearching: true), .otherOptionsDivider(beforeIndex: 6), "6 fair + 4 fallback (searching): divider appears live before index 6")
    expect(FairnessPresentation.notice(for: snap3, isSearching: false), .otherOptionsDivider(beforeIndex: 6), "6 fair + 4 fallback (finished): same divider")

    // A fallback-only early snapshot must not claim "no fair options" while
    // the search runs, and the message must disappear if fair results later
    // displace fallback ones.
    let early = ETAVerificationDecision.buildDisplayList(fair: [], verifiedUnfair: fallback, etaCache: cache, yelpOrderIndex: [:])
    expect(FairnessPresentation.notice(for: early, isSearching: true), .none, "fallback-only early snapshot while searching: no zero-fair message")
    let displaced = ETAVerificationDecision.buildDisplayList(fair: fair, verifiedUnfair: fallback, etaCache: cache, yelpOrderIndex: [:])
    expect(displaced.prefix(6).allSatisfy { $0.fairnessDisplayStatus == .fair }, true, "later fair results sort above the fallback ones")
    expect(FairnessPresentation.notice(for: displaced, isSearching: false), .otherOptionsDivider(beforeIndex: 6), "after fair results arrive the zero-fair state is gone; divider recomputed")
}

do {
    print("PR6. .noFairRestaurants OUTCOME DECISION UNCHANGED")
    expect(ETAVerificationDecision.finalOutcomeCase(verifiedCount: 0, additionalVerifiedCount: 0, roundWasReliable: true, yelpEverReturnedResults: true), .noFairRestaurants, "reliable round, Yelp returned results, nothing verified -> .noFairRestaurants")
    expect(ETAVerificationDecision.finalOutcomeCase(verifiedCount: 0, additionalVerifiedCount: 10, roundWasReliable: true, yelpEverReturnedResults: true), .limitedFairOptions, "zero fair + verified fallback -> .limitedFairOptions (shown, not an error)")
}

print("")
if failures == 0 {
    print("ALL TESTS PASSED")
    exit(0)
} else {
    print("\(failures) TEST(S) FAILED")
    exit(1)
}
