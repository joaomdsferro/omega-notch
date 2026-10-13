import AppKit
import OmegaNotchKit
import SwiftUI

/// Settings and the Dashboard: ordinary windows, opened from the notch and
/// brought forward if they are already open.
@MainActor
final class Windows {
  let client: EngineClient
  private var settings: NSWindow?
  private var dashboard: NSWindow?

  init(client: EngineClient) {
    self.client = client
  }

  func showSettings() {
    if settings == nil {
      settings = makeWindow(
        title: "Omega Notch Settings", size: CGSize(width: 700, height: 640),
        content: SettingsView(client: client))
    }
    bringForward(settings)
  }

  func showDashboard() {
    client.requestDashboard(days: 30)
    if dashboard == nil {
      dashboard = makeWindow(
        title: "Omega Notch Dashboard", size: CGSize(width: 1180, height: 820),
        content: DashboardView(client: client) { [weak self] in self?.showSettings() })
    }
    bringForward(dashboard)
  }

  /// Once GitHub's device code arrives, copy it and open GitHub's page, so all
  /// that is left is pasting it.
  static func finishCopilotSignIn(_ login: CopilotLogin) {
    if let code = login.userCode, !code.isEmpty {
      NSPasteboard.general.clearContents()
      NSPasteboard.general.setString(code, forType: .string)
    }
    openVerification(login)
  }

  /// Opens GitHub's verification page; only ever an https link.
  static func openVerification(_ login: CopilotLogin) {
    guard let raw = login.verificationUri, let url = URL(string: raw), url.scheme == "https" else {
      return
    }
    NSWorkspace.shared.open(url)
  }

  private func makeWindow(title: String, size: CGSize, content: some View) -> NSWindow {
    let window = NSWindow(
      contentRect: CGRect(origin: .zero, size: size),
      styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
      backing: .buffered, defer: false)
    window.title = title
    window.titlebarAppearsTransparent = true
    window.isReleasedWhenClosed = false
    window.appearance = NSAppearance(named: .darkAqua)
    window.backgroundColor = NSColor(Theme.panel)
    window.contentView = NSHostingView(rootView: content.environment(\.colorScheme, .dark))
    window.center()
    return window
  }

  private func bringForward(_ window: NSWindow?) {
    guard let window else { return }
    NSApp.activate()
    window.makeKeyAndOrderFront(nil)
  }
}
