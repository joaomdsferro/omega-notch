import OmegaNotchKit
import SwiftUI

/// What a ring means, spelled out: limit windows, today's tokens, and the
/// chats behind them. It stays open while the pointer is on it.
struct CardView: View {
  var client: EngineClient
  var provider: String
  var edge: String
  var s: CGFloat
  var now: Date
  var tailOffset: CGFloat
  var bannerKind: String
  var bannerLabel: String

  private var reading: UsageReading? { client.reading(for: provider) }
  private var session: SessionState? { reading == nil ? nil : client.session(for: provider) }
  private var sessionKind: SessionKind { session?.kind ?? .idle }
  private var sessionLabel: String { session?.label ?? "" }
  private var status: String { reading?.status ?? "offline" }
  private var stats: TokenStats? { reading == nil ? nil : client.tokens(for: provider) }
  private var chats: [ChatSummary] { reading == nil ? [] : client.chats(for: provider) }

  var body: some View {
    VStack(alignment: .leading, spacing: 12 * s) {
      if !bannerKind.isEmpty { banner }
      header
      if sessionKind != .idle && !sessionLabel.isEmpty {
        Text(sessionLabel)
          .font(.notch(11.5 * s))
          .foregroundStyle(Theme.textSecondary)
          .lineLimit(1)
          .padding(.top, -6 * s)
      }
      if !message.isEmpty {
        Text(message)
          .font(.notch(11.5 * s))
          .foregroundStyle(status == "error" ? Theme.critical : Theme.textSecondary)
          .lineSpacing(2 * s)
          .fixedSize(horizontal: false, vertical: true)
      }
      ForEach(Array((reading?.windows ?? []).enumerated()), id: \.offset) { _, window in
        UsageRow(window: window, now: now, s: s)
      }
      if let stats {
        Rectangle().fill(Theme.hairline).frame(height: 1)
        TokenPanel(stats: stats, s: s)
      }
      // Finished chats to read come first, under their own heading.
      let unread = chats.filter(\.isUnread)
      let rest = chats.filter { !$0.isUnread }.prefix(max(2, 5 - unread.count))
      if !unread.isEmpty {
        Rectangle().fill(Theme.hairline).frame(height: 1)
        chatSection(
          "TO READ · \(unread.count)", color: Theme.unread, chats: Array(unread.prefix(5)))
      }
      if !rest.isEmpty {
        Rectangle().fill(Theme.hairline).frame(height: 1)
        chatSection("RECENT CHATS", color: Theme.textSecondary, chats: Array(rest))
      }
    }
    .padding(16 * s)
    .frame(width: 320 * s, alignment: .topLeading)
    .background {
      RoundedRectangle(cornerRadius: 20 * s)
        .fill(Theme.card)
        .overlay(RoundedRectangle(cornerRadius: 20 * s).strokeBorder(Theme.cardStroke, lineWidth: 1))
        .shadow(color: .black.opacity(0.6), radius: 18, y: 8)
    }
    .overlay {
      CardTail(edge: edge, offset: tailOffset, half: 10 * s, length: 11 * s).fill(Theme.card)
    }
  }

  private func chatSection(_ heading: String, color: Color, chats: [ChatSummary]) -> some View {
    VStack(alignment: .leading, spacing: 9 * s) {
      Text(heading)
        .font(.notch(10.5 * s, .semibold))
        .kerning(0.6)
        .foregroundStyle(color)
      ForEach(chats) { chat in
        ChatRow(chat: chat, now: now, s: s) { client.openChat(chat) }
      }
    }
  }

  private var message: String {
    guard let reading else {
      return client.connected
        ? "No providers are switched on. Open Settings to pick some."
        : "Engine offline — waiting for omega-notch-engine."
    }
    return reading.message ?? ""
  }

  /// Peek: why the card opened on its own.
  private var banner: some View {
    let (tint, title): (Color, String) =
      switch bannerKind {
      case "waiting_you": (Theme.waiting, "Needs you")
      case "limit": (Theme.watch, "")
      case "limit_reached": (Theme.critical, "")
      default: (Theme.ample, "Finished")
      }
    // A limit's label already says it all.
    let text = [title, bannerLabel].filter { !$0.isEmpty }.joined(separator: "  ·  ")
    return Text(text)
      .font(.notch(12 * s, .semibold))
      .foregroundStyle(tint)
      .lineLimit(1)
      .padding(.horizontal, 10 * s)
      .padding(.vertical, 6 * s)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(RoundedRectangle(cornerRadius: 9 * s).fill(tint.opacity(0.14)))
  }

  private var header: some View {
    HStack(alignment: .firstTextBaseline, spacing: 9 * s) {
      ProviderGlyph(provider: reading?.provider ?? "", color: Theme.text)
        .frame(width: 18 * s, height: 18 * s)
        .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 5 * s }
      Text(reading?.displayName ?? "Omega Notch")
        .font(.notch(14.5 * s, .semibold))
        .foregroundStyle(Theme.text)
        .lineLimit(1)
      Spacer(minLength: 8 * s)
      Text(stateText)
        .font(.notch(11.5 * s, sessionKind == .idle ? .regular : .semibold))
        .foregroundStyle(
          sessionKind == .waitingYou
            ? Theme.waiting : sessionKind == .busy ? Theme.text : Theme.textSecondary)
    }
  }

  private var stateText: String {
    switch sessionKind {
    case .busy: return "Working"
    case .waitingYou: return "Needs you"
    case .idle:
      guard let reading else { return "" }
      if reading.fidelity == "derived" { return "Estimated" }
      if reading.fetchedAt != nil && (status == "ok" || status == "stale") {
        return "Updated " + Format.ago(reading.fetchedAt, now: now)
      }
      return ""
    }
  }
}

