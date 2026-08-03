// Copyright 2026 Ilia Sazonov
// SPDX-License-Identifier: MIT

import Foundation
import Sparkle
import Testing

@testable import OCISessionBar

/// Ground truth: `BUNDLE_LOADER`/`TEST_HOST` in project.yml load this test bundle
/// into the app itself, so `Bundle.main` here is the real, build-setting-substituted
/// Info.plist Sparkle will actually read — not a stand-in. A typo'd feed URL or a
/// truncated signing key would otherwise ship silently: Sparkle only surfaces either
/// failure at update time, on every installed copy, long after release.
@Suite("Sparkle configuration")
struct SparkleConfigurationTests {
  private var info: [String: Any] {
    Bundle.main.infoDictionary ?? [:]
  }

  @Test("SUPublicEDKey decodes to a 32-byte Ed25519 public key")
  func publicKeyIsWellFormed() throws {
    let key = try #require(info["SUPublicEDKey"] as? String)
    let decoded = try #require(Data(base64Encoded: key))
    #expect(decoded.count == 32)
  }

  @Test("SUFeedURL is an https GitHub releases asset")
  func feedURLIsWellFormed() throws {
    let raw = try #require(info["SUFeedURL"] as? String)
    let url = try #require(URL(string: raw))
    #expect(url.scheme == "https")
    #expect(url.host() == "github.com")
    #expect(url.path(percentEncoded: false).hasPrefix("/iliasaz/oci-session-bar/releases"))
  }

  // Being `LSUIElement` means there is no window to have prompted Sparkle's usual
  // second-launch permission alert, so the app must opt in up front instead of
  // leaving the key unset. See UpdaterModel's doc comment for why the Settings
  // toggle is what lets a user turn this back off.
  @Test("Automatic update checks default on, so the second-launch permission alert never fires")
  func automaticChecksDefaultOn() {
    #expect(info["SUEnableAutomaticChecks"] as? Bool == true)
  }
}

/// `startingUpdater: false` is what `#Preview` uses to avoid touching the network
/// or scheduling anything — see `UpdaterModel.init`. It is also the only path a test
/// may take: the app skips starting its own updater under a test host (see
/// ``UpdaterModel/isRunningTests``), and a started one here would put that back.
@Suite("UpdaterModel")
struct UpdaterModelTests {
  @Test("Constructing without starting the updater does not crash, and it starts unable to check")
  func constructsWithoutStarting() {
    let updater = UpdaterModel(startingUpdater: false)
    // Sparkle only flips `canCheckForUpdates` to true from `-startUpdater:`, which
    // this deliberately never calls.
    #expect(updater.canCheckForUpdates == false)
  }

  // Ground truth for the seam that keeps this suite network-hermetic: if Xcode ever
  // stops setting XCTest-prefixed environment variables in the test host, this fails
  // here instead of the app quietly starting a live updater during every test run.
  @Test("The test host is recognised, which is what keeps the app's own updater off here")
  func testHostIsRecognised() {
    #expect(UpdaterModel.isRunningTests)
  }
}

/// Ground truth: Sparkle logs "Background app automatically schedules for update checks
/// but does not implement gentle reminders" when a `LSUIElement` app leaves these out,
/// and then shows scheduled updates behind every other window where they go unnoticed.
@Suite("Update reminders")
struct UpdateReminderTests {
  @Test("Gentle reminders are declared — the property Sparkle actually reads")
  func declaresGentleReminders() {
    #expect(UpdateReminder().supportsGentleScheduledUpdateReminders)
  }

  @Test("Sparkle keeps the updates it would show in front, and hands over the rest")
  func takesOverUpdatesShownInTheBackground() {
    let reminder = UpdateReminder()
    #expect(
      reminder.standardUserDriverShouldHandleShowingScheduledUpdate(
        SUAppcastItem.empty(), andInImmediateFocus: true
      )
    )
    #expect(
      reminder.standardUserDriverShouldHandleShowingScheduledUpdate(
        SUAppcastItem.empty(), andInImmediateFocus: false
      ) == false
    )
  }

  // Sparkle keeps its own `canCheckForUpdates` false for the whole update session, so
  // without this the menu item is disabled for exactly as long as an update is waiting
  // — the one time it is needed most, since nothing else can bring the alert forward.
  @Test("A waiting update leaves Check for Updates enabled")
  func waitingUpdateKeepsTheCommandLive() {
    let updater = UpdaterModel(startingUpdater: false)
    #expect(updater.canCheckForUpdates == false)
    updater.isShowingScheduledUpdate = true
    #expect(updater.canCheckForUpdates)
  }

  @Test("An update the user has seen, or that has finished, stops counting as waiting")
  func attentionAndSessionEndClearTheWaitingUpdate() {
    let updater = UpdaterModel(startingUpdater: false)
    let reminder = UpdateReminder()
    reminder.model = updater

    updater.isShowingScheduledUpdate = true
    reminder.standardUserDriverDidReceiveUserAttention(forUpdate: SUAppcastItem.empty())
    #expect(updater.isShowingScheduledUpdate == false)

    updater.isShowingScheduledUpdate = true
    reminder.standardUserDriverWillFinishUpdateSession()
    #expect(updater.isShowingScheduledUpdate == false)
  }
}
