// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Metrics",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [
        .library(name: "Metrics", targets: ["Metrics"]),
    ],
    targets: [
        .target(name: "Metrics"),
        .testTarget(name: "MetricsTests", dependencies: ["Metrics"]),
    ]
)
