import AppKit
import OmegaNotchKit
import ServiceManagement
import SwiftUI

/// Placement, the notch's look, providers, alerts and login: the same tabs as
/// the Plasma shell's Settings window, plus a General tab for what only macOS
/// has (opening chats, starting at login).
struct SettingsView: View {
  var client: EngineClient

  @State private var tab: Tab = .placement
  @State private var screens = NSScreen.screens.map(ScreenInfo.init)
  @State private var openAtLogin = SMAppService.mainApp.status == .enabled
  @State private var loginError = ""
  /// The sound whose list is open, if any: only one at a time.
  @State private var openSound: AlertSound.Kind?
  @State private var windowsAllowed = WindowRaiser.trusted
  @AppStorage(WindowRaiser.pickTabKey) private var pickTab = false

  enum Tab: String, CaseIterable, Identifiable {
    case placement = "Placement"
    case notch = "Notch"
    case providers = "Providers"
    case alerts = "Alerts"
    case general = "General"

    var id: Self { self }

    var icon: String {
      switch self {
      case .placement: "display"
      case .notch: "rectangle.topthird.inset.filled"
      case .providers: "square.grid.2x2"
      case .alerts: "bell"
      case .general: "gearshape"
      }
    }
  }

  private static let providers = [
    ("cursor", "Cursor"), ("claude_code", "Claude Code"), ("claude_desktop", "Claude Desktop"),
    ("copilot", "GitHub Copilot"), ("grok_bot", "Grok Bot"), ("codex", "Codex"),
  ]

  private var config: NotchConfig { client.config }

