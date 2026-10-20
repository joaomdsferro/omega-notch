import Foundation
import Observation

/// The shell's view of the engine: the latest snapshot, kept up to date over
/// the socket, and the requests the shell can make. Reconnects on its own.
@MainActor
@Observable
public final class EngineClient {
  public private(set) var connected = false
  /// The engine's provider registry, in display order; empty until the
  /// first snapshot.
  public private(set) var providers: [ProviderInfo] = []
  public private(set) var readings: [UsageReading] = []
  public private(set) var sessions: [SessionState] = []
  public private(set) var chats: [ChatSummary] = []
  public private(set) var tokens: [TokenStats] = []
  public private(set) var dashboard = Dashboard()
  /// Whether the dashboard is on its way: a request is out and no answer has
  /// come yet.
  public private(set) var dashboardLoading = false
  /// Why the dashboard has no numbers to show: the request never reached the
  /// engine, or the engine stopped before answering. Empty once an answer
  /// arrives.
  public private(set) var dashboardError = ""
  public private(set) var copilotLogin: CopilotLogin?
  /// Claude's latest advice on usage, if one was asked for.
  public private(set) var analysis: UsageAnalysis?
  public private(set) var config = NotchConfig(raw: .object([:]))
  /// Whether a config has arrived from the engine yet.
  public private(set) var hasConfig = false

  // Peek: a session finished or asks for you, so the notch comes out.
  public private(set) var peekOpen = false
  public private(set) var peekProvider = ""
  public private(set) var peekKind = ""
  public private(set) var peekLabel = ""

  /// Called with the provider's display name and the session label.
  @ObservationIgnored public var onSessionFinished: ((String, String) -> Void)?
  @ObservationIgnored public var onSessionWaiting: ((String, String) -> Void)?
  @ObservationIgnored public var onLimitReached: ((LimitAlert) -> Void)?
  /// Called when the device code is ready, to copy it and open GitHub.
  @ObservationIgnored public var onCopilotCode: ((CopilotLogin) -> Void)?
  /// Called when a clicked chat's window is the shell's to bring forward.
  @ObservationIgnored public var onRaiseWindow: ((RaiseRequest) -> Void)?

  @ObservationIgnored private let socketPath: String
  @ObservationIgnored private var socket: LineSocket?
  @ObservationIgnored private var reconnect: Timer?
  @ObservationIgnored private var peekTimer: Timer?
  @ObservationIgnored private var dashboardDays = 30
  @ObservationIgnored private var dashboardSearch = ""
  @ObservationIgnored private var dashboardProject = ""
  @ObservationIgnored private var dashboardSession = ""
  /// The analysis this shell is waiting for; answers to anything else, or
  /// to a scope since left, are dropped.
  @ObservationIgnored private var analysisRequest = ""
  @ObservationIgnored private let encoder = JSONEncoder()

  public init(socketPath: String = EnginePaths.socket) {
    self.socketPath = socketPath
  }

