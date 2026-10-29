import AtlasCore
import AtlasSpaces
import Foundation

public enum StudySessionError: Error, LocalizedError, Equatable {
    case timerUnavailable
    case lockedDown

    public var errorDescription: String? {
        switch self {
        case .timerUnavailable: return "The focus timer isn't available right now."
        case .lockedDown: return "Lockdown is on; end it before starting a study session."
        }
    }
}

/// Study sessions: the hourglass. A session runs on the Stage 07 focus
/// timer through a pomodoro cycle (25/5 by default, or one block), until
/// its focus goal is met, you end it, or you leave the Study Library.
/// Never blocks or hides any app.
public final class StudySessions: @unchecked Sendable {
    static let activeKey = "study.activeSession"
    static let summaryKey = "study.lastSummary"
    static let clickWindow: TimeInterval = 30 * 60

    /// What's saved while a session runs, so a relaunch can wrap it up.
    struct Active: Codable {
        var session: StudySession
        var goalSeconds: TimeInterval
        var usesPomodoro: Bool
        var phase: PomodoroPhase
    }

    let core: AtlasCore
    let courses: StudyService
    var store: AtlasStore { core.store }
    private let lock = NSLock()
    private var active: Active?
    private var cycle: PomodoroCycle?
    private var lastClick: (id: UUID, at: Date)?
    private var _lastSummary: StudySummary?
    private var _finished = 0
    private var subscriptions: [EventBus.Subscription] = []

    init(core: AtlasCore, courses: StudyService) {
        self.core = core
        self.courses = courses
        _lastSummary = try? store.preference(Self.summaryKey, as: StudySummary.self)
        courses.courseOpened = { [weak self] id in self?.noteCourseOpened(id) }
        subscriptions = [
            // Leaving the Study Library ends the session.
            core.events.subscribe(AtlasEvent.Name.spaceDeactivated) { [weak self] event in
                guard let self, self.current != nil,
                      let id = event.payload["spaceId"]?.stringValue.flatMap(UUID.init(uuidString:)),
                      (try? self.store.space(id: id))??.templateID == StudyLibrary.templateID
                else { return }
                self.end(early: true)
            },
            core.events.subscribe(AtlasEvent.Name.fileModifiedEvent) { [weak self] event in
                if let path = event.payload["path"]?.stringValue { self?.fileChanged(path) }
            },
            core.events.subscribe(AtlasEvent.Name.fileCreatedEvent) { [weak self] event in
                if let path = event.payload["path"]?.stringValue { self?.fileChanged(path) }
            },
        ]
    }

    deinit {
        subscriptions.forEach(core.events.unsubscribe)
    }

    private var now: Date { courses.now() }
    private var focus: FocusService? { core.time?.focus }

    public var current: StudySession? { lock.withLock { active?.session } }
    public var lastSummary: StudySummary? { lock.withLock { _lastSummary } }
    public var phase: PomodoroPhase? { lock.withLock { cycle?.phase } }
    public var isRunning: Bool { lock.withLock { cycle }?.isRunning ?? false }
    public var isPaused: Bool { lock.withLock { cycle }?.currentSession?.state == .paused }
    public var goalSeconds: TimeInterval? { lock.withLock { active?.goalSeconds } }
    /// The book clicked last, and when.
    public var lastClickedCourse: (id: UUID, at: Date)? { lock.withLock { lastClick } }

    /// The course of the most recent session that had one (last two weeks).
    public func recentCourse() -> UUID? {
        let since = now.addingTimeInterval(-14 * 86_400)
        return ((try? store.studySessions(in: DateInterval(start: since, end: now.addingTimeInterval(1)))) ?? [])
            .last { $0.courseID != nil }?.courseID
    }

    /// Every finished session, for the shelf (a few hundred a year at most).
    public func allSessions() -> [StudySession] {
        (try? store.studySessions(in: DateInterval(start: .distantPast, end: now.addingTimeInterval(1)))) ?? []
    }

    /// Sessions finished since launch (turns the hourglass over).
    public var finishedCount: Int { lock.withLock { _finished } }

    /// Focus time so far in the running session.
    public func focusedSeconds() -> TimeInterval {
        lock.withLock { cycle }?.focusedSeconds(at: now) ?? 0
    }

    // MARK: - Control

    /// Starts a session (ending any running one). `minutes` and `pomodoro`
    /// default to the Study Library settings.
    @discardableResult
    public func start(minutes: Double? = nil, pomodoro: Bool? = nil, courseID: UUID? = nil) throws -> StudySession {
        guard let focus else { throw StudySessionError.timerUnavailable }
        if core.time?.lockdown.isActive == true { throw StudySessionError.lockedDown }
        if current != nil { end(early: true) }
        let settings = courses.settings
        let goal = max(1, minutes ?? Double(settings.sessionMinutes)) * 60
        let usesPomodoro = pomodoro ?? settings.usesPomodoro
        var session = StudySession(term: AcademicTerm.name(for: now), startedAt: now)
        if let courseID { session.guess = CourseGuess(courseID: courseID, reason: .chosen) }
        let active = Active(session: session, goalSeconds: goal, usesPomodoro: usesPomodoro, phase: PomodoroPhase())
        lock.withLock { self.active = active }
        save()
        let cycle = makeCycle(focus: focus, active: active, settings: settings)
        cycle.start(.focus)
        publishChange(announce: false)
        return session
    }

