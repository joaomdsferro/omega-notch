import AppKit
import OmegaNotchKit
import SwiftUI

/// One provider in the notch: a gauge of twenty segments that fills with the
/// tightest limit, the provider's mark inside it, and a short readout underneath.
/// With two windows the readout is a chip ("5h 0 · wk 97") so both limits stay
/// obvious. The last two segments are the danger zone. A white arc turns inside
/// while a session works; it becomes a breathing amber ring when one is waiting.
struct RingView: View {
  var reading: UsageReading?
  var sessionKind: SessionKind
  var unread: Int = 0
  var s: CGFloat
  var surface: String
  var hovered: Bool
  var onTap: () -> Void

  @State private var refreshing = false

  private var status: String { reading?.status ?? "offline" }
  private var hasData: Bool { reading?.hasData ?? false }
  private var windows: [UsageWindow] { reading?.windows ?? [] }
  private var dual: Bool { hasData && windows.count >= 2 }
  /// Ring shows the tightest window (the one that will stop you first).
  private var pct: Double { reading?.headlinePct ?? 0 }
  private var sessionPct: Double { dual ? windows[0].usedPct : 0 }
  private var weeklyPct: Double { dual ? windows[1].usedPct : 0 }
  private var ringSize: CGFloat { 44 * s }
  /// The gauge: twenty segments, the last two the danger zone.
  private var segments: Int { 20 }
  private var gaugeWidth: CGFloat { 4.6 * s }
  private var segmentAngle: Double { 360 / Double(segments) }
  private var segmentGap: Double { 3.4 }
  private var radius: CGFloat { (ringSize - gaugeWidth) / 2 }
  /// The colour of the used part, by how much is used.
  private var accent: Color { Theme.usageColor(pct) }
  private var sessionAccent: Color { Theme.usageColor(sessionPct) }
  private var weeklyAccent: Color { Theme.usageColor(weeklyPct) }
  /// Where the used part ends, for the cap that rides on it.
  private var headAngle: Double { (-90 + 360 * min(1, max(0, pct / 100))) * .pi / 180 }

  /// How much of a segment is used, from 0 to 1. The last used segment is cut
  /// short, so a small percentage still reads as small.
  private func covered(_ index: Int) -> Double {
    max(0, min(1, pct / 100 * Double(segments) - Double(index)))
  }

