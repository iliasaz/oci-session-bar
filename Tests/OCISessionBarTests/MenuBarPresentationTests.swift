// Copyright 2026 Ilia Sazonov
// SPDX-License-Identifier: MIT

import AppKit
import Foundation
import SwiftUI
import Testing

@testable import OCISessionBar

@Suite("Menu bar presentation")
struct MenuBarPresentationTests {
  @Test("A live session shows a countdown, not a symbol")
  func liveSessionCountsDown() {
    let presentation = MenuBarPresentation.countdown(text: "1:20", isCritical: false)
    #expect(presentation.symbolName == nil)
    #expect(presentation.isCritical == false)
  }

  /// A healthy countdown is green, and green survives only if AppKit is told not
  /// to recolour the image. Tying that to `isCritical` — the obvious-looking
  /// shortcut — silently repaints the healthy countdown in the menu bar's own
  /// colour, which is how this regressed once already.
  @Test(
    "Only the neutral state may be recoloured by AppKit",
    arguments: [
      (MenuBarPresentation.countdown(text: "1:20", isCritical: false), false),
      (.countdown(text: "0:04", isCritical: true), false),
      (.expired, false),
      (.unconfigured, true),
    ]
  )
  func templatesOnlyTheNeutralState(presentation: MenuBarPresentation, isTemplate: Bool) {
    #expect(presentation.usesTemplateRendering == isTemplate)
  }

  @Test("An expired session shows a lapsed-clock symbol in the alert colour")
  func expiredShowsSymbol() {
    #expect(MenuBarPresentation.expired.symbolName == "clock.badge.xmark")
    #expect(MenuBarPresentation.expired.isCritical)
  }

  /// Nothing has gone wrong when no profile is configured, so the item stays a
  /// normal template icon rather than shouting in red.
  @Test("An unconfigured app is not treated as an alert")
  func unconfiguredIsNotCritical() {
    #expect(MenuBarPresentation.unconfigured.symbolName == "key.slash")
    #expect(MenuBarPresentation.unconfigured.isCritical == false)
  }

  /// A symbol name that does not exist on the running OS renders nothing at all,
  /// which would leave an invisible menu bar item. Cheap to check, expensive to miss.
  @Test(
    "Every symbol used actually resolves on this OS",
    arguments: [MenuBarPresentation.expired, .unconfigured]
  )
  func symbolsResolve(presentation: MenuBarPresentation) throws {
    let name = try #require(presentation.symbolName)
    #expect(
      NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil,
      "SF Symbol \"\(name)\" is unavailable on this macOS version"
    )
  }

  @Test(
    "Every state carries an accessibility description",
    arguments: [
      MenuBarPresentation.countdown(text: "1:20", isCritical: false),
      .countdown(text: "0:04", isCritical: true),
      .expired,
      .unconfigured,
    ]
  )
  func describesItselfForVoiceOver(presentation: MenuBarPresentation) {
    #expect(presentation.accessibilityDescription.isEmpty == false)
  }
}

@MainActor
@Suite("Menu bar rendering")
struct MenuBarRendererTests {
  @Test(
    "Every state renders to an image",
    arguments: [
      MenuBarPresentation.countdown(text: "1:20", isCritical: false),
      .expired,
      .unconfigured,
    ]
  )
  func rendersToAnImage(presentation: MenuBarPresentation) throws {
    let image = try #require(MenuBarRenderer.image(for: presentation))
    #expect(image.size.width > 0)
    #expect(image.size.height > 0)
    #expect(image.accessibilityDescription == presentation.accessibilityDescription)
    // Coloured states must opt out of templating or AppKit repaints them; the
    // neutral state must stay templated so it adapts to the menu bar.
    #expect(image.isTemplate == presentation.usesTemplateRendering)
  }

