import OmegaNotchKit
import SwiftUI

/// The notch body, fused to the screen edge: rounded on the inside, and
/// flaring into the bezel with a concave curl at each end so it reads as part
/// of the screen rather than a bar parked on it. Its length and depth come
/// from the frame it is given, so animating the frame animates the outline.
struct NotchShape: Shape {
  var edge: String
  var curl: CGFloat
  var radius: CGFloat
  /// A ripple along the outer side, in points, travelling as `wavePhase`
  /// turns; it fades out towards the corners so they stay round.
  var wave: CGFloat = 0
  var wavePhase: CGFloat = 0

  func path(in rect: CGRect) -> Path {
    let vertical = edge == "left" || edge == "right"
    let length = (vertical ? rect.height : rect.width) - 2 * curl
    let depth = vertical ? rect.width : rect.height
    guard length > 0, depth > 0 else { return Path() }

    // Written once in edge-local coordinates (u along the edge, v away from
    // it) and mapped onto whichever edge the notch lives on.
    func p(_ u: CGFloat, _ v: CGFloat) -> CGPoint {
      switch edge {
      case "left": CGPoint(x: rect.minX + v, y: rect.minY + u + curl)
      case "right": CGPoint(x: rect.minX + depth - v, y: rect.minY + u + curl)
      case "bottom": CGPoint(x: rect.minX + u + curl, y: rect.minY + depth - v)
      default: CGPoint(x: rect.minX + u + curl, y: rect.minY + v)
      }
    }
    let k: CGFloat = 0.5523
    let L = length
    let D = depth
    let C = min(curl, D / 2)
    let R = min(radius, D - C, L / 2)
    var path = Path()
    path.move(to: p(-C, 0))
    path.addCurve(to: p(0, C), control1: p(-C + k * C, 0), control2: p(0, C - k * C))
    path.addLine(to: p(0, D - R))
    path.addCurve(to: p(R, D), control1: p(0, D - R + k * R), control2: p(R - k * R, D))
    if wave > 0 && L - 2 * R >= 4 {
      let n = 32
      let span = L - 2 * R
      let crests: CGFloat = 1.25
      for i in 1...n {
        let t = CGFloat(i) / CGFloat(n)
        let v = D + wave * sin(.pi * t) * sin(2 * .pi * crests * t - wavePhase)
        path.addLine(to: p(R + span * t, v))
      }
    } else {
      path.addLine(to: p(L - R, D))
    }
    path.addCurve(to: p(L, D - R), control1: p(L - R + k * R, D), control2: p(L, D - R + k * R))
    path.addLine(to: p(L, C))
    path.addCurve(to: p(L + C, 0), control1: p(L, C - k * C), control2: p(L + C - k * C, 0))
    path.closeSubpath()
    return path
  }
}

/// A provider's mark, from its SVG path, scaled to fit.
struct ProviderGlyph: View {
  var provider: String
  var color: Color

  var body: some View {
    MarkShape(provider: provider)
      .fill(color, style: FillStyle(eoFill: ProviderMarks.evenOdd(provider)))
  }

  struct MarkShape: Shape {
    var provider: String

    func path(in rect: CGRect) -> Path {
      let side = min(rect.width, rect.height)
      let scale = side / 24
      let transform = CGAffineTransform(
        translationX: rect.midX - side / 2, y: rect.midY - side / 2
      ).scaledBy(x: scale, y: scale)
      return Path(SVGPath.parse(ProviderMarks.path(provider))).applying(transform)
    }
  }
}

/// One bot's avatar, as Grok Bot draws it: a shape in a colour with two eye
/// slots, all named by the bot's roster row (`blob`, `cloud`… in `orange`,
/// `blue`…). Shapes are our own 24x24 silhouettes; an unknown or missing
/// shape becomes a disc.
struct BotAvatar: View {
  var shape: String
  var colorName: String

  var body: some View {
    GeometryReader { geo in
      let u = min(geo.size.width, geo.size.height) / 24
      let eye = BotAvatar.eyeLine(shape)
      ZStack {
        MarkShape(shape: shape).fill(Theme.botColor(colorName))
        eyeSlot(u: u, rotation: 18)
          .offset(x: (eye.center.x - eye.spread - 12) * u, y: (eye.center.y - 12) * u)
        eyeSlot(u: u, rotation: 18)
          .offset(x: (eye.center.x + eye.spread - 12) * u, y: (eye.center.y - 12) * u)
      }
    }
  }

  /// The eyes: thick slots leaning the same way, as Grok Bot draws them.
  private func eyeSlot(u: CGFloat, rotation: Double) -> some View {
    RoundedRectangle(cornerRadius: 1.7 * u)
      .fill(Theme.botEye)
      .frame(width: 3.4 * u, height: 6.6 * u)
      .rotationEffect(.degrees(rotation))
  }

