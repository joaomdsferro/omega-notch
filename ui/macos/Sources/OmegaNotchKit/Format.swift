import Foundation

/// Copy formatting shared by the notch, its card and the dashboard; the same
/// rules as the Plasma shell's Theme.qml.
public enum Format {
  public static let watchAt = 75.0
  public static let criticalAt = 90.0

  public enum Level: Equatable { case ample, watch, critical }

  public static func level(_ pct: Double) -> Level {
    pct >= criticalAt ? .critical : pct >= watchAt ? .watch : .ample
  }

  /// 412 -> "412", 282472 -> "282K", 35144356 -> "35.1M"
  public static func tokens(_ n: Double) -> String {
    guard n >= 1000 else { return String(Int(max(0, n).rounded())) }
    for (size, unit) in [(1e9, "B"), (1e6, "M"), (1e3, "K")] where n >= size {
      let v = n / size
      if v >= 100 { return "\(Int(v.rounded()))\(unit)" }
      var text = String(format: "%.1f", v)
      if text.hasSuffix(".0") { text.removeLast(2) }
      return text + unit
    }
    return String(Int(n))
  }

  /// 13.2 -> "$13.20", 0.004 -> "<$0.01", 1234.5 -> "$1,235"
  public static func usd(_ v: Double) -> String {
    if v > 0 && v < 0.01 { return "<$0.01" }
    if v >= 1000 {
      let formatter = NumberFormatter()
      formatter.locale = Locale(identifier: "en_US")
      formatter.numberStyle = .decimal
      formatter.maximumFractionDigits = 0
      return "$" + (formatter.string(from: NSNumber(value: v.rounded())) ?? "\(Int(v))")
    }
    return String(format: "$%.2f", max(0, v))
  }

  /// A round number at or above n: 1, 1.5, 2, 2.5, 3, 4, 5, 6 or 8 times a
  /// power of ten.
  public static func niceCeil(_ n: Double) -> Double {
    guard n > 0 else { return 1 }
    let mag = pow(10, floor(log10(n)))
    for step in [1, 1.5, 2, 2.5, 3, 4, 5, 6, 8, 10] where step * mag >= n {
      return step * mag
    }
    return 10 * mag
  }

  /// "now", "4m", "3h", "2d", then a date.
  public static func ago(_ date: Date?, now: Date = Date()) -> String {
    guard let date else { return "" }
    let s = max(0, now.timeIntervalSince(date))
    if s < 60 { return "now" }
    if s < 3600 { return "\(Int(s / 60))m" }
    if s < 86400 { return "\(Int(s / 3600))h" }
    if s < 7 * 86400 { return "\(Int(s / 86400))d" }
    return formatted(date, "d MMM")
  }

  public static func resetsIn(_ date: Date?, now: Date = Date()) -> String {
    guard let date else { return "" }
    let mins = Int((date.timeIntervalSince(now) / 60).rounded())
    if mins <= 0 { return "Resets now" }
    if mins < 60 { return "Resets in \(mins) min" }
    let hours = mins / 60
    if hours < 24 { return "Resets in \(hours)h \(mins % 60)m" }
    if hours < 24 * 6 { return "Resets " + formatted(date, "EEE HH:mm") }
    return "Resets " + formatted(date, "d MMM")
  }

  /// The notification for a usage threshold: "Claude Code: 81% of Current
  /// session used. Resets in 2h 10m".
  public static func limitAlert(_ limit: LimitAlert, now: Date = Date()) -> String {
    let what = "\(limit.displayName): \(limitBanner(limit))"
    let reset = resetsIn(limit.resetsAt, now: now)
    return reset.isEmpty ? what : "\(what). \(reset)"
  }

  /// The same on the provider's card, which already names it: "81% of
  /// Current session used".
  public static func limitBanner(_ limit: LimitAlert) -> String {
    limit.threshold >= 100
      ? "\(limit.label) limit reached"
      : "\(Int(limit.usedPct.rounded(.down)))% of \(limit.label) used"
  }

  public static func formatted(_ date: Date, _ pattern: String) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = pattern
    return formatter.string(from: date)
  }

  /// One line under a chat's title: project, model, tokens, context, lines.
  public static func chatDetail(_ chat: ChatSummary) -> String {
    var parts: [String] = []
    if let project = chat.project, !project.isEmpty { parts.append(project) }
    if let model = chat.model, !model.isEmpty {
      parts.append(model)
    } else if let surface = chat.surface, !surface.isEmpty {
      parts.append(surface)
    }
    if let tokens = chat.tokens, tokens.total > 0 { parts.append(Self.tokens(tokens.total) + " tok") }
    if let pct = chat.contextPct { parts.append("\(Int(pct.rounded()))% ctx") }
    let added = chat.linesAdded ?? 0
    let removed = chat.linesRemoved ?? 0
    if added > 0 || removed > 0 { parts.append("+\(added) −\(removed)") }
    return parts.joined(separator: "  ·  ")
  }
}
