import Foundation
@preconcurrency import UserNotifications

/// macOS notifications for sessions that finish or need you. Permission is
/// asked the first time there is something to say. Needs the app bundle:
/// run from `swift run`, it only logs.
@MainActor
final class Notifier {
  private var asked = false

  func notify(title: String, body: String, sound: Bool) {
    guard Bundle.main.bundleIdentifier != nil else {
      NSLog("Omega Notch: \(body)")
      return
    }
    let center = UNUserNotificationCenter.current()
    let content = UNMutableNotificationContent()
    content.title = title
    content.body = body
    if sound { content.sound = .default }
    let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)

    if asked {
      center.add(request)
      return
    }
    asked = true
    center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
      if granted { center.add(request) }
    }
  }
}
