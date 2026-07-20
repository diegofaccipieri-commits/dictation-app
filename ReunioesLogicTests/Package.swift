// swift-tools-version:5.9
import PackageDescription

// Headless test harness for the pure logic of the Reuniões module. Sources are SYMLINKS to the
// canonical files under DictationApp/Reunioes/, so there is a single source of truth.
let package = Package(
    name: "ReunioesLogic",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "ReunioesLogic"),
        .testTarget(name: "ReunioesLogicTests", dependencies: ["ReunioesLogic"]),
    ]
)
