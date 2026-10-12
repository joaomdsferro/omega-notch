// swift-tools-version: 5.10

import PackageDescription

let package = Package(
  name: "OmegaNotch",
  platforms: [.macOS(.v14)],
  products: [
    .executable(name: "OmegaNotch", targets: ["OmegaNotch"])
  ],
  targets: [
    // Everything that can be tested without a screen: the protocol, the
    // engine connection and the formatting.
    .target(name: "OmegaNotchKit"),
    .executableTarget(name: "OmegaNotch", dependencies: ["OmegaNotchKit"]),
    // Decodes the JSON fixtures the engine's own tests keep in
    // protocol/fixtures, so the two sides of the protocol cannot drift.
    .testTarget(name: "OmegaNotchKitTests", dependencies: ["OmegaNotchKit"]),
  ]
)
