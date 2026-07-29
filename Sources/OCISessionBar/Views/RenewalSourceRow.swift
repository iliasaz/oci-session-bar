// Copyright 2026 Ilia Sazonov
// SPDX-License-Identifier: MIT

import SwiftUI

/// Optionally links the selected profile to an API-key profile that can renew it
/// without a browser.
struct RenewalSourceRow: View {
  @Bindable var model: AuthModel

  var body: some View {
    Picker("Renew using", selection: $model.renewalSourceForSelectedProfile) {
      Text("Browser sign-in").tag(nil as String?)
      ForEach(model.authorizingProfiles) { candidate in
        Text(candidate.name).tag(candidate.name as String?)
      }
    }

    Text(explanation)
      .font(.callout)
      .foregroundStyle(.secondary)
  }

  private var explanation: String {
    model.renewalSourceForSelectedProfile == nil
      ? "When the session can no longer be refreshed, the OCI Console opens in your browser."
      : "When the session can no longer be refreshed, a new one is minted silently using that profile's API key — no browser."
  }
}

#if DEBUG
  #Preview("Silent renewal available") {
    Form {
      RenewalSourceRow(model: .preview())
    }
    .formStyle(.grouped)
    .frame(width: 520)
  }

  #Preview("Browser sign-in only") {
    // `boat` has no linked API-key profile, which is the common case.
    Form {
      RenewalSourceRow(model: .preview(profileName: "boat"))
    }
    .formStyle(.grouped)
    .frame(width: 520)
  }
#endif