    public func pause() {
        lock.withLock { cycle }?.pause()
        publishChange(announce: false)
    }

    public func resume() {
        lock.withLock { cycle }?.resume()
        publishChange(announce: false)
    }

    public func skipPhase() {
        lock.withLock { cycle }?.skip()
    }

    /// Ends the running session (you stopped it or left the Space).
    @discardableResult
    public func end(early: Bool = true) -> StudySummary? {
        finish(early: early)
    }

    /// Credits assignments checked off during the running session.
    func noteCompleted(_ ids: [UUID]) {
        lock.withLock {
            guard active != nil else { return }
            for id in ids where !(active?.session.completedAssignments.contains(id) ?? true) {
                active?.session.completedAssignments.append(id)
            }
        }
        save()
    }

    /// Remembers a clicked course book, for guessing the session's course.
    public func noteCourseOpened(_ courseID: UUID) {
        lock.withLock { lastClick = (courseID, now) }
    }

    /// "Change": the session was about another course.
    public func setCourse(_ courseID: UUID?, forSession sessionID: UUID) throws {
        guard var session = try store.studySession(id: sessionID) else { return }
        session.guess = courseID.map { CourseGuess(courseID: $0, reason: .chosen) }
        try store.saveStudySession(session)
        if var summary = lastSummary, summary.sessionID == sessionID {
            summary.courseCode = courseID.flatMap { courses.course(id: $0)?.code }
            summary.guessReason = courseID == nil ? nil : .chosen
            lock.withLock { _lastSummary = summary }
            try? store.setPreference(summary, for: Self.summaryKey)
        }
        core.events.publish(AtlasEvent(AtlasEvent.Name.studyChanged))
    }

    // MARK: - Today, streak, stats

    /// Focus time in the current study day, including a session in progress.
    public func studiedToday() -> TimeInterval {
        let day = courses.settings.studyDay
        let start = day.start(of: now)
        let done = ((try? store.studySessions(in: DateInterval(start: start, end: day.next(after: start)))) ?? [])
            .reduce(0) { $0 + $1.focusedSeconds }
        let running = current.map { $0.startedAt >= start ? focusedSeconds() : 0 } ?? 0
        return done + running
    }

    public func streak() -> Int {
        let day = courses.settings.studyDay
        let since = day.start(of: now).addingTimeInterval(-400 * 86_400)
        var totals: [Date: TimeInterval] = [:]
        for session in (try? store.studySessions(in: DateInterval(start: since, end: now.addingTimeInterval(1)))) ?? [] {
            totals[day.start(of: session.startedAt), default: 0] += session.focusedSeconds
        }
        if let current, current.startedAt >= day.start(of: now) { totals[day.start(of: now), default: 0] += focusedSeconds() }
        return StudyMath.streak(totals: totals, now: now, day: day, minimum: Double(courses.settings.streakMinutes) * 60)
    }

    /// Hours per course per week, for the last `weeks` weeks (oldest first).
    /// Sessions with no course count under nil.
    public func weeklyHours(weeks: Int = 6) -> [(weekStart: Date, courseID: UUID?, hours: Double)] {
        let calendar = Calendar.current
        guard let thisWeek = calendar.dateInterval(of: .weekOfYear, for: now)?.start,
              let first = calendar.date(byAdding: .weekOfYear, value: -(weeks - 1), to: thisWeek)
        else { return [] }
        var hours: [Date: [UUID?: Double]] = [:]
        for session in (try? store.studySessions(in: DateInterval(start: first, end: now.addingTimeInterval(1)))) ?? [] {
            let week = calendar.dateInterval(of: .weekOfYear, for: session.startedAt)?.start ?? first
            hours[week, default: [:]][session.courseID, default: 0] += session.focusedSeconds / 3600
        }
        return hours.keys.sorted().flatMap { week in hours[week]!.map { (week, $0.key, $0.value) } }
    }

    // MARK: - Internals

