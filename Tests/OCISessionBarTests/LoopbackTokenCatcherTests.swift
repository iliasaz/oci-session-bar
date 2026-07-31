// Copyright 2026 Ilia Sazonov
// SPDX-License-Identifier: MIT

import Foundation
import Testing

@testable import OCISessionBar

/// These bind a real socket and speak real HTTP to it, because the parts most
/// likely to break — the two-request fragment relay, and giving up cleanly — cannot
/// be observed any other way.
///
/// Each catcher binds port 0, so the OS hands out a free loopback port and the test
/// reads it back with ``LoopbackTokenCatcher/boundPort``. Fixed ports were the old
/// approach and were flaky: the numbers chosen sat inside the ephemeral range the OS
/// itself hands out, so an unrelated outbound socket on the machine could already be
/// holding one when `bind()` ran. An OS-assigned port cannot collide, so the tests
/// no longer need a port to themselves and can run in parallel.
@Suite("Loopback callback")
struct LoopbackTokenCatcherTests {
  private func get(_ path: String, port: UInt16) async throws -> String {
    let url = try #require(URL(string: "http://127.0.0.1:\(port)\(path)"))
    let (data, _) = try await URLSession.shared.data(from: url)
    return String(decoding: data, as: UTF8.self)
  }

  /// Binds a catcher on an OS-assigned port and returns both, so a test can drive it
  /// without repeating the ceremony.
  private func boundCatcher() async throws -> (catcher: LoopbackTokenCatcher, port: UInt16) {
    let catcher = LoopbackTokenCatcher(port: 0)
    try await catcher.bind()
    let port = try #require(await catcher.boundPort)
    return (catcher, port)
  }

  @Test("A token in the query string is captured and acknowledged")
  func capturesToken() async throws {
    let (catcher, port) = try await boundCatcher()

    async let captured = catcher.waitForToken(timeout: .seconds(10))
    let page = try await get("/token?security_token=abc.def.ghi", port: port)

    #expect(try await captured == "abc.def.ghi")
    #expect(page.contains("You can close this window"))
    await catcher.shutdown()
  }

  /// The Console puts the token in the URL fragment, which browsers keep to
  /// themselves. The first response has to be the script that sends it back.
  @Test("The root request returns the fragment relay page")
  func servesFragmentRelay() async throws {
    let (catcher, port) = try await boundCatcher()

    async let captured = catcher.waitForToken(timeout: .seconds(10))
    let relay = try await get("/", port: port)
    #expect(relay.contains("window.location.hash"))
    #expect(relay.contains("/token?"))

    // The relay's own follow-up request is what actually delivers the token.
    _ = try await get("/token?security_token=from.the.fragment", port: port)
    #expect(try await captured == "from.the.fragment")
    await catcher.shutdown()
  }

  @Test("Stray requests do not end the wait")
  func ignoresStrayRequests() async throws {
    let (catcher, port) = try await boundCatcher()

    async let captured = catcher.waitForToken(timeout: .seconds(10))
    _ = try await get("/favicon.ico", port: port)
    _ = try await get("/token?error=access_denied", port: port)
    // Still waiting, so the real callback afterwards is the one that counts.
    _ = try await get("/token?security_token=eventual.token", port: port)

    #expect(try await captured == "eventual.token")
    await catcher.shutdown()
  }

  @Test("An unattended sign-in gives up rather than holding the port")
  func timesOut() async throws {
    let (catcher, _) = try await boundCatcher()
    await #expect(throws: LoopbackTokenCatcher.Failure.self) {
      try await catcher.waitForToken(timeout: .milliseconds(300))
    }
    await catcher.shutdown()
  }

  /// Port 8181 is not negotiable, so a conflict has to surface as a clear error at
  /// bind time — before a browser window opens — not as a silent hang. The holder
  /// takes an OS-assigned port and the second catcher is pointed at that exact port,
  /// so the conflict is real without pinning a number the OS might hand out.
  @Test("A port already in use fails at bind")
  func reportsPortConflict() async throws {
    let (holder, held) = try await boundCatcher()

    let second = LoopbackTokenCatcher(port: held)
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
    let (catcher, port) = try await boundCatcher()

    // No waiter yet — this is the race the browser can win if the user is quick.
    _ = try await get("/token?security_token=early.bird", port: port)
    try await Task.sleep(for: .milliseconds(200))

    let token = try await catcher.waitForToken(timeout: .seconds(5))
    #expect(token == "early.bird")
    await catcher.shutdown()
  }
}
