// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "HealthRelayKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "HealthRelayKit", targets: ["HealthRelayKit"]),
    ],
    targets: [
        .target(name: "HealthRelayKit"),
        .testTarget(name: "HealthRelayKitTests", dependencies: ["HealthRelayKit"]),
    ]
)
