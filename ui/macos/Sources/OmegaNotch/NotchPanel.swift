import AppKit
import OmegaNotchKit
import SwiftUI

/// A borderless, transparent panel along one screen edge, above the menu bar
/// and on every Space. It never takes keyboard focus or activates the app.
final class NotchPanel: NSPanel {
  init() {
    super.init(
      contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered,
      defer: false)
    isOpaque = false
    backgroundColor = .clear
    hasShadow = false
    level = .statusBar
    collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
    isMovable = false
    hidesOnDeactivate = false
    acceptsMouseMovedEvents = true
    ignoresMouseEvents = true
  }

  override var canBecomeKey: Bool { false }
  override var canBecomeMain: Bool { false }
}

/// Clicks reach the notch without first making the panel key.
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Places the panel on the chosen screen, and decides from the pointer's
/// position whether the panel takes it or lets it through.
@MainActor
final class NotchPanelController {
  let model: NotchModel
  private let panel = NotchPanel()
  private var monitors: [Any] = []
  private var wheelTravel: CGFloat = 0
  var openSettings: () -> Void = {}
  var openDashboard: () -> Void = {}

  init(model: NotchModel) {
    self.model = model
  }

  /// How long to wait for the engine's config before showing the notch
  /// with the defaults, so a missing engine never leaves it invisible.
  private static let configWait: Duration = .seconds(3)
  private var presented = false

  func show() {
    // Shown only once the engine's config is here: drawn with the defaults
    // first, it would appear in the wrong place and then animate across to
    // the right one.
    if model.client.hasConfig {
      present()
    } else {
      waitForConfig()
      Task { @MainActor [weak self] in
        try? await Task.sleep(for: Self.configWait)
        self?.present()
      }
    }
  }

  private func waitForConfig() {
    withObservationTracking {
      _ = model.client.hasConfig
    } onChange: { [weak self] in
      Task { @MainActor in self?.present() }
    }
  }

  /// Places the panel, then builds the view in it, so its first frame already
  /// has the right geometry and nothing animates into place.
  private func present() {
    guard !presented else { return }
    presented = true
    place()
    let view = NotchView(
      model: model,
      openSettings: { [weak self] in self?.openSettings() },
      openDashboard: { [weak self] in self?.openDashboard() })
    panel.contentView = FirstMouseHostingView(rootView: view)
    panel.orderFrontRegardless()
    model.showOnce()

    // Mouse moves anywhere (no permission needed for these) and inside the
    // panel once it takes the pointer.
    let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged]
    monitors.append(
      NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] _ in
        MainActor.assumeIsolated { self?.trackPointer() }
      } as Any)
    monitors.append(
      NSEvent.addLocalMonitorForEvents(matching: mask.union([.scrollWheel, .rightMouseDown])) {
        [weak self] event in
        // Local monitors run on the main thread.
        nonisolated(unsafe) let event = event
        let swallow = MainActor.assumeIsolated { self?.handleLocal(event) ?? false }
        return swallow ? nil : event
      } as Any)

    NotificationCenter.default.addObserver(
      forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated { self?.place() }
    }
    trackConfig()
    trackPeek()
  }

  /// Follows the chosen screen (the main one while it is unplugged or none
  /// is chosen), edge and size.
  func place() {
    let screens = NSScreen.screens
    let name = model.config.screen
    guard let screen = screens.first(where: { $0.localizedName == name }) ?? NSScreen.main ?? screens.first
    else { return }
    let frame = screen.frame

    // The camera housing: the gap between the two menu bar areas beside it.
    var housing = CGSize.zero
    if model.edge == "top", screen.safeAreaInsets.top > 0,
      let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea
    {
      housing = CGSize(width: right.minX - left.maxX, height: screen.safeAreaInsets.top)
    }
    model.housing = housing

    let s = model.s
    let size: CGSize
    if model.vertical {
      size = CGSize(width: model.depth + model.cardGap + model.cardWidth + 40, height: frame.height)
    } else {
      size = CGSize(width: frame.width, height: model.depth + model.cardGap + 660 * s)
    }
    model.panelSize = size
    let origin: CGPoint =
      switch model.edge {
      case "left": CGPoint(x: frame.minX, y: frame.minY)
      case "right": CGPoint(x: frame.maxX - size.width, y: frame.minY)
      case "bottom": CGPoint(x: frame.minX, y: frame.minY)
      default: CGPoint(x: frame.minX, y: frame.maxY - size.height)
      }
    panel.setFrame(CGRect(origin: origin, size: size), display: true)
  }

  /// The pointer in panel coordinates, top-left origin.
  private func pointer() -> CGPoint {
    let location = NSEvent.mouseLocation
    let frame = panel.frame
    return CGPoint(x: location.x - frame.minX, y: frame.maxY - location.y)
  }

  private func trackPointer() {
    let point = pointer()
    model.pointerMoved(to: point)
    let take = model.interactive(at: point) || model.dragging
    if panel.ignoresMouseEvents == take {
      panel.ignoresMouseEvents = !take
    }
  }

  /// Whether the event was the notch's to handle (and goes no further).
  private func handleLocal(_ event: NSEvent) -> Bool {
    trackPointer()
    guard event.window === panel else { return false }
    let point = pointer()
    let onNotch = model.notchRect.contains(point)
    switch event.type {
    case .rightMouseDown where onNotch:
      openSettings()
      return true
    case .scrollWheel where onNotch:
      // Scroll to look at another provider.
      let delta = event.scrollingDeltaY != 0 ? event.scrollingDeltaY : event.scrollingDeltaX
      wheelTravel += event.hasPreciseScrollingDeltas ? delta : delta * 40
      if abs(wheelTravel) >= 120 {
        model.cycleProvider(wheelTravel < 0 ? 1 : -1)
        wheelTravel = 0
      }
      return true
    default:
      return false
    }
  }

  /// Re-places the panel when the edge, size or screen changes.
  private func trackConfig() {
    withObservationTracking {
      _ = (model.config.edge, model.config.size, model.config.screen, model.shownReadings.count)
    } onChange: { [weak self] in
      Task { @MainActor in
        self?.place()
        self?.trackConfig()
      }
    }
  }

  private func trackPeek() {
    withObservationTracking {
      _ = model.client.peekOpen
    } onChange: { [weak self] in
      Task { @MainActor in
        self?.model.peekChanged()
        self?.trackPeek()
      }
    }
  }
}
