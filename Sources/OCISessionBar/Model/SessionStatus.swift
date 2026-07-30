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

  /// How far before the exact half-life the background refresh first fires.
  ///
  /// OCI's `/authentication/refresh` extends a token at any point while it is still
  /// valid, so this lead is not about a server-side deadline — it is margin. Firing a
  /// touch *before* the midpoint means a refresh that is briefly refused (a network
  /// not yet up on wake, a throttled exchange) is retried while nearly a full
  /// half-life of runway still remains, rather than starting the retry clock only
  /// once the midpoint has already slipped past.
  static let refreshLead: TimeInterval = 60

  /// Past its refresh point — a short lead before half-life (see ``refreshLead``),
  /// which is roughly where the SDK itself considers a token stale. Refreshing here
  /// leaves most of a half-lifetime of margin to retry in if the exchange fails.
  func needsRefresh(at now: Date) -> Bool {
    guard let issuedAt else { return timeRemaining(at: now) < lifetime / 2 + Self.refreshLead }
    return now >= issuedAt.addingTimeInterval(lifetime / 2 - Self.refreshLead)
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
