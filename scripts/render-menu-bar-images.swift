// Copyright 2026 Ilia Sazonov
// SPDX-License-Identifier: MIT

import AppKit

/// Renders each menu bar state through the app's own `MenuBarRenderer`, composited
/// onto a menu-bar-like backdrop, and writes the results out as PNGs for the README.
///
/// Compiled against the real renderer rather than reimplementing it, so the images
/// cannot drift from what the status item actually draws. Run via
/// `scripts/render-menu-bar-images.sh`.
@MainActor
func run() {
  let scale: CGFloat = 3
  let states: [(String, MenuBarPresentation)] = [
    ("countdown-healthy", .countdown(text: "1:20", isCritical: false)),
    ("countdown-critical", .countdown(text: "0:04", isCritical: true)),
    ("expired", .expired),
    ("unconfigured", .unconfigured),
  ]
  let backdrops: [(String, MenuBarAppearance, NSColor)] = [
    ("dark", .dark, NSColor(srgbRed: 0.13, green: 0.13, blue: 0.14, alpha: 1)),
    ("light", .light, NSColor(srgbRed: 0.93, green: 0.93, blue: 0.94, alpha: 1)),
  ]
  let outputDirectory = URL(fileURLWithPath: CommandLine.arguments[1])

  for (suffix, appearance, background) in backdrops {
    for (name, presentation) in states {
      guard let item = MenuBarRenderer.image(for: presentation, appearance: appearance) else {
        print("no image for \(name)")
        continue
      }
      // The unconfigured item is a template, which AppKit would normally tint to
      // the menu bar's foreground colour; do that here so the still matches.
      let glyph = item.isTemplate ? item.tinted(appearance == .dark ? .white : .black) : item

      let size = NSSize(width: glyph.size.width + 16, height: NSStatusBar.system.thickness)
      guard
        let rep = NSBitmapImageRep(
          bitmapDataPlanes: nil,
          pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
          bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
          colorSpaceName: .calibratedRGB, bytesPerRow: 0, bitsPerPixel: 0)
      else { continue }
      rep.size = size

      NSGraphicsContext.saveGraphicsState()
      NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
      background.setFill()
      NSRect(origin: .zero, size: size).fill()
      glyph.draw(
        at: NSPoint(x: 8, y: (size.height - glyph.size.height) / 2),
        from: .zero, operation: .sourceOver, fraction: 1)
      NSGraphicsContext.restoreGraphicsState()

      guard let data = rep.representation(using: .png, properties: [:]) else { continue }
      let url = outputDirectory.appending(path: "\(name)-\(suffix).png")
      try? data.write(to: url)
      print("wrote \(url.path(percentEncoded: false))")
    }
  }
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

@main
enum Main {
  static func main() {
    _ = NSApplication.shared
    run()
  }
}
