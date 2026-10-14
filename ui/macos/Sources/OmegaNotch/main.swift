import AppKit
import OmegaNotchKit

/// The app: an agent (no Dock icon, no menu bar) that runs the engine, shows
/// the notch, and opens Settings and the Dashboard on demand.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
  let supervisor = EngineSupervisor()
  let client = EngineClient()
  lazy var model = NotchModel(client: client)
  lazy var notch = NotchPanelController(model: model)
  let notifications = Notifier()
  lazy var windows = Windows(client: client)

  func applicationDidFinishLaunching(_ notification: Notification) {
    supervisor.start()

    client.onSessionFinished = { [weak self] provider, label in
      self?.announce(
        label.isEmpty ? "\(provider) finished" : "\(provider) · \(label) finished", .finished)
    }
    client.onSessionWaiting = { [weak self] provider, label in
      self?.announce(
        label.isEmpty ? "\(provider) is waiting on you" : "\(provider) · \(label) is waiting on you",
        .waiting)
    }
    client.onLimitReached = { [weak self] limit in
      self?.announce(Format.limitAlert(limit), .waiting)
    }
    client.onCopilotCode = { login in Windows.finishCopilotSignIn(login) }
    client.onRaiseWindow = { request in WindowRaiser.raise(request) }
    client.start()

    notch.openSettings = { [weak self] in self?.windows.showSettings() }
    notch.openDashboard = { [weak self] in self?.windows.showDashboard() }
    notch.show()

    if model.previewProvider == "settings" { windows.showSettings() }
  }

  func applicationWillTerminate(_ notification: Notification) {
    supervisor.stop()
  }

  /// The notch shows the alert on its own; this adds the sound and, when
  /// asked for, a system notification.
  private func announce(_ body: String, _ kind: AlertSound.Kind) {
    let config = client.config
    guard config.alertsEnabled else { return }
    if config.soundEnabled {
      AlertSound.play(kind == .finished ? config.soundFinished : config.soundWaiting, for: kind)
    }
    if config.systemNotifications {
      notifications.notify(title: "Omega Notch", body: body)
    }
  }
}

MainActor.assumeIsolated {
  let app = NSApplication.shared
  let delegate = AppDelegate()
  app.delegate = delegate
  app.setActivationPolicy(.accessory)
  app.run()
}
