# ATLAS — Stage 01: Foundation and Automation Core

A native macOS utility that saves and runs simple automation configurations. This is the first roadmap stage: the engine every later module (Spaces, Orbit, Flow, Companion) will run on, plus a SwiftUI app to drive it.

Requires **macOS 14 Sonoma** or later and **Xcode 15+** (Swift 5.9+).

## Run it

```bash
# Open in Xcode (recommended): pick the "ATLAS" scheme and press ⌘R
open Package.swift

# Or from the terminal
swift run ATLAS

# Run the tests
swift test

# Build a real ATLAS.app (needed for notifications)
chmod +x scripts/build-app.sh
./scripts/build-app.sh && open build/ATLAS.app
```

On first launch ATLAS creates three starter automations that use only built-in Mac apps: **Coding Setup**, **Morning Setup** and **Focus Reset**. Data lives in `~/Library/Application Support/ATLAS/atlas.sqlite`.

## What's in Stage 01

| Spec item | Where | Notes |
|---|---|---|
| Application shell | `App/` | Sidebar app with Automations, Run History, Action Library, Permissions. Menu-bar utility for running and pausing. |
| Local database | `Core/Persistence/` | SQLite via the system library, versioned migrations (`PRAGMA user_version`). Tables already named for Stage 04 (`workflow_node`, `workflow_run`). |
| Event bus | `Core/EventBus/` | Dot-named events with `workflow.*` wildcards; sync handlers or `AsyncStream`. |
| Action registry | `Core/ActionRegistry/` | Descriptors declare parameters, permissions, side effects, confirmation and idempotency. Parameters are validated before anything runs. |
| Permission manager | `Core/Permissions/` | Every step passes `authorize()`. Per-action off switches persist. Dashboard explains each permission. |
| App-launch actions | `BuiltInActions.swift` | Launch App, Quit App (asks first), Open Link, Open File, Show in Finder, Show Notification, Wait, Log Message. |
| Execution engine | `Core/AutomationEngine/` | Run records with pending/running/succeeded/partiallySucceeded/failed/skipped/canceled, per-step timeouts, capped retries for idempotent actions only, cancellation, pause. |

## How it fits together

```
SwiftUI app / menu bar  ──►  AppModel (mirrors state)
                                │
                           AtlasCore
   ┌──────────┬─────────────┬───┴──────────┬──────────────┐
EventBus  ActionRegistry  PermissionManager  AtlasStore (SQLite)
   ▲              │               │                ▲
   └──────── AutomationEngine (actor) ─────────────┘
                     │
               SystemAdapter  ──►  MacSystemAdapter (NSWorkspace, UserNotifications)
```

`AtlasCore` has no UI dependency, so the same engine can later run inside a background helper with the 3D dashboard closed (spec 7.7, 10).

Key rules the engine enforces, from the spec:

- **One path for every action.** `engine.invoke(_:parameters:source:)` is how a 3D room object, keyboard shortcut or Companion command will run an action, with the same validation, permissions and history as a workflow step.
- **Honest status.** A run where some steps worked and some didn't is `partiallySucceeded`, never "succeeded".
- **Nothing irreversible without consent.** Actions marked `confirmationRequired` prompt the user; with no one to ask, they're refused. Quit App uses the polite `terminate()`, so apps still ask about unsaved work.
- **No duplicate side effects.** Only actions declared idempotent are retried, capped at 5.
- **History survives.** Deleting a workflow keeps its runs; runs interrupted by a crash are closed as canceled at next launch.

## Adding an action

```swift
struct OpenTerminalHere: AtlasAction {
    let descriptor = ActionDescriptor(
        id: "terminal.openFolder",
        title: "Open Terminal Here",
        summary: "Opens Terminal in a folder.",
        category: "Developer",
        symbolName: "terminal",
        parameters: [ParameterSpec(key: "path", label: "Folder", kind: .folderPath)],
        permissions: [.automation],
        sideEffects: [.launchesApplication],
        isIdempotent: false
    )

    func perform(_ p: ActionParameters, context: ActionContext) async throws -> ActionOutput {
        let path = try p.path("path")
        try await context.system.openFile(atPath: path, withApplication: "com.apple.Terminal")
        return ActionOutput("Opened Terminal in \(path)")
    }
}

try core.registry.register(OpenTerminalHere())
```

The editor generates fields from `parameters` automatically, and the Action Library and Permissions screens pick it up.

## Known limits and next stage

- This code was written in an environment without a Swift compiler, so it has not been built yet. Expect possibly a few small compile fixes on first build in Xcode; the structure and logic are complete.
- Notifications need the app bundle from `build-app.sh`; under `swift run` that step fails with a clear message instead of crashing.
- Only manual, menu-bar and programmatic triggers exist. Event triggers (app launched, file created, time reached) arrive with Flow in Stage 04.
- **Stage 02 (ATLAS Spaces MVP)** goes under `Modules/Spaces/`: a `Space` model whose activation is a `Workflow`, RealityKit room templates, and `space.activated` events on the bus.
