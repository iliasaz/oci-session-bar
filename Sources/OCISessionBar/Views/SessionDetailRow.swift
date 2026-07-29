// Copyright 2026 Ilia Sazonov
// SPDX-License-Identifier: MIT

import SwiftUI

/// Expiry, time left, and an explicit validate against the service.
struct SessionDetailRow: View {
  @Bindable var model: AuthModel
  @Binding var validationResult: String?

  var body: some View {
    if let status = model.status {
      LabeledContent("Expires", value: status.expiresAt.formatted(date: .abbreviated, time: .standard))
      LabeledContent("Time left", value: model.countdownText)
    } else {
      LabeledContent("Status", value: "No session")
    }

    HStack {
      if let validationResult {
        Text(validationResult)
          .font(.callout)
          .foregroundStyle(.secondary)
      }
      Spacer()
      Button("Validate Now", action: validate)
      .disabled(model.profileName == nil || model.isBusy)
    }
  }

  private func validate() {
    Task { validationResult = await model.validate() }
  }
}

#if DEBUG
  #Preview("Live session") {
    @Previewable @State var result: String?
    Form {
      SessionDetailRow(model: .preview(), validationResult: $result)
    }
    .formStyle(.grouped)
    .frame(width: 520)
  }

  #Preview("Validated") {
    @Previewable @State var result: String? = "Session is valid until 7:42 PM."
    Form {
      SessionDetailRow(model: .preview(), validationResult: $result)
    }
    .formStyle(.grouped)
    .frame(width: 520)
  }

  #Preview("No session") {
    @Previewable @State var result: String?
    Form {
      SessionDetailRow(model: .preview(status: nil), validationResult: $result)
    }
    .formStyle(.grouped)
    .frame(width: 520)
  }
#endif
