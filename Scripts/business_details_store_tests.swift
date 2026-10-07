//
// Deterministic tests for BusinessDetailsStore - the lock-protected,
// expiring Business Details cache and in-flight request coalescer behind
// YelpManager.fetchBusinessDetails - and the YelpCachePolicy freshness rule
// shared with the photo cache. No network and no real waiting: the clock is
// injected, and the concurrency tests assert invariants that hold for EVERY
// interleaving (exactly one request started, every completion fired exactly
// once) rather than relying on timing. The state-transition tests run first
// and single-threaded, so they are fully deterministic on their own.
//
// This is a standalone script, NOT part of the LetsMeet Xcode target (see
// decision_logic_tests.swift for why). It only needs Foundation, so it runs
// directly on macOS (staged as literally "main.swift" so top-level code is
// allowed). Add -sanitize=thread to also check for data races:
//   cp Scripts/business_details_store_tests.swift /tmp/main.swift && \
//   swiftc -o /tmp/business_details_store_tests [-sanitize=thread] \
//     LetsMeet/Model/BusinessDetailsStore.swift \
//     /tmp/main.swift \
//     && /tmp/business_details_store_tests

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

struct TestFailure: Error, Equatable {}

typealias Store = BusinessDetailsStore<Int, TestFailure>

/// Thread-safe tally of how many times each numbered completion fired.
final class Tally {
    private let lock = NSLock()
    private var counts: [Int: Int] = [:]
    func record(_ index: Int) {
        lock.lock(); counts[index, default: 0] += 1; lock.unlock()
    }
    func count(for index: Int) -> Int {
        lock.lock(); defer { lock.unlock() }
        return counts[index, default: 0]
    }
    var totalFirings: Int {
        lock.lock(); defer { lock.unlock() }
        return counts.values.reduce(0, +)
    }
    var distinctFired: Int {
        lock.lock(); defer { lock.unlock() }
        return counts.count
    }
}

final class Counter {
    private let lock = NSLock()
    private var value = 0
    func increment() { lock.lock(); value += 1; lock.unlock() }
    var current: Int { lock.lock(); defer { lock.unlock() }; return value }
}

/// A clock the tests move by hand.
final class TestClock {
    var current = Date(timeIntervalSinceReferenceDate: 1_000_000)
    func advance(_ seconds: TimeInterval) { current = current.addingTimeInterval(seconds) }
}

func noop(_ result: Result<Int, TestFailure>) {}

func isStart(_ b: Store.Begin) -> Bool { if case .startRequest = b { return true } else { return false } }
func isJoined(_ b: Store.Begin) -> Bool { if case .joined = b { return true } else { return false } }
func cachedValue(_ b: Store.Begin) -> Int? { if case .cached(let v) = b { return v } else { return nil } }

// MARK: - Policy

print("YelpCachePolicy")
do {
    expect(YelpCachePolicy.maxAge, 12 * 60 * 60, "default retention is exactly 12 hours")
    let t0 = Date(timeIntervalSinceReferenceDate: 5_000)
    expect(YelpCachePolicy.isFresh(storedAt: t0, now: t0), true, "age 0 is fresh")
    expect(YelpCachePolicy.isFresh(storedAt: t0, now: t0.addingTimeInterval(12 * 3600 - 1)), true, "1s before 12h is fresh")
    expect(YelpCachePolicy.isFresh(storedAt: t0, now: t0.addingTimeInterval(12 * 3600)), false, "exactly 12h is expired")
    expect(YelpCachePolicy.isFresh(storedAt: t0, now: t0.addingTimeInterval(24 * 3600)), false, "24h is expired")
    expect(YelpCachePolicy.isFresh(storedAt: t0, now: t0.addingTimeInterval(-1)), false, "stored-at in the future (clock moved back) is expired")
}

// MARK: - State transitions (single-threaded, deterministic)

print("\nCoalescing and caching transitions")
do {
    let store = Store()
    let tally = Tally()

    let first = store.begin(id: "A") { _ in tally.record(1) }
    let second = store.begin(id: "A") { _ in tally.record(2) }
    let third = store.begin(id: "A") { _ in tally.record(3) }
    expect(isStart(first), true, "first caller for an ID starts the request")
    expect(isJoined(second), true, "second caller joins the in-flight request")
    expect(isJoined(third), true, "third caller joins the in-flight request")
    expect(store.inFlightCount, 1, "one in-flight entry for the three callers")
    expect(store.cachedCount, 0, "nothing cached before the request finishes")
    expect(tally.totalFirings, 0, "no completion fires before finish")

    let waiting = store.finish(id: "A", result: .success(42))
    expect(waiting.count, 3, "finish hands back all three waiting completions")
    expect(store.inFlightCount, 0, "in-flight entry removed on finish")
    expect(store.cachedCount, 1, "success is cached on finish")
    waiting.forEach { $0(.success(42)) }
    expect(tally.count(for: 1), 1, "completion 1 fired exactly once")
    expect(tally.count(for: 2), 1, "completion 2 fired exactly once")
    expect(tally.count(for: 3), 1, "completion 3 fired exactly once")

    let hit = store.begin(id: "A") { _ in tally.record(99) }
    expect(cachedValue(hit), 42, "fresh cache hit returns the cached value synchronously")
    expect(store.inFlightCount, 0, "a cache hit registers nothing in flight")
    expect(tally.count(for: 99), 0, "a cache hit does not store/fire the caller's completion itself")
}

