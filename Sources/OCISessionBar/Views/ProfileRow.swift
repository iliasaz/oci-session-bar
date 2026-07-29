// Copyright 2026 Ilia Sazonov
// SPDX-License-Identifier: MIT

import SwiftUI

/// Which session profile the menu bar tracks.
struct ProfileRow: View {
  @Bindable var model: AuthModel
  @Binding var isCreatingProfile: Bool

  var body: some View {
    Picker("Profile", selection: $model.profileName) {
      ForEach(model.sessionProfiles) { profile in
        Text(profile.name).tag(profile.name as String?)
      }
      if model.sessionProfiles.isEmpty {
        Text("None").tag(nil as String?)
      }
    }
    .disabled(model.sessionProfiles.isEmpty)

    HStack {
      if model.sessionProfiles.isEmpty {
        Text("No profiles with a `security_token_file` entry were found in this config file.")
          .font(.callout)
          .foregroundStyle(.secondary)
      }
      Spacer()
      Button("New Session Profile…", action: startCreatingProfile)
    }
  }

  private func startCreatingProfile() {
    isCreatingProfile = true
  }
}

#if DEBUG
  #Preview("With profiles") {
    @Previewable @State var isCreating = false
    Form {
      ProfileRow(model: .preview(), isCreatingProfile: $isCreating)
    }
    .formStyle(.grouped)
    .frame(width: 520)
  }

  #Preview("Empty config") {
    @Previewable @State var isCreating = false
    Form {
      ProfileRow(
        model: .preview(profileName: nil, status: nil),
        isCreatingProfile: $isCreating
      )
    }
    .formStyle(.grouped)
    .frame(width: 520)
  }
#endif
