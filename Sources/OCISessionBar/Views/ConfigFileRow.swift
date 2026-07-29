// Copyright 2026 Ilia Sazonov
// SPDX-License-Identifier: MIT

import AppKit
import OCIKit
import SwiftUI

/// The path to the config file, with a file picker.
struct ConfigFileRow: View {
  @Bindable var model: AuthModel

  var body: some View {
    LabeledContent("Config file") {
      HStack {
        Text(model.configFilePath)
          .lineLimit(1)
          .truncationMode(.middle)
          .foregroundStyle(.secondary)
          .help(model.configFilePath)
        Spacer()
        Button("Choose…", action: choose)
      }
    }
  }

  private func choose() {
    let panel = NSOpenPanel()
    panel.title = "Choose your OCI config file"
    panel.canChooseFiles = true
    panel.canChooseDirectories = false
    panel.allowsMultipleSelection = false
    // ~/.oci is a hidden directory; without this the user cannot navigate into it
    // even though the panel opens there.
    panel.showsHiddenFiles = true
    panel.directoryURL = URL(
      fileURLWithPath: SessionTokenStore.expandingTilde("~/.oci"), isDirectory: true
    )
    NSApp.activate(ignoringOtherApps: true)
    guard panel.runModal() == .OK, let url = panel.url else { return }
    model.configFilePath = url.path(percentEncoded: false)
  }
}

#if DEBUG
  #Preview {
    Form {
      ConfigFileRow(model: .preview())
    }
    .formStyle(.grouped)
    .frame(width: 520)
  }
#endif
