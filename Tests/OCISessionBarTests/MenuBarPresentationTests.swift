// Copyright 2026 Ilia Sazonov
// SPDX-License-Identifier: MIT

import AppKit
import Foundation
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

  @MainActor
  @Test(
    "Every state renders to an image",
    arguments: [
      MenuBarPresentation.countdown(text: "1:20", isCritical: false),
      .expired,
      .unconfigured,
    ]
  )
  func rendersToAnImage(presentation: MenuBarPresentation) throws {
    let image = try #require(MenuBarLabel.render(presentation))
    #expect(image.size.width > 0)
    #expect(image.size.height > 0)
    #expect(image.accessibilityDescription == presentation.accessibilityDescription)
    // Coloured states must opt out of templating or AppKit repaints them; the
    // neutral state must stay templated so it adapts to the menu bar.
    #expect(image.isTemplate == presentation.usesTemplateRendering)
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
