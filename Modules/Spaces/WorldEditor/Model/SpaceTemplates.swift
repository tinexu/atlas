import AtlasCore
import Foundation

/// The five built-in templates. Activations only use apps that ship with
/// macOS (Terminal, Safari, Notes, Calendar, Music, Finder) so they work on
/// any Mac without setup.
///
/// Room coordinates: the floor spans -1…1 on x and z, the back wall is at
/// z = -1 and the side wall at x = -1. Heights are in the same units.
public enum SpaceTemplates {
    public static var all: [SpaceTemplate] { [codingLab, studyLibrary, creativeStudio, meetingRoom, personalLounge] }

    /// Created on first launch.
    public static var starters: [SpaceTemplate] { [codingLab, studyLibrary, creativeStudio] }

    public static func template(id: String) -> SpaceTemplate? {
        all.first { $0.id == id }
    }

    /// For Spaces whose template was removed or renamed.
    public static var fallback: SpaceTemplate { personalLounge }

    // MARK: - Bundle identifiers

    enum App {
        static let terminal = "com.apple.Terminal"
        static let safari = "com.apple.Safari"
        static let notes = "com.apple.Notes"
        static let calendar = "com.apple.iCal"
        static let music = "com.apple.Music"
    }

    private static func launch(_ bundleID: String) -> WorkflowStep {
        WorkflowStep(actionID: LaunchApplicationAction.id, parameters: ["bundleId": .string(bundleID)])
    }

    private static func safari(_ url: String) -> WorkflowStep {
        WorkflowStep(actionID: OpenURLAction.id, parameters: ["url": .string(url), "bundleId": .string(App.safari)])
    }

    private static func finder(_ path: String) -> WorkflowStep {
        WorkflowStep(actionID: RevealInFinderAction.id, parameters: ["path": .string(path)])
    }

    private static func log(_ message: String) -> WorkflowStep {
        WorkflowStep(actionID: LogMessageAction.id, parameters: ["message": .string(message)])
    }

    // MARK: - Templates

    public static var codingLab: SpaceTemplate {
        let docs = "https://developer.apple.com/documentation/swift"
        return SpaceTemplate(
            id: "coding-lab",
            name: "Coding Lab",
            summary: "Terminal, Swift documentation in Safari and your home folder.",
            symbolName: "chevron.left.forwardslash.chevron.right",
            group: .work,
            room: RoomLayout(floorColor: "#3A3F4B", wallColor: "#D9DEE7", accentColor: "#3B82F6", lighting: .cool),
            objects: [
                SpaceObjectBlueprint(.monitor, label: "Swift docs", at: [0.05, 0, -0.6],
                                     action: OpenURLAction.id, ["url": .string(docs), "bundleId": .string(App.safari)]),
                SpaceObjectBlueprint(.terminal, label: "Terminal", at: [-0.5, 0, -0.45], yaw: 25,
                                     action: LaunchApplicationAction.id, ["bundleId": .string(App.terminal)]),
                SpaceObjectBlueprint(.bookshelf, label: "Home folder", at: [-0.82, 0, 0.35], yaw: 90,
                                     action: RevealInFinderAction.id, ["path": "~"]),
                SpaceObjectBlueprint(.clock, label: "Calendar", at: [0.6, 0.78, -0.96],
                                     action: LaunchApplicationAction.id, ["bundleId": .string(App.calendar)]),
                SpaceObjectBlueprint(.lamp, at: [0.62, 0, -0.55]),
                SpaceObjectBlueprint(.cube, at: [0.45, 0, 0.45], yaw: 20),
                SpaceObjectBlueprint(.poster, at: [-0.97, 0.6, -0.4], yaw: 90),
            ],
            profiles: [
                ProfileBlueprint(
                    name: "Deep Work",
                    summary: "Opens Terminal, the Swift documentation in Safari and your home folder in Finder.",
                    isDefault: true,
                    steps: [launch(App.terminal), safari(docs), finder("~"), log("Coding Lab ready")]
                ),
                ProfileBlueprint(
                    name: "Quick Review",
                    summary: "Just Safari on the documentation and a Terminal window.",
                    steps: [safari(docs), launch(App.terminal)]
                ),
            ]
        )
    }

    public static var studyLibrary: SpaceTemplate {
        SpaceTemplate(
            id: "study-library",
            name: "Study Library",
            summary: "Notes, Calendar, a reference in Safari and your Documents folder.",
            symbolName: "books.vertical",
            group: .school,
            transitionBehavior: .hidePrevious,
            room: RoomLayout(floorColor: "#6B4F3A", wallColor: "#EFE6D8", accentColor: "#10B981", lighting: .warm),
            objects: [
                SpaceObjectBlueprint(.bookshelf, label: "Documents", at: [-0.45, 0, -0.85],
                                     action: RevealInFinderAction.id, ["path": "~/Documents"]),
                SpaceObjectBlueprint(.bookshelf, at: [0.2, 0, -0.85]),
                SpaceObjectBlueprint(.monitor, label: "Notes", at: [0.1, 0, -0.2],
                                     action: LaunchApplicationAction.id, ["bundleId": .string(App.notes)]),
                SpaceObjectBlueprint(.clock, label: "Calendar", at: [0.7, 0.78, -0.96],
                                     action: LaunchApplicationAction.id, ["bundleId": .string(App.calendar)]),
                SpaceObjectBlueprint(.lamp, at: [-0.4, 0, 0.1]),
                SpaceObjectBlueprint(.poster, at: [-0.97, 0.62, 0.25], yaw: 90),
            ],
            profiles: [
                ProfileBlueprint(
                    name: "Study Session",
                    summary: "Opens Notes and Calendar, a reference page in Safari and your Documents folder.",
                    isDefault: true,
                    steps: [
                        launch(App.notes), launch(App.calendar), safari("https://en.wikipedia.org"),
                        finder("~/Documents"), log("Study Library ready"),
                    ]
                ),
            ]
        )
    }

