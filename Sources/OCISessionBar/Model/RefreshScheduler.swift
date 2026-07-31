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
  ///
  /// Two minutes rather than seconds: an attempt is already given a full minute to
  /// answer (``AuthModel/refreshTimeout``), so a failure means the service or the
  /// network is genuinely unwell, not momentarily busy. Retrying seconds later would
  /// just spend the refresh window on requests that were never going to land.
  static let base: TimeInterval = 2 * 60
  /// The longest any retry ever waits, so a prolonged outage still gets probed
  /// several times across a typical refresh window rather than drifting to hours.
  static let cap: TimeInterval = 10 * 60

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

  /// Set when a refresh came back expiring no later than the token it replaced.
  ///
  /// A session has its own end, fixed when it was created, and a refresh can only
  /// move the *token* up to it — never past. Once there, every further exchange
  /// returns the same `exp` with a fresh `iat`, which halves the token's apparent
  /// lifetime and so halves the time to the next refresh. Measured against a real
  /// 5-minute session, the tail ran 149s left, 74s, 36s, 18s, 8s, 3s, 1s — seven
  /// exchanges in the last two and a half minutes, none of which bought a second.
  /// A 5-minute session is only the ordinary end-of-session case in miniature.
  /// Refreshing stops here and the session is allowed to lapse into the
  /// re-authentication path, which is the only thing that can actually help.
  private(set) var isAtSessionCeiling = false

  /// Whether a refresh should start for `status` at `now`: the token has to be live,
  /// past its refresh point, and clear of any backoff left by an earlier failure.
  ///
  /// Nothing here guards against *overlapping* attempts — that is ``AuthModel``'s
  /// single in-flight `work` task, which is what actually makes "never retry while a
  /// request is still outstanding" true. The backoff clock only starts once an
  /// attempt has finished and failed.
  func shouldAttempt(
    _ status: SessionStatus, at now: Date, whenRemaining threshold: TimeInterval
  ) -> Bool {
    shouldAttempt(status, at: now, due: status.needsRefresh(at: now, whenRemaining: threshold))
  }

  /// As ``shouldAttempt(_:at:whenRemaining:)`` but with the "past its refresh point"
  /// decision supplied by the caller.
  ///
  /// The randomized schedule decides due-ness from a rolled random instant rather
  /// than a fixed threshold, but the ceiling, validity and backoff guards are
  /// identical — so both paths share them here rather than duplicating the rule.
  func shouldAttempt(_ status: SessionStatus, at now: Date, due: Bool) -> Bool {
    !isAtSessionCeiling
      && status.isValid(at: now)
      && due
      && now >= notBefore
  }

  /// The least a refresh must push `exp` out to count as having achieved anything.
  ///
  /// Nothing legitimate lands near this line: a refresh that genuinely extends the
  /// session buys minutes, and one against a session at its end buys exactly zero.
  /// The margin is only here so clock skew between the token's clock and ours cannot
  /// read as a tiny gain and restart the spin.
  static let minimumUsefulExtension: TimeInterval = 30

  /// What a successful refresh actually achieved, so the caller can say so.
  ///
  /// Returned rather than logged from here: this type stays a pure value so the
  /// timing rules can be replayed against a synthetic clock in tests, and a `Logger`
  /// inside it would make every one of those a source of Console noise.
  enum Outcome: Sendable, Equatable {
    /// The session moved out by a useful amount. The gain is carried so it can be
    /// logged even when nothing is wrong — a tenancy whose gains are unexpectedly
    /// small should be visible before it becomes a ceiling.
    case extended(by: TimeInterval)
    /// The refresh succeeded but bought nothing: the session is at its end.
    case atCeiling(gain: TimeInterval)
    /// Nothing to compare against, so nothing can be concluded.
    case firstRefresh
    /// The expiry barely moved, but so little time passed since the last refresh
    /// that it could not have moved much anyway. Says nothing either way.
    case tooSoonToTell(gain: TimeInterval, elapsed: TimeInterval)
  }

  /// Records a successful refresh, and reports whether it actually bought any time.
  ///
  /// `previous` is the token this one replaced; `nil` when there was nothing to
  /// compare against, which counts as progress.
  ///
  /// A small gain on its own does **not** mean the session is capped. Refreshing
  /// slides the expiry to `now + lifetime`, so the gain equals the time elapsed since
  /// the previous refresh: press Refresh Session twice five seconds apart on a
  /// perfectly healthy session and the second one gains five seconds. Concluding
  /// "ceiling" from that would switch off auto-refresh for a session with a full
  /// lifetime left and most of a day of refreshes still available. So the gain is
  /// only read as a ceiling once enough time has passed for it to have moved — at the
  /// real thing the gain is *exactly* zero however long you wait, because the expiry
  /// is pinned to a fixed session end.
  @discardableResult
  mutating func recordSuccess(previous: SessionStatus?, refreshed: SessionStatus) -> Outcome {
    reset()
    guard let previous else { return .firstRefresh }
    let gain = refreshed.expiresAt.timeIntervalSince(previous.expiresAt)
    guard gain < Self.minimumUsefulExtension else { return .extended(by: gain) }

    // OCI always stamps `iat`; if one is somehow missing, fall through to the gain
    // alone rather than never concluding anything and spinning forever.
    if let before = previous.issuedAt, let after = refreshed.issuedAt {
      let elapsed = after.timeIntervalSince(before)
      guard elapsed >= Self.minimumUsefulExtension else {
        return .tooSoonToTell(gain: gain, elapsed: elapsed)
      }
    }

    isAtSessionCeiling = true
    return .atCeiling(gain: gain)
  }

  /// Records a failed attempt at `now` and pushes the next one out by the backoff.
  mutating func recordFailure(at now: Date) {
    backoff.recordFailure()
    notBefore = now.addingTimeInterval(backoff.delay)
  }

  /// A new session is in play — refreshed, re-minted, or replaced out of band — so
  /// start clean and let the next tick that finds it stale act without waiting.
  mutating func reset() {
    backoff.reset()
    notBefore = .distantPast
    isAtSessionCeiling = false
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
