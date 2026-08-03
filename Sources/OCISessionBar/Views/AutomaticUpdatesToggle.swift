// Copyright 2026 Ilia Sazonov
// SPDX-License-Identifier: MIT

import SwiftUI

/// "Automatically check for updates", backed by Sparkle.
///
/// The toggle binds straight through to `SPUUpdater`, which is where the preference
/// lives; see ``UpdaterModel/automaticallyChecksForUpdates``.
struct AutomaticUpdatesToggle: View {
  @Bindable var updater: UpdaterModel

  var body: some View {
    VStack(alignment: .leading) {
      Toggle("Automatically check for updates", isOn: $updater.automaticallyChecksForUpdates)
      Text("Look for a new version in the background once a day. Nothing is installed until you say so.")
        .font(.callout)
        .foregroundStyle(.secondary)
    }
  }
}

#if DEBUG
  #Preview {
    Form {
      AutomaticUpdatesToggle(updater: .preview())
    }
    .formStyle(.grouped)
    .frame(width: 520)
  }
#endif
