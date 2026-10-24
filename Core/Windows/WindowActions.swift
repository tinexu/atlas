import Foundation

/// Stage 03 window actions. Each holds the `WindowService`, declares
/// Accessibility, and reports exactly which windows it placed or skipped.
public enum WindowActions {
    public static func all(service: WindowService) -> [any AtlasAction] {
        [
            ApplyWindowLayoutAction(service: service),
            CaptureWindowLayoutAction(service: service),
            SaveSnapshotAction(service: service),
            RestoreSnapshotAction(service: service),
            ArrangeWindowAction(service: service),
        ]
    }

    /// The registry owns the actions and the service is owned by `AtlasCore`;
    /// a weak reference avoids keeping either alive through the other.
    final class ServiceRef: @unchecked Sendable {
        weak var service: WindowService?
        init(_ service: WindowService) { self.service = service }

        func get() throws -> WindowService {
            guard let service else { throw ActionError.failed("Window control isn't available right now.") }
            return service
        }
    }

    static let displayHelp = "main, secondary, or a display's name"
}

public struct ApplyWindowLayoutAction: AtlasAction {
    public static let id: ActionID = "window.applyLayout"
    private let ref: WindowActions.ServiceRef

    public let descriptor = ActionDescriptor(
        id: ApplyWindowLayoutAction.id,
        title: "Apply Window Layout",
        summary: "Moves and resizes windows to match a saved layout, opening apps that aren't running.",
        category: "Windows",
        symbolName: "macwindow.on.rectangle",
        parameters: [
            ParameterSpec(key: "layout", label: "Layout", kind: .text, help: "Name of a saved layout, e.g. Programming"),
        ],
        permissions: [.accessibility],
        sideEffects: [.arrangesWindows, .launchesApplication],
        // Applying the same layout twice leaves windows where they are.
        isIdempotent: true,
        // Includes waiting for just-opened apps to show their windows.
        defaultTimeout: 90
    )

    public init(service: WindowService) { ref = .init(service) }

    public func perform(_ parameters: ActionParameters, context: ActionContext) async throws -> ActionOutput {
        let service = try ref.get()
        let reference = try parameters.requiredString("layout")
        guard let layout = try service.storeLayout(reference) else {
            throw ActionError.failed("No window layout called “\(reference)” exists.")
        }
        let result = try await service.apply(layout)
        return try result.actionOutput(extra: ["layoutId": .string(layout.id.uuidString)])
    }
}

public struct CaptureWindowLayoutAction: AtlasAction {
    public static let id: ActionID = "window.captureLayout"
    private let ref: WindowActions.ServiceRef

    public let descriptor = ActionDescriptor(
        id: CaptureWindowLayoutAction.id,
        title: "Capture Window Layout",
        summary: "Saves where your windows are now as a layout. Capturing again with the same name updates it.",
        category: "Windows",
        symbolName: "camera.viewfinder",
        parameters: [
            ParameterSpec(key: "name", label: "Layout name", kind: .text, help: "e.g. Programming"),
        ],
        permissions: [.accessibility],
        isIdempotent: true,
        defaultTimeout: 20
    )

    public init(service: WindowService) { ref = .init(service) }

    public func perform(_ parameters: ActionParameters, context: ActionContext) async throws -> ActionOutput {
        let service = try ref.get()
        let layout = try await service.captureLayout(named: try parameters.requiredString("name"))
        let apps = Set(layout.rules.map(\.displayName)).sorted()
        return ActionOutput(
            "Saved “\(layout.name)” with \(layout.rules.count) window\(layout.rules.count == 1 ? "" : "s")",
            values: [
                "layoutId": .string(layout.id.uuidString),
                "windows": .number(Double(layout.rules.count)),
                "details": .string(apps.joined(separator: ", ")),
            ]
        )
    }
}

public struct SaveSnapshotAction: AtlasAction {
    public static let id: ActionID = "window.snapshot.save"
    private let ref: WindowActions.ServiceRef

    public let descriptor = ActionDescriptor(
        id: SaveSnapshotAction.id,
        title: "Save Session Snapshot",
        summary: "Remembers every window and running app so you can come back to them. It doesn't save what's inside apps.",
        category: "Windows",
        symbolName: "square.and.arrow.down.on.square",
        parameters: [
            ParameterSpec(key: "name", label: "Name", kind: .text, isRequired: false,
                          help: "Leave empty to name it after the date and time"),
        ],
        permissions: [.accessibility],
        // Each run adds another snapshot.
        isIdempotent: false,
        defaultTimeout: 20
    )

    public init(service: WindowService) { ref = .init(service) }

