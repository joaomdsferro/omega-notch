import Foundation
import XCTest

@testable import OmegaNotchKit

final class NubMotionTests: XCTestCase {
  func testEveryMotionStartsAndLoopsAtRest() {
    for style in NubMotion.names where style != "wave" {
      XCTAssertEqual(NubMotion.pose(style, at: 0), .rest, style)
    }
    // A full shiver loop is 1.86 s; the next one starts from rest again.
    XCTAssertEqual(NubMotion.pose("shiver", at: 1.86 * 3), .rest)
  }

  func testUnknownOrStillStaysAtRest() {
    XCTAssertEqual(NubMotion.pose("none", at: 0.4), .rest)
    XCTAssertEqual(NubMotion.pose("wiggle", at: 0.4), .rest)
  }

  func testKeyframesLandOnTheirValues() {
    XCTAssertEqual(NubMotion.pose("shiver", at: 0.045, unit: 2).along, 3.2, accuracy: 1e-9)
    XCTAssertEqual(NubMotion.pose("breathe", at: 1.1).fade, 0.25, accuracy: 1e-9)
    XCTAssertEqual(NubMotion.pose("bounce", at: 0.17).depthScale, 2.2, accuracy: 1e-9)
    XCTAssertEqual(NubMotion.pose("stretch", at: 0.75).lengthScale, 1.9, accuracy: 1e-9)
    let beat = NubMotion.pose("pulse", at: 0.13)
    XCTAssertEqual(beat.lengthScale, 1.3, accuracy: 1e-9)
    XCTAssertEqual(beat.depthScale, 1.5, accuracy: 1e-9)
  }

  func testWaveGrowsThenKeepsRippling() {
    XCTAssertEqual(NubMotion.pose("wave", at: 0).wave, 0)
    let grown = NubMotion.pose("wave", at: 2)
    XCTAssertEqual(grown.wave, 0.28, accuracy: 1e-9)
    XCTAssertEqual(grown.lengthScale, 1.5, accuracy: 1e-9)
    XCTAssertNotEqual(grown.wavePhase, NubMotion.pose("wave", at: 2.3).wavePhase)
  }

  func testConfigFallsBackToTheEngineDefaults() throws {
    let raw = try JSONDecoder().decode(
      JSONValue.self, from: Data(#"{"nub_waiting":"wiggle"}"#.utf8))
    var config = NotchConfig(raw: raw)
    XCTAssertEqual(config.nubWorking, "shiver")
    XCTAssertEqual(config.nubWaiting, "pulse")

    config.nubWorking = "wave"
    config.nubWaiting = "nope"
    XCTAssertEqual(config.nubWorking, "wave")
    XCTAssertEqual(config.raw["nub_waiting"], .string("wiggle"))
  }
}
