import Foundation

// The engine's IPC protocol (protocol/README.md), as Swift types. Fields
// follow the JSON names through `convertFromSnakeCase`; anything optional on
// the Rust side is optional here, so an older or newer engine still decodes.

public let supportedProtocol = 6

public enum SessionKind: String, Codable, Sendable {
  case idle
  case busy
  case waitingYou = "waiting_you"
}

public struct UsageWindow: Codable, Equatable, Sendable {
  public var label: String
  public var usedPct: Double
  public var resetsAt: Date?
}

public struct UsageReading: Codable, Equatable, Sendable, Identifiable {
  public var provider: String
  public var displayName: String
  public var fidelity: String
  public var status: String
  public var windows: [UsageWindow]
  public var fetchedAt: Date?
  public var message: String?

  public var id: String { provider }
  /// Something to draw: a limit, from a reading that is current or merely old.
  public var hasData: Bool { !windows.isEmpty && (status == "ok" || status == "stale") }
  public var headlinePct: Double { hasData ? windows[0].usedPct : 0 }
}

public struct SessionState: Codable, Equatable, Sendable {
  public var provider: String
  public var kind: SessionKind
  public var label: String?
  public var updatedAt: Date?
}

/// A provider's headline window passing 80% or reaching 100% (v5).
public struct LimitAlert: Codable, Equatable, Sendable {
  public var provider: String
  public var displayName: String
  /// The window's own name, such as "Current session".
  public var label: String
  public var usedPct: Double
  public var threshold: Int
  public var resetsAt: Date?
}

public struct TokenTotals: Codable, Equatable, Sendable {
  public var input: Double
  public var output: Double
  public var cacheRead: Double
  public var cacheWrite: Double

  public init(input: Double = 0, output: Double = 0, cacheRead: Double = 0, cacheWrite: Double = 0) {
    self.input = input
    self.output = output
    self.cacheRead = cacheRead
    self.cacheWrite = cacheWrite
  }

  public var total: Double { input + output + cacheRead + cacheWrite }
}

public struct ChatSummary: Codable, Equatable, Sendable, Identifiable {
  public var provider: String
  public var id: String
  public var title: String
  public var project: String?
  public var cwd: String?
  public var model: String?
  public var surface: String?
  public var state: SessionKind
  public var live: Bool
  public var updatedAt: Date?
  public var messages: Int?
  public var tokens: TokenTotals?
  public var contextTokens: Double?
  public var contextPct: Double?
  public var linesAdded: Int?
  public var linesRemoved: Int?
  /// Stopped with a reply you have not looked at yet (v6).
  public var unread: Bool?

  public var isUnread: Bool { unread ?? false }
}

public struct DayTokens: Codable, Equatable, Sendable {
  public var date: String
  public var total: Double
}

public struct ModelTokens: Codable, Equatable, Sendable {
  public var model: String
  public var total: Double
}

public struct TokenStats: Codable, Equatable, Sendable {
  public var provider: String
  public var today: TokenTotals
  public var week: TokenTotals
  public var daily: [DayTokens]
  public var modelsToday: [ModelTokens]
}

public struct HistoryPoint: Codable, Equatable, Sendable {
  public var provider: String
  public var date: String
  public var input: Double
  public var output: Double
  public var cacheRead: Double
  public var cacheWrite: Double
  public var total: Double
}

public struct ModelDayPoint: Codable, Equatable, Sendable {
  public var provider: String
  public var date: String
  public var model: String
  public var input: Double
  public var output: Double
  public var cacheRead: Double
  public var cacheWrite: Double
  public var total: Double
  public var costUsd: Double
}

public struct CostEstimate: Codable, Equatable, Sendable {
  public var provider: String
  public var model: String
  public var total: Double
  public var costUsd: Double
}

public struct SessionModelCost: Codable, Equatable, Sendable, Identifiable {
  public var model: String
  public var input: Double
  public var output: Double
  public var cacheRead: Double
  public var cacheWrite: Double
  public var total: Double
  public var costUsd: Double

