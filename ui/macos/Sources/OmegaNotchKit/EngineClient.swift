import Foundation
import Observation

/// The shell's view of the engine: the latest snapshot, kept up to date over
/// the socket, and the requests the shell can make. Reconnects on its own.
@MainActor
@Observable
public final class EngineClient {
  public private(set) var connected = false
  public private(set) var readings: [UsageReading] = []
  public private(set) var sessions: [SessionState] = []
  public private(set) var chats: [ChatSummary] = []
  public private(set) var tokens: [TokenStats] = []
  public private(set) var dashboard = Dashboard()
  public private(set) var copilotLogin: CopilotLogin?
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

  public func requestDashboard(days: Int = 30) {
    send(.object(["type": .string("get_dashboard"), "days": .number(Double(min(90, max(7, days))))]))
  }

  public func openChat(_ chat: ChatSummary) {
    var message: [String: JSONValue] = [
      "type": .string("open_chat"), "provider": .string(chat.provider), "id": .string(chat.id),
    ]
    for (key, value) in [("cwd", chat.cwd), ("title", chat.title), ("surface", chat.surface)] {
      if let value, !value.isEmpty { message[key] = .string(value) }
    }
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
  }

  private func disconnected() {
    socket = nil
    connected = false
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
    case .snapshot(let readings, let sessions, let chats, let tokens, let config):
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
      self.dashboard = dashboard
    case .copilotLogin(let login):
      copilotLogin = login
      if login.state == "pending" { onCopilotCode?(login) }
    case .raiseWindow(let request):
      onRaiseWindow?(request)
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
