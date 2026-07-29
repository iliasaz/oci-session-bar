// Copyright 2026 Ilia Sazonov
// SPDX-License-Identifier: MIT

import SwiftUI

/// The countdown as it appears in the menu bar: green normally, red once the
/// session is nearly over.
///
/// The text is rendered to a bitmap rather than handed to `MenuBarExtra` as a
/// `Text`. AppKit treats a menu bar item's label as a *template* image and recolors
/// it to match the menu bar, so `foregroundStyle` on a `Text` is silently discarded
/// and the countdown comes out monochrome. Rendering it here and clearing
/// `isTemplate` is what keeps the colour.
///
/// The trade-off that buys: the image no longer inverts automatically for a dark
/// menu bar. That is the intent — the colour carries meaning — and both system
/// greens and reds are legible on either background.
struct MenuBarLabel: View {
  let text: String
  let isCritical: Bool

  var body: some View {
    if let image = Self.render(text: text, isCritical: isCritical) {
      Image(nsImage: image)
    } else {
      // Only reachable if rendering fails outright; a monochrome countdown still
      // beats an empty menu bar item.
      Text(text)
    }
  }

  @MainActor
  private static func render(text: String, isCritical: Bool) -> NSImage? {
    let renderer = ImageRenderer(
      content:
        Text(text)
        .font(.system(size: 13, weight: .medium, design: .rounded).monospacedDigit())
        .foregroundStyle(isCritical ? Color(nsColor: .systemRed) : Color(nsColor: .systemGreen))
        .padding(.horizontal, 2)
    )
    // Match the menu bar's backing scale so the text is not soft on Retina.
    renderer.scale = NSScreen.main?.backingScaleFactor ?? 2
    guard let image = renderer.nsImage else { return nil }
    image.isTemplate = false
    return image
  }
}
