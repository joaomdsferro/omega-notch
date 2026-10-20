import AppKit
import Observation
import OmegaNotchKit
import SwiftUI

/// The colours of one theme. The same values as the Plasma shell's Theme.qml;
/// the catalogue in `ThemeCatalog` holds them.
struct ThemeTokens {
  /// The same tokens as hex values, to measure contrast with.
  var hex: [String: String]
  var notch: Color
  var card: Color
  var cardStroke: Color
  var hairline: Color
  var track: Color
  var panel: Color
  var panelRaised: Color
  var panelHover: Color
  var text: Color
  var textSecondary: Color
  var textTertiary: Color
  var ample: Color
  var watch: Color
  var critical: Color
  var waiting: Color
  var unread: Color
  var busy: Color
  var accent: Color
  var botEye: Color
  var controlFill: Color
  var controlChosen: Color
  var controlHover: Color

  /// A theme of the catalogue; an unknown name gives the default's.
  init(name: String) {
    let colors = ThemeCatalog.colors(name)
    hex = colors
    func color(_ token: String) -> Color {
      guard let value = colors[token] else { return .clear }
      return Color(hex: value.hex).opacity(value.alpha)
    }
    notch = color("notch")
    card = color("card")
    cardStroke = color("cardStroke")
    hairline = color("hairline")
    track = color("track")
    panel = color("panel")
    panelRaised = color("panelRaised")
    panelHover = color("panelHover")
    text = color("text")
    textSecondary = color("textSecondary")
    textTertiary = color("textTertiary")
    ample = color("ample")
    watch = color("watch")
    critical = color("critical")
    waiting = color("waiting")
    unread = color("unread")
    busy = color("busy")
    accent = color("accent")
    botEye = color("botEye")
    controlFill = color("controlFill")
    controlChosen = color("controlChosen")
    controlHover = color("controlHover")
  }
}

/// The theme in use. The views read the colours through `Theme`, but this is
/// what they watch: putting another theme in place redraws every one of them.
@Observable
final class ThemeStore {
  nonisolated(unsafe) static let shared = ThemeStore()

  /// The tokens of the theme in use.
  private(set) var tokens: ThemeTokens
  /// The theme's name.
  private(set) var name: String

  init() {
    name = ThemeCatalog.defaultName
    tokens = ThemeTokens(name: ThemeCatalog.defaultName)
  }

  /// Puts a theme in place. An unknown name is ignored, and the theme in use
  /// is not applied twice.
  @MainActor
  func apply(_ name: String) {
    guard ThemeCatalog.names.contains(name), name != self.name else { return }
    self.name = name
    tokens = ThemeTokens(name: name)
  }
}

/// Every colour and size rule, shared by the notch, its card, Settings and
/// the Dashboard; the same values as the Plasma shell's Theme.qml.
enum Theme {
  /// The tokens of the theme in use.
  static var tokens: ThemeTokens { ThemeStore.shared.tokens }

  // Surfaces
  static var notch: Color { tokens.notch }
  static var card: Color { tokens.card }
  static var cardStroke: Color { tokens.cardStroke }
  static var hairline: Color { tokens.hairline }
  static var track: Color { tokens.track }
  static var panel: Color { tokens.panel }
  static var panelRaised: Color { tokens.panelRaised }
  static var panelHover: Color { tokens.panelHover }

  // Ink
  static var text: Color { tokens.text }
  static var textSecondary: Color { tokens.textSecondary }
  static var textTertiary: Color { tokens.textTertiary }

  // Meaning
  static var ample: Color { tokens.ample }
  static var watch: Color { tokens.watch }
  static var critical: Color { tokens.critical }
  static var waiting: Color { tokens.waiting }
  static var busy: Color { tokens.busy }
  /// The one accent, for what is chosen or interactive.
  static var accent: Color { tokens.accent }
  /// A bot avatar's eye slots, as good as the card behind them.
  static var botEye: Color { tokens.botEye }
  /// A finished chat you have not read yet.
  static var unread: Color { tokens.unread }

  /// Dashboard series in the default palette; the dashboard draws with
  /// `\.seriesShades`, the palette chosen in Settings.
  static let shades = DashboardPalette.colors("mono").map { Color(hex: $0) }
  static var controlFill: Color { tokens.controlFill }
  static var controlChosen: Color { tokens.controlChosen }
  static var controlHover: Color { tokens.controlHover }

  /// Medium is the size everything was drawn at; presets scale the lot.
  static func scale(for preset: String) -> CGFloat {
    preset == "small" ? 0.86 : preset == "large" ? 1.18 : 1.0
  }

  static func usageColor(_ pct: Double) -> Color {
    switch Format.level(pct) {
    case .critical: critical
    case .watch: watch
    case .ample: ample
    }
  }

  static func stateColor(_ kind: SessionKind) -> Color {
    switch kind {
    case .waitingYou: waiting
    case .busy: busy
    case .idle: textTertiary
    }
  }

