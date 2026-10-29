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

/// What the Creative Studio room shows from the Creative module: plain
/// data, so the 3D layer never reaches into projects or files itself.
public struct CreativeRoomState: Hashable, Sendable {
    /// The current project on the easel.
    public struct Easel: Hashable, Sendable {
        public var projectID: UUID
        /// On hover: "Robot Model · In progress · last edited 2 h ago".
        public var detail: String
        /// A small PNG of its latest file or export (nil: the abstract blobs).
        public var image: String?

        public init(projectID: UUID, detail: String, image: String? = nil) {
            self.projectID = projectID
            self.detail = detail
            self.image = image
        }
    }

    /// The mug: the creative session timer.
    public struct Mug: Hashable, Sendable {
        public var isRunning = false
        public var isPaused = false
        /// Counts finished sessions; a change refills the mug (with a chime).
        public var refills = 0
        /// On hover: "1 h 12 m to go · click to pause".
        public var detail = "Click to start a 90 min creative session · right-click for more"

        public init(isRunning: Bool = false, isPaused: Bool = false, refills: Int = 0, detail: String? = nil) {
            self.isRunning = isRunning
            self.isPaused = isPaused
            self.refills = refills
            if let detail { self.detail = detail }
        }
    }

    /// A finished project on the gallery wall.
    public struct Frame: Hashable, Sendable, Identifiable {
        public var id: UUID { projectID }
        public var projectID: UUID
        public var image: String?
        /// On hover: "Poster Series · finished Oct 2026 · click for its exports".
        public var detail: String

        public init(projectID: UUID, image: String?, detail: String) {
            self.projectID = projectID
            self.image = image
            self.detail = detail
        }
    }

    /// A paint splash on the rug: one per creative day this month.
    public struct Splash: Hashable, Sendable {
        /// Day of the month (it fixes the splash's place on the rug).
        public var day: Int
        public var color: String

        public init(day: Int, color: String) {
            self.day = day
            self.color = color
        }
    }

    /// The Companion at its tiny easel.
    public struct Painter: Hashable, Sendable {
        public enum Style: String, Hashable, Sendable { case robot, creature, orb }
        public var style: Style
        public var primary: String
        public var secondary: String
        /// A creative session: a calm focus look, nothing waiting shown.
        public var isFocused: Bool
        /// Counts exports saved; a change makes it do a small happy bounce.
        public var bounces: Int
        /// Watch mode: on the window seat with a bowl of popcorn instead.
        public var isWatching = false
        public var waiting: Int
        public var detail: String

        public init(style: Style = .robot, primary: String = "#5B8DEF", secondary: String = "#F5F7FA", isFocused: Bool = false,
                    bounces: Int = 0, waiting: Int = 0, detail: String = "") {
            self.style = style
            self.primary = primary
            self.secondary = secondary
            self.isFocused = isFocused
            self.bounces = bounces
            self.waiting = waiting
            self.detail = detail
        }
    }

    /// Room items that aren't Space objects, by name ("creativeitem:jar:2").
    public enum Item: Hashable, Sendable {
        /// A paint jar on the shelf (0…4): click copies its colour.
        case jar(Int)
        /// A framed finished project on the gallery wall.
        case frame(UUID)
        /// The window: the time of day and the weather.
        case window
        /// The paint splashes on the rug: the creative streak.
        case rug
        /// The Companion at its tiny easel.
        case painter
        /// The little TV: Watch mode.
        case tv

        public var entityName: String {
            switch self {
            case .jar(let index): return "creativeitem:jar:\(index)"
            case .frame(let id): return "creativeitem:frame:\(id.uuidString)"
            case .window: return "creativeitem:window"
            case .rug: return "creativeitem:rug"
            case .painter: return "creativeitem:painter"
            case .tv: return "creativeitem:tv"
            }
        }

        public init?(entityName: String) {
            guard entityName.hasPrefix("creativeitem:") else { return nil }
            let rest = entityName.dropFirst("creativeitem:".count)
            switch rest {
            case "window": self = .window; return
            case "rug": self = .rug; return
            case "painter": self = .painter; return
            case "tv": self = .tv; return
            default: break
            }
            if rest.hasPrefix("jar:"), let index = Int(rest.dropFirst(4)) {
                self = .jar(index)
            } else if rest.hasPrefix("frame:"), let id = UUID(uuidString: String(rest.dropFirst(6))) {
                self = .frame(id)
            } else {
                return nil
            }
        }
    }

    public var easel: Easel?
    /// A blurred copy of the easel's picture, for the monitor's screen.
    public var monitorImage: String?
    /// On hover over the monitor: "Open Blender".
    public var monitorDetail: String
    public var mug: Mug
    /// Up to 6 small pictures pinned on the pegboard, newest first.
    public var pegboard: [String]
    public var pegboardDetail: String
    /// The paint jars' colours (5), from the current project's latest picture.
    public var jars: [String]
    public var shelvesDetail: String
    /// Up to 6 finished projects, newest first.
    public var gallery: [Frame]
    /// The sky and weather (shared with the Study Library's weather city).
    public var window: StudyRoomState.WindowView
    public var windowDetail: String
    /// This month's splashes, and the streak (7+ days brightens the neon).
    public var rug: [Splash]
    public var streak: Int
    public var rugDetail: String
    /// Nil hides the painter (Companion off, or set not to paint).
    public var painter: Painter?
    /// Watch mode: the TV glows; `dimmed` gives the room its cozy evening look.
    public var isWatching = false
    public var dimmed = false
    public var tvDetail = "Click to watch (YouTube in its own window)"

    public init(easel: Easel? = nil, monitorImage: String? = nil, monitorDetail: String = "", mug: Mug = Mug(),
                pegboard: [String] = [], pegboardDetail: String = "", jars: [String] = [], shelvesDetail: String = "",
                gallery: [Frame] = [], window: StudyRoomState.WindowView = .init(sky: .golden, weather: .clear), windowDetail: String = "",
                rug: [Splash] = [], streak: Int = 0, rugDetail: String = "", painter: Painter? = nil) {
        self.easel = easel
        self.monitorImage = monitorImage
        self.monitorDetail = monitorDetail
        self.mug = mug
        self.pegboard = pegboard
        self.pegboardDetail = pegboardDetail
        self.jars = jars
        self.shelvesDetail = shelvesDetail
        self.gallery = gallery
        self.window = window
        self.windowDetail = windowDetail
        self.rug = rug
        self.streak = streak
        self.rugDetail = rugDetail
        self.painter = painter
    }

    /// Hover text for a room item.
    public func detail(for item: Item) -> String? {
        switch item {
        case .jar(let index): return jars.indices.contains(index) ? "\(jars[index]) · click to copy" : nil
        case .frame(let id): return gallery.first { $0.projectID == id }?.detail
        case .window: return windowDetail.isEmpty ? nil : windowDetail
        case .rug: return rugDetail.isEmpty ? nil : rugDetail
        case .painter: return painter?.detail
        case .tv: return tvDetail
        }
    }

    /// Hover text for a room object, when the room knows better than its label.
    public func detail(for kind: SpaceObjectKind) -> String? {
        switch kind {
        case .easel: return easel?.detail ?? "No project yet · click to set one up"
        case .monitor: return monitorDetail.isEmpty ? nil : monitorDetail
        case .mug: return mug.detail
        case .poster: return pegboardDetail.isEmpty ? nil : pegboardDetail
        case .bookshelf: return shelvesDetail.isEmpty ? nil : shelvesDetail
        default: return nil
        }
    }
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
