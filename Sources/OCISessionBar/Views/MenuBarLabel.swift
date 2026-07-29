// Copyright 2026 Ilia Sazonov
// SPDX-License-Identifier: MIT

import SwiftUI

/// The menu bar item: a countdown while a session is live, an SF Symbol when there
/// is nothing to count down.
///
/// Thin on purpose. `MenuBarExtra` cannot host a live SwiftUI view as its label, so
/// all the drawing happens in ``MenuBarRenderer`` and this only hands the result
/// over — see that type for why it is a bitmap.
struct MenuBarLabel: View {
  let presentation: MenuBarPresentation
  let appearance: MenuBarAppearance

  var body: some View {
    if let image = MenuBarRenderer.image(for: presentation, appearance: appearance) {
      Image(nsImage: image)
    } else {
      // Only reachable if a symbol is missing on this OS. A monochrome label still
      // beats an empty menu bar item.
      Text(presentation.fallbackText)
    }
  }
}

extension MenuBarPresentation {
  /// Shown only if no image can be produced at all.
  var fallbackText: String {
    switch self {
    case .countdown(let text, _): text
    case .expired: "expired"
    case .unconfigured: "—"
    }
  }
}

#if DEBUG
  #Preview("Menu bar states", traits: .sizeThatFitsLayout) {
    VStack(alignment: .leading, spacing: 12) {
      LabeledContent("Healthy") {
        MenuBarLabel(presentation: .countdown(text: "1:20", isCritical: false), appearance: .dark)
      }
      LabeledContent("Nearly expired") {
        MenuBarLabel(presentation: .countdown(text: "0:04", isCritical: true), appearance: .dark)
      }
      LabeledContent("Expired") {
        MenuBarLabel(presentation: .expired, appearance: .dark)
      }
      LabeledContent("Not configured") {
        MenuBarLabel(presentation: .unconfigured, appearance: .dark)
      }
    }
    .padding()
  }
#endif
