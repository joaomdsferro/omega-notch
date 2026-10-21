import Foundation

/// The themes the app can paint with: a name, a label for Settings, and the
/// colours of each one. Mirrors the Plasma shell's Theme.qml, and the engine's
/// config picks the one in use.
public enum ThemeCatalog {
  /// The themes, the first being the default.
  public static let names = ["noir", "classic", "vidro", "clube", "aurora", "terminal"]

  /// The theme a config without one gets.
  public static let defaultName = "noir"

  /// A theme's name for Settings to show.
  public static func label(_ name: String) -> String {
    switch name {
    case "classic": return "Classic"
    case "vidro": return "Vidro"
    case "clube": return "Clube"
    case "aurora": return "Aurora"
    case "terminal": return "Terminal"
    default: return "Noir"
    }
  }

  /// A theme's one-line description, for Settings to show under its name.
  public static func blurb(_ name: String) -> String {
    switch name {
    case "classic": return "The look as it was"
    case "vidro": return "Translucent material"
    case "clube": return "An instrument panel"
    case "aurora": return "A field of light"
    case "terminal": return "Mono, hairlines, one accent"
    default: return "Graphite with one accent"
    }
  }

  /// The three colours Settings previews a theme with: its panel, its raised
  /// surface and its accent.
  public static func swatches(_ name: String) -> [String] {
    switch name {
    case "classic": return ["#0B0B0D", "#16161A", "#3DDC97"]
    case "vidro": return ["#0C0E14", "#161923", "#7AA2FF"]
    case "clube": return ["#0A0A0C", "#131317", "#7FD1AE"]
    case "aurora": return ["#0D0F1A", "#161A28", "#7C8CFF"]
    case "terminal": return ["#000000", "#0D0D0D", "#00E5A0"]
    default: return ["#0C0C10", "#15151B", "#5B8CFF"]
    }
  }

  /// A theme's colours, by token name; an unknown name gives the default's.
  public static func colors(_ name: String) -> [String: ThemeColor] {
    switch name {
    case "classic": return classic
    case "vidro": return vidro
    case "clube": return clube
    case "aurora": return aurora
    case "terminal": return terminal
    default: return noir
    }
  }

  /// A theme's colours, or nil when the name is not one of ours.
  public static func colorsIfKnown(_ name: String) -> [String: ThemeColor]? {
    guard names.contains(name) else { return nil }
    return colors(name)
  }
}

/// One colour of a theme: a hex value and how solid it is.
public struct ThemeColor: Equatable, Sendable {
  public var hex: String
  public var alpha: Double

  public init(_ hex: String, _ alpha: Double = 1) {
    self.hex = hex
    self.alpha = alpha
  }

  /// A colour of white at the given opacity, as a theme token.
  static func white(_ opacity: Double) -> ThemeColor {
    ThemeColor("#FFFFFF", opacity)
  }
}

// MARK: - The themes

extension ThemeCatalog {
  static let noir: [String: ThemeColor] = [
    "notch": ThemeColor("#000000"),
    "card": ThemeColor("#08080A"),
    "cardStroke": .white(0x24 / 255),
    "hairline": .white(0x14 / 255),
    "track": ThemeColor("#3A3A45"),
    "panel": ThemeColor("#0C0C10"),
    "panelRaised": ThemeColor("#15151B"),
    "panelHover": ThemeColor("#1E1E26"),
    "text": ThemeColor("#FFFFFF"),
    "textSecondary": ThemeColor("#A9A9B5"),
    "textTertiary": ThemeColor("#8B8B97"),
    "ample": ThemeColor("#3DDC97"),
    "watch": ThemeColor("#F5C542"),
    "critical": ThemeColor("#FF6A4D"),
    "waiting": ThemeColor("#FFB020"),
    "unread": ThemeColor("#5B8CFF"),
    "busy": ThemeColor("#FFFFFF"),
    "accent": ThemeColor("#5B8CFF"),
    "botEye": ThemeColor("#08080A"),
    "controlFill": .white(0x14 / 255),
    "controlChosen": ThemeColor("#5B8CFF", 0x1F / 255),
    "controlHover": .white(0x12 / 255),
  ]

  /// The look the app had before the themes: the same, with the faintest ink
  /// lifted so it reads on the raised surfaces.
  static let classic: [String: ThemeColor] = [
    "notch": ThemeColor("#000000"),
    "card": ThemeColor("#000000"),
    "cardStroke": .white(0x1F / 255),
    "hairline": .white(0x1A / 255),
    "track": .white(0x2E / 255),
    "panel": ThemeColor("#0B0B0D"),
    "panelRaised": ThemeColor("#16161A"),
    "panelHover": ThemeColor("#1F1F25"),
    "text": ThemeColor("#FFFFFF"),
    "textSecondary": ThemeColor("#9A9AA2"),
    "textTertiary": ThemeColor("#8B8B95"),
    "ample": ThemeColor("#3DDC97"),
    "watch": ThemeColor("#F5C542"),
    "critical": ThemeColor("#FF5A36"),
    "waiting": ThemeColor("#FFB020"),
    "unread": ThemeColor("#3DDC97"),
    "busy": ThemeColor("#FFFFFF"),
    "accent": ThemeColor("#4C8DFF"),
    "botEye": ThemeColor("#0B0B0D"),
    "controlFill": .white(0x14 / 255),
    "controlChosen": .white(0x2E / 255),
    "controlHover": .white(0x12 / 255),
  ]

