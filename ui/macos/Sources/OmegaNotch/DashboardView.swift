import Combine
import OmegaNotchKit
import SwiftUI

/// Every tool's limits, token and cost history from the engine's database,
/// today's estimated spend, the dearest sessions and the recent chats. One
/// tool filter at the top scopes the whole page.
struct DashboardView: View {
  var client: EngineClient
  var openSettings: () -> Void

  @State private var days = 30
  @State private var providerFilter = "all"
  @State private var tokensBy = "tool"
  @State private var costBy = "model"
  @State private var showAllChats = false
  @State private var showAllSessions = false
  @State private var openSession: String?
  /// Words that sessions must carry, and the project they ran in: both
  /// narrow the whole page. The engine narrows its numbers; the chats are
  /// already here.
  @State private var search = ""
  @State private var project = ""
  /// One session, by id, that the numbers narrow to.
  @State private var chat = ""
  /// The model Claude's analysis runs on.
  @State private var analysisModel = "sonnet"
  @State private var now = Date()

  private let ticker = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

  // MARK: Data

  /// The series colours chosen in Settings.
  private var shades: [Color] { DashboardPalette.shades(client.config).map { Color(hex: $0) } }

  private func matches(_ provider: String) -> Bool { providerFilter == "all" || provider == providerFilter }
  private var activeReadings: [UsageReading] { client.activeReadings }
  private var shownReadings: [UsageReading] { activeReadings.filter { matches($0.provider) } }

  /// What to say where the numbers are not here yet: the engine is still
  /// sending them, it is not running, or there is nothing to show.
  private var loadingHint: String {
    if client.dashboardLoading { return "Loading…" }
    return client.connected ? "No tools are switched on." : "Waiting for the engine…"
  }
  private var dates: [String] { DashboardData.rangeDates(days: days, now: now) }
  private var today: String { DashboardData.isoDay(now) }
  private var points: [HistoryPoint] { client.dashboard.points.filter { matches($0.provider) } }
  private var modelPoints: [ModelDayPoint] { client.dashboard.models.filter { matches($0.provider) } }

  private var filterOptions: [DashSegmented.Option] {
    [DashSegmented.Option(value: "all", label: "All tools")]
      + activeReadings.map { .init(value: $0.provider, label: $0.displayName, provider: $0.provider) }
  }

  private static let kindLabels = [
    ("output", "Output"), ("input", "Input"), ("cache_write", "Cache write"), ("cache_read", "Cache read"),
  ]

  private var tokenChart: DashboardData.Stack {
    switch tokensBy {
    case "model":
      return DashboardData.stack(
        modelPoints.map { .init(date: $0.date, key: $0.model, value: $0.total) }, dates: dates) { $0 }
    case "kind":
      let entries = points.flatMap { p in
        [
          DashboardData.Entry(date: p.date, key: "output", value: p.output),
          .init(date: p.date, key: "input", value: p.input),
          .init(date: p.date, key: "cache_write", value: p.cacheWrite),
          .init(date: p.date, key: "cache_read", value: p.cacheRead),
        ]
      }
      let labels = Dictionary(uniqueKeysWithValues: Self.kindLabels)
      return DashboardData.stack(entries, dates: dates) { labels[$0] ?? $0 }
    default:
      return DashboardData.stack(
        points.map { .init(date: $0.date, key: $0.provider, value: $0.total) }, dates: dates
      ) { client.displayName($0) }
    }
  }

  private var costChart: DashboardData.Stack {
    if costBy == "tool" {
      return DashboardData.stack(
        modelPoints.map { .init(date: $0.date, key: $0.provider, value: $0.costUsd) }, dates: dates
      ) { client.displayName($0) }
    }
    return DashboardData.stack(
      modelPoints.map { .init(date: $0.date, key: $0.model, value: $0.costUsd) }, dates: dates) { $0 }
  }

  private var rangeKinds: TokenTotals {
    points.reduce(into: TokenTotals()) { t, p in
      t.input += p.input
      t.output += p.output
      t.cacheRead += p.cacheRead
      t.cacheWrite += p.cacheWrite
    }
  }

  private var tokenStats: [TokenStats] { client.tokens.filter { matches($0.provider) } }
  /// Narrowed, today and the days before come from the sessions in scope.
  private func scopedDay(_ date: String) -> [HistoryPoint] { points.filter { $0.date == date } }
  private var tokensToday: Double {
    scoped ? scopedDay(today).reduce(0) { $0 + $1.total } : tokenStats.reduce(0) { $0 + $1.today.total }
  }

  /// Mean of the six days before today, from the live seven-day window.
  private var priorAverage: Double {
    if scoped {
      let before = DashboardData.rangeDates(days: 7, now: now).dropLast()
      return before.reduce(0) { sum, date in sum + scopedDay(date).reduce(0) { $0 + $1.total } } / 6
    }
    var sums = Array(repeating: 0.0, count: 6)
    for stats in tokenStats {
      for j in 0..<min(6, max(0, stats.daily.count - 1)) { sums[j] += stats.daily[j].total }
    }
    return sums.reduce(0, +) / 6
  }

  private var todayTotals: TokenTotals {
    if scoped {
      return scopedDay(today).reduce(into: TokenTotals()) { t, p in
        t.input += p.input
        t.output += p.output
        t.cacheRead += p.cacheRead
        t.cacheWrite += p.cacheWrite
      }
    }
    return tokenStats.reduce(into: TokenTotals()) { t, s in
      t.input += s.today.input
      t.output += s.today.output
      t.cacheRead += s.today.cacheRead
      t.cacheWrite += s.today.cacheWrite
    }
  }

  private var shownCosts: [CostEstimate] { client.dashboard.costs.filter { matches($0.provider) } }
  private var shownChats: [ChatSummary] { client.chats.filter { matches($0.provider) } }
  private var searchWords: [String] { DashboardData.searchWords(search) }
  /// Whether the numbers on screen are narrowed; they lag the field a little.
  private var scoped: Bool { client.dashboard.isScoped }
  /// What they are narrowed to, as a few words.
  private var scopeLabel: String {
    let d = client.dashboard
    let chat = d.session.isEmpty ? nil : chatTitle(d.session)
    return [d.project.isEmpty ? nil : d.project, d.search.isEmpty ? nil : "“\(d.search)”", chat]
      .compactMap { $0 }.joined(separator: " · ")
  }

