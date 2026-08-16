// Copyright 2026 Ilia Sazonov
// SPDX-License-Identifier: MIT

import Foundation
import Testing

@testable import OCISessionBar

/// The menu's authentication items: one button that says what it will do, plus a
/// second new-session button that appears only while a session is live — a session
/// at its ceiling refreshes to the same expiry, so Refresh alone can strand the
/// user until the token lapses.
@MainActor
@Suite("Authenticate menu items")
struct AuthMenuItemsTests {
  // In the preview fixture, "jroga-token" has a linked API-key renewal source and
  // "boat" does not — which is exactly the pair of cases the titles hinge on.

  @Test("A live session offers Refresh, with Sign In beside it")
  func liveSessionOffersBoth() {
    let model = AuthModel.preview(profileName: "boat")
    #expect(model.hasSession)
    #expect(model.authenticateTitle == "Refresh Session")
    #expect(model.newSessionTitle == "Sign In…")
  }

  @Test("A profile with a renewal source starts over silently, not via the browser")
  func renewalSourceRenamesTheNewSessionItem() {
    let model = AuthModel.preview(profileName: "jroga-token")
    #expect(model.hasSession)
    #expect(model.authenticateTitle == "Refresh Session")
    #expect(model.newSessionTitle == "Renew Session")
  }

  /// With no live session the primary item already mints a new session, so the
  /// menu must collapse to one item — its title and the new-session title must
  /// agree, or hiding the second item would hide a distinct action.
  @Test("Without a live session the two items would be twins, so only one shows")
  func expiredSessionCollapsesToOneItem() {
    let expired = AuthModel.preview(profileName: "boat", status: .previewExpired)
    #expect(expired.hasSession == false)
    #expect(expired.authenticateTitle == "Sign In…")
    #expect(expired.authenticateTitle == expired.newSessionTitle)

    let renewable = AuthModel.preview(profileName: "jroga-token", status: .previewExpired)
    #expect(renewable.hasSession == false)
    #expect(renewable.authenticateTitle == "Renew Session")
    #expect(renewable.authenticateTitle == renewable.newSessionTitle)
  }

  @Test("A profile with no session at all is offered a sign-in")
  func noTokenOffersSignIn() {
    let model = AuthModel.preview(profileName: "boat", status: nil)
    #expect(model.hasSession == false)
    #expect(model.authenticateTitle == "Sign In…")
  }

  @Test("With no profile selected the item stays a generic Authenticate")
  func noProfileStaysGeneric() {
    let model = AuthModel.preview(profileName: nil, status: nil)
    #expect(model.hasSession == false)
    #expect(model.authenticateTitle == "Authenticate…")
  }
}
