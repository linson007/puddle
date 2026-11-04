// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Puddle",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "Puddle", targets: ["Puddle"])],
    targets: [
        .target(name: "PuddleCore", resources: [.process("Resources")]),
        .executableTarget(name: "Puddle", dependencies: ["PuddleCore"]),
        .testTarget(name: "PuddleCoreTests", dependencies: ["PuddleCore"]),
        .testTarget(name: "PuddleAppTests", dependencies: ["Puddle", "PuddleCore"]),
    ],
    swiftLanguageModes: [.v6]
)