/// One limit window: what it is, when it resets, and how much is gone.
struct UsageRow: View {
  var window: UsageWindow
  var now: Date
  var s: CGFloat

  var body: some View {
    let pct = max(0, min(100, window.usedPct))
    VStack(alignment: .leading, spacing: 6 * s) {
      HStack(alignment: .firstTextBaseline) {
        Text(window.label.isEmpty ? "Usage" : window.label)
          .font(.notch(12.5 * s))
          .foregroundStyle(Theme.text)
          .lineLimit(1)
        Spacer(minLength: 8 * s)
        Text(Format.resetsIn(window.resetsAt, now: now))
          .font(.notch(11.5 * s))
          .foregroundStyle(Theme.textSecondary)
      }
      GeometryReader { geo in
        ZStack(alignment: .leading) {
          Capsule().fill(Theme.track)
          Capsule()
            .fill(Theme.usageColor(pct))
            .frame(width: max(pct > 0 ? 4 * s : 0, geo.size.width * pct / 100))
            .animation(.easeOut(duration: 0.4), value: pct)
        }
      }
      .frame(height: 4 * s)
      Text("\(Int(pct.rounded()))% used")
        .font(.notch(11 * s, tabular: true))
        .foregroundStyle(Theme.textSecondary)
    }
  }
}

/// Tokens the provider burned today, with the last seven days for scale.
struct TokenPanel: View {
  var stats: TokenStats
  var s: CGFloat

  var body: some View {
    let days = stats.daily
    let peak = max(1, days.map(\.total).max() ?? 1)
    VStack(alignment: .leading, spacing: 6 * s) {
      HStack(alignment: .firstTextBaseline) {
        Text("TOKENS TODAY")
          .font(.notch(10.5 * s, .semibold))
          .kerning(0.6)
          .foregroundStyle(Theme.textSecondary)
        Spacer()
        Text(Format.tokens(stats.week.total) + " this week")
          .font(.notch(11 * s, tabular: true))
          .foregroundStyle(Theme.textSecondary)
      }
      HStack(alignment: .center) {
        Text(Format.tokens(stats.today.total))
          .font(.notch(24 * s, .semibold, tabular: true))
          .foregroundStyle(Theme.text)
        Spacer()
        // Seven days, oldest first; today is the bright bar on the right.
        HStack(alignment: .bottom, spacing: 4 * s) {
          ForEach(Array(days.enumerated()), id: \.offset) { index, day in
            RoundedRectangle(cornerRadius: 2 * s)
              .fill(index == days.count - 1 ? Theme.text : Theme.track)
              .frame(width: 8 * s, height: max(2 * s, 30 * s * day.total / peak))
          }
        }
        .frame(height: 30 * s, alignment: .bottom)
      }
      .frame(height: 30 * s)
      Text(
        "in \(Format.tokens(stats.today.input))  ·  out \(Format.tokens(stats.today.output))  ·  cache \(Format.tokens(stats.today.cacheRead + stats.today.cacheWrite))"
      )
      .font(.notch(11 * s, tabular: true))
      .foregroundStyle(Theme.textSecondary)
      .lineLimit(1)
      let models = stats.modelsToday.prefix(3).map { "\($0.model) \(Format.tokens($0.total))" }
      if !models.isEmpty {
        Text(models.joined(separator: "  ·  "))
          .font(.notch(11 * s, tabular: true))
          .foregroundStyle(Theme.textTertiary)
          .lineLimit(1)
      }
    }
  }
}

/// One recent chat: is it alive, what is it, where, and what it has cost.
/// Click to jump to it: its window, or a new one resuming it.
struct ChatRow: View {
  var chat: ChatSummary
  var now: Date
  var s: CGFloat
  var open: () -> Void

  @State private var hovered = false

  var body: some View {
    VStack(alignment: .leading, spacing: 2 * s) {
      HStack(alignment: .firstTextBaseline, spacing: 9 * s) {
        Circle()
          .fill(chat.isUnread ? Theme.unread : Theme.stateColor(chat.state))
          .frame(width: 7 * s, height: 7 * s)
          .breathing(chat.state != .idle)
          .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 * s }
        Text(chat.title)
          .font(.notch(12.5 * s, chat.isUnread ? .semibold : .regular))
          .foregroundStyle(Theme.text)
          .lineLimit(1)
        Spacer(minLength: 8 * s)
        Text(when)
          .font(.notch(11 * s, tabular: true))
          .foregroundStyle(
            chat.isUnread
              ? Theme.unread
              : chat.state == .waitingYou
                ? Theme.waiting : chat.state == .busy ? Theme.text : Theme.textSecondary)
      }
      Text(Format.chatDetail(chat))
        .font(.notch(11 * s, tabular: true))
        .foregroundStyle(Theme.textSecondary)
        .lineLimit(1)
        .padding(.leading, 16 * s)
    }
    .padding(4 * s)
    .background(RoundedRectangle(cornerRadius: 6 * s).fill(hovered ? Theme.panelHover : .clear))
    .padding(-4 * s)
    .contentShape(Rectangle())
    .onHover { hovered = $0 }
    .clickable()
    .onTapGesture(perform: open)
  }

  private var when: String {
    switch chat.state {
    case .busy: "working"
    case .waitingYou: "needs you"
    case .idle:
      chat.isUnread
        ? "finished " + Format.ago(chat.updatedAt, now: now) : Format.ago(chat.updatedAt, now: now)
    }
  }
}
