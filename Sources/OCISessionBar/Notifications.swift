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
/// wants to post, rather than at launch — a menu bar utility that prompts for
/// notification permission before it has anything to say is a nuisance. A refused
/// prompt is not an error: the menu still shows the state in full.
enum Notifications {
  private static let logger = Logger(subsystem: "com.iliasaz.OCISessionBar", category: "notifications")

  static func post(title: String, body: String) {
    Task {
      let center = UNUserNotificationCenter.current()
      do {
        guard try await center.requestAuthorization(options: [.alert, .sound]) else {
          logger.debug("Notification authorization declined; staying silent")
          return
        }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        try await center.add(
          UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        )
      } catch {
        // Unsigned development builds have no valid bundle identity for the
        // notification centre, which is expected and not worth surfacing.
        logger.debug("Could not post notification: \(error.localizedDescription, privacy: .public)")
      }
    }
  }
}
