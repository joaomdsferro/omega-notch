import AppKit
import OmegaNotchKit
import ServiceManagement
import SwiftUI

/// Placement, the notch's look, providers, alerts and login: the same choices
/// as the Plasma shell's Settings window, plus starting at login.
struct SettingsView: View {
  var client: EngineClient

  @State private var screens = NSScreen.screens.map(ScreenInfo.init)
  @State private var openAtLogin = SMAppService.mainApp.status == .enabled
  @State private var loginError = ""

  private static let providers = [
    ("cursor", "Cursor"), ("claude_code", "Claude Code"), ("claude_desktop", "Claude Desktop"),
    ("copilot", "GitHub Copilot"), ("grok_bot", "Grok Bot"), ("codex", "Codex"),
  ]

  private var config: NotchConfig { client.config }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 14) {
        header
        placement
        notch
        providers
        alerts
        startup
        HStack {
          SettingsButton(title: "Refresh all now", enabled: client.connected) { client.refresh() }
          Spacer()
          SettingsButton(title: "Quit Omega Notch", destructive: true) { NSApp.terminate(nil) }
        }
      }
      .padding(.horizontal, 20)
      .padding(.top, 36)
      .padding(.bottom, 24)
    }
    .frame(minWidth: 400, idealWidth: 440, minHeight: 360)
    .background(Theme.panel)
    .onReceive(
      NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
    ) { _ in screens = NSScreen.screens.map(ScreenInfo.init) }
  }

  private func update(_ change: (inout NotchConfig) -> Void) {
    client.updateConfig(change)
  }

  private var header: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        Text("Omega Notch").font(.notch(22, .semibold)).foregroundStyle(Theme.text)
        Text("v" + (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"))
          .font(.notch(12)).foregroundStyle(Theme.textSecondary)
      }
      HStack(spacing: 7) {
        Circle().fill(client.connected ? Theme.ample : Theme.critical).frame(width: 7, height: 7)
        Text(client.connected ? "Engine connected" : "Engine offline — waiting for it to start")
          .font(.notch(12)).foregroundStyle(Theme.textSecondary)
      }
    }
    .padding(.bottom, 4)
  }

  // MARK: Placement

  private var chosenScreenMissing: Bool {
    !config.screen.isEmpty && !screens.contains { $0.name == config.screen }
  }

  /// The camera housing pins the notch to the middle of the top edge.
  private var pinnedByHousing: Bool {
    guard config.edge == "top" else { return false }
    let screen = screens.first { $0.name == config.screen } ?? screens.first { $0.main }
    return screen?.housing ?? false
  }

  private var placement: some View {
    SettingsSection(heading: "Placement") {
      FieldLabel(text: "Screen")
      ScreenRow(
        title: "Main screen", subtitle: "Follows whichever screen has the menu bar",
        chosen: config.screen.isEmpty
      ) { update { $0.screen = "" } }
      ForEach(screens) { screen in
        ScreenRow(title: screen.name, subtitle: screen.subtitle, chosen: screen.name == config.screen) {
          update { $0.screen = screen.name }
        }
      }
      if chosenScreenMissing {
        ScreenRow(
          title: config.screen, subtitle: "Not connected — on the main screen until it is",
          chosen: true, enabled: false)
      }

      FieldLabel(text: "Screen edge")
      Segmented(
        options: [("left", "Left"), ("right", "Right"), ("top", "Top"), ("bottom", "Bottom")],
        value: config.edge
      ) { edge in update { $0.edge = edge } }

      FieldLabel(text: "Size")
      Segmented(options: [("small", "Small"), ("medium", "Medium"), ("large", "Large")], value: config.size) {
        size in update { $0.size = size }
      }

      if pinnedByHousing {
        Hint(text: "On this screen the notch grows out of the camera housing, in the middle of the top edge.")
      } else {
        FieldLabel(text: "Position along the edge")
        HStack(spacing: 12) {
          SettingsSlider(value: config.edgePosition, range: 0...1) { value in
            update { $0.edgePosition = value }
          }
          SettingsButton(title: "Recentre") { update { $0.edgePosition = 0.5 } }
        }
        Hint(text: "Or drag the grip that appears beside the rings.")
      }
    }
  }

  // MARK: Notch

  private var notch: some View {
    SettingsSection(heading: "Notch") {
      SettingsSwitch(
        title: "Hide when idle",
        subtitle: config.autoHide
          ? "Tucked away until a session finishes or the pointer touches its edge"
          : "Always on screen",
        isOn: config.autoHide
      ) { on in update { $0.autoHide = on } }

      if config.autoHide && !pinnedByHousing {
        FieldLabel(text: "Size when idle")
        HStack(spacing: 12) {
          SettingsSlider(value: config.idleSize, range: 1...3, step: 0.25) { value in
            update { $0.idleSize = value }
          }
          SettingsButton(title: "Reset") { update { $0.idleSize = 1 } }
        }
      }

      FieldLabel(text: "Notch colour")
      SwatchPicker(value: config.notchColor) { color in update { $0.notchColor = color } }

      if config.autoHide && !pinnedByHousing {
        FieldLabel(text: "Nub colour when idle")
        SwatchPicker(value: config.idleColor) { color in update { $0.idleColor = color } }
      }

      FieldLabel(text: "Providers shown at once")
      Segmented(options: (1...5).map { ("\($0)", "\($0)") }, value: "\(config.maxProviders)") { value in
        update { $0.maxProviders = Int(value) ?? 1 }
      }
      Hint(
        text:
          "Working providers come first, then the most recently used. Scroll on the notch to bring up another."
      )
    }
  }

  // MARK: Providers

  private func summary(_ provider: String, enabled: Bool) -> String {
    guard enabled else { return "Off" }
    guard let reading = client.readings.first(where: { $0.provider == provider }) else {
      return client.connected ? "Waiting for the first reading…" : "Engine offline"
    }
    if reading.status == "needs_auth" || reading.status == "error" {
      return reading.message ?? "Unavailable"
    }
    guard let window = reading.windows.first else { return "No limits reported" }
    return "\(Int(window.usedPct.rounded()))% of \(window.label.isEmpty ? "usage" : window.label.lowercased())"
      + (reading.status == "stale" ? " · stale" : "")
  }

  private var providers: some View {
    SettingsSection(heading: "Providers") {
      ForEach(Self.providers, id: \.0) { id, name in
        let enabled = config.providerEnabled(id)
        SettingsSwitch(
          title: name, subtitle: summary(id, enabled: enabled), provider: id,
          subtitleIsError: enabled && client.readings.first { $0.provider == id }?.status == "error",
          isOn: enabled
        ) { on in update { $0.setProvider(id, enabled: on) } }
      }
      CopilotSignIn(client: client)
    }
  }

  // MARK: Alerts and startup

  private var alerts: some View {
    SettingsSection(heading: "Alerts") {
      SettingsSwitch(
        title: "Notify me", subtitle: "When a session finishes or stops to ask you something",
        isOn: config.alertsEnabled
      ) { on in update { $0.alertsEnabled = on } }
      SettingsSwitch(
        title: "Play a sound", subtitle: config.alertsEnabled ? "" : "Notifications are off",
        isOn: config.soundEnabled
      ) { on in update { $0.soundEnabled = on } }
    }
  }

  private var startup: some View {
    SettingsSection(heading: "Startup") {
      SettingsSwitch(
        title: "Open at login",
        subtitle: loginError.isEmpty ? "Starts with your Mac, in the background" : loginError,
        subtitleIsError: !loginError.isEmpty,
        isOn: openAtLogin
      ) { on in setOpenAtLogin(on) }
    }
  }

  private func setOpenAtLogin(_ on: Bool) {
    do {
      if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
      loginError = ""
    } catch {
      loginError = "Could not change it: \(error.localizedDescription)"
    }
    openAtLogin = SMAppService.mainApp.status == .enabled
  }
}