  /// Sessions in scope: one when one is picked.
  private var scopedCount: Int { client.dashboard.session.isEmpty ? shownSessions.count : 1 }

  /// A session's title, short enough for a button.
  private func chatTitle(_ id: String) -> String {
    let title = client.dashboard.sessions.first { $0.id == id }?.title ?? "One chat"
    return title.count > 40 ? String(title.prefix(39)) + "…" : title
  }
  private var shownSessions: [SessionCost] { client.dashboard.sessions.filter { matches($0.provider) } }

  private var workingCount: Int { client.sessions.filter { $0.kind == .busy && matches($0.provider) }.count }
  private var waitingCount: Int {
    client.sessions.filter { $0.kind == .waitingYou && matches($0.provider) }.count
  }

  private var maxWindows: Int {
    shownReadings.filter(\.hasData).map(\.windows.count).max() ?? 1
  }

  // MARK: Page

  var body: some View {
    let tokens = tokenChart
    let costs = costChart
    let kinds = rangeKinds
    let rangeTotal = kinds.total
    let activeDays = tokens.days.filter { $0.total > 0 }.count
    let costDays = costs.days.filter { $0.total > 0 }.count
    let costToday = shownCosts.reduce(0) { $0 + $1.costUsd }

    ScrollView {
      VStack(alignment: .leading, spacing: 24) {
        header
        filterBar(rangeCost: costs.total)
        stats(
          rangeTotal: rangeTotal, activeDays: activeDays, rangeCost: costs.total, costDays: costDays,
          costToday: costToday, cacheRead: kinds.cacheRead)
        suggestions
        limits

        DashCard(
          heading: "Estimated cost", caption: "Per day at list prices · hover a day for the breakdown",
          trailing: {
            DashSegmented(
              options: [.init(value: "model", label: "By model"), .init(value: "tool", label: "By tool")],
              value: costBy
            ) { costBy = $0 }
          }
        ) {
          UsageChart(
            stack: costs, today: today, money: true,
            emptyText: "No cost history yet — it fills in as you work."
          )
          .frame(height: 220)
          Legend(series: costs.series, money: true)
        }

        DashCard(
          heading: "Tokens", caption: "Per day · hover a day for the breakdown",
          trailing: {
            DashSegmented(
              options: [
                .init(value: "tool", label: "By tool"), .init(value: "model", label: "By model"),
                .init(value: "kind", label: "By kind"),
              ], value: tokensBy
            ) { tokensBy = $0 }
          }
        ) {
          UsageChart(stack: tokens, today: today).frame(height: 220)
          Legend(series: tokens.series)
        }

        let rows = DashboardData.modelRows(modelPoints, dates: dates)
        HStack(alignment: .top, spacing: 16) {
          DashCard(
            heading: "Models",
            caption: "\(rows.count) \(rows.count == 1 ? "model" : "models") in the last \(days) days · by estimated cost"
          ) {
            ModelTable(models: rows, totalCost: costs.total)
          }
          DashCard(heading: "Today", caption: "Estimated cost and token mix") {
            CostBreakdown(costs: shownCosts, total: costToday, today: todayTotals)
          }
          .frame(width: 360)
        }
        .fixedSize(horizontal: false, vertical: true)

        sessions(models: rows, rangeCost: costs.total)
        chats
        bots
      }
      .padding(.horizontal, 32)
      .padding(.top, 40)
      .padding(.bottom, 36)
    }
    .frame(minWidth: 920, minHeight: 620)
    .background(Theme.panel)
    .environment(\.seriesShades, shades)
    .onAppear { client.requestDashboard(days: days) }
    .onChange(of: days) { _, new in client.requestDashboard(days: new) }
    .onChange(of: filterOptions.map(\.value)) { _, values in
      // A tool that was switched off cannot stay selected.
      if !values.contains(providerFilter) { providerFilter = "all" }
    }
    .onReceive(ticker) { _ in
      now = Date()
      client.requestDashboard(days: days)
    }
  }

  private var header: some View {
    HStack(alignment: .top) {
      VStack(alignment: .leading, spacing: 6) {
        Text("Usage").font(.notch(26, .semibold)).foregroundStyle(Theme.text)
        HStack(spacing: 8) {
          Circle()
            .fill(
              !client.connected
                ? Theme.critical
                : waitingCount > 0 ? Theme.waiting : workingCount > 0 ? Theme.text : Theme.ample
            )
            .frame(width: 8, height: 8)
          Text(statusLine).font(.notch(13))
            .foregroundStyle(client.connected ? Theme.textSecondary : Theme.critical)
        }
      }
      Spacer()
      DashSegmented(
        options: [7, 30, 90].map { .init(value: "\($0)", label: "\($0) days") }, value: "\(days)"
      ) { days = Int($0) ?? 30 }
    }
  }