    public func perform(_ parameters: ActionParameters, context: ActionContext) async throws -> ActionOutput {
        let service = try ref.get()
        let snapshot = try await service.saveSnapshot(name: parameters.optionalString("name"))
        return ActionOutput(
            "Saved “\(snapshot.name)”: \(snapshot.rules.count) windows, \(snapshot.runningApps.count) apps",
            values: ["snapshotId": .string(snapshot.id.uuidString), "windows": .number(Double(snapshot.rules.count))]
        )
    }
}

public struct RestoreSnapshotAction: AtlasAction {
    public static let id: ActionID = "window.snapshot.restore"
    private let ref: WindowActions.ServiceRef

    public let descriptor = ActionDescriptor(
        id: RestoreSnapshotAction.id,
        title: "Restore Session Snapshot",
        summary: "Reopens the apps from a snapshot and puts their windows back. Unsaved content inside apps can't be restored.",
        category: "Windows",
        symbolName: "arrow.uturn.backward.square",
        parameters: [
            ParameterSpec(key: "snapshot", label: "Snapshot", kind: .text,
                          help: "A snapshot's name, or “latest”", defaultValue: "latest"),
        ],
        permissions: [.accessibility],
        sideEffects: [.arrangesWindows, .launchesApplication],
        isIdempotent: true,
        defaultTimeout: 120
    )

    public init(service: WindowService) { ref = .init(service) }

    public func perform(_ parameters: ActionParameters, context: ActionContext) async throws -> ActionOutput {
        let service = try ref.get()
        let reference = try parameters.requiredString("snapshot")
        guard let snapshot = try service.storeSnapshot(reference) else {
            throw ActionError.failed("No snapshot called “\(reference)” exists.")
        }
        let result = try await service.restore(snapshot)
        return try result.actionOutput(extra: ["snapshotId": .string(snapshot.id.uuidString)])
    }
}

public struct ArrangeWindowAction: AtlasAction {
    public static let id: ActionID = "window.arrange"
    private let ref: WindowActions.ServiceRef

    public let descriptor = ActionDescriptor(
        id: ArrangeWindowAction.id,
        title: "Arrange App Windows",
        summary: "Puts an app's windows in a preset position, e.g. Terminal on the right half of the main display.",
        category: "Windows",
        symbolName: "rectangle.split.2x1",
        parameters: [
            ParameterSpec(key: "app", label: "App", kind: .bundleIdentifier, help: "Bundle identifier, e.g. com.apple.Terminal"),
            ParameterSpec(key: "preset", label: "Position", kind: .text, defaultValue: .string(WindowPreset.leftHalf.rawValue),
                          options: WindowPreset.allCases.map(\.rawValue)),
            ParameterSpec(key: "display", label: "Display", kind: .text, isRequired: false,
                          help: WindowActions.displayHelp, defaultValue: "main"),
        ],
        permissions: [.accessibility],
        sideEffects: [.arrangesWindows, .launchesApplication],
        isIdempotent: true,
        defaultTimeout: 60
    )

    public init(service: WindowService) { ref = .init(service) }

    public func perform(_ parameters: ActionParameters, context: ActionContext) async throws -> ActionOutput {
        let service = try ref.get()
        let bundleID = try parameters.requiredString("app")
        let presetText = try parameters.requiredString("preset")
        guard let preset = WindowPreset(loose: presetText) else {
            throw ActionError.invalidParameter("Position", reason: "“\(presetText)” isn't a known position")
        }
        let display = try await service.displayTarget(named: parameters.optionalString("display") ?? "main")
        let result = try await service.arrange(bundleID: bundleID, preset: preset, display: display)
        return try result.actionOutput()
    }
}

extension WindowService {
    func storeLayout(_ reference: String) throws -> WindowLayout? {
        try store.windowLayout(reference: reference)
    }

    func storeSnapshot(_ reference: String) throws -> SessionSnapshot? {
        try store.snapshot(reference: reference)
    }

    /// "main", "secondary", or a connected display's name or ID.
    public func displayTarget(named text: String) async throws -> DisplayTarget {
        let key = text.trimmingCharacters(in: .whitespaces)
        switch key.lowercased() {
        case "", "main": return .main
        case "secondary": return .secondary
        case "same", "same as before": return .sameAsBefore
        default:
            let displays = await displays()
            guard let match = displays.first(where: {
                $0.id == key || $0.name.caseInsensitiveCompare(key) == .orderedSame
            }) else {
                let names = displays.map(\.name).joined(separator: ", ")
                throw ActionError.invalidParameter("Display", reason: "no connected display is called “\(key)” (connected: \(names))")
            }
            return match.isMain ? .main : .display(id: match.id, name: match.name)
        }
    }
}
