import AppKit
import Observation
import OmegaNotchKit

/// The notch's state and geometry, the same rules as the Plasma shell's
/// Main.qml. The panel spans the whole screen edge and is transparent: the
/// notch slides along it and the card opens beside it without the window
/// moving. Only the notch and an open card take the pointer (`interactive`);
/// elsewhere it falls through to whatever is underneath.
///
/// Unless told to stay, the notch tucks behind the edge, leaving a nub, until
/// a session finishes or asks for you, or the pointer touches the edge where
/// it lives. On a screen with a camera housing, the housing is the nub.
@MainActor
@Observable
final class NotchModel {
  let client: EngineClient

  /// The panel's size, and how far the camera housing reaches down into it
  /// (zero without one, or away from the top edge).
  var panelSize = CGSize(width: 1440, height: 400)
  var housing = CGSize.zero

  // Pointer state, fed by the panel controller.
  private(set) var pointerInside = false
  private(set) var notchHovered = false
  var dragging = false
  var dragPosition = 0.5

  private(set) var revealed = true
  /// The ring under the pointer, kept while the pointer is on the card.
  private(set) var hoveredProvider = ""
  /// Held through the fade-out so the card does not empty while it leaves.
  private(set) var cardProvider = ""
  /// Picked with the wheel; forgotten when the notch hides.
  private(set) var manualProvider = ""
  var cardSize = CGSize(width: 320, height: 200)
  private(set) var now = Date()

  @ObservationIgnored private var hideTimer: Timer?
  @ObservationIgnored private var unhoverTimer: Timer?
  @ObservationIgnored private var clock: Timer?

