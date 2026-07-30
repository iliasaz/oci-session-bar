// Copyright 2026 Ilia Sazonov
// SPDX-License-Identifier: MIT

import Foundation

/// The release the running app was built from.
///
/// `CFBundleShortVersionString` is `$(MARKETING_VERSION)`, and the release workflow
/// archives with `MARKETING_VERSION` set to the GitHub release tag — so the bundle
/// already carries the release name and nothing has to be fetched at runtime.
/// `CFBundleVersion` is `$(CURRENT_PROJECT_VERSION)`, the workflow's run number,
/// which distinguishes two builds of the same tag.
nonisolated struct AppVersion: Equatable, Sendable {
  /// The release tag, e.g. `0.3`.
  let release: String
  /// The build number, absent in local builds that never went through CI.
  let build: String?

  /// Fails when the bundle carries no usable version — a locally built bundle whose
  /// build settings never substituted the `$(…)` placeholders, most likely. Showing
  /// a literal `$(MARKETING_VERSION)` in the menu would be worse than showing nothing.
  init?(infoDictionary: [String: Any]?) {
    guard let release = Self.value(infoDictionary?["CFBundleShortVersionString"]) else { return nil }
    self.release = release
    build = Self.value(infoDictionary?["CFBundleVersion"])
  }

  init?(bundle: Bundle = .main) {
    self.init(infoDictionary: bundle.infoDictionary)
  }

  private static func value(_ raw: Any?) -> String? {
    guard let string = raw as? String, !string.isEmpty, !string.contains("$(") else { return nil }
    return string
  }

  /// What the menu shows. The build number is dropped when it adds nothing — a
  /// fresh checkout has `CURRENT_PROJECT_VERSION` of `1` next to a two-part release.
  var displayName: String {
    guard let build, build != release else { return "Version \(release)" }
    return "Version \(release) (\(build))"
  }
}
