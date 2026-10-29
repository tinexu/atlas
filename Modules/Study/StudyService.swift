import AtlasCore
import AtlasSpaces
import Foundation

/// Study Library settings, kept as a preference. Every field is optional
/// when reading, so later phases can add settings without breaking it.
public struct StudySettings: Codable, Equatable, Sendable {
    /// An Obsidian vault to scan for course folders, if you use one.
    public var vaultPath: String?
    /// Where notes live when they're not on this Mac, e.g. "Notability on iPad".
    public var notesRemark: String?
    /// The candle burns down fully at this much study in a day.
    public var dailyGoalHours: Double = 3
    /// A study day starts at this hour, so late nights count for the right day.
    public var dayBoundaryHour: Int = 4
    /// What clicking the hourglass starts.
    public var sessionMinutes: Int = 50
    public var usesPomodoro = true
    /// Calendars whose events are assignments (e.g. your school's Canvas feed).
    public var assignmentCalendarIDs: [String] = []
    /// A Reminders list whose reminders are assignments (e.g. "School").
    public var remindersListID: String?
    /// Exam cram's flashcards: an app's bundle ID or a link. Anki if it's
    /// installed when set up, otherwise Quizlet.
    public var flashcards = "https://quizlet.com/latest"
    /// Exam cram opens this folder inside the course folder, if it's there.
    public var practiceFolderName = "Practice Tests"
    /// The window shows this city's real weather (Open-Meteo, no key);
    /// empty shows only the time of day.
    public var weatherCity = ""
    /// A day counts towards the streak with at least this much study.
    public var streakMinutes = 30
    /// The Companion sits on the window seat reading.
    public var companionReads = true
    /// Offers and suggestions wait for a break or the session's end.
    public var holdSuggestions = true
    /// The Default profile's music (a Spotify URI or link).
    public var lofiPlaylist = "spotify:playlist:37i9dQZF1DWWQRwui0ExPn"
    /// The Reading and Problem set profiles open PDFs with this app.
    public var pdfReader = "com.apple.Preview"
    /// The Problem set profile's calculator: a link or an app's bundle ID.
    public var calculator = "https://www.desmos.com/calculator"
    public var pomodoro: PomodoroSettings = {
        var settings = PomodoroSettings()
        settings.focusMinutes = 25
        settings.shortBreakMinutes = 5
        return settings
    }()

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = StudySettings()
        vaultPath = try c.decodeIfPresent(String.self, forKey: .vaultPath)
        notesRemark = try c.decodeIfPresent(String.self, forKey: .notesRemark)
        dailyGoalHours = try c.decodeIfPresent(Double.self, forKey: .dailyGoalHours) ?? defaults.dailyGoalHours
        dayBoundaryHour = try c.decodeIfPresent(Int.self, forKey: .dayBoundaryHour) ?? defaults.dayBoundaryHour
        sessionMinutes = try c.decodeIfPresent(Int.self, forKey: .sessionMinutes) ?? defaults.sessionMinutes
        usesPomodoro = try c.decodeIfPresent(Bool.self, forKey: .usesPomodoro) ?? defaults.usesPomodoro
        pomodoro = try c.decodeIfPresent(PomodoroSettings.self, forKey: .pomodoro) ?? defaults.pomodoro
        assignmentCalendarIDs = try c.decodeIfPresent([String].self, forKey: .assignmentCalendarIDs) ?? []
        remindersListID = try c.decodeIfPresent(String.self, forKey: .remindersListID)
        flashcards = try c.decodeIfPresent(String.self, forKey: .flashcards) ?? defaults.flashcards
        practiceFolderName = try c.decodeIfPresent(String.self, forKey: .practiceFolderName) ?? defaults.practiceFolderName
        weatherCity = try c.decodeIfPresent(String.self, forKey: .weatherCity) ?? defaults.weatherCity
        streakMinutes = try c.decodeIfPresent(Int.self, forKey: .streakMinutes) ?? defaults.streakMinutes
        companionReads = try c.decodeIfPresent(Bool.self, forKey: .companionReads) ?? defaults.companionReads
        holdSuggestions = try c.decodeIfPresent(Bool.self, forKey: .holdSuggestions) ?? defaults.holdSuggestions
        lofiPlaylist = try c.decodeIfPresent(String.self, forKey: .lofiPlaylist) ?? defaults.lofiPlaylist
        pdfReader = try c.decodeIfPresent(String.self, forKey: .pdfReader) ?? defaults.pdfReader
        calculator = try c.decodeIfPresent(String.self, forKey: .calculator) ?? defaults.calculator
    }

    public var studyDay: StudyDay { StudyDay(boundaryHour: dayBoundaryHour) }
}

