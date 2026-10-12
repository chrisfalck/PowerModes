// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "PowerModes",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "PowerPolicy"),
        .executableTarget(name: "PowerModes", dependencies: ["PowerPolicy"]),
        .testTarget(name: "PowerPolicyTests", dependencies: ["PowerPolicy"]),
    ]
)
