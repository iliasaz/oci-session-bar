// Copyright 2026 Ilia Sazonov
// SPDX-License-Identifier: MIT

import AppKit
import Foundation
import OCIKit
import OSLog

enum BrowserAuthError: LocalizedError {
  case malformedAuthorizeURL(region: String)
  case tokenNotUsable(detail: String)

  var errorDescription: String? {
    switch self {
    case .malformedAuthorizeURL(let region):
      "Could not build a Console sign-in URL for region \"\(region)\"."
    case .tokenNotUsable(let detail):
      "The Console returned a token that could not be used: \(detail)"
    }
  }
}

/// The interactive half of `oci session authenticate`: generate a keypair, send the
/// user to the Console with its public half, catch the redirect on loopback, and
/// persist the issued token as a config profile.
///
/// `OCIKit` deliberately does not implement this — its `authenticate(using:)` is the
/// `--no-browser` path and needs credentials that already exist. This is the path
/// for a profile that has no API key to bootstrap from.
nonisolated enum BrowserAuthFlow {
  private static let logger = Logger(subsystem: "com.iliasaz.OCISessionBar", category: "browser-auth")

  struct Outcome: Sendable {
    let status: SessionStatus
    let paths: SessionTokenStore.SessionPaths
  }

  /// Runs the flow end to end and writes the profile.
  ///
  /// Ordering is load-bearing: the port is bound *first*, so a conflict is reported
  /// before a browser window is opened or a keypair generated, and so the redirect
  /// cannot outrun the listener.
  static func run(
    configFilePath: String,
    profile: String,
    region: String,
    tenancyName: String? = nil,
    // `Swift.Duration` spelled out: OCIKit exports an ObjectStorage model also
    // called `Duration`, which shadows the standard library type in this file.
    timeout: Swift.Duration = .seconds(300)
  ) async throws -> Outcome {
    try SessionTokenStore.validateProfileName(profile)

    let catcher = LoopbackTokenCatcher()
    try await catcher.bind()
    defer { Task { await catcher.shutdown() } }

    let keyPair = try SessionKeyPair.generate()
    let publicKeyParameter = try JWK.consolePublicKeyParameter(for: keyPair)
    let authorizeURL = try ConsoleAuthURL.build(
      region: region,
      publicKeyParameter: publicKeyParameter,
      tenancyName: tenancyName
    )

    logger.debug("Opening the Console sign-in page for region \(region, privacy: .public)")
    NSWorkspace.shared.open(authorizeURL)

    let token = try await catcher.waitForToken(timeout: timeout)

    let container: SecurityTokenContainer
    do {
      container = try SecurityTokenContainer(token: token)
    } catch {
      throw BrowserAuthError.tokenNotUsable(detail: error.localizedDescription)
    }

    // Carry across any keys the app does not manage, so re-authenticating an
    // existing profile does not quietly drop the user's own settings.
    let preserved = SessionService.preservedEntries(
      configFilePath: configFilePath, profile: profile
    )
    let paths = try SessionTokenStore.persistSession(
      keyPair: keyPair,
      token: token,
      profile: profile,
      region: region,
      tenancyOCID: container.tenancyId,
      userOCID: container.subject,
      configFilePath: configFilePath
    )
    do {
      try SessionService.restore(preserved, configFilePath: configFilePath, profile: profile)
    } catch {
      // The session is already safely on disk; losing a preserved extra key is not
      // worth failing a completed sign-in over.
      logger.error(
        "Could not restore unmanaged keys for profile \(profile, privacy: .public): \(error.localizedDescription, privacy: .public)"
      )
    }

    logger.notice("Created session for profile \(profile, privacy: .public)")
    return Outcome(status: SessionStatus(profile: profile, container: container), paths: paths)
  }
}
