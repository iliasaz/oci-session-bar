// Copyright 2026 Ilia Sazonov
// SPDX-License-Identifier: MIT

import AppKit
import OSLog

/// Keeps a tooltip on the menu bar item, so hovering shows the session's status
/// without having to open the menu.
///
/// `MenuBarExtra` exposes no handle on its `NSStatusItem`, and its label is
/// rasterized into the status button, so `.help()` on the label view does not
/// reliably reach it. The button is therefore located through the status bar
/// window the app owns — every status item lives in an `NSStatusBarWindow` in its
/// own process, so this only ever finds ours — and its `toolTip` is set directly.
/// That is the same `NSView.toolTip` mechanism `.help()` drives, just reached
/// explicitly.
@MainActor
enum StatusItemTooltip {
  private static let logger = Logger(subsystem: "com.iliasaz.OCISessionBar", category: "tooltip")

  /// The text last successfully applied, so the view hierarchy is only searched
  /// when the tooltip actually changes — roughly once a minute, not every tick.
  private static var applied: String?

  /// Logged once, so a failure to find the button is diagnosable without a line
  /// of noise every second forever.
  private static var hasReportedMissingButton = false

  static func apply(_ text: String) {
    guard text != applied else { return }
    guard let button = statusBarButton() else {
      if !hasReportedMissingButton {
        hasReportedMissingButton = true
        // Not fatal: the status item may simply not exist yet at first tick, and
        // the next change tries again.
        logger.debug("No status bar button found yet; tooltip deferred")
      }
      return
    }
    button.toolTip = text
    if applied == nil {
      // Once, on the first success: confirms the status button was found at all,
      // which is the part that depends on undocumented view hierarchy.
      logger.notice("Menu bar tooltip attached to the status item")
    }
    applied = text
  }

  /// The app's own status item button, if it has been created yet.
  static func statusBarButton() -> NSStatusBarButton? {
    for window in NSApp.windows {
      if let button = firstStatusBarButton(in: window.contentView) { return button }
    }
    return nil
  }

  private static func firstStatusBarButton(in view: NSView?) -> NSStatusBarButton? {
    guard let view else { return nil }
    if let button = view as? NSStatusBarButton { return button }
    for subview in view.subviews {
      if let button = firstStatusBarButton(in: subview) { return button }
    }
    return nil
  }
}
