// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Store",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [
        .library(name: "Store", targets: ["Store"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.11.1"),
        .package(path: "../Metrics"),
    ],
    targets: [
        .target(
            name: "Store",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "Metrics", package: "Metrics"),
            ]
        ),
        .testTarget(
            name: "StoreTests",
            dependencies: [
                "Store",
                .product(name: "Metrics", package: "Metrics"),
            ]
        ),
    ]
)
