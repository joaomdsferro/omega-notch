import Foundation

/// Where the engine listens, as `paths::socket_path()` decides it on macOS.
public enum EnginePaths {
  public static var socket: String {
    if let override = ProcessInfo.processInfo.environment["OMEGA_NOTCH_SOCKET"], !override.isEmpty {
      return override
    }
    return dataDirectory.appendingPathComponent("omega-notch.sock").path
  }

  /// `~/Library/Application Support/omega-notch`, the engine's own folder.
  public static var dataDirectory: URL {
    let support =
      FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(
        "Library/Application Support")
    return support.appendingPathComponent("omega-notch", isDirectory: true)
  }
}