extension AtlasEvent.Name {
    /// Courses (or anything the Study Library shows) changed.
    public static let studyChanged = "study.changed"
}

/// The Study Library's brain: courses and their discovery for now;
/// sessions, assignments and automations join in later phases. Headless,
/// so it works with every window closed; everything it opens goes through
/// the engine.
public final class StudyService: @unchecked Sendable {
    static let settingsKey = "study.settings"
    static let setupKey = "study.setup.done"
    static let ignoredKey = "study.ignoredCodes"

    let core: AtlasCore
    var store: AtlasStore { core.store }
    /// Replaced in tests.
    var now: @Sendable () -> Date = { Date() }
    var fileManager: FileManager = .default
    /// A course was opened (its book clicked, or an automation): sessions
    /// use this to tell which course you're working on.
    var courseOpened: ((UUID) -> Void)?

    init(core: AtlasCore) {
        self.core = core
    }

    public var settings: StudySettings {
        get { (try? store.preference(Self.settingsKey, as: StudySettings.self)) ?? StudySettings() }
        set {
            try? store.setPreference(newValue, for: Self.settingsKey)
            changed()
        }
    }

    // MARK: - Courses

    public func courses(includingArchived: Bool = false) -> [Course] {
        (try? store.courses(includingArchived: includingArchived)) ?? []
    }

    public func course(id: UUID) -> Course? { try? store.course(id: id) }

    /// A course by ID or code (any spelling).
    public func course(reference: String) -> Course? {
        let all = courses(includingArchived: true)
        if let id = UUID(uuidString: reference), let match = all.first(where: { $0.id == id }) { return match }
        let code = CourseCode.parse(reference)?.canonical ?? reference.uppercased()
        return all.first { $0.code == code || $0.aliases.contains(code) }
            ?? all.first { $0.name.caseInsensitiveCompare(reference) == .orderedSame }
    }

    /// Saves a course; a new one goes to the end of the shelf with the next free colour.
    @discardableResult
    public func save(_ course: Course) throws -> Course {
        var course = course
        let existing = courses(includingArchived: true)
        if !existing.contains(where: { $0.id == course.id }) {
            course.position = (existing.map(\.position).max() ?? -1) + 1
            if course.color.isEmpty { course.color = CourseColors.next(after: existing) }
            if course.term.isEmpty { course.term = AcademicTerm.name(for: now()) }
        }
        if course.folderBookmark == nil, let path = course.folderPath { course.folderBookmark = Self.bookmark(for: path) }
        try store.saveCourse(course)
        changed()
        return course
    }

    public func setArchived(_ archived: Bool, courseID: UUID) throws {
        guard var course = course(id: courseID) else { return }
        course.isArchived = archived
        try store.saveCourse(course)
        changed()
    }

    /// New shelf order for active courses.
    public func reorder(_ ids: [UUID]) throws {
        try store.database.transaction {
            for (position, id) in ids.enumerated() {
                guard var course = try store.course(id: id) else { continue }
                course.position = position
                try store.saveCourse(course)
            }
        }
        changed()
    }

    public func delete(courseID: UUID) throws {
        try store.deleteCourse(id: courseID)
        changed()
    }

    // MARK: - Discovery

    public var hasFinishedSetup: Bool {
        get { (try? store.preference(Self.setupKey, as: Bool.self)) == true }
        set { try? store.setPreference(newValue, for: Self.setupKey) }
    }

    /// Codes you said aren't courses ("Ignore"), never suggested again.
    public var ignoredCodes: Set<String> {
        get { Set((try? store.preference(Self.ignoredKey, as: [String].self)) ?? []) }
        set { try? store.setPreference(newValue.sorted(), for: Self.ignoredKey) }
    }

