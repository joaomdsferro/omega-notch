import Foundation

/// The engine's config, read and changed through typed accessors but kept as
/// raw JSON, so `set_config` sends back every field, known or not.
public struct NotchConfig: Equatable, Sendable {
  public private(set) var raw: JSONValue

  public init(raw: JSONValue) {
    self.raw = raw
  }

  public static let providerIds = [
    "cursor", "claude_code", "claude_desktop", "copilot", "grok_bot", "codex",
  ]

  public var edge: String {
    get { raw["edge"]?.string ?? "top" }
    set { raw["edge"] = .string(newValue) }
  }

  public var isVertical: Bool { edge == "left" || edge == "right" }

  public var edgePosition: Double {
    get { min(1, max(0, raw["edge_position"]?.double ?? 0.5)) }
    set { raw["edge_position"] = .number(min(1, max(0, newValue))) }
  }

  public var size: String {
    get { raw["size"]?.string ?? "medium" }
    set { raw["size"] = .string(newValue) }
  }

  public var peekSeconds: Int {
    get { Int(raw["peek_seconds"]?.double ?? 5) }
    set { raw["peek_seconds"] = .number(Double(newValue)) }
  }

  public var autoHide: Bool {
    get { raw["auto_hide"]?.bool ?? true }
    set { raw["auto_hide"] = .bool(newValue) }
  }

  public var maxProviders: Int {
    get { min(5, max(1, Int(raw["max_providers"]?.double ?? 1))) }
    set { raw["max_providers"] = .number(Double(min(5, max(1, newValue)))) }
  }

  public var idleSize: Double {
    get { min(3, max(1, raw["idle_size"]?.double ?? 1)) }
    set { raw["idle_size"] = .number(min(3, max(1, newValue))) }
  }

  public var idleColor: String {
    get { Self.hexOrBlack(raw["idle_color"]?.string) }
    set { if Self.isHexColor(newValue) { raw["idle_color"] = .string(newValue.uppercased()) } }
  }

  /// How the nub moves while a session works, by name (see `NubMotion`); an
  /// unknown name reads as the engine's default.
  public var nubWorking: String {
    get { Self.motionOr(raw["nub_working"]?.string, "shiver") }
    set { if NubMotion.names.contains(newValue) { raw["nub_working"] = .string(newValue) } }
  }

  /// The same, while a session waits for you.
  public var nubWaiting: String {
    get { Self.motionOr(raw["nub_waiting"]?.string, "pulse") }
    set { if NubMotion.names.contains(newValue) { raw["nub_waiting"] = .string(newValue) } }
  }

  public var notchColor: String {
    get { Self.hexOrBlack(raw["notch_color"]?.string) }
    set { if Self.isHexColor(newValue) { raw["notch_color"] = .string(newValue.uppercased()) } }
  }

  /// The screen the notch lives on, by its localized name; empty follows the
  /// main screen.
  public var screen: String {
    get { raw["screen"]?.string ?? "" }
    set { raw["screen"] = .string(newValue) }
  }

  public func providerEnabled(_ id: String) -> Bool {
    raw["providers"]?[id]?.bool ?? true
  }

  public mutating func setProvider(_ id: String, enabled: Bool) {
    var providers = raw["providers"] ?? .object([:])
    providers[id] = .bool(enabled)
    raw["providers"] = providers
  }

  public var alertsEnabled: Bool {
    get { raw["alerts"]?["enabled"]?.bool ?? true }
    set { setAlert("enabled", newValue) }
  }

  public var soundEnabled: Bool {
    get { raw["alerts"]?["sound"]?.bool ?? true }
    set { setAlert("sound", newValue) }
  }

  /// The sound for a session that finished, by name; empty for the default.
  public var soundFinished: String {
    get { raw["alerts"]?["sound_finished"]?.string ?? "" }
    set { setAlertSound("sound_finished", newValue) }
  }

  /// The sound for a session that stopped to ask you something.
  public var soundWaiting: String {
    get { raw["alerts"]?["sound_waiting"]?.string ?? "" }
    set { setAlertSound("sound_waiting", newValue) }
  }

  /// Whether the notch also opens for a few seconds with each alert.
  public var openNotchOnAlert: Bool {
    get { raw["alerts"]?["open_notch"]?.bool ?? true }
    set { setAlert("open_notch", newValue) }
  }

  /// Decide that per alert instead, with the two below.
  public var openNotchSplit: Bool {
    get { raw["alerts"]?["open_notch_split"]?.bool ?? false }
    set { setAlert("open_notch_split", newValue) }
  }

  public var openNotchFinished: Bool {
    get { raw["alerts"]?["open_notch_finished"]?.bool ?? true }
    set { setAlert("open_notch_finished", newValue) }
  }

  public var openNotchWaiting: Bool {
    get { raw["alerts"]?["open_notch_waiting"]?.bool ?? true }
    set { setAlert("open_notch_waiting", newValue) }
  }

  /// Whether an alert of this kind (`finished` or `waiting_you`) opens the
  /// notch.
  public func opensNotch(for kind: String) -> Bool {
    guard openNotchSplit else { return openNotchOnAlert }
    return kind == "finished" ? openNotchFinished : openNotchWaiting
  }

  private mutating func setAlertSound(_ key: String, _ value: String) {
    var alerts = raw["alerts"] ?? .object([:])
    alerts[key] = .string(value)
    raw["alerts"] = alerts
  }

  private mutating func setAlert(_ key: String, _ value: Bool) {
    var alerts = raw["alerts"] ?? .object([:])
    alerts[key] = .bool(value)
    raw["alerts"] = alerts
  }

  public static func isHexColor(_ value: String) -> Bool {
    value.count == 7 && value.hasPrefix("#") && value.dropFirst().allSatisfy(\.isHexDigit)
  }

  private static func motionOr(_ value: String?, _ fallback: String) -> String {
    guard let value, NubMotion.names.contains(value) else { return fallback }
    return value
  }

  private static func hexOrBlack(_ value: String?) -> String {
    guard let value, isHexColor(value) else { return "#000000" }
    return value
  }
}
