// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "HealthDataRelayKit",
    platforms: [.iOS(.v17), .macOS(.v14), .visionOS(.v2)],
    products: [
        .library(name: "HealthDataRelayKit", targets: ["HealthDataRelayKit"]),
    ],
    targets: [
        .target(name: "HealthDataRelayKit", resources: [.copy("Resources/Templates")]),
        .testTarget(name: "HealthDataRelayKitTests", dependencies: ["HealthDataRelayKit"], exclude: ["Golden"]),
    ]
)
