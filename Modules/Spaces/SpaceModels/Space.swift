import AtlasCore
import Foundation

/// Which shelf of the world a Space sits on. The four presets come first;
/// any other name is a custom group, sorted alphabetically after them.
public struct SpaceGroup: RawRepresentable, Hashable, Codable, Sendable, Comparable, ExpressibleByStringLiteral {
    public let rawValue: String

    public init(rawValue: String) {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        self.rawValue = trimmed.isEmpty ? "Personal" : trimmed
    }

    public init(_ rawValue: String) { self.init(rawValue: rawValue) }
    public init(stringLiteral value: String) { self.init(rawValue: value) }

    public static let work: SpaceGroup = "Work"
    public static let school: SpaceGroup = "School"
    public static let creative: SpaceGroup = "Creative"
    public static let personal: SpaceGroup = "Personal"
    public static let presets: [SpaceGroup] = [.work, .school, .creative, .personal]

    public var isPreset: Bool { Self.presets.contains(self) }

    public static func < (lhs: SpaceGroup, rhs: SpaceGroup) -> Bool {
        let l = presets.firstIndex(of: lhs) ?? presets.count
        let r = presets.firstIndex(of: rhs) ?? presets.count
        return l != r ? l < r : lhs.rawValue.localizedStandardCompare(rhs.rawValue) == .orderedAscending
    }
}

/// What happens to the previous Space's apps when this Space is activated.
/// Apps are never quit by a Space switch: at most they're hidden.
public enum TransitionBehavior: String, Codable, CaseIterable, Sendable {
    case leaveRunning
    case hidePrevious
    case minimizePrevious

    public var title: String {
        switch self {
        case .leaveRunning: return "Leave previous apps as they are"
        case .hidePrevious: return "Hide the previous Space's apps"
        case .minimizePrevious: return "Minimize the previous Space's windows"
        }
    }
}

/// A workspace for one activity, e.g. Coding Lab. What it does is defined
/// by its activation profiles; this is only identity and presentation.
public struct Space: Identifiable, Hashable, Codable, Sendable {
    public var id: UUID
    public var name: String
    public var group: SpaceGroup
    public var templateID: String
    /// Hex colour such as `#3B82F6`.
    public var accentColor: String
    /// Grid slot: ordering across the world. Mission Control lays groups
    /// out as rows and orders each row by slot.
    public var slot: Int
    public var transitionBehavior: TransitionBehavior
    /// Pinned Spaces come first within their group.
    public var isPinned: Bool
    /// Save a snapshot of the windows when switching away, so returning can
    /// offer "Restore where you left off".
    public var snapshotOnLeave: Bool
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        name: String,
        group: SpaceGroup = .personal,
        templateID: String,
        accentColor: String,
        slot: Int = 0,
        transitionBehavior: TransitionBehavior = .leaveRunning,
        isPinned: Bool = false,
        snapshotOnLeave: Bool = true,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.group = group
        self.templateID = templateID
        self.accentColor = accentColor
        self.slot = slot
        self.transitionBehavior = transitionBehavior
        self.isPinned = isPinned
        self.snapshotOnLeave = snapshotOnLeave
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

/// One way of activating a Space, e.g. "Deep Work" or "Quick Review".
/// Activation is always a saved workflow run through the engine.
public struct ActivationProfile: Identifiable, Hashable, Codable, Sendable {
    public var id: UUID
    public var spaceID: UUID
    public var name: String
    public var workflowID: UUID
    /// Applied as the activation's last step, after the workflow's apps open.
    public var windowLayoutID: UUID?
    public var isDefault: Bool
    public var position: Int

    public init(
        id: UUID = UUID(),
        spaceID: UUID,
        name: String,
        workflowID: UUID,
        windowLayoutID: UUID? = nil,
        isDefault: Bool = false,
        position: Int = 0
    ) {
        self.id = id
        self.spaceID = spaceID
        self.name = name
        self.workflowID = workflowID
        self.windowLayoutID = windowLayoutID
        self.isDefault = isDefault
        self.position = position
    }
}

public enum SpaceObjectKind: String, Codable, CaseIterable, Sendable {
    case monitor, terminal, bookshelf, clock, cube, lamp, poster
    /// Stage 09 (Creative Studio loft). Stored as text, so older rows are unaffected.
    case easel, neon, mug

    public var title: String {
        switch self {
        case .monitor: return "Monitor"
        case .terminal: return "Terminal"
        case .bookshelf: return "Bookshelf"
        case .clock: return "Clock"
        case .cube: return "Cube"
        case .lamp: return "Lamp"
        case .poster: return "Poster"
        case .easel: return "Easel"
        case .neon: return "Neon Sign"
        case .mug: return "Mug"
        }
    }

    public var symbolName: String {
        switch self {
        case .monitor: return "display"
        case .terminal: return "terminal"
        case .bookshelf: return "books.vertical"
        case .clock: return "clock"
        case .cube: return "cube"
        case .lamp: return "lamp.desk"
        case .poster: return "photo.artframe"
        case .easel: return "paintbrush.pointed"
        case .neon: return "heart"
        case .mug: return "mug"
        }
    }
}

/// Position in room units (the floor spans -1…1 on x and z), rotation as
/// Euler angles in degrees, and per-axis scale.
public struct SpaceTransform: Hashable, Codable, Sendable {
    public var position: SIMD3<Float>
    public var rotation: SIMD3<Float>
    public var scale: SIMD3<Float>

    public init(
        position: SIMD3<Float> = .zero,
        rotation: SIMD3<Float> = .zero,
        scale: SIMD3<Float> = .one
    ) {
        self.position = position
        self.rotation = rotation
        self.scale = scale
    }

    public static let identity = SpaceTransform()
}

/// Something in a room. Optionally runs one registered action or a saved
/// workflow when clicked; either way it goes through the engine.
public struct SpaceObject: Identifiable, Hashable, Codable, Sendable {
    public var id: UUID
    public var spaceID: UUID
    public var kind: SpaceObjectKind
    public var label: String?
    public var transform: SpaceTransform
    public var actionID: ActionID?
    public var parameters: ActionParameters
    public var workflowID: UUID?

    public init(
        id: UUID = UUID(),
        spaceID: UUID,
        kind: SpaceObjectKind,
        label: String? = nil,
        transform: SpaceTransform = .identity,
        actionID: ActionID? = nil,
        parameters: ActionParameters = [:],
        workflowID: UUID? = nil
    ) {
        self.id = id
        self.spaceID = spaceID
        self.kind = kind
        self.label = label
        self.transform = transform
        self.actionID = actionID
        self.parameters = parameters
        self.workflowID = workflowID
    }

    public var hasAssignment: Bool { workflowID != nil || actionID != nil }

    public var displayName: String {
        if let label, !label.trimmingCharacters(in: .whitespaces).isEmpty { return label }
        return kind.title
    }
}
