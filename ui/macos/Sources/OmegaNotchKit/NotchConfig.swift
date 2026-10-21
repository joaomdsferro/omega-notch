import Foundation

/// The engine's config, read and changed through typed accessors but kept as
/// raw JSON, so `set_config` sends back every field, known or not.
public struct NotchConfig: Equatable, Sendable {
  public private(set) var raw: JSONValue

  public init(raw: JSONValue) {
    self.raw = raw
  }

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

  /// Providers the user starred; the notch prefers them over idle ones.
  public var favorites: [String] {
    get { stringList("favorites") }
    set { raw["favorites"] = .array(Self.cleanProviderList(newValue).map { .string($0) }) }
  }

  /// Layout order for notch rings; unnamed providers follow in registry order.
  public var notchOrder: [String] {
    get { stringList("notch_order") }
    set { raw["notch_order"] = .array(Self.cleanProviderList(newValue).map { .string($0) }) }
  }

  public func isFavorite(_ id: String) -> Bool { favorites.contains(id) }

  public mutating func setFavorite(_ id: String, favorite: Bool) {
    guard Self.isProviderId(id) else { return }
    var list = favorites
    if favorite {
      if !list.contains(id) { list.append(id) }
    } else {
      list.removeAll { $0 == id }
    }
    favorites = list
  }

  /// Move an enabled provider earlier (`by` < 0) or later in the notch.
  public mutating func moveInNotch(_ id: String, by: Int, among enabled: [String]) {
    guard by != 0, enabled.contains(id) else { return }
    var order = enabled.sorted { a, b in
      let ai = notchOrder.firstIndex(of: a) ?? Int.max
      let bi = notchOrder.firstIndex(of: b) ?? Int.max
      if ai != bi { return ai < bi }
      return enabled.firstIndex(of: a)! < enabled.firstIndex(of: b)!
    }
    guard let from = order.firstIndex(of: id) else { return }
    let to = min(max(0, from + by), order.count - 1)
    guard to != from else { return }
    order.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
    notchOrder = order
  }

  private func stringList(_ key: String) -> [String] {
    guard case .array(let list)? = raw[key] else { return [] }
    return Self.cleanProviderList(list.compactMap(\.string))
  }

  private static let providerListMax = 64
  private static let providerIdMax = 48

  private static func isProviderId(_ id: String) -> Bool {
    !id.isEmpty && id.count <= providerIdMax
      && id.unicodeScalars.allSatisfy {
        CharacterSet.alphanumerics.contains($0) || $0 == "_" || $0 == "-"
      }
  }

  private static func cleanProviderList(_ list: [String]) -> [String] {
    var seen = Set<String>()
    var out: [String] = []
    for id in list where isProviderId(id) && seen.insert(id).inserted {
      out.append(id)
      if out.count == providerListMax { break }
    }
    return out
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

  /// The dashboard's palette, by name (see `DashboardPalette`).
  public var dashboardPalette: String {
    get {
      let name = raw["dashboard_palette"]?.string ?? ""
      return DashboardPalette.names.contains(name) ? name : "mono"
    }
    set { if DashboardPalette.names.contains(newValue) { raw["dashboard_palette"] = .string(newValue) } }
  }

  /// Colours set over the palette's, first series first; an empty one keeps
  /// the palette's.
  public var dashboardColors: [String] {
    guard case .array(let list)? = raw["dashboard_colors"] else { return [] }
    return list.prefix(DashboardPalette.series).map { value in
      guard let hex = value.string, Self.isHexColor(hex) else { return "" }
      return hex.uppercased()
    }
  }

  /// Gives one series its own colour, or (with nil) the palette's back.
  public mutating func setDashboardColor(_ index: Int, _ color: String?) {
    guard (0..<DashboardPalette.series).contains(index) else { return }
    if let color, !Self.isHexColor(color) { return }
    var list = dashboardColors
    while list.count <= index { list.append("") }
    list[index] = color?.uppercased() ?? ""
    while list.last == "" { list.removeLast() }
    raw["dashboard_colors"] = .array(list.map { .string($0) })
  }

  /// The theme the app paints with, by name (see `ThemeCatalog`).
  public var theme: String {
    get {
      let name = raw["theme"]?.string ?? ""
      return ThemeCatalog.names.contains(name) ? name : ThemeCatalog.defaultName
    }
    set { if ThemeCatalog.names.contains(newValue) { raw["theme"] = .string(newValue) } }
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

  /// Whether each alert is also a system notification. Off by default: the
  /// notch and the sound are the alert.
  public var systemNotifications: Bool {
    get { raw["alerts"]?["system_notifications"]?.bool ?? false }
    set { setAlert("system_notifications", newValue) }
  }

  /// Whether the notch opens for a few seconds with each alert.
  public var openNotchOnAlert: Bool {
    get { raw["alerts"]?["open_notch"]?.bool ?? true }
    set { setAlert("open_notch", newValue) }
  }

  /// Decide that per alert instead, with the three below.
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

  public var openNotchLimits: Bool {
    get { raw["alerts"]?["open_notch_limits"]?.bool ?? true }
    set { setAlert("open_notch_limits", newValue) }
  }

  /// Whether an alert of this kind (`finished`, `waiting_you`, `limit` or
  /// `limit_reached`) opens the notch.
  public func opensNotch(for kind: String) -> Bool {
    guard openNotchSplit else { return openNotchOnAlert }
    switch kind {
    case "finished": return openNotchFinished
    case "limit", "limit_reached": return openNotchLimits
    default: return openNotchWaiting
    }
  }

  /// Whether to announce a provider's usage passing 80% and reaching 100%.
  public var limitAlerts: Bool {
    get { raw["alerts"]?["limits"]?.bool ?? true }
    set { setAlert("limits", newValue) }
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
