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

/// What the Study Library room shows from the Study module: plain data,
/// so the 3D layer never reaches into courses or the calendar itself.
public struct StudyRoomState: Hashable, Sendable {
    public struct Book: Hashable, Sendable, Identifiable {
        public var id: UUID
        /// "CHEM 101", printed on the spine.
        public var code: String
        public var name: String
        /// Spine colour, sRGB hex.
        public var color: String
        /// Shown on hover: name, next class.
        public var detail: String

        public init(id: UUID, code: String, name: String, color: String, detail: String) {
            self.id = id
            self.code = code
            self.name = name
            self.color = color
            self.detail = detail
        }
    }

    /// The study timer on the desk.
    public struct Hourglass: Hashable, Sendable {
        /// How much of the session's focus is done, 0…1 (sand drained).
        public var drained: Double = 0
        public var isRunning = false
        public var isPaused = false
        /// Counts finished sessions; a change flips the hourglass over.
        public var flips = 0
        /// Shown on hover.
        public var detail = "Click to start studying"

        public init(drained: Double = 0, isRunning: Bool = false, isPaused: Bool = false, flips: Int = 0,
                    detail: String = "Click to start studying") {
            self.drained = drained
            self.isRunning = isRunning
            self.isPaused = isPaused
            self.flips = flips
            self.detail = detail
        }
    }

    /// Today's candle: burns down with today's study time.
    public struct Candle: Hashable, Sendable {
        /// 0 (fresh) … 1 (burned down: the daily goal is met).
        public var burned: Double = 0
        public var goalReached = false
        /// Flickers only while a session runs.
        public var flickers = false
        public var detail = ""

        public init(burned: Double = 0, goalReached: Bool = false, flickers: Bool = false, detail: String = "") {
            self.burned = burned
            self.goalReached = goalReached
            self.flickers = flickers
            self.detail = detail
        }
    }

    /// A chalk row on the board: something due this week.
    public struct BoardRow: Hashable, Sendable, Identifiable {
        public var id: UUID
        public var title: String
        /// "Today", "Tmrw", "Thu".
        public var due: String
        /// The course's colour, for the dot.
        public var color: String?
        public var isExam: Bool
        /// Just checked off: struck through, about to leave the board.
        public var isStruck: Bool

        public init(id: UUID, title: String, due: String, color: String?, isExam: Bool = false, isStruck: Bool = false) {
            self.id = id
            self.title = title
            self.due = due
            self.color = color
            self.isExam = isExam
            self.isStruck = isStruck
        }
    }

    public struct Board: Hashable, Sendable {
        public var rows: [BoardRow]
        /// Due this week but not on the board ("+3 more").
        public var more: Int

        public init(rows: [BoardRow] = [], more: Int = 0) {
            self.rows = rows
            self.more = more
        }
    }

    /// The desk calendar: days to the next deadline or exam.
    public struct DeskCalendar: Hashable, Sendable {
        public enum Tone: Hashable, Sendable { case calm, soon, today }
        /// Big digits: days left, or today's date when nothing's due.
        public var text: String
        public var caption: String
        /// The course's colour, as a small ribbon.
        public var ribbon: String?
        public var tone: Tone
        /// On hover: "CHEM101 Midterm — 4 days".
        public var detail: String
        /// The day clicking opens in Calendar.
        public var date: Date?

        public init(text: String, caption: String = "", ribbon: String? = nil, tone: Tone = .calm, detail: String = "", date: Date? = nil) {
            self.text = text
            self.caption = caption
            self.ribbon = ribbon
            self.tone = tone
            self.detail = detail
            self.date = date
        }
    }

    /// The window: the sky at this time of day and the real weather.
    public struct WindowView: Hashable, Sendable {
        public enum Sky: String, CaseIterable, Hashable, Sendable { case dawn, day, golden, blueHour, night }
        public enum Weather: String, CaseIterable, Hashable, Sendable { case clear, clouds, rain, snow, fog }
        public var sky: Sky
        public var weather: Weather
        /// On hover: "Light rain · 9° · Boston".
        public var detail: String

        public init(sky: Sky = .blueHour, weather: Weather = .rain, detail: String = "") {
            self.sky = sky
            self.weather = weather
            self.detail = detail
        }
    }

    /// A term's books on the upper shelves: one per hour studied.
    public struct ShelfSection: Hashable, Sendable, Identifiable {
        public var id: String { term }
        /// "Fall 2026", on the brass plaque.
        public var term: String
        public var hours: Int
        /// One spine colour per book, oldest first.
        public var colors: [String]
        /// On hover: hours by course, the latest book.
        public var detail: String

