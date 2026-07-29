// Copyright 2026 Ilia Sazonov
// SPDX-License-Identifier: MIT

import SwiftUI

/// The first line of the menu: which profile is being tracked, and when it lapses.
struct MenuStatusLine: View {
  let model: AuthModel

  var body: some View {
    if let profile = model.profileName {
      if let status = model.status, status.isValid(at: model.now) {
        Text("\(profile) — expires \(status.expiresAt.formatted(date: .omitted, time: .shortened))")
      } else {
        Text("\(profile) — no valid session")
      }
    } else if model.sessionProfiles.isEmpty {
      Text("No session profiles found")
    } else {
      Text("No profile selected")
    }
  }
}

#if DEBUG
  #Preview("Live session") {
    MenuStatusLine(model: .preview())
      .padding()
  }

  #Preview("No valid session") {
    MenuStatusLine(model: .preview(status: .previewExpired))
      .padding()
  }

  #Preview("Nothing configured") {
    MenuStatusLine(model: .preview(profileName: nil, status: nil))
      .padding()
  }
#endif