  /// Search, project and tool: what the whole page is narrowed to.
  private func filterBar(rangeCost: Double) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      SearchField(prompt: "Search sessions and chats by title, project, folder or model", text: $search, large: true)
      HStack(spacing: 12) {
        ScopeMenu(
          icon: "folder", all: "All projects",
          choices: client.dashboard.projects.map {
            .init(
              value: $0.project, label: $0.project,
              detail: Format.usd($0.costUsd) + " · \($0.sessions) \($0.sessions == 1 ? "session" : "sessions")")
          },
          value: project, chosenLabel: project
        ) { project = $0 }
        ScopeMenu(
          icon: "bubble.left.and.bubble.right", all: "All chats",
          choices: shownSessions.map {
            .init(value: $0.id, label: $0.title.count > 60 ? String($0.title.prefix(59)) + "…" : $0.title,
                  detail: Format.usd($0.costUsd))
          },
          value: chat, chosenLabel: chatTitle(chat)
        ) { chat = $0 }
        if activeReadings.count > 1 {
          DashSegmented(options: filterOptions, value: providerFilter) { providerFilter = $0 }
        }
        Spacer()
      }
      if scoped {
        HStack(alignment: .top, spacing: 12) {
          RoundedRectangle(cornerRadius: 2).fill(Theme.text).frame(width: 3)
          VStack(alignment: .leading, spacing: 3) {
            Text("Showing \(scopeLabel)").font(.notch(14, .semibold)).foregroundStyle(Theme.text)
            Text(
              "\(scopedCount) \(scopedCount == 1 ? "session" : "sessions") · \(Format.usd(rangeCost)) in the last \(days) days. Only Claude Code sessions know their project and title, so the numbers below are theirs; limits are the account's."
            )
            .font(.notch(12)).foregroundStyle(Theme.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
          }
          Spacer()
          TextButton(label: "Clear") {
            search = ""
            project = ""
            chat = ""
          }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.panelRaised))
      }
    }
    // Typing settles before the engine is asked again.
    .task(id: search) {
      guard (try? await Task.sleep(for: .milliseconds(250))) != nil else { return }
      client.searchDashboard(search)
    }
    .onChange(of: project) { _, new in
      // A chat from another project would leave nothing to show.
      chat = ""
      client.setDashboardProject(new)
    }
    .onChange(of: chat) { _, new in client.setDashboardSession(new) }
  }

  private var statusLine: String {
    guard client.connected else { return "Engine offline — numbers may be out of date" }
    var parts: [String] = []
    if workingCount > 0 { parts.append("\(workingCount) working") }
    if waitingCount > 0 { parts.append("\(waitingCount) waiting on you") }
    let unread = shownChats.filter(\.isUnread).count
    if unread > 0 { parts.append("\(unread) to read") }
    if parts.isEmpty { parts.append("All quiet") }
    return parts.joined(separator: " · ") + " · updated " + Format.formatted(now, "HH:mm")
  }

  private func stats(
    rangeTotal: Double, activeDays: Int, rangeCost: Double, costDays: Int, costToday: Double,
    cacheRead: Double
  ) -> some View {
    let change: String = {
      guard priorAverage > 0 else { return "No earlier days to compare" }
      let d = (tokensToday - priorAverage) / priorAverage * 100
      return (d >= 0 ? "▲ " : "▼ ") + "\(Int(abs(d).rounded()))% vs 6-day average"
    }()
    return HStack(spacing: 0) {
      Stat(label: "Tokens today", value: Format.tokens(tokensToday), note: change)
      Divider().overlay(Theme.hairline).padding(.vertical, 16)
      Stat(
        label: "Tokens · \(days) days", value: Format.tokens(rangeTotal),
        note: activeDays > 0
          ? "\(Format.tokens(rangeTotal / Double(activeDays))) per active day · \(activeDays) active"
          : "No history in this range")
      Divider().overlay(Theme.hairline).padding(.vertical, 16)
      Stat(
        label: "Estimated cost · \(days) days", value: Format.usd(rangeCost),
        note: costDays > 0
          ? "\(Format.usd(rangeCost / Double(costDays))) per active day · today \(Format.usd(costToday))"
          : "Nothing spent in this range")
      Divider().overlay(Theme.hairline).padding(.vertical, 16)
      Stat(
        label: "Served from cache",
        value: rangeTotal > 0 ? "\(Int((100 * cacheRead / rangeTotal).rounded()))%" : "—",
        note: rangeTotal > 0 ? "Cache reads, share of \(days)-day tokens" : "No tokens in this range")
    }
    .frame(height: 96)
    .background(
      RoundedRectangle(cornerRadius: 12).fill(Theme.panelRaised)
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.hairline, lineWidth: 1)))
  }

  private var limits: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(alignment: .firstTextBaseline, spacing: 10) {
        Text("Limits").font(.notch(15, .semibold)).foregroundStyle(Theme.text)
        Text("Click a tool to refresh it").font(.notch(12)).foregroundStyle(Theme.textTertiary)
      }
      if shownReadings.isEmpty {
        VStack(spacing: 12) {
          Text(loadingHint)
            .font(.notch(13)).foregroundStyle(Theme.textSecondary)
          if client.connected { TextButton(label: "Open Settings", action: openSettings) }
        }
        .frame(maxWidth: .infinity, minHeight: 120)
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.cardStroke, lineWidth: 1))
      } else {
        LazyVGrid(
          columns: Array(
            repeating: GridItem(.flexible(), spacing: 16, alignment: .top),
            count: max(1, min(3, shownReadings.count))),
          spacing: 16
        ) {
          ForEach(shownReadings) { reading in
            LimitCard(
              reading: reading, session: client.session(for: reading.provider), now: now,
              windowSlots: maxWindows
            ) { client.refresh(reading.provider) }
          }
        }
      }
    }
  }

  /// What to change, from the engine's local rules over the sessions in
  /// view. Each can narrow the page to the chat it is about, or open it.
  private var suggestions: some View {
    // The rules and Claude read Claude Code's sessions: with another tool
    // picked, there is nothing of its own to say.
    let all = client.dashboard.suggestions.filter { matches($0.provider) }
    let saving = all.compactMap(\.savingUsd).reduce(0, +)
    let asking = client.analysis?.state == "running"
    let canAsk = matches("claude_code")
    return DashCard(
      heading: "Suggestions",
      caption: (saving > 0 ? "Up to \(Format.usd(saving)) less in the last \(days) days · " : "")
        + "from local rules over these sessions, nothing leaves your Mac",
      trailing: {
        if canAsk {
          HStack(spacing: 8) {
            DashSegmented(
              options: [.init(value: "sonnet", label: "Sonnet"), .init(value: "opus", label: "Opus")],
              value: analysisModel
            ) { analysisModel = $0 }
            TextButton(label: asking ? "Asking Claude…" : "Ask Claude") {
              if !asking { client.analyzeUsage(model: analysisModel) }
            }
          }
        }
      }
    ) {
      VStack(spacing: 0) {
        if all.isEmpty {
          Text(
            canAsk
              ? "Nothing stands out in these sessions. Ask Claude for a closer look."
              : "Suggestions read Claude Code's sessions. Pick All tools or Claude Code to see them.")
            .font(.notch(13)).foregroundStyle(Theme.textTertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 8)
        }
        ForEach(Array(all.enumerated()), id: \.element.id) { index, item in
          if index > 0 { Rectangle().fill(Theme.hairline).frame(height: 1) }
          SuggestionRow(
            item: item,
            show: item.sessions.first.flatMap { id in
              client.dashboard.sessions.contains { $0.id == id } && chat != id ? { chat = id } : nil
            },
            open: item.sessions.first.flatMap { id in
              client.chats.first { $0.id == id }.map { found in { client.openChat(found) } }
            })
        }
        if canAsk, let analysis = client.analysis {
          Rectangle().fill(Theme.hairline).frame(height: 1)
          AnalysisView(analysis: analysis)
        }
        if canAsk {
          Text(
          "Ask Claude sends only totals, ratios and models, with sessions as S1, S2…: no titles, folders or chat text. It runs through your own claude command and subscription, with no tools."
        )
          .font(.notch(11)).foregroundStyle(Theme.textTertiary)
          .fixedSize(horizontal: false, vertical: true)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.top, 10)
        }
      }
    }
  }

  /// The range's dearest sessions. A model keeps the colour it has in the
  /// Models table, so the two read together.
  private func sessions(models: [DashboardData.ModelRow], rangeCost: Double) -> some View {
    let chosen = client.dashboard.session
    let all = chosen.isEmpty ? shownSessions : shownSessions.filter { $0.id == chosen }
    let shown = showAllSessions ? all : Array(all.prefix(8))
    let modelShades = Dictionary(
      models.enumerated().map { ($1.model, shades[$0 % shades.count]) },
      uniquingKeysWith: { first, _ in first })
    let caption: String = {
      if scoped {
        return "\(all.count) \(all.count == 1 ? "session" : "sessions") for \(scopeLabel) in the last \(days) days, by estimated cost"
      }
      return all.isEmpty
        ? "By estimated cost in the last \(days) days"
        : "Top \(all.count) by estimated cost in the last \(days) days · click one for its models"
    }()
    return DashCard(
      heading: "Dearest sessions",
      caption: caption,
      trailing: {
        if all.count > 8 {
          TextButton(label: showAllSessions ? "Show fewer" : "Show all \(all.count)") {
            showAllSessions.toggle()
          }
        }
      }
    ) {
      if all.isEmpty {
        Text(scoped ? "No session in this range matches." : "No session history in this range yet.").font(.notch(13)).foregroundStyle(Theme.textTertiary)
          .padding(.top, 8)
      } else {
        VStack(spacing: 0) {
          HStack(spacing: 0) {
            Text("Session").padding(.leading, 44)
            Spacer()
            Text("Models").frame(width: 112)
            Text("Tokens").frame(width: 76, alignment: .trailing)
            Text("Est. cost").frame(width: 84, alignment: .trailing)
            Text("Share").frame(width: 64, alignment: .trailing)
            Text("Last day").frame(width: 84, alignment: .trailing)
          }
          .font(.notch(11, .medium))
          .foregroundStyle(Theme.textTertiary)
          .frame(height: 20)
          ForEach(Array(shown.enumerated()), id: \.element.id) { index, session in
            SessionRow(
              session: session, today: today, first: index == 0, rangeCost: rangeCost,
              shade: { modelShades[$0] ?? shades[shades.count - 1] },
              expanded: openSession == session.id || !chosen.isEmpty,
              toggle: {
                withAnimation(.easeOut(duration: 0.18)) {
                  openSession = openSession == session.id ? nil : session.id
                }
              },
              open: { client.openChat(session) },
              focus: chosen.isEmpty ? { chat = session.id } : nil)
          }
        }
      }
    }
  }

  private var chats: some View {
    let words = searchWords
    let found = shownChats.filter {
      (project.isEmpty || $0.project == project) && (chat.isEmpty || $0.id == chat)
        && DashboardData.matches(words, in: [$0.title, $0.project, $0.cwd, $0.model, $0.id])
    }
    let narrowed = !words.isEmpty || !project.isEmpty || !chat.isEmpty
    // Chats to read first, so the ones counted are never past "Show all".
    let all = found.filter(\.isUnread) + found.filter { !$0.isUnread }
    let shown = showAllChats ? all : Array(all.prefix(8))
    let showContext = all.contains { $0.contextPct != nil }
    let unreadCount = all.filter(\.isUnread).count
    return DashCard(
      heading: "Recent chats",
      caption: (!narrowed
        ? "\(all.count) \(all.count == 1 ? "chat" : "chats")"
        : "\(all.count) of \(shownChats.count) \(shownChats.count == 1 ? "chat matches" : "chats match")")
        + (unreadCount > 0 ? " · \(unreadCount) to read" : "") + " · click one to jump to it",
      trailing: {
        if all.count > 8 {
          TextButton(label: showAllChats ? "Show fewer" : "Show all \(all.count)") { showAllChats.toggle() }
        }
      }
    ) {
      if all.isEmpty {
        Text(narrowed ? "No recent chat matches." : "No recent chats found.").font(.notch(13)).foregroundStyle(Theme.textTertiary).padding(.top, 8)
      } else {
        VStack(spacing: 0) {
          HStack(spacing: 0) {
            Text("Chat").padding(.leading, 44)
            Spacer()
            Text("Tokens").frame(width: 84, alignment: .trailing)
            if showContext { Text("Context").frame(width: 96, alignment: .trailing) }
            Text("Last active").frame(width: 76, alignment: .trailing)
          }
          .font(.notch(11, .medium))
          .foregroundStyle(Theme.textTertiary)
          .frame(height: 20)
          ForEach(Array(shown.enumerated()), id: \.element.id) { index, chat in
            DashChatRow(chat: chat, now: now, first: index == 0, showContext: showContext) {
              client.openChat(chat)
            }
          }
        }
      }
    }
  }

  /// Grok Bot's bots, busiest first. Grok Bot records no per-bot counters,
  /// so the tokens are read off the local transcripts, never measured.
  @ViewBuilder private var bots: some View {
    let all = client.dashboard.bots
    if matches("grok_bot") && !all.isEmpty {
      DashCard(
        heading: "Grok Bot bots",
        caption: "By estimated usage in the last \(days) days · estimated from local transcripts, never measured"
      ) {
        VStack(spacing: 0) {
          HStack(spacing: 0) {
            Text("Bot")
            Spacer()
            Text("Messages").frame(width: 76, alignment: .trailing)
            Text("Est. tokens").frame(width: 84, alignment: .trailing)
          }
          .font(.notch(11, .medium)).foregroundStyle(Theme.textTertiary).frame(height: 20)
          ForEach(Array(all.enumerated()), id: \.element.id) { index, bot in
            BotRow(bot: bot, first: index == 0) { client.openChat(bot) }
          }
        }
      }
    }
  }
}

