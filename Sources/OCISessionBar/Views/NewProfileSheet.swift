// Copyright 2026 Ilia Sazonov
// SPDX-License-Identifier: MIT

import OCIKit
import SwiftUI

/// Creates a new session-token profile.
///
/// Two ways in, and which one is available depends on what the config file already
/// holds. If there is an API-key profile, its key can authorise a new session
/// directly — this is the `jroga` → `jroga-token` case, and it needs no browser. If
/// there is not, the OCI Console signs the user in interactively instead.
///
/// Existing profiles are never modified. A name that is already taken is refused
/// outright rather than merged into or overwritten, because the source profile is
/// often the only copy of a working API-key configuration.
struct NewProfileSheet: View {
  @Bindable var model: AuthModel
  @Environment(\.dismiss) private var dismiss

  @State private var name = ""
  @State private var sourceProfileName: String?
  @State private var region = ""
  @State private var failure: String?
  @State private var isWorking = false

  var body: some View {
    Form {
      Section {
        TextField("Profile name", text: $name)
          .onChange(of: sourceProfileName) { _, source in applyDefaults(for: source) }
        if nameCollides {
          Text("“\(name)” already exists. Existing profiles are never modified — pick another name.")
            .font(.callout)
            .foregroundStyle(.red)
        }
      }

      Section("Authorize with") {
        Picker("Source", selection: $sourceProfileName) {
          Text("Browser sign-in").tag(nil as String?)
          ForEach(model.authorizingProfiles) { profile in
            Text("\(profile.name) (API key)").tag(profile.name as String?)
          }
        }
        Text(
          sourceProfileName == nil
            ? "The OCI Console opens in your browser. Use this when you have no API key configured."
            : "A session is minted directly from that profile's API key. No browser, and the source profile is only read."
        )
        .font(.callout)
        .foregroundStyle(.secondary)

        TextField("Region", text: $region)
          .disabled(sourceProfileName != nil)
      }

      if let failure {
        Section {
          Text(failure)
            .font(.callout)
            .foregroundStyle(.red)
        }
      }
    }
    .formStyle(.grouped)
    .frame(width: 480)
    .fixedSize(horizontal: false, vertical: true)
    .safeAreaInset(edge: .bottom) {
      HStack {
        Spacer()
        Button("Cancel", role: .cancel) { dismiss() }
          .keyboardShortcut(.cancelAction)
        Button(sourceProfileName == nil ? "Sign In…" : "Create", action: create)
          .keyboardShortcut(.defaultAction)
          .disabled(!isValid || isWorking)
      }
      .padding()
    }
    .onAppear { applyDefaults(for: sourceProfileName) }
    .disabled(isWorking)
  }

  private var trimmedName: String { name.trimmingCharacters(in: .whitespaces) }

  /// Checked against the names the model already holds rather than by re-reading
  /// the config file: this is consulted from `body`, which SwiftUI may evaluate on
  /// every keystroke, and a disk read per keystroke is not acceptable there.
  private var nameCollides: Bool {
    !trimmedName.isEmpty && model.allProfileNames.contains(trimmedName)
  }

  private var isValid: Bool {
    !trimmedName.isEmpty
      && SessionTokenStore.isValidProfileName(trimmedName)
      && !nameCollides
      && !region.trimmingCharacters(in: .whitespaces).isEmpty
  }

  /// Proposes `<source>-token` and inherits the source's region, which is the
  /// convention the user already follows by hand.
  private func applyDefaults(for source: String?) {
    guard let source, let profile = model.authorizingProfiles.first(where: { $0.name == source })
    else { return }
    if trimmedName.isEmpty || trimmedName.hasSuffix("-token") {
      name = "\(source)-token"
    }
    if let sourceRegion = profile.region { region = sourceRegion }
  }

  private func create() {
    isWorking = true
    failure = nil
    Task {
      defer { isWorking = false }
      do {
        let source = model.authorizingProfiles.first { $0.name == sourceProfileName }
        try await model.createProfile(
          named: trimmedName,
          from: source,
          region: region.trimmingCharacters(in: .whitespaces)
        )
        dismiss()
      } catch {
        failure = AuthModel.describe(error)
      }
    }
  }
}
