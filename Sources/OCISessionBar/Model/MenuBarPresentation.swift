// Copyright 2026 Ilia Sazonov
// SPDX-License-Identifier: MIT

import Foundation

/// What the menu bar item should show.
///
/// Modelled as three distinct cases rather than one string, because they are not
/// variations on a countdown: two of them have no time to count down *to*, and
/// rendering them as text ("—") says nothing about whether the session lapsed or
/// was never set up.
enum MenuBarPresentation: Equatable {
  /// A live session, with the time left and whether it is nearly over.
  case countdown(text: String, isCritical: Bool)

  /// A session that exists but is past its expiry.
  case expired

  /// No profile selected, or the selected profile has no readable session.
  case unconfigured

  /// The SF Symbol standing in for a state that has no countdown.
  ///
  /// `clock.badge.xmark` for a lapsed session — a clock that has run out is
  /// exactly what happened — and `key.slash` for one that was never established.
  var symbolName: String? {
    switch self {
    case .countdown: nil
    case .expired: "clock.badge.xmark"
    case .unconfigured: "key.slash"
    }
  }

  /// Whether the item should be drawn in the alert colour.
  ///
  /// `unconfigured` is deliberately *not* critical: nothing has gone wrong, the
  /// app simply has nothing to track yet.
  var isCritical: Bool {
    switch self {
    case .countdown(_, let isCritical): isCritical
    case .expired: true
    case .unconfigured: false
    }
  }

  /// Whether AppKit may recolor the item to match the menu bar.
  ///
  /// Only the neutral state allows it. Every other state carries meaning in its
  /// colour — green for healthy, red for trouble — and templating throws that
  /// away, repainting the image in the menu bar's own foreground colour.
  ///
  /// Note this is *not* the same question as ``isCritical``: a healthy countdown
  /// is not critical but is still green, so it must not be templated either.
  var usesTemplateRendering: Bool {
    switch self {
    case .countdown, .expired: false
    case .unconfigured: true
    }
  }

  /// Spoken by VoiceOver, and the fallback if a symbol is unavailable.
  var accessibilityDescription: String {
    switch self {
    case .countdown(let text, let isCritical):
      isCritical ? "OCI session expiring, \(text) remaining" : "OCI session, \(text) remaining"
    case .expired: "OCI session expired"
    case .unconfigured: "No OCI session"
    }
  }
}
