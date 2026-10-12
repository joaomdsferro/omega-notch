import OmegaNotchKit
import SwiftUI

// The pieces the Dashboard is built from; the same as the Plasma shell's
// Dash* components.

/// A raised panel with a hairline edge and an optional heading row, with
/// room on the right for controls.
struct DashCard<Trailing: View, Content: View>: View {
  var heading: String
  var caption: String = ""
  @ViewBuilder var trailing: Trailing
  @ViewBuilder var content: Content

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      if !heading.isEmpty {
        HStack(alignment: .center) {
          VStack(alignment: .leading, spacing: 2) {
            Text(heading).font(.notch(14, .semibold)).foregroundStyle(Theme.text)
            if !caption.isEmpty {
              Text(caption).font(.notch(12)).foregroundStyle(Theme.textSecondary)
            }
          }
          Spacer(minLength: 12)
          trailing
        }
      }
      content
    }
    .padding(20)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .background(
      RoundedRectangle(cornerRadius: 12).fill(Theme.panelRaised)
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.hairline, lineWidth: 1)))
  }
}

extension DashCard where Trailing == EmptyView {
  init(heading: String, caption: String = "", @ViewBuilder content: () -> Content) {
    self.init(heading: heading, caption: caption, trailing: { EmptyView() }, content: content)
  }
}

/// Compact segmented control: each segment as wide as its label, with an
/// optional provider mark.
struct DashSegmented: View {
  struct Option: Hashable {
    var value: String
    var label: String
    var provider: String = ""
  }

  var options: [Option]
  var value: String
  var pick: (String) -> Void

  var body: some View {
    HStack(spacing: 0) {
      ForEach(options, id: \.self) { option in
        Segment(option: option, chosen: option.value == value) { pick(option.value) }
      }
    }
    .padding(3)
    .frame(height: 32)
    .background(RoundedRectangle(cornerRadius: 9).fill(Theme.controlFill))
    .fixedSize()
  }

  private struct Segment: View {
    var option: Option
    var chosen: Bool
    var action: () -> Void
    @State private var hovered = false

    var body: some View {
      HStack(spacing: 6) {
        if !option.provider.isEmpty {
          ProviderGlyph(provider: option.provider, color: chosen ? Theme.text : Theme.textSecondary)
            .frame(width: 14, height: 14)
        }
        Text(option.label).font(.notch(12, chosen ? .semibold : .medium))
          .foregroundStyle(chosen ? Theme.text : Theme.textSecondary)
      }
      .padding(.horizontal, 12)
      .frame(maxHeight: .infinity)
      .background(
        RoundedRectangle(cornerRadius: 7)
          .fill(chosen ? Theme.controlChosen : hovered ? Theme.controlHover : .clear))
      .animation(.easeOut(duration: 0.12), value: chosen)
      .contentShape(Rectangle())
      .onHover { hovered = $0 }
      .clickable()
      .onTapGesture(perform: action)
      .accessibilityAddTraits(chosen ? [.isButton, .isSelected] : .isButton)
      .accessibilityLabel(option.label)
    }
  }
}

struct TextButton: View {
  var label: String
  var action: () -> Void
  @State private var hovered = false

  var body: some View {
    Text(label).font(.notch(12, .medium)).foregroundStyle(Theme.text)
      .padding(.horizontal, 10)
      .frame(height: 28)
      .background(RoundedRectangle(cornerRadius: 7).fill(hovered ? Theme.controlChosen : Theme.controlFill))
      .onHover { hovered = $0 }
      .clickable()
      .onTapGesture(perform: action)
      .accessibilityAddTraits(.isButton)
  }
}

/// The notch's ring, dashboard-sized: track, coloured sweep, number inside.
struct DashRing: View {
  /// 0...100, or below zero for no data.
  var pct: Double
  var stroke: CGFloat = 6

  var body: some View {
    GeometryReader { geo in
      let side = min(geo.size.width, geo.size.height)
      ZStack {
        Circle().stroke(Theme.track, lineWidth: stroke).padding(stroke / 2)
        Circle()
          .trim(from: 0, to: max(0, min(1, pct / 100)))
          .stroke(Theme.usageColor(pct), style: StrokeStyle(lineWidth: stroke, lineCap: .round))
          .rotationEffect(.degrees(-90))
          .padding(stroke / 2)
          .animation(.easeOut(duration: 0.6), value: pct)
        HStack(alignment: .firstTextBaseline, spacing: 0) {
          Text(pct >= 0 ? "\(Int(pct.rounded()))" : "—")
            .font(.notch((side * 0.3).rounded(), .semibold, tabular: true))
            .foregroundStyle(pct >= 0 ? Theme.text : Theme.textTertiary)
          if pct >= 0 {
            Text("%").font(.notch((side * 0.16).rounded(), .semibold)).foregroundStyle(Theme.textSecondary)
          }
        }
      }
    }
  }
}

