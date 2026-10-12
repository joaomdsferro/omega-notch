import CoreGraphics
import Foundation

/// Turns SVG path data (`d`) into a CGPath. Covers every command: M L H V C S
/// Q T A Z, absolute and relative. Enough for the provider marks, which are
/// kept as path data so they stay crisp at every size.
public enum SVGPath {
  public static func parse(_ d: String) -> CGPath {
    var parser = Parser(d)
    return parser.run()
  }

  private struct Parser {
    let chars: [Character]
    var i = 0
    let path = CGMutablePath()
    var current = CGPoint.zero
    var start = CGPoint.zero
    var lastControl: CGPoint?
    var lastCommand: Character = " "

    init(_ d: String) { chars = Array(d) }

    mutating func run() -> CGPath {
      var command: Character = " "
      while true {
        skipSeparators()
        guard i < chars.count else { break }
        if chars[i].isLetter {
          command = chars[i]
          i += 1
        } else if command == "M" {
          command = "L"  // extra pairs after a moveto are linetos
        } else if command == "m" {
          command = "l"
        }
        guard apply(command) else { break }
      }
      return path
    }

    mutating func apply(_ c: Character) -> Bool {
      let relative = c.isLowercase
      let base = relative ? current : .zero
      switch c.uppercased() {
      case "M":
        guard let p = point(base) else { return false }
        path.move(to: p)
        current = p
        start = p
        lastControl = nil
      case "L":
        guard let p = point(base) else { return false }
        line(p)
      case "H":
        guard let x = number() else { return false }
        line(CGPoint(x: x + (relative ? current.x : 0), y: current.y))
      case "V":
        guard let y = number() else { return false }
        line(CGPoint(x: current.x, y: y + (relative ? current.y : 0)))
      case "C":
        guard let c1 = point(base), let c2 = point(base), let p = point(base) else { return false }
        path.addCurve(to: p, control1: c1, control2: c2)
        lastControl = c2
        current = p
      case "S":
        guard let c2 = point(base), let p = point(base) else { return false }
        let c1 = reflected(after: "CcSs")
        path.addCurve(to: p, control1: c1, control2: c2)
        lastControl = c2
        current = p
      case "Q":
        guard let c1 = point(base), let p = point(base) else { return false }
        path.addQuadCurve(to: p, control: c1)
        lastControl = c1
        current = p
      case "T":
        guard let p = point(base) else { return false }
        let c1 = reflected(after: "QqTt")
        path.addQuadCurve(to: p, control: c1)
        lastControl = c1
        current = p
      case "A":
        guard let rx = number(), let ry = number(), let rotation = number(),
          let large = flag(), let sweep = flag(), let p = point(base)
        else { return false }
        arc(to: p, rx: rx, ry: ry, rotation: rotation, large: large, sweep: sweep)
        lastControl = nil
        current = p
      case "Z":
        path.closeSubpath()
        current = start
        lastControl = nil
      default:
        return false
      }
      lastCommand = c
      return true
    }

    mutating func line(_ p: CGPoint) {
      path.addLine(to: p)
      current = p
      lastControl = nil
    }

    func reflected(after commands: String) -> CGPoint {
      guard commands.contains(lastCommand), let control = lastControl else { return current }
      return CGPoint(x: 2 * current.x - control.x, y: 2 * current.y - control.y)
    }

