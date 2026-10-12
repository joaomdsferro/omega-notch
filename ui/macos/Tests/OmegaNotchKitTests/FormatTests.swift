import CoreGraphics
import Foundation
import XCTest

@testable import OmegaNotchKit

final class FormatTests: XCTestCase {
  func testTokens() {
    XCTAssertEqual(Format.tokens(412), "412")
    XCTAssertEqual(Format.tokens(282_472), "282K")
    XCTAssertEqual(Format.tokens(35_144_356), "35.1M")
    XCTAssertEqual(Format.tokens(2_000_000), "2M")
    XCTAssertEqual(Format.tokens(1_500_000_000), "1.5B")
  }

  func testUsd() {
    XCTAssertEqual(Format.usd(13.2), "$13.20")
    XCTAssertEqual(Format.usd(0.004), "<$0.01")
    XCTAssertEqual(Format.usd(0), "$0.00")
    XCTAssertEqual(Format.usd(1234.5), "$1,235")
  }

  func testNiceCeil() {
    XCTAssertEqual(Format.niceCeil(0), 1)
    XCTAssertEqual(Format.niceCeil(7), 8)
    XCTAssertEqual(Format.niceCeil(110), 150)
    XCTAssertEqual(Format.niceCeil(4_100_000), 5_000_000)
  }

  func testAgoAndResets() {
    let now = Date(timeIntervalSince1970: 1_000_000)
    XCTAssertEqual(Format.ago(now.addingTimeInterval(-30), now: now), "now")
    XCTAssertEqual(Format.ago(now.addingTimeInterval(-4 * 60), now: now), "4m")
    XCTAssertEqual(Format.ago(now.addingTimeInterval(-3 * 3600), now: now), "3h")
    XCTAssertEqual(Format.ago(now.addingTimeInterval(-2 * 86400), now: now), "2d")
    XCTAssertEqual(Format.resetsIn(now.addingTimeInterval(-1), now: now), "Resets now")
    XCTAssertEqual(Format.resetsIn(now.addingTimeInterval(25 * 60), now: now), "Resets in 25 min")
    XCTAssertEqual(Format.resetsIn(now.addingTimeInterval(3 * 3600 + 5 * 60), now: now), "Resets in 3h 5m")
  }

  func testLevels() {
    XCTAssertEqual(Format.level(10), .ample)
    XCTAssertEqual(Format.level(75), .watch)
    XCTAssertEqual(Format.level(90), .critical)
  }

  func testSvgPathCommands() {
    // Relative and absolute lines, curves, an arc and numbers run together.
    let path = SVGPath.parse("M11.503.131 1.891 5.678a.84.84 0 0 0-.42.726v11.188c0 .3.162.575.42.724Z")
    let box = path.boundingBoxOfPath
    XCTAssertEqual(box.minX, 1.471, accuracy: 0.01)
    XCTAssertEqual(box.maxX, 11.503, accuracy: 0.01)
    XCTAssertEqual(box.minY, 0.131, accuracy: 0.01)
    XCTAssertEqual(box.maxY, 18.316, accuracy: 0.05)

    let arc = SVGPath.parse("M0 10 A10 10 0 0 1 20 10").boundingBoxOfPath
    XCTAssertEqual(arc.minY, 0, accuracy: 0.01)
    XCTAssertEqual(arc.maxX, 20, accuracy: 0.01)
  }

  func testEveryMarkFitsItsGrid() {
    for provider in ["claude_code", "claude_desktop", "cursor", "copilot", "codex", "grok_bot", "grok"] {
      let box = SVGPath.parse(ProviderMarks.path(provider)).boundingBoxOfPath
      XCTAssertGreaterThan(box.width, 10, provider)
      XCTAssertGreaterThanOrEqual(box.minX, -0.5, provider)
      XCTAssertLessThanOrEqual(box.maxX, 24.5, provider)
      XCTAssertGreaterThanOrEqual(box.minY, -0.5, provider)
      XCTAssertLessThanOrEqual(box.maxY, 24.5, provider)
    }
  }
}
