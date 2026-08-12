// Copyright 2026 Ilia Sazonov
// SPDX-License-Identifier: MIT

import AppKit

/// Writing the menu bar item out as a PNG, shared by the two scripts that do it:
/// `render-menu-bar-images.swift` (every state, for the README) and
/// `capture-menu-bar-item.swift` (whatever the app is showing right now). Neither
/// owns the format, so the stills cannot end up produced two different ways.

/// Renders one state and writes it to `url` with nothing behind it.
///
/// Transparent on purpose. These are shown on backgrounds this file has no way to
/// know — GitHub's light theme, its dark theme, whatever a docs page uses — and a
/// still with a menu-bar-coloured rectangle baked in reads as a grey slab on all of
/// them. The item keeps its own alpha instead and sits on whatever it is put on,
/// which is what it does in the menu bar.
///
/// `appearance` still matters with the backdrop gone: it sets how heavily the
/// capsule is washed and which shade the state's colour resolves to, so the pair of
/// stills for a state remains a light one and a dark one.
@MainActor
func writeMenuBarItem(
  _ presentation: MenuBarPresentation,
  appearance: MenuBarAppearance,
  to url: URL,
  scale: CGFloat = 3
) throws {
  guard let item = MenuBarRenderer.image(for: presentation, appearance: appearance) else {
    throw Failure("the renderer produced no image for \(presentation)")
  }
  // The unconfigured state ships as a template, which AppKit tints to the menu bar's
  // foreground colour on its way into the status item. Do that here too, or the still
  // is a black glyph rather than the white one on screen.
  let glyph = item.isTemplate ? item.tinted(appearance == .dark ? .white : .black) : item

  guard let data = png(of: onBarHeight(glyph), scale: scale) else {
    throw Failure("could not encode \(url.lastPathComponent)")
  }
  try data.write(to: url)
}

/// The image centred on a canvas the height of the menu bar, if it is not that tall
/// already.
///
/// Every still then has one height, so markup that pins them to a single height —
/// as the README's `<img height="24">` does — shows each state at the size it really
/// is next to the others. Only the neutral symbol needs it: the capsule states are
/// drawn bar-height by the renderer, but a bare glyph is its own size and would
/// otherwise be scaled up to fill the row.
@MainActor
func onBarHeight(_ image: NSImage) -> NSImage {
  let height = NSStatusBar.system.thickness
  guard image.size.height != height else { return image }

  let size = NSSize(width: image.size.width, height: height)
  let padded = NSImage(size: size, flipped: false) { _ in
    image.draw(
      at: NSPoint(x: 0, y: (height - image.size.height) / 2),
      from: .zero, operation: .sourceOver, fraction: 1)
    return true
  }
  padded.isTemplate = false
  return padded
}

/// The image at `scale` pixels per point, over transparency.
@MainActor
func png(of image: NSImage, scale: CGFloat) -> Data? {
  let size = image.size
  guard
    let rep = NSBitmapImageRep(
      bitmapDataPlanes: nil,
      pixelsWide: Int((size.width * scale).rounded()),
      pixelsHigh: Int((size.height * scale).rounded()),
      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
      colorSpaceName: .calibratedRGB, bytesPerRow: 0, bitsPerPixel: 0)
  else { return nil }
  rep.size = size

  NSGraphicsContext.saveGraphicsState()
  NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
  image.draw(at: .zero, from: .zero, operation: .sourceOver, fraction: 1)
  NSGraphicsContext.restoreGraphicsState()

  return rep.representation(using: .png, properties: [:])
}

extension NSImage {
  /// Paints a template image in a single colour, the way AppKit does for a status
  /// item, so the still shows what lands in the menu bar rather than a black glyph.
  func tinted(_ color: NSColor) -> NSImage {
    let copy = NSImage(size: size, flipped: false) { bounds in
      self.draw(in: bounds, from: .zero, operation: .sourceOver, fraction: 1)
      color.set()
      bounds.fill(using: .sourceAtop)
      return true
    }
    copy.isTemplate = false
    return copy
  }
}

nonisolated struct Failure: LocalizedError {
  let message: String
  init(_ message: String) { self.message = message }
  var errorDescription: String? { message }
}
