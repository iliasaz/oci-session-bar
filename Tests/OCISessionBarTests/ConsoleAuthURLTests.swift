// Copyright 2026 Ilia Sazonov
// SPDX-License-Identifier: MIT

import Foundation
import Testing

@testable import OCISessionBar

@Suite("Console authorize URL")
struct ConsoleAuthURLTests {
  private func queryItems(_ url: URL) -> [String: String] {
    let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
    return Dictionary(
      (components?.queryItems ?? []).compactMap { item in
        item.value.map { (item.name, $0) }
      },
      uniquingKeysWith: { first, _ in first }
    )
  }

  @Test("The commercial realm resolves to login.<region>.oraclecloud.com")
  func buildsCommercialHost() throws {
    let url = try ConsoleAuthURL.build(region: "us-ashburn-1", publicKeyParameter: "KEY")
    #expect(url.host() == "login.us-ashburn-1.oraclecloud.com")
    #expect(url.path() == "/v1/oauth2/authorize")
    #expect(url.scheme == "https")
  }

  @Test(
    "Non-commercial regions resolve to their own realm's domain",
    arguments: [
      ("us-gov-ashburn-1", "login.us-gov-ashburn-1.oraclegovcloud.com"),
      ("uk-gov-london-1", "login.uk-gov-london-1.oraclegovcloud.uk"),
      ("eu-frankfurt-2", "login.eu-frankfurt-2.oraclecloud.eu"),
    ]
  )
  func buildsRealmHosts(region: String, expectedHost: String) throws {
    let url = try ConsoleAuthURL.build(region: region, publicKeyParameter: "KEY")
    #expect(url.host() == expectedHost)
  }

  /// Matching the Python SDK: a region nobody has heard of is assumed commercial
  /// rather than treated as an error.
  @Test("An unknown region falls back to the commercial realm")
  func fallsBackToCommercial() throws {
    let url = try ConsoleAuthURL.build(region: "xx-nowhere-1", publicKeyParameter: "KEY")
    #expect(url.host() == "login.xx-nowhere-1.oraclecloud.com")
  }

  /// The single most breakable value in the flow: the redirect URI is registered
  /// against `client_id=iaas_console`, so it cannot vary — no trailing slash, no
  /// path, no alternative port.
  @Test("The redirect URI is exactly http://localhost:8181")
  func pinsRedirectURI() throws {
    let url = try ConsoleAuthURL.build(region: "us-ashburn-1", publicKeyParameter: "KEY")
    #expect(queryItems(url)["redirect_uri"] == "http://localhost:8181")
    #expect(ConsoleAuthURL.redirectPort == 8181)
  }

  @Test("Every parameter the Console requires is present")
  func includesRequiredParameters() throws {
    let url = try ConsoleAuthURL.build(region: "us-ashburn-1", publicKeyParameter: "PUBKEY")
    let items = queryItems(url)
    #expect(items["action"] == "login")
    #expect(items["client_id"] == "iaas_console")
    #expect(items["response_type"] == "token id_token")
    #expect(items["scope"] == "openid")
    #expect(items["public_key"] == "PUBKEY")
    #expect(items["nonce"]?.isEmpty == false)
  }

  @Test("Each sign-in gets its own nonce")
  func generatesFreshNonce() throws {
    let first = try ConsoleAuthURL.build(region: "us-ashburn-1", publicKeyParameter: "KEY")
    let second = try ConsoleAuthURL.build(region: "us-ashburn-1", publicKeyParameter: "KEY")
    #expect(queryItems(first)["nonce"] != queryItems(second)["nonce"])
  }

  @Test("Optional tenancy and provider hints are only sent when set")
  func includesOptionalHints() throws {
    let bare = try ConsoleAuthURL.build(region: "us-ashburn-1", publicKeyParameter: "KEY")
    #expect(queryItems(bare)["tenant"] == nil)
    #expect(queryItems(bare)["provider"] == nil)

    let hinted = try ConsoleAuthURL.build(
      region: "us-ashburn-1",
      publicKeyParameter: "KEY",
      tenancyName: "acme",
      identityProvider: "OracleIdentityCloudService"
    )
    #expect(queryItems(hinted)["tenant"] == "acme")
    #expect(queryItems(hinted)["provider"] == "OracleIdentityCloudService")
  }

  /// A JWK parameter is base64 with `=` padding and `-`/`_`; none of it may leak
  /// into the query unescaped.
  @Test("A padded base64url public key survives percent-encoding")
  func encodesPublicKeySafely() throws {
    let key = "eyJhbGciOiJSUzI1NiJ9-_=="
    let url = try ConsoleAuthURL.build(region: "us-ashburn-1", publicKeyParameter: key)
    #expect(queryItems(url)["public_key"] == key)
  }

  @Test("A realm override wins over the table")
  func honoursDomainOverride() {
    #expect(Realms.domain(forRegion: "us-ashburn-1", override: "example.com") == "example.com")
    #expect(Realms.domain(forRegion: "us-ashburn-1", override: "") == "oraclecloud.com")
  }

  @Test("Every realm referenced by the region table actually has a domain")
  func realmTableIsConsistent() {
    for (region, realm) in Realms.regionRealms {
      #expect(Realms.secondLevelDomains[realm] != nil, "\(region) maps to unknown realm \(realm)")
    }
  }
}