/// A screen as Settings lists it.
struct ScreenInfo: Identifiable {
  var name: String
  var subtitle: String
  var main: Bool
  var housing: Bool
  var id: String { name }

  @MainActor
  init(_ screen: NSScreen) {
    name = screen.localizedName
    let size = screen.frame.size
    let scale = screen.backingScaleFactor
    main = screen == NSScreen.screens.first
    housing = screen.safeAreaInsets.top > 0
    var parts = ["\(Int(size.width * scale))×\(Int(size.height * scale))"]
    if main { parts.append("main") }
    if housing { parts.append("camera housing") }
    subtitle = parts.joined(separator: " · ")
  }
}

/// One click to sign in to GitHub Copilot: the engine asks GitHub for a code,
/// which lands on the clipboard while the GitHub page opens, so signing in is
/// a paste and a confirm. Shown only while Copilot has no working sign-in.
struct CopilotSignIn: View {
  var client: EngineClient

  private var state: String { client.copilotLogin?.state ?? "" }
  private var needsAuth: Bool {
    client.readings.first { $0.provider == "copilot" }?.status == "needs_auth"
  }

  var body: some View {
    if client.config.providerEnabled("copilot")
      && (needsAuth || ["starting", "pending", "failed"].contains(state))
    {
      VStack(alignment: .leading, spacing: 8) {
        if state == "failed" {
          Text(client.copilotLogin?.message ?? "Sign-in failed")
            .font(.notch(12)).foregroundStyle(Theme.critical)
        }
        if state == "pending", let login = client.copilotLogin {
          VStack(alignment: .leading, spacing: 10) {
            Text("Paste this code on the GitHub page that just opened — it is already copied.")
              .font(.notch(12)).foregroundStyle(Theme.textSecondary)
            Text(login.userCode ?? "")
              .font(.system(size: 22, weight: .semibold, design: .monospaced))
              .kerning(2)
              .foregroundStyle(Theme.text)
              .textSelection(.enabled)
            HStack(spacing: 8) {
              SettingsButton(title: "Open GitHub") { Windows.openVerification(login) }
              SettingsButton(title: "Copy code") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(login.userCode ?? "", forType: .string)
              }
            }
          }
          .padding(12)
          .frame(maxWidth: .infinity, alignment: .leading)
          .background(RoundedRectangle(cornerRadius: 10).fill(Theme.panelHover))
        } else {
          SettingsButton(
            title: state == "starting" ? "Asking GitHub for a code…" : "Sign in to GitHub Copilot",
            enabled: client.connected && state != "starting"
          ) { client.copilotSignIn() }
        }
      }
      .padding(.top, 2)
      .padding(.bottom, 6)
    }
  }
}