/// One Grok Bot bot on the dashboard: its routines under its name, then how
/// much it moved and what that roughly cost in tokens.
private struct BotRow: View {
  var bot: BotUsage
  var first: Bool
  var open: () -> Void

  @State private var hovered = false

  var body: some View {
    HStack(spacing: 0) {
      // Every ranked bot gets its drawn avatar — a plain disc when the
      // roster never styled one — so the names line up.
      BotAvatar(shape: bot.avatarShape ?? "", colorName: bot.avatarColor ?? "")
        .frame(width: 24, height: 24)
        .padding(.trailing, 10)
      VStack(alignment: .leading, spacing: 2) {
        Text(bot.name).font(.notch(13, .medium)).foregroundStyle(Theme.text).lineLimit(1)
        if !bot.routines.isEmpty {
          Text(bot.routines.joined(separator: ", "))
            .font(.notch(11)).foregroundStyle(Theme.textTertiary).lineLimit(1)
        }
      }
      Spacer(minLength: 16)
      Text("\(bot.messages)")
        .font(.notch(12, tabular: true)).foregroundStyle(Theme.textSecondary)
        .frame(width: 76, alignment: .trailing)
      Text("~" + Format.tokens(bot.tokens))
        .font(.notch(12, tabular: true)).foregroundStyle(Theme.text)
        .frame(width: 84, alignment: .trailing)
    }
    .frame(height: 44)
    .padding(.horizontal, 8)
    .background(RoundedRectangle(cornerRadius: 8).fill(Theme.panelHover).opacity(hovered ? 1 : 0))
    .overlay(alignment: .top) {
      if !first && !hovered { Rectangle().fill(Theme.hairline).frame(height: 1).padding(.horizontal, 8) }
    }
    .padding(.horizontal, -8)
    .contentShape(Rectangle())
    .onHover { hovered = $0 }
    .clickable()
    .onTapGesture(perform: open)
    .accessibilityElement(children: .combine)
    .accessibilityAddTraits(.isButton)
    .accessibilityHint("Open Grok Bot")
  }
}

