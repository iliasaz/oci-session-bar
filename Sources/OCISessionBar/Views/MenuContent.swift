// Copyright 2026 Ilia Sazonov
// SPDX-License-Identifier: MIT

import AppKit
import SwiftUI

/// The menu behind the countdown.
///
/// `MenuBarExtra` is used in its `.menu` style, so this is a menu builder rather
/// than an ordinary view hierarchy: `Button`, `Text`, `Divider` and `Menu` compose
/// here, arbitrary views do not.
struct MenuContent: View {
  @Bindable var model: AuthModel
  let updater: UpdaterModel
  @Environment(\.openSettings) private var openSettings

  var body: some View {
    MenuStatusLine(model: model)

    if let activity = model.activity.description {
      Text(activity)
    }

    if let error = model.lastError {
      Text(error)
    }

    Divider()

    Button(model.authenticateTitle, action: model.authenticate)
      .disabled(model.isBusy || model.profileName == nil)

    // Starting over is offered beside Refresh while the session is live: a session
    // at its ceiling refreshes to the same expiry every time, and without this item
    // the only way to a new session was waiting out the countdown. With no live
    // session the button above already mints one, and a twin would just confuse.
    if model.hasSession {
      Button(model.newSessionTitle, action: model.startNewSession)
        .disabled(model.isBusy)
    }

    Button("Settings…", action: showSettings)
      .keyboardShortcut(",", modifiers: .command)

    Divider()

    if let version = AppVersion() {
      Text(version.displayName)
    }

    Button("Check for Updates…", action: updater.checkForUpdates)
      .disabled(!updater.canCheckForUpdates)

    Button("Quit OCI Session Bar", action: quit)
      .keyboardShortcut("q", modifiers: .command)
  }

  private func quit() {
    NSApp.terminate(nil)
  }

  /// Under `LSUIElement` the app is not in the activation order, so the Settings
  /// window opens behind everything unless the app is activated first.
  private func showSettings() {
    NSApp.activate(ignoringOtherApps: true)
    openSettings()
  }
}

#if DEBUG
  // Wrapped in a `Menu` because `MenuBarExtra`'s `.menu` style renders this content
  // in a menu context, and previewing it loose in a stack would not show how the
  // items actually lay out or behave.
  #Preview("Live session") {
    Menu("OCI Session Bar") {
      MenuContent(model: .preview(), updater: .preview())
    }
    .menuStyle(.borderlessButton)
    .padding()
    .frame(width: 260)
  }

  #Preview("Expired, needs sign-in") {
    Menu("OCI Session Bar") {
      MenuContent(
        model: .preview(
          profileName: "boat",
          status: .previewExpired,
          lastError: "Re-authentication required: the service declined to extend the session"
        ),
        updater: .preview()
      )
    }
    .menuStyle(.borderlessButton)
    .padding()
    .frame(width: 260)
  }

  #Preview("Working") {
    Menu("OCI Session Bar") {
      MenuContent(model: .preview(activity: .signingIn), updater: .preview())
    }
    .menuStyle(.borderlessButton)
    .padding()
    .frame(width: 260)
  }
#endif