  public func start() {
    tryConnect()
    reconnect = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated { self?.tryConnect() }
    }
  }

  // MARK: Lookups

  public var activeReadings: [UsageReading] { readings.filter { $0.status != "disabled" } }

  public func session(for provider: String) -> SessionState? {
    sessions.first { $0.provider == provider }
  }

  public func chats(for provider: String) -> [ChatSummary] {
    chats.filter { $0.provider == provider }
  }

  /// Finished chats you have not looked at yet, newest first.
  public var unreadChats: [ChatSummary] { chats.filter(\.isUnread) }

  public func unreadCount(for provider: String) -> Int {
    chats.filter { $0.provider == provider && $0.isUnread }.count
  }

  public func tokens(for provider: String) -> TokenStats? {
    tokens.first { $0.provider == provider }
  }

  public func reading(for provider: String) -> UsageReading? {
    activeReadings.first { $0.provider == provider }
  }

  public func displayName(_ provider: String) -> String {
    readings.first { $0.provider == provider }?.displayName ?? provider
  }

  // MARK: Requests

  public func refresh(_ provider: String? = nil) {
    var message: [String: JSONValue] = ["type": .string("refresh")]
    if let provider { message["provider"] = .string(provider) }
    send(.object(message))
  }

  /// Asks for the dashboard over `days`, with the search it has now.
  public func requestDashboard(days: Int = 30) {
    let days = min(90, max(7, days))
    if days != dashboardDays { clearAnalysis() }
    dashboardDays = days
    guard connected else {
      // The request would be dropped in silence and the page would keep
      // saying "Loading…" forever; say why instead.
      dashboardLoading = false
      dashboardError = "The engine is not running, so there are no numbers to show."
      return
    }
    dashboardError = ""
    dashboardLoading = true
    var message: [String: JSONValue] = [
      "type": .string("get_dashboard"), "days": .number(Double(dashboardDays)),
    ]
    if !dashboardSearch.isEmpty { message["search"] = .string(dashboardSearch) }
    if !dashboardProject.isEmpty { message["project"] = .string(dashboardProject) }
    if !dashboardSession.isEmpty { message["session"] = .string(dashboardSession) }
    send(.object(message))
  }

  /// Narrows the whole dashboard to one project's sessions; empty for all.
  public func setDashboardProject(_ project: String) {
    guard project != dashboardProject else { return }
    clearAnalysis()
    dashboardProject = project
    requestDashboard(days: dashboardDays)
  }

  /// Asks Claude, through the user's own `claude`, for advice on what the
  /// dashboard shows now. Only numbers are sent.
  public func analyzeUsage(model: String) {
    guard connected, socket != nil else {
      analysis = UsageAnalysis(state: "failed", model: model, text: "The engine is not running.")
      return
    }
    analysisRequest = String(UUID().uuidString.prefix(8))
    var message: [String: JSONValue] = [
      "type": .string("analyze_usage"), "days": .number(Double(dashboardDays)), "model": .string(model),
      "request": .string(analysisRequest),
    ]
    for (key, value) in [("search", dashboardSearch), ("project", dashboardProject), ("session", dashboardSession)]
    where !value.isEmpty {
      message[key] = .string(value)
    }
    analysis = UsageAnalysis(state: "running", model: model, text: "", request: analysisRequest)
    send(.object(message))
  }

  /// Advice belongs to the numbers it was asked about; they changed.
  private func clearAnalysis() {
    analysisRequest = ""
    if analysis != nil { analysis = nil }
  }

  /// Narrows the dashboard's numbers to one session, by id; empty for all.
  public func setDashboardSession(_ session: String) {
    guard session != dashboardSession else { return }
    clearAnalysis()
    dashboardSession = session
    requestDashboard(days: dashboardDays)
  }

  /// Narrows the whole dashboard to the sessions carrying every word; every
  /// later request keeps the search until it changes.
  public func searchDashboard(_ search: String) {
    let search = DashboardData.searchWords(search).joined(separator: " ")
    guard search != dashboardSearch else { return }
    clearAnalysis()
    dashboardSearch = search
    requestDashboard(days: dashboardDays)
  }

  public func openChat(_ chat: ChatSummary) {
    openChat(provider: chat.provider, id: chat.id, cwd: chat.cwd, title: chat.title, surface: chat.surface)
  }

  public func openChat(_ session: SessionCost) {
    openChat(
      provider: session.provider, id: session.id, cwd: session.cwd, title: session.title,
      surface: session.surface)
  }

  public func openChat(_ bot: BotUsage) {
    openChat(provider: "grok_bot", id: bot.id, cwd: nil, title: bot.name, surface: nil)
  }

  private func openChat(provider: String, id: String, cwd: String?, title: String?, surface: String?) {
    var message: [String: JSONValue] = [
      "type": .string("open_chat"), "provider": .string(provider), "id": .string(id),
    ]
    for (key, value) in [("cwd", cwd), ("title", title), ("surface", surface)] {
      if let value, !value.isEmpty { message[key] = .string(value) }
    }
    send(.object(message))
  }

  /// The window in front: the pid of the app that owns it and its title.
  public func windowFocused(pid: Int32, title: String?) {
    var message: [String: JSONValue] = ["type": .string("window_focused"), "pid": .number(Double(pid))]
    if let title, !title.isEmpty { message["title"] = .string(title) }
    send(.object(message))
  }

  public func copilotSignIn() {
    copilotLogin = CopilotLogin(state: "starting")
    send(.object(["type": .string("copilot_sign_in")]))
  }

  /// Changes the config here at once and has the engine persist it.
  public func updateConfig(_ change: (inout NotchConfig) -> Void) {
    var next = config
    change(&next)
    guard next != config else { return }
    config = next
    send(.object(["type": .string("set_config"), "config": next.raw]))
  }

  // MARK: Connection

  private func tryConnect() {
    guard socket == nil, let socket = LineSocket(path: socketPath) else { return }
    self.socket = socket
    socket.onLine = { [weak self] line in
      MainActor.assumeIsolated { self?.receive(line) }
    }
    socket.onClose = { [weak self] in
      MainActor.assumeIsolated { self?.disconnected() }
    }
    connected = true
    send(.object(["type": .string("hello"), "client": .string("macos"), "version": .number(1)]))
    send(.object(["type": .string("subscribe")]))
    // The page asked while the engine was away; ask again now that it is here.
    if !dashboardError.isEmpty { requestDashboard(days: dashboardDays) }
  }

  private func disconnected() {
    socket = nil
    connected = false
    // The answer would come on this connection; it will not now.
    if dashboardLoading {
      dashboardLoading = false
      dashboardError = "The engine stopped before the numbers arrived."
    }
    if analysis?.state == "running" {
      analysis?.state = "failed"
      analysis?.text = "Lost the engine before Claude answered. Ask again."
      analysisRequest = ""
    }
  }

  private func send(_ message: JSONValue) {
    guard let socket, let data = try? encoder.encode(message) else { return }
    socket.send(data)
  }

  private func receive(_ line: Data) {
    guard let message = try? ServerMessage.decode(line) else { return }
    apply(message)
  }

  /// Applies one message from the engine. Public for tests.
  public func apply(_ message: ServerMessage) {
    switch message {
    case .snapshot(let providers, let readings, let sessions, let chats, let tokens, let config):
      self.providers = providers
      self.readings = readings
      self.sessions = sessions
      self.chats = chats
      self.tokens = tokens
      applyConfig(config)
    case .activityUpdated(let chats, let tokens):
      self.chats = chats
      self.tokens = tokens
    case .usageUpdated(let reading):
      if let i = readings.firstIndex(where: { $0.provider == reading.provider }) {
        readings[i] = reading
      } else {
        readings.append(reading)
      }
    case .sessionUpdated(let session):
      if let i = sessions.firstIndex(where: { $0.provider == session.provider }) {
        sessions[i] = session
      } else {
        sessions.append(session)
      }
    // The provider's own state arrives as `session_updated`; these are about
    // one session, to be announced.
    case .sessionFinished(let session):
      triggerPeek(session.provider, label: session.label ?? "", kind: "finished")
      onSessionFinished?(displayName(session.provider), session.label ?? "")
    case .sessionWaiting(let session):
      triggerPeek(session.provider, label: session.label ?? "", kind: "waiting_you")
      onSessionWaiting?(displayName(session.provider), session.label ?? "")
    case .limitReached(let limit):
      triggerPeek(
        limit.provider, label: Format.limitBanner(limit),
        kind: limit.threshold >= 100 ? "limit_reached" : "limit")
      onLimitReached?(limit)
    case .configUpdated(let config):
      applyConfig(config)
    case .dashboard(let dashboard):
      dashboardLoading = false
      dashboardError = ""
      self.dashboard = dashboard
    case .copilotLogin(let login):
      copilotLogin = login
      if login.state == "pending" { onCopilotCode?(login) }
    case .raiseWindow(let request):
      onRaiseWindow?(request)
    case .usageAnalysis(let answer):
      // Only an answer to what this shell asked, for the numbers in view.
      guard !analysisRequest.isEmpty, answer.request == analysisRequest else { break }
      analysis = answer
      if answer.state != "running" { analysisRequest = "" }
    case .hello, .pong, .error, .unknown:
      break
    }
  }

  private func applyConfig(_ raw: JSONValue) {
    guard case .object(let object) = raw, !object.isEmpty else { return }
    config = NotchConfig(raw: raw)
    hasConfig = true
  }

  private func triggerPeek(_ provider: String, label: String, kind: String) {
    guard config.alertsEnabled, config.opensNotch(for: kind) else { return }
    peekProvider = provider
    peekLabel = label
    peekKind = kind
    peekOpen = true
    peekTimer?.invalidate()
    peekTimer = Timer.scheduledTimer(
      withTimeInterval: TimeInterval(max(1, config.peekSeconds)), repeats: false
    ) { [weak self] _ in
      MainActor.assumeIsolated { self?.peekOpen = false }
    }
  }
}