private struct Stat: View {
  var label: String
  var value: String
  var note: String

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(label).font(.notch(12, .medium)).foregroundStyle(Theme.textSecondary)
      Text(value).font(.notch(26, .semibold, tabular: true)).foregroundStyle(Theme.text).lineLimit(1)
      Text(note).font(.notch(12, tabular: true)).foregroundStyle(Theme.textTertiary).lineLimit(1)
    }
    .padding(.horizontal, 20)
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

/// Every model used in the range: a daily-token sparkline, tokens, estimated
/// cost and its share of the spend.
private struct ModelTable: View {
  var models: [DashboardData.ModelRow]
  var totalCost: Double

  @Environment(\.seriesShades) private var shades

  var body: some View {
    if models.isEmpty {
      Text("No model history in this range yet.").font(.notch(13)).foregroundStyle(Theme.textTertiary)
    } else {
      VStack(spacing: 0) {
        HStack(spacing: 0) {
          Text("Model")
          Spacer()
          Text("Daily tokens").frame(width: 112)
          Text("Tokens").frame(width: 76, alignment: .trailing)
          Text("Est. cost").frame(width: 84, alignment: .trailing)
          Text("Share").frame(width: 96, alignment: .trailing)
        }
        .font(.notch(11, .medium)).foregroundStyle(Theme.textTertiary).frame(height: 20)

        ForEach(Array(models.enumerated()), id: \.element.id) { index, row in
          let share = totalCost > 0 ? row.cost / totalCost : 0
          let peak = max(1, row.daily.max() ?? 1)
          VStack(spacing: 0) {
            if index > 0 { Rectangle().fill(Theme.hairline).frame(height: 1) }
            HStack(spacing: 0) {
              RoundedRectangle(cornerRadius: 2).fill(shades[index % shades.count])
                .frame(width: 8, height: 8)
              ProviderGlyph(provider: row.provider, color: Theme.textSecondary)
                .frame(width: 14, height: 14).padding(.leading, 12)
              VStack(alignment: .leading, spacing: 2) {
                Text(row.model).font(.notch(13, .medium)).foregroundStyle(Theme.text).lineLimit(1)
                Text("\(row.activeDays) \(row.activeDays == 1 ? "day" : "days") used")
                  .font(.notch(11)).foregroundStyle(Theme.textTertiary)
              }
              .padding(.leading, 10)
              Spacer(minLength: 12)
              // Sparkline: one hairline column per day of the range.
              HStack(alignment: .bottom, spacing: row.daily.count > 45 ? 0 : 1) {
                ForEach(Array(row.daily.enumerated()), id: \.offset) { _, value in
                  Rectangle()
                    .fill(value > 0 ? Theme.text.opacity(0.85) : Theme.track)
                    .frame(height: value > 0 ? max(2, 22 * value / peak) : 1)
                }
              }
              .frame(width: 96, height: 22, alignment: .bottom)
              .frame(width: 112)
              Text(Format.tokens(row.total)).font(.notch(12, tabular: true))
                .foregroundStyle(Theme.textSecondary).frame(width: 76, alignment: .trailing)
              Text(Format.usd(row.cost)).font(.notch(13, .semibold, tabular: true))
                .foregroundStyle(Theme.text).frame(width: 84, alignment: .trailing)
              HStack(spacing: 8) {
                Bar(fraction: share, color: Theme.text, minimum: 2).frame(width: 40)
                Text(share > 0 && share < 0.01 ? "<1%" : "\(Int((share * 100).rounded()))%")
                  .font(.notch(12, tabular: true)).foregroundStyle(Theme.textSecondary)
                  .frame(width: 32, alignment: .trailing)
              }
              .frame(width: 96, alignment: .trailing)
            }
            .frame(height: 51)
          }
        }
      }
    }
  }
}

