// Copyright 2026 Ilia Sazonov
// SPDX-License-Identifier: MIT

import AppKit

/// Draws the menu bar item into a bitmap.
///
/// The bitmap itself is unavoidable. `MenuBarExtra` does not host its label as a
/// live SwiftUI view: a `Text` label is reduced to the status button's `title`
/// string and every modifier — `foregroundStyle` included — is dropped before
/// AppKit sees it, so an image is the only way the state colour survives.
///
/// What *was* avoidable is doing it through SwiftUI. This used to build a view
/// tree — text, capsule, gradient fill, sheen overlay, rim stroke — and push it
/// through `ImageRenderer` on every one-second tick. Drawn directly it is a
/// rounded rect, a stroke and a string, and the result is cached so a tick that
/// changes nothing redraws nothing.
@MainActor
enum MenuBarRenderer {
  /// Everything the drawing depends on. Cheap to compare, so the cache can be
  /// keyed on it wholesale rather than on a hand-maintained list of fields.
  private struct Key: Equatable {
    let presentation: MenuBarPresentation
    let appearance: MenuBarAppearance
  }

  private static var cached: (key: Key, image: NSImage)?

  /// The image for the current state, or `nil` if a symbol it needs is missing on
  /// this OS — in which case the caller falls back to text.
  static func image(
    for presentation: MenuBarPresentation, appearance: MenuBarAppearance = .dark
  ) -> NSImage? {
    let key = Key(presentation: presentation, appearance: appearance)
    if let cached, cached.key == key { return cached.image }

    guard let image = draw(key) else { return nil }
    image.accessibilityDescription = presentation.accessibilityDescription
    cached = (key, image)
    return image
  }

  private static func draw(_ key: Key) -> NSImage? {
    switch key.presentation {
    case .countdown(let text, _):
      countdown(text, key: key)
    case .expired:
      symbol(key.presentation.symbolName, key: key)
    case .unconfigured:
      // Nothing has gone wrong here, so the item stays an ordinary template icon
      // and lets AppKit adapt it to the menu bar like every other one. No capsule:
      // templating would flatten bed and glyph together into a solid blob.
      neutralSymbol(key.presentation.symbolName)
    }
  }

  // MARK: Metrics

  /// Leaves a little room above and below the capsule inside the menu bar's own
  /// height, so it reads as an inset object rather than filling the bar edge to edge.
  private static var barHeight: CGFloat { NSStatusBar.system.thickness }
  private static var capsuleHeight: CGFloat { max(16, barHeight - 5) }
  private static let horizontalPadding: CGFloat = 10
  private static let font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold)

  // MARK: States

  private static func countdown(_ text: String, key: Key) -> NSImage {
    let tint = tint(for: key)
    let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: tint]
    let size = (text as NSString).size(withAttributes: attributes)
    let height = barHeight

    return capsule(contentWidth: size.width, tint: tint, appearance: key.appearance) { bounds in
      (text as NSString).draw(
        at: NSPoint(x: (bounds.width - size.width) / 2, y: (height - size.height) / 2),
        withAttributes: attributes
      )
    }
  }

  private static func symbol(_ name: String?, key: Key) -> NSImage? {
    let tint = tint(for: key)
    // `paletteColors` needs a colour it can use as-is, which is exactly what
    // `tint(for:)` hands back — see the note there about lazy drawing.
    let configuration = NSImage.SymbolConfiguration(pointSize: 12, weight: .medium)
      .applying(NSImage.SymbolConfiguration(paletteColors: [tint]))
    guard let name,
      let glyph = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
        .withSymbolConfiguration(configuration)
    else { return nil }

    let size = glyph.size
    let height = barHeight
    return capsule(contentWidth: size.width, tint: tint, appearance: key.appearance) { bounds in
      glyph.draw(
        at: NSPoint(x: (bounds.width - size.width) / 2, y: (height - size.height) / 2),
        from: .zero, operation: .sourceOver, fraction: 1
      )
    }
  }

  private static func neutralSymbol(_ name: String?) -> NSImage? {
    guard let name,
      let glyph = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
        .withSymbolConfiguration(.init(pointSize: 14, weight: .medium))
    else { return nil }
    glyph.isTemplate = true
    return glyph
  }

  // MARK: The capsule

  /// The bed the coloured states sit on, so the item reads as an object rather than
  /// text floating in the bar: a wash of the state's own colour at low alpha, with a
  /// brighter rim of the same colour.
  ///
  /// The alpha is low enough that the capsule stays a hint of colour rather than a
  /// second red surface behind red text — which is what went wrong the last time
  /// this was tinted, at gradient strength.
  ///
  /// The translucency is real: the bitmap keeps its alpha and the status item
  /// composites it over the menu bar, which is itself translucent over the desktop.
  private static func capsule(
    contentWidth: CGFloat,
    tint: NSColor,
    appearance: MenuBarAppearance,
    content: @escaping (NSRect) -> Void
  ) -> NSImage {
    let width = ceil(contentWidth) + horizontalPadding * 2
    let height = barHeight
    let capsuleHeight = capsuleHeight
    let fillAlpha = fillAlpha(for: appearance)

    let image = NSImage(size: NSSize(width: width, height: height), flipped: false) { bounds in
      let rect = NSRect(
        x: 0.5, y: (height - capsuleHeight) / 2,
        width: width - 1, height: capsuleHeight
      )
      let path = NSBezierPath(
        roundedRect: rect, xRadius: capsuleHeight / 2, yRadius: capsuleHeight / 2)
      tint.withAlphaComponent(fillAlpha).setFill()
      path.fill()
      tint.withAlphaComponent(0.55).setStroke()
      path.lineWidth = 0.8
      path.stroke()
      content(bounds)
      return true
    }
    // The colour is the whole point; templating would repaint it in the menu bar's
    // own foreground colour. This is *not* the same question as `isCritical` — a
    // healthy countdown is green without being critical.
    image.isTemplate = false
    return image
  }

  /// A wash needs more weight on a dark menu bar, where it has less to contrast
  /// against, than on a light one where the same alpha already reads as a surface.
  private static func fillAlpha(for appearance: MenuBarAppearance) -> CGFloat {
    switch appearance {
    case .dark: 0.22
    case .light: 0.16
    }
  }

  /// The state's colour, resolved against the *menu bar's* appearance rather than
  /// the app's — the image opts out of templating, so AppKit will not adapt it and
  /// the app has to.
  ///
  /// Resolving up front is what makes that stick. `NSImage`'s drawing handler runs
  /// lazily, whenever the image is finally rasterized, long after any
  /// `performAsCurrentDrawingAppearance` block has exited; a dynamic system colour
  /// left unresolved would pick up whatever appearance happened to be current then.
  private static func tint(for key: Key) -> NSColor {
    let dynamic: NSColor = key.presentation.isCritical ? .systemRed : .systemGreen
    var resolved = dynamic
    key.appearance.nsAppearance.performAsCurrentDrawingAppearance {
      resolved = dynamic.usingColorSpace(.sRGB) ?? dynamic
    }
    return resolved
  }
}