    private func makeCycle(focus: FocusService, active: Active, settings: StudySettings) -> PomodoroCycle {
        var pomodoro = settings.pomodoro
        if !active.usesPomodoro { pomodoro.focusMinutes = max(1, Int((active.goalSeconds / 60).rounded(.up))) }
        let cycle = PomodoroCycle(focus: focus, events: core.events, titlePrefix: "Study", settings: pomodoro,
                                  phase: active.phase, spaceID: nil)
        cycle.limit = { [weak self, weak cycle] kind in
            guard kind == .focus, let self, let cycle, let goal = self.goalSeconds else { return nil }
            return goal - cycle.focusedSeconds(at: self.now)
        }
        cycle.onChange = { [weak self] phase in
            guard let self else { return }
            self.lock.withLock { self.active?.phase = phase }
            self.save()
        }
        cycle.onPhase = { [weak self] _, kind, minutes, announce in
            guard let self, announce else { return }
            let system = self.core.system
            Task {
                try? await system.postNotification(title: kind == .focus ? "Back to studying" : "Break time",
                                                   body: kind == .focus ? "\(Int(minutes)) min of focus." : "Take \(Int(minutes)) min.")
            }
            self.publishChange(announce: true)
        }
        cycle.onExhausted = { [weak self] in self?.finish(early: false) }
        // Stopped from the menu bar or the Companion: the session ends there.
        cycle.onStopped = { [weak self] in self?.finish(early: true) }
        lock.withLock { self.cycle = cycle }
        return cycle
    }

    private func fileChanged(_ path: String) {
        lock.withLock {
            guard active != nil, !(active?.session.files.contains(path) ?? true) else { return }
            active?.session.files.append(path)
        }
    }

    /// Files under each course's folder or notes.
    private func fileCounts(_ files: [String]) -> [UUID: Int] {
        var counts: [UUID: Int] = [:]
        for course in courses.courses() {
            let roots = [courses.resolvedFolder(of: course), course.notes.watchedPath]
                .compactMap { $0 }.map { ($0 as NSString).expandingTildeInPath }
            let count = files.filter { file in roots.contains { file == $0 || file.hasPrefix($0 + "/") } }.count
            if count > 0 { counts[course.id] = count }
        }
        return counts
    }

    @discardableResult
    private func finish(early: Bool) -> StudySummary? {
        let taken = lock.withLock { () -> (Active, PomodoroCycle?)? in
            guard let active else { return nil }
            defer {
                self.active = nil
                cycle = nil
            }
            return (active, cycle)
        }
        guard let (active, cycle) = taken else { return nil }
        cycle?.stop()
        let phase = cycle?.phase ?? active.phase
        var session = active.session
        session.endedAt = now
        session.focusedSeconds = phase.focusedSeconds
        session.pomodoros = phase.completedFocus
        let counts = fileCounts(session.files)
        // Only files in a course's folder or notes are kept.
        session.files = session.files.filter { !fileCounts([$0]).isEmpty }
        if session.guess?.reason != .chosen {
            let classNow = courses.courses().first { course in
                courses.classes(of: course, in: DateInterval(start: session.startedAt, end: now.addingTimeInterval(1))).isEmpty == false
            }?.id
            session.guess = CourseGuess.guess(clicked: lock.withLock { lastClick }, sessionStart: session.startedAt,
                                              classNow: classNow, fileCounts: counts)
        }
        try? store.saveStudySession(session)
        try? store.setPreference(Active?.none, for: Self.activeKey)

        let summary = StudySummary(
            sessionID: session.id, focusedSeconds: session.focusedSeconds, pomodoros: session.pomodoros,
            courseCode: session.courseID.flatMap { courses.course(id: $0)?.code }, guessReason: session.guess?.reason,
            notesUpdated: counts.keys.compactMap { courses.course(id: $0)?.code }.sorted(),
            assignmentsCompleted: session.completedAssignments.count, streak: streak(), endedEarly: early
        )
        lock.withLock {
            _lastSummary = summary
            _finished += 1
        }
        try? store.setPreference(summary, for: Self.summaryKey)
        core.events.publish(AtlasEvent(AtlasEvent.Name.studySessionEnded, payload: [
            "sessionId": .string(session.id.uuidString), "headline": .string(summary.headline), "early": .bool(early),
        ]))
        core.events.publish(AtlasEvent(AtlasEvent.Name.studyChanged))
        return summary
    }

    private func save() {
        guard let active = lock.withLock({ active }) else { return }
        try? store.setPreference(active, for: Self.activeKey)
    }

    private func publishChange(announce: Bool) {
        let session = current
        core.events.publish(AtlasEvent(AtlasEvent.Name.studySessionChanged, payload: [
            "sessionId": .string(session?.id.uuidString ?? ""), "phase": .string(phase?.kind.rawValue ?? ""),
            "announce": .bool(announce),
        ]))
    }

    // MARK: - Relaunch

    /// Picks up a session that was running when ATLAS closed: carries on if
    /// its focus phase is still on the timer, otherwise wraps it up with
    /// the time recorded so far.
    func restore() {
        guard let saved = try? store.preference(Self.activeKey, as: Active.self) else { return }
        lock.withLock { active = saved }
        guard let focus, let id = saved.phase.sessionID, let running = focus.session, running.id == id else {
            finish(early: true)
            return
        }
        _ = makeCycle(focus: focus, active: saved, settings: courses.settings)
        publishChange(announce: false)
    }
}
