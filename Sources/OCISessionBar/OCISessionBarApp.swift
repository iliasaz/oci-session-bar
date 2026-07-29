// Copyright 2026 Ilia Sazonov
// SPDX-License-Identifier: MIT

import SwiftUI

/// A menu bar utility that shows how long the current OCI session token has left,
/// and keeps it alive so the browser sign-in flow stays rare.
///
/// There is no `WindowGroup`: with `LSUIElement` set, the app has no Dock icon and
/// no main window, and its whole surface is the menu bar item plus the Settings
/// scene.
@main
struct OCISessionBarApp: App {
  @State private var model = AuthModel()

  var body: some Scene {
    MenuBarExtra {
      MenuContent(model: model)
    } label: {
      MenuBarLabel(presentation: model.menuBarPresentation, appearance: model.menuBarAppearance)
        // `.help()` is the standard route to a tooltip, but a MenuBarExtra label
        // is rasterized into the status button, so it does not reliably survive.
        // `StatusItemTooltip`, driven from the model's tick, is what actually
        // makes the tooltip appear; this stays because it costs nothing and is
        // the correct expression of the intent.
        .help(model.statusSummary)
    }
    // `.menu` rather than `.window`: the design calls for menu items, and this way
    // dismissal, keyboard navigation and system styling come for free.
    .menuBarExtraStyle(.menu)

    Settings {
      SettingsView(model: model)
    }
  }
}
