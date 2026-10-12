import OmegaNotchKit
import SwiftUI

// The controls Settings is built from, in the notch's own look rather than
// the system's: the same as the Plasma shell's Settings* components.

/// A rounded panel with a small heading.
struct SettingsSection<Content: View>: View {
  var heading: String
  @ViewBuilder var content: Content

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(heading.uppercased())
        .font(.notch(11, .semibold))
        .kerning(0.6)
        .foregroundStyle(Theme.textSecondary)
        .padding(.bottom, 2)
      content
    }
    .padding(16)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(RoundedRectangle(cornerRadius: 14).fill(Theme.panelRaised))
  }
}

struct FieldLabel: View {
  var text: String

  var body: some View {
    Text(text)
      .font(.notch(12))
      .foregroundStyle(Theme.textSecondary)
      .padding(.top, 4)
  }
}

struct Hint: View {
  var text: String

  var body: some View {
    Text(text)
      .font(.notch(12))
      .foregroundStyle(Theme.textTertiary)
      .fixedSize(horizontal: false, vertical: true)
  }
}

/// A labelled on/off row. The whole row is the target, not just the knob.
struct SettingsSwitch: View {
  var title: String
  var subtitle: String = ""
  var provider: String = ""
  var subtitleIsError = false
  var isOn: Bool
  var toggle: (Bool) -> Void

  @State private var hovered = false

  var body: some View {
    HStack(spacing: 12) {
      if !provider.isEmpty {
        ProviderGlyph(provider: provider, color: isOn ? Theme.text : Theme.textSecondary)
          .frame(width: 18, height: 18)
      }
      VStack(alignment: .leading, spacing: 2) {
        Text(title).font(.notch(14)).foregroundStyle(Theme.text).lineLimit(1)
        if !subtitle.isEmpty {
          Text(subtitle)
            .font(.notch(12))
            .foregroundStyle(subtitleIsError ? Theme.critical : Theme.textSecondary)
            .lineLimit(1)
        }
      }
      Spacer(minLength: 12)
      ZStack(alignment: isOn ? .trailing : .leading) {
        Capsule().fill(isOn ? Theme.ample : Color.white.opacity(0x33 / 255))
        Circle().fill(isOn ? Color.black : Color.white).frame(width: 18, height: 18).padding(2)
      }
      .frame(width: 38, height: 22)
      .animation(.easeOut(duration: 0.14), value: isOn)
    }
    .frame(minHeight: 44)
    .padding(.horizontal, 8)
    .background(RoundedRectangle(cornerRadius: 8).fill(hovered ? Theme.panelHover : .clear))
    .padding(.horizontal, -8)
    .contentShape(Rectangle())
    .onHover { hovered = $0 }
    .clickable()
    .onTapGesture { toggle(!isOn) }
    .accessibilityElement(children: .combine)
    .accessibilityAddTraits(.isButton)
    .accessibilityValue(isOn ? "On" : "Off")
  }
}

/// Pick one of a few: a row of segments with the chosen one raised.
struct Segmented: View {
  var options: [(value: String, label: String)]
  var value: String
  var pick: (String) -> Void

  var body: some View {
    HStack(spacing: 0) {
      ForEach(options, id: \.value) { option in
        Segment(label: option.label, chosen: option.value == value) { pick(option.value) }
      }
    }
    .padding(3)
    .frame(height: 32)
    .background(RoundedRectangle(cornerRadius: 9).fill(Theme.controlFill))
  }

  private struct Segment: View {
    var label: String
    var chosen: Bool
    var action: () -> Void
    @State private var hovered = false

    var body: some View {
      Text(label)
        .font(.notch(13, chosen ? .semibold : .regular))
        .foregroundStyle(chosen ? Theme.text : Theme.textSecondary)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
          RoundedRectangle(cornerRadius: 7)
            .fill(chosen ? Theme.controlChosen : hovered ? Theme.controlHover : .clear)
        )
        .animation(.easeOut(duration: 0.12), value: chosen)
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .clickable()
        .onTapGesture(perform: action)
        .accessibilityAddTraits(chosen ? [.isButton, .isSelected] : .isButton)
    }
  }
}

struct SettingsButton: View {
  var title: String
  var destructive = false
  var enabled = true
  var action: () -> Void

  @State private var hovered = false

  var body: some View {
    Text(title)
      .font(.notch(13, .medium))
      .foregroundStyle(destructive ? Theme.critical : Theme.text)
      .padding(.horizontal, 14)
      .frame(height: 34)
      .background(
        RoundedRectangle(cornerRadius: 9)
          .fill(Color.white.opacity(!enabled ? 0x0D / 255 : hovered ? 0x2B / 255 : 0x1A / 255))
      )
      .opacity(enabled ? 1 : 0.5)
      .contentShape(Rectangle())
      .onHover { hovered = $0 }
      .clickable(enabled: enabled)
      .onTapGesture { if enabled { action() } }
      .accessibilityAddTraits(.isButton)
  }
}

/// A slider in the notch's style. Reports while dragging and once more when
/// let go, since saving makes the engine refetch every provider.
struct SettingsSlider: View {
  var value: Double
  var range: ClosedRange<Double>
  var step: Double = 0
  var commit: (Double) -> Void

