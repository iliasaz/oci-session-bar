// Copyright 2026 Ilia Sazonov
// SPDX-License-Identifier: MIT

import Foundation
import OCIKit
import OSLog
import Observation

/// Everything the menu bar item and the Settings window read from.
///
/// Main-actor by default (the project builds with `SWIFT_DEFAULT_ACTOR_ISOLATION =
/// MainActor`); the network work happens inside `OCIKit`, which hops off on its own.
@Observable
final class AuthModel {
  private static let logger = Logger(subsystem: "com.iliasaz.OCISessionBar", category: "model")

  /// Where the app is in its own work, so the menu can say something truthful.
  enum Activity: Equatable {
    case idle
    case refreshing
    case signingIn
    case creatingProfile(String)

    var description: String? {
      switch self {
      case .idle: nil
      case .refreshing: "Refreshing…"
      case .signingIn: "Waiting for browser sign-in…"
      case .creatingProfile(let name): "Creating \(name)…"
      }
    }
  }

  // MARK: Settings

  var configFilePath: String {
    didSet {
      guard configFilePath != oldValue else { return }
      defaults.set(configFilePath, forKey: Keys.configFilePath)
      reload()
    }
  }

  var profileName: String? {
    didSet {
      guard profileName != oldValue else { return }
      defaults.set(profileName, forKey: Keys.profileName)
      reload()
    }
  }

  /// Token profile to the API-key profile that may renew it without a browser.
  ///
  /// Recorded when a profile is created by copying an API-key profile, and editable
  /// in Settings. A profile with no entry here — `boat`, say — can only be renewed
  /// interactively, which is the normal case for a user who has no API key.
  private(set) var renewalSources: [String: String] {
    didSet { defaults.set(renewalSources, forKey: Keys.renewalSources) }
  }

  // MARK: Derived state

  private(set) var sessionProfiles: [OCIProfile] = []
  private(set) var authorizingProfiles: [OCIProfile] = []
  private(set) var status: SessionStatus?
  private(set) var lastError: String?
  private(set) var activity: Activity = .idle

  /// Ticked once a second; the countdown and the colour both read it, so the whole
  /// UI moves off one clock.
  private(set) var now: Date = .now

  private let defaults: UserDefaults
  private var ticker: Task<Void, Never>?
  private var work: Task<Void, Never>?

  /// How often the token file is re-read to notice out-of-band changes. Well below
  /// the shortest session OCI issues (5 minutes), so a token replaced by the CLI is
  /// picked up long before it matters.
  private static let diskCheckInterval: TimeInterval = 15
  private var lastDiskCheck: Date = .distantPast

  /// Set once per dead session so the notification does not repeat every tick.
  private var notifiedExpiryFor: Date?