  /// Where the eyes sit on each silhouette, and how far apart, in the 24x24
  /// design box. The wedge's face is narrow, so its eyes sit lower and
  /// closer, clear of its slopes.
  static func eyeLine(_ shape: String) -> (center: CGPoint, spread: CGFloat) {
    switch shape {
    case "blob": (CGPoint(x: 12.0, y: 10.3), 3.3)
    case "cloud": (CGPoint(x: 12.0, y: 10.6), 3.3)
    case "tablet": (CGPoint(x: 12.0, y: 9.2), 3.3)
    case "wedge": (CGPoint(x: 12.0, y: 14.2), 2.2)
    case "squircle": (CGPoint(x: 12.0, y: 10.1), 3.3)
    case "teardrop": (CGPoint(x: 12.0, y: 11.2), 3.3)
    case "hex": (CGPoint(x: 12.0, y: 10.3), 3.3)
    case "pebble": (CGPoint(x: 12.1, y: 10.0), 3.3)
    case "crystal": (CGPoint(x: 12.0, y: 9.9), 3.3)
    case "shield": (CGPoint(x: 12.0, y: 9.7), 3.3)
    default: (CGPoint(x: 12.0, y: 10.3), 3.3)
    }
  }

  struct MarkShape: Shape {
    var shape: String

    func path(in rect: CGRect) -> Path {
      let side = min(rect.width, rect.height)
      let scale = side / 24
      let transform = CGAffineTransform(
        translationX: rect.midX - side / 2, y: rect.midY - side / 2
      ).scaledBy(x: scale, y: scale)
      return Path(SVGPath.parse(BotAvatar.mark(shape))).applying(transform)
    }
  }

  static func mark(_ shape: String) -> String {
    switch shape {
    case "blob":
      "M12 2.1 C16.9 2.1 21.4 5.6 21.9 10.3 C22.4 14.6 19.4 19 15 20.9 C10.7 22.7 5.4 21.1 3.1 17.2 C0.8 13.3 2.2 8.2 5.6 5.1 C7.3 3.5 9.6 2.1 12 2.1 Z"
    case "cloud":
      "M7.2 17.8 C4.3 17.8 2 15.6 2 13 C2 10.6 3.9 8.7 6.4 8.4 C7.1 5.6 9.4 3.7 12.3 3.7 C15.4 3.7 17.9 5.9 18.3 8.8 C20.6 9 22 10.9 22 13.2 C22 15.7 20 17.8 17.3 17.8 Z"
    case "tablet":
      "M6.2 3 H17.8 C19.6 3 21 4.4 21 6.2 V17.8 C21 19.6 19.6 21 17.8 21 H6.2 C4.4 21 3 19.6 3 17.8 V6.2 C3 4.4 4.4 3 6.2 3 Z"
    case "wedge":
      "M4.3 20.4 C3.4 20.4 2.9 19.4 3.5 18.7 L11 3.6 C11.4 2.8 12.6 2.8 13 3.6 L20.5 18.7 C21.1 19.4 20.6 20.4 19.7 20.4 Z"
    case "squircle":
      "M12 2 C19.5 2 22 4.5 22 12 C22 19.5 19.5 22 12 22 C4.5 22 2 19.5 2 12 C2 4.5 4.5 2 12 2 Z"
    case "teardrop":
      "M12 1.8 C13.8 3.9 20 10.6 20 15.2 C20 19.5 16.4 22.2 12 22.2 C7.6 22.2 4 19.5 4 15.2 C4 10.6 10.2 3.9 12 1.8 Z"
    case "hex":
      "M12 2.3 L20.1 6.9 V17.1 L12 21.7 L3.9 17.1 V6.9 Z"
    case "pebble":
      "M12.2 4.8 C17.4 4.8 21.3 7.9 21.3 12 C21.3 16.1 17.4 19.2 12.2 19.2 C7 19.2 2.7 16.1 2.7 12 C2.7 7.9 6.8 4.8 12.2 4.8 Z"
    case "crystal":
      "M12 2 L20.4 8.8 L12 22 L3.6 8.8 Z"
    case "shield":
      "M12 2.1 L20 5 V11.2 C20 16.3 16.7 20.4 12 22 C7.3 20.4 4 16.3 4 11.2 V5 Z"
    default:
      "M12 3 C17 3 21 7 21 12 C21 17 17 21 12 21 C7 21 3 17 3 12 C3 7 7 3 12 3 Z"
    }
  }
}

/// The small tail on the card's side that faces the notch, pointing at the
/// ring the card belongs to.
struct CardTail: Shape {
  var edge: String
  var offset: CGFloat
  var half: CGFloat
  var length: CGFloat

  func path(in rect: CGRect) -> Path {
    func p(_ a: CGFloat, _ b: CGFloat) -> CGPoint {
      switch edge {
      case "left": CGPoint(x: -b, y: offset + a)
      case "right": CGPoint(x: rect.width + b, y: offset + a)
      case "bottom": CGPoint(x: offset + a, y: rect.height + b)
      default: CGPoint(x: offset + a, y: -b)
      }
    }
    let h = half
    var path = Path()
    path.move(to: p(-h, -1.5))
    path.addQuadCurve(to: p(0, length), control: p(-h * 0.25, 1))
    path.addQuadCurve(to: p(h, -1.5), control: p(h * 0.25, 1))
    path.closeSubpath()
    return path
  }
}
