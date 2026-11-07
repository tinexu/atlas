import AtlasCore
import AtlasSpaces
import Foundation

/// The Study Library's session tasks: written before or during a study
/// session, checked off as you go, credited with the pomodoros spent on
/// them, and carried over to the next session if you like. Tasks can link
/// a course ("#CHEM101") and come from the chalkboard's assignments; a
/// task from an assignment checks that assignment off too.
public final class StudyTasks: @unchecked Sendable {
    /// The kind of Space these tasks belong to.
    public static let space = StudyLibrary.templateID

    let core: AtlasCore
    let courses: StudyService
    let assignments: AssignmentService
    weak var sessions: StudySessions?
    var store: AtlasStore { core.store }
    private let lock = NSLock()
    private var credit = PomodoroCredit()
    private var lastCurrent: UUID?

    /// Set by the app so a linked assignment is struck through on the
    /// chalkboard before it's checked off. Without it, it's checked off at once.
    public var completeAssignment: ((_ id: UUID, _ syncReminders: Bool) -> Void)?

    init(core: AtlasCore, courses: StudyService, assignments: AssignmentService) {
        self.core = core
        self.courses = courses
        self.assignments = assignments
    }

    private var now: Date { courses.now() }

    public var settings: SessionTaskSettings {
        get { courses.settings.tasks }
        set {
            var settings = courses.settings
            settings.tasks = newValue
            courses.settings = settings
        }
    }

    /// The running session, if any.
    public var sessionID: UUID? { sessions?.current?.id }

    /// The tasks you're looking at: the running session's, or the ones
    /// waiting for the next session (planned ahead or carried over).
    public func list() -> SessionTaskList {
        if let sessionID { return SessionTaskList((try? store.sessionTasks(sessionID: sessionID)) ?? []) }
        return SessionTaskList((try? store.waitingSessionTasks(space: Self.space)) ?? [])
    }

    /// Courses, for "#CHEM101" and the colour dots.
    public func links() -> [SessionTask.Link] {
        courses.courses().map { course in
            SessionTask.Link(kind: .course, id: course.id, label: course.displayCode, color: course.color.isEmpty ? nil : course.color,
                             aliases: [course.code, course.name] + course.aliases)
        }
    }

    // MARK: - Adding

    /// Adds a task from what was typed ("Outline essay x2 #ENG110").
    @discardableResult
    public func add(_ raw: String) -> SessionTask? {
        let parsed = TaskTitleParser.parse(raw, links: links())
        guard !parsed.title.isEmpty else { return nil }
        return insert(SessionTask(title: parsed.title, estimatedPomodoros: parsed.estimate, link: parsed.link, space: Self.space,
                                  createdAt: now, sessionID: sessionID))
    }

    /// This week's chalkboard assignments not done and not already tasks.
    public func chalkboard() -> [MergedAssignment] {
        let taken = Set(list().tasks.compactMap(\.assignmentID))
        return assignments.upcoming(days: 7).filter { !$0.isDone && !$0.all.contains { taken.contains($0.id) } }
    }