/// One tool's limits: a ring for the tightest window, then every window with
/// its bar and reset time. Click refreshes the tool.
struct LimitCard: View {
  var reading: UsageReading
  var session: SessionState?
  var now: Date
  var windowSlots: Int
  var refresh: () -> Void

  @State private var hovered = false

  private var hasData: Bool { reading.hasData }
  /// The window that will stop you first.
  private var tightest: Int {
    reading.windows.indices.max { reading.windows[$0].usedPct < reading.windows[$1].usedPct } ?? 0
  }
  private var headline: Double { hasData ? reading.windows[tightest].usedPct : -1 }

  private var verdict: String {
    switch Format.level(headline) {
    case _ where headline < 0: ""
    case .critical: "Almost out"
    case .watch: "Getting close"
    case .ample: "Plenty left"
    }
  }

  private var badge: (String, Color)? {
    switch (session?.kind, reading.status) {
    case (.waitingYou, _): ("Needs you", Theme.waiting)
    case (.busy, _): ("Working", Theme.text)
    case (_, "stale"): ("Stale", Theme.watch)
    case (_, "needs_auth"): ("Sign in", Theme.watch)
    case (_, "error"): ("Error", Theme.critical)
    default: nil
    }
  }

  /// "Checked just now", "Checked 4m ago", "Checked 3 Oct".
  private var checked: String {
    let ago = Format.ago(reading.fetchedAt, now: now)
    if ago.isEmpty { return "" }
    if ago == "now" { return "Checked just now" }
    return "Checked " + ago + (ago.last.map { "mhd".contains($0) } == true && ago.first?.isNumber == true ? " ago" : "")
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack(spacing: 16) {
        DashRing(pct: headline).frame(width: 64, height: 64)
        VStack(alignment: .leading, spacing: 4) {
          HStack(spacing: 8) {
            ProviderGlyph(provider: reading.provider, color: Theme.text).frame(width: 16, height: 16)
            Text(reading.displayName).font(.notch(14, .semibold)).foregroundStyle(Theme.text).lineLimit(1)
            Spacer(minLength: 8)
            if let (text, color) = badge {
              Text(text).font(.notch(11, .semibold)).foregroundStyle(color)
                .padding(.horizontal, 8).frame(height: 20)
                .background(Capsule().fill(color.opacity(0.12)))
            }
          }
          if hasData {
            Text(
              verdict
                + (reading.windows.count > 1
                  ? " · " + reading.windows[tightest].label.lowercased() : "")
            )
            .font(.notch(12, .medium)).foregroundStyle(Theme.usageColor(headline)).lineLimit(1)
          }
          Text(hasData ? checked : reading.message ?? "No limits reported")
            .font(.notch(12, tabular: true))
            .foregroundStyle(reading.status == "error" ? Theme.critical : Theme.textTertiary)
            .lineLimit(hasData ? 1 : 2)
        }
      }
      if hasData {
        VStack(spacing: 0) {
          Rectangle().fill(Theme.hairline).frame(height: 1)
          ForEach(Array(reading.windows.enumerated()), id: \.offset) { _, window in
            let pct = max(0, min(100, window.usedPct))
            VStack(spacing: 8) {
              HStack(alignment: .firstTextBaseline) {
                Text(window.label.isEmpty ? "Usage" : window.label).font(.notch(12))
                  .foregroundStyle(Theme.textSecondary).lineLimit(1)
                Spacer(minLength: 12)
                Text(Format.resetsIn(window.resetsAt, now: now).replacingOccurrences(of: "Resets ", with: ""))
                  .font(.notch(11, tabular: true)).foregroundStyle(Theme.textTertiary)
                Text("\(Int(pct.rounded()))%").font(.notch(12, .semibold, tabular: true))
                  .foregroundStyle(Theme.text)
              }
              Bar(fraction: pct / 100, color: Theme.usageColor(pct))
            }
            .padding(.top, 10)
            .frame(height: 40, alignment: .top)
          }
        }
      }
    }
    .padding(20)
    .frame(maxWidth: .infinity, minHeight: 20 + 64 + 16 + CGFloat(windowSlots) * 40 + 12, alignment: .topLeading)
    .background(
      RoundedRectangle(cornerRadius: 12).fill(hovered ? Theme.panelHover : Theme.panelRaised)
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.hairline, lineWidth: 1)))
    .animation(.easeOut(duration: 0.12), value: hovered)
    .contentShape(Rectangle())
    .onHover { hovered = $0 }
    .clickable()
    .onTapGesture(perform: refresh)
    .accessibilityElement(children: .combine)
    .accessibilityAddTraits(.isButton)
    .accessibilityHint("Refresh")
  }
}

