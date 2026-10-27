import AtlasCore
import Foundation

/// The interactive props of the Study Library reading room.
public enum StudyLibraryRole: String, DioramaRole {
    case bookshelf, lamp, calendar, globe, chalkboard, book
    /// A small laptop on the desk, drawn only when the Space has a monitor
    /// (older Study Libraries open Notes from one).
    case laptop

    public var kind: SpaceObjectKind {
        switch self {
        case .bookshelf: return .bookshelf
        case .lamp: return .lamp
        case .calendar: return .clock
        case .globe: return .globe
        case .chalkboard: return .chalkboard
        case .book: return .book
        case .laptop: return .monitor
        }
    }

    public var defaultLabel: String {
        switch self {
        case .bookshelf: return "Courses & notes"
        case .lamp: return "Study timer"
        case .calendar: return "Calendar"
        case .globe: return "Research"
        case .chalkboard: return "Assignments"
        case .book: return "Study Library"
        case .laptop: return "Notes"
        }
    }

    /// Roles that get a default action when nothing runs from them yet.
    static let withDefaults: [StudyLibraryRole] = [.bookshelf, .lamp, .calendar, .globe, .chalkboard, .book]
}

public enum StudyLibrary {
    public static let templateID = "study-library"
    /// Placeholder until you set your own (edit the globe object).
    public static let researchURL = "https://scholar.google.com"
    public static let focusMinutes = 50

    public typealias Assignment = DioramaAssignment<StudyLibraryRole>

    public static func assign(_ objects: [SpaceObject]) -> Assignment {
        Diorama.assign(objects)
    }

    /// What to save so the room's props have their default actions (see
    /// `Diorama.defaults`): an existing action is never replaced.
    public static func missingDefaults(for spaceID: UUID, existing: [SpaceObject], activationWorkflowID: UUID?,
                                       hasFocusAction: Bool) -> [SpaceObject] {
        Diorama.defaults(for: spaceID, existing: existing, roles: StudyLibraryRole.withDefaults,
                         position: blueprintPosition) { role, object in
            switch role {
            case .bookshelf, .chalkboard:
                object.actionID = OpenFileAction.id
                object.parameters = ["path": "~/Documents"]
            case .lamp:
                if hasFocusAction {
                    object.actionID = "timer.focus.start"
                    object.parameters = ["minutes": .number(Double(focusMinutes))]
                } else {
                    object.actionID = LaunchApplicationAction.id
                    object.parameters = ["bundleId": "com.apple.Notes"]
                }
            case .calendar:
                object.actionID = LaunchApplicationAction.id
                object.parameters = ["bundleId": "com.apple.iCal"]
            case .globe:
                object.actionID = OpenURLAction.id
                object.parameters = ["url": .string(researchURL)]
            case .book:
                object.workflowID = activationWorkflowID
            case .laptop:
                break
            }
        }
    }

    /// Roughly where each prop stands, in room units, for the editor's
    /// placement fields. The room itself places props by role.
    public static func blueprintPosition(_ role: StudyLibraryRole) -> SIMD3<Float> {
        switch role {
        case .bookshelf: return [-0.9, 0, -0.3]
        case .lamp: return [-0.37, 0.4, -0.6]
        case .calendar: return [-0.05, 0.4, -0.55]
        case .globe: return [0.5, 0, 0.25]
        case .chalkboard: return [-0.5, 0.8, -0.98]
        case .book: return [-0.2, 0.4, -0.48]
        case .laptop: return [-0.45, 0.4, -0.45]
        }
    }
}

extension SpaceLibrary {
    /// Adds the reading room's props, with their default actions, to Study
    /// Library Spaces made before the redesign. Runs once per Space; objects
    /// that already run something are left exactly as they are.
    public func upgradeStudyLibraries() throws {
        let hasFocusAction = self.hasFocusAction
        try upgradeDiorama(templateID: StudyLibrary.templateID, key: "spaces.studyLibrary.v1") { space, existing, activation in
            StudyLibrary.missingDefaults(for: space.id, existing: existing, activationWorkflowID: activation,
                                         hasFocusAction: hasFocusAction)
        }
    }
}