  /// Short tag for a window label: "Current session" → "5h", "Weekly limit" → "wk".
  private func shortTag(_ label: String) -> String {
    let s = label.lowercased()
    if s.range(of: #"week|weekly|7\s*d|7d"#, options: .regularExpression) != nil { return "wk" }
    if s.range(of: #"5\s*h|5h|hour|session|current"#, options: .regularExpression) != nil {
      return "5h"
    }
    if s.range(of: #"day|24\s*h|24h"#, options: .regularExpression) != nil { return "1d" }
    let chunk = s.split { !$0.isLetter && !$0.isNumber }.first.map(String.init) ?? "lim"
    return String(chunk.prefix(3))
  }

  var body: some View {
    VStack(spacing: 5 * s) {
      ZStack {
        gauge

        // Working: a short arc orbiting between the mark and the ring.
        Circle()
          .trim(from: 0, to: 95.0 / 360)
          .stroke(Theme.ink(surface), style: StrokeStyle(lineWidth: 2 * s, lineCap: .round))
          .frame(width: 25 * s, height: 25 * s)
          .spinning(sessionKind == .busy || refreshing)
          .opacity(sessionKind == .busy || refreshing ? 1 : 0)
          .animation(.easeInOut(duration: 0.18), value: sessionKind == .busy || refreshing)

        // Waiting on you: the same orbit, closed and breathing amber.
        if sessionKind == .waitingYou && !refreshing {
          Circle()
            .stroke(Theme.waiting, lineWidth: 2 * s)
            .frame(width: 25 * s, height: 25 * s)
            .breathing(true)
        }

        ProviderGlyph(
          provider: reading?.provider ?? "",
          color: hasData ? Theme.ink(surface) : Theme.inkSecondary(surface)
        )
        .frame(width: 17 * s, height: 17 * s)

        // The cap that rides on the head of the used part: a speck of light
        // on the glass.
        if pct > 0 {
          Circle()
            .fill(Color.white.opacity(0.92))
            .frame(width: 4.2 * s, height: 4.2 * s)
            .offset(
              x: CGFloat(cos(headAngle)) * radius,
              y: CGFloat(sin(headAngle)) * radius
            )
        }
      }
      .frame(width: ringSize, height: ringSize)
      .overlay(alignment: .topTrailing) {
        if unread > 0 {
          Text("\(unread)")
            .font(.notch(9.5 * s, .bold, tabular: true))
            .foregroundStyle(Color.black)
            .padding(.horizontal, 4 * s)
            .frame(minWidth: 15 * s, minHeight: 15 * s)
            .background(Capsule().fill(Theme.unread))
            .overlay(Capsule().strokeBorder(Color(hex: surface), lineWidth: 1.5 * s))
            .offset(x: 3 * s, y: -2 * s)
            .transition(.scale.combined(with: .opacity))
            .accessibilityLabel("\(unread) finished \(unread == 1 ? "chat" : "chats") to read")
        }
      }
      .animation(.easeOut(duration: 0.2), value: unread)
      .scaleEffect(hovered ? 1.06 : 1)
      .animation(.easeOut(duration: 0.14), value: hovered)

      labels
    }
    .frame(width: 56 * s, height: 72 * s, alignment: .top)
    .contentShape(Rectangle())
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(accessibilityName)
    .onTapGesture {
      refreshing = true
      onTap()
      DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { refreshing = false }
    }
    .clickable()
  }

  /// The gauge: twenty segments, the last two the danger zone.
  private var gauge: some View {
    ZStack {
      ForEach(0..<segments, id: \.self) { index in
        let zone = index >= Int(Double(segments) * 0.9)
        // The track: every segment, whole, so the ring stays round.
        segment(index, covering: 1)
          .stroke(
            zone ? Theme.critical.opacity(0.5) : Theme.inkTrack(surface).opacity(0.75),
            style: StrokeStyle(lineWidth: gaugeWidth, lineCap: .butt)
          )
        // The part in use, on top.
        segment(index, covering: covered(index))
          .stroke(accent, style: StrokeStyle(lineWidth: gaugeWidth, lineCap: .butt))
      }
    }
    .frame(width: ringSize, height: ringSize)
    .animation(.easeOut(duration: 0.6), value: pct)
  }

  /// One segment, from twelve o'clock clockwise, cut to a share of its length.
  /// Inset by half the stroke, so the gauge stays inside its frame and runs
  /// along `radius`, where the cap rides.
  private func segment(_ index: Int, covering share: Double) -> some Shape {
    let start = Double(index) * segmentAngle + segmentGap / 2
    return Circle()
      .inset(by: gaugeWidth / 2)
      .trim(from: start / 360, to: (start + share * (segmentAngle - segmentGap)) / 360)
      .rotation(.degrees(-90))
  }

  @ViewBuilder private var labels: some View {
    if dual && hasData {
      // Tagged chip so session vs weekly stay obvious ("5h 0 · wk 97").
      HStack(spacing: 3 * s) {
        Text(shortTag(windows[0].label))
          .foregroundStyle(Theme.inkSecondary(surface))
          .font(.notch(9 * s, .semibold, tabular: true))
        Text("\(Int(sessionPct.rounded()))")
          .foregroundStyle(sessionAccent)
          .font(.notch(10 * s, .bold, tabular: true))
        Text("·")
          .foregroundStyle(Theme.inkSecondary(surface))
          .font(.notch(10 * s, .semibold))
        Text(shortTag(windows[1].label))
          .foregroundStyle(Theme.inkSecondary(surface))
          .font(.notch(9 * s, .semibold, tabular: true))
        Text("\(Int(weeklyPct.rounded()))")
          .foregroundStyle(weeklyAccent)
          .font(.notch(10 * s, .bold, tabular: true))
      }
      .padding(.horizontal, 5 * s)
      .frame(height: 16 * s)
      .background(Capsule().fill(Theme.ink(surface).opacity(0.08)))
      .overlay(Capsule().strokeBorder(Theme.ink(surface).opacity(0.12), lineWidth: 1))
      .lineLimit(1)
      .fixedSize()
    } else {
      Text(singleLabel)
        .font(.notch(13 * s, .semibold, tabular: true))
        .foregroundStyle(singleLabelColor)
        .lineLimit(1)
        .fixedSize()
    }
  }

  private var singleLabel: String {
    if hasData { return "\(Int(pct.rounded()))%" }
    return status == "error" ? "!" : "—"
  }

  private var singleLabelColor: Color {
    if status == "error" { return Theme.critical }
    return hasData ? Theme.ink(surface) : Theme.inkSecondary(surface)
  }

  private var accessibilityName: String {
    let name = reading?.displayName ?? "Provider"
    guard hasData else {
      return status == "error" ? "\(name), error" : "\(name), no data"
    }
    if dual {
      return "\(name), \(shortTag(windows[0].label)) \(Int(sessionPct.rounded())) percent, \(shortTag(windows[1].label)) \(Int(weeklyPct.rounded())) percent"
    }
    return "\(name), \(Int(pct.rounded())) percent used"
  }
}

/// A small round control in the notch's footer.
struct ToolButton: View {
  enum Icon { case settings, grip, dashboard }

  var icon: Icon
  var s: CGFloat
  var surface: String
  /// The pointing hand, or the resize arrows for the grip.
  var cursor: NSCursor = .pointingHand
  var action: () -> Void = {}

  @State private var hovered = false

  var body: some View {
    let onLight = Theme.isLight(surface)
    let fill = (onLight ? Color.black : Color.white).opacity(hovered ? 0x2B / 255 : 0x17 / 255)
    ZStack {
      Circle().fill(fill)
      switch icon {
      case .settings: sliders
      case .grip: dots
      case .dashboard: bars
      }
    }
    .frame(width: 26 * s, height: 26 * s)
    .animation(.easeOut(duration: 0.12), value: hovered)
    .contentShape(Circle())
    .onHover { inside in
      hovered = inside
      if inside { cursor.push() } else { NSCursor.pop() }
    }
    .onTapGesture(perform: action)
  }

  private var ink: Color { hovered ? Theme.ink(surface) : Theme.inkSecondary(surface) }

  /// Settings: three sliders.
  private var sliders: some View {
    VStack(spacing: (10 * s - 3 * 1.5 * s) / 2) {
      ForEach([0.68, 0.28, 0.55], id: \.self) { knob in
        ZStack(alignment: .leading) {
          Capsule().fill(Theme.inkSecondary(surface)).frame(height: 1.5 * s)
          Circle().fill(Theme.ink(surface)).frame(width: 4 * s, height: 4 * s)
            .offset(x: (12 * s - 4 * s) * knob)
        }
        .frame(width: 12 * s, height: 1.5 * s)
      }
    }
    .frame(width: 12 * s, height: 10 * s)
  }

  /// Grip: six dots.
  private var dots: some View {
    Grid(horizontalSpacing: 2.5 * s, verticalSpacing: 2.5 * s) {
      ForEach(0..<3, id: \.self) { _ in
        GridRow {
          Circle().fill(ink).frame(width: 2.5 * s, height: 2.5 * s)
          Circle().fill(ink).frame(width: 2.5 * s, height: 2.5 * s)
        }
      }
    }
  }

  /// Dashboard: three rising bars.
  private var bars: some View {
    HStack(alignment: .bottom, spacing: 2 * s) {
      ForEach([5.0, 9.0, 7.0], id: \.self) { height in
        RoundedRectangle(cornerRadius: 1 * s).fill(ink).frame(width: 3 * s, height: height * s)
      }
    }
  }
}
