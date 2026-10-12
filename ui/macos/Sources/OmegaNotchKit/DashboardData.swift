import Foundation

/// The Dashboard's arithmetic, kept apart from its views so it can be tested:
/// the days of a range, daily stacks by series, and a row per model. The same
/// rules as the Plasma shell's DashboardWindow.qml.
public enum DashboardData {
  public struct Series: Equatable, Sendable {
    public var key: String
    public var label: String
    public var total: Double
    /// Index into the shades, brightest first.
    public var shade: Int
  }

  public struct Day: Equatable, Sendable {
    public var date: String
    public var total: Double
    public var values: [String: Double]
  }

  public struct Stack: Equatable, Sendable {
    public var series: [Series]
    public var days: [Day]
    public var total: Double
  }

  public struct Entry: Sendable {
    public var date: String
    public var key: String
    public var value: Double

    public init(date: String, key: String, value: Double) {
      self.date = date
      self.key = key
      self.value = value
    }
  }

  public static let otherKey = "__other"
  public static let shadeCount = 6

  /// `yyyy-MM-dd` in the local time zone.
  public static func isoDay(_ date: Date, calendar: Calendar = .current) -> String {
    let c = calendar.dateComponents([.year, .month, .day], from: date)
    return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
  }

  /// Every day of the range, oldest first, ending today. Steps from local
  /// noon so a DST change never skips or repeats a day.
  public static func rangeDates(days: Int, now: Date = Date(), calendar: Calendar = .current) -> [String] {
    let noon = calendar.date(bySettingHour: 12, minute: 0, second: 0, of: now) ?? now
    return (0..<max(1, days)).reversed().compactMap { back in
      calendar.date(byAdding: .day, value: -back, to: noon).map { isoDay($0, calendar: calendar) }
    }
  }

  /// One column per day of the range. Series are ordered largest first, so
  /// the biggest sits at the bottom in the brightest shade; past `limit`, the
  /// smallest fold into "Other".
  public static func stack(
    _ entries: [Entry], dates: [String], limit: Int = shadeCount, label: (String) -> String
  ) -> Stack {
    var totals: [String: Double] = [:]
    for entry in entries { totals[entry.key, default: 0] += entry.value }
    var keys = totals.filter { $0.value > 0 }.sorted { $0.value > $1.value || ($0.value == $1.value && $0.key < $1.key) }
      .map(\.key)
    var folded: [String] = []
    if keys.count > limit {
      folded = Array(keys[(limit - 1)...])
      keys = Array(keys[..<(limit - 1)])
    }
    let foldedSet = Set(folded)

    var byDate: [String: Day] = [:]
    for entry in entries {
      let key = foldedSet.contains(entry.key) ? otherKey : entry.key
      var day = byDate[entry.date] ?? Day(date: entry.date, total: 0, values: [:])
      day.values[key, default: 0] += entry.value
      day.total += entry.value
      byDate[entry.date] = day
    }

    var series = keys.enumerated().map { index, key in
      Series(key: key, label: label(key), total: totals[key] ?? 0, shade: index % shadeCount)
    }
    if !folded.isEmpty {
      series.append(
        Series(
          key: otherKey, label: "Other (\(folded.count))",
          total: folded.reduce(0) { $0 + (totals[$1] ?? 0) }, shade: shadeCount - 1))
    }
    let days = dates.map { byDate[$0] ?? Day(date: $0, total: 0, values: [:]) }
    return Stack(series: series, days: days, total: days.reduce(0) { $0 + $1.total })
  }

  public struct ModelRow: Equatable, Sendable, Identifiable {
    public var model: String
    public var provider: String
    public var total: Double
    public var cost: Double
    public var activeDays: Int
    /// Tokens per day of the range, oldest first.
    public var daily: [Double]
    public var id: String { model }
  }

  /// One row per model over the range, dearest first.
  public static func modelRows(_ points: [ModelDayPoint], dates: [String]) -> [ModelRow] {
    let index = Dictionary(uniqueKeysWithValues: dates.enumerated().map { ($1, $0) })
    var rows: [String: ModelRow] = [:]
    for point in points {
      var row =
        rows[point.model]
        ?? ModelRow(
          model: point.model, provider: point.provider, total: 0, cost: 0, activeDays: 0,
          daily: Array(repeating: 0, count: dates.count))
      row.total += point.total
      row.cost += point.costUsd
      if let at = index[point.date] {
        if row.daily[at] == 0 && point.total > 0 { row.activeDays += 1 }
        row.daily[at] += point.total
      }
      rows[point.model] = row
    }
    return rows.values.sorted { a, b in
      a.cost != b.cost ? a.cost > b.cost : a.total != b.total ? a.total > b.total : a.model < b.model
    }
  }
}
