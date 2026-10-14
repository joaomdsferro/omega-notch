import AppKit
import Sparkle

/// Updates for the downloaded app, through Sparkle: once a day it reads the
/// appcast attached to the latest GitHub release, and asks before installing
/// anything. Each update is checked against the EdDSA key built into the app
/// and must be signed by the same Developer ID.
///
/// Only a release build has a feed (`SUFeedURL`); a local build, or one run
/// with `swift run`, never looks for updates.
@MainActor
@Observable
final class Updater: NSObject, SPUStandardUserDriverDelegate {
  static let shared = Updater()

  /// Whether this build can update itself at all.
  let available: Bool
  /// False while a check is already under way.
  private(set) var canCheck = false

  @ObservationIgnored private var controller: SPUStandardUpdaterController?
  @ObservationIgnored private var observation: NSKeyValueObservation?

  private override init() {
    let info = Bundle.main.infoDictionary ?? [:]
    available = info["SUFeedURL"] != nil && info["SUPublicEDKey"] != nil
    super.init()
  }

  func start() {
    guard available, controller == nil else { return }
    let controller = SPUStandardUpdaterController(
      startingUpdater: true, updaterDelegate: nil, userDriverDelegate: self)
    self.controller = controller
    observation = controller.updater.observe(\.canCheckForUpdates, options: [.initial, .new]) {
      [weak self] updater, _ in
      let can = updater.canCheckForUpdates
      MainActor.assumeIsolated { self?.canCheck = can }
    }
  }

  func checkNow() {
    controller?.checkForUpdates(nil)
  }

  var checksAutomatically: Bool {
    get {
      access(keyPath: \.checksAutomatically)
      return controller?.updater.automaticallyChecksForUpdates ?? false
    }
    set {
      withMutation(keyPath: \.checksAutomatically) {
        controller?.updater.automaticallyChecksForUpdates = newValue
      }
    }
  }

  // MARK: SPUStandardUserDriverDelegate

  // The app has no Dock icon or menu bar, so a window it opens on its own
  // would stay behind whatever is in front. Bring it forward.
  nonisolated func standardUserDriverWillHandleShowingUpdate(
    _ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState
  ) {
    MainActor.assumeIsolated { NSApp.activate() }
  }
}
