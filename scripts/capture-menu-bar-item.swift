// Copyright 2026 Ilia Sazonov
// SPDX-License-Identifier: MIT

import AppKit

/// Writes the menu bar item out as a PNG with nothing behind it.
///
/// A screenshot of the same pixels comes back as a rectangle of *menu bar*: the
/// bar's own backdrop, the desktop picture showing through it, and whatever
/// happens to sit either side of the item. So this does not photograph the screen
/// — it asks the app's own ``MenuBarRenderer`` for the very image the status item
/// is displaying and saves that, alpha intact.
///
/// The state is the live one by default: the profile comes from the app's
/// `profileName` default and the countdown from the JWT in that profile's
/// `security_token_file`, so running this while the app is up reproduces what is
/// in the menu bar at that moment. `--text` and `--critical` override it when a
/// particular state is wanted rather than the current one.
///
/// Run via `scripts/capture-menu-bar-item.sh`.
@MainActor
func run() throws {
  let options = try Options(arguments: Array(CommandLine.arguments.dropFirst()))
  let presentation = try options.presentation()
  let appearance = options.appearance ?? menuBarAppearance()

  try writeMenuBarItem(
    presentation, appearance: appearance, to: options.output, scale: options.scale)
  print(
    "wrote \(options.output.path(percentEncoded: false)) — \(presentation), \(appearance) menu bar"
  )
}

// MARK: Live state

/// What the item is showing right now, derived from the token on disk.
///
/// The rules are ``SessionStatus``': two components at every magnitude so the item
/// does not change width every hour, and red under a tenth of the issued lifetime.
/// They are restated here rather than imported because that type is built against
/// `OCIKit`, and pulling the SDK in would make a docs script depend on a full
/// package resolve. Everything that decides how the item *looks* still comes from
/// the real renderer, so a capture can only ever be wrong about the clock.
nonisolated struct LiveSession {
  let expiresAt: Date
  let issuedAt: Date?

  /// OCI's ceiling on a session, and the denominator for a token that carries no
  /// `iat` — matches `SessionTokenClient.maximumSessionMinutes`.
  static let maximumLifetime: TimeInterval = 60 * 60

  var lifetime: TimeInterval {
    guard let issuedAt else { return Self.maximumLifetime }
    let span = expiresAt.timeIntervalSince(issuedAt)
    return span > 0 ? span : Self.maximumLifetime
  }

  func presentation(at now: Date) -> MenuBarPresentation {
    let remaining = expiresAt.timeIntervalSince(now)
    guard remaining > 0 else { return .expired }
    let total = Int(remaining.rounded(.down))
    let minutes = (total % 3600) / 60
    let text =
      "\(total / 3600):\(minutes.formatted(.number.grouping(.never).precision(.integerLength(2))))"
    return .countdown(text: text, isCritical: remaining / lifetime < 0.10)
  }

  /// The session for `profile`, read from its `security_token_file`.
  static func onDisk(profile: String, configPath: String) throws -> LiveSession {
    let config = try String(contentsOfFile: expandingTilde(configPath), encoding: .utf8)
    guard let path = value(of: "security_token_file", in: profile, of: config) else {
      throw Failure("profile [\(profile)] has no security_token_file in \(configPath)")
    }
    let token = try String(contentsOfFile: expandingTilde(path), encoding: .utf8)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return try claims(of: token)
  }

  /// One key of one INI section. Section names end at the first `]`, and the file
  /// is split on newlines as *Characters* so a CRLF config divides.
  private static func value(of key: String, in section: String, of config: String) -> String? {
    var isInSection = false
    for line in config.split(whereSeparator: \.isNewline) {
      let line = line.trimmingCharacters(in: .whitespaces)
      if line.hasPrefix("[") {
        isInSection = line.dropFirst().prefix(while: { $0 != "]" }) == section
      } else if isInSection, let separator = line.firstIndex(of: "=") {
        guard line[..<separator].trimmingCharacters(in: .whitespaces) == key else { continue }
        return line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)
      }
    }
    return nil
  }

  /// `exp` and `iat` out of the JWT payload. Nothing else in the token is read,
  /// and nothing from it is ever printed.
  private static func claims(of token: String) throws -> LiveSession {
    struct Claims: Decodable {
      let exp: TimeInterval
      let iat: TimeInterval?
    }
    let segments = token.split(separator: ".")
    guard segments.count > 1 else { throw Failure("the session token is not a JWT") }
    var encoded = String(segments[1])
      .replacing("-", with: "+")
      .replacing("_", with: "/")
    encoded += String(repeating: "=", count: (4 - encoded.count % 4) % 4)
    guard let data = Data(base64Encoded: encoded),
      let claims = try? JSONDecoder().decode(Claims.self, from: data)
    else { throw Failure("the session token's payload could not be decoded") }
    return LiveSession(
      expiresAt: Date(timeIntervalSince1970: claims.exp),
      issuedAt: claims.iat.map(Date.init(timeIntervalSince1970:))
    )
  }

  private static func expandingTilde(_ path: String) -> String {
    path.hasPrefix("~") ? NSString(string: path).expandingTildeInPath : path
  }
}