print("\nDifferent IDs stay independent")
do {
    let store = Store()
    let a = store.begin(id: "A", completion: noop)
    let b = store.begin(id: "B", completion: noop)
    let a2 = store.begin(id: "A", completion: noop)
    expect(isStart(a) && isStart(b), true, "each distinct ID starts its own request")
    expect(isJoined(a2), true, "a second caller joins only its own ID's request")
    expect(store.inFlightCount, 2, "two IDs in flight")

    let forB = store.finish(id: "B", result: .success(2))
    expect(forB.count, 1, "finishing B returns only B's completion")
    expect(store.inFlightCount, 1, "A is still in flight after B finishes")
    expect(cachedValue(store.begin(id: "B", completion: noop)), 2, "B is now cached")
    expect(isJoined(store.begin(id: "A", completion: noop)), true, "A still coalesces")
    let forA = store.finish(id: "A", result: .success(1))
    expect(forA.count, 3, "A's three waiting completions come back together")
}

print("\nFailure is not cached, retry starts a new request")
do {
    let store = Store()
    let tally = Tally()
    expect(isStart(store.begin(id: "A") { _ in tally.record(1) }), true, "request starts")
    expect(isJoined(store.begin(id: "A") { _ in tally.record(2) }), true, "second caller joins")

    let waiting = store.finish(id: "A", result: .failure(TestFailure()))
    expect(waiting.count, 2, "a failure still returns every waiting completion")
    waiting.forEach { $0(.failure(TestFailure())) }
    expect(tally.totalFirings, 2, "both completions fired once on failure")
    expect(store.cachedCount, 0, "no cache entry is created for a failure")
    expect(store.inFlightCount, 0, "in-flight entry removed on failure")

    expect(isStart(store.begin(id: "A", completion: noop)), true, "retry after failure starts a fresh request")
    let retried = store.finish(id: "A", result: .success(7))
    expect(retried.count, 1, "retry's completion is returned")
    expect(store.cachedCount, 1, "retry success is cached")
}

print("\nTTL expiration (injected clock)")
do {
    let clock = TestClock()
    let store = Store(maxAge: 100, now: { clock.current })
    _ = store.begin(id: "A", completion: noop)
    _ = store.finish(id: "A", result: .success(5))

    clock.advance(99)
    expect(cachedValue(store.begin(id: "A", completion: noop)), 5, "just before the TTL the entry is a hit")

    clock.advance(1)
    expect(store.cachedCount, 1, "expiry is lazy: entry still stored until looked at or swept")
    expect(isStart(store.begin(id: "A", completion: noop)), true, "at the TTL the entry is a miss and a new request starts")
    expect(store.cachedCount, 0, "the expired entry was removed")
    let refreshed = store.finish(id: "A", result: .success(6))
    expect(refreshed.count, 1, "refetch completion returned")
    expect(cachedValue(store.begin(id: "A", completion: noop)), 6, "refetched value replaces the expired one with a fresh timestamp")

    clock.advance(-1_000)
    expect(isStart(store.begin(id: "A", completion: noop)), true, "an entry stored 'in the future' (clock moved back) is a miss")
}

print("\nExpiration sweep")
do {
    let clock = TestClock()
    let store = Store(maxAge: 100, now: { clock.current })
    _ = store.begin(id: "old", completion: noop)
    _ = store.finish(id: "old", result: .success(1))
    clock.advance(60)
    _ = store.begin(id: "newer", completion: noop)
    _ = store.finish(id: "newer", result: .success(2))
    expect(store.cachedCount, 2, "two entries before the sweep")

    clock.advance(60)   // old is 120s, newer is 60s
    store.sweepExpired()
    expect(store.cachedCount, 1, "sweep removes only the expired entry")
    expect(cachedValue(store.begin(id: "newer", completion: noop)), 2, "the unexpired entry survives the sweep")
    expect(isStart(store.begin(id: "old", completion: noop)), true, "the swept entry is a miss")

    // `begin` sweeps by itself: an unrelated expired entry goes away on any call.
    let clock2 = TestClock()
    let store2 = Store(maxAge: 100, now: { clock2.current })
    _ = store2.begin(id: "x", completion: noop)
    _ = store2.finish(id: "x", result: .success(1))
    clock2.advance(200)
    _ = store2.begin(id: "y", completion: noop)
    expect(store2.cachedCount, 0, "begin() for another ID also sweeps expired entries")
}

