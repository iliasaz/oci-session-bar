// Copyright 2026 Ilia Sazonov
// SPDX-License-Identifier: MIT

import Foundation
import OCIKit

/// Builds the `public_key` query parameter the OCI Console's authorize endpoint
/// expects: base64url of a JWK carrying the RSA modulus and exponent.
///
/// The inputs come from ``SessionKeyPair/publicKeyPEM``, which is a documented
/// SubjectPublicKeyInfo PEM. Deriving `n` and `e` by parsing that DER — rather than
/// reaching for a swift-crypto SPI such as `pkcs1DERRepresentation` — keeps this
/// working across swift-crypto versions, since the PEM's shape is fixed by RFC 5280
/// while the SPI surface is not.
nonisolated enum JWK {
  enum Failure: LocalizedError {
    case malformedPEM
    case malformedDER(String)

    var errorDescription: String? {
      switch self {
      case .malformedPEM: "The session public key is not a valid PEM document."
      case .malformedDER(let detail): "The session public key could not be decoded: \(detail)."
      }
    }
  }

  /// The value of the `public_key` query parameter.
  ///
  /// Note the asymmetry, which matches the CLI byte for byte: `n` and `e` are
  /// base64url **without** padding (per RFC 7518), while the outer encoding of the
  /// JSON **keeps** its `=` padding.
  static func consolePublicKeyParameter(for keyPair: SessionKeyPair) throws -> String {
    let (modulus, exponent) = try rsaComponents(spkiPEM: keyPair.publicKeyPEM)
    let jwk = [
      "kty": "RSA",
      "n": base64URLUnpadded(modulus),
      "e": base64URLUnpadded(exponent),
      // The service ignores the value but requires the field to be present.
      "kid": "Ignored",
    ]
    let json = try JSONSerialization.data(withJSONObject: jwk, options: [.sortedKeys])
    return json.base64EncodedString()
      .replacing("+", with: "-")
      .replacing("/", with: "_")
  }

  static func base64URLUnpadded(_ data: Data) -> String {
    data.base64EncodedString()
      .replacing("+", with: "-")
      .replacing("/", with: "_")
      .replacing("=", with: "")
  }

  /// `(modulus, exponent)` as big-endian bytes, from a SubjectPublicKeyInfo PEM.
  static func rsaComponents(spkiPEM pem: String) throws -> (modulus: Data, exponent: Data) {
    let body = pem
      .split(separator: "\n")
      .filter { !$0.hasPrefix("-----") }
      .joined()
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard let der = Data(base64Encoded: body, options: [.ignoreUnknownCharacters]) else {
      throw Failure.malformedPEM
    }
    return try rsaComponents(der: der)
  }

  /// Accepts either a SubjectPublicKeyInfo DER or a bare PKCS#1 `RSAPublicKey` DER.
  ///
  /// Both start `SEQUENCE`, and they are told apart by what follows: an `INTEGER`
  /// means PKCS#1 (the modulus), a nested `SEQUENCE` means SPKI (the algorithm
  /// identifier), in which case the real key is inside the following `BIT STRING`.
  static func rsaComponents(der: Data) throws -> (modulus: Data, exponent: Data) {
    var reader = DERReader(der)
    let outer = try reader.readSequenceContents()

    // What follows the outer SEQUENCE header tells the two encodings apart.
    var probe = DERReader(outer)
    let body: Data
    if try probe.peekTag() == DERReader.sequenceTag {
      // SPKI: skip the AlgorithmIdentifier, then the BIT STRING holds a complete
      // RSAPublicKey DER, whose own SEQUENCE still has to be unwrapped.
      _ = try probe.readSequenceContents()
      var key = DERReader(try probe.readBitStringContents())
      body = try key.readSequenceContents()
    } else {
      // PKCS#1: the two INTEGERs are already the contents just read.
      body = outer
    }

    var integers = DERReader(body)
    let modulus = try integers.readInteger()
    let exponent = try integers.readInteger()
    return (modulus, exponent)
  }
}

/// A minimal DER reader covering exactly the four shapes an RSA public key uses:
/// SEQUENCE, BIT STRING, INTEGER, and definite-length headers.
nonisolated private struct DERReader {
  static let sequenceTag: UInt8 = 0x30
  static let bitStringTag: UInt8 = 0x03
  static let integerTag: UInt8 = 0x02

  private let bytes: [UInt8]
  private var index = 0

  init(_ data: Data) { self.bytes = Array(data) }

  private mutating func byte() throws -> UInt8 {
    guard index < bytes.count else { throw JWK.Failure.malformedDER("unexpected end of data") }
    defer { index += 1 }
    return bytes[index]
  }

  func peekTag() throws -> UInt8 {
    guard index < bytes.count else { throw JWK.Failure.malformedDER("unexpected end of data") }
    return bytes[index]
  }

  private mutating func length() throws -> Int {
    let first = try byte()
    guard first & 0x80 != 0 else { return Int(first) }
    let count = Int(first & 0x7F)
    // A 0-byte count is the indefinite form, which DER forbids; more than 4 bytes
    // is a length no key material can legitimately need.
    guard count > 0, count <= 4 else { throw JWK.Failure.malformedDER("bad length encoding") }
    var value = 0
    for _ in 0..<count { value = (value << 8) | Int(try byte()) }
    return value
  }

  private mutating func readValue(tag expected: UInt8) throws -> Data {
    let tag = try byte()
    guard tag == expected else {
      throw JWK.Failure.malformedDER(
        "expected tag 0x\(String(expected, radix: 16)) but found 0x\(String(tag, radix: 16))"
      )
    }
    let count = try length()
    guard index + count <= bytes.count else {
      throw JWK.Failure.malformedDER("element runs past the end of the data")
    }
    defer { index += count }
    return Data(bytes[index..<(index + count)])
  }

  mutating func readSequenceContents() throws -> Data { try readValue(tag: Self.sequenceTag) }

  mutating func readBitStringContents() throws -> Data {
    var contents = try readValue(tag: Self.bitStringTag)
    // The first byte counts unused trailing bits; for a wrapped DER structure it
    // is always 0, and it is not part of the payload.
    guard let unused = contents.first else {
      throw JWK.Failure.malformedDER("empty bit string")
    }
    guard unused == 0 else { throw JWK.Failure.malformedDER("unexpected unused bits") }
    contents.removeFirst()
    return contents
  }

  mutating func readInteger() throws -> Data {
    var value = try readValue(tag: Self.integerTag)
    // DER prefixes a 0x00 byte when the high bit would otherwise make the integer
    // negative. JWK wants the unsigned magnitude, so drop it.
    while value.first == 0x00, value.count > 1 { value.removeFirst() }
    return value
  }
}
