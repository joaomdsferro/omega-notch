import AppKit
import OmegaNotchKit
import SwiftUI

/// Everything drawn in the notch panel, placed by `NotchModel`'s geometry.
struct NotchView: View {
  var model: NotchModel
  var openSettings: () -> Void
  var openDashboard: () -> Void

  @State private var motionStart = Date.now
  @State private var dragStart: Double = 0

  private var client: EngineClient { model.client }
  private var s: CGFloat { model.s }

  var body: some View {
    ZStack(alignment: .topLeading) {
      nub
      body(of: model.notchRect)
      rings
      footer
      card
    }
    .frame(width: model.panelSize.width, height: model.panelSize.height, alignment: .topLeading)
    .animation(.easeOut(duration: 0.22), value: model.bodyLength)
    .animation(.easeOut(duration: 0.24), value: model.revealed)
    .environment(\.colorScheme, .dark)
  }

  // MARK: The nub

  /// What is left on the edge while the notch is tucked away; on a screen
  /// with a camera housing, the housing plays that part. It moves while a
  /// session works or waits for you, in the motion chosen in Settings.
  @ViewBuilder private var nub: some View {
    if model.housing == .zero {
      TimelineView(.animation(paused: motion.isEmpty)) { context in
        let pose = NubMotion.pose(motion, at: context.date.timeIntervalSince(motionStart), unit: s)
        let length = 30 * s * model.config.idleSize * pose.lengthScale
        let depth = model.nubDepth * pose.depthScale
        let centre = model.bodyStart + model.collapsedLength / 2 + pose.along
        let frame = edgeFrame(start: centre - length / 2 - depth / 2, length: length + depth, depth: depth)
        // Breathing fades the paint; the nub's own opacity belongs to hiding
        // and showing.
        NotchShape(
          edge: model.edge, curl: depth / 2, radius: depth / 2, wave: pose.wave * depth,
          wavePhase: pose.wavePhase
        )
        .fill(Color(hex: model.config.idleColor).opacity(pose.fade))
        .frame(width: frame.width, height: frame.height)
        .offset(x: frame.minX, y: frame.minY)
      }
      .opacity(model.revealed ? 0 : 1)
      // Each motion starts from rest, so switching never leaves it half way.
      .onChange(of: motion, initial: true) { motionStart = .now }
    }
  }

  /// The motion the nub plays now, or empty to keep it still. Waiting for you
  /// outranks working.
  private var motion: String {
    guard !model.revealed else { return "" }
    let kinds = client.activeReadings.compactMap { client.session(for: $0.provider)?.kind }
    let style =
      kinds.contains(.waitingYou)
      ? model.config.nubWaiting : kinds.contains(.busy) ? model.config.nubWorking : "none"
    return style == "none" ? "" : style
  }

  /// A frame along the edge, in panel coordinates, flush with the edge.
  private func edgeFrame(start: CGFloat, length: CGFloat, depth: CGFloat) -> CGRect {
    let size = model.panelSize
    switch model.edge {
    case "left": return CGRect(x: 0, y: start, width: depth, height: length)
    case "right": return CGRect(x: size.width - depth, y: start, width: depth, height: length)
    case "bottom": return CGRect(x: start, y: size.height - depth, width: length, height: depth)
    default: return CGRect(x: start, y: 0, width: length, height: depth)
    }
  }

  // MARK: The notch

  private func body(of rect: CGRect) -> some View {
    let frame =
      model.vertical
      ? rect.insetBy(dx: 0, dy: -model.curl) : rect.insetBy(dx: -model.curl, dy: 0)
    return NotchShape(edge: model.edge, curl: model.curl, radius: 28 * s)
      .fill(Color(hex: model.notchColor))
      .frame(width: frame.width, height: frame.height)
      .offset(x: frame.minX, y: frame.minY)
  }

  private var rings: some View {
    let shown = model.shownReadings
    return ForEach(Array((shown.isEmpty ? [nil] : shown.map { $0 }).enumerated()), id: \.offset) {
      index, reading in
      let cell = model.cellRect(index)
      RingView(
        reading: reading,
        sessionKind: reading.flatMap { client.session(for: $0.provider)?.kind } ?? .idle,
        s: s,
        surface: model.notchColor,
        hovered: reading != nil && model.hoveredProvider == reading?.provider
      ) {
        if let provider = reading?.provider { client.refresh(provider) }
      }
      .offset(x: cell.minX, y: cell.minY)
    }
  }

  // MARK: Footer

