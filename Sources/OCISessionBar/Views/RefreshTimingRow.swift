// Copyright 2026 Ilia Sazonov
// SPDX-License-Identifier: MIT

import SwiftUI

/// Chooses how much time may be left on the token before it is refreshed.
struct RefreshTimingRow: View {
  @Bindable var model: AuthModel

  /// Half-life for the hour-long session OCI issues, then progressively later
  /// points. Fewer, later exchanges trade margin for quiet: at 10 minutes a failed
  /// refresh has only two backoff attempts before the session lapses.
  private static let choices = [30, 20, 15, 10]

  var body: some View {
    Toggle("Randomize refresh time", isOn: $model.randomizedRefreshEnabled)

    Picker("Refresh when", selection: $model.refreshWhenRemainingMinutes) {
      ForEach(Self.choices, id: \.self) { minutes in
        Text("\(minutes) minutes left").tag(minutes)
      }
    }
    // A randomized schedule chooses its own point, so the fixed threshold is moot.
    .disabled(model.randomizedRefreshEnabled)

    Text(explanation)
      .font(.callout)
      .foregroundStyle(.secondary)
  }

  private var explanation: String {
    if model.randomizedRefreshEnabled {
      return """
        Each refresh is scheduled at a random time between half-life and five \
        minutes before the token expires — never before half its life has passed.
        """
    }
    guard let status = model.status else {
      return "A token is never refreshed before half its life has passed, however this is set."
    }
    let point = Int(status.refreshPoint(whenRemaining: model.refreshWhenRemaining) / 60)
    let lifetime = Int(status.lifetime / 60)
    // Refreshing restarts the clock — the new token runs a full lifetime from the
    // moment of the exchange — so the gap between refreshes is whatever is spent
    // before asking, and a later trigger is simply a longer gap.
    let cadence = lifetime - point
    if point < model.refreshWhenRemainingMinutes {
      return """
        This session lasts \(lifetime) minutes, so it refreshes at \(point) minutes left, \
        about every \(cadence) minutes — a token is never refreshed before half its life \
        has passed.
        """
    }
    return """
      This session lasts \(lifetime) minutes, so it refreshes at \(point) minutes left — \
      about every \(cadence) minutes.
      """
  }
}

#if DEBUG
  #Preview("Default — half-life of an hour-long session") {
    Form {
      RefreshTimingRow(model: .preview())
    }
    .formStyle(.grouped)
    .frame(width: 520)
  }

  #Preview("No session") {
    Form {
      RefreshTimingRow(model: .preview(profileName: nil, status: nil))
    }
    .formStyle(.grouped)
    .frame(width: 520)
  }

  #Preview("Randomized — picker disabled") {
    let model = AuthModel.preview()
    model.randomizedRefreshEnabled = true
    return Form {
      RefreshTimingRow(model: model)
    }
    .formStyle(.grouped)
    .frame(width: 520)
  }
#endif