        public init(term: String, hours: Int, colors: [String], detail: String = "") {
            self.term = term
            self.hours = hours
            self.colors = colors
            self.detail = detail
        }
    }

    /// Brass stars on the windowsill: the study streak.
    public struct Streak: Hashable, Sendable {
        public var days: Int
        public var detail: String

        public init(days: Int = 0, detail: String = "") {
            self.days = days
            self.detail = detail
        }
    }

    /// The Companion, reading on the window seat.
    public struct Reader: Hashable, Sendable {
        public enum Style: String, Hashable, Sendable { case robot, creature, orb }
        public var style: Style
        public var primary: String
        public var secondary: String
        /// A study session's focus phase: a calm reading pose, nothing waiting shown.
        public var isFocused: Bool
        /// Offers held for the next break.
        public var waiting: Int
        public var detail: String

        public init(style: Style = .robot, primary: String = "#5B8DEF", secondary: String = "#F5F7FA", isFocused: Bool = false,
                    waiting: Int = 0, detail: String = "") {
            self.style = style
            self.primary = primary
            self.secondary = secondary
            self.isFocused = isFocused
            self.waiting = waiting
            self.detail = detail
        }
    }

    /// One per active course, in shelf order.
    public var books: [Book]
    public var hourglass: Hourglass
    public var candle: Candle
    public var board: Board
    public var deskCalendar: DeskCalendar
    public var window: WindowView
    /// Oldest term first; the last is the current one.
    public var shelf: [ShelfSection]
    public var streak: Streak
    /// Nil hides the reader (the Companion is off, or set not to read).
    public var reader: Reader?

    public init(books: [Book] = [], hourglass: Hourglass = Hourglass(), candle: Candle = Candle(), board: Board = Board(),
                deskCalendar: DeskCalendar = DeskCalendar(text: ""), window: WindowView = WindowView(), shelf: [ShelfSection] = [],
                streak: Streak = Streak(), reader: Reader? = nil) {
        self.books = books
        self.hourglass = hourglass
        self.candle = candle
        self.board = board
        self.deskCalendar = deskCalendar
        self.window = window
        self.shelf = shelf
        self.streak = streak
        self.reader = reader
    }

    /// Room items that aren't Space objects, by name suffix ("studyitem:hourglass").
    public enum Item: Hashable, Sendable {
        case hourglass, candle
        /// A chalkboard row's checkbox.
        case boardRow(UUID)
        /// A term's books on the upper shelves, by term.
        case shelf(String)
        case stars, window, reader

        public var entityName: String {
            switch self {
            case .hourglass: return "studyitem:hourglass"
            case .candle: return "studyitem:candle"
            case .boardRow(let id): return "studyitem:row:\(id.uuidString)"
            case .shelf(let term): return "studyitem:shelf:\(term)"
            case .stars: return "studyitem:stars"
            case .window: return "studyitem:window"
            case .reader: return "studyitem:reader"
            }
        }

        public init?(entityName: String) {
            let name = entityName.hasPrefix("studyitem:") ? String(entityName.dropFirst("studyitem:".count)) : entityName
            switch name {
            case "hourglass": self = .hourglass
            case "candle": self = .candle
            case "stars": self = .stars
            case "window": self = .window
            case "reader": self = .reader
            case _ where name.hasPrefix("shelf:"): self = .shelf(String(name.dropFirst(6)))
            default:
                guard name.hasPrefix("row:"), let id = UUID(uuidString: String(name.dropFirst(4))) else { return nil }
                self = .boardRow(id)
            }
        }
    }



    /// Just what changes the room's meshes (hover text doesn't).
    /// The shelf's books and the reader's look rebuild the room (once an
    /// hour at most); the window, stars and reader's mood update in place.
    public var geometry: [String] {
        books.map { "\($0.id)|\($0.code)|\($0.color)" }
            + shelf.map { "shelf|\($0.term)|\($0.colors.joined(separator: ","))" }
            + [reader.map { "reader|\($0.style.rawValue)|\($0.primary)|\($0.secondary)" } ?? "reader|none"]
    }

    /// What hovering a room item shows.
    public func detail(for item: Item) -> String? {
        switch item {
        case .hourglass: return hourglass.detail
        case .candle: return candle.detail
        case .boardRow(let id): return board.rows.first { $0.id == id }.map { "\($0.title) · \($0.due) · click to check off" }
        case .shelf(let term): return shelf.first { $0.term == term }?.detail
        case .stars: return streak.detail
        case .window: return window.detail
        case .reader: return reader?.detail
        }
    }

    public static func courseName(_ id: UUID) -> String { "course:\(id.uuidString)" }
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
