// Copyright 2026 Ilia Sazonov
// SPDX-License-Identifier: MIT

import Foundation
import Testing

@testable import OCISessionBar

@Suite("Event log formatting")
struct EventLogLineTests {
  static let time = Date(timeIntervalSince1970: 1_800_000_000)
  static let expiry = Date(timeIntervalSince1970: 1_800_003_600)
  static let newExpiry = Date(timeIntervalSince1970: 1_800_007_200)

  /// A successful refresh names both expiries and the running count.
  @Test("A refresh with both expiries fills every column")
  func refreshWithBothExpiries() {
    let line = EventLog.line(
      for: EventLogEntry(
        time: Self.time, currentExpiry: Self.expiry, name: .refresh,
        newExpiry: Self.newExpiry, refreshCount: 3
      )
    )
    let columns = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
    #expect(columns.count == 5)
    #expect(columns[0] == Self.time.formatted(.iso8601))
    #expect(columns[1] == Self.expiry.formatted(.iso8601))
    #expect(columns[2] == "refresh")
    #expect(columns[3] == Self.newExpiry.formatted(.iso8601))
    #expect(columns[4] == "3")
  }

  /// A declined refresh has no new expiry — that column reads `NA`, not blank.
  @Test("A declined refresh renders the new expiry as NA")
  func declinedRefreshIsNA() {
    let line = EventLog.line(
      for: EventLogEntry(
        time: Self.time, currentExpiry: Self.expiry, name: .refresh,
        newExpiry: nil, refreshCount: 7
      )
    )
    let columns = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
    #expect(columns[3] == "NA")
    #expect(columns[4] == "7")
  }

  /// A first-time sign-in has no prior token, so the current expiry is `NA`.
  @Test("A fresh sign-in renders the current expiry as NA")
  func freshAuthIsNA() {
    let line = EventLog.line(
      for: EventLogEntry(
        time: Self.time, currentExpiry: nil, name: .auth,
        newExpiry: Self.newExpiry, refreshCount: 0
      )
    )
    let columns = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
    #expect(columns[1] == "NA")
    #expect(columns[2] == "auth")
    #expect(columns[4] == "0")
  }

  /// The count column carries no thousands separator, so it stays machine-readable
  /// in any locale.
  @Test("A large refresh count is written without grouping")
  func largeCountHasNoGrouping() {
    let line = EventLog.line(
      for: EventLogEntry(
        time: Self.time, currentExpiry: nil, name: .refresh, newExpiry: nil,
        refreshCount: 1234
      )
    )
    let columns = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
    #expect(columns[4] == "1234")
  }

  @Test("The default log path lands in the temp directory")
  func defaultPathIsInTemp() {
    let url = EventLog.defaultFileURL
    #expect(url.deletingLastPathComponent().path == FileManager.default.temporaryDirectory.path)
    #expect(url.lastPathComponent == "OCISessionBar-events.log")
  }
}

@Suite("Event log writing")
struct EventLogWritingTests {
  /// A private file per test, in the temp directory, removed on the way out — the
  /// project rule is never to touch the real one and always to clean up.
  private static func temporaryURL() -> URL {
    FileManager.default.temporaryDirectory
      .appending(path: "eventlog-test-\(UUID().uuidString).log")
  }

  static let time = Date(timeIntervalSince1970: 1_800_000_000)
  static let expiry = Date(timeIntervalSince1970: 1_800_003_600)

  @Test("The first write creates the file with a header then the line")
  func firstWriteAddsHeader() async throws {
    let url = Self.temporaryURL()
    defer { try? FileManager.default.removeItem(at: url) }

    let log = EventLog(fileURL: url)
    let entry = EventLogEntry(
      time: Self.time, currentExpiry: Self.expiry, name: .refresh,
      newExpiry: Self.expiry, refreshCount: 1
    )
    await log.record(entry)

    let contents = try String(contentsOf: url, encoding: .utf8)
    let lines = contents.split(whereSeparator: \.isNewline).map(String.init)
    #expect(lines.count == 2)
    #expect(lines[0] == EventLog.header)
    #expect(lines[1] == EventLog.line(for: entry))
  }

  @Test("A second write appends without repeating the header")
  func secondWriteAppends() async throws {
    let url = Self.temporaryURL()
    defer { try? FileManager.default.removeItem(at: url) }

    let log = EventLog(fileURL: url)
    let first = EventLogEntry(
      time: Self.time, currentExpiry: nil, name: .auth, newExpiry: Self.expiry, refreshCount: 0
    )
    let second = EventLogEntry(
      time: Self.time.addingTimeInterval(60), currentExpiry: Self.expiry, name: .refresh,
      newExpiry: nil, refreshCount: 1
    )
    await log.record(first)
    await log.record(second)

    let contents = try String(contentsOf: url, encoding: .utf8)
    let lines = contents.split(whereSeparator: \.isNewline).map(String.init)
    #expect(lines.count == 3)
    #expect(lines[0] == EventLog.header)
    #expect(lines[1] == EventLog.line(for: first))
    #expect(lines[2] == EventLog.line(for: second))
  }
}
