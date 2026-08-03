// Copyright 2026 Ilia Sazonov
// SPDX-License-Identifier: MIT

import AppKit
import Combine
import Observation
import Sparkle

/// The Sparkle updater, as something SwiftUI can read and bind to.
///
/// Owns the one `SPUStandardUpdaterController` for the process. Sparkle keeps the
/// user's automatic-check preference in the app's own defaults domain, so there is
/// deliberately no `UserDefaults` or `@AppStorage` copy here: ``automaticallyChecksForUpdates``
/// reads and writes `SPUUpdater` directly, and `SUEnableAutomaticChecks` in Info.plist
/// supplies the default until the user changes it.
@Observable
final class UpdaterModel {
  /// Whether the Check for Updates command has anything to do.
  ///
  /// False while a check is already running, and false if the updater failed to start —
  /// but true while a scheduled update waits for the user, because ``checkForUpdates()``
  /// brings that update's alert into focus instead of starting a second check. Sparkle
  /// holds its own `canCheckForUpdates` down for the whole update session, which
  /// includes that wait; leaving the command disabled for it would strand the update,
  /// since a menu bar app has no other way back to an alert it never brought forward.
  var canCheckForUpdates: Bool { updaterCanCheck || isShowingScheduledUpdate }

  /// Whether a scheduled update has been found and is still waiting to be looked at.
  /// Written by ``UpdateReminder``.
  var isShowingScheduledUpdate = false

  private var updaterCanCheck = false

  /// Whether Sparkle looks for a new version on its own schedule.
  ///
  /// A computed passthrough rather than stored state: Sparkle persists this itself,
  /// and a mirrored copy would go stale the moment anything else wrote it.
  var automaticallyChecksForUpdates: Bool {
    get {
      access(keyPath: \.automaticallyChecksForUpdates)
      return controller.updater.automaticallyChecksForUpdates
    }
    set {
      withMutation(keyPath: \.automaticallyChecksForUpdates) {
        controller.updater.automaticallyChecksForUpdates = newValue
      }
    }
  }

  private let controller: SPUStandardUpdaterController

  /// Sparkle references the user driver delegate weakly, so the model is what keeps
  /// it alive.
  @ObservationIgnored private let reminder: UpdateReminder

  @ObservationIgnored private var canCheckObserver: AnyCancellable?

  /// `startingUpdater: false` builds the controller without starting Sparkle, which
  /// is what `#Preview` and the tests need: starting it reads the real Info.plist
  /// feed, schedules background checks, and can put a modal alert on screen.
  init(startingUpdater: Bool = true) {
    let reminder = UpdateReminder()
    self.reminder = reminder
    controller = SPUStandardUpdaterController(
      startingUpdater: startingUpdater, updaterDelegate: nil, userDriverDelegate: reminder
    )
    updaterCanCheck = controller.updater.canCheckForUpdates
    reminder.model = self
    // `canCheckForUpdates` is KVO-compliant, and the KVO publisher is the only way to
    // learn that a check has finished. It is marked `@Sendable` so it stays outside
    // the main actor — the notification carries no promise about which thread it
    // arrives on — and hops before touching observable state.
    canCheckObserver = controller.updater.publisher(for: \.canCheckForUpdates)
      .sink { @Sendable [weak self] canCheck in
        Task { @MainActor in self?.updaterCanCheck = canCheck }
      }

    // Sparkle checks at launch only when the last check is at least a day stale, so a
    // user who relaunches more often than that would never see one happen. This makes
    // every launch a check — in the background, so nothing blocks and nothing appears
    // unless an update really exists — while Sparkle's own daily timer covers the app
    // that never quits. Gated on the same setting as the scheduled checks: off means off.
    if startingUpdater, controller.updater.automaticallyChecksForUpdates {
      controller.updater.checkForUpdatesInBackground()
    }
  }

  /// True when this process is the unit-test host rather than an app the user launched.
  /// The updater must never start there: with a launch-time check, every test run would
  /// hit the live appcast, and once a release newer than the dev build exists, Sparkle
  /// would raise its update alert in the middle of every suite.
  nonisolated static var isRunningTests: Bool {
    ProcessInfo.processInfo.environment.keys.contains { $0.hasPrefix("XCTest") }
  }

  /// The Check for Updates menu item.
  ///
  /// Under `LSUIElement` the app is not in the activation order, so Sparkle's window
  /// would open behind everything unless the app is activated first. With an update
  /// already found and waiting, Sparkle answers this by bringing that alert forward
  /// rather than checking again.
  func checkForUpdates() {
    NSApp.activate(ignoringOtherApps: true)
    controller.updater.checkForUpdates()
  }

  #if DEBUG
    /// An updater that is built but never started, for `#Preview`.
    static func preview() -> UpdaterModel { UpdaterModel(startingUpdater: false) }
  #endif
}

/// Sparkle's gentle reminders, which a background app scheduling its own checks has to
/// implement — Sparkle says so at runtime, and it is right: with no Dock icon and no
/// window of its own, an alert Sparkle raises after a scheduled check sits behind every
/// other app with nothing to point at it, and the user may never notice the update.
///
/// So a scheduled update that Sparkle would show in the background is taken over here:
/// it becomes a notification, the menu item stays live to bring the alert forward (see
/// ``UpdaterModel/canCheckForUpdates``), and nothing appears on screen until the user
/// asks for it. Updates Sparkle would show in front — a user-initiated check, or one
/// found moments after launch — are left to Sparkle, and get no notice.
final class UpdateReminder: NSObject, SPUStandardUserDriverDelegate {
  weak var model: UpdaterModel?

  /// The flag Sparkle looks for; without it, it logs that this app's update alerts may
  /// go unnoticed.
  let supportsGentleScheduledUpdateReminders = true

  func standardUserDriverShouldHandleShowingScheduledUpdate(
    _ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool
  ) -> Bool {
    // `immediateFocus` is Sparkle's own judgement that showing the update right now is
    // no imposition — the app has just launched, or the machine has been idle. Every
    // other scheduled update it would put up behind other apps, so take those over.
    immediateFocus
  }

  func standardUserDriverWillHandleShowingUpdate(
    _ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState
  ) {
    // Sparkle is putting this one in front of the user itself, so there is nothing left
    // to remind them about.
    guard !handleShowingUpdate else { return }
    model?.isShowingScheduledUpdate = true
    Notifications.post(
      title: "Update available",
      body: """
        OCI Session Bar \(update.displayVersionString) is ready to install. \
        Choose Check for Updates to see it.
        """
    )
  }

  /// The user has the update in front of them, so the menu item goes back to meaning
  /// "check again".
  func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
    model?.isShowingScheduledUpdate = false
  }

  func standardUserDriverWillFinishUpdateSession() {
    model?.isShowingScheduledUpdate = false
  }
}
