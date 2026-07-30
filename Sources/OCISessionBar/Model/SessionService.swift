// Copyright 2026 Ilia Sazonov
// SPDX-License-Identifier: MIT

import Foundation
import OCIKit
import OSLog

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
  /// `session` rather than `model`, so the exchange itself can be followed on its own
  /// in Console without the once-a-second tick chatter around it.
  private static let logger = Logger(subsystem: "com.iliasaz.OCISessionBar", category: "session")

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

  /// `oci session refresh`: exchanges the current token for a fresh one and writes
  /// it back to the profile's `security_token_file`.
  ///
  /// **The exchange is sent to the region that *issued* the session, not the
  /// region named in the profile.** Those are usually the same, but they diverge
  /// whenever a tenancy's sign-in is served by its home region while the profile
  /// points somewhere else — and the auth service's `/authentication/refresh` is
  /// region-bound, so the mismatch comes back as a bare `401 NotAuthenticated`
  /// that is indistinguishable from a dead session. The issuing region is read
  /// from the token itself (see ``issuingRegionCode(forToken:)``), with the
  /// profile's region tried as a fallback.
  ///
  /// This is why the exchange is driven directly rather than through
  /// ``SessionTokenManager/refresh(minimumRemaining:)``: the manager always uses
  /// the profile's region, exactly as the `oci` CLI does.
  ///
  /// - Throws: ``NeedsReauthentication`` when the session genuinely cannot be
  ///   extended. Every other error propagates unchanged, because a transient
  ///   network failure must stay retryable rather than being reported as "go do a
  ///   browser sign-in".
  static func refresh(configFilePath: String, profile: String) async throws -> SessionStatus {
    let section = try SessionTokenStore.profileSection(
      configFilePath: configFilePath, profile: profile
    )
    guard let tokenPath = section["security_token_file"], !tokenPath.isEmpty else {
      throw ConfigErrors.missingSecurityTokenFile
    }
    let configuration = try SignerConfiguration.fromFileForSecurityToken(
      configFilePath: configFilePath, configName: profile
    )
    guard let token = configuration.securityToken else { throw ConfigErrors.badSecurityTokenFile }

    // The exchange is signed with the current token, so an expired one cannot be
    // used to obtain its successor. Caught locally to save a round trip.
    let current = try SecurityTokenContainer(token: token)
    guard current.isValid() else {
      logger.error(
        """
        Refresh of \(profile, privacy: .public) abandoned: the token on disk already \
        expired at \(current.expiresAt.formatted(date: .omitted, time: .standard), privacy: .public)
        """
      )
      throw NeedsReauthentication(reason: "the session expired at \(current.expiresAt.formatted())")
    }

    var regions: [String] = []
    if let issuing = issuingRegionCode(forToken: token) { regions.append(issuing) }
    if !regions.contains(configuration.region) { regions.append(configuration.region) }

    logger.info(
      """
      Refreshing \(profile, privacy: .public), expiring \
      \(current.expiresAt.formatted(date: .omitted, time: .standard), privacy: .public); \
      regions to try: \(regions.joined(separator: ", "), privacy: .public)
      """
    )

    for region in regions {
      do {
        let client = try SessionTokenClient(region: region)
        let refreshedToken = try await client.refreshSecurityToken(
          currentToken: token, privateKey: configuration.privateKey
        )
        let refreshed = try SecurityTokenContainer(token: refreshedToken)
        try SessionTokenStore.writeToken(refreshedToken, toPath: tokenPath)
        let gained = refreshed.expiresAt.timeIntervalSince(current.expiresAt)
        logger.notice(
          """
          Refreshed \(profile, privacy: .public) via \(region, privacy: .public): now expires \
          \(refreshed.expiresAt.formatted(date: .omitted, time: .standard), privacy: .public), \
          \(Int(gained), privacy: .public)s later than before
          """
        )
        return SessionStatus(profile: profile, container: refreshed)
      } catch SessionTokenError.refreshRejected {
        // A 401 here means "wrong region" just as often as "session over", so try
        // the next candidate before concluding anything.
        logger.info(
          """
          Region \(region, privacy: .public) declined the refresh of \
          \(profile, privacy: .public); \(regions.last == region ? "no candidates left" : "trying the next region", privacy: .public)
          """
        )
        continue
      } catch {
        // One line at `error` level for the story, the raw dump at `debug` for when
        // the story is not enough — an SDK `NSError` runs to several hundred
        // characters of nested `userInfo` and buries everything around it.
        logger.error(
          """
          Refresh of \(profile, privacy: .public) via \(region, privacy: .public) failed: \
          \((error as NSError).localizedDescription, privacy: .public)
          """
        )
        logger.debug("Underlying error: \(String(describing: error), privacy: .public)")
        throw error
      }
    }
    logger.error(
      """
      Every region declined the refresh of \(profile, privacy: .public); the session itself \
      has ended and a new sign-in is required
      """
    )
    throw NeedsReauthentication(reason: "the service declined to extend the session")
  }

  /// The short region code of the auth service that issued `token`, or `nil` when
  /// the token does not say.
  ///
  /// The JWT header's `kid` names the issuing auth service's signing key, in the
  /// form `asw_<region>_<serial>` — for example `asw_phx_1715632587076`, meaning
  /// Phoenix. Only a component that is a region code the SDK recognises is
  /// accepted, so an unfamiliar `kid` format yields `nil` and the caller falls
  /// back to the profile's region rather than inventing a hostname.
  ///
  /// `SessionTokenClient` takes short codes directly, so no expansion is needed.
  static func issuingRegionCode(forToken token: String) -> String? {
    let segments = token.split(separator: ".")
    guard segments.count >= 2,
      let headerData = base64URLDecode(String(segments[0])),
      let header = try? JSONSerialization.jsonObject(with: headerData) as? [String: Any],
      let keyID = header["kid"] as? String
    else { return nil }

    return keyID.split(separator: "_")
      .lazy
      .map(String.init)
      .first { Region(rawValue: $0) != nil }
  }

  private static func base64URLDecode(_ value: String) -> Data? {
    var standard = value.replacing("-", with: "+").replacing("_", with: "/")
    standard += String(repeating: "=", count: (4 - standard.count % 4) % 4)
    return Data(base64Encoded: standard)
  }

  /// `oci session validate` — a real service round trip, not just an `exp` check.
  static func validate(configFilePath: String, profile: String) async throws -> SessionStatus {
    logger.info("Validating \(profile, privacy: .public) against the service")
    do {
      let container = try await manager(configFilePath: configFilePath, profile: profile)
        .validate()
      logger.notice(
        """
        \(profile, privacy: .public) validated; expires \
        \(container.expiresAt.formatted(date: .omitted, time: .standard), privacy: .public)
        """
      )
      return SessionStatus(profile: profile, container: container)
    } catch {
      logger.error(
        """
        Validation of \(profile, privacy: .public) failed: \
        \(String(describing: error), privacy: .public)
        """
      )
      throw error
    }
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
    logger.info(
      """
      Minting a session for \(targetProfile, privacy: .public) from the API key of \
      \(sourceProfile, privacy: .public) in \(region, privacy: .public)
      """
    )
    let signer = try APIKeySigner(configFilePath: configFilePath, configName: sourceProfile)
    let preserved = preservedEntries(configFilePath: configFilePath, profile: targetProfile)
    if !preserved.isEmpty {
      logger.debug(
        """
        Carrying \(preserved.count, privacy: .public) unmanaged key(s) across the rewrite of \
        \(targetProfile, privacy: .public)
        """
      )
    }

    do {
      let session = try await SessionTokenManager.authenticate(
        using: signer,
        region: region,
        profile: targetProfile,
        configFilePath: configFilePath
      )
      try restore(preserved, configFilePath: configFilePath, profile: targetProfile)
      logger.notice(
        """
        Minted a session for \(targetProfile, privacy: .public); expires \
        \(session.container.expiresAt.formatted(date: .omitted, time: .standard), privacy: .public)
        """
      )
      return SessionStatus(profile: targetProfile, container: session.container)
    } catch {
      logger.error(
        """
        Could not mint a session for \(targetProfile, privacy: .public) from \
        \(sourceProfile, privacy: .public): \(String(describing: error), privacy: .public)
        """
      )
      throw error
    }
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
