// Copyright 2026 Ilia Sazonov
// SPDX-License-Identifier: MIT

import Foundation
import OCIKit

/// One profile (INI section) of an OCI config file.
nonisolated struct OCIProfile: Identifiable, Hashable, Sendable {
  var id: String { name }
  let name: String
  let entries: [String: String]

  var region: String? { entries["region"] }
  var keyFile: String? { entries["key_file"] }
  var securityTokenFile: String? { entries["security_token_file"] }

  /// A session-token profile: the app can show a countdown for it and refresh it.
  /// This is exactly the CLI's own test — the presence of `security_token_file`.
  var isSessionProfile: Bool { securityTokenFile?.isEmpty == false }

  /// An API-key profile that can authorise minting a *new* session token without
  /// a browser. Requires the full signing quartet; a profile carrying only some of
  /// it cannot sign, so offering it as a source would fail at the network call.
  var canAuthorizeSession: Bool {
    !isSessionProfile
      && keyFile?.isEmpty == false
      && entries["fingerprint"]?.isEmpty == false
      && entries["user"]?.isEmpty == false
      && entries["tenancy"]?.isEmpty == false
      && region?.isEmpty == false
  }
}

/// Reads OCI config files.
///
/// The SDK's ``SessionTokenStore/profileSection(configFilePath:profile:)`` returns a
/// single named section, but the Settings pickers need to *enumerate* every profile,
/// so this reads the file itself. Section headers are recognised the same way
/// `INIParser`, `SessionTokenStore` and the CLI's `configparser` recognise them —
/// the name ends at the first `]`, so `[work] ; comment` and CRLF files both parse
/// the way the writer assumes they will.
nonisolated enum OCIConfigFile {
  static let defaultPath = SessionTokenStore.defaultConfigFilePath

  enum Failure: LocalizedError {
    case unreadable(path: String, underlying: String)

    var errorDescription: String? {
      switch self {
      case .unreadable(let path, let underlying):
        "Could not read the OCI config file at \(path): \(underlying)"
      }
    }
  }

  /// Every profile in the file, in the order they appear.
  ///
  /// A missing file is not an error — it yields no profiles, which is what a
  /// first-run user has. A file that exists but cannot be read *is* an error, and
  /// must stay distinguishable: treating it as empty is how a config file gets
  /// silently replaced by a single profile later on.
  static func profiles(at path: String = defaultPath) throws -> [OCIProfile] {
    let expanded = SessionTokenStore.expandingTilde(path)
    guard FileManager.default.fileExists(atPath: expanded) else { return [] }
    let text: String
    do {
      text = try String(contentsOfFile: expanded, encoding: .utf8)
    } catch {
      throw Failure.unreadable(path: expanded, underlying: error.localizedDescription)
    }
    return parse(text)
  }

  /// Profiles the app can track: those with a `security_token_file`.
  static func sessionProfiles(at path: String = defaultPath) throws -> [OCIProfile] {
    try profiles(at: path).filter(\.isSessionProfile)
  }

  /// Profiles usable as the *source* of a new session, i.e. API-key profiles.
  static func authorizingProfiles(at path: String = defaultPath) throws -> [OCIProfile] {
    try profiles(at: path).filter(\.canAuthorizeSession)
  }

  /// The pure text transform, exposed for testing.
  static func parse(_ text: String) -> [OCIProfile] {
    var profiles: [OCIProfile] = []
    var currentName: String?
    var currentEntries: [String: String] = [:]

    func flush() {
      guard let currentName else { return }
      profiles.append(OCIProfile(name: currentName, entries: currentEntries))
      currentEntries = [:]
    }

    // Split on *any* newline rather than on "\n". Swift treats CRLF as a single
    // Character, so `split(separator: "\n")` does not divide a Windows-authored
    // config file at all — it comes back as one enormous line and every profile
    // after the first disappears.
    for rawLine in text.split(whereSeparator: \.isNewline) {
      let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
      if line.isEmpty || line.hasPrefix("#") || line.hasPrefix(";") { continue }

      if line.hasPrefix("["), let close = line.firstIndex(of: "]") {
        flush()
        let name = line[line.index(after: line.startIndex)..<close]
        currentName = name.filter { !$0.isWhitespace }
        continue
      }

      guard currentName != nil, let separator = line.firstIndex(of: "=") else { continue }
      let key = line[line.startIndex..<separator].trimmingCharacters(in: .whitespaces)
      let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)
      if !key.isEmpty { currentEntries[key] = value }
    }
    flush()
    return profiles
  }
}
