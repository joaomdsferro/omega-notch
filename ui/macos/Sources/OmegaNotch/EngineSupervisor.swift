import Foundation
import OmegaNotchKit

/// Starts the engine bundled with the app and keeps it running: restarted
/// when it exits, stopped when the app quits. An engine that is already
/// answering on the socket (one started by hand, say) is left alone.
@MainActor
final class EngineSupervisor {
  private var process: Process?
  private var stopping = false
  private var delay: TimeInterval = 1

  /// `OMEGA_NOTCH_ENGINE`, then the copy inside the app bundle.
  static var engineURL: URL? {
    if let path = ProcessInfo.processInfo.environment["OMEGA_NOTCH_ENGINE"], !path.isEmpty {
      return URL(fileURLWithPath: path)
    }
    let helper = Bundle.main.bundleURL.appendingPathComponent(
      "Contents/Helpers/omega-notch-engine")
    return FileManager.default.isExecutableFile(atPath: helper.path) ? helper : nil
  }

  /// Where the engine's output goes: ~/Library/Logs/Omega Notch/engine.log.
  static var logURL: URL {
    FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Logs/Omega Notch/engine.log")
  }

  func start() {
    stopping = false
    if let probe = LineSocket(path: EnginePaths.socket) {
      probe.close()
      NSLog("Omega Notch: an engine is already running; not starting another")
      return
    }
    guard let url = Self.engineURL else {
      NSLog("Omega Notch: no engine found; set OMEGA_NOTCH_ENGINE or run the app bundle")
      return
    }
    let process = Process()
    process.executableURL = url
    process.arguments = ["serve"]
    if let log = openLog() {
      process.standardOutput = log
      process.standardError = log
    }
    process.terminationHandler = { [weak self] _ in
      Task { @MainActor in self?.exited() }
    }
    do {
      try process.run()
      self.process = process
    } catch {
      NSLog("Omega Notch: could not start the engine: \(error)")
      scheduleRestart()
    }
  }

  func stop() {
    stopping = true
    process?.terminate()
    process = nil
  }

  private func exited() {
    process = nil
    guard !stopping else { return }
    scheduleRestart()
  }

  /// Waits a little longer after each failure, up to half a minute.
  private func scheduleRestart() {
    let wait = delay
    delay = min(30, delay * 2)
    DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
      guard let self, !self.stopping, self.process == nil else { return }
      self.start()
      // A run that lasts resets the wait.
      DispatchQueue.main.asyncAfter(deadline: .now() + 60) { [weak self] in
        if self?.process?.isRunning == true { self?.delay = 1 }
      }
    }
  }

  private func openLog() -> FileHandle? {
    let url = Self.logURL
    try? FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
    return try? FileHandle(forWritingTo: url)
  }
}
