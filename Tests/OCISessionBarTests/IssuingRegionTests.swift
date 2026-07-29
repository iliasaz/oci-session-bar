// Copyright 2026 Ilia Sazonov
// SPDX-License-Identifier: MIT

import Foundation
import OCIKit
import Testing

@testable import OCISessionBar

/// The auth service's `/authentication/refresh` is region-bound: sending the
/// exchange to the wrong region returns `401 NotAuthenticated`, which looks exactly
/// like an ended session. The issuing region therefore has to come from the token,
/// not from the profile — the two differ whenever sign-in is served by a tenancy's
/// home region while the profile points elsewhere.
@Suite("Issuing region")
struct IssuingRegionTests {
  private func token(header: [String: String]) -> String {
    let data = try! JSONSerialization.data(withJSONObject: header, options: [.sortedKeys])
    let encoded = JWK.base64URLUnpadded(data)
    // Only the header is inspected; the rest just has to be shaped like a JWT.
    return "\(encoded).eyJzdWIiOiJ4In0.signature"
  }

  @Test("The region is read from the kid's asw_<region>_<serial> form")
  func readsRegionFromKeyID() {
    let jwt = token(header: ["kid": "asw_phx_1715632587076", "alg": "RS256"])
    #expect(SessionService.issuingRegionCode(forToken: jwt) == "phx")
  }

  @Test(
    "Every realistic region code is recognised",
    arguments: ["phx", "iad", "fra", "lhr", "nrt", "syd", "yyz", "zrh"]
  )
  func recognisesRegionCodes(code: String) {
    let jwt = token(header: ["kid": "asw_\(code)_1715632587076"])
    #expect(SessionService.issuingRegionCode(forToken: jwt) == code)
  }

  /// Falling back to the profile's region is correct behaviour; guessing a
  /// hostname from an unfamiliar `kid` is not.
  @Test(
    "An unrecognisable kid yields nil rather than a guess",
    arguments: [
      "asw_zzz_123",  // not a region
      "somekey",  // no separators
      "",  // empty
      "asw__123",  // empty component
    ]
  )
  func returnsNilForUnknownKeyID(keyID: String) {
    #expect(SessionService.issuingRegionCode(forToken: token(header: ["kid": keyID])) == nil)
  }

  @Test("A header with no kid yields nil")
  func returnsNilWithoutKeyID() {
    #expect(SessionService.issuingRegionCode(forToken: token(header: ["alg": "RS256"])) == nil)
  }

  @Test("Malformed tokens yield nil rather than throwing", arguments: ["", "notajwt", "a.b"])
  func returnsNilForMalformedToken(raw: String) {
    #expect(SessionService.issuingRegionCode(forToken: raw) == nil)
  }

  /// The header is unpadded base64url; decoding must handle every remainder length
  /// or a perfectly good token would be read as having no `kid` at all.
  @Test("Headers of every base64 padding length decode")
  func decodesEveryPaddingLength() {
    for filler in 0..<4 {
      let jwt = token(header: ["kid": "asw_phx_1", "x": String(repeating: "a", count: filler)])
      #expect(
        SessionService.issuingRegionCode(forToken: jwt) == "phx",
        "failed with \(filler) filler characters"
      )
    }
  }

  /// The real token observed in the field, reduced to its header.
  @Test("A real Console-issued header resolves to Phoenix")
  func readsRealHeader() {
    // {"kid":"asw_phx_1715632587076","alg":"RS256"}
    let real = "eyJraWQiOiJhc3dfcGh4XzE3MTU2MzI1ODcwNzYiLCJhbGciOiJSUzI1NiJ9.eyJzdWIiOiJ4In0.sig"
    #expect(SessionService.issuingRegionCode(forToken: real) == "phx")
  }
}