  public var id: String { model }
}

/// One project's Claude Code sessions over the dashboard range.
public struct ProjectCost: Decodable, Equatable, Sendable, Identifiable {
  public var provider: String
  /// The folder's name, as sessions carry it.
  public var project: String
  public var sessions: Int
  public var total: Double
  public var costUsd: Double

  public var id: String { provider + ":" + project }
}

/// One session's spend over the dashboard range, split by model (v6).
public struct SessionCost: Codable, Equatable, Sendable, Identifiable {
  public var provider: String
  public var id: String
  public var title: String
  public var project: String?
  public var cwd: String?
  public var surface: String?
  /// Last day in the range with tokens, `yyyy-MM-dd`.
  public var lastDate: String
  public var input: Double
  public var output: Double
  public var cacheRead: Double
  public var cacheWrite: Double
  public var total: Double
  public var costUsd: Double
  /// Dearest first.
  public var models: [SessionModelCost]
}

public struct Dashboard: Equatable, Sendable {
  public var points: [HistoryPoint] = []
  public var costs: [CostEstimate] = []
  public var models: [ModelDayPoint] = []
  /// The range's dearest sessions, dearest first (v6); with a search, the
  /// range's sessions that match it.
  public var sessions: [SessionCost] = []
  /// The search everything answers, as the engine read it; empty for none.
  public var search = ""
  /// The project everything answers; empty for none.
  public var project = ""
  /// Every project in the range, dearest first, to narrow to.
  public var projects: [ProjectCost] = []

  /// Whether the numbers are narrowed to a project or a search, so they come
  /// from Claude Code's sessions alone.
  public var isScoped: Bool { !search.isEmpty || !project.isEmpty }
  public var totalUsd: Double = 0

  public init() {}
}

/// GitHub's device flow, as the engine reports it.
public struct CopilotLogin: Codable, Equatable, Sendable {
  /// `starting` is the shell's own, until the engine answers; then `pending`,
  /// `signed_in` or `failed`.
  public var state: String
  public var userCode: String?
  public var verificationUri: String?
  public var message: String?

  public init(state: String) { self.state = state }
}

/// Which window to bring forward for a chat in a live session.
public struct RaiseRequest: Codable, Equatable, Sendable {
  /// The session's process and its parents, nearest first.
  public var pids: [Int32]
  /// Words the window's title may carry, best first.
  public var hints: [String]
  /// The session's terminal, such as `/dev/ttys003`.
  public var tty: String?

  /// Only a real terminal device: it ends up in a script.
  public var safeTty: String? {
    guard let tty, tty.hasPrefix("/dev/ttys"), tty.dropFirst(9).allSatisfy(\.isNumber),
      tty.count > 9
    else { return nil }
    return tty
  }
}

public enum ServerMessage: Sendable {
  case hello(protocol: Int)
  case snapshot(
    readings: [UsageReading], sessions: [SessionState], chats: [ChatSummary],
    tokens: [TokenStats], config: JSONValue)
  case activityUpdated(chats: [ChatSummary], tokens: [TokenStats])
  case usageUpdated(UsageReading)
  case sessionUpdated(SessionState)
  case sessionFinished(SessionState)
  case sessionWaiting(SessionState)
  /// A usage threshold passed, to be announced (v5).
  case limitReached(LimitAlert)
  case configUpdated(JSONValue)
  case dashboard(Dashboard)
  case copilotLogin(CopilotLogin)
  /// The chat runs in a live session: pick its window (v4).
  case raiseWindow(RaiseRequest)
  case pong
  case error(String)
  /// A message this shell does not know; ignored.
  case unknown(String)
}

extension ServerMessage {
  public static let decoder: JSONDecoder = {
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    decoder.dateDecodingStrategy = .custom { decoder in
      let raw = try decoder.singleValueContainer().decode(String.self)
      guard let date = parseDate(raw) else {
        throw DecodingError.dataCorrupted(
          .init(codingPath: decoder.codingPath, debugDescription: "not a date: \(raw)"))
      }
      return date
    }
    return decoder
  }()

