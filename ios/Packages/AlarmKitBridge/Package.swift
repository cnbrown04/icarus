// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "AlarmKitBridge",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [
        .library(name: "AlarmKitBridge", targets: ["AlarmKitBridge"]),
    ],
    dependencies: [
        .package(path: "../BandKit"),
    ],
    targets: [
        .target(
            name: "AlarmKitBridge",
            dependencies: [
                .product(name: "BandKit", package: "BandKit"),
            ]
        ),
        .testTarget(
            name: "AlarmKitBridgeTests",
            dependencies: [
                "AlarmKitBridge",
                .product(name: "BandKit", package: "BandKit"),
            ]
        ),
    ]
)
