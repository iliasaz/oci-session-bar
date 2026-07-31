// Copyright 2026 Ilia Sazonov
// SPDX-License-Identifier: MIT

import Foundation
import OCIKit

/// A snapshot of one profile's session token, derived entirely from the JWT on
/// disk. Constructing this makes no network call.
nonisolated struct SessionStatus: Sendable, Equatable {
  let profile: String
  let issuedAt: Date?
  let expiresAt: Date

  /// The lifetime the token was issued for. OCI session tokens always carry `iat`,
  /// but a token without one still needs a denominator for the "10% left" rule, and
  /// the service's maximum session length is the honest assumption.
  var lifetime: TimeInterval {
    guard let issuedAt else { return TimeInterval(SessionTokenClient.maximumSessionMinutes * 60) }
    let span = expiresAt.timeIntervalSince(issuedAt)
    return span > 0 ? span : TimeInterval(SessionTokenClient.maximumSessionMinutes * 60)
  }

  func isValid(at now: Date) -> Bool { expiresAt > now }

  func timeRemaining(at now: Date) -> TimeInterval {
    max(0, expiresAt.timeIntervalSince(now))
  }

  /// How much of the issued lifetime is left, 0...1. Drives the red threshold.
  func remainingFraction(at now: Date) -> Double {
    max(0, min(1, timeRemaining(at: now) / lifetime))
  }

  /// When the background refresh fires, expressed as time left on the token.
  ///
  /// The default matches the old fixed behaviour for the one-hour session OCI
  /// normally issues: 30 minutes left *is* that token's half-life.
  static let defaultRefreshWhenRemaining: TimeInterval = 30 * 60

  /// The point this token actually refreshes at, given a configured threshold.
  ///
  /// Half-life is not a service deadline — `/authentication/refresh` extends a token
  /// at any point while it is still valid — so the trigger is a free choice, and
  /// pushing it later means fewer exchanges over a long session. It is only ever
  /// clamped *later*, never earlier: a 30-minute threshold against the 5-minute
  /// session used for testing would otherwise be past the moment it was issued and
  /// refresh continuously, so a token always keeps at least half its life first.
  func refreshPoint(whenRemaining threshold: TimeInterval) -> TimeInterval {
    min(threshold, lifetime / 2)
  }

  /// Past its refresh point — see ``refreshPoint(whenRemaining:)`` for why the
  /// threshold cannot pull the refresh in front of half-life.
  func needsRefresh(at now: Date, whenRemaining threshold: TimeInterval) -> Bool {
    timeRemaining(at: now) <= refreshPoint(whenRemaining: threshold)
  }

  /// The margin kept before expiry when a refresh is scheduled at a random point:
  /// the chosen instant never falls later than five minutes before the token
  /// expires, so a refresh still has room to land and, if it fails, to back off and
  /// retry before the session lapses.
  static let randomizedRefreshLead: TimeInterval = 5 * 60

  /// The span a randomized refresh may fire in: from the half-life instant to
  /// `max(halfLife, exp - lead)`.
  ///
  /// Expressed in time-remaining terms like ``refreshPoint(whenRemaining:)`` so it
  /// does not lean on `iat` being present — the half-life instant is
  /// `exp - lifetime/2`. The upper bound is clamped up to half-life so a short
  /// session, where `exp - lead` falls *before* half-life, still yields a
  /// non-empty range rather than an inverted one.
  func randomizedRefreshWindow(lead: TimeInterval = Self.randomizedRefreshLead) -> ClosedRange<Date> {
    let halfLife = expiresAt.addingTimeInterval(-lifetime / 2)
    let latest = max(halfLife, expiresAt.addingTimeInterval(-lead))
    return halfLife...latest
  }

  /// A random instant within ``randomizedRefreshWindow(lead:)``.
  ///
  /// The generator is injected so a test can replay a fixed sequence; production
  /// passes `SystemRandomNumberGenerator`. Rolled once per token by the caller —
  /// re-rolling every tick would move the target constantly and never fire.
  func randomizedRefreshInstant<G: RandomNumberGenerator>(
    lead: TimeInterval = Self.randomizedRefreshLead, using generator: inout G
  ) -> Date {
    let window = randomizedRefreshWindow(lead: lead)
    let span = window.upperBound.timeIntervalSince(window.lowerBound)
    guard span > 0 else { return window.lowerBound }
    return window.lowerBound.addingTimeInterval(.random(in: 0...span, using: &generator))
  }

  init(profile: String, container: SecurityTokenContainer) {
    self.profile = profile
    self.issuedAt = container.issuedAtDate
    self.expiresAt = container.expiresAt
  }

  init(profile: String, issuedAt: Date?, expiresAt: Date) {
    self.profile = profile
    self.issuedAt = issuedAt
    self.expiresAt = expiresAt
  }
}

#if DEBUG
  extension SessionStatus {
    /// Anchored to `.now` so previews always render a live-looking countdown.
    private static func preview(issuedMinutesAgo: Double, lifetimeMinutes: Double) -> SessionStatus {
      let issuedAt = Date.now.addingTimeInterval(-issuedMinutesAgo * 60)
      return SessionStatus(
        profile: "jroga-token",
        issuedAt: issuedAt,
        expiresAt: issuedAt.addingTimeInterval(lifetimeMinutes * 60)
      )
    }

    /// Plenty of time left — the green case. Reads "1:20".
    static let previewHealthy = preview(issuedMinutesAgo: 10, lifetimeMinutes: 90)

    /// Under a tenth of the lifetime remaining — the red case.
    static let previewCritical = preview(issuedMinutesAgo: 57, lifetimeMinutes: 60)

    /// Past `exp`, which is what a session looks like after a laptop wakes up.
    static let previewExpired = preview(issuedMinutesAgo: 120, lifetimeMinutes: 60)
  }
#endif

extension SessionStatus {
  /// `"1:20"` for an hour and twenty minutes; `"0:07"` for seven minutes. Matches
  /// the format the user asked for, and stays two components at every magnitude so
  /// the menu bar item does not change width every hour.
  func countdownText(at now: Date) -> String {
    let total = Int(timeRemaining(at: now).rounded(.down))
    let minutes = (total % 3600) / 60
    return "\(total / 3600):\(minutes.formatted(.number.grouping(.never).precision(.integerLength(2))))"
  }
}
