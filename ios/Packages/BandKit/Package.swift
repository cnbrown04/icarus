// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "BandKit",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [
        .library(name: "BandKit", targets: ["BandKit"]),
    ],
    dependencies: [
        .package(path: "../BandProtocol"),
    ],
    targets: [
        .target(
            name: "BandKit",
            dependencies: [
                .product(name: "BandProtocol", package: "BandProtocol"),
            ]
        ),
        .testTarget(
            name: "BandKitTests",
            dependencies: ["BandKit"]
        ),
    ]
)