// MARK: Appearance

/// The menu bar's own appearance, read the way the app reads it.
///
/// It does not follow Dark Mode — the menu bar tracks the desktop picture too, so a
/// light-mode Mac with a dark wallpaper still gets a dark bar — and the only honest
/// source is a status button's `effectiveAppearance`. This process has no status
/// item, so it borrows one for the length of the question: a zero-width item that is
/// created, read and removed without ever being visible.
///
/// The wait is the whole trick. `NSStatusBar` hands back the item immediately but
/// AppKit does not put its window into `NSApp.windows` until the run loop turns, and
/// asking before then finds no button at all — at which point
/// ``MenuBarAppearance/current`` falls back to *this process's* appearance, which
/// follows Dark Mode and so reports light over a dark bar. Spinning the run loop
/// until the button exists is what makes the answer the menu bar's rather than
/// System Settings'.
@MainActor
func menuBarAppearance() -> MenuBarAppearance {
  let item = NSStatusBar.system.statusItem(withLength: 0)
  defer { NSStatusBar.system.removeStatusItem(item) }

  let deadline = Date.now.addingTimeInterval(2)
  while item.button?.window == nil, Date.now < deadline {
    RunLoop.current.run(mode: .default, before: Date.now.addingTimeInterval(0.05))
  }
  return MenuBarAppearance.current
}

// MARK: Options

@MainActor
struct Options {
  var output = URL(fileURLWithPath: "menu-bar-item.png")
  var scale: CGFloat = 3
  /// `nil` asks the menu bar itself.
  var appearance: MenuBarAppearance?
  var profile: String?
  var configPath = "~/.oci/config"
  /// Set by `--text`/`--expired`/`--unconfigured`, and overrides the live session.
  var forced: MenuBarPresentation?
  var isCritical = false

  init(arguments: [String]) throws {
    var arguments = arguments[...]
    var text: String?
    while let argument = arguments.popFirst() {
      func next(_ name: String) throws -> String {
        guard let value = arguments.popFirst() else { throw Failure("\(name) needs a value") }
        return value
      }
      switch argument {
      case "--scale": scale = CGFloat(Double(try next("--scale")) ?? 3)
      case "--profile": profile = try next("--profile")
      case "--config": configPath = try next("--config")
      case "--text": text = try next("--text")
      case "--critical": isCritical = true
      case "--expired": forced = .expired
      case "--unconfigured": forced = .unconfigured
      case "--appearance":
        let value = try next("--appearance")
        switch value {
        case "light": appearance = .light
        case "dark": appearance = .dark
        case "auto": appearance = nil
        default: throw Failure("--appearance takes light, dark or auto, not \(value)")
        }
      case let flag where flag.hasPrefix("-"): throw Failure("unknown option \(flag)")
      default: output = URL(fileURLWithPath: argument)
      }
    }
    if let text { forced = .countdown(text: text, isCritical: isCritical) }
  }

  /// The forced state, or the live one.
  func presentation() throws -> MenuBarPresentation {
    if let forced { return forced }
    guard
      let profile = profile
        ?? UserDefaults(suiteName: "com.iliasaz.OCISessionBar")?.string(forKey: "profileName")
    else { return .unconfigured }
    return try LiveSession.onDisk(profile: profile, configPath: configPath).presentation(at: .now)
  }
}

@main
enum Main {
  static func main() {
    _ = NSApplication.shared
    // Status items are only vended to apps that are in the activation policy at
    // all, and this binary has no bundle to declare `LSUIElement` in.
    NSApp.setActivationPolicy(.accessory)
    do {
      try run()
    } catch {
      FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
      exit(1)
    }
  }
}
