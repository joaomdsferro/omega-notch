import Foundation
import XCTest

@testable import OmegaNotchKit

final class DashboardDataTests: XCTestCase {
  func testRangeEndsTodayAndSkipsNoDayAcrossDst() {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Europe/Lisbon")!
    // 26 Oct 2026, the day after clocks go back in Lisbon.
    let now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 26, hour: 0, minute: 30))!
    let dates = DashboardData.rangeDates(days: 3, now: now, calendar: calendar)
    XCTAssertEqual(dates, ["2026-10-24", "2026-10-25", "2026-10-26"])
  }

  func testStackOrdersLargestFirstAndFoldsTheRest() {
    let dates = ["2026-10-01", "2026-10-02"]
    let entries = ["a": 50.0, "b": 40, "c": 30, "d": 20, "e": 10].flatMap { key, value in
      [DashboardData.Entry(date: "2026-10-01", key: key, value: value)]
    } + [DashboardData.Entry(date: "2026-10-02", key: "a", value: 5)]

    let stack = DashboardData.stack(entries, dates: dates, limit: 3) { $0.uppercased() }
    XCTAssertEqual(stack.series.map(\.key), ["a", "b", DashboardData.otherKey])
    XCTAssertEqual(stack.series.map(\.label), ["A", "B", "Other (3)"])
    XCTAssertEqual(stack.series.last?.total, 60)
    XCTAssertEqual(stack.series.last?.shade, DashboardData.shadeCount - 1)
    XCTAssertEqual(stack.days.map(\.total), [150, 5])
    XCTAssertEqual(stack.days[0].values[DashboardData.otherKey], 60)
    XCTAssertEqual(stack.total, 155)
  }

  func testQuietDaysStillGetASlot() {
    let stack = DashboardData.stack(
      [DashboardData.Entry(date: "2026-10-02", key: "a", value: 1)],
      dates: ["2026-10-01", "2026-10-02", "2026-10-03"]
    ) { $0 }
    XCTAssertEqual(stack.days.map(\.total), [0, 1, 0])
  }

  func testModelRowsDearestFirst() {
    func point(_ date: String, _ model: String, _ total: Double, _ cost: Double) -> ModelDayPoint {
      ModelDayPoint(
        provider: "claude_code", date: date, model: model, input: 0, output: 0, cacheRead: 0,
        cacheWrite: 0, total: total, costUsd: cost)
    }
    let rows = DashboardData.modelRows(
      [
        point("2026-10-01", "Sonnet", 100, 0.5),
        point("2026-10-01", "Opus", 50, 2),
        point("2026-10-02", "Opus", 10, 1),
      ], dates: ["2026-10-01", "2026-10-02"])
    XCTAssertEqual(rows.map(\.model), ["Opus", "Sonnet"])
    XCTAssertEqual(rows[0].cost, 3)
    XCTAssertEqual(rows[0].activeDays, 2)
    XCTAssertEqual(rows[0].daily, [50, 10])
  }
}