  private enum Keys {
    static let configFilePath = "configFilePath"
    static let profileName = "profileName"
    static let renewalSources = "renewalSources"
  }

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    self.configFilePath =
      defaults.string(forKey: Keys.configFilePath) ?? OCIConfigFile.defaultPath
    self.profileName = defaults.string(forKey: Keys.profileName)
    self.renewalSources = defaults.dictionary(forKey: Keys.renewalSources) as? [String: String] ?? [:]
    reload()
    startTicking()
  }

  // No `deinit` teardown: it would be nonisolated and so could not touch these
  // tasks anyway. The ticker captures `self` weakly and returns on the first tick
  // after the model goes away, which ends the loop without one.

  // MARK: Presentation

  /// `"1:20"`, or an em dash when there is no live session to count down.
  var countdownText: String {
    guard let status, status.isValid(at: now) else { return "—" }
    return status.countdownText(at: now)
  }

  /// Red once under a tenth of the issued lifetime remains, or when there is no
  /// usable session at all.
  var isCritical: Bool {
    guard let status, status.isValid(at: now) else { return true }
    return status.remainingFraction(at: now) < 0.10
  }

  var hasSession: Bool { status?.isValid(at: now) == true }

  var isBusy: Bool { activity != .idle }

  /// What the Authenticate menu item will actually do, so it can say so.
  var authenticateTitle: String {
    guard profileName != nil else { return "Authenticate…" }
    if hasSession { return "Refresh Session" }
    if renewalSource(for: profileName) != nil { return "Renew Session" }
    return "Sign In…"
  }

  func renewalSource(for profile: String?) -> String? {
    guard let profile else { return nil }
    guard let source = renewalSources[profile] else { return nil }
    // A source profile that has since been deleted or converted is not usable.
    return authorizingProfiles.contains { $0.name == source } ? source : nil
  }

  /// The selected profile's renewal source, as something a `Picker` can bind to
  /// directly. Settings would otherwise need a hand-built `Binding(get:set:)`,
  /// which is harder to follow and easy to get subtly wrong.
  var renewalSourceForSelectedProfile: String? {
    get { renewalSource(for: profileName) }
    set {
      guard let profile = profileName else { return }
      if let newValue {
        renewalSources[profile] = newValue
      } else {
        renewalSources.removeValue(forKey: profile)
      }
    }
  }

  /// Every profile name in the config file, for collision checks. Cached from the
  /// last ``reload()`` so a view can consult it without touching the disk.
  private(set) var allProfileNames: Set<String> = []

  // MARK: Loading

  /// Re-reads the config file and the selected profile's token. Cheap and local —
  /// no network — so it is safe to call whenever something might have changed.
  func reload() {
    do {
      let all = try OCIConfigFile.profiles(at: configFilePath)
      sessionProfiles = all.filter(\.isSessionProfile)
      authorizingProfiles = all.filter(\.canAuthorizeSession)
      allProfileNames = Set(all.map(\.name))

      if let current = profileName, !sessionProfiles.contains(where: { $0.name == current }) {
        profileName = sessionProfiles.first?.name
        return  // the didSet re-enters reload()
      }
      if profileName == nil, let first = sessionProfiles.first?.name {
        profileName = first
        return
      }
      guard let profile = profileName else {
        status = nil
        lastError = sessionProfiles.isEmpty ? nil : "No profile selected."
        return
      }
      status = try SessionService.status(configFilePath: configFilePath, profile: profile)
      lastError = nil
    } catch {
      status = nil
      lastError = Self.describe(error)
      Self.logger.error("Reload failed: \(String(describing: error), privacy: .public)")
    }
  }

  // MARK: The clock

  private func startTicking() {
    ticker?.cancel()
    ticker = Task { [weak self] in
      while !Task.isCancelled {
        guard let self else { return }
        self.now = .now
        self.autoRefreshIfNeeded()
        try? await Task.sleep(for: .seconds(1))
      }
    }
  }

  /// Refreshes once the token is past its half-life.
  ///
  /// Driven from the same one-second tick as the countdown rather than a scheduled
  /// one-shot, because the tick recomputes from wall-clock `iat`/`exp` every pass:
  /// after the machine sleeps through a refresh window, the very next tick notices
  /// and acts, with no timer to have been missed.
  private func autoRefreshIfNeeded() {
    guard work == nil, let profile = profileName else { return }

    // Re-read from disk periodically: `oci session refresh` in a terminal, or
    // another copy of this app, may have replaced the token since the last check.
    // Throttled rather than done every tick — the countdown itself needs no disk
    // access, and re-reading two files plus parsing a JWT once a second, forever,
    // is real I/O for a menu bar utility that is idle almost all of the time.
    if now.timeIntervalSince(lastDiskCheck) >= Self.diskCheckInterval {
      lastDiskCheck = now
      if let fresh = try? SessionService.status(configFilePath: configFilePath, profile: profile),
        fresh != status
      {
        status = fresh
        lastError = nil
      }
    }

    guard let status else { return }

    guard status.isValid(at: now) else {
      notifyExpiredOnce(status)
      return
    }
    guard status.needsRefresh(at: now) else { return }

    work = Task { [weak self] in
      defer { self?.work = nil }
      guard let self else { return }
      do {
        self.status = try await SessionService.refresh(
          configFilePath: self.configFilePath, profile: profile
        )
        self.lastError = nil
        self.notifiedExpiryFor = nil
      } catch let error as NeedsReauthentication {
        // Try the silent path if this profile has one. Never open a browser from a
        // background task — that is the user's decision to make.
        if let source = self.renewalSource(for: profile), let region = self.region(for: profile) {
          await self.renewSilently(profile: profile, source: source, region: region, after: error)
        } else {
          self.lastError = error.localizedDescription
          self.notifyReauthenticationNeeded(profile: profile, reason: error.reason)
        }
      } catch {
        // Transient: the next tick tries again, and there is half a lifetime left.
        self.lastError = Self.describe(error)
      }
    }
  }

  private func renewSilently(
    profile: String, source: String, region: String, after failure: NeedsReauthentication
  ) async {
    do {
      status = try await SessionService.createSession(
        configFilePath: configFilePath,
        sourceProfile: source,
        targetProfile: profile,
        region: region
      )
      lastError = nil
      notifiedExpiryFor = nil
      Self.logger.notice(
        "Renewed \(profile, privacy: .public) from \(source, privacy: .public) without a browser"
      )
    } catch {
      lastError = "\(failure.localizedDescription) Renewal from \(source) also failed: \(Self.describe(error))"
      notifyReauthenticationNeeded(profile: profile, reason: failure.reason)
    }
  }

  // MARK: Actions

  /// The Authenticate menu item.
  ///
  /// Refresh while the session is alive; otherwise renew from an API-key profile if
  /// one is linked, and fall back to the browser when it is not.
  func authenticate() {
    guard let profile = profileName, work == nil else { return }
    work = Task { [weak self] in
      defer { self?.work = nil; self?.activity = .idle }
      guard let self else { return }
      do {
        if self.hasSession {
          self.activity = .refreshing
          self.status = try await SessionService.refresh(
            configFilePath: self.configFilePath, profile: profile
          )
          self.lastError = nil
          self.notifiedExpiryFor = nil
          return
        }
        try await self.mintNewSession(profile: profile)
      } catch is NeedsReauthentication {
        // The refresh was refused mid-flight — the session ended between the
        // validity check above and the exchange. Minting a new one is the answer.
        do { try await self.mintNewSession(profile: profile) } catch {
          self.lastError = Self.describe(error)
        }
      } catch {
        self.lastError = Self.describe(error)
      }
    }
  }

  private func mintNewSession(profile: String) async throws {
    guard let region = region(for: profile) else { throw ConfigErrors.missingRegion }

    if let source = renewalSource(for: profile) {
      activity = .creatingProfile(profile)
      status = try await SessionService.createSession(
        configFilePath: configFilePath,
        sourceProfile: source,
        targetProfile: profile,
        region: region
      )
    } else {
      activity = .signingIn
      let outcome = try await BrowserAuthFlow.run(
        configFilePath: configFilePath, profile: profile, region: region
      )
      status = outcome.status
    }
    lastError = nil
    notifiedExpiryFor = nil
    reload()
  }

  /// Creates a brand-new session profile. Refuses to touch an existing one.
  ///
  /// `source` names an API-key profile to mint from without a browser; passing
  /// `nil` runs the interactive Console flow instead, which is the only option for
  /// a user who has no API key configured.
  func createProfile(named name: String, from source: OCIProfile?, region: String) async throws {
    try SessionTokenStore.validateProfileName(name)
    let existing = try OCIConfigFile.profiles(at: configFilePath)
    guard !existing.contains(where: { $0.name == name }) else {
      throw ProfileCreationError.alreadyExists(name)
    }

    activity = .creatingProfile(name)
    defer { activity = .idle }

    if let source {
      status = try await SessionService.createSession(
        configFilePath: configFilePath,
        sourceProfile: source.name,
        targetProfile: name,
        region: region
      )
      renewalSources[name] = source.name
    } else {
      let outcome = try await BrowserAuthFlow.run(
        configFilePath: configFilePath, profile: name, region: region
      )
      status = outcome.status
    }
    profileName = name
    lastError = nil
    reload()
  }

  /// `oci session validate` — an explicit service round trip.
  func validate() async -> String {
    guard let profile = profileName else { return "No profile selected." }
    do {
      let validated = try await SessionService.validate(
        configFilePath: configFilePath, profile: profile
      )
      status = validated
      return "Session is valid until \(validated.expiresAt.formatted())."
    } catch {
      return Self.describe(error)
    }
  }

  // MARK: Helpers

  func region(for profile: String) -> String? {
    sessionProfiles.first { $0.name == profile }?.region
      ?? (try? SessionTokenStore.profileSection(
        configFilePath: configFilePath, profile: profile
      ))?["region"]
  }

  private func notifyReauthenticationNeeded(profile: String, reason: String) {
    guard notifiedExpiryFor != status?.expiresAt else { return }
    notifiedExpiryFor = status?.expiresAt
    Notifications.post(
      title: "OCI session needs sign-in",
      body: "Profile “\(profile)” can no longer be refreshed: \(reason)"
    )
  }

  private func notifyExpiredOnce(_ status: SessionStatus) {
    guard notifiedExpiryFor != status.expiresAt else { return }
    notifiedExpiryFor = status.expiresAt
    Notifications.post(
      title: "OCI session expired",
      body: "Profile “\(status.profile)” expired. Choose Authenticate to sign in again."
    )
  }

  static func describe(_ error: Error) -> String {
    (error as? LocalizedError)?.errorDescription ?? String(describing: error)
  }
}

enum ProfileCreationError: LocalizedError {
  case alreadyExists(String)

  var errorDescription: String? {
    switch self {
    case .alreadyExists(let name):
      "A profile named “\(name)” already exists. Existing profiles are never modified — choose a different name."
    }
  }
}