/// A thin bar on a track.
struct Bar: View {
  var fraction: Double
  var color: Color
  var height: CGFloat = 4
  var minimum: CGFloat = 0

  var body: some View {
    GeometryReader { geo in
      ZStack(alignment: .leading) {
        Capsule().fill(Theme.track)
        Capsule().fill(color)
          .frame(width: max(fraction > 0 ? minimum : 0, geo.size.width * max(0, min(1, fraction))))
          .animation(.easeOut(duration: 0.45), value: fraction)
      }
    }
    .frame(height: height)
  }
}

/// Lays its children out in rows, wrapping when a row is full.
struct FlowLayout: Layout {
  var spacing: CGFloat = 20
  var lineSpacing: CGFloat = 8

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    let width = proposal.width ?? .infinity
    var x: CGFloat = 0
    var y: CGFloat = 0
    var line: CGFloat = 0
    var widest: CGFloat = 0
    for view in subviews {
      let size = view.sizeThatFits(.unspecified)
      if x > 0 && x + size.width > width {
        y += line + lineSpacing
        x = 0
        line = 0
      }
      x += size.width + spacing
      widest = max(widest, x - spacing)
      line = max(line, size.height)
    }
    return CGSize(width: proposal.width ?? widest, height: y + line)
  }

  func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
    var x = bounds.minX
    var y = bounds.minY
    var line: CGFloat = 0
    for view in subviews {
      let size = view.sizeThatFits(.unspecified)
      if x > bounds.minX && x + size.width > bounds.maxX {
        y += line + lineSpacing
        x = bounds.minX
        line = 0
      }
      view.place(at: CGPoint(x: x, y: y), proposal: .unspecified)
      x += size.width + spacing
      line = max(line, size.height)
    }
  }
}

/// Every series of a chart with its total and share of the range.
struct Legend: View {
  var series: [DashboardData.Series]
  var money = false

  var body: some View {
    let sum = series.reduce(0) { $0 + $1.total }
    FlowLayout {
      ForEach(series, id: \.key) { item in
        HStack(spacing: 6) {
          RoundedRectangle(cornerRadius: 2).fill(Theme.shades[item.shade]).frame(width: 8, height: 8)
          Text(item.label).font(.notch(12)).foregroundStyle(Theme.textSecondary)
          Text(
            (money ? Format.usd(item.total) : Format.tokens(item.total))
              + (series.count > 1 && sum > 0 ? "  \(Int((100 * item.total / sum).rounded()))%" : "")
          )
          .font(.notch(12, .semibold, tabular: true)).foregroundStyle(Theme.text)
        }
      }
    }
  }
}

/// A daily value as stacked columns, one segment per series, on a round
/// axis. Every day of the range gets a slot, so gaps read as quiet days.
/// Hover a column for its breakdown.
struct UsageChart: View {
  var stack: DashboardData.Stack
  var today: String
  var money = false
  var emptyText = "No history yet — it fills in as you work."

  @State private var hovered: Int?

  private let axisWidth: CGFloat = 44
  private let xAxisHeight: CGFloat = 24

  private func format(_ v: Double, axis: Bool = false) -> String {
    guard money else { return Format.tokens(v) }
    // The axis rounds to whole dollars; the tooltip keeps the cents.
    if axis && (v == 0 || v >= 10) { return "$\(Int(v.rounded()))" }
    return Format.usd(v)
  }

  private func dayLabel(_ iso: String, long: Bool) -> String {
    let parser = DateFormatter()
    parser.locale = Locale(identifier: "en_US_POSIX")
    parser.dateFormat = "yyyy-MM-dd"
    guard let date = parser.date(from: iso) else { return iso }
    return Format.formatted(date, long ? "EEE, d MMM" : "d MMM")
  }

