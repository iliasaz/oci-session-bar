// Copyright 2026 Ilia Sazonov
// SPDX-License-Identifier: MIT

import Foundation
import Testing

@testable import OCISessionBar

@Suite("OCI config parsing")
struct OCIConfigFileTests {
  /// The shape the user actually has: an API-key profile alongside the session
  /// profile derived from it.
  static let sample = """
    [DEFAULT]
    user=ocid1.user.oc1..default
    fingerprint=aa:bb
    key_file=~/.oci/oci_api_key.pem
    tenancy=ocid1.tenancy.oc1..default
    region=us-ashburn-1

    # A hand-written comment
    [jroga]
    user=ocid1.user.oc1..jroga
    fingerprint=cc:dd
    key_file=~/.oci/jroga.pem
    tenancy=ocid1.tenancy.oc1..jroga
    region=us-phoenix-1

    [jroga-token]
    user=ocid1.user.oc1..jroga
    fingerprint=ee:ff
    key_file=~/.oci/sessions/jroga-token/oci_api_key.pem
    tenancy=ocid1.tenancy.oc1..jroga
    region=us-phoenix-1
    security_token_file=~/.oci/sessions/jroga-token/token

    [boat]
    key_file=~/.oci/sessions/boat/oci_api_key.pem
    region=eu-frankfurt-1
    security_token_file=~/.oci/sessions/boat/token
    """

  @Test("Every section is read, in file order")
  func parsesAllProfiles() {
    let profiles = OCIConfigFile.parse(Self.sample)
    #expect(profiles.map(\.name) == ["DEFAULT", "jroga", "jroga-token", "boat"])
  }

  @Test("Session profiles are exactly those with a security_token_file")
  func identifiesSessionProfiles() {
    let profiles = OCIConfigFile.parse(Self.sample)
    #expect(profiles.filter(\.isSessionProfile).map(\.name) == ["jroga-token", "boat"])
  }

  @Test("Only complete API-key profiles can authorize a new session")
  func identifiesAuthorizingProfiles() {
    let profiles = OCIConfigFile.parse(Self.sample)
    #expect(profiles.filter(\.canAuthorizeSession).map(\.name) == ["DEFAULT", "jroga"])
  }

  /// `boat` has a token but no API key, so it has no silent renewal path — it must
  /// not be offered as a source, and it must not be mistaken for one.
  @Test("A token profile is never also an authorizing profile")
  func tokenProfileIsNotAuthorizing() {
    let boat = OCIConfigFile.parse(Self.sample).first { $0.name == "boat" }
    #expect(boat?.isSessionProfile == true)
    #expect(boat?.canAuthorizeSession == false)
  }

  @Test("An incomplete API-key profile is rejected as a source")
  func rejectsIncompleteAuthorizingProfile() {
    // No `user`, so it cannot sign — offering it would fail at the network call.
    let profiles = OCIConfigFile.parse(
      """
      [partial]
      fingerprint=aa:bb
      key_file=~/.oci/k.pem
      tenancy=ocid1.tenancy.oc1..x
      region=us-ashburn-1
      """
    )
    #expect(profiles.first?.canAuthorizeSession == false)
  }

  /// The writer treats a header as ending at the first `]`. The reader has to
  /// agree, or a trailing comment would make one profile swallow the next.
  @Test("A section header ends at the first bracket, not the end of the line")
  func parsesHeaderWithTrailingComment() {
    let profiles = OCIConfigFile.parse(
      """
      [work] ; my other tenancy
      region=us-ashburn-1

      [other]
      region=us-phoenix-1
      """
    )
    #expect(profiles.map(\.name) == ["work", "other"])
    #expect(profiles.first?.region == "us-ashburn-1")
  }

  @Test("A config file copied in from Windows parses the same")
  func parsesCRLF() {
    let profiles = OCIConfigFile.parse(
      "[a]\r\nregion=us-ashburn-1\r\n\r\n[b]\r\nregion=us-phoenix-1\r\n"
    )
    #expect(profiles.map(\.name) == ["a", "b"])
    #expect(profiles.first?.region == "us-ashburn-1")
  }

  @Test("Comments and blank lines are ignored", arguments: ["#", ";"])
  func ignoresComments(marker: String) {
    let profiles = OCIConfigFile.parse(
      """
      \(marker) leading comment
      [a]

      \(marker) inner comment
      region=us-ashburn-1
      """
    )
    #expect(profiles.count == 1)
    #expect(profiles.first?.entries == ["region": "us-ashburn-1"])
  }

  @Test("A value containing '=' keeps everything after the first separator")
  func parsesValueContainingSeparator() {
    let profiles = OCIConfigFile.parse("[a]\npass=abc=def==\n")
    #expect(profiles.first?.entries["pass"] == "abc=def==")
  }

  @Test("Keys before any section header are discarded")
  func ignoresLeadingKeys() {
    let profiles = OCIConfigFile.parse("stray=value\n[a]\nregion=us-ashburn-1\n")
    #expect(profiles.count == 1)
    #expect(profiles.first?.entries["stray"] == nil)
  }

  @Test("A missing config file is an empty list, not an error")
  func missingFileYieldsNoProfiles() throws {
    let path = FileManager.default.temporaryDirectory
      .appending(path: "does-not-exist-\(UUID().uuidString)")
      .path
    #expect(try OCIConfigFile.profiles(at: path).isEmpty)
  }

  @Test("A real file on disk round-trips")
  func readsFromDisk() throws {
    let url = FileManager.default.temporaryDirectory.appending(path: "config-\(UUID().uuidString)")
    try Self.sample.write(to: url, atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(at: url) }

    #expect(try OCIConfigFile.sessionProfiles(at: url.path).map(\.name) == ["jroga-token", "boat"])
    #expect(try OCIConfigFile.authorizingProfiles(at: url.path).map(\.name) == ["DEFAULT", "jroga"])
  }
}
