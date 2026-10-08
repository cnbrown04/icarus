// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "SyncKit",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [
        .library(name: "SyncKit", targets: ["SyncKit"]),
    ],
    dependencies: [
        .package(path: "../Store"),
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.11.1"),
    ],
    targets: [
        .target(
            name: "SyncKit",
            dependencies: [
                .product(name: "Store", package: "Store"),
                .product(name: "GRDB", package: "GRDB.swift"),
            ]
        ),
        .testTarget(
            name: "SyncKitTests",
            dependencies: [
                "SyncKit",
                .product(name: "Store", package: "Store"),
                .product(name: "GRDB", package: "GRDB.swift"),
            ]
        ),
    ]
)
