import Foundation
import XCTest

@testable import OmegaNotchKit

final class ThemeCatalogTests: XCTestCase {
  /// Every token every theme has to set, so a new theme cannot forget one.
  private let tokens = [
    "notch", "card", "cardStroke", "hairline", "track", "panel", "panelRaised",
    "panelHover", "text", "textSecondary", "textTertiary", "ample", "watch",
    "critical", "waiting", "unread", "busy", "accent", "botEye", "controlFill",
    "controlChosen", "controlHover",
  ]

  private func config(_ json: String) -> NotchConfig {
    NotchConfig(raw: try! JSONDecoder().decode(JSONValue.self, from: Data(json.utf8)))
  }

  func testEveryThemeSetsEveryToken() {
    for name in ThemeCatalog.names {
      let colors = ThemeCatalog.colors(name)
      XCTAssertEqual(colors.count, tokens.count, name)
      for token in tokens {
        let color = colors[token]
        XCTAssertNotNil(color, "\(name) has no \(token)")
        XCTAssertTrue(NotchConfig.isHexColor(color?.hex ?? ""), "\(name).\(token)")
        XCTAssertTrue((0...1).contains(color?.alpha ?? -1), "\(name).\(token)")
      }
    }
  }

  func testTheDefaultIsTheFirstTheme() {
    XCTAssertEqual(ThemeCatalog.defaultName, ThemeCatalog.names.first)
    XCTAssertEqual(ThemeCatalog.names.first, "noir")
  }

  func testAnUnknownThemeFallsBackToTheDefault() {
    XCTAssertNil(ThemeCatalog.colorsIfKnown("neon"))
    XCTAssertEqual(ThemeCatalog.colors("neon"), ThemeCatalog.colors("noir"))
    XCTAssertEqual(ThemeCatalog.label("neon"), ThemeCatalog.label("noir"))
  }

  func testTheFaintestInkReadsOnTheRaisedSurface() {
    // The ink of table heads and footnotes, on the surface they sit on:
    // at least 4.5:1, so the text is readable.
    for name in ThemeCatalog.names {
      let colors = ThemeCatalog.colors(name)
      guard let ink = colors["textTertiary"], let surface = colors["panelRaised"] else {
        return XCTFail("\(name) is missing a token")
      }
      let ratio = contrast(ink.hex, surface.hex)
      XCTAssertGreaterThanOrEqual(ratio, 4.5, "\(name) tertiary is \(ratio):1")
    }
  }

  func testUnreadIsNotTheColourOfPlentyOfQuota() {
    for name in ThemeCatalog.names where name != "classic" {
      let colors = ThemeCatalog.colors(name)
      XCTAssertNotEqual(colors["unread"]?.hex, colors["ample"]?.hex, name)
    }
  }

  func testTheConfigKeepsAKnownThemeAndForgetsAnUnknownOne() {
    XCTAssertEqual(config(#"{"theme":"clube"}"#).theme, "clube")
    XCTAssertEqual(config(#"{"theme":"neon"}"#).theme, "noir")
    // A config from before the setting has none at all.
    XCTAssertEqual(config("{}").theme, "noir")

    var c = config("{}")
    c.theme = "aurora"
    XCTAssertEqual(c.theme, "aurora")
    // An unknown name is not written.
    c.theme = "neon"
    XCTAssertEqual(c.theme, "aurora")
  }

  /// The WCAG contrast ratio between two hex colours.
  private func contrast(_ a: String, _ b: String) -> Double {
    func luminance(_ hex: String) -> Double {
      let value = UInt32(hex.dropFirst(), radix: 16) ?? 0
      let parts = [
        Double((value >> 16) & 0xFF) / 255, Double((value >> 8) & 0xFF) / 255,
        Double(value & 0xFF) / 255,
      ].map { $0 <= 0.03928 ? $0 / 12.92 : pow(($0 + 0.055) / 1.055, 2.4) }
      return 0.2126 * parts[0] + 0.7152 * parts[1] + 0.0722 * parts[2]
    }
    let first = luminance(a), second = luminance(b)
    return (max(first, second) + 0.05) / (min(first, second) + 0.05)
  }
}
