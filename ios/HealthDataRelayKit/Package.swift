// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "HealthDataRelayKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "HealthDataRelayKit", targets: ["HealthDataRelayKit"]),
    ],
    targets: [
        .target(name: "HealthDataRelayKit"),
        .testTarget(name: "HealthDataRelayKitTests", dependencies: ["HealthDataRelayKit"], exclude: ["Golden"]),
    ]
)