  /// The item is sized from `NSStatusBar.thickness`, so a bumped font or padding
  /// could silently push the image past the bar's height, where the system scales
  /// it down and everything goes soft.
  @Test(
    "Nothing rendered is taller than the menu bar",
    arguments: [
      MenuBarPresentation.countdown(text: "1:20", isCritical: false),
      .expired,
      .unconfigured,
    ]
  )
  func fitsWithinTheMenuBar(presentation: MenuBarPresentation) throws {
    let image = try #require(MenuBarRenderer.image(for: presentation))
    #expect(
      image.size.height <= NSStatusBar.system.thickness,
      "\(image.size.height)pt tall, but the menu bar is \(NSStatusBar.system.thickness)pt"
    )
  }

  /// The capsule has to actually be drawn: without it the countdown is bare text,
  /// which is the thing it exists to fix.
  @Test("The countdown is drawn on a capsule, not bare")
  func countdownSitsOnACapsule() throws {
    let bare = ("1:20" as NSString).size(withAttributes: [
      .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
    ])
    let image = try #require(MenuBarRenderer.image(for: .countdown(text: "1:20", isCritical: false)))
    // The capsule pads well beyond the glyphs themselves.
    #expect(image.size.width > bare.width + 8)
    #expect(image.size.height >= 16)
  }

  /// The image opts out of templating, so AppKit will not adapt it and the renderer
  /// has to. If these come out identical the appearance is being ignored, and one of
  /// the two menu bars gets a capsule that works against it rather than with it.
  @Test("The item is drawn differently for a light and a dark menu bar")
  func adaptsToMenuBarAppearance() throws {
    let onDark = try #require(
      MenuBarRenderer.image(for: .countdown(text: "1:20", isCritical: false), appearance: .dark))
    let onLight = try #require(
      MenuBarRenderer.image(for: .countdown(text: "1:20", isCritical: false), appearance: .light))
    #expect(onDark.tiffRepresentation != onLight.tiffRepresentation)
  }

  /// The alert state has to be visibly different from the healthy one, and the only
  /// thing that distinguishes them is the colour — same text, same geometry.
  @Test("A critical countdown is drawn differently from a healthy one")
  func criticalDiffersFromHealthy() throws {
    let healthy = try #require(
      MenuBarRenderer.image(for: .countdown(text: "1:20", isCritical: false)))
    let critical = try #require(
      MenuBarRenderer.image(for: .countdown(text: "1:20", isCritical: true)))
    #expect(healthy.tiffRepresentation != critical.tiffRepresentation)
  }

  /// The tick redraws once a second whether or not anything changed, which is what
  /// the cache exists to absorb. It is keyed on the whole of the state, so a changed
  /// countdown must still produce a fresh image.
  @Test("An unchanged state is served from the cache, a changed one is not")
  func cachesUnchangedStates() throws {
    let first = try #require(MenuBarRenderer.image(for: .countdown(text: "1:20", isCritical: false)))
    let again = try #require(MenuBarRenderer.image(for: .countdown(text: "1:20", isCritical: false)))
    #expect(first === again)

    let ticked = try #require(MenuBarRenderer.image(for: .countdown(text: "1:19", isCritical: false)))
    #expect(first !== ticked)
  }

  /// The two menu bar appearances must not collide in the cache, or the item keeps
  /// whichever one it was first drawn for until its text happens to change.
  @Test("The cache distinguishes the two menu bar appearances")
  func cacheKeysOnAppearance() throws {
    let onDark = try #require(MenuBarRenderer.image(for: .expired, appearance: .dark))
    let onLight = try #require(MenuBarRenderer.image(for: .expired, appearance: .light))
    #expect(onDark !== onLight)
  }
}

@MainActor
@Suite("Status summary")
struct StatusSummaryTests {
  @Test("A live session names the profile and when it lapses")
  func describesLiveSession() {
    let model = AuthModel.preview()
    let summary = model.statusSummary
    #expect(summary.contains("jroga-token"))
    #expect(summary.contains("expires"))
    #expect(summary.contains("left"))
  }

  /// The point of the symbol change: "expired" has to be *said*, not implied by a
  /// dash.
  @Test("An expired session says so")
  func describesExpiredSession() {
    let model = AuthModel.preview(status: .previewExpired)
    #expect(model.statusSummary.contains("expired"))
    #expect(model.menuBarPresentation == .expired)
  }

  @Test("With nothing configured the summary explains which of the two it is")
  func describesUnconfigured() {
    let model = AuthModel.preview(profileName: nil, status: nil)
    // The preview model does have session profiles, just none selected.
    #expect(model.statusSummary == "No profile selected")
    #expect(model.menuBarPresentation == .unconfigured)
  }

  @Test("A healthy session is not flagged as critical")
  func healthySessionIsNotCritical() {
    #expect(AuthModel.preview().menuBarPresentation.isCritical == false)
  }

  @Test("A session in its last tenth is flagged as critical")
  func nearlyExpiredIsCritical() {
    let model = AuthModel.preview(status: .previewCritical)
    #expect(model.menuBarPresentation.isCritical)
  }
}
