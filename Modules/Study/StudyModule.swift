import AtlasCore
import AtlasSpaces
import Foundation

/// The Study Library's headless half, installed once ATLAS's core is up.
public final class StudyModule: @unchecked Sendable {
    public let service: StudyService
    public let sessions: StudySessions
    public let assignments: AssignmentService
    public let automations: StudyAutomations
    public let weather: WeatherService
    private let actionContext = StudyActionContext()

    public init(core: AtlasCore, reminders: ReminderStore = EventKitReminderStore(),
                weatherFetcher: WeatherFetching = URLSessionWeatherFetcher()) throws {
        service = StudyService(core: core)
        weather = WeatherService(store: core.store, fetcher: weatherFetcher)
        sessions = StudySessions(core: core, courses: service)
        assignments = AssignmentService(core: core, courses: service, reminders: reminders)
        assignments.onCompleted = { [weak sessions] ids in sessions?.noteCompleted(ids) }
        sessions.restore()
        if core.registry.descriptor(for: OpenCalendarDayAction.id) == nil {
            try core.registry.register(OpenCalendarDayAction())
        }
        automations = StudyAutomations(core: core, service: service, assignments: assignments)
        actionContext.service = service
        actionContext.sessions = sessions
        actionContext.assignments = assignments
        actionContext.automations = automations
        actionContext.windows = core.windows
        let actions: [any AtlasAction] = [
            ClassSoonAction(context: actionContext), WeekAheadAction(context: actionContext), SyncExamModeAction(context: actionContext),
            OpenExamKitAction(context: actionContext), MorningCheckAction(context: actionContext), StartStudySessionAction(context: actionContext),
            OpenDefaultStudyAction(context: actionContext), OpenReadingAction(context: actionContext),
            OpenProblemSetAction(context: actionContext),
        ]
        for action in actions where core.registry.descriptor(for: action.descriptor.id) == nil {
            try core.registry.register(action)
        }
        if core.registry.descriptor(for: OpenCourseAction.id) == nil {
            try core.registry.register(OpenCourseAction(service: service))
        }
    }

    /// The hourglass and candle as they are now: cheap, so it can be asked
    /// a few times a minute while studying.
    public func liveState() -> (hourglass: StudyRoomState.Hourglass, candle: StudyRoomState.Candle) {
        let settings = service.settings
        var hourglass = StudyRoomState.Hourglass(flips: sessions.finishedCount,
                                                 detail: "Click to study for \(settings.sessionMinutes) min · right-click for more")
        if sessions.current != nil, let goal = sessions.goalSeconds {
            let focused = sessions.focusedSeconds()
            hourglass.drained = min(1, focused / goal)
            hourglass.isRunning = sessions.isRunning
            hourglass.isPaused = sessions.isPaused
            let phase = sessions.phase.map { $0.isBreak ? " · \($0.title.lowercased())" : "" } ?? ""
            hourglass.detail = sessions.isPaused
                ? "Paused · \(StudyMath.duration(max(0, goal - focused))) to go · click to resume"
                : "\(StudyMath.duration(max(0, goal - focused))) to go\(phase) · click to pause"
        }
        let studied = sessions.studiedToday()
        let goal = settings.dailyGoalHours * 3600
        let math = StudyMath.candle(studied: studied, goal: goal)
        let candle = StudyRoomState.Candle(
            burned: math.burned, goalReached: math.goalReached, flickers: sessions.isRunning,
            detail: math.goalReached ? "Today: \(StudyMath.duration(studied)) · goal reached!"
                : "Today: \(StudyMath.duration(studied)) of \(StudyMath.duration(goal))"
        )
        return (hourglass, candle)
    }

