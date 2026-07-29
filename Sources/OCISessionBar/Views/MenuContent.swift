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

    Button("Settings…", action: showSettings)
      .keyboardShortcut(",", modifiers: .command)

    Divider()

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
