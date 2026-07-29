// Copyright 2026 Ilia Sazonov
// SPDX-License-Identifier: MIT

import Foundation

/// Maps an OCI region onto the DNS domain its Console lives under.
///
/// The SDK's own `Region.urlPart` is internal, so the realm table is duplicated
/// here. Only the non-commercial regions need listing: everything else falls back
/// to `oc1`/`oraclecloud.com`, which is exactly what the Python SDK does for a
/// region it does not recognise.
nonisolated enum Realms {
  /// Realm key to second-level domain.
  static let secondLevelDomains: [String: String] = [
    "oc1": "oraclecloud.com",
    "oc2": "oraclegovcloud.com",
    "oc3": "oraclegovcloud.com",
    "oc4": "oraclegovcloud.uk",
    "oc8": "oraclecloud8.com",
    "oc9": "oraclecloud9.com",
    "oc10": "oraclecloud10.com",
    "oc14": "oraclecloud14.com",
    "oc15": "oraclecloud15.com",
    "oc19": "oraclecloud.eu",
    "oc20": "oraclecloud20.com",
    "oc21": "oraclecloud21.com",
    "oc23": "oraclecloud23.com",
    "oc24": "oraclecloud24.com",
    "oc26": "oraclecloud26.com",
    "oc29": "oraclecloud29.com",
    "oc35": "oraclecloud35.com",
    "oc42": "oraclecloud42.com",
    "oc51": "oraclecloud51.com",
    "oc52": "oraclecloud52.com",
  ]

  /// Region to realm, for every region outside the commercial realm.
  static let regionRealms: [String: String] = [
    "us-langley-1": "oc2", "us-luke-1": "oc2",
    "us-gov-ashburn-1": "oc3", "us-gov-chicago-1": "oc3", "us-gov-phoenix-1": "oc3",
    "uk-gov-london-1": "oc4", "uk-gov-cardiff-1": "oc4",
    "eu-frankfurt-2": "oc19", "eu-madrid-2": "oc19",
    "eu-jovanovac-1": "oc20",
    "me-dcc-doha-1": "oc21", "me-alrayyan-1": "oc21",
    "us-somerset-1": "oc23", "us-thames-1": "oc23",
    "eu-dcc-zurich-1": "oc24", "eu-crissier-1": "oc24",
    "ap-dcc-gazipur-1": "oc29",
    "eu-dcc-milan-1": "oc35",
  ]

  static let defaultDomain = "oraclecloud.com"

  static func domain(forRegion region: String, override: String? = nil) -> String {
    if let override, !override.isEmpty { return override }
    guard let realm = regionRealms[region.lowercased()] else { return defaultDomain }
    return secondLevelDomains[realm] ?? defaultDomain
  }
}

/// The Console authorize URL that starts an interactive sign-in, and the loopback
/// port its redirect comes back to.
nonisolated enum ConsoleAuthURL {
  /// Fixed, and not a choice this app gets to make: `http://localhost:8181` is the
  /// redirect URI registered against `client_id=iaas_console`. A different port is
  /// rejected by the service, so a port conflict has to be reported to the user
  /// rather than worked around.
  static let redirectPort: UInt16 = 8181

  static func build(
    region: String,
    publicKeyParameter: String,
    tenancyName: String? = nil,
    identityProvider: String? = nil,
    domainOverride: String? = nil
  ) throws -> URL {
    var components = URLComponents()
    components.scheme = "https"
    components.host = "login.\(region).\(Realms.domain(forRegion: region, override: domainOverride))"
    components.path = "/v1/oauth2/authorize"

    var query: [URLQueryItem] = [
      URLQueryItem(name: "action", value: "login"),
      URLQueryItem(name: "client_id", value: "iaas_console"),
      URLQueryItem(name: "response_type", value: "token id_token"),
      URLQueryItem(name: "nonce", value: UUID().uuidString.lowercased()),
      URLQueryItem(name: "scope", value: "openid"),
      URLQueryItem(name: "public_key", value: publicKeyParameter),
      URLQueryItem(name: "redirect_uri", value: "http://localhost:\(redirectPort)"),
    ]
    if let tenancyName, !tenancyName.isEmpty {
      query.append(URLQueryItem(name: "tenant", value: tenancyName))
    }
    if let identityProvider, !identityProvider.isEmpty {
      query.append(URLQueryItem(name: "provider", value: identityProvider))
    }
    components.queryItems = query

    guard let url = components.url else {
      throw BrowserAuthError.malformedAuthorizeURL(region: region)
    }
    return url
  }
}
