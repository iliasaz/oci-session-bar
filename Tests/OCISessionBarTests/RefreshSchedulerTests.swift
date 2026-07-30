// Copyright 2026 Ilia Sazonov
// SPDX-License-Identifier: MIT

import Foundation
import Testing

@testable import OCISessionBar

@Suite("Refresh backoff")
struct RefreshBackoffTests {
  @Test("The first attempt is never delayed")
  func firstAttemptIsImmediate() {
    #expect(RefreshBackoff().delay == 0)
  }

  /// The delay doubles with each consecutive failure, then holds at the cap so even a
  /// long outage keeps getting a steady probe instead of drifting to hours apart.
  ///
  /// It starts at two minutes, not seconds: an attempt already had a full minute to
  /// answer before it counted as failed.
  @Test(
    "The delay doubles per failure and then holds at the cap",
    arguments: [
      (1, 120.0),  // 2 min
      (2, 240.0),  // 4 min
      (3, 480.0),  // 8 min
      (4, 600.0),  // 16 min clamped to the 10 min cap
      (5, 600.0),
      (20, 600.0),
    ]
  )
  func doublesThenCaps(failures: Int, expected: TimeInterval) {
    var backoff = RefreshBackoff()
    for _ in 0..<failures { backoff.recordFailure() }
    #expect(backoff.delay == expected)
    #expect(backoff.failures == failures)
  }

  /// A pathological failure streak must not overflow the shift, just stay pinned at
  /// the cap.
  @Test("A huge failure count stays at the cap without overflowing")
  func doesNotOverflow() {
    var backoff = RefreshBackoff()
    for _ in 0..<1000 { backoff.recordFailure() }
    #expect(backoff.delay == RefreshBackoff.cap)
  }

  @Test("A success clears the failure count")
  func resetClears() {
    var backoff = RefreshBackoff()
    backoff.recordFailure()
    backoff.recordFailure()
    backoff.reset()
    #expect(backoff.failures == 0)
    #expect(backoff.delay == 0)
  }
}

@Suite("Refresh scheduler")
struct RefreshSchedulerTests {
  static let issuedAt = Date(timeIntervalSince1970: 1_800_000_000)

  /// A one-hour session, the maximum OCI issues.
  static func hourLong() -> SessionStatus {
    SessionStatus(
      profile: "test", issuedAt: issuedAt, expiresAt: issuedAt.addingTimeInterval(3600)
    )
  }

  /// The 5-minute session `oci session authenticate
  /// --session-expiration-in-minutes 5` mints, used for live testing. Its refresh
  /// point is half-life — 2m30s left — because the threshold clamps.
  static func fiveMinute() -> SessionStatus {
    SessionStatus(
      profile: "test", issuedAt: issuedAt, expiresAt: issuedAt.addingTimeInterval(300)
    )
  }

  /// The default: refresh with 30 minutes left, which on an hour-long token is
  /// half-life.
  static let threshold = SessionStatus.defaultRefreshWhenRemaining

  /// A time comfortably past the refresh point but well before expiry.
  static var pastRefreshPoint: Date { issuedAt.addingTimeInterval(1800) }

