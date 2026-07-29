// Copyright 2026 Ilia Sazonov
// SPDX-License-Identifier: MIT

import SwiftUI

/// The first line of the menu: which profile is being tracked, and when it lapses.
struct MenuStatusLine: View {
  let model: AuthModel

  var body: some View {
    // The same string the menu bar item's tooltip shows, by construction.
    Text(model.statusSummary)
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
