// Copyright 2026 Ilia Sazonov
// SPDX-License-Identifier: MIT

import Foundation
import Network
import OSLog

/// Receives the Console's sign-in redirect on `http://localhost:8181`.
///
/// Two GETs arrive, not one. The Console returns the token in the URL *fragment*,
/// which browsers never put on the wire, so the first request — for `/` — is
/// answered with a small page whose script re-issues the fragment as a query
/// string. The token is read from that second request.
///
/// `NWListener` rather than an HTTP package: the protocol surface here is two bare
/// GETs with no body, no TLS and no keep-alive, so a full server would be a large
/// dependency for a listener that lives about a minute. It also binds IPv4 *and*
/// IPv6 loopback by default, which matters because browsers resolve `localhost` to
/// either one.
actor LoopbackTokenCatcher {
  enum Failure: LocalizedError {
    case portUnavailable(UInt16, detail: String)
    case timedOut(Duration)
    case cancelled

    var errorDescription: String? {
      switch self {
      case .portUnavailable(let port, let detail):
        """
        Port \(port) is not available (\(detail)). Oracle registers \
        http://localhost:\(port) as the sign-in redirect for the OCI Console, so no \
        other port can be used. Quit whatever is holding it — often an `oci session \
        authenticate` still waiting in a terminal — and try again.
        """
      case .timedOut(let duration):
        "Sign-in was not completed within \(duration.components.seconds / 60) minutes."
      case .cancelled:
        "Sign-in was cancelled."
      }
    }
  }

  private let logger = Logger(subsystem: "com.iliasaz.OCISessionBar", category: "callback")
  private let port: UInt16

  private var listener: NWListener?
  private var connections: [NWConnection] = []

  private var readyContinuation: CheckedContinuation<Void, Error>?
  private var tokenContinuation: CheckedContinuation<String, Error>?
  /// Set if the token arrives before anyone asks for it, so it is never dropped.
  private var capturedToken: String?
  private var terminalError: Error?

  init(port: UInt16 = ConsoleAuthURL.redirectPort) {
    self.port = port
  }

  /// Binds the port and returns once the listener is actually accepting.
  ///
  /// Separate from ``waitForToken(timeout:)`` on purpose: the browser must not be
  /// opened until the socket is up, otherwise a fast redirect can arrive before
  /// anything is listening. It also makes a port conflict fail immediately, before
  /// a keypair is generated or a browser window appears.
  func bind() async throws {
    let parameters = NWParameters.tcp
    parameters.allowLocalEndpointReuse = true
    // The redirect only ever originates on this machine.
    parameters.requiredInterfaceType = .loopback

    guard let nwPort = NWEndpoint.Port(rawValue: port) else {
      throw Failure.portUnavailable(port, detail: "invalid port number")
    }
    let listener: NWListener
    do {
      listener = try NWListener(using: parameters, on: nwPort)
    } catch {
      throw Failure.portUnavailable(port, detail: error.localizedDescription)
    }
    self.listener = listener

    listener.stateUpdateHandler = { [weak self] state in
      Task { await self?.handle(state: state) }
    }
    listener.newConnectionHandler = { [weak self] connection in
      Task { await self?.accept(connection) }
    }

    try await withCheckedThrowingContinuation { continuation in
      readyContinuation = continuation
      listener.start(queue: .global(qos: .userInitiated))
    }
    logger.debug("Listening on loopback port \(self.port, privacy: .public)")
  }

  /// Waits for the Console redirect to deliver a security token.
  ///
  /// The `oci` CLI blocks here forever; a menu bar app cannot, so an unattended
  /// sign-in gives up rather than holding port 8181 indefinitely.
  func waitForToken(timeout: Duration = .seconds(300)) async throws -> String {
    if let capturedToken { return capturedToken }
    if let terminalError { throw terminalError }

    return try await withThrowingTaskGroup(of: String.self) { group in
      group.addTask { try await self.awaitCallback() }
      group.addTask {
        try await Task.sleep(for: timeout)
        throw Failure.timedOut(timeout)
      }
      defer { group.cancelAll() }
      guard let token = try await group.next() else { throw Failure.cancelled }
      return token
    }
  }

  private func awaitCallback() async throws -> String {
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        if let capturedToken {
          continuation.resume(returning: capturedToken)
        } else if let terminalError {
          continuation.resume(throwing: terminalError)
        } else {
          tokenContinuation = continuation
        }
      }
    } onCancel: {
      Task { await self.finish(.failure(Failure.cancelled)) }
    }
  }

  /// Tears down the listener and every connection. Safe to call more than once.
  func shutdown() {
    listener?.cancel()
    listener = nil
    for connection in connections { connection.cancel() }
    connections.removeAll()
  }

  // MARK: Listener plumbing

  private func handle(state: NWListener.State) {
    switch state {
    case .ready:
      readyContinuation?.resume()
      readyContinuation = nil
    case .failed(let error):
      let failure = Failure.portUnavailable(port, detail: error.localizedDescription)
      readyContinuation?.resume(throwing: failure)
      readyContinuation = nil
      finish(.failure(failure))
    case .cancelled:
      readyContinuation?.resume(throwing: Failure.cancelled)
      readyContinuation = nil
    default:
      break
    }
  }

  private func accept(_ connection: NWConnection) {
    connections.append(connection)
    connection.start(queue: .global(qos: .userInitiated))
    receiveRequest(on: connection)
  }

  private func receiveRequest(on connection: NWConnection) {
    connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
      [weak self] data, _, isComplete, error in
      guard let self else { return }
      guard error == nil, let data, !data.isEmpty else {
        if isComplete || error != nil { connection.cancel() }
        return
      }
      Task { await self.handleRequest(data: data, on: connection) }
    }
  }

  private func handleRequest(data: Data, on connection: NWConnection) {
    guard let text = String(data: data, encoding: .utf8),
      let requestLine = text.split(separator: "\r\n", maxSplits: 1).first,
      let target = requestLine.split(separator: " ").dropFirst().first
    else {
      connection.cancel()
      return
    }
    respond(to: String(target), on: connection)
  }

  private func respond(to target: String, on connection: NWConnection) {
    // The Console's redirect lands on "/" with everything interesting in the
    // fragment, which the browser keeps to itself. Hand back a page that re-sends
    // the fragment as a query string.
    if target == "/" || target.hasPrefix("/?") {
      send(Self.fragmentRelayPage, on: connection)
      return
    }

    guard let components = URLComponents(string: "http://localhost\(target)"),
      let token = components.queryItems?.first(where: { $0.name == "security_token" })?.value,
      !token.isEmpty
    else {
      // Stray requests — /favicon.ico and the like — get a page and are ignored;
      // the sign-in is still in flight.
      send(Self.waitingPage, on: connection)
      return
    }

    send(Self.successPage, on: connection)
    logger.debug("Received a security token on the loopback callback")
    finish(.success(token))
  }

  private func send(_ html: String, on connection: NWConnection) {
    let body = Data(html.utf8)
    let headers = """
      HTTP/1.1 200 OK\r
      Content-Type: text/html; charset=utf-8\r
      Content-Length: \(body.count)\r
      Cache-Control: no-store\r
      Connection: close\r
      \r\n
      """
    connection.send(
      content: Data(headers.utf8) + body,
      completion: .contentProcessed { _ in connection.cancel() }
    )
  }

  private func finish(_ result: Result<String, Error>) {
    switch result {
    case .success(let token):
      guard capturedToken == nil else { return }
      capturedToken = token
    case .failure(let error):
      guard capturedToken == nil, terminalError == nil else { return }
      terminalError = error
    }
    if let continuation = tokenContinuation {
      tokenContinuation = nil
      continuation.resume(with: result)
    }
  }

  // MARK: Pages

  private static let pageStyle = """
    body { font: 15px -apple-system, system-ui, sans-serif; color: #1d1d1f;
           background: #fff; padding: 4rem 2rem; text-align: center; }
    @media (prefers-color-scheme: dark) { body { color: #f5f5f7; background: #1d1d1f; } }
    """

  /// Re-issues the URL fragment as a query string so the token reaches the server.
  static let fragmentRelayPage = """
    <!doctype html><html><head><meta charset="utf-8"><title>Signing in…</title>
    <style>\(pageStyle)</style></head><body>
    <p id="status">Completing sign-in…</p>
    <script>
    var fragment = window.location.hash;
    if (fragment.charAt(0) === '#') { fragment = fragment.substring(1); }
    var request = new XMLHttpRequest();
    request.addEventListener('load', function () {
      document.getElementById('status').textContent =
        'Sign-in complete. You can close this window.';
    });
    request.open('GET', '/token?' + fragment);
    request.send();
    </script></body></html>
    """

  static let successPage = """
    <!doctype html><html><head><meta charset="utf-8"><title>Signed in</title>
    <style>\(pageStyle)</style></head><body>
    <p>Sign-in complete. You can close this window.</p>
    </body></html>
    """

  static let waitingPage = """
    <!doctype html><html><head><meta charset="utf-8"><title>Waiting</title>
    <style>\(pageStyle)</style></head><body>
    <p>Waiting for the OCI Console to complete sign-in…</p>
    </body></html>
    """
}