  @Test("Attempts once the token is past its refresh point")
  func attemptsWhenStale() {
    let scheduler = RefreshScheduler()
    let status = Self.hourLong()
    #expect(
      scheduler.shouldAttempt(status, at: Self.issuedAt, whenRemaining: Self.threshold) == false)
    #expect(
      scheduler.shouldAttempt(status, at: Self.pastRefreshPoint, whenRemaining: Self.threshold)
        == true)
  }

  @Test("Never attempts once the token has expired")
  func neverAttemptsExpired() {
    let scheduler = RefreshScheduler()
    let status = Self.hourLong()
    #expect(
      scheduler.shouldAttempt(
        status, at: Self.issuedAt.addingTimeInterval(4000), whenRemaining: Self.threshold) == false)
  }

  /// A short session must not be treated as permanently due just because the
  /// threshold is longer than the whole token — the case the live test exercises.
  @Test("A 5-minute session refreshes at its own half-life, not immediately")
  func shortSessionRefreshesAtHalfLife() {
    let scheduler = RefreshScheduler()
    let status = Self.fiveMinute()
    #expect(
      scheduler.shouldAttempt(status, at: Self.issuedAt, whenRemaining: Self.threshold) == false)
    #expect(
      scheduler.shouldAttempt(
        status, at: Self.issuedAt.addingTimeInterval(149), whenRemaining: Self.threshold) == false)
    #expect(
      scheduler.shouldAttempt(
        status, at: Self.issuedAt.addingTimeInterval(150), whenRemaining: Self.threshold) == true)
  }

  /// The heart of the retry: a failure spaces the next attempt out rather than
  /// letting the one-second tick pound the service.
  @Test("A failure holds off the next attempt until the backoff elapses")
  func failureBacksOff() {
    var scheduler = RefreshScheduler()
    let status = Self.hourLong()
    let t = Self.pastRefreshPoint

    #expect(scheduler.shouldAttempt(status, at: t, whenRemaining: Self.threshold) == true)
    scheduler.recordFailure(at: t)  // first failure → 2 min backoff

    #expect(
      scheduler.shouldAttempt(status, at: t.addingTimeInterval(119), whenRemaining: Self.threshold)
        == false)
    #expect(
      scheduler.shouldAttempt(status, at: t.addingTimeInterval(120), whenRemaining: Self.threshold)
        == true)
  }

  /// Replaying a run of failures: each waits longer than the last, exactly as the
  /// backoff dictates, without any real time passing.
  @Test("Consecutive failures widen the gap between attempts")
  func consecutiveFailuresWiden() {
    var scheduler = RefreshScheduler()
    let status = Self.hourLong()
    var t = Self.pastRefreshPoint

    // Fail at t, then at each point the schedule next allows, and confirm the gap
    // grows 2, 4, 8 minutes then holds at the 10-minute cap.
    for expectedGap: TimeInterval in [120, 240, 480, 600] {
      #expect(scheduler.shouldAttempt(status, at: t, whenRemaining: Self.threshold) == true)
      scheduler.recordFailure(at: t)
      #expect(
        scheduler.shouldAttempt(
          status, at: t.addingTimeInterval(expectedGap - 1), whenRemaining: Self.threshold) == false)
      t = t.addingTimeInterval(expectedGap)
      #expect(scheduler.shouldAttempt(status, at: t, whenRemaining: Self.threshold) == true)
    }
    #expect(scheduler.failureCount == 4)
  }

  @Test("A success resets the schedule so the next stale tick may act at once")
  func successResets() {
    var scheduler = RefreshScheduler()
    let status = Self.hourLong()
    let t = Self.pastRefreshPoint

    scheduler.recordFailure(at: t)
    scheduler.recordFailure(at: t)  // 4 min backoff pending
    #expect(
      scheduler.shouldAttempt(status, at: t.addingTimeInterval(60), whenRemaining: Self.threshold)
        == false)

    scheduler.reset()  // refresh finally succeeded (or the token was replaced)
    #expect(scheduler.failureCount == 0)
    #expect(
      scheduler.shouldAttempt(status, at: t.addingTimeInterval(60), whenRemaining: Self.threshold)
        == true)
  }

  /// The full failing-then-recovering arc the feature exists for: several transient
  /// failures, spaced by a widening backoff, then a success that clears everything.
  @Test("A transient outage retries with backoff, then recovers cleanly")
  func outageThenRecovery() {
    var scheduler = RefreshScheduler()
    let status = Self.hourLong()
    var t = Self.pastRefreshPoint

    #expect(scheduler.shouldAttempt(status, at: t, whenRemaining: Self.threshold) == true)
    scheduler.recordFailure(at: t)  // network down
    t = t.addingTimeInterval(120)
    #expect(scheduler.shouldAttempt(status, at: t, whenRemaining: Self.threshold) == true)
    scheduler.recordFailure(at: t)  // still down
    t = t.addingTimeInterval(240)
    #expect(scheduler.shouldAttempt(status, at: t, whenRemaining: Self.threshold) == true)

    scheduler.reset()  // this attempt succeeds
    #expect(scheduler.failureCount == 0)
  }

  /// Observed live against a real 5-minute session: every refresh came back with the
  /// same `exp` and a fresh `iat`, so the apparent lifetime halved each time and the
  /// next refresh fell due twice as soon — 149s left, 74s, 36s, 18s, 8s, 3s, 1s.
  /// Seven exchanges in the last two and a half minutes, none of which bought a
  /// second. Detecting the first one ends it.
  @Test("A refresh that does not extend the session stops the spin")
  func stopsWhenRefreshBuysNothing() {
    var scheduler = RefreshScheduler()
    let expiry = Self.issuedAt.addingTimeInterval(300)
    // The token was replaced, but `exp` did not move: the session is at its end.
    let halved = SessionStatus(
      profile: "test", issuedAt: Self.issuedAt.addingTimeInterval(150), expiresAt: expiry
    )

    scheduler.recordSuccess(previousExpiry: expiry, newExpiry: expiry)

    #expect(scheduler.isAtSessionCeiling)
    // Past its (now halved) half-life, and still refused.
    #expect(
      scheduler.shouldAttempt(
        halved, at: Self.issuedAt.addingTimeInterval(225), whenRemaining: Self.threshold) == false)
  }

  /// The ordinary case, and the one that must not be mistaken for a ceiling. A
  /// browser-created session slides: refreshing returns `exp = now + lifetime`, so
  /// the gain is however long was spent before asking. Measured against a real
  /// federated session — refreshed 427s after issue, `exp` moved out by exactly
  /// 427s. At the default trigger that gain is half an hour, against a 30-second
  /// ceiling threshold, so there is no chance of confusing the two.
  @Test("A refresh that genuinely extends the session keeps going")
  func continuesWhenRefreshExtends() {
    var scheduler = RefreshScheduler()
    let previous = Self.issuedAt.addingTimeInterval(3600)
    let extended = previous.addingTimeInterval(1800)
    let status = SessionStatus(
      profile: "test", issuedAt: Self.issuedAt.addingTimeInterval(1800), expiresAt: extended
    )

    scheduler.recordSuccess(previousExpiry: previous, newExpiry: extended)

    #expect(scheduler.isAtSessionCeiling == false)
    #expect(
      scheduler.shouldAttempt(status, at: extended.addingTimeInterval(-600), whenRemaining: 15 * 60)
        == true)
  }

  /// The first refresh of a session has nothing to compare against, so it must not
  /// be mistaken for one that bought no time.
  @Test("A first refresh with no previous expiry counts as progress")
  func firstRefreshCountsAsProgress() {
    var scheduler = RefreshScheduler()
    scheduler.recordSuccess(
      previousExpiry: nil, newExpiry: Self.issuedAt.addingTimeInterval(3600))
    #expect(scheduler.isAtSessionCeiling == false)
  }

  /// Minting a new session is exactly the thing that escapes the ceiling, so the
  /// flag must not outlive it.
  @Test("A new session clears the ceiling")
  func newSessionClearsCeiling() {
    var scheduler = RefreshScheduler()
    let expiry = Self.issuedAt.addingTimeInterval(300)
    scheduler.recordSuccess(previousExpiry: expiry, newExpiry: expiry)
    #expect(scheduler.isAtSessionCeiling)

    scheduler.reset()
    #expect(scheduler.isAtSessionCeiling == false)
    #expect(
      scheduler.shouldAttempt(
        Self.hourLong(), at: Self.pastRefreshPoint, whenRemaining: Self.threshold) == true)
  }

  /// A lower threshold pushes the refresh later, so the same clock that was due at
  /// half-life is not yet due at three-quarter-life.
  @Test("The threshold moves the attempt point")
  func thresholdMovesAttemptPoint() {
    let scheduler = RefreshScheduler()
    let status = Self.hourLong()
    let atHalfLife = Self.pastRefreshPoint

    #expect(scheduler.shouldAttempt(status, at: atHalfLife, whenRemaining: 30 * 60) == true)
    #expect(scheduler.shouldAttempt(status, at: atHalfLife, whenRemaining: 15 * 60) == false)
    #expect(
      scheduler.shouldAttempt(
        status, at: Self.issuedAt.addingTimeInterval(2700), whenRemaining: 15 * 60) == true)
  }
}

@Suite("Timeout guard")
struct WithTimeoutTests {
  @Test("A fast operation returns its value")
  func returnsValueInTime() async throws {
    let value = try await withTimeout(.seconds(10)) {
      try await Task.sleep(for: .milliseconds(1))
      return 42
    }
    #expect(value == 42)
  }

  /// The point of the guard: an operation that would hang is abandoned rather than
  /// pinning the caller open forever. The slow task is generous so the assertion is
  /// about the timeout firing, not about a tight race.
  @Test("An operation that outlives its budget throws TimeoutError")
  func throwsOnOverrun() async {
    await #expect(throws: TimeoutError.self) {
      try await withTimeout(.milliseconds(20)) {
        try await Task.sleep(for: .seconds(10))
        return 0
      }
    }
  }

  @Test("An error from the operation propagates unchanged")
  func propagatesOperationError() async {
    struct Boom: Error {}
    await #expect(throws: Boom.self) {
      try await withTimeout(.seconds(10)) {
        throw Boom()
      }
    }
  }
}
