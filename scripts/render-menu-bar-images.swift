// Copyright 2026 Ilia Sazonov
// SPDX-License-Identifier: MIT

import AppKit

/// Renders every menu bar state through the app's own `MenuBarRenderer` and writes
/// the results out as PNGs for the README, one light and one dark per state.
///
/// Compiled against the real renderer rather than reimplementing it, so the images
/// cannot drift from what the status item actually draws. The writing itself lives
/// in `MenuBarImageOutput.swift`, shared with `capture-menu-bar-item.swift` — see
/// there for why the stills carry no background. Run via
/// `scripts/render-menu-bar-images.sh`.
@MainActor
func run() throws {
  let states: [(String, MenuBarPresentation)] = [
    ("countdown-healthy", .countdown(text: "1:20", isCritical: false)),
    ("countdown-critical", .countdown(text: "0:04", isCritical: true)),
    ("expired", .expired),
    ("unconfigured", .unconfigured),
  ]
  let appearances: [(String, MenuBarAppearance)] = [("dark", .dark), ("light", .light)]
  let outputDirectory = URL(fileURLWithPath: CommandLine.arguments[1])

  for (suffix, appearance) in appearances {
    for (name, presentation) in states {
      let url = outputDirectory.appending(path: "\(name)-\(suffix).png")
      try writeMenuBarItem(presentation, appearance: appearance, to: url)
      print("wrote \(url.path(percentEncoded: false))")
    }
  }
}

@main
enum Main {
  static func main() {
    _ = NSApplication.shared
    do {
      try run()
    } catch {
      FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
      exit(1)
    }
  }
}
