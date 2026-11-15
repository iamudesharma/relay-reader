// swift-tools-version: 5.9
import PackageDescription

let package = Package(
  name: "SupertonicCore",
  platforms: [.macOS("15.0"), .iOS("18.0")],
  products: [.library(name: "SupertonicCore", targets: ["SupertonicCore"])],
  targets: [.target(name: "SupertonicCore", swiftSettings: [.define("TTS")]),
    .testTarget(name: "SupertonicCoreTests", dependencies: ["SupertonicCore"])]
)
