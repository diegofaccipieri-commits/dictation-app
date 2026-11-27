// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "RelogioDuplo",
    platforms: [.macOS(.v15)],
    targets: [
        .target(name: "RelogioDuploCore"),
        .executableTarget(name: "RelogioDuplo", dependencies: ["RelogioDuploCore"]),
        .testTarget(name: "RelogioDuploCoreTests", dependencies: ["RelogioDuploCore"]),
    ]
)