    /// "From chalkboard": each picked assignment becomes a task, linked to it and its course.
    public func addAssignments(_ ids: [UUID]) {
        let byID = Dictionary(assignments.all().map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let links = links()
        for id in ids {
            guard let item = byID[id] else { continue }
            let link = item.courseID.flatMap { course in links.first { $0.id == course } }
            insert(SessionTask(title: item.title, link: link, assignmentID: item.id, space: Self.space, createdAt: now, sessionID: sessionID))
        }
    }

    @discardableResult
    private func insert(_ task: SessionTask) -> SessionTask {
        var list = list()
        let added = list.append(task)
        try? store.saveSessionTask(added)
        changed()
        return added
    }

    // MARK: - Changing

    /// Checks a task off: credits a linked assignment, and tells Mochi.
    public func check(_ id: UUID) {
        var list = list()
        guard let task = list.tasks.first(where: { $0.id == id }), !task.done else { return }
        list.check(id, at: now)
        save(list)
        let settings = self.settings
        if let assignmentID = task.assignmentID {
            if let completeAssignment {
                completeAssignment(assignmentID, settings.syncAssignments)
            } else {
                try? assignments.setDone(true, assignmentID: assignmentID, syncReminders: settings.syncAssignments)
            }
        }
        core.events.publish(AtlasEvent(AtlasEvent.Name.sessionTaskCompleted, payload: [
            "taskId": .string(id.uuidString), "title": .string(task.title), "space": .string(Self.space),
            "assignmentId": .string(task.assignmentID?.uuidString ?? ""), "last": .bool(list.allDone && sessionID != nil),
            "celebrate": .bool(settings.celebrations),
        ]))
        changed()
    }

    public func uncheck(_ id: UUID) {
        var list = list()
        list.uncheck(id)
        save(list)
        changed()
    }

    public func pin(_ id: UUID) {
        var list = list()
        list.pin(id)
        save(list)
        changed()
    }

    /// Puts the open tasks in this order.
    public func reorder(_ ids: [UUID]) {
        var list = list()
        list.reorder(ids)
        save(list)
        changed()
    }

    public func delete(_ id: UUID) {
        try? store.deleteSessionTask(id: id)
        changed()
    }

    /// Renames a task (shortcuts work here too: "x3", "#CS180").
    public func edit(_ id: UUID, title raw: String) {
        update(id) { task in
            let parsed = TaskTitleParser.parse(raw, links: links())
            guard !parsed.title.isEmpty else { return }
            task.title = parsed.title
            if let estimate = parsed.estimate { task.estimatedPomodoros = estimate }
            if let link = parsed.link { task.link = link }
        }
    }

    public func setEstimate(_ id: UUID, _ estimate: Int?) {
        update(id) { $0.estimatedPomodoros = estimate.map(SessionTask.clampEstimate) }
    }

    public func setLink(_ id: UUID, _ link: SessionTask.Link?) {
        update(id) { $0.link = link }
    }

    private func update(_ id: UUID, _ change: (inout SessionTask) -> Void) {
        guard var task = list().tasks.first(where: { $0.id == id }) else { return }
        change(&task)
        try? store.saveSessionTask(task)
        changed()
    }

    private func save(_ list: SessionTaskList) {
        for task in list.tasks { try? store.saveSessionTask(task) }
    }

    /// Keeps the pomodoro credit up to date with the current task, then tells the UI.
    private func changed() {
        let current = list().current?.id
        lock.withLock {
            if current != lastCurrent {
                lastCurrent = current
                credit.current(current, at: now)
            }
        }
        core.events.publish(AtlasEvent(AtlasEvent.Name.sessionTasksChanged, payload: ["space": .string(Self.space)]))
    }

    // MARK: - Session hooks (from StudySessions)

    /// A session began: tasks waiting for it (planned or carried over) join
    /// it, carried-over ones at the top.
    func sessionStarted(_ sessionID: UUID) {
        let waiting = (try? store.waitingSessionTasks(space: Self.space)) ?? []
        let ordered = waiting.filter(\.carriedOver) + waiting.filter { !$0.carriedOver }
        for (index, var task) in ordered.enumerated() {
            task.sessionID = sessionID
            task.order = index
            try? store.saveSessionTask(task)
        }
        lock.withLock { lastCurrent = nil }
        changed()
    }

    /// A focus phase began.
    func focusBegan() {
        let current = list().current?.id
        lock.withLock {
            lastCurrent = current
            credit.begin(at: now, current: current)
        }
    }

    /// A focus phase finished: one more pomodoro for the task that was
    /// current for most of it.
    func pomodoroFinished() {
        guard let id = lock.withLock({ credit.finish(at: now) }) else { return }
        update(id) { $0.actualPomodoros += 1 }
    }

    /// A break began: "Did you finish …?" for the task in progress.
    func breakBegan() {
        guard settings.breakCheckIn, let current = list().current else { return }
        core.events.publish(AtlasEvent(AtlasEvent.Name.sessionTaskCheckIn, payload: [
            "taskId": .string(current.id.uuidString), "title": .string(current.title), "space": .string(Self.space),
        ]))
    }

    /// The session ended: the tally for its summary. Unfinished tasks are
    /// carried over or cleared now if the setting says so; otherwise they
    /// wait for "Carry over" / "Clear" on the summary.
    func sessionEnded(_ sessionID: UUID) -> SessionTaskTally? {
        _ = lock.withLock { credit.finish(at: now) }
        let tasks = (try? store.sessionTasks(sessionID: sessionID)) ?? []
        guard !tasks.isEmpty else { return nil }
        let list = SessionTaskList(tasks)
        var unfinished = list.open.count
        switch settings.carryOver {
        case .ask: break
        case .always:
            carryOver(sessionID: sessionID)
            unfinished = 0
        case .never:
            clear(sessionID: sessionID)
            unfinished = 0
        }
        changed()
        return SessionTaskTally(done: list.finished.count, total: tasks.count,
                                finished: list.finished.map { .init(title: $0.title, planned: $0.estimatedPomodoros, actual: $0.actualPomodoros) },
                                unfinished: unfinished)
    }

    /// "Carry over": a session's unfinished tasks wait for the next one.
    public func carryOver(sessionID: UUID) {
        for var task in (try? store.sessionTasks(sessionID: sessionID)) ?? [] where !task.done {
            task.sessionID = nil
            task.carriedOver = true
            task.pinned = false
            try? store.saveSessionTask(task)
        }
        changed()
    }

    /// "Clear": a session's unfinished tasks are dropped.
    public func clear(sessionID: UUID) {
        for task in (try? store.sessionTasks(sessionID: sessionID)) ?? [] where !task.done {
            try? store.deleteSessionTask(id: task.id)
        }
        changed()
    }

    // MARK: - Stats

    /// Tasks checked off per study day, for the last `days` days (oldest first).
    public func completedPerDay(days: Int = 7) -> [(day: Date, count: Int)] {
        let studyDay = courses.settings.studyDay
        let today = studyDay.start(of: now)
        guard let first = Calendar.current.date(byAdding: .day, value: -(days - 1), to: today) else { return [] }
        let done = (try? store.completedSessionTasks(in: DateInterval(start: first, end: now.addingTimeInterval(1)), space: Self.space)) ?? []
        var counts: [Date: Int] = [:]
        for task in done { counts[studyDay.start(of: task.completedAt ?? first), default: 0] += 1 }
        return (0..<days).compactMap { offset in
            Calendar.current.date(byAdding: .day, value: offset, to: first).map { ($0, counts[$0] ?? 0) }
        }
    }

    /// Tasks checked off per course in the last `days` days (nil: no course).
    public func completedPerCourse(days: Int = 7) -> [(link: SessionTask.Link?, count: Int)] {
        let since = now.addingTimeInterval(-Double(days) * 86_400)
        let done = (try? store.completedSessionTasks(in: DateInterval(start: since, end: now.addingTimeInterval(1)), space: Self.space)) ?? []
        var counts: [UUID?: (SessionTask.Link?, Int)] = [:]
        for task in done {
            let entry = counts[task.link?.id] ?? (task.link, 0)
            counts[task.link?.id] = (entry.0, entry.1 + 1)
        }
        return counts.values.map { ($0.0, $0.1) }.sorted { $0.1 > $1.1 }
    }
}

/// `task.add`: adds a task to the current study session (or the next one).
public struct AddSessionTaskAction: AtlasAction {
    public static let id: ActionID = "task.add"
    final class Ref: @unchecked Sendable { weak var tasks: StudyTasks? }
    let ref = Ref()

    public let descriptor = ActionDescriptor(
        id: AddSessionTaskAction.id,
        title: "Add Session Task",
        summary: "Adds a task to the current study session's list (or the next session's). “x2” sets an estimate; “#CHEM101” links a course.",
        category: "Timing",
        symbolName: "checklist",
        parameters: [ParameterSpec(key: "title", label: "Task", kind: .text, help: "e.g. Outline essay x2 #ENG110")],
        isIdempotent: false,
        defaultTimeout: 5
    )

    init(tasks: StudyTasks) { ref.tasks = tasks }

    public func perform(_ parameters: ActionParameters, context: ActionContext) async throws -> ActionOutput {
        guard let tasks = ref.tasks else { throw ActionError.failed("Session tasks aren't available right now.") }
        let raw = try parameters.requiredString("title")
        guard let task = tasks.add(raw) else { throw ActionError.invalidParameter("Task", reason: "it's empty.") }
        return ActionOutput(tasks.sessionID == nil ? "Added “\(task.title)” for your next study session" : "Added “\(task.title)”")
    }
}
