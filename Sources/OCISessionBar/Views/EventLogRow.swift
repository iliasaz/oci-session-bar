// Copyright 2026 Ilia Sazonov
// SPDX-License-Identifier: MIT

import SwiftUI

/// Turns the refresh/auth event log on, and shows where it is written.
struct EventLogRow: View {
  @Bindable var model: AuthModel

  var body: some View {
    Toggle("Log refresh and auth events", isOn: $model.logEventsEnabled)

    if model.logEventsEnabled {
      LabeledContent("Log file") {
        Text(model.eventLogPath)
          // The point of surfacing the path is to copy it, so it is selectable
          // rather than a plain label.
          .textSelection(.enabled)
          .lineLimit(1)
          .truncationMode(.middle)
          .foregroundStyle(.secondary)
          .help(model.eventLogPath)
      }
    }
  }
}

#if DEBUG
  #Preview("Logging off") {
    Form {
      EventLogRow(model: .preview())
    }
    .formStyle(.grouped)
    .frame(width: 520)
  }
#endif