  init(client: EngineClient) {
    self.client = client
    clock = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated { self?.now = Date() }
    }
  }

  /// Shows itself once when it first appears, then tucks away.
  func showOnce() {
    revealed = true
    updateWanted()
  }

  // MARK: Metrics (medium preset, scaled by s)

  var config: NotchConfig { client.config }
  /// The edge the panel sits on: the config's, once `NotchPanel.place()` has
  /// moved the panel there, so the notch is never drawn for one edge in a
  /// panel shaped for another.
  var edge = "top"
  var vertical: Bool { edge == "left" || edge == "right" }
  var s: CGFloat { Theme.scale(for: config.size) }
  var notchColor: String { config.notchColor }

  var cellWidth: CGFloat { 48 * s }
  var cellHeight: CGFloat { 67 * s }  // ring + gap + label
  var cellAlong: CGFloat { vertical ? cellHeight : cellWidth }
  var cellSpacing: CGFloat { (vertical ? 20 : 22) * s }
  var padStart: CGFloat { (vertical ? 24 : 26) * s }
  var padEnd: CGFloat { (vertical ? 16 : 26) * s }
  /// From the screen edge to the rings: below the camera housing on top.
  var padAcross: CGFloat { 14 * s + housing.height }
  var depth: CGFloat { vertical ? 72 * s : cellHeight + padAcross + 12 * s }
  var curl: CGFloat { 34 * s }
  var footerLength: CGFloat { 68 * s }
  var cardGap: CGFloat { 19 * s }  // notch edge -> card, tail included
  var cardWidth: CGFloat { 320 * s }

  var cellCount: Int { max(1, shownReadings.count) }
  /// The rings alone, end to end.
  var ringsSpan: CGFloat { CGFloat(cellCount) * cellAlong + CGFloat(cellCount - 1) * cellSpacing }
  /// Grown out of a camera housing, the notch is symmetric about it: the
  /// rings in the middle, under the camera, and a button on either side.
  var onHousing: Bool { housing.width > 0 }
  /// One of those buttons and its gap to the rings.
  var wingLength: CGFloat { (26 + 14) * s }
  /// Never narrower than the housing it grows out of.
  private var housingMinimum: CGFloat { housing.width - 2 * curl + 24 * s }
  var collapsedLength: CGFloat {
    let rings = padStart + ringsSpan + padEnd
    return onHousing ? max(rings, housingMinimum) : rings
  }
  var expandedLength: CGFloat {
    onHousing
      ? max(padStart + ringsSpan + padEnd + 2 * wingLength, housingMinimum)
      : collapsedLength + footerLength
  }
  var expanded: Bool { notchHovered || dragging || client.peekOpen }
  var bodyLength: CGFloat { expanded ? expandedLength : collapsedLength }

  var axisLength: CGFloat { vertical ? panelSize.height : panelSize.width }
  /// Travel is measured against the expanded length so that unfolding never
  /// pushes the rings out from under the pointer.
  var travel: CGFloat { max(0, axisLength - expandedLength - 2 * curl) }
  var bodyStart: CGFloat {
    // With a housing, the notch is centred on it and grows both ways.
    if onHousing { return (axisLength - bodyLength) / 2 }
    return curl + CGFloat(dragging ? dragPosition : config.edgePosition) * travel
  }

  /// How far the notch is pushed out past its edge.
  var tuck: CGFloat { revealed ? 0 : depth + 2 }
  var nubDepth: CGFloat { housing.height > 0 ? housing.height : 6 * s * config.idleSize }

  /// The notch body (without its curls), where it rests.
  var notchRect: CGRect {
    switch edge {
    case "left": CGRect(x: -tuck, y: bodyStart, width: depth, height: bodyLength)
    case "right":
      CGRect(x: panelSize.width - depth + tuck, y: bodyStart, width: depth, height: bodyLength)
    case "bottom":
      CGRect(x: bodyStart, y: panelSize.height - depth + tuck, width: bodyLength, height: depth)
    default: CGRect(x: bodyStart, y: -tuck, width: bodyLength, height: depth)
    }
  }

  /// Where the panel listens for the pointer: the notch, or only the nub's
  /// sliver of the edge while it is tucked away.
  var maskRect: CGRect {
    let d = revealed ? depth : nubDepth
    let span = expandedLength + 2 * curl
    let start =
      onHousing
      ? (axisLength - (revealed ? span : housing.width)) / 2 : bodyStart - curl
    let length = onHousing && !revealed ? housing.width : span
    switch edge {
    case "left": return CGRect(x: 0, y: start, width: d, height: length)
    case "right": return CGRect(x: panelSize.width - d, y: start, width: d, height: length)
    case "bottom": return CGRect(x: start, y: panelSize.height - d, width: length, height: d)
    default: return CGRect(x: start, y: 0, width: length, height: d)
    }
  }

  /// The card where it rests, stretched back to the notch so the pointer can
  /// cross over to it.
  var cardMask: CGRect {
    let card = cardFrame
    switch edge {
    case "left": return CGRect(x: depth, y: card.minY, width: card.width + cardGap, height: card.height)
    case "right":
      return CGRect(
        x: panelSize.width - depth - cardGap - card.width, y: card.minY,
        width: card.width + cardGap, height: card.height)
    case "bottom":
      return CGRect(
        x: card.minX, y: panelSize.height - depth - cardGap - card.height,
        width: card.width, height: card.height + cardGap)
    default: return CGRect(x: card.minX, y: depth, width: card.width, height: card.height + cardGap)
    }
  }

  /// Whether the pointer at `point` (panel coordinates, top-left origin)
  /// belongs to the notch rather than to what is underneath.
  func interactive(at point: CGPoint) -> Bool {
    maskRect.contains(point) || (cardActive && cardMask.contains(point))
  }

  /// Where along the edge the first ring starts: after the padding, or
  /// centred under the camera housing, where it stays as the notch unfolds.
  var ringsStart: CGFloat {
    onHousing ? (axisLength - ringsSpan) / 2 : bodyStart + padStart
  }

  /// A ring's cell, in panel coordinates.
  func cellRect(_ index: Int) -> CGRect {
    let along = ringsStart + CGFloat(index) * (cellAlong + cellSpacing)
    let body = notchRect
    if vertical {
      return CGRect(
        x: body.minX + (depth - cellWidth) / 2, y: along, width: cellWidth, height: cellHeight)
    }
    return CGRect(x: along, y: body.minY + padAcross, width: cellWidth, height: cellHeight)
  }

  // MARK: Which providers the notch shows

  var activeReadings: [UsageReading] { client.activeReadings }

  /// Newest chat of a provider; distant past when it keeps none.
  private func lastChatAt(_ provider: String) -> Date {
    client.chats(for: provider).compactMap(\.updatedAt).max() ?? .distantPast
  }

  /// A provider with a session running outranks an idle one; among equals the
  /// one whose session started or ended last comes first.
  var ranked: [String] {
    activeReadings.map { reading -> (String, Bool, Date) in
      let session = client.session(for: reading.provider)
      let running = session.map { $0.kind != .idle } ?? false
      let at = running ? (session?.updatedAt ?? .distantPast) : lastChatAt(reading.provider)
      return (reading.provider, running, at)
    }
    .sorted { a, b in a.1 != b.1 ? a.1 : a.2 > b.2 }
    .map(\.0)
  }

  /// Read once: it is asked for on every redraw, and copying the process's
  /// environment each time adds up.
  let previewProvider = ProcessInfo.processInfo.environment["OMEGA_NOTCH_PREVIEW"] ?? ""

  private func isActive(_ provider: String) -> Bool {
    activeReadings.contains { $0.provider == provider }
  }

  /// Always among the rings, whatever its rank.
  var pinnedProvider: String {
    if isActive(manualProvider) { return manualProvider }
    if client.peekOpen && isActive(client.peekProvider) { return client.peekProvider }
    if isActive(previewProvider) { return previewProvider }
    return ""
  }

  /// Chosen by rank, laid out in the providers' own order so rings do not
  /// swap places as sessions come and go.
  var shownReadings: [UsageReading] {
    var picked = Array(ranked.prefix(config.maxProviders))
    if !pinnedProvider.isEmpty, !picked.isEmpty, !picked.contains(pinnedProvider) {
      picked[picked.count - 1] = pinnedProvider
    }
    return activeReadings.filter { picked.contains($0.provider) }
  }

  func shownIndex(of provider: String) -> Int? {
    shownReadings.firstIndex { $0.provider == provider }
  }

  /// Brings up the next provider that has no ring at the moment.
  func cycleProvider(_ step: Int) {
    let all = activeReadings
    let shown = shownReadings
    guard !shown.isEmpty, shown.count < all.count else { return }
    let from = pinnedProvider.isEmpty ? shown[shown.count - 1].provider : pinnedProvider
    guard var i = all.firstIndex(where: { $0.provider == from }) else { return }
    for _ in 0..<all.count {
      i = (i + step + all.count) % all.count
      let candidate = all[i].provider
      if shownIndex(of: candidate) == nil || candidate == from {
        manualProvider = candidate
        return
      }
    }
  }

  // MARK: The card

  var cardTarget: String {
    if !hoveredProvider.isEmpty { return hoveredProvider }
    if isActive(previewProvider) { return previewProvider }
    return ""
  }
  var cardShown: Bool { !cardTarget.isEmpty && shownIndex(of: cardTarget) != nil }
  var cardActive: Bool { cardShown && !dragging }

  /// Where along the edge the card points: the middle of its ring.
  var cardAim: CGFloat {
    let index = CGFloat(shownIndex(of: cardProvider) ?? 0)
    return ringsStart + index * (cellAlong + cellSpacing)
      + (vertical ? 22 * s : cellWidth / 2)
  }

  var cardFrame: CGRect {
    let margin: CGFloat = 12
    let size = CGSize(width: cardWidth, height: cardSize.height)
    let along =
      vertical
      ? max(margin, min(panelSize.height - size.height - margin, cardAim - size.height / 2))
      : max(margin, min(panelSize.width - size.width - margin, cardAim - size.width / 2))
    switch edge {
    case "left": return CGRect(origin: CGPoint(x: depth + cardGap, y: along), size: size)
    case "right":
      return CGRect(
        origin: CGPoint(x: panelSize.width - depth - cardGap - size.width, y: along), size: size)
    case "bottom":
      return CGRect(
        origin: CGPoint(x: along, y: panelSize.height - depth - cardGap - size.height), size: size)
    default: return CGRect(origin: CGPoint(x: along, y: depth + cardGap), size: size)
    }
  }

  var tailOffset: CGFloat { cardAim - (vertical ? cardFrame.minY : cardFrame.minX) }

  // MARK: Pointer

  /// Called on every pointer move with its position in panel coordinates.
  func pointerMoved(to point: CGPoint) {
    let inside = interactive(at: point)
    if inside != pointerInside {
      pointerInside = inside
      updateWanted()
    }
    // Set only when it changes: an observed property notifies on every
    // write, and this runs on every pointer move, so the whole notch and its
    // card were redrawn as the pointer crossed them.
    let overNotch =
      notchRect.insetBy(dx: vertical ? 0 : -curl, dy: vertical ? -curl : 0).contains(point) && revealed
    if overNotch != notchHovered { notchHovered = overNotch }

    // The ring under the pointer, or the card it opened.
    let ring = revealed ? shownReadings.indices.first { cellRect($0).contains(point) } : nil
    if let ring {
      unhoverTimer?.invalidate()
      setHovered(shownReadings[ring].provider)
    } else if cardActive && cardFrame.contains(point) {
      unhoverTimer?.invalidate()
    } else if !hoveredProvider.isEmpty && unhoverTimer?.isValid != true {
      // Long enough to carry the pointer across the gap from ring to card.
      unhoverTimer = Timer.scheduledTimer(withTimeInterval: 0.26, repeats: false) { [weak self] _ in
        MainActor.assumeIsolated { self?.setHovered("") }
      }
    }
  }

  private func setHovered(_ provider: String) {
    guard provider != hoveredProvider else { return }
    hoveredProvider = provider
    if !provider.isEmpty {
      cardProvider = provider
      now = Date()
    }
  }

  /// Something wants the notch out: the pointer, a drag, a peek, a preview.
  var wanted: Bool {
    !config.autoHide || pointerInside || dragging || client.peekOpen || isActive(previewProvider)
  }

  func updateWanted() {
    if wanted {
      hideTimer?.invalidate()
      revealed = true
    } else {
      scheduleHide()
    }
  }

  func peekChanged() {
    // A session that just finished is the news; drop any manual pick.
    if client.peekOpen { manualProvider = "" }
    if !previewProvider.isEmpty { cardProvider = previewProvider }
    updateWanted()
  }

  private func scheduleHide() {
    guard hideTimer?.isValid != true else { return }
    hideTimer = Timer.scheduledTimer(withTimeInterval: 0.45, repeats: false) { [weak self] _ in
      MainActor.assumeIsolated {
        guard let self, !self.wanted else { return }
        self.revealed = false
        self.manualProvider = ""
      }
    }
  }
}
