// Copyright 2026 Ilia Sazonov
// SPDX-License-Identifier: MIT

import AppKit
import SwiftUI

/// Whether the menu bar is currently drawing light content on dark, or the reverse.
///
/// The menu bar item is a bitmap that opts out of templating so it can keep its
/// colour, which means AppKit will not adapt it — so the app has to. This is read
/// from the status button itself rather than from Dark Mode, because the menu bar's
/// appearance also follows the desktop picture: a light-mode Mac with a dark
/// wallpaper still gets a dark menu bar, and the button's `effectiveAppearance` is
/// what AppKit uses to invert everybody else's template icons.
enum MenuBarAppearance: Equatable {
  case light
  case dark

  var colorScheme: ColorScheme {
    switch self {
    case .light: .light
    case .dark: .dark
    }
  }

  @MainActor
  static var current: MenuBarAppearance {
    let appearance = StatusItemTooltip.statusBarButton()?.effectiveAppearance
      ?? NSApp.effectiveAppearance
    return appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? .dark : .light
  }
}
