import AtlasCore
import Foundation

/// The interactive props of the Creative Studio loft.
public enum CreativeLoftRole: String, DioramaRole {
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

    public typealias Assignment = DioramaAssignment<CreativeLoftRole>

    public static func assign(_ objects: [SpaceObject]) -> Assignment {
        Diorama.assign(objects)
    }

    /// Figma if it's installed, otherwise Preview.
    public static func designAppBundleID(fileManager: FileManager = .default) -> String {
        let figma = ["/Applications/Figma.app", (NSHomeDirectory() as NSString).appendingPathComponent("Applications/Figma.app")]
        return figma.contains(where: fileManager.fileExists(atPath:)) ? "com.figma.Desktop" : "com.apple.Preview"
    }

    /// What to save so the loft's props have their default actions (see
    /// `Diorama.defaults`): an existing action is never replaced.
    public static func missingDefaults(for spaceID: UUID, existing: [SpaceObject], activationWorkflowID: UUID?,
                                       designApp: String, hasFocusAction: Bool) -> [SpaceObject] {
        Diorama.defaults(for: spaceID, existing: existing, roles: CreativeLoftRole.withDefaults,
                         position: blueprintPosition) { role, object in
            switch role {
            case .monitor:
                object.actionID = LaunchApplicationAction.id
                object.parameters = ["bundleId": .string(designApp)]
            case .easel, .shelves:
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
    /// Adds the loft's props, with their default actions, to Creative
    /// Studio Spaces made before the redesign. Runs once per Space; objects
    /// that already run something are left exactly as they are.
    public func upgradeCreativeStudios() throws {
        let hasFocusAction = self.hasFocusAction
        try upgradeDiorama(templateID: CreativeLoft.templateID, key: "spaces.creativeLoft.v1") { space, existing, activation in
            CreativeLoft.missingDefaults(for: space.id, existing: existing, activationWorkflowID: activation,
                                         designApp: CreativeLoft.designAppBundleID(), hasFocusAction: hasFocusAction)
        }
    }
}