    /// A sunlit pink artist's loft (Stage 09). The loft is drawn by
    /// `CreativeLoftBuilder` (AtlasSpacesUI); these objects drive its props.
    public static var creativeStudio: SpaceTemplate {
        func object(_ role: CreativeLoftRole, _ action: ActionID?, _ parameters: ActionParameters = [:]) -> SpaceObjectBlueprint {
            SpaceObjectBlueprint(role.kind, label: role.defaultLabel, at: CreativeLoft.blueprintPosition(role),
                                 action: action, parameters)
        }
        return SpaceTemplate(
            id: CreativeLoft.templateID,
            name: "Creative Studio",
            summary: "A sunlit pink loft: your design app, project and assets folders, inspiration and a focus mug.",
            symbolName: "paintpalette",
            group: .creative,
            room: RoomLayout(floorColor: "#F3E1DC", wallColor: "#F6D6DC", accentColor: "#E8A6B4", lighting: .warm),
            objects: [
                object(.monitor, LaunchApplicationAction.id, ["bundleId": .string(CreativeLoft.designAppBundleID())]),
                object(.easel, OpenFileAction.id, ["path": "~/Pictures"]),
                object(.shelves, OpenFileAction.id, ["path": "~/Pictures"]),
                object(.pegboard, OpenURLAction.id, ["url": .string(CreativeLoft.inspirationURL)]),
                object(.mug, "timer.focus.start", ["minutes": 25]),
                object(.pouf, LaunchApplicationAction.id, ["bundleId": .string(App.music)]),
                object(.pendant, nil),
                // The neon sign runs this Space's activation; it's added with
                // the new Space's workflow by `upgradeCreativeStudios()`.
            ],
            profiles: [
                ProfileBlueprint(
                    name: "Create",
                    summary: "Opens Music and Notes, and your Pictures folder in Finder.",
                    isDefault: true,
                    steps: [launch(App.music), launch(App.notes), finder("~/Pictures"), log("Creative Studio ready")]
                ),
            ]
        )
    }

    public static var meetingRoom: SpaceTemplate {
        SpaceTemplate(
            id: "meeting-room",
            name: "Meeting Room",
            summary: "Calendar and Notes, with everything else out of the way.",
            symbolName: "person.3",
            group: .work,
            transitionBehavior: .hidePrevious,
            room: RoomLayout(floorColor: "#9CA3AF", wallColor: "#F3F4F6", accentColor: "#F59E0B", lighting: .daylight),
            objects: [
                SpaceObjectBlueprint(.cube, label: "Table", at: [0, 0, 0.05], scale: [2.2, 0.55, 1.1]),
                SpaceObjectBlueprint(.monitor, label: "Calendar", at: [0, 0.35, -0.85], scale: [1.4, 1.4, 1],
                                     action: LaunchApplicationAction.id, ["bundleId": .string(App.calendar)]),
                SpaceObjectBlueprint(.clock, at: [0.7, 0.8, -0.96]),
                SpaceObjectBlueprint(.poster, label: "Notes", at: [-0.97, 0.6, 0], yaw: 90,
                                     action: LaunchApplicationAction.id, ["bundleId": .string(App.notes)]),
                SpaceObjectBlueprint(.lamp, at: [0.75, 0, 0.6]),
            ],
            profiles: [
                ProfileBlueprint(
                    name: "Meeting",
                    summary: "Opens Calendar and Notes.",
                    isDefault: true,
                    steps: [launch(App.calendar), launch(App.notes), log("Meeting Room ready")]
                ),
            ]
        )
    }

    public static var personalLounge: SpaceTemplate {
        SpaceTemplate(
            id: "personal-lounge",
            name: "Personal Lounge",
            summary: "Music and something to read.",
            symbolName: "sofa",
            group: .personal,
            room: RoomLayout(floorColor: "#4C3F5E", wallColor: "#E9E3F2", accentColor: "#8B5CF6", lighting: .dusk),
            objects: [
                SpaceObjectBlueprint(.cube, label: "Sofa", at: [0, 0, -0.55], scale: [2.4, 0.7, 0.9]),
                SpaceObjectBlueprint(.lamp, label: "Music", at: [0.7, 0, -0.6],
                                     action: LaunchApplicationAction.id, ["bundleId": .string(App.music)]),
                SpaceObjectBlueprint(.bookshelf, label: "Reading", at: [-0.82, 0, 0.2], yaw: 90,
                                     action: OpenURLAction.id,
                                     ["url": "https://www.apple.com/newsroom/", "bundleId": .string(App.safari)]),
                SpaceObjectBlueprint(.poster, at: [0.1, 0.65, -0.97]),
                SpaceObjectBlueprint(.clock, at: [-0.97, 0.8, -0.5], yaw: 90),
            ],
            profiles: [
                ProfileBlueprint(
                    name: "Unwind",
                    summary: "Opens Music and Apple Newsroom in Safari.",
                    isDefault: true,
                    steps: [launch(App.music), safari("https://www.apple.com/newsroom/")]
                ),
            ]
        )
    }
}
