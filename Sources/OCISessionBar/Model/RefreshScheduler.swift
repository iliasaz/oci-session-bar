// Copyright 2026 Ilia Sazonov
// SPDX-License-Identifier: MIT

import Foundation

/// Exponential backoff for the background refresh.
///
/// A refresh that fails for a transient reason — the network is not up yet after a
/// wake, the auth service throttled the exchange — has to be retried, but retrying
/// on every one-second tick would hammer the service and drain the battery for the
/// whole half-life window there is to play with. Successive attempts are spaced by a
/// doubling delay, capped so even a long outage keeps getting a steady retry, and the
/// count is reset the moment a refresh succeeds.
nonisolated struct RefreshBackoff: Sendable, Equatable {
  /// Consecutive failures since the last success.
  private(set) var failures = 0

  /// The first retry waits this long; each further failure doubles it.
  static let base: TimeInterval = 2
  /// The longest any retry ever waits, so a prolonged outage still gets probed.
  static let cap: TimeInterval = 60

  /// How long to wait before the next attempt, given the failures seen so far.
  /// Zero while there have been none, so the first attempt is never delayed.
  var delay: TimeInterval {
    guard failures > 0 else { return 0 }
    // Shift rather than `pow` to keep it integer-exact, and clamp the exponent well
    // below `Int`'s width so a pathological failure streak cannot overflow.
    let doublings = min(failures - 1, 20)
    return min(Self.base * TimeInterval(1 << doublings), Self.cap)
  }

  mutating func recordFailure() { failures += 1 }
  mutating func reset() { failures = 0 }
}

/// Decides when the background refresh may next attempt, kept as a value so the
/// timing and retry rules can be exercised without a clock or a network.
///
/// ``AuthModel`` owns one of these and feeds it the tick's `now`. Every decision
/// here is a pure function of its inputs, which is what lets the retry behaviour be
/// tested by replaying a sequence of `Date`s rather than by waiting in real time.
nonisolated struct RefreshScheduler: Sendable, Equatable {
  private var backoff = RefreshBackoff()

  /// The earliest an attempt may start. Advanced past `now` by every failure, and
  /// dropped to the distant past by ``reset()`` so the next tick may act at once.
  private(set) var notBefore: Date = .distantPast

  /// Whether a refresh should start for `status` at `now`: the token has to be live,
  /// past its refresh point, and clear of any backoff left by an earlier failure.
  func shouldAttempt(_ status: SessionStatus, at now: Date) -> Bool {
    status.isValid(at: now) && status.needsRefresh(at: now) && now >= notBefore
  }

  /// Records a failed attempt at `now` and pushes the next one out by the backoff.
  mutating func recordFailure(at now: Date) {
    backoff.recordFailure()
    notBefore = now.addingTimeInterval(backoff.delay)
  }

  /// A refresh succeeded, or the token was replaced out of band: start clean, so the
  /// next tick that finds the token stale again may act without waiting.
  mutating func reset() {
    backoff.reset()
    notBefore = .distantPast
  }

  /// Consecutive failures since the last success, for tests and diagnostics.
  var failureCount: Int { backoff.failures }
}

/// Thrown by ``withTimeout(_:operation:)`` when the operation outlives its budget.
struct TimeoutError: LocalizedError {
  var errorDescription: String? { "The operation timed out." }
}

/// Runs `operation`, throwing ``TimeoutError`` if it has not finished within
/// `duration`.
///
/// A background refresh that hangs — a network black hole, a request that never
/// returns — would otherwise pin ``AuthModel``'s in-flight `work` non-nil forever and
/// silently stop every future auto-refresh. Bounding it turns that wedge into an
/// ordinary transient failure that the retry schedule picks up on the next tick.
nonisolated func withTimeout<T: Sendable>(
  _ duration: Swift.Duration,
  operation: @escaping @Sendable () async throws -> T
) async throws -> T {
  try await withThrowingTaskGroup(of: T.self) { group in
    group.addTask { try await operation() }
    group.addTask {
      try await Task.sleep(for: duration)
      throw TimeoutError()
    }
    defer { group.cancelAll() }
    // Two tasks were added, so the first to finish is never nil. Whichever it is —
    // the operation's result or the timeout's throw — the `defer` cancels the other.
    return try await group.next()!
  }
}
