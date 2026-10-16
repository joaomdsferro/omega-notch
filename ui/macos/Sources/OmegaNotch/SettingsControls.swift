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
  /// Off, it is dimmed and does not toggle.
  var enabled = true
  /// Set in under the switch it belongs to.
  var indent: CGFloat = 0
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
    .opacity(enabled ? 1 : 0.45)
    .frame(minHeight: 44)
    .padding(.horizontal, 8)
    .background(RoundedRectangle(cornerRadius: 8).fill(hovered && enabled ? Theme.panelHover : .clear))
    .padding(.leading, indent)
    .padding(.horizontal, -8)
    .contentShape(Rectangle())
    .onHover { hovered = $0 }
    .clickable(enabled: enabled)
    .onTapGesture { if enabled { toggle(!isOn) } }
    .accessibilityElement(children: .combine)
    .accessibilityAddTraits(.isButton)
    .accessibilityValue(isOn ? "On" : "Off")
    .accessibilityRespondsToUserInteraction(enabled)
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
  /// For the dashboard's series, which sit on the dark panel.
  static let seriesSwatches = ["#F2F2F5", "#5B9BFF", "#43D9AD", "#F2D04B", "#FF8A3D", "#E86BD0", "#9C8CFF"]

  var swatches = SwatchPicker.swatches
  var value: String
  var pick: (String) -> Void

  @State private var text = ""
  @FocusState private var editing: Bool

  var body: some View {
    HStack(spacing: 8) {
      ForEach(swatches, id: \.self) { swatch in
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

/// The dashboard's series in their colours, first series first; one is
/// picked to recolour, and a dot marks the ones given their own colour.
struct SeriesStrip: View {
  var shades: [String]
  var custom: [Bool]
  var chosen: Int
  var pick: (Int) -> Void

  var body: some View {
    HStack(spacing: 8) {
      ForEach(Array(shades.enumerated()), id: \.offset) { index, shade in
        Chip(
          number: index + 1, color: shade, chosen: index == chosen,
          custom: index < custom.count && custom[index]
        ) { pick(index) }
      }
    }
    .frame(height: 40)
  }

  private struct Chip: View {
    var number: Int
    var color: String
    var chosen: Bool
    var custom: Bool
    var action: () -> Void
    @State private var hovered = false

    var body: some View {
      RoundedRectangle(cornerRadius: 8)
        .fill(Color(hex: color))
        .overlay(
          Text("\(number)").font(.notch(12, .semibold, tabular: true)).foregroundStyle(Theme.ink(color)))
        .overlay(alignment: .topTrailing) {
          if custom {
            Circle().fill(Theme.ink(color)).frame(width: 5, height: 5).padding(4)
          }
        }
        .overlay(
          RoundedRectangle(cornerRadius: 8)
            .strokeBorder(chosen ? Theme.text : Theme.cardStroke, lineWidth: chosen ? 2 : 1)
        )
        .frame(width: 40, height: 32)
        .scaleEffect(hovered ? 1.06 : 1)
        .animation(.easeOut(duration: 0.1), value: hovered)
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .clickable()
        .onTapGesture(perform: action)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Series \(number), \(color)\(custom ? ", your own colour" : "")")
        .accessibilityAddTraits(chosen ? [.isButton, .isSelected] : .isButton)
    }
  }
}

/// One screen as a tile: its kind, its name, and a tick on the chosen one;
/// the details are in the tip.
struct ScreenTile: View {
  var title: String
  var icon: String
  var detail: String
  var badge = ""
  var chosen: Bool
  var enabled = true
  var action: () -> Void = {}

  @State private var hovered = false

  var body: some View {
    VStack(alignment: .leading, spacing: 1) {
      HStack(alignment: .top) {
        Image(systemName: icon)
          .font(.system(size: 18))
          .foregroundStyle(chosen ? Theme.text : Theme.textSecondary)
        Spacer(minLength: 0)
        if chosen {
          Image(systemName: "checkmark")
            .font(.system(size: 9, weight: .heavy))
            .foregroundStyle(Theme.panel)
            .frame(width: 18, height: 18)
            .background(Circle().fill(Theme.text))
        }
      }
      Spacer(minLength: 0)
      Text(title)
        .font(.notch(13, chosen ? .semibold : .regular))
        .foregroundStyle(Theme.text)
        .lineLimit(1)
        .truncationMode(.tail)
      if !badge.isEmpty {
        Text(badge).font(.notch(11)).foregroundStyle(Theme.watch)
      }
    }
    .padding(.horizontal, 12)
    .padding(.top, 12)
    .padding(.bottom, 10)
    .frame(width: 118, height: 78, alignment: .leading)
    .background(
      RoundedRectangle(cornerRadius: 10)
        .fill(chosen ? Theme.controlChosen : hovered && enabled ? Theme.panelHover : Theme.controlFill)
        .strokeBorder(Color.white.opacity(chosen ? 0x40 / 255 : 0), lineWidth: 1)
    )
    .animation(.easeOut(duration: 0.12), value: chosen)
    .contentShape(Rectangle())
    .onHover { hovered = $0 }
    .clickable(enabled: enabled)
    .onTapGesture { if enabled { action() } }
    .help(detail)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(title)
    .accessibilityHint(detail)
    .accessibilityAddTraits(chosen ? [.isButton, .isSelected] : .isButton)
  }
}

/// The screen in miniature, shaped like the one the notch lives on (its
/// proportions, its camera housing, and a stand or a laptop's base under it),
/// with the notch drawn where it sits. The whole screen is the target: a click
/// moves the notch to the nearest edge, where the pointer is, and a drag
/// slides it along that edge. The same as the Plasma shell's EdgePicker.
struct EdgePicker: View {
  var screen: ScreenInfo?
  var edge: String
  var position: Double
  var size: String
  var notchColor: String
  /// On a camera housing the notch sits in the middle of the top edge.
  var pinned: Bool
  /// The edge and the position along it, saved together.
  var place: (String, Double) -> Void

  /// The edge and position while the pointer is down; saving refetches every
  /// provider, so they are only committed on release.
  @State private var dragEdge: String?
  @State private var dragPosition: Double?
  @State private var hover: (edge: String, position: Double)?

  private static let edgeNames = [("top", "Top edge"), ("left", "Left edge"), ("right", "Right edge"), ("bottom", "Bottom edge")]
  private let bezel: CGFloat = 6
  private let displayWidth: CGFloat = 300
  private let notchDepth: CGFloat = 9
  private let notchCurl: CGFloat = 6
  /// How close to the middle a position snaps to it.
  private let snap = 0.04

  private var laptop: Bool { screen?.builtIn ?? false }
  private var housing: Bool { screen?.housing ?? false }
  private var displayHeight: CGFloat {
    guard let size = screen?.size, size.width > 0, size.height > 0 else { return 188 }
    return max(140, min(220, displayWidth * size.height / size.width))
  }
  private var lid: CGSize { CGSize(width: displayWidth + 2 * bezel, height: displayHeight + 2 * bezel) }
  private var standHeight: CGFloat { laptop ? 8 : 20 }
  private var pill: CGFloat { 40 * Theme.scale(for: size) }
  private var shownEdge: String { dragEdge ?? edge }
  private var shownPosition: Double {
    if let dragEdge, let dragPosition { return pinnedOn(dragEdge) ? 0.5 : dragPosition }
    return pinned ? 0.5 : position
  }

  var body: some View {
    let width = laptop ? lid.width + 32 : lid.width
    ZStack(alignment: .top) {
      stand
      RoundedRectangle(cornerRadius: 16)
        .fill(Color(hex: "#050506"))
        .strokeBorder(Theme.cardStroke, lineWidth: 1)
        .frame(width: lid.width, height: lid.height)
      display
        .frame(width: displayWidth, height: displayHeight)
        .padding(.top, bezel)
      surface
    }
    .frame(width: width, height: lid.height + standHeight, alignment: .top)
  }

  /// A monitor stands on a neck and a foot; a laptop sits on its base.
  @ViewBuilder private var stand: some View {
    if laptop {
      RoundedRectangle(cornerRadius: 4.5)
        .fill(LinearGradient(colors: [Color(hex: "#3A3A42"), Color(hex: "#202026")], startPoint: .top, endPoint: .bottom))
        .overlay(alignment: .top) {
          RoundedRectangle(cornerRadius: 1.5).fill(Color(hex: "#1E1E24")).frame(width: 40, height: 3)
        }
        .frame(height: 9)
        .padding(.top, lid.height - 1)
        .allowsHitTesting(false)
    } else {
      Rectangle().fill(Color(hex: "#1E1E24")).frame(width: 30, height: 14).padding(.top, lid.height - 1)
      RoundedRectangle(cornerRadius: 3).fill(Color(hex: "#2A2A31")).frame(width: 84, height: 6)
        .padding(.top, lid.height + 12)
    }
  }

  /// Drawn only; the pointer is handled by `surface` above it.
  private var display: some View {
    ZStack(alignment: .topLeading) {
      RoundedRectangle(cornerRadius: 11)
        .fill(LinearGradient(colors: [Color(hex: "#2C303C"), Color(hex: "#17181E")], startPoint: .top, endPoint: .bottom))

      // The camera housing, where the notch goes on the top edge.
      if housing {
        let width = displayWidth * (screen?.housingShare ?? 0.12)
        UnevenRoundedRectangle(bottomLeadingRadius: 3, bottomTrailingRadius: 3)
          .fill(Color(hex: "#050506"))
          .frame(width: width, height: notchDepth - 2)
          .offset(x: (displayWidth - width) / 2)
      }

      // A ghost of the notch where a click would put it.
      if dragEdge == nil, let hover, hover.edge != edge || !pinned {
        notch(on: hover.edge).fill(Color.white.opacity(0x4D / 255))
          .frame(width: notchSize(hover.edge).width, height: notchSize(hover.edge).height)
          .offset(notchOrigin(hover.edge, pinnedOn(hover.edge) ? 0.5 : hover.position))
      }
      // The notch itself, in its own colour, fused to the bezel.
      notch(on: shownEdge).fill(Color(hex: notchColor))
        .frame(width: notchSize(shownEdge).width, height: notchSize(shownEdge).height)
        .offset(notchOrigin(shownEdge, shownPosition))
        .animation(dragPosition == nil ? .easeOut(duration: 0.16) : nil, value: shownPosition)
        .animation(.easeOut(duration: 0.16), value: shownEdge)

      Text(pinnedOn(shownEdge) ? "Camera" : "\(Int((shownPosition * 100).rounded()))%")
        .font(.system(size: 12, design: .monospaced))
        .foregroundStyle(Theme.textSecondary)
        .frame(width: displayWidth, height: displayHeight)
        .opacity(dragPosition == nil ? 0 : 1)
        .animation(.easeOut(duration: 0.12), value: dragPosition == nil)
    }
    .allowsHitTesting(false)
  }

  /// The whole lid, bezel included, as one target: no thin bands to aim at.
  private var surface: some View {
    Color.clear
      .frame(width: lid.width, height: lid.height)
      .contentShape(RoundedRectangle(cornerRadius: 16))
      .coordinateSpace(name: "lid")
      .onContinuousHover(coordinateSpace: .named("lid")) { phase in
        switch phase {
        case .active(let point):
          let at = inDisplay(point)
          let zone = nearestEdge(at)
          hover = (zone, positionAt(zone, at))
        case .ended:
          hover = nil
        }
      }
      .clickable()
      .gesture(
        DragGesture(minimumDistance: 0, coordinateSpace: .named("lid"))
          .onChanged { drag in
            let zone = dragEdge ?? nearestEdge(inDisplay(drag.startLocation))
            dragEdge = zone
            dragPosition = positionAt(zone, inDisplay(drag.location))
          }
          .onEnded { drag in
            let zone = dragEdge ?? nearestEdge(inDisplay(drag.startLocation))
            let at = pinnedOn(zone) ? 0.5 : positionAt(zone, inDisplay(drag.location))
            dragEdge = nil
            dragPosition = nil
            if zone != edge || abs(at - position) > 0.001 { place(zone, at) }
          }
      )
      .help(pinned ? "Click another edge to move the notch off the camera" : "Click an edge, or drag along it")
      .accessibilityElement()
      .accessibilityLabel("Notch position")
      .accessibilityValue(
        pinned ? "Camera housing" : "\(Self.edgeNames.first { $0.0 == edge }?.1 ?? edge), \(Int((position * 100).rounded())) percent"
      )
      .accessibilityActions {
        ForEach(Self.edgeNames.filter { $0.0 != edge }, id: \.0) { zone, name in
          Button("Move to the \(name.lowercased())") { place(zone, 0.5) }
        }
      }
      .accessibilityAdjustableAction { direction in
        guard !pinned else { return }
        let step = direction == .increment ? 0.05 : -0.05
        place(edge, max(0, min(1, position + step)))
      }
  }

  /// The top edge of a screen with a camera housing has one place: the housing.
  private func pinnedOn(_ edge: String) -> Bool { edge == "top" && housing }

  private func inDisplay(_ point: CGPoint) -> CGPoint {
    CGPoint(x: point.x - bezel, y: point.y - bezel)
  }

  /// The edge nearest a point, so every point on the screen picks one.
  private func nearestEdge(_ point: CGPoint) -> String {
    let distances = [
      ("top", point.y), ("left", point.x),
      ("right", displayWidth - point.x), ("bottom", displayHeight - point.y),
    ]
    return distances.min { $0.1 < $1.1 }?.0 ?? "top"
  }

  private func notch(on edge: String) -> NotchShape {
    NotchShape(edge: edge, curl: notchCurl, radius: notchDepth / 2)
  }

  private func notchSize(_ edge: String) -> CGSize {
    let along = pill + 2 * notchCurl
    return edge == "left" || edge == "right"
      ? CGSize(width: notchDepth, height: along) : CGSize(width: along, height: notchDepth)
  }

  /// Where the notch sits on an edge, from a position along it.
  private func notchOrigin(_ edge: String, _ position: Double) -> CGSize {
    let vertical = edge == "left" || edge == "right"
    let length = vertical ? displayHeight : displayWidth
    let start = 8 + CGFloat(position) * (length - pill - 2 * notchCurl - 16)
    switch edge {
    case "left": return CGSize(width: 0, height: start)
    case "right": return CGSize(width: displayWidth - notchDepth, height: start)
    case "bottom": return CGSize(width: start, height: displayHeight - notchDepth)
    default: return CGSize(width: start, height: 0)
    }
  }

  /// The position under a point, snapped to the middle when close to it.
  private func positionAt(_ edge: String, _ point: CGPoint) -> Double {
    let vertical = edge == "left" || edge == "right"
    let length = vertical ? displayHeight : displayWidth
    let at = (vertical ? point.y : point.x) - 8 - notchCurl - pill / 2
    let position = max(0, min(1, Double(at / (length - pill - 2 * notchCurl - 16))))
    return abs(position - 0.5) < snap ? 0.5 : position
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
