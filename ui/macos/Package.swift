// swift-tools-version: 5.10

import PackageDescription

let package = Package(
  name: "OmegaNotch",
  platforms: [.macOS(.v14)],
  products: [
    .executable(name: "OmegaNotch", targets: ["OmegaNotch"])
  ],
  dependencies: [
    // Updates for the downloaded app. Pinned: a new version is a deliberate
    // change, checked like any other.
    .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0")
  ],
  targets: [
    // Everything that can be tested without a screen: the protocol, the
    // engine connection and the formatting.
    .target(name: "OmegaNotchKit"),
    .executableTarget(
      name: "OmegaNotch",
      dependencies: ["OmegaNotchKit", .product(name: "Sparkle", package: "Sparkle")]),
    // Decodes the JSON fixtures the engine's own tests keep in
    // protocol/fixtures, so the two sides of the protocol cannot drift.
    .testTarget(name: "OmegaNotchKitTests", dependencies: ["OmegaNotchKit"]),
  ]
)