    /// Endpoint arc to a series of cubic curves (SVG 1.1, appendix F.6).
    mutating func arc(to end: CGPoint, rx: Double, ry: Double, rotation: Double, large: Bool, sweep: Bool) {
      var rx = abs(rx)
      var ry = abs(ry)
      if rx == 0 || ry == 0 || current == end {
        path.addLine(to: end)
        return
      }
      let phi = rotation * .pi / 180
      let (cosPhi, sinPhi) = (cos(phi), sin(phi))
      let dx = (current.x - end.x) / 2
      let dy = (current.y - end.y) / 2
      let x1 = cosPhi * dx + sinPhi * dy
      let y1 = -sinPhi * dx + cosPhi * dy
      let lambda = (x1 * x1) / (rx * rx) + (y1 * y1) / (ry * ry)
      if lambda > 1 {
        rx *= lambda.squareRoot()
        ry *= lambda.squareRoot()
      }
      let num = rx * rx * ry * ry - rx * rx * y1 * y1 - ry * ry * x1 * x1
      let den = rx * rx * y1 * y1 + ry * ry * x1 * x1
      var factor = (max(0, num) / den).squareRoot()
      if large == sweep { factor = -factor }
      let cx1 = factor * rx * y1 / ry
      let cy1 = -factor * ry * x1 / rx
      let cx = cosPhi * cx1 - sinPhi * cy1 + (current.x + end.x) / 2
      let cy = sinPhi * cx1 + cosPhi * cy1 + (current.y + end.y) / 2

      func angle(_ ux: Double, _ uy: Double, _ vx: Double, _ vy: Double) -> Double {
        atan2(ux * vy - uy * vx, ux * vx + uy * vy)
      }
      let theta1 = angle(1, 0, (x1 - cx1) / rx, (y1 - cy1) / ry)
      var delta = angle((x1 - cx1) / rx, (y1 - cy1) / ry, (-x1 - cx1) / rx, (-y1 - cy1) / ry)
      if !sweep && delta > 0 { delta -= 2 * .pi }
      if sweep && delta < 0 { delta += 2 * .pi }

      let segments = max(1, Int(ceil(abs(delta) / (.pi / 2))))
      let step = delta / Double(segments)
      let k = 4.0 / 3.0 * tan(step / 4)
      func onEllipse(_ t: Double) -> (CGPoint, CGPoint) {
        let (cosT, sinT) = (cos(t), sin(t))
        let p = CGPoint(
          x: cx + rx * cosT * cosPhi - ry * sinT * sinPhi,
          y: cy + rx * cosT * sinPhi + ry * sinT * cosPhi)
        let derivative = CGPoint(
          x: -rx * sinT * cosPhi - ry * cosT * sinPhi,
          y: -rx * sinT * sinPhi + ry * cosT * cosPhi)
        return (p, derivative)
      }
      var t = theta1
      for n in 0..<segments {
        let (p1, d1) = onEllipse(t)
        let (p2, d2) = onEllipse(t + step)
        let target = n == segments - 1 ? end : p2
        path.addCurve(
          to: target,
          control1: CGPoint(x: p1.x + k * d1.x, y: p1.y + k * d1.y),
          control2: CGPoint(x: p2.x - k * d2.x, y: p2.y - k * d2.y))
        t += step
      }
    }

    mutating func point(_ base: CGPoint) -> CGPoint? {
      guard let x = number(), let y = number() else { return nil }
      return CGPoint(x: x + base.x, y: y + base.y)
    }

    mutating func skipSeparators() {
      while i < chars.count, chars[i] == " " || chars[i] == "," || chars[i].isNewline || chars[i] == "\t" {
        i += 1
      }
    }

    /// Arc flags are single digits and may be written without separators.
    mutating func flag() -> Bool? {
      skipSeparators()
      guard i < chars.count, chars[i] == "0" || chars[i] == "1" else { return nil }
      defer { i += 1 }
      return chars[i] == "1"
    }

    /// A number, which may run straight into the next one: "-.5.5" is -0.5
    /// then 0.5, "1-2" is 1 then -2.
    mutating func number() -> Double? {
      skipSeparators()
      var text = ""
      var seenDot = false
      var seenExponent = false
      if i < chars.count, chars[i] == "-" || chars[i] == "+" {
        text.append(chars[i])
        i += 1
      }
      while i < chars.count {
        let c = chars[i]
        if c.isNumber {
          text.append(c)
        } else if c == "." && !seenDot && !seenExponent {
          seenDot = true
          text.append(c)
        } else if (c == "e" || c == "E") && !seenExponent && !text.isEmpty {
          seenExponent = true
          text.append(c)
          if i + 1 < chars.count, chars[i + 1] == "-" || chars[i + 1] == "+" {
            i += 1
            text.append(chars[i])
          }
        } else {
          break
        }
        i += 1
      }
      return Double(text)
    }
  }
}
