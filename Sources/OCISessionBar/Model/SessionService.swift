// Copyright 2026 Ilia Sazonov
// SPDX-License-Identifier: MIT

import Foundation
import OCIKit

/// Signals that no amount of refreshing will help: the *server-side session* is
/// over, not merely the token. The only way forward is minting a new session —
/// silently from an API-key profile, or through the browser.
struct NeedsReauthentication: LocalizedError {
  let reason: String
  var errorDescription: String? { "Re-authentication required: \(reason)" }
}

/// The app's seam onto `OCIKit`'s session layer.
///
/// Deliberately thin: `SessionTokenManager` already reads the profile, signs the
/// exchange and writes the refreshed token back to `security_token_file` atomically
/// at 0600. Re-doing any of that here would be a bug, not a safeguard.
nonisolated enum SessionService {
  static func manager(configFilePath: String, profile: String) -> SessionTokenManager {
    SessionTokenManager(
      configFilePath: configFilePath,
      profile: profile,
      transport: .live
    )
  }

  /// The token currently on disk, parsed. Local only — no network.
  static func status(configFilePath: String, profile: String) throws -> SessionStatus {
    let container = try manager(configFilePath: configFilePath, profile: profile).container()
    return SessionStatus(profile: profile, container: container)
  }

  /// `oci session refresh`. The SDK writes the new token to the profile's
  /// `security_token_file`; this only reports the result.
  ///
  /// - Throws: ``NeedsReauthentication`` when the session cannot be extended,
  ///   whatever the SDK called it. Every other error propagates unchanged, because
  ///   a transient network failure must stay retryable rather than being reported
  ///   as "go do a browser login".
  static func refresh(configFilePath: String, profile: String) async throws -> SessionStatus {
    do {
      // minimumRemaining: 0 — attempt the exchange whenever the token has not
      // already expired. The default would refuse locally in the last minute of a
      // session, which is exactly when keeping this session alive matters most.
      let refreshed = try await manager(configFilePath: configFilePath, profile: profile)
        .refresh(minimumRemaining: 0)
      return SessionStatus(profile: profile, container: refreshed)
    } catch let error as SessionTokenError {
      switch error {
      case .sessionExpired(let expiredAt):
        throw NeedsReauthentication(reason: "the session expired at \(expiredAt.formatted())")
      case .sessionTooCloseToExpiry(let expiresAt, _):
        throw NeedsReauthentication(reason: "the session expires at \(expiresAt.formatted())")
      case .refreshRejected:
        throw NeedsReauthentication(reason: "the service declined to extend the session")
      default:
        throw error
      }
    }
  }

  /// `oci session validate` — a real service round trip, not just an `exp` check.
  static func validate(configFilePath: String, profile: String) async throws -> SessionStatus {
    let container = try await manager(configFilePath: configFilePath, profile: profile)
      .validate()
    return SessionStatus(profile: profile, container: container)
  }

  // MARK: Creating a session from an API-key profile

  /// Mints a session token for `targetProfile` using `sourceProfile`'s API key —
  /// the `--no-browser` half of `oci session authenticate`, and the path behind
  /// "copy jroga into jroga-token".
  ///
  /// No browser is involved: the source profile's key is itself the credential
  /// that authorises the exchange, so this is silent and scriptable.
  ///
  /// The source profile is only ever *read*. The target profile's section is
  /// rewritten, with any keys the app does not manage carried across (see
  /// ``preservedEntries(configFilePath:profile:)``).
  static func createSession(
    configFilePath: String,
    sourceProfile: String,
    targetProfile: String,
    region: String
  ) async throws -> SessionStatus {
    try SessionTokenStore.validateProfileName(targetProfile)
    let signer = try APIKeySigner(configFilePath: configFilePath, configName: sourceProfile)
    let preserved = preservedEntries(configFilePath: configFilePath, profile: targetProfile)

    let session = try await SessionTokenManager.authenticate(
      using: signer,
      region: region,
      profile: targetProfile,
      configFilePath: configFilePath
    )
    try restore(preserved, configFilePath: configFilePath, profile: targetProfile)
    return SessionStatus(profile: targetProfile, container: session.container)
  }

  // MARK: Preserving hand-written config keys

  /// The keys `persistSession` writes. Everything else in a section is the user's.
  private static let managedKeys: Set<String> = [
    "user", "fingerprint", "key_file", "tenancy", "region", "security_token_file",
  ]

  /// Keys in `profile` that the app does not manage, captured *before* a write.
  ///
  /// `SessionTokenStore.upsertProfile` replaces a section wholesale, so a profile
  /// carrying a hand-added `pass_phrase`, `compartment-id` or similar would lose it
  /// on every re-authentication. Reading them first and putting them back afterwards
  /// keeps re-auth non-destructive.
  ///
  /// A profile that does not exist yet simply has nothing to preserve.
  static func preservedEntries(configFilePath: String, profile: String) -> [String: String] {
    guard let section = try? SessionTokenStore.profileSection(
      configFilePath: configFilePath, profile: profile
    ) else { return [:] }
    return section.filter { !managedKeys.contains($0.key) }
  }

  /// Re-applies `preserved` on top of the section just written.
  ///
  /// Best-effort by design: the session itself is already safely on disk at this
  /// point, and failing the whole operation because a comment-adjacent key could
  /// not be restored would be worse than the loss it prevents. The caller logs it.
  static func restore(
    _ preserved: [String: String],
    configFilePath: String,
    profile: String
  ) throws {
    guard !preserved.isEmpty else { return }
    let current = try SessionTokenStore.profileSection(
      configFilePath: configFilePath, profile: profile
    )
    // Managed values win: they describe the session that was just created.
    let merged = preserved.merging(current) { _, managed in managed }
    try SessionTokenStore.upsertProfile(
      configFilePath: configFilePath,
      profile: profile,
      entries: merged.sorted { $0.key < $1.key }.map { (key: $0.key, value: $0.value) }
    )
  }
}
