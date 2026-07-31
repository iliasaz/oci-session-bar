// Copyright 2026 Ilia Sazonov
// SPDX-License-Identifier: MIT

import Foundation
import Testing

@testable import OCISessionBar

@Suite("Session countdown and refresh timing")
struct SessionStatusTests {
  /// A one-hour session — the maximum OCI issues, and what the CLI creates.
  static func hourLong(issuedAt: Date) -> SessionStatus {
    SessionStatus(
      profile: "test",
      issuedAt: issuedAt,
      expiresAt: issuedAt.addingTimeInterval(3600)
    )
  }

  @Test(
    "The countdown reads h:mm at every magnitude",
    arguments: [
      (4_800.0, "1:20"),
      (3_600.0, "1:00"),
      (3_599.0, "0:59"),
      (420.0, "0:07"),
      (59.0, "0:00"),
      (0.0, "0:00"),
    ]
  )
  func formatsCountdown(remaining: TimeInterval, expected: String) {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let status = SessionStatus(
      profile: "test", issuedAt: now.addingTimeInterval(-600),
      expiresAt: now.addingTimeInterval(remaining)
    )
    #expect(status.countdownText(at: now) == expected)
  }

  /// The example from the brief: an hour and twenty minutes reads "1:20".
  @Test("Minutes are always two digits, so the item does not change width")
  func padsMinutes() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let status = SessionStatus(
      profile: "test", issuedAt: now, expiresAt: now.addingTimeInterval(3600 + 5 * 60)
    )
    #expect(status.countdownText(at: now) == "1:05")
  }

  @Test("An expired token never reports negative time")
  func clampsToZero() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let status = SessionStatus(
      profile: "test", issuedAt: now.addingTimeInterval(-7200),
      expiresAt: now.addingTimeInterval(-3600)
    )
    #expect(status.timeRemaining(at: now) == 0)
    #expect(status.remainingFraction(at: now) == 0)
    #expect(status.isValid(at: now) == false)
    #expect(status.countdownText(at: now) == "0:00")
  }

  @Test(
    "The red threshold is a tenth of the issued lifetime",
    arguments: [
      (0.0, false),  // just issued
      (0.5, false),  // half gone
      (0.89, false),  // 11% left
      (0.91, true),  // 9% left
      (1.0, true),  // expired
    ]
  )
  func criticalThreshold(elapsedFraction: Double, isCritical: Bool) {
    let issuedAt = Date(timeIntervalSince1970: 1_800_000_000)
    let status = Self.hourLong(issuedAt: issuedAt)
    let now = issuedAt.addingTimeInterval(3600 * elapsedFraction)
    #expect((status.remainingFraction(at: now) < 0.10) == isCritical)
  }

  /// The default threshold is 30 minutes left, which for the hour-long session OCI
  /// issues is exactly half-life — the behaviour this replaced.
  @Test("At the default threshold an hour-long session refreshes at half-life")
  func refreshesAtHalfLifeByDefault() {
    let issuedAt = Date(timeIntervalSince1970: 1_800_000_000)
    let status = Self.hourLong(issuedAt: issuedAt)
    let threshold = SessionStatus.defaultRefreshWhenRemaining

    #expect(status.needsRefresh(at: issuedAt, whenRemaining: threshold) == false)
    #expect(
      status.needsRefresh(at: issuedAt.addingTimeInterval(1799), whenRemaining: threshold) == false)
    #expect(
      status.needsRefresh(at: issuedAt.addingTimeInterval(1800), whenRemaining: threshold) == true)
    #expect(
      status.needsRefresh(at: issuedAt.addingTimeInterval(3000), whenRemaining: threshold) == true)
  }

  /// The point of making it configurable: a lower threshold pushes the refresh later
  /// and so spends fewer exchanges on a long session.
  @Test(
    "A lower threshold refreshes later",
    arguments: [
      (30.0, 1800.0),  // half-life
      (20.0, 2400.0),
      (15.0, 2700.0),  // three-quarter-life
      (10.0, 3000.0),
    ]
  )
  func lowerThresholdRefreshesLater(minutes: Double, firesAfter: TimeInterval) {
    let issuedAt = Date(timeIntervalSince1970: 1_800_000_000)
    let status = Self.hourLong(issuedAt: issuedAt)
    let threshold = minutes * 60

    #expect(
      status.needsRefresh(at: issuedAt.addingTimeInterval(firesAfter - 1), whenRemaining: threshold)
        == false)
    #expect(
      status.needsRefresh(at: issuedAt.addingTimeInterval(firesAfter), whenRemaining: threshold)
        == true)
  }

  /// A threshold longer than the session itself must not mean "always due". The
  /// 5-minute session used for live testing is exactly this case: 30 minutes left is
  /// past the moment it was issued, so without the clamp it would refresh every tick.
  @Test("A threshold longer than the session is clamped to half-life")
  func clampsThresholdToHalfLife() {
    let issuedAt = Date(timeIntervalSince1970: 1_800_000_000)
    let status = SessionStatus(
      profile: "test", issuedAt: issuedAt, expiresAt: issuedAt.addingTimeInterval(300)
    )
    let threshold = SessionStatus.defaultRefreshWhenRemaining  // 30 min, vs a 5 min session

    #expect(status.refreshPoint(whenRemaining: threshold) == 150)
    #expect(status.needsRefresh(at: issuedAt, whenRemaining: threshold) == false)
    #expect(
      status.needsRefresh(at: issuedAt.addingTimeInterval(149), whenRemaining: threshold) == false)
    #expect(
      status.needsRefresh(at: issuedAt.addingTimeInterval(150), whenRemaining: threshold) == true)
  }

  /// After a laptop sleeps through the refresh window, the next tick has to notice
  /// on its own — the schedule is recomputed from wall-clock, never from a timer
  /// that could have been missed.
  @Test("A long gap still reports the refresh as due")
  func survivesSleep() {
    let issuedAt = Date(timeIntervalSince1970: 1_800_000_000)
    let status = Self.hourLong(issuedAt: issuedAt)
    let afterSleep = issuedAt.addingTimeInterval(3500)
    #expect(
      status.needsRefresh(
        at: afterSleep, whenRemaining: SessionStatus.defaultRefreshWhenRemaining) == true)
    #expect(status.isValid(at: afterSleep) == true)
  }

  /// OCI always sends `iat`, but the 10% rule still needs a denominator without it.
  @Test("A token with no issued-at falls back to the maximum session length")
  func handlesMissingIssuedAt() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let status = SessionStatus(
      profile: "test", issuedAt: nil, expiresAt: now.addingTimeInterval(3600)
    )
    let threshold = SessionStatus.defaultRefreshWhenRemaining
    #expect(status.lifetime == 3600)
    #expect(status.remainingFraction(at: now) == 1.0)
    #expect(status.needsRefresh(at: now, whenRemaining: threshold) == false)
    #expect(status.needsRefresh(at: now.addingTimeInterval(1799), whenRemaining: threshold) == false)
    #expect(status.needsRefresh(at: now.addingTimeInterval(1800), whenRemaining: threshold) == true)
  }

  @Test("A nonsensical issued-at does not produce a zero or negative lifetime")
  func handlesIssuedAfterExpiry() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let status = SessionStatus(
      profile: "test", issuedAt: now.addingTimeInterval(600), expiresAt: now
    )
    #expect(status.lifetime > 0)
    #expect(status.remainingFraction(at: now) == 0)
  }

  /// The randomized window opens at half-life and closes five minutes before
  /// expiry, so on an hour-long token it is a 25-minute band.
  @Test("The randomized window runs from half-life to five minutes before expiry")
  func randomizedWindowSpansHalfLifeToLead() {
    let issuedAt = Date(timeIntervalSince1970: 1_800_000_000)
    let status = Self.hourLong(issuedAt: issuedAt)
    let window = status.randomizedRefreshWindow()
    // Half-life is 30 min in; five-minutes-before-expiry is 55 min in.
    #expect(window.lowerBound == issuedAt.addingTimeInterval(1800))
    #expect(window.upperBound == issuedAt.addingTimeInterval(3300))
  }

  /// A short session, where five-minutes-before-expiry falls *before* half-life,
  /// must still yield a non-empty range rather than an inverted one — the window
  /// collapses to the half-life instant.
  @Test("A session shorter than twice the lead collapses to the half-life instant")
  func randomizedWindowClampsForShortSession() {
    let issuedAt = Date(timeIntervalSince1970: 1_800_000_000)
    // A 5-minute session: half-life is 2m30s in, but exp - 5min is at issue.
    let status = SessionStatus(
      profile: "test", issuedAt: issuedAt, expiresAt: issuedAt.addingTimeInterval(300)
    )
    let window = status.randomizedRefreshWindow()
    #expect(window.lowerBound == issuedAt.addingTimeInterval(150))
    #expect(window.upperBound == window.lowerBound)
    #expect(window.lowerBound <= window.upperBound)
  }

  /// Every rolled instant, whatever the generator returns, lands inside the window
  /// and so never before half-life — the invariant the feature rests on.
  @Test("A rolled instant always falls within the window")
  func randomizedInstantStaysInWindow() {
    let issuedAt = Date(timeIntervalSince1970: 1_800_000_000)
    let status = Self.hourLong(issuedAt: issuedAt)
    let window = status.randomizedRefreshWindow()
    var generator = SeededGenerator(seed: 0x1234_5678)
    for _ in 0..<200 {
      let instant = status.randomizedRefreshInstant(using: &generator)
      #expect(instant >= window.lowerBound)
      #expect(instant <= window.upperBound)
    }
  }
}

/// A deterministic generator so a random-instant test replays the same sequence
/// every run rather than flaking on the system source.
struct SeededGenerator: RandomNumberGenerator {
  private var state: UInt64
  init(seed: UInt64) { state = seed == 0 ? 0x9E37_79B9_7F4A_7C15 : seed }
  mutating func next() -> UInt64 {
    // SplitMix64 — small, well-distributed, and enough for a bounds test.
    state &+= 0x9E37_79B9_7F4A_7C15
    var z = state
    z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
    z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
    return z ^ (z >> 31)
  }
}
