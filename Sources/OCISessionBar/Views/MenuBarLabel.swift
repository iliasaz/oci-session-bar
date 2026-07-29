// Copyright 2026 Ilia Sazonov
// SPDX-License-Identifier: MIT

import SwiftUI

/// The menu bar item: a countdown while a session is live, an SF Symbol when
/// there is nothing to count down.
///
/// The content is rendered to a bitmap rather than handed to `MenuBarExtra` as a
/// `Text` or `Image`. AppKit treats a menu bar item's label as a *template* image
/// and recolors it to match the menu bar, so `foregroundStyle` is silently
/// discarded and the countdown comes out monochrome. Rendering it here and
/// clearing `isTemplate` is what keeps the colour.
///
/// The exception is the `unconfigured` state, which stays a template image on
/// purpose: nothing has gone wrong there, so it should behave like every other
/// menu bar icon and adapt to light and dark menu bars automatically.
struct MenuBarLabel: View {
  let presentation: MenuBarPresentation
  let appearance: MenuBarAppearance

  var body: some View {
    if let image = Self.render(presentation, appearance: appearance) {
      Image(nsImage: image)
    } else {
      // Only reachable if rendering fails outright, or a symbol is missing on this
      // OS. A monochrome label still beats an empty menu bar item.
      Text(presentation.fallbackText)
    }
  }

  @MainActor
  static func render(
    _ presentation: MenuBarPresentation,
    appearance: MenuBarAppearance = .dark
  ) -> NSImage? {
    let rendered: NSImage?
    switch presentation {
    case .countdown(let text, _):
      rendered = renderCountdown(
        text, color: presentation.tintColor, appearance: appearance,
        isCritical: presentation.isCritical)
    case .expired:
      rendered = renderSymbol(
        presentation.symbolName, color: presentation.tintColor,
        appearance: appearance, onCapsule: true)
    case .unconfigured:
      rendered = renderSymbol(
        presentation.symbolName, color: presentation.tintColor,
        appearance: appearance, onCapsule: false)
    }
    guard let image = rendered else { return nil }
    // Only the neutral state may be recoloured by AppKit; see the note above.
    image.isTemplate = presentation.usesTemplateRendering
    image.accessibilityDescription = presentation.accessibilityDescription
    return image
  }

  /// Leaves room above and below the capsule inside the menu bar's own height, so
  /// it reads as an inset object rather than filling the bar edge to edge.
  private static var capsuleHeight: Double {
    max(16, NSStatusBar.system.thickness - 6)
  }

  private static func renderCountdown(
    _ text: String, color: Color, appearance: MenuBarAppearance, isCritical: Bool
  ) -> NSImage? {
    render(
      Text(text)
        .font(.system(size: 12, weight: .semibold, design: .rounded).monospacedDigit())
        .foregroundStyle(color)
        .padding(.horizontal, 7)
        .frame(height: capsuleHeight)
        .background { MenuBarCapsule(appearance: appearance, isCritical: isCritical) },
      appearance: appearance
    )
  }

  /// - Parameter onCapsule: Whether to sit the symbol on the same capsule as the
  ///   countdown. The neutral state does not, because it is a template image and
  ///   AppKit would flatten capsule and glyph together into one solid blob.
  private static func renderSymbol(
    _ name: String?, color: Color, appearance: MenuBarAppearance, onCapsule: Bool
  ) -> NSImage? {
    // A symbol missing on this OS version must fall back to text rather than
    // render an empty item, so the name is resolved before drawing it.
    guard let name, NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil else {
      return nil
    }
    let symbol = Image(systemName: name)
      .font(.system(size: onCapsule ? 12 : 14, weight: .medium))
      .foregroundStyle(color)

    guard onCapsule else {
      return render(symbol.padding(.horizontal, 2), appearance: appearance)
    }
    return render(
      symbol
        .padding(.horizontal, 7)
        .frame(height: capsuleHeight)
        // `.expired` is the only state that reaches here with a capsule, and it is
        // always critical, so it gets the same dark alert bed as a red countdown.
        .background { MenuBarCapsule(appearance: appearance, isCritical: true) },
      appearance: appearance
    )
  }

  private static func render(
    _ content: some View, appearance: MenuBarAppearance
  ) -> NSImage? {
    // Pinning the colour scheme makes system colours resolve for the menu bar the
    // image will actually sit on, not for whatever the app's own appearance is.
    let renderer = ImageRenderer(content: content.environment(\.colorScheme, appearance.colorScheme))
    // Match the menu bar's backing scale so the result is not soft on Retina.
    renderer.scale = NSScreen.main?.backingScaleFactor ?? 2
    return renderer.nsImage
  }
}

extension MenuBarPresentation {
  /// System colours rather than SwiftUI's `.red`/`.green`, so the shades match the
  /// rest of the system UI and stay legible on light and dark menu bars alike.
  ///
  /// The neutral state uses the label colour, which AppKit then replaces anyway
  /// when it paints the template image.
  var tintColor: Color {
    switch self {
    case .countdown, .expired:
      isCritical ? Color(nsColor: .systemRed) : Color(nsColor: .systemGreen)
    case .unconfigured:
      Color(nsColor: .labelColor)
    }
  }

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
