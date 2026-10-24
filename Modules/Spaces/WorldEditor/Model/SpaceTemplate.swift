import AtlasCore
import Foundation

/// How a room's surfaces are tinted. The whole world shares one light so
/// idle rendering stays cheap; presets change mood through colour instead.
public enum LightingPreset: String, Codable, CaseIterable, Sendable {
    case daylight, warm, cool, studio, dusk

    /// RGB multiplier applied to floor and wall colours.
    public var tint: SIMD3<Float> {
        switch self {
        case .daylight: return [1.0, 1.0, 1.0]
        case .warm: return [1.0, 0.92, 0.80]
        case .cool: return [0.88, 0.94, 1.0]
        case .studio: return [0.97, 0.97, 1.0]
        case .dusk: return [0.82, 0.76, 0.92]
        }
    }

    /// Colour of glowing parts such as lamp shades.
    public var glowColor: String {
        switch self {
        case .daylight, .studio: return "#FFF7E0"
        case .warm: return "#FFD18A"
        case .cool: return "#CFE6FF"
        case .dusk: return "#FFB27A"
        }
    }
}

/// The empty room a template starts from.
public struct RoomLayout: Hashable, Sendable {
    public var floorColor: String
    public var wallColor: String
    public var accentColor: String
    public var lighting: LightingPreset

    public init(floorColor: String, wallColor: String, accentColor: String, lighting: LightingPreset) {
        self.floorColor = floorColor
        self.wallColor = wallColor
        self.accentColor = accentColor
        self.lighting = lighting
    }
}

/// An object a new Space starts with.
public struct SpaceObjectBlueprint: Hashable, Sendable {
    public var kind: SpaceObjectKind
    public var label: String?
    public var transform: SpaceTransform
    public var actionID: ActionID?
    public var parameters: ActionParameters

    public init(
        _ kind: SpaceObjectKind,
        label: String? = nil,
        at position: SIMD3<Float>,
        yaw: Float = 0,
        scale: SIMD3<Float> = .one,
        action actionID: ActionID? = nil,
        _ parameters: ActionParameters = [:]
    ) {
        self.kind = kind
        self.label = label
        self.transform = SpaceTransform(position: position, rotation: [0, yaw, 0], scale: scale)
        self.actionID = actionID
        self.parameters = parameters
    }
}

/// A profile a new Space starts with, and the steps of the workflow
/// created for it.
public struct ProfileBlueprint: Hashable, Sendable {
    public var name: String
    public var summary: String
    public var isDefault: Bool
    public var steps: [WorkflowStep]

    public init(name: String, summary: String, isDefault: Bool = false, steps: [WorkflowStep]) {
        self.name = name
        self.summary = summary
        self.isDefault = isDefault
        self.steps = steps
    }

    /// A fresh workflow (new IDs) for a Space called `spaceName`.
    public func makeWorkflow(spaceName: String) -> Workflow {
        Workflow(
            name: "\(spaceName) · \(name)",
            summary: summary,
            // Keep going past a missing app so the Space reports exactly
            // which parts are ready.
            failurePolicy: .continueOnFailure,
            steps: steps.map { step in
                var copy = step
                copy.id = UUID()
                return copy
            }
        )
    }
}

/// A starting point for a new Space: room look, furniture and a default
/// activation that only uses apps every Mac has.
public struct SpaceTemplate: Identifiable, Hashable, Sendable {
    public let id: String
    public var name: String
    public var summary: String
    public var symbolName: String
    public var group: SpaceGroup
    public var transitionBehavior: TransitionBehavior
    public var room: RoomLayout
    public var objects: [SpaceObjectBlueprint]
    public var profiles: [ProfileBlueprint]

    public init(
        id: String,
        name: String,
        summary: String,
        symbolName: String,
        group: SpaceGroup,
        transitionBehavior: TransitionBehavior = .leaveRunning,
        room: RoomLayout,
        objects: [SpaceObjectBlueprint],
        profiles: [ProfileBlueprint]
    ) {
        self.id = id
        self.name = name
        self.summary = summary
        self.symbolName = symbolName
        self.group = group
        self.transitionBehavior = transitionBehavior
        self.room = room
        self.objects = objects
        self.profiles = profiles
    }
}