  /// chrono writes RFC 3339 with anything from no fraction to nanoseconds.
  static func parseDate(_ raw: String) -> Date? {
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = fractional.date(from: raw) { return date }
    let plain = ISO8601DateFormatter()
    plain.formatOptions = [.withInternetDateTime]
    if let date = plain.date(from: raw) { return date }
    // More than three fraction digits: trim to milliseconds and try again.
    if let dot = raw.firstIndex(of: "."),
      let end = raw[dot...].firstIndex(where: { !$0.isNumber && $0 != "." })
    {
      let digits = raw[raw.index(after: dot)..<end]
      let trimmed = raw[..<dot] + "." + digits.prefix(3) + raw[end...]
      return fractional.date(from: String(trimmed))
    }
    return nil
  }

  private struct Envelope: Decodable { var type: String }
  private struct Snapshot: Decodable {
    var readings: [UsageReading]
    var sessions: [SessionState]
    var chats: [ChatSummary]
    var tokens: [TokenStats]
    var config: JSONValue
  }
  private struct Activity: Decodable {
    var chats: [ChatSummary]
    var tokens: [TokenStats]
  }
  private struct ReadingBody: Decodable { var reading: UsageReading }
  private struct SessionBody: Decodable { var session: SessionState }
  private struct LimitBody: Decodable { var limit: LimitAlert }
  private struct ConfigBody: Decodable { var config: JSONValue }
  private struct HelloBody: Decodable { var `protocol`: Int }
  private struct ErrorBody: Decodable { var message: String }
  private struct LoginBody: Decodable { var login: CopilotLogin }
  private struct DashboardBody: Decodable {
    var points: [HistoryPoint]
    var costs: [CostEstimate]
    var models: [ModelDayPoint]?
    var sessions: [SessionCost]?
    var search: String?
    var project: String?
    var projects: [ProjectCost]?
    var totalUsd: Double
  }

  public static func decode(_ line: Data) throws -> ServerMessage {
    let d = decoder
    let type = try d.decode(Envelope.self, from: line).type
    switch type {
    case "hello":
      return .hello(protocol: try d.decode(HelloBody.self, from: line).protocol)
    case "snapshot":
      let s = try d.decode(Snapshot.self, from: line)
      return .snapshot(
        readings: s.readings, sessions: s.sessions, chats: s.chats, tokens: s.tokens,
        config: s.config)
    case "activity_updated":
      let a = try d.decode(Activity.self, from: line)
      return .activityUpdated(chats: a.chats, tokens: a.tokens)
    case "usage_updated":
      return .usageUpdated(try d.decode(ReadingBody.self, from: line).reading)
    case "session_updated":
      return .sessionUpdated(try d.decode(SessionBody.self, from: line).session)
    case "session_finished":
      return .sessionFinished(try d.decode(SessionBody.self, from: line).session)
    case "session_waiting":
      return .sessionWaiting(try d.decode(SessionBody.self, from: line).session)
    case "limit_reached":
      return .limitReached(try d.decode(LimitBody.self, from: line).limit)
    case "config_updated":
      return .configUpdated(try d.decode(ConfigBody.self, from: line).config)
    case "dashboard":
      let body = try d.decode(DashboardBody.self, from: line)
      var dashboard = Dashboard()
      dashboard.points = body.points
      dashboard.costs = body.costs
      dashboard.models = body.models ?? []
      dashboard.sessions = body.sessions ?? []
      dashboard.search = body.search ?? ""
      dashboard.project = body.project ?? ""
      dashboard.projects = body.projects ?? []
      dashboard.totalUsd = body.totalUsd
      return .dashboard(dashboard)
    case "copilot_login":
      return .copilotLogin(try d.decode(LoginBody.self, from: line).login)
    case "raise_window":
      return .raiseWindow(try d.decode(RaiseRequest.self, from: line))
    case "pong":
      return .pong
    case "error":
      return .error(try d.decode(ErrorBody.self, from: line).message)
    default:
      return .unknown(type)
    }
  }
}
