import AppKit
@preconcurrency import UserNotifications

/// The sounds an alert can play: the system's own, from
/// /System/Library/Sounds.
enum AlertSound {
  enum Kind {
    case finished, waiting

    /// Different by default, so the two can be told apart by ear.
    var fallback: String { self == .finished ? "Glass" : "Ping" }
  }

  static var names: [String] {
    let folder = URL(fileURLWithPath: "/System/Library/Sounds")
    let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
    let names = files.filter { $0.pathExtension == "aiff" }.map { $0.deletingPathExtension().lastPathComponent }
    return names.sorted()
  }

  /// The configured sound, or the kind's default when it is unset or gone.
  static func resolve(_ name: String, for kind: Kind) -> String {
    names.contains(name) ? name : kind.fallback
  }

  /// Plays it now: for alerts, and to preview a choice in Settings.
  @MainActor
  static func play(_ name: String, for kind: Kind) {
    // A fresh copy each time, so a preview clicked twice starts over.
    (NSSound(named: NSSound.Name(resolve(name, for: kind)))?.copy() as? NSSound)?.play()
  }
}

/// macOS notifications for alerts, when Settings asks for them. Permission is
/// asked the first time there is something to say. Needs the app bundle:
/// run from `swift run`, it only logs.
///
/// The notification itself is silent: the app plays the chosen sound, so any
/// system sound can be picked and previewed, and it plays without the
/// notification too.
@MainActor
final class Notifier {
  private var asked = false

  func notify(title: String, body: String) {
    guard Bundle.main.bundleIdentifier != nil else {
      NSLog("Omega Notch: \(body)")
      return
    }
    let center = UNUserNotificationCenter.current()
    let content = UNMutableNotificationContent()
    content.title = title
    content.body = body
    let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)

    let deliver: @Sendable (Bool) -> Void = { granted in
      if granted { center.add(request) }
    }
    if asked {
      center.getNotificationSettings { settings in
        deliver(settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional)
      }
      return
    }
    asked = true
    center.requestAuthorization(options: [.alert]) { granted, _ in deliver(granted) }
  }
}
