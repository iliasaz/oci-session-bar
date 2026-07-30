// Copyright 2026 Ilia Sazonov
// SPDX-License-Identifier: MIT

import Foundation
import Testing

@testable import OCISessionBar

@Suite("App version")
struct AppVersionTests {
  @Test("Reads the release tag and build number the workflow injected")
  func readsReleaseAndBuild() {
    let version = AppVersion(infoDictionary: [
      "CFBundleShortVersionString": "0.3",
      "CFBundleVersion": "42",
    ])
    #expect(version?.release == "0.3")
    #expect(version?.build == "42")
    #expect(version?.displayName == "Version 0.3 (42)")
  }

  @Test("A three-part release tag survives verbatim")
  func threePartTag() {
    let version = AppVersion(infoDictionary: ["CFBundleShortVersionString": "0.0.2", "CFBundleVersion": "7"])
    #expect(version?.displayName == "Version 0.0.2 (7)")
  }

  @Test("Omits the build number when there is none")
  func omitsMissingBuild() {
    let version = AppVersion(infoDictionary: ["CFBundleShortVersionString": "0.3"])
    #expect(version?.build == nil)
    #expect(version?.displayName == "Version 0.3")
  }

  @Test("Omits the build number when it merely repeats the release")
  func omitsRedundantBuild() {
    let version = AppVersion(infoDictionary: [
      "CFBundleShortVersionString": "1",
      "CFBundleVersion": "1",
    ])
    #expect(version?.displayName == "Version 1")
  }

  // The menu must show nothing rather than a raw build-setting placeholder, which
  // is what an unsubstituted Info.plist leaves behind.
  @Test(
    "Refuses a version that is not a version",
    arguments: [
      ["CFBundleShortVersionString": "$(MARKETING_VERSION)"],
      ["CFBundleShortVersionString": ""],
      [:],
    ] as [[String: String]]
  )
  func refusesUnusableVersion(info: [String: String]) {
    #expect(AppVersion(infoDictionary: info) == nil)
  }

  @Test("Refuses a bundle with no Info.plist at all")
  func refusesMissingInfoDictionary() {
    #expect(AppVersion(infoDictionary: nil) == nil)
  }

  // Ground truth: the real app bundle these tests are hosted in. This is the value
  // the menu item will actually display, and it catches a project.yml that stopped
  // wiring MARKETING_VERSION through to CFBundleShortVersionString.
  //
  // The bundle is located from an app type, not a test type: the tests live in their
  // own `.xctest` bundle inside the app, so a marker class declared here would find
  // that bundle's Info.plist instead of the app's.
  @Test("The app bundle under test carries a substituted version")
  func hostBundleHasVersion() throws {
    let version = try #require(AppVersion(bundle: Bundle(for: AuthModel.self)))
    #expect(!version.release.isEmpty)
    #expect(!version.release.contains("$("))
  }
}
