import Foundation

/// The dashboard's series colours: a named palette, with any series given its
/// own colour in Settings. Mirrors `DASHBOARD_PALETTES` in the engine's config.
public enum DashboardPalette {
  /// How many series get a colour of their own; later ones reuse the last.
  public static let series = 6

  public static let names = ["mono", "vivid", "colorblind"]

  public static func label(_ name: String) -> String {
    switch name {
    case "vivid": return "Vivid"
    case "colorblind": return "Colour-blind safe"
    default: return "Monochrome"
    }
  }

  /// A palette's colours, first series first; an unknown name is `mono`.
  public static func colors(_ name: String) -> [String] {
    switch name {
    // Distinct hues, light enough to read on the dark panel.
    case "vivid": return ["#5B9BFF", "#FF8A3D", "#43D9AD", "#E86BD0", "#F2D04B", "#9C8CFF"]
    // Okabe–Ito, ordered so neighbours differ the most.
    case "colorblind": return ["#E69F00", "#56B4E9", "#009E73", "#F0E442", "#CC79A7", "#0072B2"]
    // Brightest first: the biggest share gets the most ink.
    default: return ["#F2F2F5", "#B4B4BE", "#808089", "#5C5C66", "#44444D", "#33333B"]
    }
  }

  /// The colours the dashboard draws with: the palette's, with each colour
  /// set in Settings in its place.
  public static func shades(_ config: NotchConfig) -> [String] {
    let overrides = config.dashboardColors
    return colors(config.dashboardPalette).enumerated().map { index, color in
      index < overrides.count && !overrides[index].isEmpty ? overrides[index] : color
    }
  }
}