    /// Classes in your calendar (next two weeks), folders you gave ATLAS and
    /// your Obsidian vault that aren't courses yet.
    public func suggestions(extraFolders: [String] = []) -> [CourseSuggestion] {
        let start = now()
        let events = core.time?.calendar.events(in: DateInterval(start: start, duration: 14 * 86_400)) ?? []
        let roots = ((try? store.locations()) ?? []).map(\.path) + extraFolders
        let folders = CourseDiscovery.subfolders(of: roots, depth: 2, fileManager: fileManager)
        let vault = settings.vaultPath.map { CourseDiscovery.subfolders(of: [$0], depth: 1, fileManager: fileManager) } ?? []
        return CourseDiscovery.suggest(events: events, folders: folders, vaultFolders: vault,
                                       existing: courses(includingArchived: true), ignored: ignoredCodes)
    }

    /// Adds the confirmed suggestions as courses, each with its own colour.
    @discardableResult
    public func add(_ suggestions: [CourseSuggestion]) throws -> [Course] {
        let remark = settings.notesRemark
        var added: [Course] = []
        for suggestion in suggestions {
            var notes = Course.Notes.none(remark: remark)
            if let vault = settings.vaultPath, let path = suggestion.vaultPath {
                notes = .obsidian(vaultPath: vault, relativePath: (path as NSString).lastPathComponent)
            }
            let course = Course(name: suggestion.name, code: suggestion.code.canonical, color: "", folderPath: suggestion.folderPath,
                                notes: notes)
            added.append(try save(course))
        }
        hasFinishedSetup = true
        return added
    }

    // MARK: - Calendar

    /// The course's classes (calendar events that match it) in `range`.
    public func classes(of course: Course, in range: DateInterval) -> [CalendarEvent] {
        (core.time?.calendar.events(in: range) ?? []).filter { course.matches($0.title) }
    }

    /// The course's next class in the coming week, if the calendar shows one.
    public func nextClass(of course: Course) -> CalendarEvent? {
        let start = now()
        return core.time?.calendar.events(in: DateInterval(start: start, duration: 7 * 86_400))
            .filter { $0.end > start && course.matches($0.title) }
            .min { $0.start < $1.start }
    }

    /// The course you're most likely working on: a class on now (or starting
    /// within 45 minutes), else the book you clicked in the last two hours,
    /// else your last session's course, else the first on the shelf.
    public func courseOfTheMoment(lastClicked: (id: UUID, at: Date)?, recent: UUID?) -> Course? {
        let active = courses()
        let start = now()
        let window = DateInterval(start: start.addingTimeInterval(-15 * 60), duration: 60 * 60)
        let events = core.time?.calendar.events(in: window) ?? []
        if let current = events.sorted(by: { $0.start < $1.start }).lazy.compactMap({ event in active.first { $0.matches(event.title) } }).first {
            return current
        }
        if let lastClicked, start.timeIntervalSince(lastClicked.at) < 2 * 3600, let course = active.first(where: { $0.id == lastClicked.id }) {
            return course
        }
        if let recent, let course = active.first(where: { $0.id == recent }) { return course }
        return active.first
    }

    // MARK: - Room

    /// What the room draws: one book per active course, in shelf order.
    public func roomState() -> StudyRoomState {
        StudyRoomState(books: courses().map { course in
            var detail = course.name == course.displayCode ? course.displayCode : "\(course.displayCode) · \(course.name)"
            if let next = nextClass(of: course) {
                detail += "\nNext class \(next.start.formatted(.dateTime.weekday(.abbreviated).hour().minute()))"
            }
            return StudyRoomState.Book(id: course.id, code: course.displayCode, name: course.name, color: course.color, detail: detail)
        })
    }

    // MARK: - Helpers

    private func changed() {
        core.events.publish(AtlasEvent(AtlasEvent.Name.studyChanged))
    }

    /// A security-scoped bookmark when possible, so the folder is found
    /// after a rename or move (and access survives sandboxing later).
    static func bookmark(for path: String) -> Data? {
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        return (try? url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil))
            ?? (try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil))
    }

    /// The course folder's current path, following its bookmark if it moved.
    func resolvedFolder(of course: Course) -> String? {
        if let path = course.folderPath, fileManager.fileExists(atPath: (path as NSString).expandingTildeInPath) { return path }
        guard let bookmark = course.folderBookmark else { return course.folderPath }
        var stale = false
        let url = (try? URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &stale))
            ?? (try? URL(resolvingBookmarkData: bookmark, options: [], relativeTo: nil, bookmarkDataIsStale: &stale))
        if let url, var moved = self.course(id: course.id) {
            moved.folderPath = url.path
            moved.folderBookmark = Self.bookmark(for: url.path)
            try? store.saveCourse(moved)
        }
        return url?.path ?? course.folderPath
    }
}