  @State private var dragValue: Double?

  var body: some View {
    GeometryReader { geo in
      let shown = dragValue ?? value
      let fraction = (shown - range.lowerBound) / (range.upperBound - range.lowerBound)
      let x = CGFloat(fraction) * (geo.size.width - 16)
      ZStack(alignment: .leading) {
        Capsule().fill(Theme.track).frame(height: 4)
        Capsule().fill(Theme.text).frame(width: x + 8, height: 4)
        Circle().fill(Theme.text).frame(width: 16, height: 16)
          .scaleEffect(dragValue == nil ? 1 : 1.15)
          .offset(x: x)
      }
      .frame(maxHeight: .infinity)
      .contentShape(Rectangle())
      .clickable()
      .gesture(
        DragGesture(minimumDistance: 0)
          .onChanged { drag in dragValue = valueAt(drag.location.x, width: geo.size.width) }
          .onEnded { drag in
            commit(valueAt(drag.location.x, width: geo.size.width))
            dragValue = nil
          })
    }
    .frame(height: 34)
  }

  private func valueAt(_ x: CGFloat, width: CGFloat) -> Double {
    let fraction = max(0, min(1, Double((x - 8) / max(1, width - 16))))
    var value = range.lowerBound + fraction * (range.upperBound - range.lowerBound)
    if step > 0 { value = (value / step).rounded() * step }
    return min(range.upperBound, max(range.lowerBound, value))
  }
}

/// Swatches plus a hex field for any other colour.
struct SwatchPicker: View {
  static let swatches = ["#000000", "#FFFFFF", "#3DDC97", "#F5C542", "#FF5A36", "#4C8DFF", "#B07CFF"]

  var value: String
  var pick: (String) -> Void

  @State private var text = ""
  @FocusState private var editing: Bool

  var body: some View {
    HStack(spacing: 8) {
      ForEach(Self.swatches, id: \.self) { swatch in
        Swatch(color: swatch, chosen: swatch == value) { pick(swatch) }
      }
      Spacer()
      TextField("#000000", text: $text)
        .textFieldStyle(.plain)
        .font(.system(size: 13, design: .monospaced))
        .foregroundStyle(Theme.text)
        .focused($editing)
        .padding(.horizontal, 10)
        .frame(width: 92, height: 32)
        .background(
          RoundedRectangle(cornerRadius: 9)
            .fill(Theme.controlFill)
            .strokeBorder(
              editing ? Theme.text : NotchConfig.isHexColor(text) ? .clear : Theme.critical,
              lineWidth: 1)
        )
        .onChange(of: text) { _, new in
          if new.count > 7 { text = String(new.prefix(7)) }
          if NotchConfig.isHexColor(new) && new.uppercased() != value { pick(new.uppercased()) }
        }
        .onSubmit { text = value }
        .onChange(of: editing) { _, now in if !now { text = value } }
    }
    .frame(height: 34)
    .onAppear { text = value }
    .onChange(of: value) { _, new in if !editing { text = new } }
  }

  private struct Swatch: View {
    var color: String
    var chosen: Bool
    var action: () -> Void
    @State private var hovered = false

    var body: some View {
      Circle()
        .fill(Color(hex: color))
        .overlay(Circle().strokeBorder(chosen ? Theme.text : Theme.cardStroke, lineWidth: chosen ? 2 : 1))
        .frame(width: 24, height: 24)
        .scaleEffect(hovered ? 1.12 : 1)
        .animation(.easeOut(duration: 0.1), value: hovered)
        .onHover { hovered = $0 }
        .clickable()
        .onTapGesture(perform: action)
        .accessibilityLabel(color)
        .accessibilityAddTraits(chosen ? [.isButton, .isSelected] : .isButton)
    }
  }
}

/// One screen per row; the chosen one carries a tick.
struct ScreenRow: View {
  var title: String
  var subtitle: String
  var chosen: Bool
  var enabled = true
  var action: () -> Void = {}

  @State private var hovered = false

  var body: some View {
    HStack {
      VStack(alignment: .leading, spacing: 2) {
        Text(title).font(.notch(14, chosen ? .semibold : .regular)).foregroundStyle(Theme.text)
          .lineLimit(1)
        if !subtitle.isEmpty {
          Text(subtitle).font(.notch(12)).foregroundStyle(Theme.textSecondary).lineLimit(1)
        }
      }
      Spacer(minLength: 12)
      Text("✓").font(.notch(15)).foregroundStyle(Theme.text).opacity(chosen ? 1 : 0)
    }
    .frame(minHeight: 40)
    .padding(.horizontal, 8)
    .background(
      RoundedRectangle(cornerRadius: 8)
        .fill(chosen ? Color.white.opacity(0x1A / 255) : hovered ? Theme.panelHover : .clear)
    )
    .padding(.horizontal, -8)
    .contentShape(Rectangle())
    .onHover { hovered = $0 }
    .clickable(enabled: enabled)
    .onTapGesture { if enabled { action() } }
  }
}
