// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "BandProtocol",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [
        .library(name: "BandProtocol", targets: ["BandProtocol"]),
    ],
    targets: [
        .target(name: "BandProtocol"),
        .testTarget(name: "BandProtocolTests", dependencies: ["BandProtocol"]),
    ]
)
