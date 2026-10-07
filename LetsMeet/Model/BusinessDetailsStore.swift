//
//  BusinessDetailsStore.swift
//  LetsMeet
//

import Foundation

/// Retention rule for Yelp-originated data cached in memory. Yelp's API terms
/// limit caching to about 24 hours; 12 hours leaves a margin for an app that
/// sits suspended. Nothing is persisted, so a relaunch always starts empty.
enum YelpCachePolicy {
    static let maxAge: TimeInterval = 12 * 60 * 60

    /// An entry is fresh only if it was stored in the past and less than
    /// `maxAge` ago. A stored-at time in the future (the clock was moved back)
    /// counts as expired rather than keeping the entry alive indefinitely.
    static func isFresh(storedAt: Date, now: Date, maxAge: TimeInterval = YelpCachePolicy.maxAge) -> Bool {
        let age = now.timeIntervalSince(storedAt)
        return age >= 0 && age < maxAge
    }
}

/// Thread-safe, expiring cache with in-flight request coalescing, one entry
/// per ID. It owns no networking: the caller asks `begin` what to do, performs
/// the request itself if told to, then reports back through `finish`.
///
/// `begin` decides "fresh hit / join an in-flight request / start a request"
/// in one critical section, and `finish` stores a success and removes the
/// in-flight entry in one critical section, so a concurrent `begin` can never
/// observe the gap between the two (a duplicate request) or register a
/// completion after the in-flight entry was already taken (a lost completion).
/// Completions are never invoked while the lock is held; `finish` returns them
/// for the caller to run.
final class BusinessDetailsStore<Value, Failure: Error> {
    typealias Completion = (Result<Value, Failure>) -> Void

    enum Begin {
        /// A fresh cached value. The completion was NOT registered; the
        /// caller invokes it with this value.
        case cached(Value)
        /// A request for this ID is already in flight; the completion was
        /// registered and will be returned by that request's `finish`.
        case joined
        /// No fresh value and nothing in flight. The completion was
        /// registered; the caller must start the request and call `finish`.
        case startRequest
    }

    private struct Entry {
        let value: Value
        let storedAt: Date
    }

    private let lock = NSLock()
    private let maxAge: TimeInterval
    private let now: () -> Date
    private var entries: [String: Entry] = [:]
    private var inFlight: [String: [Completion]] = [:]

    init(maxAge: TimeInterval = YelpCachePolicy.maxAge, now: @escaping () -> Date = Date.init) {
        self.maxAge = maxAge
        self.now = now
    }

    func begin(id: String, completion: @escaping Completion) -> Begin {
        lock.lock()
        defer { lock.unlock() }

        removeExpiredLocked()

        if let entry = entries[id] {
            return .cached(entry.value)
        }
        if inFlight[id] != nil {
            inFlight[id]?.append(completion)
            return .joined
        }
        inFlight[id] = [completion]
        return .startRequest
    }

    /// Completes the request for `id`, caching a success (a failure is never
    /// cached), and returns every completion that was waiting on it.
    func finish(id: String, result: Result<Value, Failure>) -> [Completion] {
        lock.lock()
        defer { lock.unlock() }

        if case .success(let value) = result {
            entries[id] = Entry(value: value, storedAt: now())
        }
        return inFlight.removeValue(forKey: id) ?? []
    }

    /// Drops every expired entry. `begin` already does this on each call.
    func sweepExpired() {
        lock.lock()
        defer { lock.unlock() }
        removeExpiredLocked()
    }

    var cachedCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return entries.count
    }

    var inFlightCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return inFlight.count
    }

    private func removeExpiredLocked() {
        let current = now()
        entries = entries.filter { YelpCachePolicy.isFresh(storedAt: $0.value.storedAt, now: current, maxAge: maxAge) }
    }
}