  var body: some View {
    HStack(spacing: 0) {
      sidebar
      Rectangle().fill(Theme.hairline).frame(width: 1)
      ScrollView {
        VStack(alignment: .leading, spacing: 14) {
          switch tab {
          case .placement: placement
          case .notch: notch
          case .providers: providers
          case .alerts: alerts
          case .general:
            windows
            startup
          }
        }
        .padding(.horizontal, 22)
        .padding(.top, 36)
        .padding(.bottom, 24)
      }
      .id(tab)  // each tab opens at its top
    }
    .frame(minWidth: 620, idealWidth: 680, minHeight: 480)
    .background(Theme.panel)
    .onReceive(
      NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
    ) { _ in screens = NSScreen.screens.map(ScreenInfo.init) }
    // Back from System Settings with the permission granted, or not.
    .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
      windowsAllowed = WindowRaiser.trusted
    }
  }

  private func update(_ change: (inout NotchConfig) -> Void) {
    client.updateConfig(change)
  }

  /// The name and the engine's state, the tabs, and Refresh and Quit at the
  /// foot.
  private var sidebar: some View {
    VStack(alignment: .leading, spacing: 0) {
      VStack(alignment: .leading, spacing: 4) {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
          Text("Omega Notch").font(.notch(16, .semibold)).foregroundStyle(Theme.text)
          Text("v" + (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"))
            .font(.notch(11)).foregroundStyle(Theme.textSecondary)
        }
        HStack(spacing: 6) {
          Circle().fill(client.connected ? Theme.ample : Theme.critical).frame(width: 7, height: 7)
          Text(client.connected ? "Connected" : "Engine offline")
            .font(.notch(11)).foregroundStyle(Theme.textSecondary)
        }
      }
      .padding(.horizontal, 12)
      .padding(.bottom, 24)

      VStack(spacing: 2) {
        ForEach(Tab.allCases) { item in
          TabRow(title: item.rawValue, icon: item.icon, chosen: item == tab) { tab = item }
        }
      }

      Spacer(minLength: 16)
      HStack(spacing: 8) {
        SettingsButton(title: "Refresh", enabled: client.connected) { client.refresh() }
          .help("Fetch every provider's usage now")
        Spacer(minLength: 0)
        SettingsButton(title: "Quit", destructive: true) { NSApp.terminate(nil) }
          .help("Quit Omega Notch")
      }
    }
    .padding(.horizontal, 10)
    .padding(.top, 40)
    .padding(.bottom, 16)
    .frame(width: 190)
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

  /// The screen the notch is on: the chosen one, else the main one.
  private var targetScreen: ScreenInfo? {
    screens.first { $0.name == config.screen } ?? screens.first { $0.main }
  }

  @ViewBuilder private var placement: some View {
    SettingsSection(heading: "Screen") {
      FlowLayout(spacing: 8, lineSpacing: 8) {
        ScreenTile(
          title: "Main screen", icon: "star", detail: "Follows whichever screen has the menu bar",
          chosen: config.screen.isEmpty
        ) { update { $0.screen = "" } }
        ForEach(screens) { screen in
          ScreenTile(
            title: screen.name, icon: screen.builtIn ? "laptopcomputer" : "display",
            detail: screen.subtitle, chosen: screen.name == config.screen
          ) { update { $0.screen = screen.name } }
        }
        if chosenScreenMissing {
          ScreenTile(
            title: config.screen, icon: "powerplug", detail: "Not plugged in. The notch stays on the main screen until it is",
            badge: "Not connected", chosen: true, enabled: false)
        }
      }
      .padding(.top, 4)
    }
    SettingsSection(heading: "On screen") {
      EdgePicker(
        screen: targetScreen, edge: config.edge, position: config.edgePosition, size: config.size,
        notchColor: config.notchColor, pinned: pinnedByHousing,
        place: { edge, position in
          update {
            $0.edge = edge
            $0.edgePosition = position
          }
        }
      )
      .frame(maxWidth: .infinity)
      .padding(.vertical, 8)

      FieldLabel(text: "Size")
      HStack(spacing: 12) {
        Segmented(options: [("small", "Small"), ("medium", "Medium"), ("large", "Large")], value: config.size) {
          size in update { $0.size = size }
        }
        if !pinnedByHousing {
          SettingsButton(title: "Recentre") { update { $0.edgePosition = 0.5 } }
            .help("Put the notch in the middle of its edge")
        }
      }
      Hint(
        text: pinnedByHousing
          ? "On this screen the notch grows out of the camera housing, in the middle of the top edge. Click another edge to move it."
          : "Click near an edge of the little screen to move the notch there, or drag along it; it snaps to the middle. You can also drag the grip beside the rings."
      )
    }
  }

  // MARK: Notch

  @ViewBuilder private var notch: some View {
    SettingsSection(heading: "Behaviour") {
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

      FieldLabel(text: "Providers shown at once")
      Segmented(options: (1...5).map { ("\($0)", "\($0)") }, value: "\(config.maxProviders)") { value in
        update { $0.maxProviders = Int(value) ?? 1 }
      }
      Hint(
        text:
          "Working providers come first, then the most recently used. Scroll on the notch to bring up another."
      )
    }

    SettingsSection(heading: "Colours") {
      FieldLabel(text: "Notch colour")
      SwatchPicker(value: config.notchColor) { color in update { $0.notchColor = color } }

      if config.autoHide && !pinnedByHousing {
        FieldLabel(text: "Nub colour when idle")
        SwatchPicker(value: config.idleColor) { color in update { $0.idleColor = color } }
      }
    }

    // On a camera housing there is no nub to move.
    if !pinnedByHousing {
      let usable = config.autoHide
      SettingsSection(heading: "Nub motion") {
        FieldLabel(text: "While working")
        MotionPicker(value: config.nubWorking, enabled: usable) { value in
          update { $0.nubWorking = value }
        }
        FieldLabel(text: "Needs you")
        MotionPicker(value: config.nubWaiting, enabled: usable) { value in
          update { $0.nubWaiting = value }
        }
        Hint(
          text: usable
            ? "Waiting for your answer takes over from working. Hover a motion for what it does."
            : "Used only while Hide when idle is on.")
      }
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

  @ViewBuilder private var alerts: some View {
    SettingsSection(heading: "Alerts") {
      SettingsSwitch(
        title: "Notify me", subtitle: "When a session finishes or stops to ask you something",
        isOn: config.alertsEnabled
      ) { on in update { $0.alertsEnabled = on } }
      SettingsSwitch(
        title: "Usage limits",
        subtitle: config.alertsEnabled
          ? "When a provider passes 80% and when it reaches 100%"
          : "Notifications are off",
        isOn: config.limitAlerts
      ) { on in update { $0.limitAlerts = on } }
      SettingsSwitch(
        title: "Play a sound", subtitle: config.alertsEnabled ? "" : "Notifications are off",
        isOn: config.soundEnabled
      ) { on in update { $0.soundEnabled = on } }
    }

    if config.soundEnabled {
      SettingsSection(heading: "Sounds") {
        SoundRow(
          title: "When a session finishes", kind: .finished, value: config.soundFinished,
          open: $openSound
        ) { name in update { $0.soundFinished = name } }
        SoundRow(
          title: "When a session needs you", kind: .waiting, value: config.soundWaiting,
          open: $openSound
        ) { name in update { $0.soundWaiting = name } }
      }
    }
  }

  /// Opening a chat: the window it runs in, and optionally its tab.
  private var windows: some View {
    SettingsSection(heading: "Opening chats") {
      HStack(spacing: 12) {
        VStack(alignment: .leading, spacing: 2) {
          Text("Bring the chat's window forward").font(.notch(14)).foregroundStyle(Theme.text)
          Text(
            windowsAllowed
              ? "Allowed in Accessibility"
              : "Needs Accessibility permission; without it, only the app comes forward"
          )
          .font(.notch(12))
          .foregroundStyle(windowsAllowed ? Theme.textSecondary : Theme.watch)
          .fixedSize(horizontal: false, vertical: true)
        }
        Spacer(minLength: 12)
        if !windowsAllowed {
          SettingsButton(title: "Allow…") {
            WindowRaiser.askForAccessibility()
            WindowRaiser.openAccessibilitySettings()
          }
        }
      }
      .frame(minHeight: 44)
      SettingsSwitch(
        title: "Pick the terminal tab",
        subtitle: "Terminal and iTerm2 · macOS asks to let Omega Notch control them the first time",
        isOn: pickTab
      ) { on in pickTab = on }
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
  /// How much of the screen's width the housing takes, for drawing it.
  var housingShare: CGFloat
  /// A laptop's own display, drawn on its base rather than on a stand.
  var builtIn: Bool
  /// Its size in points, for the proportions of the little screen.
  var size: CGSize
  var id: String { name }

  @MainActor
  init(_ screen: NSScreen) {
    name = screen.localizedName
    let size = screen.frame.size
    let scale = screen.backingScaleFactor
    main = screen == NSScreen.screens.first
    housing = screen.safeAreaInsets.top > 0
    if housing, let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea, size.width > 0 {
      housingShare = (right.minX - left.maxX) / size.width
    } else {
      housingShare = 0.12
    }
    self.size = size
    let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
    builtIn = number.map { CGDisplayIsBuiltin($0.uint32Value) != 0 } ?? false
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