    /// One book per course, with its next class and next due on hover.
    public func books() -> [StudyRoomState.Book] {
        let upcoming = assignments.all().filter { !$0.isDone && ($0.dueAt.map { $0 >= Calendar.current.startOfDay(for: Date()) } ?? false) }
        return service.roomState().books.map { book in
            var book = book
            if let next = upcoming.first(where: { $0.courseID == book.id }) {
                book.detail += "\nNext due: \(next.title) · \(Self.dueText(next.dueAt, now: Date()))"
            }
            return book
        }
    }

    // MARK: - Window, shelf and streak

    /// The window: the time of day, and the weather when a city is set.
    public func window() -> StudyRoomState.WindowView {
        weather.view(city: service.settings.weatherCity)
    }

    /// Fetches the weather if it's due. True if the window should change.
    @discardableResult
    public func refreshWeather(force: Bool = false) async -> Bool {
        await weather.refresh(city: service.settings.weatherCity, force: force)
    }

    /// Every term's earned books, the current term last.
    public func shelf() -> [StudyRoomState.ShelfSection] {
        let terms = StudyShelf.terms(sessions: sessions.allSessions(), currentTerm: AcademicTerm.name(for: service.now()),
                                     courses: service.courses(includingArchived: true))
        return StudyShelf.sections(terms)
    }

    /// The stars on the windowsill.
    public func streak() -> StudyRoomState.Streak {
        let days = sessions.streak()
        let minimum = service.settings.streakMinutes
        let today = sessions.studiedToday()
        let counted = today >= Double(minimum) * 60
        let line: String
        if days == 0 {
            line = "No streak yet · study \(minimum) min today to start one"
        } else if counted {
            line = "Streak: \(days) day\(days == 1 ? "" : "s") · today counts"
        } else {
            line = "Streak: \(days) day\(days == 1 ? "" : "s") · \(StudyMath.duration(max(0, Double(minimum) * 60 - today))) more today makes it \(days + 1)"
        }
        return StudyRoomState.Streak(days: days, detail: line)
    }

    // MARK: - Chalkboard and desk calendar

    /// This week's assignments for the chalkboard (up to 8, then "+N more").
    public func board(now: Date = Date()) -> StudyRoomState.Board {
        let upcoming = assignments.upcoming(days: 7)
        let courses = service.courses()
        let rows = upcoming.prefix(8).map { item -> StudyRoomState.BoardRow in
            let course = item.courseID.flatMap { id in courses.first { $0.id == id } }
            return StudyRoomState.BoardRow(id: item.id, title: item.title, due: Self.dueText(item.dueAt, now: now),
                                           color: course?.color, isExam: item.kind == .exam)
        }
        return StudyRoomState.Board(rows: Array(rows), more: max(0, upcoming.count - rows.count))
    }

    /// Days until the next deadline or exam, for the desk calendar.
    public func deskCalendar(now: Date = Date()) -> StudyRoomState.DeskCalendar {
        let calendar = Calendar.current
        guard let next = assignments.nextDeadline(), let due = next.dueAt else {
            return StudyRoomState.DeskCalendar(text: "\(calendar.component(.day, from: now))", caption: "", detail: "Nothing due · click for Calendar")
        }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: due)).day ?? 0
        let course = next.courseID.flatMap { service.course(id: $0) }
        let name = [course?.code, next.title].compactMap { $0 }.joined(separator: " ")
        let when = days == 0 ? "today" : days == 1 ? "tomorrow" : "\(days) days"
        return StudyRoomState.DeskCalendar(
            text: "\(max(0, days))", caption: days == 1 ? "day" : "days", ribbon: course?.color,
            tone: days <= 0 ? .today : days <= 3 ? .soon : .calm, detail: "\(name) — \(when)", date: due
        )
    }

    /// "Today", "Tomorrow", "Thu".
    static func dueText(_ date: Date?, now: Date) -> String {
        guard let date else { return "" }
        let calendar = Calendar.current
        if calendar.isDate(date, inSameDayAs: now) { return "Today" }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(date, inSameDayAs: tomorrow) { return "Tmrw" }
        return date.formatted(.dateTime.weekday(.abbreviated))
    }
}
