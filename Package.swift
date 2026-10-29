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
        .library(name: "AtlasOrbit", targets: ["AtlasOrbit"]),
        .library(name: "AtlasOrbitUI", targets: ["AtlasOrbitUI"]),
        .library(name: "AtlasCompanion", targets: ["AtlasCompanion"]),
        .library(name: "AtlasCompanionUI", targets: ["AtlasCompanionUI"]),
        .library(name: "AtlasStudy", targets: ["AtlasStudy"]),
        .library(name: "AtlasCreative", targets: ["AtlasCreative"]),
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
        // Stage 05 Orbit, headless half: the file indexer, search, rules,
        // duplicate detection, projects, cleanup and Mac Health sampling.
        // Reads only folders the user added; every change goes through the
        // engine as a registered action.
        .target(
            name: "AtlasOrbit",
            dependencies: ["AtlasCore"],
            path: "Modules/Orbit",
            exclude: ["FileUniverse", "Browser", "FileOrganizer/Views", "Search/Views", "DuplicateDetection/Views",
                      "SystemHealth/Views", "Workspace/Views"],
            sources: ["FileIndexer", "Search/Model", "FileOrganizer/Model", "DuplicateDetection/Model", "SystemHealth/Model",
                      "Workspace/Model"]
        ),
        // Stage 05 Orbit, presentation half: the 3D File Universe, the 2D
        // browser and storage chart, search, rules, duplicates, projects,
        // folders and Mac Health screens.
        .target(
            name: "AtlasOrbitUI",
            dependencies: ["AtlasOrbit"],
            path: "Modules/Orbit",
            exclude: ["FileIndexer", "Search/Model", "FileOrganizer/Model", "DuplicateDetection/Model", "SystemHealth/Model",
                      "Workspace/Model"],
            sources: ["FileUniverse", "Browser", "FileOrganizer/Views", "Search/Views", "DuplicateDetection/Views",
                      "SystemHealth/Views", "Workspace/Views"]
        ),
        // Stage 06 Companion, headless half: the animation state machine, the
        // command parser and optional AI layer, plan validation, suggestions
        // and overlay geometry. A control surface only: every command ends as
        // a registered action or workflow run through the engine.
        .target(
            name: "AtlasCompanion",
            dependencies: ["AtlasCore", "AtlasSpaces", "AtlasOrbit"],
            path: "Modules/Companion",
            exclude: ["CharacterRenderer/Views", "DesktopOverlay/Views", "CommandInterface/Views", "Settings"],
            sources: ["AnimationStates", "IntentParser", "ContextualSuggestions", "CommandInterface/Model", "DesktopOverlay/Model",
                      "CharacterRenderer/Model"]
        ),
        // Stage 06 Companion, presentation half: the RealityKit character, the
        // desktop overlay panel, quick controls, the command palette and the
        // Companion settings screen.
        .target(
            name: "AtlasCompanionUI",
            dependencies: ["AtlasCompanion"],
            path: "Modules/Companion",
            exclude: ["AnimationStates", "IntentParser", "ContextualSuggestions", "CommandInterface/Model", "DesktopOverlay/Model",
                      "CharacterRenderer/Model"],
            sources: ["CharacterRenderer/Views", "DesktopOverlay/Views", "CommandInterface/Views", "Settings"]
        ),
        // Study Library: courses, assignments, study sessions and their
        // automations. Headless; the room draws from `StudyRoomState`
        // (AtlasSpaces) and everything it does runs through the engine.
        .target(
            name: "AtlasStudy",
            dependencies: ["AtlasCore", "AtlasSpaces", "AtlasOrbit"],
            path: "Modules/Study"
        ),
        // Creative Studio: creative projects (Orbit projects with creative
        // fields), thumbnails, sessions and file rules. Headless; the room
        // draws from `CreativeRoomState` (AtlasSpaces).
        .target(
            name: "AtlasCreative",
            dependencies: ["AtlasCore", "AtlasSpaces", "AtlasOrbit"],
            path: "Modules/Creative"
        ),
        // Native SwiftUI shell.
        .executableTarget(
            name: "ATLAS",
            dependencies: ["AtlasCore", "AtlasSpaces", "AtlasSpacesUI", "AtlasFlow", "AtlasOrbit", "AtlasOrbitUI",
                           "AtlasCompanion", "AtlasCompanionUI", "AtlasStudy", "AtlasCreative"],
            path: "App"
        ),
        .testTarget(
            name: "AtlasCoreTests",
            dependencies: ["AtlasCore", "AtlasSpaces", "AtlasSpacesUI", "AtlasOrbit", "AtlasCompanion", "AtlasStudy", "AtlasFlow", "AtlasCreative"],
            // Unit tests and cross-module integration tests share the mocks.
            path: "Tests",
            sources: ["Unit", "Integration"]
        ),
    ]
)