  var body: some View {
    let days = stack.days
    let peak = days.map(\.total).max() ?? 0
    let axisMax = 4 * Format.niceCeil(peak / 4)
    let empty = peak <= 0

    GeometryReader { geo in
      let plotWidth = geo.size.width - axisWidth
      let plotHeight = geo.size.height - xAxisHeight
      let slot = days.isEmpty ? plotWidth : plotWidth / CGFloat(days.count)
      let gap: CGFloat = slot > 14 ? 4 : slot > 6 ? 2 : 1

      ZStack(alignment: .topLeading) {
        // Gridlines with their values, bottom to top.
        ForEach(0..<5, id: \.self) { i in
          let y = plotHeight * (1 - CGFloat(i) / 4)
          Rectangle()
            .fill(i == 0 ? Theme.cardStroke : Theme.hairline.opacity(0.6))
            .frame(width: plotWidth, height: 1)
            .offset(x: axisWidth, y: y)
          if !empty || i == 0 {
            Text(format(axisMax * Double(i) / 4, axis: true))
              .font(.notch(11, tabular: true)).foregroundStyle(Theme.textTertiary)
              .frame(width: axisWidth - 10, alignment: .trailing)
              .offset(y: y - 7)
          }
        }

        // Columns: the top of the stack first.
        ForEach(Array(days.enumerated()), id: \.offset) { index, day in
          let dimmed = hovered != nil && hovered != index
          ZStack(alignment: .bottom) {
            if hovered == index {
              RoundedRectangle(cornerRadius: 4).fill(Theme.controlHover)
            }
            VStack(spacing: 0) {
              ForEach(stack.series.reversed(), id: \.key) { series in
                let value = day.values[series.key] ?? 0
                if value > 0 && axisMax > 0 {
                  Rectangle().fill(Theme.shades[series.shade])
                    .frame(height: (plotHeight * value / axisMax).rounded())
                }
              }
            }
            .padding(.horizontal, gap / 2)
            .opacity(dimmed ? 0.45 : 1)
            .animation(.easeOut(duration: 0.12), value: dimmed)
          }
          .frame(width: slot, height: plotHeight, alignment: .bottom)
          .offset(x: axisWidth + CGFloat(index) * slot)
        }

        // X axis: first, middle and last day, or every day when there is room.
        ForEach(labelIndices(days.count), id: \.self) { index in
          let day = days[index]
          let isToday = day.date == today
          Text(isToday ? "Today" : dayLabel(day.date, long: false))
            .font(.notch(11, tabular: true))
            .foregroundStyle(isToday ? Theme.text : Theme.textTertiary)
            .fixedSize()
            .frame(width: 80)
            .offset(
              x: max(axisWidth - 30, min(geo.size.width - 60, axisWidth + (CGFloat(index) + 0.5) * slot - 40)),
              y: plotHeight + 6)
        }

        if empty {
          Text(emptyText).font(.notch(13)).foregroundStyle(Theme.textTertiary)
            .frame(width: plotWidth, height: plotHeight)
            .offset(x: axisWidth)
        }

        if let hovered, hovered < days.count {
          tooltip(days[hovered])
            .offset(
              x: {
                let anchor = axisWidth + (CGFloat(hovered) + 0.5) * slot
                return anchor + 14 + 220 > geo.size.width ? anchor - 14 - 220 : anchor + 14
              }(), y: 4)
        }
      }
      .contentShape(Rectangle())
      .onContinuousHover { phase in
        switch phase {
        case .active(let point):
          let i = Int(floor((point.x - axisWidth) / slot))
          hovered = !empty && point.x >= axisWidth && i >= 0 && i < days.count ? i : nil
        case .ended:
          hovered = nil
        }
      }
    }
  }

  private func labelIndices(_ n: Int) -> [Int] {
    guard n > 0 else { return [] }
    if n <= 8 { return Array(0..<n) }
    let step = Int(ceil(Double(n) / 6))
    return Array(stride(from: n - 1, through: 0, by: -step).reversed())
  }

  private func tooltip(_ day: DashboardData.Day) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack {
        Text(dayLabel(day.date, long: true)).font(.notch(11)).foregroundStyle(Theme.textSecondary)
        Spacer()
        Text(format(day.total)).font(.notch(12, .semibold, tabular: true)).foregroundStyle(Theme.text)
      }
      ForEach(stack.series, id: \.key) { series in
        HStack(spacing: 8) {
          RoundedRectangle(cornerRadius: 2).fill(Theme.shades[series.shade]).frame(width: 8, height: 8)
          Text(series.label).font(.notch(11)).foregroundStyle(Theme.textSecondary).lineLimit(1)
          Spacer()
          Text(format(day.values[series.key] ?? 0)).font(.notch(11, tabular: true)).foregroundStyle(Theme.text)
        }
      }
    }
    .padding(12)
    .frame(width: 220)
    .background(
      RoundedRectangle(cornerRadius: 10).fill(Color(hex: "#1C1C21").opacity(0xE6 / 255))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.cardStroke, lineWidth: 1)))
    .allowsHitTesting(false)
  }
}