// MARK: - Concurrency

print("\nMany simultaneous callers, same ID")
do {
    let callers = 400
    let store = Store()
    let tally = Tally()
    let starts = Counter()
    let hits = Counter()
    let finisherQueue = DispatchQueue(label: "finisher")
    let group = DispatchGroup()

    DispatchQueue.concurrentPerform(iterations: callers) { i in
        switch store.begin(id: "A", completion: { _ in tally.record(i) }) {
        case .startRequest:
            starts.increment()
            // Complete from another thread, like a URLSession callback.
            group.enter()
            finisherQueue.asyncAfter(deadline: .now() + .milliseconds(5)) {
                store.finish(id: "A", result: .success(1)).forEach { $0(.success(1)) }
                group.leave()
            }
        case .joined:
            break
        case .cached:
            hits.increment()
            tally.record(i)   // the caller runs its own completion on a cache hit
        }
    }
    group.wait()

    expect(starts.current, 1, "exactly one request started for \(callers) simultaneous callers")
    expect(tally.distinctFired, callers, "every one of the \(callers) completions fired")
    var exactlyOnce = true
    for i in 0..<callers where tally.count(for: i) != 1 { exactlyOnce = false }
    expect(exactlyOnce, true, "every completion fired exactly once")
    expect(store.inFlightCount, 0, "nothing left in flight")
    expect(store.cachedCount, 1, "one cached entry")
}

print("\nBegin/finish race window")
do {
    // Many threads call begin for one ID while whichever thread is told to
    // start the request finishes it immediately, so begin and finish
    // interleave in every possible order. For a single ID whose request
    // succeeds, EVERY interleaving must yield: exactly one request started
    // (no duplicate between in-flight removal and cache insertion) and every
    // completion fired exactly once (none lost to a missed in-flight entry).
    let rounds = 600
    let workers = 16
    var roundsWithDuplicateStart = 0
    var roundsWithLostOrDoubledCompletion = 0

    for _ in 0..<rounds {
        let store = Store()
        let tally = Tally()
        let starts = Counter()

        DispatchQueue.concurrentPerform(iterations: workers) { i in
            switch store.begin(id: "A", completion: { _ in tally.record(i) }) {
            case .startRequest:
                starts.increment()
                store.finish(id: "A", result: .success(1)).forEach { $0(.success(1)) }
            case .joined:
                break
            case .cached:
                tally.record(i)
            }
        }

        if starts.current != 1 { roundsWithDuplicateStart += 1 }
        var allOnce = tally.distinctFired == workers
        for i in 0..<workers where tally.count(for: i) != 1 { allOnce = false }
        if !allOnce || store.inFlightCount != 0 { roundsWithLostOrDoubledCompletion += 1 }
    }
    expect(roundsWithDuplicateStart, 0, "no duplicate request in any of \(rounds) interleaved rounds")
    expect(roundsWithLostOrDoubledCompletion, 0, "no lost or doubled completion in any of \(rounds) interleaved rounds")
}

print("\nSimultaneous different IDs")
do {
    let ids = 60
    let perID = 8
    let store = Store()
    let tally = Tally()
    let startsPerID = (0..<ids).map { _ in Counter() }

    DispatchQueue.concurrentPerform(iterations: ids * perID) { n in
        let id = n % ids
        switch store.begin(id: "id\(id)", completion: { _ in tally.record(n) }) {
        case .startRequest:
            startsPerID[id].increment()
            store.finish(id: "id\(id)", result: .success(id)).forEach { $0(.success(id)) }
        case .joined:
            break
        case .cached:
            tally.record(n)
        }
    }

    expect(startsPerID.filter { $0.current == 1 }.count, ids, "each of \(ids) IDs started exactly one request")
    expect(tally.distinctFired, ids * perID, "all \(ids * perID) completions fired")
    var exactlyOnce = true
    for n in 0..<(ids * perID) where tally.count(for: n) != 1 { exactlyOnce = false }
    expect(exactlyOnce, true, "every completion fired exactly once across IDs")
    expect(store.cachedCount, ids, "one cache entry per ID")
    expect(store.inFlightCount, 0, "nothing left in flight")
}

print("")
if failures == 0 {
    print("ALL TESTS PASSED")
    exit(0)
} else {
    print("\(failures) TEST(S) FAILED")
    exit(1)
}
