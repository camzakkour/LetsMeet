//
//  SearchCancellationToken.swift
//  LetsMeet
//

import Foundation

/// Per-search, cooperative cancellation flag. Pure Foundation (no MapKit or
/// CoreLocation) so `Scripts/decision_logic_tests.swift` can compile and
/// exercise it directly.
///
/// Cancelling only means "don't START anything further": a request that is
/// already in flight is left to finish on its own (nothing here aborts an
/// `MKDirections`, `URLSessionTask` or geocoder), and each pipeline stage
/// simply checks `SearchCancellationGate.shouldContinue` before scheduling
/// its next request, batch, retry or round. A cancelled search ends silently
/// - it never produces an outcome, an error, or a failure/circuit-breaker
/// count - so `HomeViewModel`'s `activeSearchID` guards stay as the UI-side
/// defense in depth.
///
/// One token per search, owned by `HomeViewModel` and passed down as a plain
/// parameter. It is never stored on a shared singleton, so cancelling
/// Search A can never affect Search B. Checks happen from MapKit, URLSession
/// and main-queue completion contexts, hence the lock.
final class SearchCancellationToken {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    /// Monotonic and idempotent: once cancelled, always cancelled.
    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }
}

/// The single "may this search schedule more work?" decision, so every
/// pipeline gate asks the same question the same way.
enum SearchCancellationGate {
    static func shouldContinue(_ token: SearchCancellationToken) -> Bool {
        !token.isCancelled
    }
}