/// Today at a glance: estimated spend, a share bar across models, each model
/// with its tokens, cost and share, then today's tokens split by kind.
private struct CostBreakdown: View {
  var costs: [CostEstimate]
  var total: Double
  var today: TokenTotals

  @Environment(\.seriesShades) private var shades

  var body: some View {
    let rows = Array(costs.sorted { $0.costUsd > $1.costUsd }.prefix(6))
    let mix = [
      ("Cache read", today.cacheRead), ("Cache write", today.cacheWrite), ("Input", today.input),
      ("Output", today.output),
    ]
    let mixTotal = today.total

    VStack(alignment: .leading, spacing: 16) {
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        Text(Format.usd(total)).font(.notch(32, .semibold, tabular: true)).foregroundStyle(Theme.text)
        Text("today").font(.notch(13)).foregroundStyle(Theme.textSecondary)
      }
      if rows.count > 1 {
        GeometryReader { geo in
          HStack(spacing: 2) {
            ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
              Rectangle().fill(shades[index % shades.count])
                .frame(width: max(2, (geo.size.width - CGFloat(rows.count - 1) * 2) * row.costUsd / max(total, 0.0001)))
            }
          }
        }
        .frame(height: 8)
        .background(Theme.track)
        .clipShape(Capsule())
      }
      if rows.isEmpty {
        Text(client.dashboardLoading ? "Loading…" : "Nothing spent yet today.")
          .font(.notch(13)).foregroundStyle(Theme.textTertiary)
      } else {
        VStack(spacing: 0) {
          ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
            let share = total > 0 ? row.costUsd / total : 0
            VStack(spacing: 0) {
              if index > 0 { Rectangle().fill(Theme.hairline).frame(height: 1) }
              HStack(spacing: 0) {
                RoundedRectangle(cornerRadius: 2).fill(shades[index % shades.count])
                  .frame(width: 8, height: 8)
                ProviderGlyph(provider: row.provider, color: Theme.textSecondary)
                  .frame(width: 14, height: 14).padding(.leading, 12)
                VStack(alignment: .leading, spacing: 2) {
                  Text(row.model.isEmpty ? "Unknown model" : row.model).font(.notch(13))
                    .foregroundStyle(Theme.text).lineLimit(1)
                  Text("\(Format.tokens(row.total)) tokens").font(.notch(11, tabular: true))
                    .foregroundStyle(Theme.textTertiary)
                }
                .padding(.leading, 10)
                Spacer(minLength: 12)
                VStack(alignment: .trailing, spacing: 2) {
                  Text(Format.usd(row.costUsd)).font(.notch(13, .semibold, tabular: true))
                    .foregroundStyle(Theme.text)
                  Text("\(Int((share * 100).rounded()))%").font(.notch(11, tabular: true))
                    .foregroundStyle(Theme.textTertiary)
                }
              }
              .frame(height: 43)
            }
          }
        }
      }
      if mixTotal > 0 {
        VStack(alignment: .leading, spacing: 12) {
          Rectangle().fill(Theme.hairline).frame(height: 1)
          HStack(alignment: .firstTextBaseline) {
            Text("Tokens today").font(.notch(13, .semibold)).foregroundStyle(Theme.text)
            Spacer()
            Text(Format.tokens(mixTotal)).font(.notch(12, tabular: true)).foregroundStyle(Theme.textSecondary)
          }
          ForEach(mix, id: \.0) { label, value in
            let share = value / mixTotal
            VStack(spacing: 6) {
              HStack(alignment: .firstTextBaseline) {
                Text(label).font(.notch(12)).foregroundStyle(Theme.textSecondary)
                Spacer()
                Text(
                  "\(Format.tokens(value))  ·  \(share > 0 && share < 0.01 ? "<1" : "\(Int((share * 100).rounded()))")%"
                )
                .font(.notch(12, tabular: true)).foregroundStyle(Theme.text)
              }
              Bar(fraction: share, color: Theme.text, minimum: 2)
            }
          }
        }
      }
      Text("Estimated from list prices per model, cache-aware. Not a bill: plans and vendors price differently.")
        .font(.notch(11)).foregroundStyle(Theme.textTertiary)
        .fixedSize(horizontal: false, vertical: true)
    }
  }
}

/// One session in the dearest list: its title and where it ran, a bar of its
/// spend by model, tokens, estimated cost, share of the range's spend and the
/// last day it ran. Click to see each model's tokens by kind.
/// Claude's answer: a line while it thinks, then its Markdown, or why not.
private struct AnalysisView: View {
  var analysis: UsageAnalysis

