// Copyright 2026 Ilia Sazonov
// SPDX-License-Identifier: MIT

import AppKit
import OCIKit
import SwiftUI

/// The standard macOS Settings window.
struct SettingsView: View {
  @Bindable var model: AuthModel
  let updater: UpdaterModel
  @State private var isCreatingProfile = false
  @State private var validationResult: String?

  var body: some View {
    Form {
      Section("OCI configuration") {
        ConfigFileRow(model: model)
        ProfileRow(model: model, isCreatingProfile: $isCreatingProfile)
      }

      if model.profileName != nil {
        Section("Renewal") {
          RenewalSourceRow(model: model)
        }
      }

      Section("Session") {
        SessionDetailRow(model: model, validationResult: $validationResult)
        RefreshTimingRow(model: model)
      }

      Section("Logging") {
        EventLogRow(model: model)
      }

      Section {
        LaunchAtLoginToggle()
        AutomaticUpdatesToggle(updater: updater)
      }
    }
    .formStyle(.grouped)
    .frame(width: 520)
    .fixedSize(horizontal: false, vertical: true)
    .sheet(isPresented: $isCreatingProfile) {
      NewProfileSheet(model: model)
    }
    .onChange(of: model.profileName) { _, _ in validationResult = nil }
  }
}

#if DEBUG
  #Preview("Settings") {
    SettingsView(model: .preview(), updater: .preview())
  }

  #Preview("No session profiles") {
    SettingsView(model: .preview(profileName: nil, status: nil), updater: .preview())
  }
#endif
