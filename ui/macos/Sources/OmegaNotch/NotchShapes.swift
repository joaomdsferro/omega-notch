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