  private var name: String { analysis.model == "opus" ? "Opus" : "Sonnet" }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 8) {
        Image(systemName: "sparkles").font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.textSecondary)
        Text(
          analysis.state == "running" ? "Claude (\(name)) is reading the numbers…"
            : analysis.state == "failed" ? "Claude could not answer" : "Claude (\(name)) suggests"
        )
        .font(.notch(14, .semibold)).foregroundStyle(Theme.text)
        if analysis.state == "running" { ProgressView().controlSize(.small) }
      }
      if !analysis.text.isEmpty {
        Text(markdown)
          .font(.notch(13))
          .foregroundStyle(analysis.state == "failed" ? Theme.critical : Theme.textSecondary)
          .textSelection(.enabled)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.vertical, 12)
  }

  /// Bold, code and links render; bullets and line breaks stay as written.
  private var markdown: AttributedString {
    (try? AttributedString(
      markdown: analysis.text,
      options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
      ?? AttributedString(analysis.text)
  }
}

private struct SuggestionRow: View {
  var item: Suggestion
  /// Narrows the page to the chat it is about; nil when it cannot.
  var show: (() -> Void)?
  var open: (() -> Void)?

  private var icon: String {
    switch item.kind {
    case "model_choice": "cpu"
    case "cache_churn": "arrow.triangle.2.circlepath"
    case "long_session": "text.alignleft"
    case "context_full": "gauge.with.dots.needle.67percent"
    default: "lightbulb"
    }
  }

  var body: some View {
    HStack(alignment: .top, spacing: 12) {
      Image(systemName: icon).font(.system(size: 14, weight: .medium)).foregroundStyle(Theme.textSecondary)
        .frame(width: 20).padding(.top, 2)
      VStack(alignment: .leading, spacing: 4) {
        Text(item.title).font(.notch(14, .semibold)).foregroundStyle(Theme.text).lineLimit(2)
        Text(item.detail).font(.notch(12)).foregroundStyle(Theme.textSecondary)
          .fixedSize(horizontal: false, vertical: true)
        if show != nil || open != nil {
          HStack(spacing: 8) {
            if let show {
              TextButton(label: item.sessions.count > 1 ? "Show the dearest" : "Only this chat", action: show)
            }
            if let open { TextButton(label: "Open chat", action: open) }
          }
          .padding(.top, 4)
        }
      }
      Spacer(minLength: 12)
      if let saving = item.savingUsd {
        Text("≈ \(Format.usd(saving)) less").font(.notch(13, .semibold, tabular: true))
          .foregroundStyle(Theme.ample)
          .padding(.horizontal, 10).frame(height: 26)
          .background(Capsule().fill(Theme.ample.opacity(0.12)))
      }
    }
    .padding(.vertical, 12)
    .accessibilityElement(children: .contain)
  }
}

private struct SessionRow: View {
  var session: SessionCost
  var today: String
  var first: Bool
  var rangeCost: Double
  var shade: (String) -> Color
  var expanded: Bool
  var toggle: () -> Void
  var open: () -> Void
  /// Narrows the page to this session; nil once it is.
  var focus: (() -> Void)?

  @State private var hovered = false

  private var place: String {
    var parts: [String] = []
    for part in [session.project, session.surface] {
      if let part, !part.isEmpty { parts.append(part) }
    }
    parts.append(session.models.map(\.model).joined(separator: ", "))
    return parts.joined(separator: "  ·  ")
  }

  private static func percent(_ share: Double) -> String {
    share > 0 && share < 0.01 ? "<1%" : "\(Int((share * 100).rounded()))%"
  }

  var body: some View {
    let share = rangeCost > 0 ? session.costUsd / rangeCost : 0
    VStack(spacing: 0) {
      HStack(spacing: 0) {
        RoundedRectangle(cornerRadius: 8).fill(Theme.controlFill).frame(width: 32, height: 32)
          .overlay(
            ProviderGlyph(provider: session.provider, color: Theme.textSecondary).frame(width: 16, height: 16))
        VStack(alignment: .leading, spacing: 3) {
          Text(session.title).font(.notch(13, .medium)).foregroundStyle(Theme.text).lineLimit(1)
          Text(place).font(.notch(11)).foregroundStyle(Theme.textTertiary).lineLimit(1)
        }
        .padding(.leading, 12)
        Spacer(minLength: 16)
        mix.frame(width: 96).frame(width: 112)
        Text(Format.tokens(session.total)).font(.notch(12, tabular: true))
          .foregroundStyle(Theme.textSecondary).frame(width: 76, alignment: .trailing)
        Text(Format.usd(session.costUsd)).font(.notch(13, .semibold, tabular: true))
          .foregroundStyle(Theme.text).frame(width: 84, alignment: .trailing)
        Text(Self.percent(share)).font(.notch(12, tabular: true))
          .foregroundStyle(Theme.textSecondary).frame(width: 64, alignment: .trailing)
        Text(Format.day(session.lastDate, today: today)).font(.notch(12, tabular: true))
          .foregroundStyle(Theme.textSecondary).frame(width: 84, alignment: .trailing)
      }
      .frame(height: 56)
      .contentShape(Rectangle())
      .onHover { hovered = $0 }
      .clickable()
      .onTapGesture(perform: toggle)
      .accessibilityElement(children: .combine)
      .accessibilityAddTraits(.isButton)
      .accessibilityHint(expanded ? "Hide its models" : "Show its models")

      if expanded { details.padding(.leading, 44).padding(.bottom, 14) }
    }
    .padding(.horizontal, 8)
    .background(RoundedRectangle(cornerRadius: 8).fill(Theme.panelHover).opacity(hovered || expanded ? 1 : 0))
    .overlay(alignment: .top) {
      if !first && !hovered && !expanded {
        Rectangle().fill(Theme.hairline).frame(height: 1).padding(.horizontal, 8)
      }
    }
    .padding(.horizontal, -8)
  }

  /// The session's spend as one bar, a segment per model.
  private var mix: some View {
    GeometryReader { geo in
      let gaps = CGFloat(max(0, session.models.count - 1)) * 2
      HStack(spacing: 2) {
        ForEach(session.models) { model in
          Rectangle().fill(shade(model.model))
            .frame(
              width: max(2, (geo.size.width - gaps) * model.costUsd / max(session.costUsd, 0.0001)))
        }
      }
    }
    .frame(height: 6)
    .background(Theme.track)
    .clipShape(Capsule())
  }

  private var details: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: 0) {
        Text("Model")
        Spacer()
        ForEach(["Input", "Output", "Cache write", "Cache read"], id: \.self) {
          Text($0).frame(width: 84, alignment: .trailing)
        }
        Text("Est. cost").frame(width: 84, alignment: .trailing)
        Text("Share").frame(width: 64, alignment: .trailing)
      }
      .font(.notch(11, .medium)).foregroundStyle(Theme.textTertiary).frame(height: 22)
      ForEach(session.models) { model in
        HStack(spacing: 0) {
          RoundedRectangle(cornerRadius: 2).fill(shade(model.model)).frame(width: 8, height: 8)
          Text(model.model).font(.notch(12, .medium)).foregroundStyle(Theme.text).lineLimit(1)
            .padding(.leading, 10)
          Spacer(minLength: 12)
          ForEach(Array([model.input, model.output, model.cacheWrite, model.cacheRead].enumerated()), id: \.offset) {
            _, value in
            Text(Format.tokens(value)).font(.notch(12, tabular: true))
              .foregroundStyle(Theme.textSecondary).frame(width: 84, alignment: .trailing)
          }
          Text(Format.usd(model.costUsd)).font(.notch(12, .semibold, tabular: true))
            .foregroundStyle(Theme.text).frame(width: 84, alignment: .trailing)
          Text(Self.percent(session.costUsd > 0 ? model.costUsd / session.costUsd : 0))
            .font(.notch(12, tabular: true)).foregroundStyle(Theme.textSecondary)
            .frame(width: 64, alignment: .trailing)
        }
        .frame(height: 30)
      }
      HStack {
        Text(
          session.total > 0
            ? "\(Int((100 * session.cacheRead / session.total).rounded()))% served from cache"
            : ""
        )
        .font(.notch(11, tabular: true)).foregroundStyle(Theme.textTertiary)
        Spacer()
        if let focus { TextButton(label: "Only this chat", action: focus) }
        TextButton(label: "Open chat", action: open)
      }
      .padding(.top, 8)
    }
  }
}

