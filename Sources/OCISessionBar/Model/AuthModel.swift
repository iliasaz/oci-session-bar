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

  /// How much time may be left on the token before the background refresh fires,
  /// in minutes.
  ///
  /// 30 minutes is the old fixed behaviour for the hour-long session OCI issues —
  /// that token's half-life. Lowering it pushes the refresh later (15 minutes is
  /// three-quarter-life) and so spends fewer exchanges on a long-lived session. It
  /// can never pull the refresh in front of half-life; see
  /// ``SessionStatus/refreshPoint(whenRemaining:)``.
  var refreshWhenRemainingMinutes: Int {
    didSet {
      guard refreshWhenRemainingMinutes != oldValue else { return }
      defaults.set(refreshWhenRemainingMinutes, forKey: Keys.refreshWhenRemainingMinutes)
      // A threshold the user just widened may already be met, so let the next tick
      // act on it rather than sitting behind a backoff from the old setting.
      refreshScheduler.reset()
    }
  }

  /// ``refreshWhenRemainingMinutes`` as the interval the timing code works in.
  var refreshWhenRemaining: TimeInterval { TimeInterval(refreshWhenRemainingMinutes * 60) }

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

  /// The instant the UI is drawn for; the countdown and the colour both read it, so
  /// the whole UI moves off one clock.
  ///
  /// Advanced by the tick only when doing so would change what is displayed — which,
  /// for an `h:mm` countdown, is once a minute rather than once a second. Scheduling
  /// does *not* read this: the tick passes the real instant along as a parameter.
  /// See ``tick(at:)``.
  private(set) var now: Date = .now

  /// Whether the menu bar is currently dark. Polled from the same tick rather than
  /// observed: the item's bitmap opts out of templating, so it has to be redrawn
  /// when the bar flips, and a once-a-second comparison is cheaper than the
  /// notification plumbing it would replace.
  private(set) var menuBarAppearance: MenuBarAppearance = .dark

  private let defaults: UserDefaults
  private var ticker: Task<Void, Never>?
  private var work: Task<Void, Never>?

  /// Spaces out background refresh attempts so a transient failure is retried with a
  /// widening backoff instead of on every tick, and so a still-valid-but-dead session
  /// is not re-attempted once a second until it finally expires.
  private var refreshScheduler = RefreshScheduler()

  /// The longest a single background refresh may run before it is abandoned as a
  /// transient failure.
  ///
  /// Two jobs. It stops a hung exchange from pinning ``work`` non-nil forever, which
  /// would silently disable every later auto-refresh. And because ``work`` is the
  /// single in-flight slot, bounding one attempt is what guarantees a retry is never
  /// issued while its predecessor is still outstanding: a slow auth service gets its
  /// minute, and only then does the backoff clock start.
  private static let refreshTimeout: Swift.Duration = .seconds(60)

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
    static let refreshWhenRemainingMinutes = "refreshWhenRemainingMinutes"
  }

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    self.configFilePath =
      defaults.string(forKey: Keys.configFilePath) ?? OCIConfigFile.defaultPath
    self.profileName = defaults.string(forKey: Keys.profileName)
    self.renewalSources = defaults.dictionary(forKey: Keys.renewalSources) as? [String: String] ?? [:]
    // `integer(forKey:)` reads 0 for an absent key, which would mean "refresh only
    // once the token has expired" — so an unset preference takes the default.
    let storedThreshold = defaults.integer(forKey: Keys.refreshWhenRemainingMinutes)
    self.refreshWhenRemainingMinutes =
      storedThreshold > 0
      ? storedThreshold : Int(SessionStatus.defaultRefreshWhenRemaining / 60)
    reload()
    startTicking()
  }

  #if DEBUG
    /// A model holding fixed state, for `#Preview`.
    ///
    /// Deliberately does **not** call `reload()` or `startTicking()`: a preview must
    /// not read the developer's real `~/.oci/config`, and must never reach the point
    /// where the one-second tick decides a token is past its half-life and fires a
    /// live refresh against Oracle. Every property is set directly instead, which
    /// also skips the `didSet` observers that would otherwise write to `UserDefaults`.
    private init(
      profileName: String?,
      status: SessionStatus?,
      lastError: String?,
      activity: Activity,
      sessionProfiles: [OCIProfile],
      authorizingProfiles: [OCIProfile],
      renewalSources: [String: String]
    ) {
      // A named suite rather than `.standard`, so a preview that does mutate
      // something cannot disturb the real app's settings.
      self.defaults = UserDefaults(suiteName: "com.iliasaz.OCISessionBar.previews") ?? .standard
      self.configFilePath = "~/.oci/config"
      self.profileName = profileName
      self.renewalSources = renewalSources
      self.refreshWhenRemainingMinutes = Int(SessionStatus.defaultRefreshWhenRemaining / 60)
      self.sessionProfiles = sessionProfiles
      self.authorizingProfiles = authorizingProfiles
      self.allProfileNames = Set(
        sessionProfiles.map(\.name) + authorizingProfiles.map(\.name)
      )
      self.status = status
      self.lastError = lastError
      self.activity = activity
    }

    /// The states worth looking at while designing: a healthy session, one about to
    /// lapse, none at all, and a failure.
    static func preview(
      profileName: String? = "jroga-token",
      status: SessionStatus? = .previewHealthy,
      lastError: String? = nil,
      activity: Activity = .idle
    ) -> AuthModel {
      AuthModel(
        profileName: profileName,
        status: status,
        lastError: lastError,
        activity: activity,
        sessionProfiles: [
          OCIProfile(
            name: "jroga-token",
            entries: [
              "region": "us-phoenix-1",
              "security_token_file": "~/.oci/sessions/jroga-token/token",
            ]
          ),
          OCIProfile(
            name: "boat",
            entries: [
              "region": "eu-frankfurt-1",
              "security_token_file": "~/.oci/sessions/boat/token",
            ]
          ),
        ],
        authorizingProfiles: [
          OCIProfile(
            name: "jroga",
            entries: [
              "region": "us-phoenix-1",
              "key_file": "~/.oci/jroga.pem",
              "fingerprint": "cc:dd",
              "user": "ocid1.user.oc1..jroga",
              "tenancy": "ocid1.tenancy.oc1..jroga",
            ]
          )
        ],
        renewalSources: ["jroga-token": "jroga"]
      )
    }
  #endif

  // No `deinit` teardown: it would be nonisolated and so could not touch these
  // tasks anyway. The ticker captures `self` weakly and returns on the first tick
  // after the model goes away, which ends the loop without one.

  // MARK: Presentation

  /// What the menu bar item draws right now.
  var menuBarPresentation: MenuBarPresentation { presentation(at: now) }

  /// What the item would draw at `instant`, so the tick can ask whether advancing the
  /// clock would actually change anything before it publishes. See ``tick(at:)``.
  private func presentation(at instant: Date) -> MenuBarPresentation {
    guard profileName != nil, let status else { return .unconfigured }
    guard status.isValid(at: instant) else { return .expired }
    return .countdown(
      text: status.countdownText(at: instant), isCritical: isCritical(at: instant)
    )
  }

  /// One sentence describing the current session.
  ///
  /// Deliberately shared by the menu's first line and the menu bar item's tooltip:
  /// the tooltip exists to surface exactly what the menu says without opening it,
  /// so the two must not be able to drift apart.
  var statusSummary: String {
    guard let profile = profileName else {
      return sessionProfiles.isEmpty ? "No session profiles found" : "No profile selected"
    }
    guard let status else { return "\(profile) — no session" }
    let time = status.expiresAt.formatted(date: .omitted, time: .shortened)
    guard status.isValid(at: now) else { return "\(profile) — session expired at \(time)" }
    return "\(profile) — expires \(time) (\(status.countdownText(at: now)) left)"
  }

  /// `"1:20"`, or an em dash when there is no live session to count down.
  ///
  /// Used by Settings, which has room for a label beside it. The menu bar item
  /// uses ``menuBarPresentation`` instead, because a bare dash up there says
  /// nothing about *why* there is no countdown.
  var countdownText: String {
    guard let status, status.isValid(at: now) else { return "—" }
    return status.countdownText(at: now)
  }

  /// Red once under a tenth of the issued lifetime remains, or when there is no
  /// usable session at all.
  var isCritical: Bool { isCritical(at: now) }

  private func isCritical(at instant: Date) -> Bool {
    guard let status, status.isValid(at: instant) else { return true }
    return status.remainingFraction(at: instant) < 0.10
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
      let refreshed = try SessionService.status(configFilePath: configFilePath, profile: profile)
      // A different token than we were counting down means the profile or file
      // changed under us; clear any backoff so it does not gate the new session.
      if refreshed != status { refreshScheduler.reset() }
      status = refreshed
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
        self.tick(at: .now)
        try? await Task.sleep(for: .seconds(1))
      }
    }
  }

  /// One pass of the clock: advance the display if it would look different, notice a
  /// menu bar that has changed colour, and give the refresh schedule a chance to act.
  ///
  /// The pass happens every second so that a refresh window is never missed and a
  /// machine waking from sleep catches up immediately — but **publishing** `now`
  /// every second is a different matter. `now` is observed, so every assignment makes
  /// SwiftUI rebuild the menu bar label and hand AppKit a fresh `NSImage`, and AppKit
  /// re-queries the status item each time (visible as a stream of `NSStatusItem
  /// Preferred Position` lines in Console). The countdown reads `h:mm`, so it has a
  /// new value to show once a *minute*: fifty-nine of those sixty rebuilds produced
  /// an identical item. So the instant is passed to the logic as a parameter, and
  /// `now` moves only when it would change what is on screen.
  private func tick(at instant: Date) {
    if presentation(at: instant) != menuBarPresentation { now = instant }

    // Both of these walk the window list, so neither is worth doing every second.
    // The menu bar only changes appearance when the user changes theme or desktop
    // picture, and the tooltip tracks `now`, so a second or two of lag in either is
    // imperceptible. The tooltip is deliberately not tied to the publish above: it
    // has to be attached shortly after launch, which is a moment when the countdown
    // may not have changed yet.
    if instant.timeIntervalSince(lastStatusItemSync) >= Self.statusItemSyncInterval {
      lastStatusItemSync = instant
      let appearance = MenuBarAppearance.current
      if appearance != menuBarAppearance { menuBarAppearance = appearance }
      // The status item's tooltip has no SwiftUI binding to hang off, so it is
      // pushed from here. `apply` is a no-op unless the text actually changed.
      StatusItemTooltip.apply(statusSummary)
    }

    autoRefreshIfNeeded(at: instant)
  }

  /// How often the status item's appearance and tooltip are re-read and re-pushed.
  /// See ``tick(at:)``.
  private static let statusItemSyncInterval: TimeInterval = 2
  private var lastStatusItemSync: Date = .distantPast

  /// Refreshes once the token is past its half-life.
  ///
  /// Driven from the same one-second tick as the countdown rather than a scheduled
  /// one-shot, because the tick recomputes from wall-clock `iat`/`exp` every pass:
  /// after the machine sleeps through a refresh window, the very next tick notices
  /// and acts, with no timer to have been missed.
  private func autoRefreshIfNeeded(at instant: Date) {
    guard work == nil, let profile = profileName else { return }

    // Re-read from disk periodically: `oci session refresh` in a terminal, or
    // another copy of this app, may have replaced the token since the last check.
    // Throttled rather than done every tick — the countdown itself needs no disk
    // access, and re-reading two files plus parsing a JWT once a second, forever,
    // is real I/O for a menu bar utility that is idle almost all of the time.
    if instant.timeIntervalSince(lastDiskCheck) >= Self.diskCheckInterval {
      lastDiskCheck = instant
      if let fresh = try? SessionService.status(configFilePath: configFilePath, profile: profile),
        fresh != status
      {
        status = fresh
        lastError = nil
        // A token replaced out of band is a fresh start: drop any pending backoff so
        // the next tick may act on the new token's own schedule at once.
        refreshScheduler.reset()
      }
    }

    guard let status else { return }

    guard status.isValid(at: instant) else {
      notifyExpiredOnce(status)
      return
    }
    guard
      refreshScheduler.shouldAttempt(status, at: instant, whenRemaining: refreshWhenRemaining)
    else {
      // Say why nothing is happening, but only when the token is stale enough that a
      // refresh was actually expected — otherwise this fires every second all day.
      if status.needsRefresh(at: instant, whenRemaining: refreshWhenRemaining) {
        logDeferredRefresh(profile: profile, status: status)
      }
      return
    }

    let config = configFilePath
    let attempt = refreshScheduler.failureCount + 1
    let secondsLeft = Int(status.timeRemaining(at: instant))
    // An attempt is under way, so whatever was last deferred no longer applies.
    lastDeferralReason = nil
    Self.logger.notice(
      """
      Auto-refresh attempt \(attempt, privacy: .public) for \(profile, privacy: .public), \
      \(secondsLeft, privacy: .public)s left
      """
    )
    work = Task { [weak self] in
      defer { self?.work = nil }
      guard let self else { return }
      do {
        let previousExpiry = self.status?.expiresAt
        // Bound the exchange so a hung request becomes a retryable failure rather
        // than a permanent wedge (see ``refreshTimeout``).
        let refreshed = try await withTimeout(Self.refreshTimeout) {
          try await SessionService.refresh(configFilePath: config, profile: profile)
        }
        self.status = refreshed
        self.lastError = nil
        self.notifiedExpiryFor = nil
        let outcome = self.refreshScheduler.recordSuccess(
          previousExpiry: previousExpiry, newExpiry: refreshed.expiresAt
        )
        Self.log(outcome, for: profile, newExpiry: refreshed.expiresAt, attempt: attempt)
      } catch let error as NeedsReauthentication {
        // Try the silent path if this profile has one. Never open a browser from a
        // background task — that is the user's decision to make.
        if let source = self.renewalSource(for: profile), let region = self.region(for: profile) {
          await self.renewSilently(profile: profile, source: source, region: region, after: error)
        } else {
          self.lastError = error.localizedDescription
          self.notifyReauthenticationNeeded(profile: profile, reason: error.reason)
          // No renewal source, so there is nothing to retry against — but back off
          // anyway so a dead session that is still unexpired is not re-attempted on
          // every tick until `exp` finally passes. The tick keeps advancing `now`
          // across the await above, so it is the moment the attempt actually failed.
          self.refreshScheduler.recordFailure(at: .now)
        }
      } catch {
        // Transient (a network blip, a throttled or timed-out exchange): let a later
        // tick try again, spaced out by the backoff so it is not hammered.
        self.lastError = Self.describe(error)
        self.refreshScheduler.recordFailure(at: .now)
        Self.logger.error(
          """
          Auto-refresh attempt \(attempt, privacy: .public) for \(profile, privacy: .public) \
          failed: \(Self.summarize(error), privacy: .public). Next attempt no sooner than \
          \(self.refreshScheduler.notBefore.formatted(date: .omitted, time: .standard), privacy: .public)
          """
        )
      }
    }
  }

  /// Reports what a successful refresh achieved.
  ///
  /// Shared by the background tick and the Refresh Session menu item, because the
  /// ceiling is a property of the session and not of who asked: a refresh by hand
  /// cannot extend an ended session either, and a ceiling reached that way used to
  /// stop auto-refresh without saying anything.
  ///
  /// The gain is logged on every refresh, not only when it is zero. A tenancy whose
  /// refreshes buy less than expected should be visible in Console *before* one of
  /// them lands under ``RefreshScheduler/minimumUsefulExtension`` and stops the
  /// countdown — the measured cases are 0s at a session's end and ~30 minutes for a
  /// healthy federated session, and anything in between is worth knowing about.
  private static func log(
    _ outcome: RefreshScheduler.Outcome,
    for profile: String,
    newExpiry: Date,
    attempt: Int?
  ) {
    let expiry = newExpiry.formatted(date: .omitted, time: .standard)
    let attemptNote = attempt.map { " on attempt \($0)" } ?? ""
    switch outcome {
    case .extended(let gain):
      logger.notice(
        """
        Refreshed \(profile, privacy: .public)\(attemptNote, privacy: .public): expires \
        \(expiry, privacy: .public), \(Int(gain), privacy: .public)s later than before
        """
      )
    case .atCeiling(let gain):
      // The one case worth finding in a log after the fact, so it is spelled out and
      // raised to `error` — it is why a countdown will run to zero without another
      // attempt, which otherwise looks exactly like the app having stopped working.
      logger.error(
        """
        SESSION CEILING: refresh of \(profile, privacy: .public) succeeded but moved the \
        expiry by only \(Int(gain), privacy: .public)s (under the \
        \(Int(RefreshScheduler.minimumUsefulExtension), privacy: .public)s needed to count). \
        The session has reached its maximum lifetime and cannot be extended; it expires \
        \(expiry, privacy: .public) and auto-refresh stops here. Signing in again is the \
        only way to continue.
        """
      )
    case .firstRefresh:
      logger.notice(
        """
        Refreshed \(profile, privacy: .public)\(attemptNote, privacy: .public): expires \
        \(expiry, privacy: .public) (no previous expiry to compare against)
        """
      )
    }
  }

  /// Explains a tick that found the token stale but did not act.
  ///
  /// Logged once per reason rather than on every tick: the tick runs every second,
  /// and a ten-minute backoff would otherwise put six hundred identical lines in
  /// Console and bury the thing being looked for.
  private func logDeferredRefresh(profile: String, status: SessionStatus) {
    let reason: String =
      refreshScheduler.isAtSessionCeiling
      ? "the session has reached its maximum lifetime and cannot be extended"
      : """
        backing off after \(refreshScheduler.failureCount) failure(s) until \
        \(refreshScheduler.notBefore.formatted(date: .omitted, time: .standard))
        """
    guard reason != lastDeferralReason else { return }
    lastDeferralReason = reason
    Self.logger.info(
      """
      \(profile, privacy: .public) is due a refresh but is not attempting one: \
      \(reason, privacy: .public)
      """
    )
  }

  /// The last deferral explanation logged, so a once-a-second tick does not repeat it.
  private var lastDeferralReason: String?

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
      refreshScheduler.reset()
      Self.logger.notice(
        "Renewed \(profile, privacy: .public) from \(source, privacy: .public) without a browser"
      )
    } catch {
      lastError = "\(failure.localizedDescription) Renewal from \(source) also failed: \(Self.describe(error))"
      notifyReauthenticationNeeded(profile: profile, reason: failure.reason)
      // The silent renewal may have failed transiently too; back off and let a later
      // tick retry rather than re-minting on every second. `.now` rather than the
      // published clock: this is the moment the attempt finished, and `now` only
      // tracks what the countdown is showing.
      refreshScheduler.recordFailure(at: .now)
    }
  }

  // MARK: Actions

  /// The Authenticate menu item.
  ///
  /// Refresh while the session is alive; otherwise renew from an API-key profile if
  /// one is linked, and fall back to the browser when it is not.
  func authenticate() {
    guard let profile = profileName, work == nil else {
      Self.logger.debug("Authenticate ignored: no profile selected, or work already in flight")
      return
    }
    Self.logger.notice(
      """
      Authenticate requested for \(profile, privacy: .public) — \
      \(self.hasSession ? "refreshing the live session" : "minting a new one", privacy: .public)
      """
    )
    work = Task { [weak self] in
      defer { self?.work = nil; self?.activity = .idle }
      guard let self else { return }
      do {
        if self.hasSession {
          self.activity = .refreshing
          let previousExpiry = self.status?.expiresAt
          let refreshed = try await SessionService.refresh(
            configFilePath: self.configFilePath, profile: profile
          )
          self.status = refreshed
          self.lastError = nil
          self.notifiedExpiryFor = nil
          // Asking by hand does not make a session extensible either, so the same
          // ceiling check applies — otherwise the tick would resume the spin the
          // moment the user pressed Refresh.
          let outcome = self.refreshScheduler.recordSuccess(
            previousExpiry: previousExpiry, newExpiry: refreshed.expiresAt
          )
          Self.log(outcome, for: profile, newExpiry: refreshed.expiresAt, attempt: nil)
          return
        }
        try await self.mintNewSession(profile: profile)
      } catch is NeedsReauthentication {
        // The refresh was refused mid-flight — the session ended between the
        // validity check above and the exchange. Minting a new one is the answer.
        Self.logger.notice(
          """
          Refresh of \(profile, privacy: .public) was refused mid-flight; the session ended \
          under us, so minting a new one instead
          """
        )
        do { try await self.mintNewSession(profile: profile) } catch {
          self.lastError = Self.describe(error)
          Self.logger.error(
            """
            Minting a session for \(profile, privacy: .public) failed: \
            \(Self.describe(error), privacy: .public)
            """
          )
        }
      } catch {
        self.lastError = Self.describe(error)
        Self.logger.error(
          """
          Authenticate for \(profile, privacy: .public) failed: \
          \(Self.describe(error), privacy: .public)
          """
        )
      }
    }
  }

  private func mintNewSession(profile: String) async throws {
    guard let region = region(for: profile) else {
      Self.logger.error("No region for \(profile, privacy: .public); cannot mint a session")
      throw ConfigErrors.missingRegion
    }

    if let source = renewalSource(for: profile) {
      activity = .creatingProfile(profile)
      status = try await SessionService.createSession(
        configFilePath: configFilePath,
        sourceProfile: source,
        targetProfile: profile,
        region: region
      )
    } else {
      // The common case: no API key to mint from, so the user signs in to the
      // Console. Only ever reached from a user action, never from the tick.
      Self.logger.notice(
        """
        Starting browser sign-in for \(profile, privacy: .public) in \
        \(region, privacy: .public); no API-key profile is linked
        """
      )
      activity = .signingIn
      let outcome = try await BrowserAuthFlow.run(
        configFilePath: configFilePath, profile: profile, region: region
      )
      status = outcome.status
    }
    lastError = nil
    notifiedExpiryFor = nil
    refreshScheduler.reset()
    Self.logger.notice(
      """
      New session in place for \(profile, privacy: .public), expiring \
      \(self.status?.expiresAt.formatted(date: .omitted, time: .standard) ?? "unknown", privacy: .public)
      """
    )
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

  /// A one-line form of `error` for logging.
  ///
  /// ``describe(_:)`` is what the menu shows, and for an `NSError` coming back
  /// through the SDK it carries the whole nested `userInfo` dump — several hundred
  /// characters of `_kCFStreamErrorCodeKey` and friends, which in Console pushes the
  /// next line off the screen and hides the one thing being looked for. The full
  /// text is still logged once, by ``SessionService``, at the point of failure.
  static func summarize(_ error: Error) -> String {
    let full = describe(error)
    guard let firstLine = full.split(whereSeparator: \.isNewline).first else { return full }
    let line = String(firstLine)
    // The interesting part of an NSError is what precedes its UserInfo blob.
    let trimmed = line.split(separator: "UserInfo=").first.map(String.init) ?? line
    return trimmed.count > 200 ? String(trimmed.prefix(200)) + "…" : trimmed
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
