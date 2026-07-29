// Copyright 2026 Ilia Sazonov
// SPDX-License-Identifier: MIT

import Foundation
import OSLog
import UserNotifications

/// User notifications for the one thing worth interrupting for: a session that can
/// no longer be kept alive in the background, so the countdown is heading to zero
/// unless the user signs in.
///
/// Authorization is requested lazily, on the first notification the app actually
/// wants to post, rather than at launch — a menu bar utility that asks for
/// notification permission before it has anything to say is a nuisance.
///
/// Notifications are a *supplement* to the menu, never the only way to learn
/// something: the menu always shows the same state, so a refused prompt — or a
/// build that cannot post at all — costs the user nothing.
@MainActor
enum Notifications {
  private static let logger = Logger(subsystem: "com.iliasaz.OCISessionBar", category: "notifications")

  /// Whether posting is possible at all, decided once.
  private enum Availability {
    case unknown
    case allowed
    /// Refused by the user, or unavailable to this build. Either way, stop asking.
    case unavailable
  }

  private static var availability: Availability = .unknown

  static func post(title: String, body: String) {
    guard availability != .unavailable else { return }
    Task { await send(title: title, body: body) }
  }

  private static func send(title: String, body: String) async {
    let center = UNUserNotificationCenter.current()

    if availability == .unknown {
      do {
        let granted = try await center.requestAuthorization(options: [.alert, .sound])
        availability = granted ? .allowed : .unavailable
        if !granted {
          logger.notice("Notification authorization declined; the menu still shows session state")
          return
        }
      } catch {
        // The usual cause is not a real problem: a development build run straight
        // from DerivedData has no registered bundle identity, so the notification
        // centre refuses it outright with "Notifications are not allowed for this
        // application". A signed, notarized copy in /Applications works normally.
        // Recorded once, at debug level, because it says nothing actionable.
        availability = .unavailable
        logger.debug(
          """
          Notifications unavailable (\(error.localizedDescription, privacy: .public)). \
          Expected for an unsigned development build; session state is still shown in the menu.
          """
        )
        return
      }
    }

    let content = UNMutableNotificationContent()
    content.title = title
    content.body = body
    content.sound = .default
    do {
      try await center.add(
        UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
      )
    } catch {
      logger.debug("Could not post notification: \(error.localizedDescription, privacy: .public)")
    }
  }
}
