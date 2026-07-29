// Copyright 2026 Ilia Sazonov
// SPDX-License-Identifier: MIT

import Foundation
import OCIKit
import Testing

@testable import OCISessionBar

/// The app rewrites config sections, and the user's own keys must survive it.
/// `SessionTokenStore.upsertProfile` replaces a section wholesale, so without the
/// preserve/restore pass a hand-added `pass_phrase` would vanish on every
/// re-authentication.
@Suite("Config preservation")
struct ConfigPreservationTests {
  private func withTemporaryConfig(
    _ contents: String,
    _ body: (String) throws -> Void
  ) throws {
    let url = FileManager.default.temporaryDirectory
      .appending(path: "oci-config-\(UUID().uuidString)")
    try contents.write(to: url, atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(at: url) }
    try body(url.path)
  }

  static let config = """
    [jroga]
    user=ocid1.user.oc1..jroga
    fingerprint=cc:dd
    key_file=~/.oci/jroga.pem
    tenancy=ocid1.tenancy.oc1..jroga
    region=us-phoenix-1

    [jroga-token]
    fingerprint=ee:ff
    key_file=~/.oci/sessions/jroga-token/oci_api_key.pem
    region=us-phoenix-1
    security_token_file=~/.oci/sessions/jroga-token/token
    pass_phrase=hunter2
    compartment-id=ocid1.compartment.oc1..mine
    """

  @Test("Only keys the app does not manage are captured")
  func capturesUnmanagedKeys() throws {
    try withTemporaryConfig(Self.config) { path in
      let preserved = SessionService.preservedEntries(
        configFilePath: path, profile: "jroga-token"
      )
      #expect(preserved == ["pass_phrase": "hunter2", "compartment-id": "ocid1.compartment.oc1..mine"])
    }
  }

  @Test("A profile that does not exist yet has nothing to preserve")
  func handlesMissingProfile() throws {
    try withTemporaryConfig(Self.config) { path in
      #expect(SessionService.preservedEntries(configFilePath: path, profile: "brand-new").isEmpty)
    }
  }

  @Test("Restoring puts unmanaged keys back without disturbing the managed ones")
  func restoresUnmanagedKeys() throws {
    try withTemporaryConfig(Self.config) { path in
      let preserved = SessionService.preservedEntries(
        configFilePath: path, profile: "jroga-token"
      )
      // Stand in for what persistSession does: replace the section wholesale.
      try SessionTokenStore.upsertProfile(
        configFilePath: path,
        profile: "jroga-token",
        entries: [
          (key: "fingerprint", value: "11:22"),
          (key: "key_file", value: "/new/key.pem"),
          (key: "region", value: "us-phoenix-1"),
          (key: "security_token_file", value: "/new/token"),
        ]
      )
      #expect(
        SessionService.preservedEntries(configFilePath: path, profile: "jroga-token").isEmpty,
        "the wholesale rewrite should have dropped them"
      )

      try SessionService.restore(preserved, configFilePath: path, profile: "jroga-token")

      let section = try SessionTokenStore.profileSection(
        configFilePath: path, profile: "jroga-token"
      )
      #expect(section["pass_phrase"] == "hunter2")
      #expect(section["compartment-id"] == "ocid1.compartment.oc1..mine")
      // The freshly written session values win — they describe the new session.
      #expect(section["fingerprint"] == "11:22")
      #expect(section["security_token_file"] == "/new/token")
    }
  }

  /// The whole point of the "-token" convention: the API-key profile it was copied
  /// from is never touched.
  @Test("Rewriting a token profile leaves every other profile untouched")
  func leavesOtherProfilesAlone() throws {
    try withTemporaryConfig(Self.config) { path in
      let before = try SessionTokenStore.profileSection(configFilePath: path, profile: "jroga")

      try SessionTokenStore.upsertProfile(
        configFilePath: path,
        profile: "jroga-token",
        entries: [(key: "region", value: "us-phoenix-1")]
      )

      let after = try SessionTokenStore.profileSection(configFilePath: path, profile: "jroga")
      #expect(before == after)
      #expect(after["key_file"] == "~/.oci/jroga.pem")
    }
  }

  @Test("Profile names the SDK would reject are caught before any write")
  func validatesProfileNames() {
    #expect(SessionTokenStore.isValidProfileName("jroga-token"))
    #expect(SessionTokenStore.isValidProfileName("a.b_c-1"))
    #expect(SessionTokenStore.isValidProfileName("") == false)
    #expect(SessionTokenStore.isValidProfileName("has space") == false)
    #expect(SessionTokenStore.isValidProfileName("has]bracket") == false)
    // The CLI allows '@' in a profile name; the SDK does not, so the UI must not
    // offer it either.
    #expect(SessionTokenStore.isValidProfileName("user@tenancy") == false)
  }
}