  /// A bot avatar's ink, by the colour name Grok Bot's roster uses. Chosen
  /// to sit legibly on the black cards; black and gray stay distinguishable.
  static func botColor(_ name: String) -> Color {
    switch name {
    case "orange": Color(hex: "#E8914B")
    case "yellow": Color(hex: "#DFC04C")
    case "green": Color(hex: "#55C57D")
    case "cyan": Color(hex: "#46C2D6")
    case "blue": Color(hex: "#5C90E8")
    case "violet": Color(hex: "#9C82EA")
    case "magenta": Color(hex: "#D96CBB")
    case "red": Color(hex: "#DE655C")
    case "brown": Color(hex: "#B18257")
    case "black": Color(hex: "#62666E")
    case "gray": Color(hex: "#8A8F98")
    default: textTertiary
    }
  }

  // The notch can be painted, so what sits on it flips to black once the
  // surface is light enough.
  static func isLight(_ hex: String) -> Bool {
    let (r, g, b) = rgb(hex)
    return 0.299 * r + 0.587 * g + 0.114 * b > 0.6
  }
  static func ink(_ surface: String) -> Color { isLight(surface) ? .black : text }
  static func inkSecondary(_ surface: String) -> Color {
    isLight(surface) ? Color.black.opacity(0x99 / 255) : textSecondary
  }
  static func inkTrack(_ surface: String) -> Color {
    isLight(surface) ? Color.black.opacity(0x2E / 255) : track
  }

  /// The WCAG contrast between two colours, from 1 to 21.
  static func contrast(_ a: String, _ b: String) -> Double {
    func luminance(_ hex: String) -> Double {
      let (r, g, b) = rgb(hex)
      func f(_ v: Double) -> Double {
        v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
      }
      return 0.2126 * f(r) + 0.7152 * f(g) + 0.0722 * f(b)
    }
    let first = luminance(a)
    let second = luminance(b)
    return (max(first, second) + 0.05) / (min(first, second) + 0.05)
  }

  /// The ink of a surface: black or white, whichever reads better on it.
  static func readableInk(_ surface: String) -> Color {
    contrast("#000000", surface) >= contrast("#FFFFFF", surface) ? .black : .white
  }

  /// The colour of a mark on a surface of any colour: the unread colour
  /// when it reads there, the ink otherwise. A blue dot on a blue nub is
  /// invisible, and the nub's colour is the user's to choose.
  static func markColor(_ surface: String) -> Color {
    let unreadHex = tokens.hex["unread"] ?? "#FFFFFF"
    return contrast(unreadHex, surface) >= 3 ? unread : readableInk(surface)
  }

  static func rgb(_ hex: String) -> (Double, Double, Double) {
    let value = UInt32(hex.dropFirst(), radix: 16) ?? 0
    return (
      Double((value >> 16) & 0xFF) / 255, Double((value >> 8) & 0xFF) / 255,
      Double(value & 0xFF) / 255
    )
  }
}

extension Color {
  init(hex: String) {
    let (r, g, b) = Theme.rgb(hex)
    self.init(.sRGB, red: r, green: g, blue: b)
  }
}

extension Font {
  /// The system font at a pixel size, with tabular figures where numbers line
  /// up in columns.
  static func notch(_ size: CGFloat, _ weight: Font.Weight = .regular, tabular: Bool = false) -> Font {
    let font = Font.system(size: size, weight: weight)
    return tabular ? font.monospacedDigit() : font
  }
}

extension View {
  /// The pointing hand over anything clickable, and the not-allowed cursor
  /// over anything disabled (the repository's rule for every control).
  func clickable(enabled: Bool = true) -> some View {
    onHover { inside in
      if inside {
        (enabled ? NSCursor.pointingHand : NSCursor.operationNotAllowed).push()
      } else {
        NSCursor.pop()
      }
    }
  }
}

/// Breathing between 35% and full opacity, 1.4 s a cycle, while `active`.
/// Driven by a clock rather than a repeating animation, which SwiftUI would
/// let leak into the views around it (the ring's number would blink). With
/// reduced motion on, the state is simply shown still.
struct Breathing: ViewModifier {
  var active: Bool
  /// How long a breath takes, in seconds.
  var period: Double = 1.4
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  func body(content: Content) -> some View {
    if active && !reduceMotion {
      TimelineView(.animation) { timeline in
        let t = timeline.date.timeIntervalSinceReferenceDate
        content.opacity(0.675 + 0.325 * cos(2 * .pi * t / period))
      }
    } else {
      content
    }
  }
}

/// A full turn every `period` seconds while `active`, from the same clock.
/// With reduced motion on, it holds still.
struct Spinning: ViewModifier {
  var active: Bool
  var period: Double = 1.1
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  func body(content: Content) -> some View {
    TimelineView(.animation(paused: !active || reduceMotion)) { timeline in
      let t = timeline.date.timeIntervalSinceReferenceDate
      content.rotationEffect(.degrees(t.truncatingRemainder(dividingBy: period) / period * 360))
    }
  }
}

extension View {
  func breathing(_ active: Bool, period: Double = 1.4) -> some View {
    modifier(Breathing(active: active, period: period))
  }
  func spinning(_ active: Bool) -> some View { modifier(Spinning(active: active)) }
}

extension EnvironmentValues {
  /// The dashboard's series colours, first series first.
  @Entry var seriesShades: [Color] = Theme.shades
}
