import AtlasCore
import Foundation

/// The interactive props of the Creative Studio loft, and which stored
/// `SpaceObject` drives each one. The loft places props itself, so an
/// object's stored position doesn't matter here; its kind and its action do.
public enum CreativeLoftRole: String, CaseIterable, Sendable {
    case monitor, easel, shelves, pegboard, neon, mug, pouf, pendant

    /// The object kind that plays this role.
    public var kind: SpaceObjectKind {
        switch self {
        case .monitor: return .monitor
        case .easel: return .easel
        case .shelves: return .bookshelf
        case .pegboard: return .poster
        case .neon: return .neon
        case .mug: return .mug
        case .pouf: return .cube
        case .pendant: return .lamp
        }
    }

    public var defaultLabel: String {
        switch self {
        case .monitor: return "Design app"
        case .easel: return "Current project"
        case .shelves: return "Assets"
        case .pegboard: return "Inspiration"
        case .neon: return "Creative Studio"
        case .mug: return "Focus 25 min"
        case .pouf: return "Pouf"
        case .pendant: return "Lamp"
        }
    }

    /// Roles that get a default action when the Space has no such object.
    static let withDefaults: [CreativeLoftRole] = [.monitor, .easel, .shelves, .pegboard, .neon, .mug]
}

public enum CreativeLoft {
    public static let templateID = "creative-studio"
    /// Placeholder until you set your own (edit the pegboard object).
    public static let inspirationURL = "https://www.pinterest.com/"

    public struct Assignment: Equatable, Sendable {
        /// The object behind each prop.
        public var roles: [CreativeLoftRole: SpaceObject] = [:]
        /// Extra objects that do something: drawn as ordinary objects where they're stored.
        public var loose: [SpaceObject] = []
        /// Extra objects that do nothing (e.g. a second plain poster): not drawn.
        public var hidden: [SpaceObject] = []
    }

    /// Gives each role one object of its kind, preferring objects that run
    /// something, so existing assignments always keep a visible prop.
    public static func assign(_ objects: [SpaceObject]) -> Assignment {
        var result = Assignment()
        var used = Set<UUID>()
        for role in CreativeLoftRole.allCases {
            let candidates = objects.filter { $0.kind == role.kind && !used.contains($0.id) }
            if let chosen = candidates.first(where: \.hasAssignment) ?? candidates.first {
                result.roles[role] = chosen
                used.insert(chosen.id)
            }
        }
        for object in objects where !used.contains(object.id) {
            if object.hasAssignment { result.loose.append(object) } else { result.hidden.append(object) }
        }
        return result
    }

    /// Figma if it's installed, otherwise Preview.
    public static func designAppBundleID(fileManager: FileManager = .default) -> String {
        let figma = ["/Applications/Figma.app", (NSHomeDirectory() as NSString).appendingPathComponent("Applications/Figma.app")]
        return figma.contains(where: fileManager.fileExists(atPath:)) ? "com.figma.Desktop" : "com.apple.Preview"
    }

    /// Default objects for roles the Space doesn't have yet. Never replaces
    /// or edits an existing object.
    public static func missingDefaults(for spaceID: UUID, existing: [SpaceObject], activationWorkflowID: UUID?,
                                       designApp: String, hasFocusAction: Bool) -> [SpaceObject] {
        let kinds = Set(existing.map(\.kind))
        return CreativeLoftRole.withDefaults.filter { !kinds.contains($0.kind) }.map { role in
            var object = SpaceObject(spaceID: spaceID, kind: role.kind, label: role.defaultLabel,
                                     transform: SpaceTransform(position: blueprintPosition(role)))
            switch role {
            case .monitor:
                object.actionID = LaunchApplicationAction.id
                object.parameters = ["bundleId": .string(designApp)]
            case .easel:
                object.actionID = OpenFileAction.id
                object.parameters = ["path": "~/Pictures"]
            case .shelves:
                object.actionID = OpenFileAction.id
                object.parameters = ["path": "~/Pictures"]
            case .pegboard:
                object.actionID = OpenURLAction.id
                object.parameters = ["url": .string(inspirationURL)]
            case .neon:
                object.workflowID = activationWorkflowID
            case .mug:
                if hasFocusAction {
                    object.actionID = "timer.focus.start"
                    object.parameters = ["minutes": 25]
                }
            case .pouf, .pendant:
                break
            }
            return object
        }
    }

    /// Roughly where each prop stands, in room units, for the editor's
    /// placement fields. The loft itself places props by role.
    public static func blueprintPosition(_ role: CreativeLoftRole) -> SIMD3<Float> {
        switch role {
        case .monitor: return [-0.45, 0.4, -0.55]
        case .easel: return [0.65, 0, -0.35]
        case .shelves: return [-0.95, 0.75, -0.2]
        case .pegboard: return [-0.55, 0.8, -0.98]
        case .neon: return [-0.97, 1.05, -0.2]
        case .mug: return [-0.25, 0.4, -0.45]
        case .pouf: return [0.4, 0, -0.05]
        case .pendant: return [-0.45, 1.0, -0.55]
        }
    }
}

extension SpaceLibrary {
    /// Adds the loft's new props, with their default actions, to Creative
    /// Studio Spaces made before the redesign. Runs once per Space; objects
    /// you already have (and their actions) are left exactly as they are.
    public func upgradeCreativeStudios() throws {
        for space in try store.spaces() where space.templateID == CreativeLoft.templateID {
            let key = "spaces.creativeLoft.v1.\(space.id.uuidString)"
            guard try store.preference(key, as: Bool.self) != true else { continue }
            let existing = try store.spaceObjects(spaceID: space.id)
            let profiles = try store.profiles(spaceID: space.id)
            let activation = (profiles.first(where: \.isDefault) ?? profiles.first)?.workflowID
            let additions = CreativeLoft.missingDefaults(
                for: space.id, existing: existing, activationWorkflowID: activation,
                designApp: CreativeLoft.designAppBundleID(),
                hasFocusAction: core.registry.descriptor(for: "timer.focus.start") != nil
            )
            try store.database.transaction {
                for object in additions { try store.saveSpaceObject(object) }
                try store.setPreference(true, for: key)
            }
        }
    }
}
