import AppKit
import ApplicationServices
import OmegaNotchKit

/// Brings a live chat's window forward, as the engine asks with
/// `raise_window`: first its app, then (with Accessibility) the window whose
/// title fits the chat best, then (if switched on, with Automation) the
/// Terminal or iTerm2 tab running it.
@MainActor
enum WindowRaiser {
  /// Whether to pick the terminal tab too; off until switched on in Settings,
  /// since it asks for one more permission.
  static let pickTabKey = "pickTerminalTab"
  static var pickTab: Bool { UserDefaults.standard.bool(forKey: pickTabKey) }

  /// Whether Accessibility is allowed. Never prompts.
  static var trusted: Bool { AXIsProcessTrusted() }

  /// Shows the system prompt for Accessibility, which points at Settings.
  static func askForAccessibility() {
    let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
    _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
  }

  static func openAccessibilitySettings() {
    if let url = URL(
      string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    {
      NSWorkspace.shared.open(url)
    }
  }

  static func raise(_ request: RaiseRequest) {
    // The first of the session's processes that is an app owns the window:
    // the terminal, or VS Code for its built-in terminal.
    guard
      let app = request.pids.lazy.compactMap({ NSRunningApplication(processIdentifier: $0) })
        .first(where: { $0.activationPolicy == .regular })
    else { return }

    if pickTab, let tty = request.safeTty, let bundle = app.bundleIdentifier,
      selectTab(tty: tty, in: bundle)
    {
      return
    }

    // Asked for once, the first time a chat needs it.
    if !trusted {
      if !UserDefaults.standard.bool(forKey: "askedForAccessibility") {
        UserDefaults.standard.set(true, forKey: "askedForAccessibility")
        askForAccessibility()
      }
      return
    }
    raiseWindow(of: app.processIdentifier, hints: request.hints.map { $0.lowercased() })
  }

  /// Raises the window of `pid` whose title matches the earliest hint; among
  /// equals, the frontmost.
  private static func raiseWindow(of pid: pid_t, hints: [String]) {
    let element = AXUIElementCreateApplication(pid)
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, kAXWindowsAttribute as CFString, &value) == .success,
      let windows = value as? [AXUIElement], !windows.isEmpty
    else { return }

    func title(_ window: AXUIElement) -> String {
      var title: CFTypeRef?
      AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &title)
      return (title as? String ?? "").lowercased()
    }
    func score(_ caption: String) -> Int {
      let parts = caption.components(separatedBy: " - ").map { $0.trimmingCharacters(in: .whitespaces) }
      var best = 0
      for (i, hint) in hints.enumerated() where !hint.isEmpty {
        let weight = (hints.count - i) * 2
        if parts.contains(hint) {
          best = max(best, weight + 1)
        } else if caption.contains(hint) {
          best = max(best, weight)
        }
      }
      return best
    }
    // AX lists windows front to back, so the first best one wins ties.
    var target = windows[0]
    var top = -1
    for window in windows {
      let s = score(title(window))
      if s > top {
        top = s
        target = window
      }
    }
    AXUIElementSetAttributeValue(target, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
    AXUIElementPerformAction(target, kAXRaiseAction as CFString)
    AXUIElementSetAttributeValue(target, kAXMainAttribute as CFString, kCFBooleanTrue)
  }

  /// Selects the tab whose terminal is `tty` in Terminal or iTerm2 and brings
  /// its window forward. `tty` has been checked to be a bare device path.
  private static func selectTab(tty: String, in bundle: String) -> Bool {
    let source: String
    switch bundle {
    case "com.apple.Terminal":
      source = """
        tell application id "com.apple.Terminal"
          repeat with w in windows
            repeat with t in tabs of w
              if tty of t is "\(tty)" then
                set selected tab of w to t
                set index of w to 1
                activate
                return true
              end if
            end repeat
          end repeat
        end tell
        return false
        """
    case "com.googlecode.iterm2":
      source = """
        tell application id "com.googlecode.iterm2"
          repeat with w in windows
            repeat with t in tabs of w
              repeat with s in sessions of t
                if tty of s is "\(tty)" then
                  tell t to select
                  tell s to select
                  tell w to select
                  activate
                  return true
                end if
              end repeat
            end repeat
          end repeat
        end tell
        return false
        """
    default:
      return false
    }
    var error: NSDictionary?
    let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
    if let error { NSLog("Omega Notch: could not pick the tab: \(error)") }
    return result?.booleanValue ?? false
  }
}