/// One chat in the dashboard list: tool, title and where it ran, its tokens,
/// how full its context is, and when it last moved. Click to jump to it.
private struct DashChatRow: View {
  var chat: ChatSummary
  var now: Date
  var first: Bool
  var showContext: Bool
  var open: () -> Void

  @State private var hovered = false

  private var tokens: Double { chat.tokens?.total ?? 0 }

  private var place: String {
    var parts: [String] = []
    for part in [chat.project, chat.model, chat.surface] {
      if let part, !part.isEmpty { parts.append(part) }
    }
    let added = chat.linesAdded ?? 0
    let removed = chat.linesRemoved ?? 0
    if added > 0 || removed > 0 { parts.append("+\(added) −\(removed)") }
    let joined = parts.joined(separator: "  ·  ")
    return joined.isEmpty ? (chat.preview ?? "") : joined
  }

  var body: some View {
    HStack(spacing: 0) {
      ZStack(alignment: .topTrailing) {
        RoundedRectangle(cornerRadius: 8).fill(Theme.controlFill).frame(width: 32, height: 32)
          .overlay {
            // A bot the roster styled gets its drawn avatar instead of the
            // tool's mark.
            if let shape = chat.avatarShape, !shape.isEmpty {
              BotAvatar(shape: shape, colorName: chat.avatarColor ?? "").frame(width: 20, height: 20)
            } else {
              ProviderGlyph(
                provider: chat.provider, color: chat.state == .idle ? Theme.textSecondary : Theme.text)
                .frame(width: 16, height: 16)
            }
          }
        if chat.state != .idle || chat.isUnread {
          Circle().fill(chat.isUnread ? Theme.unread : Theme.stateColor(chat.state))
            .overlay(Circle().strokeBorder(Theme.panelRaised, lineWidth: 2))
            .frame(width: 10, height: 10)
            .offset(x: 3, y: -3)
            .breathing(chat.state != .idle)
        }
      }
      VStack(alignment: .leading, spacing: 3) {
        Text(chat.title).font(.notch(13, chat.isUnread ? .semibold : .medium)).foregroundStyle(Theme.text)
          .lineLimit(1)
        Text(place).font(.notch(11, tabular: true)).foregroundStyle(Theme.textTertiary).lineLimit(1)
      }
      .padding(.leading, 12)
      Spacer(minLength: 16)
      Text(tokens > 0 ? Format.tokens(tokens) : "—").font(.notch(12, tabular: true))
        .foregroundStyle(tokens > 0 ? Theme.text : Theme.textTertiary)
        .frame(width: 84, alignment: .trailing)
      if showContext {
        HStack(spacing: 0) {
          if let ctx = chat.contextPct {
            Bar(fraction: ctx / 100, color: Theme.usageColor(ctx)).frame(width: 36).padding(.leading, 24)
          }
          Spacer(minLength: 0)
          Text(chat.contextPct.map { "\(Int($0.rounded()))%" } ?? "—").font(.notch(12, tabular: true))
            .foregroundStyle(chat.contextPct == nil ? Theme.textTertiary : Theme.textSecondary)
        }
        .frame(width: 96)
      }
      Text(
        chat.state == .busy
          ? "Working"
          : chat.state == .waitingYou
            ? "Needs you" : chat.isUnread ? "To read" : Format.ago(chat.updatedAt, now: now)
      )
      .font(.notch(12, chat.state == .idle && !chat.isUnread ? .regular : .semibold, tabular: true))
      .foregroundStyle(
        chat.isUnread
          ? Theme.unread
          : chat.state == .waitingYou ? Theme.waiting : chat.state == .busy ? Theme.text : Theme.textSecondary)
      .frame(width: 76, alignment: .trailing)
    }
    .frame(height: 56)
    .padding(.horizontal, 8)
    .background(RoundedRectangle(cornerRadius: 8).fill(Theme.panelHover).opacity(hovered ? 1 : 0))
    .overlay(alignment: .top) {
      if !first && !hovered { Rectangle().fill(Theme.hairline).frame(height: 1).padding(.horizontal, 8) }
    }
    .padding(.horizontal, -8)
    .contentShape(Rectangle())
    .onHover { hovered = $0 }
    .clickable()
    .onTapGesture(perform: open)
    .accessibilityElement(children: .combine)
    .accessibilityAddTraits(.isButton)
    .accessibilityHint("Open chat")
  }
}
