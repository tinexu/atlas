import AtlasCore
import Foundation

/// The interactive props of the Coding Lab night loft.
public enum CodingLabRole: String, DioramaRole {
    case ultrawide, portrait, keyboard, hologram, serverRack, kanban, mug
    /// A wall clock, drawn only when the Space has a clock (older Coding
    /// Labs open Calendar from one).
    case clock

    public var kind: SpaceObjectKind {
        switch self {
        case .ultrawide: return .monitor
        case .portrait: return .terminal
        case .keyboard: return .keyboard
        case .hologram: return .hologram
        case .serverRack: return .serverRack
        case .kanban: return .kanban
        case .mug: return .mug
        case .clock: return .clock
        }
    }

    public var alternateKinds: [SpaceObjectKind] {
        // Older Coding Labs open a folder from a bookshelf.
        self == .hologram ? [.bookshelf] : []
    }

    public var defaultLabel: String {
        switch self {
        case .ultrawide: return "Code editor"
        case .portrait: return "Terminal"
        case .keyboard: return "Coding Lab"
        case .hologram: return "Project folder"
        case .serverRack: return "GitHub"
        case .kanban: return "Task board"
        case .mug: return "Focus 25 min"
        case .clock: return "Clock"
        }
    }

    /// Roles that get a default action when nothing runs from them yet.
    static let withDefaults: [CodingLabRole] = [.ultrawide, .portrait, .keyboard, .hologram, .serverRack, .kanban, .mug]
}

public enum CodingLab {
    public static let templateID = "coding-lab"
    public static let cursorBundleID = "com.todesktop.230313mzl4w4u92"
    public static let githubURL = "https://github.com"
    /// Placeholder until you set your own (edit the task board object).
    public static let taskBoardURL = "https://trello.com"

    public typealias Assignment = DioramaAssignment<CodingLabRole>

    public static func assign(_ objects: [SpaceObject]) -> Assignment {
        Diorama.assign(objects)
    }

    /// Cursor if it's installed, otherwise Xcode, otherwise TextEdit.
    public static func editorBundleID(fileManager: FileManager = .default) -> String {
        let home = NSHomeDirectory() as NSString
        func installed(_ name: String) -> Bool {
            ["/Applications/\(name).app", home.appendingPathComponent("Applications/\(name).app")].contains(where: fileManager.fileExists(atPath:))
        }
        if installed("Cursor") { return cursorBundleID }
        if installed("Xcode") { return "com.apple.dt.Xcode" }
        return "com.apple.TextEdit"
    }

    /// ~/Developer if it exists, otherwise your home folder.
    public static func projectFolder(fileManager: FileManager = .default) -> String {
        let developer = (NSHomeDirectory() as NSString).appendingPathComponent("Developer")
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: developer, isDirectory: &isDirectory) && isDirectory.boolValue ? "~/Developer" : "~"
    }

    /// What to save so the room's props have their default actions (see
    /// `Diorama.defaults`): an existing action is never replaced.
    public static func missingDefaults(for spaceID: UUID, existing: [SpaceObject], activationWorkflowID: UUID?,
                                       editor: String, projectFolder: String, hasFocusAction: Bool) -> [SpaceObject] {
        Diorama.defaults(for: spaceID, existing: existing, roles: CodingLabRole.withDefaults,
                         position: blueprintPosition) { role, object in
            switch role {
            case .ultrawide:
                object.actionID = LaunchApplicationAction.id
                object.parameters = ["bundleId": .string(editor)]
            case .portrait:
                object.actionID = OpenFileAction.id
                object.parameters = ["path": .string(projectFolder), "bundleId": "com.apple.Terminal"]
            case .keyboard:
                object.workflowID = activationWorkflowID
            case .hologram:
                object.actionID = OpenFileAction.id
                object.parameters = ["path": .string(projectFolder)]
            case .serverRack:
                object.actionID = OpenURLAction.id
                object.parameters = ["url": .string(githubURL)]
            case .kanban:
                object.actionID = OpenURLAction.id
                object.parameters = ["url": .string(taskBoardURL)]
            case .mug:
                if hasFocusAction {
                    object.actionID = "timer.focus.start"
                    object.parameters = ["minutes": 25]
                }
            case .clock:
                break
            }
        }
    }

    /// Roughly where each prop stands, in room units, for the editor's
    /// placement fields. The room itself places props by role.
    public static func blueprintPosition(_ role: CodingLabRole) -> SIMD3<Float> {
        switch role {
        case .ultrawide: return [-0.35, 0.45, -0.85]
        case .portrait: return [0.15, 0.45, -0.85]
        case .keyboard: return [-0.35, 0.37, -0.65]
        case .hologram: return [0.45, 0, -0.25]
        case .serverRack: return [-0.9, 0, -0.15]
        case .kanban: return [-0.98, 0.8, -0.65]
        case .mug: return [0, 0.37, -0.65]
        case .clock: return [-0.98, 0.9, 0.3]
        }
    }
}

extension SpaceLibrary {
    /// Adds the night loft's props, with their default actions, to Coding
    /// Lab Spaces made before the redesign. Runs once per Space; objects
    /// that already run something are left exactly as they are.
    public func upgradeCodingLabs() throws {
        let hasFocusAction = self.hasFocusAction
        try upgradeDiorama(templateID: CodingLab.templateID, key: "spaces.codingLab.v1") { space, existing, activation in
            CodingLab.missingDefaults(for: space.id, existing: existing, activationWorkflowID: activation,
                                      editor: CodingLab.editorBundleID(), projectFolder: CodingLab.projectFolder(),
                                      hasFocusAction: hasFocusAction)
        }
    }

    /// Turns lockdown on, with the coding apps allowed, for each Coding
    /// Lab's default profile (once per Space; your later changes stay).
    public func enableCodingLabLockdown() throws {
        for space in try store.spaces() where space.templateID == CodingLab.templateID {
            let key = "spaces.codingLab.lockdown.v1.\(space.id.uuidString)"
            guard try store.preference(key, as: Bool.self) != true else { continue }
            let profiles = try store.profiles(spaceID: space.id)
            try store.database.transaction {
                if let profile = profiles.first(where: \.isDefault) ?? profiles.first {
                    let settingsKey = LockdownService.settingsKey(profileID: profile.id)
                    if try store.preference(settingsKey, as: LockdownSettings.self) == nil {
                        try store.setPreference(LockdownSettings.codingLab, for: settingsKey)
                    }
                }
                try store.setPreference(true, for: key)
            }
        }
    }
}
