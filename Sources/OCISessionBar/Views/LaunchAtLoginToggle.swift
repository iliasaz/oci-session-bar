// Copyright 2026 Ilia Sazonov
// SPDX-License-Identifier: MIT

import ServiceManagement
import SwiftUI

/// "Launch at login", backed by `SMAppService`.
///
/// `SMAppService.mainApp.status` is the only source of truth — the user can remove
/// the login item from System Settings at any moment, and a copy mirrored into
/// `UserDefaults` would then be a lie. The toggle re-reads the real status whenever
/// the window becomes active again.
struct LaunchAtLoginToggle: View {
  @State private var isEnabled = false
  @State private var failure: String?
  @Environment(\.appearsActive) private var appearsActive

  var body: some View {
    VStack(alignment: .leading) {
      Toggle("Launch at login", isOn: $isEnabled)
      Text("Start OCI Session Bar automatically, so your session is kept alive from the moment you log in.")
        .font(.callout)
        .foregroundStyle(.secondary)
      if let failure {
        Text(failure)
          .font(.callout)
          .foregroundStyle(.red)
      }
    }
    .onAppear(perform: syncStatus)
    .onChange(of: appearsActive) { _, active in
      if active { syncStatus() }
    }
    .onChange(of: isEnabled) { previous, enabled in
      // Ignore the assignment made by syncStatus() itself.
      guard previous != enabled, enabled != (SMAppService.mainApp.status == .enabled) else { return }
      apply(enabled)
    }
  }

  private func syncStatus() {
    isEnabled = SMAppService.mainApp.status == .enabled
  }

  private func apply(_ enabled: Bool) {
    do {
      if enabled {
        try SMAppService.mainApp.register()
      } else {
        try SMAppService.mainApp.unregister()
      }
      failure = nil
    } catch {
      // Deliberately not swallowed with `try?`. Registration genuinely fails for a
      // build that is not signed and installed — running from DerivedData, most
      // often — and a toggle that flips without doing anything is worse than one
      // that explains itself.
      failure = "Could not \(enabled ? "enable" : "disable") launch at login: \(error.localizedDescription)"
      syncStatus()
    }
  }
}

#if DEBUG
  // The toggle reflects the real `SMAppService` status, so in a preview it shows
  // whatever the previewing host is registered as — usually off, and usually
  // failing to register, which is exactly the state worth being able to look at.
  #Preview {
    Form {
      LaunchAtLoginToggle()
    }
    .formStyle(.grouped)
    .frame(width: 520)
  }
#endif
