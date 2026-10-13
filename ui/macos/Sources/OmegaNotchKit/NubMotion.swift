import Foundation

/// How a nub moves to say what is going on, by name: the names the engine
/// accepts for `nub_working` and `nub_waiting`, timed like the Plasma shell's
/// NubMotion.qml. It only produces numbers, as a function of the time since
/// the motion started, and the nub applies them, so Settings can play the
/// same motion on its previews.
public enum NubMotion {
  public struct Style: Sendable {
    public var value: String
    public var label: String
    public var tip: String
  }

  /// Names, labels and hints, in the order Settings offers them.
  public static let styles: [Style] = [
    Style(value: "none", label: "Still", tip: "Stays still"),
    Style(value: "shiver", label: "Shiver", tip: "A quick shiver along the edge, then a rest"),
    Style(value: "breathe", label: "Breathe", tip: "Fades slowly out and back in"),
    Style(value: "wave", label: "Wave", tip: "A ripple runs along it, over and over"),
    Style(value: "pulse", label: "Pulse", tip: "Two quick beats, like a heart"),
    Style(value: "bounce", label: "Bounce", tip: "Pops out of the edge and bounces back"),
    Style(value: "stretch", label: "Stretch", tip: "Grows along the edge and shrinks back"),
  ]

  public static let names = styles.map(\.value)

  /// Where the nub is in its motion: an offset along the edge (in steps of
  /// `unit`), a stretch of its length and depth, an opacity, and a ripple
  /// along its outer side (its height as a share of the depth, and how far it
  /// has travelled).
  public struct Pose: Equatable, Sendable {
    public var along: Double = 0
    public var lengthScale: Double = 1
    public var depthScale: Double = 1
    public var fade: Double = 1
    public var wave: Double = 0
    public var wavePhase: Double = 0

    public static let rest = Pose()
  }

  /// The pose `seconds` into `style`. An unknown name, or `none`, stays at rest.
  public static func pose(_ style: String, at seconds: Double, unit: Double = 1) -> Pose {
    let t = max(0, seconds)
    if style == "wave" { return wave(at: t) }
    guard let steps = loops[style] else { return .rest }
    var pose = play(steps, at: t)
    pose.along *= unit
    return pose
  }

  // MARK: Timing

  private enum Ease {
    case linear, inQuad, outQuad, inOutQuad, outCubic, inOutSine, outBounce

    func callAsFunction(_ x: Double) -> Double {
      switch self {
      case .linear: return x
      case .inQuad: return x * x
      case .outQuad: return 1 - (1 - x) * (1 - x)
      case .inOutQuad: return x < 0.5 ? 2 * x * x : 1 - pow(-2 * x + 2, 2) / 2
      case .outCubic: return 1 - pow(1 - x, 3)
      case .inOutSine: return -(cos(.pi * x) - 1) / 2
      case .outBounce:
        let n = 7.5625, d = 2.75
        if x < 1 / d { return n * x * x }
        if x < 2 / d { let y = x - 1.5 / d; return n * y * y + 0.75 }
        if x < 2.5 / d { let y = x - 2.25 / d; return n * y * y + 0.9375 }
        let y = x - 2.625 / d
        return n * y * y + 0.984375
      }
    }
  }

  /// One leg of a loop: the values it moves to, over `ms`. No values is a pause.
  private struct Step {
    var ms: Double
    var ease: Ease = .linear
    var to: [WritableKeyPath<Pose, Double>: Double] = [:]
  }

  private static func pause(_ ms: Double) -> Step { Step(ms: ms) }

  private static func size(_ length: Double, _ depth: Double, _ ms: Double, _ ease: Ease) -> Step {
    Step(ms: ms, ease: ease, to: [\.lengthScale: length, \.depthScale: depth])
  }

  /// The looping motions. Each one ends where it starts, at rest.
  private static let loops: [String: [Step]] = [
    "shiver": [
      Step(ms: 45, to: [\.along: 1.6]), Step(ms: 90, to: [\.along: -1.6]),
      Step(ms: 90, to: [\.along: 1.2]), Step(ms: 90, to: [\.along: -1.2]),
      Step(ms: 45, to: [\.along: 0]), pause(1500),
    ],
    "breathe": [
      Step(ms: 1100, ease: .inOutSine, to: [\.fade: 0.25]),
      Step(ms: 1100, ease: .inOutSine, to: [\.fade: 1]), pause(300),
    ],
    "pulse": [
      size(1.3, 1.5, 130, .outQuad), size(1, 1, 170, .inQuad), pause(90),
      size(1.2, 1.35, 120, .outQuad), size(1, 1, 220, .inOutQuad), pause(1000),
    ],
    "bounce": [
      Step(ms: 170, ease: .outQuad, to: [\.depthScale: 2.2]),
      Step(ms: 650, ease: .outBounce, to: [\.depthScale: 1]), pause(1100),
    ],
    "stretch": [
      Step(ms: 750, ease: .inOutSine, to: [\.lengthScale: 1.9]),
      Step(ms: 750, ease: .inOutSine, to: [\.lengthScale: 1]), pause(400),
    ],
  ]

  private static func play(_ steps: [Step], at seconds: Double) -> Pose {
    let total = steps.reduce(0) { $0 + $1.ms }
    var left = (seconds * 1000).truncatingRemainder(dividingBy: total)
    var pose = Pose.rest
    for step in steps {
      if left < step.ms {
        let f = step.ease(left / step.ms)
        for (key, to) in step.to { pose[keyPath: key] += (to - pose[keyPath: key]) * f }
        return pose
      }
      for (key, to) in step.to { pose[keyPath: key] = to }
      left -= step.ms
    }
    return pose
  }

  /// Stretches out to make room, then the ripple runs for as long as it lasts.
  private static func wave(at seconds: Double) -> Pose {
    let grow = Ease.outCubic(min(1, seconds / 0.32))
    let turn = seconds.truncatingRemainder(dividingBy: 0.9) / 0.9
    return Pose(
      lengthScale: 1 + 0.5 * grow, depthScale: 1 + 0.25 * grow, wave: 0.28 * grow,
      wavePhase: 2 * .pi * turn)
  }
}
