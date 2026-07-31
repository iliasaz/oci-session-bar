// Copyright 2026 Ilia Sazonov
// SPDX-License-Identifier: MIT

import Foundation
import OSLog

/// One refresh or auth event, as it is written to the opt-in event log.
///
/// A plain value so the formatting can be exercised without touching the disk;
/// the expiry fields are optional because a fresh sign-in has no prior token and a
/// declined refresh returns no new one, and both render as `NA`.
nonisolated struct EventLogEntry: Sendable, Equatable {
  /// What a row records: a refresh, a new-session mint (`auth`), or the marker
  /// written the moment logging is switched on so the file exists to be tailed.
  nonisolated enum Name: String, Sendable { case refresh, auth, start }

  /// When the event happened.
  let time: Date
  /// The token's expiry before the event, or `nil` when there was none.
  let currentExpiry: Date?
  let name: Name
  /// The expiry the server returned, or `nil` when it declined or the exchange
  /// failed.
  let newExpiry: Date?
  /// Refresh attempts recorded since the current session was minted.
  let refreshCount: Int
  /// A short note on the outcome — the reason a refresh was declined, or the error
  /// that stopped it. Empty for a clean success.
  let detail: String
}

/// Appends one line per refresh/auth event to a user-visible file, when the user
/// has turned the log on in Settings.
///
/// An actor so the append happens off the main actor and one write cannot tear
/// against another. The events are minutes apart in practice, so serializing them
/// costs nothing and buys an ordered, uncorrupted file.
actor EventLog {
  private let fileURL: URL
  private static let logger = Logger(
    subsystem: "com.iliasaz.OCISessionBar", category: "eventlog"
  )

  init(fileURL: URL) { self.fileURL = fileURL }

  /// The default log location: a fixed name in the system temp directory, so the
  /// path is stable enough to show and copy, and no token material lands anywhere
  /// but the log itself — which records only expiry timestamps, never a token.
  static var defaultFileURL: URL {
    FileManager.default.temporaryDirectory.appending(path: "OCISessionBar-events.log")
  }

  /// The tab-separated column header, written once when the file is first created.
  static let header =
    "time\tcurrent_expiration\tevent\tnew_expiration\trefresh_count\tdetail"

  /// The columns for one entry, tab-separated to match ``header``. Kept `nonisolated`
  /// and pure so the format is testable without a file.
  nonisolated static func line(for entry: EventLogEntry) -> String {
    func stamp(_ date: Date?) -> String { date?.formatted(.iso8601) ?? "NA" }
    return [
      stamp(entry.time),
      stamp(entry.currentExpiry),
      entry.name.rawValue,
      stamp(entry.newExpiry),
      entry.refreshCount.formatted(.number.grouping(.never)),
      // The detail is free text from an error, which may carry tabs or newlines;
      // flatten them so one entry stays one line with a stable column count.
      flatten(entry.detail),
    ].joined(separator: "\t")
  }

  /// Collapses tabs and newlines to single spaces, so free-text detail cannot break
  /// the tab-separated layout. Trimmed so an all-whitespace note reads as empty.
  private nonisolated static func flatten(_ text: String) -> String {
    text
      .replacing("\t", with: " ")
      .split(whereSeparator: \.isNewline)
      .joined(separator: " ")
      .trimmingCharacters(in: .whitespaces)
  }

  /// Appends `entry` to the file, writing the header first if the file is new.
  ///
  /// Best-effort: a log that cannot be written must never take down the refresh it
  /// was recording, so a failure is logged to Console and swallowed.
  func record(_ entry: EventLogEntry) {
    guard let payload = (Self.line(for: entry) + "\n").data(using: .utf8) else { return }
    do {
      if FileManager.default.fileExists(atPath: fileURL.path(percentEncoded: false)) {
        let handle = try FileHandle(forWritingTo: fileURL)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: payload)
      } else {
        let header = Data((Self.header + "\n").utf8)
        try (header + payload).write(to: fileURL, options: .atomic)
      }
    } catch {
      Self.logger.error(
        "Could not append to the event log: \(String(describing: error), privacy: .public)"
      )
    }
  }
}
