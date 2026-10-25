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
        .library(name: "AtlasFlow", targets: ["AtlasFlow"]),
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
            exclude: ["MissionControl", "WorldEditor/Rendering", "WindowManager/Views", "SessionSnapshots"],
            sources: ["SpaceModels", "WorkspaceActivation", "WorldEditor/Model", "WindowManager/Model"]
        ),
        // Stage 02–03 Spaces, presentation half: the RealityKit world, the
        // Spatial Window Manager and snapshots. It only draws and reports
        // input; everything it changes goes through the engine.
        .target(
            name: "AtlasSpacesUI",
            dependencies: ["AtlasSpaces"],
            path: "Modules/Spaces",
            exclude: ["SpaceModels", "WorkspaceActivation", "WorldEditor/Model", "WindowManager/Model"],
            sources: ["MissionControl", "WorldEditor/Rendering", "WindowManager/Views", "SessionSnapshots"]
        ),
        // Stage 04 Flow: the Automation Galaxy editor (2D and 3D), node
        // inspectors, live run view and history graph. The graph model,
        // runner and triggers live in Core.
        .target(
            name: "AtlasFlow",
            dependencies: ["AtlasCore", "AtlasSpaces"],
            path: "Modules/Flow"
        ),
        // Native SwiftUI shell.
        .executableTarget(
            name: "ATLAS",
            dependencies: ["AtlasCore", "AtlasSpaces", "AtlasSpacesUI", "AtlasFlow"],
            path: "App"
        ),
        .testTarget(
            name: "AtlasCoreTests",
            dependencies: ["AtlasCore", "AtlasSpaces"],
            path: "Tests/Unit"
        ),
    ]
)
