// Copyright 2026 Ilia Sazonov
// SPDX-License-Identifier: MIT

import AppKit
import Testing

@testable import OCISessionBar

/// `StatusItemTooltip` walks an undocumented view hierarchy to find the status
/// item's button, so it is exactly the kind of code that breaks silently on an OS
/// update — the tooltip would just stop appearing, with nothing to notice.
///
/// These tests run against the real thing: the test host *is* the app, so by the
/// time they execute the `MenuBarExtra` scene has installed a genuine status item.
@MainActor
@Suite("Status item tooltip", .serialized)
struct StatusItemTooltipTests {
  /// Polls until `condition` holds, or gives up. The status item is installed by
  /// the app's own launch, which does not synchronise with the test run.
  private func eventually(
    timeout: Duration = .seconds(5),
    _ condition: () -> Bool
  ) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
      if condition() { return true }
      try? await Task.sleep(for: .milliseconds(100))
    }
    return condition()
  }

  @Test("The status item's button can be found in the app's window hierarchy")
  func findsStatusBarButton() async throws {
    let found = await eventually { StatusItemTooltip.statusBarButton() != nil }
    #expect(
      found,
      """
      No NSStatusBarButton was found. Either the MenuBarExtra scene did not install \
      a status item, or the view hierarchy changed and StatusItemTooltip needs updating.
      """
    )
  }

  @Test("Applying a tooltip sets it on the button")
  func appliesTooltip() async throws {
    _ = await eventually { StatusItemTooltip.statusBarButton() != nil }
    let button = try #require(StatusItemTooltip.statusBarButton())

    let unique = "Session status \(UUID().uuidString)"
    StatusItemTooltip.apply(unique)
    #expect(button.toolTip == unique)
  }

  /// The end-to-end assertion: the running app pushes its own summary from the
  /// tick, so a tooltip should appear without any test doing it.
  @Test("The running app attaches a tooltip on its own")
  func appAttachesTooltipUnprompted() async {
    let attached = await eventually {
      StatusItemTooltip.statusBarButton()?.toolTip?.isEmpty == false
    }
    #expect(attached, "The app's tick should have pushed a tooltip to the status item")
  }
}
