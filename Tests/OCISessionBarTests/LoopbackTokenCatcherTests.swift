// Copyright 2026 Ilia Sazonov
// SPDX-License-Identifier: MIT

import Foundation
import Testing

@testable import OCISessionBar

/// These bind a real socket and speak real HTTP to it, because the parts most
/// likely to break — the two-request fragment relay, and giving up cleanly — cannot
/// be observed any other way.
///
/// A high port is used rather than 8181 so the suite never fights the app, the
/// `oci` CLI, or a second copy of itself. `.serialized` because each test wants the
/// port to itself.
@Suite("Loopback callback", .serialized)
struct LoopbackTokenCatcherTests {
  /// Well outside anything OCI or the OS hands out. Each test takes its own port:
  /// a closed listening socket can linger briefly, so reusing one port across tests
  /// makes the suite flaky in a way that has nothing to do with the code.
  enum Port {
    static let capture: UInt16 = 49_181
    static let relay: UInt16 = 49_182
    static let stray: UInt16 = 49_183
    static let timeout: UInt16 = 49_184
    static let conflict: UInt16 = 49_185
    static let early: UInt16 = 49_186
  }

  private func get(_ path: String, port: UInt16) async throws -> String {
    let url = try #require(URL(string: "http://127.0.0.1:\(port)\(path)"))
    let (data, _) = try await URLSession.shared.data(from: url)
    return String(decoding: data, as: UTF8.self)
  }

  @Test("A token in the query string is captured and acknowledged")
  func capturesToken() async throws {
    let catcher = LoopbackTokenCatcher(port: Port.capture)
    try await catcher.bind()

    async let captured = catcher.waitForToken(timeout: .seconds(10))
    let page = try await get("/token?security_token=abc.def.ghi", port: Port.capture)

    #expect(try await captured == "abc.def.ghi")
    #expect(page.contains("You can close this window"))
    await catcher.shutdown()
  }

  /// The Console puts the token in the URL fragment, which browsers keep to
  /// themselves. The first response has to be the script that sends it back.
  @Test("The root request returns the fragment relay page")
  func servesFragmentRelay() async throws {
    let catcher = LoopbackTokenCatcher(port: Port.relay)
    try await catcher.bind()

    async let captured = catcher.waitForToken(timeout: .seconds(10))
    let relay = try await get("/", port: Port.relay)
    #expect(relay.contains("window.location.hash"))
    #expect(relay.contains("/token?"))

    // The relay's own follow-up request is what actually delivers the token.
    _ = try await get("/token?security_token=from.the.fragment", port: Port.relay)
    #expect(try await captured == "from.the.fragment")
    await catcher.shutdown()
  }

  @Test("Stray requests do not end the wait")
  func ignoresStrayRequests() async throws {
    let catcher = LoopbackTokenCatcher(port: Port.stray)
    try await catcher.bind()

    async let captured = catcher.waitForToken(timeout: .seconds(10))
    _ = try await get("/favicon.ico", port: Port.stray)
    _ = try await get("/token?error=access_denied", port: Port.stray)
    // Still waiting, so the real callback afterwards is the one that counts.
    _ = try await get("/token?security_token=eventual.token", port: Port.stray)

    #expect(try await captured == "eventual.token")
    await catcher.shutdown()
  }

  @Test("An unattended sign-in gives up rather than holding the port")
  func timesOut() async throws {
    let catcher = LoopbackTokenCatcher(port: Port.timeout)
    try await catcher.bind()
    await #expect(throws: LoopbackTokenCatcher.Failure.self) {
      try await catcher.waitForToken(timeout: .milliseconds(300))
    }
    await catcher.shutdown()
  }

  /// Port 8181 is not negotiable, so a conflict has to surface as a clear error at
  /// bind time — before a browser window opens — not as a silent hang.
  @Test("A port already in use fails at bind")
  func reportsPortConflict() async throws {
    let holder = LoopbackTokenCatcher(port: Port.conflict)
    try await holder.bind()

    let second = LoopbackTokenCatcher(port: Port.conflict)
    await #expect(throws: LoopbackTokenCatcher.Failure.self) {
      try await second.bind()
    }
    // Awaited, not deferred into a detached task: the port has to be released
    // before the test returns, or the release races the next test.
    await holder.shutdown()
  }

  @Test("The port conflict message names the port and the likely culprit")
  func explainsPortConflict() {
    let message = LoopbackTokenCatcher.Failure
      .portUnavailable(8181, detail: "Address already in use")
      .localizedDescription
    #expect(message.contains("8181"))
    #expect(message.contains("oci session authenticate"))
  }

  @Test("A token arriving before anyone waits is not dropped")
  func retainsEarlyToken() async throws {
    let catcher = LoopbackTokenCatcher(port: Port.early)
    try await catcher.bind()

    // No waiter yet — this is the race the browser can win if the user is quick.
    _ = try await get("/token?security_token=early.bird", port: Port.early)
    try await Task.sleep(for: .milliseconds(200))

    let token = try await catcher.waitForToken(timeout: .seconds(5))
    #expect(token == "early.bird")
    await catcher.shutdown()
  }
}
