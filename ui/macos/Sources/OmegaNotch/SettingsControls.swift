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

/// One alert's sound: its name and a play button, and the system sounds as
/// chips once the row is opened. Picking a chip plays it.
struct SoundRow: View {
  var title: String
  var kind: AlertSound.Kind
  var value: String
  @Binding var open: AlertSound.Kind?
  var pick: (String) -> Void

  @State private var hovered = false

  private var chosen: String { AlertSound.resolve(value, for: kind) }
  private var isOpen: Bool { open == kind }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 12) {
        HStack {
          VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.notch(14)).foregroundStyle(Theme.text)
            Text(chosen).font(.notch(12)).foregroundStyle(Theme.textSecondary)
          }
          Spacer(minLength: 12)
          Image(systemName: "chevron.down")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Theme.textSecondary)
            .rotationEffect(.degrees(isOpen ? 180 : 0))
        }
        .contentShape(Rectangle())
        .onTapGesture {
          withAnimation(.easeOut(duration: 0.16)) { open = isOpen ? nil : kind }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint(isOpen ? "Hides the sounds" : "Shows the sounds")
        .clickable()
        SettingsButton(title: "▶") { AlertSound.play(value, for: kind) }
          .accessibilityLabel("Play \(chosen)")
      }
      .frame(minHeight: 44)
      .padding(.horizontal, 8)
      .background(RoundedRectangle(cornerRadius: 8).fill(hovered || isOpen ? Theme.panelHover : .clear))
      .padding(.horizontal, -8)
      .onHover { hovered = $0 }

      if isOpen {
        FlowLayout(spacing: 6, lineSpacing: 6) {
          ForEach(AlertSound.names, id: \.self) { name in
            Chip(label: name, chosen: name == chosen) {
              AlertSound.play(name, for: kind)
              pick(name)
            }
          }
        }
        .padding(.bottom, 6)
        .transition(.opacity)
      }
    }
  }

  private struct Chip: View {
    var label: String
    var chosen: Bool
    var action: () -> Void
    @State private var hovered = false

    var body: some View {
      Text(label)
        .font(.notch(12, chosen ? .semibold : .regular))
        .foregroundStyle(chosen ? Theme.text : Theme.textSecondary)
        .padding(.horizontal, 10)
        .frame(height: 28)
        .background(
          RoundedRectangle(cornerRadius: 7)
            .fill(chosen ? Theme.controlChosen : hovered ? Theme.controlHover : Theme.controlFill))
        .animation(.easeOut(duration: 0.12), value: chosen)
        .onHover { hovered = $0 }
        .clickable()
        .onTapGesture(perform: action)
        .accessibilityAddTraits(chosen ? [.isButton, .isSelected] : .isButton)
        .accessibilityHint("Plays the sound")
    }
  }
}

/// One tab in Settings' sidebar: an icon and its name, the chosen one raised.
struct TabRow: View {
  var title: String
  var icon: String
  var chosen: Bool
  var action: () -> Void

  @State private var hovered = false

  var body: some View {
    HStack(spacing: 11) {
      Image(systemName: icon)
        .font(.system(size: 14))
        .frame(width: 18)
        .foregroundStyle(chosen ? Theme.text : Theme.textSecondary)
      Text(title)
        .font(.notch(13, chosen ? .semibold : .regular))
        .foregroundStyle(chosen || hovered ? Theme.text : Theme.textSecondary)
      Spacer(minLength: 0)
    }
    .padding(.horizontal, 12)
    .frame(height: 38)
    .background(
      RoundedRectangle(cornerRadius: 9)
        .fill(chosen ? Theme.controlChosen : hovered ? Theme.controlHover : .clear)
    )
    .animation(.easeOut(duration: 0.12), value: chosen)
    .contentShape(Rectangle())
    .onHover { hovered = $0 }
    .clickable()
    .onTapGesture(perform: action)
    .accessibilityElement(children: .combine)
    .accessibilityAddTraits(chosen ? [.isButton, .isSelected] : .isButton)
  }
}

/// Every motion for the nub, side by side, each playing on a sliver of screen
/// edge so the tile shows what it does; the chosen one raised.
struct MotionPicker: View {
  var value: String
  var enabled = true
  var pick: (String) -> Void

  var body: some View {
    HStack(spacing: 6) {
      ForEach(NubMotion.styles, id: \.value) { style in
        MotionTile(style: style, chosen: style.value == value, enabled: enabled) { pick(style.value) }
      }
    }
  }

  private struct MotionTile: View {
    var style: NubMotion.Style
    var chosen: Bool
    var enabled: Bool
    var action: () -> Void

    @State private var hovered = false
    @State private var start = Date.now

    var body: some View {
      let ink = chosen ? Theme.text : Theme.textSecondary
      VStack(spacing: 0) {
        TimelineView(.animation(paused: !enabled || style.value == "none")) { context in
          let pose = NubMotion.pose(style.value, at: context.date.timeIntervalSince(start), unit: 1.3)
          let length = 22 * pose.lengthScale
          let depth = 7 * pose.depthScale
          // The edge of the screen, and the nub hanging from it.
          ZStack(alignment: .top) {
            Rectangle().fill(Theme.track).frame(height: 1).padding(.horizontal, 8)
            NotchShape(
              edge: "top", curl: depth / 2, radius: depth / 2, wave: pose.wave * depth,
              wavePhase: pose.wavePhase
            )
            .fill(ink.opacity(pose.fade))
            .frame(width: length + depth, height: depth)
            .offset(x: pose.along)
          }
          .frame(maxWidth: .infinity, alignment: .top)
        }
        .frame(height: 30)
        .padding(.top, 12)
        Text(style.label)
          .font(.notch(11, chosen ? .semibold : .regular))
          .foregroundStyle(ink)
          .lineLimit(1)
          .minimumScaleFactor(0.8)
          .padding(.bottom, 9)
      }
      .frame(maxWidth: .infinity)
      .frame(height: 66)
      .background(
        RoundedRectangle(cornerRadius: 10)
          .fill(chosen ? Theme.controlChosen : hovered && enabled ? Theme.panelHover : Theme.controlFill)
          .strokeBorder(Color.white.opacity(chosen ? 0x40 / 255 : 0), lineWidth: 1)
      )
      .opacity(enabled ? 1 : 0.45)
      .animation(.easeOut(duration: 0.12), value: chosen)
      .contentShape(Rectangle())
      .onHover { hovered = $0 }
      .clickable(enabled: enabled)
      .onTapGesture { if enabled { action() } }
      .help(style.tip)
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(style.label)
      .accessibilityHint(style.tip)
      .accessibilityAddTraits(chosen ? [.isButton, .isSelected] : .isButton)
    }
  }
}
