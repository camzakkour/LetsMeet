//
//  LegSchedulerState.swift
//  LetsMeet
//

import Foundation

/// Per-search, per-restaurant-ID leg bookkeeping shared across the primary
/// ETA-verification pass and the one bounded recovery pass in
/// `RestaurantFairnessSelector.verifyBatched`. Pure Foundation, no MapKit or
/// CoreLocation dependency - deliberately factored out (mirroring
/// `ETAVerificationDecision`) so the per-leg attempt budget and concurrency
/// bookkeeping can be exercised directly by deterministic tests (see
/// `Scripts/decision_logic_tests.swift`) without a live MapKit call or an
/// XCTest target. `RestaurantFairnessSelector` is the only production
/// caller; it supplies real restaurant IDs and real MapKit results.
///
/// This is the single source of truth for "how many attempts has this leg
/// used" and "is it still eligible for another one" - there is exactly ONE
/// coherent budget per leg (`MidpointFairnessConfig.maxAttemptsPerLeg`) for
/// the whole search, never a separate budget per pass. A leg that already
/// succeeded is never re-attempted just because its sibling leg on the same
/// restaurant is still pending.
///
/// All mutable state is serialized onto a private queue. The only callers of
/// the mutating methods are `RestaurantFairnessSelector.runPass`'s
/// `MKDirections.calculateETA` completion closures, and Apple does not
/// document those completions as landing on any single, consistent thread -
/// so without this serialization, two legs completing at the same moment
/// (even just the 2 legs of a single candidate) could race on the same
/// dictionary entry or on the shared counters below.
final class LegSchedulerState {
    private final class RestaurantProgress {
        var userETA: TimeInterval?
        var friendETA: TimeInterval?
        // Route distance (meters), recorded alongside ETA from the same
        // MapKit route result - not a separate request. Nil whenever the
        // corresponding ETA is nil.
        var userDistance: Double?
        var friendDistance: Double?
        var userAttempts: Int = 0
        var friendAttempts: Int = 0
        // Set false the moment a leg fails with a non-transient error - such
        // a leg is never retried again regardless of remaining budget,
        // matching `RestaurantFairnessSelector.isTransientMapKitFailure`.
        var userEligible: Bool = true
        var friendEligible: Bool = true
    }

    private let syncQueue = DispatchQueue(label: "com.letsmeet.legSchedulerState")
    private var progress: [String: RestaurantProgress] = [:]
    private var _totalRequests = 0
    private var _currentInFlight = 0
    private var _maxObservedConcurrency = 0

    init(ids: [String]) {
        for id in ids {
            progress[id] = RestaurantProgress()
        }
    }

    private func withState<T>(_ body: (inout [String: RestaurantProgress]) -> T) -> T {
        syncQueue.sync { body(&progress) }
    }

    /// Total MapKit ETA requests made so far for this search, across both
    /// passes.
    var totalRequests: Int { syncQueue.sync { _totalRequests } }

    /// High-water mark of concurrent in-flight ETA requests observed so far
    /// for this search.
    var maxObservedConcurrency: Int { syncQueue.sync { _maxObservedConcurrency } }

    func userLegPending(_ id: String) -> Bool {
        withState { progress in
            guard let p = progress[id] else { return false }
            return p.userETA == nil && p.userEligible && p.userAttempts < MidpointFairnessConfig.maxAttemptsPerLeg
        }
    }

    func friendLegPending(_ id: String) -> Bool {
        withState { progress in
            guard let p = progress[id] else { return false }
            return p.friendETA == nil && p.friendEligible && p.friendAttempts < MidpointFairnessConfig.maxAttemptsPerLeg
        }
    }

    /// Whether either leg for `id` still has budget/eligibility remaining
    /// and hasn't yet succeeded.
    func isPending(_ id: String) -> Bool {
        userLegPending(id) || friendLegPending(id)
    }

    /// Marks the start of one leg's MapKit request: bumps its attempt
    /// count, the search's total request count, and the current in-flight
    /// count (updating the search's max-observed-concurrency high-water
    /// mark). Returns `(attemptNumber, inFlightAfterStart)` so callers can
    /// log both without a second synchronized read.
    func beginUserAttempt(_ id: String) -> (attempt: Int, inFlight: Int) {
        syncQueue.sync {
            progress[id]?.userAttempts += 1
            _totalRequests += 1
            _currentInFlight += 1
            _maxObservedConcurrency = max(_maxObservedConcurrency, _currentInFlight)
            return (progress[id]?.userAttempts ?? 0, _currentInFlight)
        }
    }

    func beginFriendAttempt(_ id: String) -> (attempt: Int, inFlight: Int) {
        syncQueue.sync {
            progress[id]?.friendAttempts += 1
            _totalRequests += 1
            _currentInFlight += 1
            _maxObservedConcurrency = max(_maxObservedConcurrency, _currentInFlight)
            return (progress[id]?.friendAttempts ?? 0, _currentInFlight)
        }
    }

    /// Marks one leg's MapKit request as finished (success or failure),
    /// freeing its in-flight slot. Returns the in-flight count after this
    /// completion, for diagnostics.
    func endAttempt() -> Int {
        syncQueue.sync {
            _currentInFlight -= 1
            return _currentInFlight
        }
    }

    func recordUserSuccess(_ id: String, eta: TimeInterval, distance: Double? = nil) {
        withState { $0[id]?.userETA = eta; $0[id]?.userDistance = distance }
    }
    func recordFriendSuccess(_ id: String, eta: TimeInterval, distance: Double? = nil) {
        withState { $0[id]?.friendETA = eta; $0[id]?.friendDistance = distance }
    }

    func recordUserFailure(_ id: String, transient: Bool) { withState { $0[id]?.userEligible = transient } }
    func recordFriendFailure(_ id: String, transient: Bool) { withState { $0[id]?.friendEligible = transient } }

    func userAttempts(_ id: String) -> Int { withState { $0[id]?.userAttempts ?? 0 } }
    func friendAttempts(_ id: String) -> Int { withState { $0[id]?.friendAttempts ?? 0 } }
    func userBudgetRemaining(_ id: String) -> Bool { userAttempts(id) < MidpointFairnessConfig.maxAttemptsPerLeg }
    func friendBudgetRemaining(_ id: String) -> Bool { friendAttempts(id) < MidpointFairnessConfig.maxAttemptsPerLeg }

    func userETA(_ id: String) -> TimeInterval? { withState { $0[id]?.userETA } }
    func friendETA(_ id: String) -> TimeInterval? { withState { $0[id]?.friendETA } }

    func verifiedResults() -> [String: (userETA: TimeInterval, friendETA: TimeInterval)] {
        withState { progress in
            var out: [String: (userETA: TimeInterval, friendETA: TimeInterval)] = [:]
            for (id, p) in progress {
                if let u = p.userETA, let f = p.friendETA {
                    out[id] = (u, f)
                }
            }
            return out
        }
    }

    /// Route distances (meters) for display only - never consulted by any
    /// fairness decision. Only includes a restaurant once both legs' routes
    /// resolved with a distance.
    func verifiedDistances() -> [String: (userDistance: Double, friendDistance: Double)] {
        withState { progress in
            var out: [String: (userDistance: Double, friendDistance: Double)] = [:]
            for (id, p) in progress {
                if let u = p.userDistance, let f = p.friendDistance {
                    out[id] = (u, f)
                }
            }
            return out
        }
    }
}
