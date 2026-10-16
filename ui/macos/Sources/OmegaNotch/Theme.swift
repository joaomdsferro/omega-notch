import AppKit
import OmegaNotchKit
import SwiftUI

/// Every colour and size rule, shared by the notch, its card, Settings and
/// the Dashboard; the same values as the Plasma shell's Theme.qml.
enum Theme {
  // Surfaces
  static let notch = Color.black
  static let card = Color.black
  static let cardStroke = Color.white.opacity(0x1F / 255)
  static let hairline = Color.white.opacity(0x1A / 255)
  static let track = Color.white.opacity(0x2E / 255)
  static let panel = Color(hex: "#0B0B0D")
  static let panelRaised = Color(hex: "#16161A")
  static let panelHover = Color(hex: "#1F1F25")

  // Ink
  static let text = Color.white
  static let textSecondary = Color(hex: "#9A9AA2")
  static let textTertiary = Color(hex: "#5F5F68")

  // Meaning
  static let ample = Color(hex: "#3DDC97")
  static let watch = Color(hex: "#F5C542")
  static let critical = Color(hex: "#FF5A36")
  static let waiting = Color(hex: "#FFB020")
  static let busy = Color.white
  /// A finished chat you have not read yet: the green of "Finished".
  static let unread = Color(hex: "#3DDC97")

  /// Dashboard series, brightest first: the biggest share gets the most ink.
  static let shades = ["#F2F2F5", "#B4B4BE", "#808089", "#5C5C66", "#44444D", "#33333B"].map {
    Color(hex: $0)
  }
  static let controlFill = Color.white.opacity(0x14 / 255)
  static let controlChosen = Color.white.opacity(0x2E / 255)
  static let controlHover = Color.white.opacity(0x12 / 255)

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
/// let leak into the views around it (the ring's number would blink).
struct Breathing: ViewModifier {
  var active: Bool

  func body(content: Content) -> some View {
    if active {
      TimelineView(.animation) { timeline in
        let t = timeline.date.timeIntervalSinceReferenceDate
        content.opacity(0.675 + 0.325 * cos(2 * .pi * t / 1.4))
      }
    } else {
      content
    }
  }
}

/// A full turn every `period` seconds while `active`, from the same clock.
struct Spinning: ViewModifier {
  var active: Bool
  var period: Double = 1.1

  func body(content: Content) -> some View {
    TimelineView(.animation(paused: !active)) { timeline in
      let t = timeline.date.timeIntervalSinceReferenceDate
      content.rotationEffect(.degrees(t.truncatingRemainder(dividingBy: period) / period * 360))
    }
  }
}

extension View {
  func breathing(_ active: Bool) -> some View { modifier(Breathing(active: active)) }
  func spinning(_ active: Bool) -> some View { modifier(Spinning(active: active)) }
}