  static let vidro: [String: ThemeColor] = [
    "notch": ThemeColor("#0A0B0F"),
    "card": ThemeColor("#14161E"),
    "cardStroke": .white(0x38 / 255),
    "hairline": .white(0x24 / 255),
    "track": ThemeColor("#39404F"),
    "panel": ThemeColor("#0C0E14"),
    "panelRaised": ThemeColor("#161923"),
    "panelHover": ThemeColor("#1F232F"),
    "text": ThemeColor("#FFFFFF"),
    "textSecondary": ThemeColor("#ADB3C4"),
    "textTertiary": ThemeColor("#8E95A8"),
    "ample": ThemeColor("#4FE3A4"),
    "watch": ThemeColor("#FFD166"),
    "critical": ThemeColor("#FF7A5C"),
    "waiting": ThemeColor("#FFB84D"),
    "unread": ThemeColor("#7AA2FF"),
    "busy": ThemeColor("#FFFFFF"),
    "accent": ThemeColor("#7AA2FF"),
    "botEye": ThemeColor("#14161E"),
    "controlFill": .white(0x1A / 255),
    "controlChosen": ThemeColor("#7AA2FF", 0x2A / 255),
    "controlHover": .white(0x12 / 255),
  ]

  static let clube: [String: ThemeColor] = [
    "notch": ThemeColor("#000000"),
    "card": ThemeColor("#0D0D10"),
    "cardStroke": .white(0x24 / 255),
    "hairline": .white(0x1A / 255),
    "track": ThemeColor("#383841"),
    "panel": ThemeColor("#0A0A0C"),
    "panelRaised": ThemeColor("#131317"),
    "panelHover": ThemeColor("#1C1C22"),
    "text": ThemeColor("#FFFFFF"),
    "textSecondary": ThemeColor("#A4A4AE"),
    "textTertiary": ThemeColor("#86868F"),
    "ample": ThemeColor("#3DDC97"),
    "watch": ThemeColor("#F5C542"),
    "critical": ThemeColor("#FF6A4D"),
    "waiting": ThemeColor("#FFB020"),
    "unread": ThemeColor("#7FD1AE"),
    "busy": ThemeColor("#FFFFFF"),
    "accent": ThemeColor("#7FD1AE"),
    "botEye": ThemeColor("#0D0D10"),
    "controlFill": .white(0x14 / 255),
    "controlChosen": ThemeColor("#7FD1AE", 0x1F / 255),
    "controlHover": .white(0x12 / 255),
  ]

  static let aurora: [String: ThemeColor] = [
    "notch": ThemeColor("#05060B"),
    "card": ThemeColor("#141827"),
    "cardStroke": .white(0x24 / 255),
    "hairline": .white(0x1A / 255),
    "track": ThemeColor("#3C4256"),
    "panel": ThemeColor("#0D0F1A"),
    "panelRaised": ThemeColor("#161A28"),
    "panelHover": ThemeColor("#202639"),
    "text": ThemeColor("#FFFFFF"),
    "textSecondary": ThemeColor("#ADB3C8"),
    "textTertiary": ThemeColor("#8E95AD"),
    "ample": ThemeColor("#3DDC97"),
    "watch": ThemeColor("#F5C542"),
    "critical": ThemeColor("#FF6A4D"),
    "waiting": ThemeColor("#FFB020"),
    "unread": ThemeColor("#E86BD0"),
    "busy": ThemeColor("#FFFFFF"),
    "accent": ThemeColor("#7C8CFF"),
    "botEye": ThemeColor("#141827"),
    "controlFill": .white(0x14 / 255),
    "controlChosen": ThemeColor("#7C8CFF", 0x1F / 255),
    "controlHover": .white(0x12 / 255),
  ]

  static let terminal: [String: ThemeColor] = [
    "notch": ThemeColor("#000000"),
    "card": ThemeColor("#0A0A0A"),
    "cardStroke": .white(0x2E / 255),
    "hairline": .white(0x1F / 255),
    "track": ThemeColor("#2A2A2A"),
    "panel": ThemeColor("#000000"),
    "panelRaised": ThemeColor("#0D0D0D"),
    "panelHover": ThemeColor("#171717"),
    "text": ThemeColor("#FFFFFF"),
    "textSecondary": ThemeColor("#A0A0A0"),
    "textTertiary": ThemeColor("#7E7E7E"),
    "ample": ThemeColor("#3DDC97"),
    "watch": ThemeColor("#F5C542"),
    "critical": ThemeColor("#FF5A36"),
    "waiting": ThemeColor("#FFB020"),
    "unread": ThemeColor("#00E5A0"),
    "busy": ThemeColor("#FFFFFF"),
    "accent": ThemeColor("#00E5A0"),
    "botEye": ThemeColor("#0A0A0A"),
    "controlFill": .white(0x14 / 255),
    "controlChosen": ThemeColor("#00E5A0", 0x1F / 255),
    "controlHover": .white(0x12 / 255),
  ]
}
