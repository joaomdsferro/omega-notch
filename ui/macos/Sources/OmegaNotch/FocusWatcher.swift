import AppKit
import ApplicationServices
import OmegaNotchKit

/// Tells the engine which window is in front while a finished chat waits to
/// be read, so looking at it marks it read. Only while you are at the Mac:
/// a reply that lands in a window left in front while you were away stays
/// unread until you come back to it.
@MainActor
final class FocusWatcher {
  private let client: EngineClient
  private var timer: Timer?
  private var observer: NSObjectProtocol?
  private var lastSent: (pid: Int32, title: String?, unread: [String])?

  /// Input more recent than this means someone is looking at the screen.
  private static let presence: TimeInterval = 10

  init(client: EngineClient) {
    self.client = client
  }

  func start() {
    timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated { self?.check() }
    }
    observer = NSWorkspace.shared.notificationCenter.addObserver(
      forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated { self?.check() }
    }
  }

  private func check() {
    let unread = client.unreadChats.filter(\.live).map(\.id)
    guard !unread.isEmpty, Self.idleSeconds < Self.presence,
      let app = NSWorkspace.shared.frontmostApplication,
      app.processIdentifier != ProcessInfo.processInfo.processIdentifier
    else { return }
    let pid = app.processIdentifier
    let title = Self.focusedWindowTitle(of: pid)
    // Only news is sent: the same window over the same unread chats was
    // already looked at.
    if let last = lastSent, last.pid == pid, last.title == title, last.unread == unread { return }
    lastSent = (pid, title, unread)
    if title == nil && !WindowRaiser.trusted {
      NSLog("Omega Notch: no Accessibility, so the window's title is unknown")
    }
    client.windowFocused(pid: pid, title: title)
  }

  /// Seconds since the last key press, click or pointer move.
  private static var idleSeconds: TimeInterval {
    CGEventSource.secondsSinceLastEventType(
      .combinedSessionState, eventType: CGEventType(rawValue: ~0) ?? .null)
  }

  /// The title of the app's focused window, with Accessibility; nil without,
  /// and the engine then settles for an app running a single session.
  private static func focusedWindowTitle(of pid: pid_t) -> String? {
    guard WindowRaiser.trusted else { return nil }
    let app = AXUIElementCreateApplication(pid)
    var window: CFTypeRef?
    guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &window) == .success,
      let window, CFGetTypeID(window) == AXUIElementGetTypeID()
    else { return nil }
    var title: CFTypeRef?
    AXUIElementCopyAttributeValue(window as! AXUIElement, kAXTitleAttribute as CFString, &title)
    return title as? String
  }
}
