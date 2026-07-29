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

  @Test("Refresh is due exactly at half-life, not before")
  func refreshesAtHalfLife() {
    let issuedAt = Date(timeIntervalSince1970: 1_800_000_000)
    let status = Self.hourLong(issuedAt: issuedAt)

    #expect(status.needsRefresh(at: issuedAt) == false)
    #expect(status.needsRefresh(at: issuedAt.addingTimeInterval(1799)) == false)
    #expect(status.needsRefresh(at: issuedAt.addingTimeInterval(1800)) == true)
    #expect(status.needsRefresh(at: issuedAt.addingTimeInterval(3000)) == true)
  }

  /// After a laptop sleeps through the refresh window, the next tick has to notice
  /// on its own — the schedule is recomputed from wall-clock, never from a timer
  /// that could have been missed.
  @Test("A long gap still reports the refresh as due")
  func survivesSleep() {
    let issuedAt = Date(timeIntervalSince1970: 1_800_000_000)
    let status = Self.hourLong(issuedAt: issuedAt)
    let afterSleep = issuedAt.addingTimeInterval(3500)
    #expect(status.needsRefresh(at: afterSleep) == true)
    #expect(status.isValid(at: afterSleep) == true)
  }

  /// OCI always sends `iat`, but the 10% rule still needs a denominator without it.
  @Test("A token with no issued-at falls back to the maximum session length")
  func handlesMissingIssuedAt() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let status = SessionStatus(
      profile: "test", issuedAt: nil, expiresAt: now.addingTimeInterval(3600)
    )
    #expect(status.lifetime == 3600)
    #expect(status.remainingFraction(at: now) == 1.0)
    #expect(status.needsRefresh(at: now) == false)
    #expect(status.needsRefresh(at: now.addingTimeInterval(1801)) == true)
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
}
