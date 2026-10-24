// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ATLAS",
    // macOS 15 for RealityView, which Mission Control's 3D world uses.
    platforms: [.macOS("15.0")],
    products: [
        .executable(name: "ATLAS", targets: ["ATLAS"]),
        .library(name: "AtlasCore", targets: ["AtlasCore"]),
        .library(name: "AtlasSpaces", targets: ["AtlasSpaces"]),
    ],
    targets: [
        // Headless foundation: event bus, action registry, permissions,
        // persistence and the automation engine. No UI code lives here, so
        // automations can later run from a background helper.
        .target(
            name: "AtlasCore",
            path: "Core"
        ),
        // Stage 02 Spaces, headless half: models, templates, the Space
        // library and activation. Works with every window closed.
        .target(
            name: "AtlasSpaces",
            dependencies: ["AtlasCore"],
            path: "Modules/Spaces",
            exclude: ["MissionControl", "WorldEditor/Rendering"],
            sources: ["SpaceModels", "WorkspaceActivation", "WorldEditor/Model"]
        ),
        // Stage 02 Spaces, presentation half: the RealityKit world. It only
        // draws and reports clicks; it never activates anything itself.
        .target(
            name: "AtlasSpacesUI",
            dependencies: ["AtlasSpaces"],
            path: "Modules/Spaces",
            exclude: ["SpaceModels", "WorkspaceActivation", "WorldEditor/Model"],
            sources: ["MissionControl", "WorldEditor/Rendering"]
        ),
        // Native SwiftUI shell.
        .executableTarget(
            name: "ATLAS",
            dependencies: ["AtlasCore", "AtlasSpaces", "AtlasSpacesUI"],
            path: "App"
        ),
        .testTarget(
            name: "AtlasCoreTests",
            dependencies: ["AtlasCore", "AtlasSpaces"],
            path: "Tests/Unit"
        ),
    ]
)