  /// Unfolds after the rings when the pointer arrives: a pair of buttons
  /// across the notch and the grip after them, so it fits the notch's depth
  /// on any edge.
  @ViewBuilder private var footer: some View {
    if model.onHousing { wings } else { footerBlock }
  }

  /// On a camera housing: the dashboard on the left of the rings and Settings
  /// on the right, level with the rings, so the notch stays symmetric.
  private var wings: some View {
    let side = 26 * s
    let gap = model.wingLength - side
    let y = model.notchRect.minY + model.padAcross + 22 * s - side / 2
    let left = model.ringsStart - gap - side
    let right = model.ringsStart + model.ringsSpan + gap
    return ZStack(alignment: .topLeading) {
      ToolButton(icon: .dashboard, s: s, surface: model.notchColor, action: openDashboard)
        .offset(x: left, y: y)
      ToolButton(icon: .settings, s: s, surface: model.notchColor, action: openSettings)
        .offset(x: right, y: y)
    }
    .opacity(model.expanded ? 1 : 0)
    .animation(.easeOut(duration: 0.16), value: model.expanded)
    .allowsHitTesting(model.expanded)
  }

  private var footerBlock: some View {
    let spacing = 6 * s
    let side = 26 * s
    let block = 2 * side + spacing
    let body = model.notchRect
    let across = model.depth
    let origin: CGPoint =
      model.vertical
      ? CGPoint(
        x: body.minX + (model.depth - block) / 2,
        y: body.minY + model.collapsedLength + (model.footerLength - block) / 2 - 6 * s)
      : CGPoint(
        x: body.minX + model.collapsedLength + (model.footerLength - block) / 2 - 8 * s,
        y: body.minY + (across - block) / 2)

    let pair = Group {
      ToolButton(icon: .dashboard, s: s, surface: model.notchColor, action: openDashboard)
      ToolButton(icon: .settings, s: s, surface: model.notchColor, action: openSettings)
    }
    let grip = ToolButton(
      icon: .grip, s: s, surface: model.notchColor,
      cursor: model.vertical ? .resizeUpDown : .resizeLeftRight
    )
    .gesture(dragGrip)
    return Group {
      if model.vertical {
        VStack(spacing: spacing) {
          HStack(spacing: spacing) { pair }
          grip
        }
      } else {
        HStack(spacing: spacing) {
          VStack(spacing: spacing) { pair }
          grip
        }
      }
    }
    .frame(width: block, height: block)
    .offset(x: origin.x, y: origin.y)
    .opacity(model.expanded ? 1 : 0)
    .animation(.easeOut(duration: 0.16), value: model.expanded)
    .allowsHitTesting(model.expanded)
  }

  /// Drag the grip to slide the notch along its edge.
  private var dragGrip: some Gesture {
    DragGesture(minimumDistance: 1, coordinateSpace: .global)
      .onChanged { value in
        if !model.dragging {
          dragStart = model.config.edgePosition
          model.dragPosition = dragStart
          model.dragging = true
        }
        let moved = model.vertical ? value.translation.height : value.translation.width
        if model.travel > 0 {
          model.dragPosition = max(0, min(1, dragStart + moved / model.travel))
        }
      }
      .onEnded { _ in
        let position = model.dragPosition
        client.updateConfig { $0.edgePosition = position }
        model.dragging = false
        model.updateWanted()
      }
  }

  // MARK: The card

  @ViewBuilder private var card: some View {
    if !model.cardProvider.isEmpty {
      let frame = model.cardFrame
      let slide = model.cardActive ? 0 : 8 * s
      let offset: CGSize =
        switch model.edge {
        case "left": CGSize(width: -slide, height: 0)
        case "right": CGSize(width: slide, height: 0)
        case "bottom": CGSize(width: 0, height: slide)
        default: CGSize(width: 0, height: -slide)
        }
      CardView(
        client: client,
        provider: model.cardProvider,
        edge: model.edge,
        s: s,
        now: model.now,
        tailOffset: model.tailOffset,
        bannerKind: client.peekOpen && model.cardProvider == client.peekProvider ? client.peekKind : "",
        bannerLabel: client.peekLabel
      )
      .fixedSize(horizontal: false, vertical: true)
      .onGeometryChange(for: CGSize.self, of: \.size) { model.cardSize = $0 }
      .offset(x: frame.minX + offset.width, y: frame.minY + offset.height)
      .opacity(model.cardActive ? 1 : 0)
      .animation(.easeOut(duration: 0.15), value: model.cardActive)
      .allowsHitTesting(model.cardActive)
    }
  }
}
