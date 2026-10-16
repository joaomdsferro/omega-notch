import Foundation
import XCTest

@testable import OmegaNotchKit

final class DashboardPaletteTests: XCTestCase {
  private func config(_ json: String) -> NotchConfig {
    NotchConfig(raw: try! JSONDecoder().decode(JSONValue.self, from: Data(json.utf8)))
  }

  func testEveryPaletteColoursEverySeries() {
    for name in DashboardPalette.names {
      let colors = DashboardPalette.colors(name)
      XCTAssertEqual(colors.count, DashboardPalette.series, name)
      XCTAssertTrue(colors.allSatisfy(NotchConfig.isHexColor), name)
      XCTAssertEqual(Set(colors).count, colors.count, name)
    }
  }

  func testAnOlderConfigKeepsTheGreys() {
    let shades = DashboardPalette.shades(config("{}"))
    XCTAssertEqual(shades, DashboardPalette.colors("mono"))
    XCTAssertEqual(config(#"{"dashboard_palette":"rainbow"}"#).dashboardPalette, "mono")
  }

  func testAColourSetInSettingsReplacesOnlyItsSeries() {
    var c = config(##"{"dashboard_palette":"vivid","dashboard_colors":["", "#ff0000", "nope"]}"##)
    var shades = DashboardPalette.shades(c)
    let vivid = DashboardPalette.colors("vivid")
    XCTAssertEqual(shades[0], vivid[0])
    XCTAssertEqual(shades[1], "#FF0000")
    XCTAssertEqual(shades[2], vivid[2])

    c.setDashboardColor(4, "#00ff00")
    c.setDashboardColor(1, nil)
    shades = DashboardPalette.shades(c)
    XCTAssertEqual(shades[1], vivid[1])
    XCTAssertEqual(shades[4], "#00FF00")
    XCTAssertEqual(c.dashboardColors, ["", "", "", "", "#00FF00"])

    // Out of range or not a colour: nothing changes.
    c.setDashboardColor(6, "#123456")
    c.setDashboardColor(0, "blue")
    XCTAssertEqual(c.dashboardColors, ["", "", "", "", "#00FF00"])

    c.setDashboardColor(4, nil)
    XCTAssertEqual(c.dashboardColors, [])
  }
}
