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
  @Test(
    "The delay doubles per failure and then holds at the cap",
    arguments: [
      (1, 2.0),
      (2, 4.0),
      (3, 8.0),
      (4, 16.0),
      (5, 32.0),
      (6, 60.0),  // 64 clamped to the 60s cap
      (7, 60.0),
      (20, 60.0),
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

  /// A time comfortably past the refresh point but well before expiry.
  static var pastRefreshPoint: Date { issuedAt.addingTimeInterval(1800) }

  @Test("Attempts once the token is past its refresh point")
  func attemptsWhenStale() {
    let scheduler = RefreshScheduler()
    let status = Self.hourLong()
    #expect(scheduler.shouldAttempt(status, at: Self.issuedAt) == false)  // fresh
    #expect(scheduler.shouldAttempt(status, at: Self.pastRefreshPoint) == true)
  }

  @Test("Never attempts once the token has expired")
  func neverAttemptsExpired() {
    let scheduler = RefreshScheduler()
    let status = Self.hourLong()
    #expect(scheduler.shouldAttempt(status, at: Self.issuedAt.addingTimeInterval(4000)) == false)
  }

  /// The heart of the retry: a failure spaces the next attempt out rather than
  /// letting the one-second tick pound the service.
  @Test("A failure holds off the next attempt until the backoff elapses")
  func failureBacksOff() {
    var scheduler = RefreshScheduler()
    let status = Self.hourLong()
    let t = Self.pastRefreshPoint

    #expect(scheduler.shouldAttempt(status, at: t) == true)
    scheduler.recordFailure(at: t)  // first failure → 2s backoff

    #expect(scheduler.shouldAttempt(status, at: t.addingTimeInterval(1)) == false)
    #expect(scheduler.shouldAttempt(status, at: t.addingTimeInterval(2)) == true)
  }

  /// Replaying a run of failures: each waits longer than the last, exactly as the
  /// backoff dictates, without any real time passing.
  @Test("Consecutive failures widen the gap between attempts")
  func consecutiveFailuresWiden() {
    var scheduler = RefreshScheduler()
    let status = Self.hourLong()
    var t = Self.pastRefreshPoint

    // Fail at t, then at each point the schedule next allows, and confirm the gap
    // grows 2, 4, 8, 16 as the backoff doubles.
    for expectedGap: TimeInterval in [2, 4, 8, 16] {
      #expect(scheduler.shouldAttempt(status, at: t) == true)
      scheduler.recordFailure(at: t)
      #expect(scheduler.shouldAttempt(status, at: t.addingTimeInterval(expectedGap - 1)) == false)
      t = t.addingTimeInterval(expectedGap)
      #expect(scheduler.shouldAttempt(status, at: t) == true)
    }
    #expect(scheduler.failureCount == 4)
  }

  @Test("A success resets the schedule so the next stale tick may act at once")
  func successResets() {
    var scheduler = RefreshScheduler()
    let status = Self.hourLong()
    let t = Self.pastRefreshPoint

    scheduler.recordFailure(at: t)
    scheduler.recordFailure(at: t)  // 4s backoff pending
    #expect(scheduler.shouldAttempt(status, at: t.addingTimeInterval(1)) == false)

    scheduler.reset()  // refresh finally succeeded (or the token was replaced)
    #expect(scheduler.failureCount == 0)
    #expect(scheduler.shouldAttempt(status, at: t.addingTimeInterval(1)) == true)
  }

  /// The full failing-then-recovering arc the feature exists for: several transient
  /// failures, spaced by a widening backoff, then a success that clears everything.
  @Test("A transient outage retries with backoff, then recovers cleanly")
  func outageThenRecovery() {
    var scheduler = RefreshScheduler()
    let status = Self.hourLong()
    var t = Self.pastRefreshPoint

    #expect(scheduler.shouldAttempt(status, at: t) == true)
    scheduler.recordFailure(at: t)  // network down
    t = t.addingTimeInterval(2)
    #expect(scheduler.shouldAttempt(status, at: t) == true)
    scheduler.recordFailure(at: t)  // still down
    t = t.addingTimeInterval(4)
    #expect(scheduler.shouldAttempt(status, at: t) == true)

    scheduler.reset()  // this attempt succeeds
    #expect(scheduler.failureCount == 0)
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
