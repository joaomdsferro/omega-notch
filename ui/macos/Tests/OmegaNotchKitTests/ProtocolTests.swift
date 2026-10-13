import Foundation
import XCTest

@testable import OmegaNotchKit

final class ProtocolTests: XCTestCase {
  /// protocol/fixtures, written by the engine's own tests.
  static let fixtures = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()  // OmegaNotchKitTests
    .deletingLastPathComponent()  // Tests
    .deletingLastPathComponent()  // macos
    .deletingLastPathComponent()  // ui
    .deletingLastPathComponent()  // repository
    .appendingPathComponent("protocol/fixtures")

  func fixture(_ name: String) throws -> ServerMessage {
    let data = try Data(contentsOf: Self.fixtures.appendingPathComponent("\(name).json"))
    return try ServerMessage.decode(data)
  }

  func testEveryFixtureDecodesToAKnownMessage() throws {
    let names = try FileManager.default.contentsOfDirectory(atPath: Self.fixtures.path)
      .filter { $0.hasSuffix(".json") }
    XCTAssertGreaterThanOrEqual(names.count, 12)
    for name in names {
      let message = try fixture(String(name.dropLast(5)))
      if case .unknown(let type) = message { XCTFail("\(name) decoded as unknown \(type)") }
    }
  }

  func testSnapshot() throws {
    guard
      case .snapshot(let readings, let sessions, let chats, let tokens, let config) =
        try fixture("snapshot")
    else { return XCTFail("not a snapshot") }

    let reading = try XCTUnwrap(readings.first)
    XCTAssertEqual(reading.provider, "claude_code")
    XCTAssertEqual(reading.windows.count, 2)
    XCTAssertEqual(reading.headlinePct, 45)
    XCTAssertNotNil(reading.windows[0].resetsAt)
    XCTAssertNil(reading.windows[1].resetsAt)

    XCTAssertEqual(sessions.first?.kind, .busy)

    let chat = try XCTUnwrap(chats.first)
    XCTAssertEqual(chat.state, .busy)
    XCTAssertTrue(chat.live)
    XCTAssertEqual(chat.tokens?.cacheRead, 3_357_968)
    XCTAssertEqual(chat.linesAdded, 120)

    XCTAssertEqual(tokens.first?.modelsToday.first?.model, "Opus 5.5")
    XCTAssertEqual(NotchConfig(raw: config).edge, "right")
  }

  func testDashboardAndCopilotLogin() throws {
    guard case .dashboard(let dashboard) = try fixture("dashboard") else {
      return XCTFail("not a dashboard")
    }
    XCTAssertEqual(dashboard.totalUsd, 1.27)
    XCTAssertEqual(dashboard.models.first?.costUsd, 1.27)

    guard case .copilotLogin(let login) = try fixture("copilot_login") else {
      return XCTFail("not a login")
    }
    XCTAssertEqual(login.state, "pending")
    XCTAssertEqual(login.userCode, "ABCD-1234")
  }

  func testLimitReached() throws {
    guard case .limitReached(let limit) = try fixture("limit_reached") else {
      return XCTFail("not a limit_reached")
    }
    XCTAssertEqual(limit.provider, "claude_code")
    XCTAssertEqual(limit.label, "Current session")
    XCTAssertEqual(limit.threshold, 80)
    XCTAssertEqual(limit.usedPct, 81.5)
    XCTAssertNotNil(limit.resetsAt)
  }

  func testRaiseWindowAndItsTty() throws {
    guard case .raiseWindow(let request) = try fixture("raise_window") else {
      return XCTFail("not a raise_window")
    }
    XCTAssertEqual(request.pids.first, 4242)
    XCTAssertEqual(request.hints.first, "omega-notch")
    XCTAssertEqual(request.safeTty, "/dev/ttys003")

    var odd = request
    for tty in ["/dev/ttys", "/dev/ttys1\" & do shell script \"x", "/dev/pts/3", "ttys003"] {
      odd.tty = tty
      XCTAssertNil(odd.safeTty, tty)
    }
  }

  func testDatesWithNanoseconds() {
    XCTAssertNotNil(ServerMessage.parseDate("2026-10-12T13:50:00.149964Z"))
    XCTAssertNotNil(ServerMessage.parseDate("2026-10-12T13:50:00.149964123+00:00"))
    XCTAssertNotNil(ServerMessage.parseDate("2026-10-12T13:50:00Z"))
    XCTAssertNil(ServerMessage.parseDate("yesterday"))
  }

  func testConfigKeepsFieldsItDoesNotKnow() throws {
    let raw = try JSONDecoder().decode(
      JSONValue.self,
      from: Data(#"{"edge":"top","accent":"plasma","future":{"x":1},"max_providers":2}"#.utf8))
    var config = NotchConfig(raw: raw)
    config.edge = "left"
    config.maxProviders = 9
    config.setProvider("codex", enabled: false)
    config.notchColor = "not a colour"

    XCTAssertEqual(config.raw["future"], .object(["x": .number(1)]))
    XCTAssertEqual(config.raw["accent"], .string("plasma"))
    XCTAssertEqual(config.edge, "left")
    XCTAssertEqual(config.maxProviders, 5)
    XCTAssertFalse(config.providerEnabled("codex"))
    XCTAssertTrue(config.providerEnabled("cursor"))
    XCTAssertEqual(config.notchColor, "#000000")

    // Whole numbers go back as integers, which the engine needs for u32 fields.
    let encoded = String(decoding: try JSONEncoder().encode(config.raw), as: UTF8.self)
    XCTAssertTrue(encoded.contains(#""max_providers":5"#), encoded)
  }
}
