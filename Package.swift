// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ATLAS",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "ATLAS", targets: ["ATLAS"]),
        .library(name: "AtlasCore", targets: ["AtlasCore"]),
    ],
    targets: [
        // Headless foundation: event bus, action registry, permissions,
        // persistence and the automation engine. No UI code lives here, so
        // automations can later run from a background helper.
        .target(
            name: "AtlasCore",
            path: "Core"
        ),
        // Native SwiftUI shell.
        .executableTarget(
            name: "ATLAS",
            dependencies: ["AtlasCore"],
            path: "App"
        ),
        .testTarget(
            name: "AtlasCoreTests",
            dependencies: ["AtlasCore"],
            path: "Tests/Unit"
        ),
    ]
)
