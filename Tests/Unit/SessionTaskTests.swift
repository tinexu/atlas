import XCTest
@testable import AtlasCompanion
@testable import AtlasCore
@testable import AtlasSpaces
@testable import AtlasStudy

// MARK: - Inline shortcuts

final class TaskTitleParserTests: XCTestCase {
    private let chem = SessionTask.Link(kind: .course, id: UUID(), label: "CHEM 101", color: "#34466B", aliases: ["General Chemistry"])
    private let robot = SessionTask.Link(kind: .project, id: UUID(), label: "Robot", color: "#E58FA5")
    private var links: [SessionTask.Link] { [chem, robot] }

    func testEstimates() {
        XCTAssertEqual(TaskTitleParser.parse("Outline essay x2").title, "Outline essay")
        XCTAssertEqual(TaskTitleParser.parse("Outline essay x2").estimate, 2)
        XCTAssertEqual(TaskTitleParser.parse("Read chapter 3 🍅3").estimate, 3)
        XCTAssertEqual(TaskTitleParser.parse("Read chapter 3 🍅3").title, "Read chapter 3")
        XCTAssertEqual(TaskTitleParser.parse("Lab write-up 🍅 2").estimate, 2, "a space after the tomato")
        XCTAssertEqual(TaskTitleParser.parse("Lab write-up 🍅 2").title, "Lab write-up")
        XCTAssertEqual(TaskTitleParser.parse("Problem set X4").estimate, 4)
        XCTAssertEqual(TaskTitleParser.parse("Big project x12").estimate, 8, "at most 8")
    }

    func testLinks() {
        let tagged = TaskTitleParser.parse("Finish lab report #CHEM101", links: links)
        XCTAssertEqual(tagged.title, "Finish lab report")
        XCTAssertEqual(tagged.link, chem)
        XCTAssertEqual(TaskTitleParser.parse("#chem titration notes", links: links).link, chem, "a prefix, any case, anywhere")
        XCTAssertEqual(TaskTitleParser.parse("Wire the arm #robot", links: links).link, robot)
        XCTAssertEqual(TaskTitleParser.parse("Wire the arm #robt", links: links).link, robot, "one typo still matches")
        XCTAssertEqual(TaskTitleParser.parse("Review #GeneralChemistry", links: links).link, chem, "a course's full name works too")
        let both = TaskTitleParser.parse("Outline essay #chem101 x2", links: links)
        XCTAssertEqual(both.title, "Outline essay")
        XCTAssertEqual(both.estimate, 2)
        XCTAssertEqual(both.link, chem)
    }

    func testTitlesWithoutShortcutsAreLeftAlone() {
        for title in ["Box2 of the set", "Fix x2 bug before lunch", "Email #1 to the TA", "x2", "Watch the 🍅 video", "  Plain task  "] {
            let parsed = TaskTitleParser.parse(title, links: links)
            XCTAssertEqual(parsed.title, title.trimmingCharacters(in: .whitespaces), title)
            XCTAssertNil(parsed.estimate, title)
            XCTAssertNil(parsed.link, title)
        }
        XCTAssertEqual(TaskTitleParser.parse("Plan the #party", links: links).title, "Plan the #party", "an unknown #tag stays")
    }
}

// MARK: - The list

final class SessionTaskListTests: XCTestCase {
    private func list(_ titles: [String]) -> SessionTaskList {
        var list = SessionTaskList([])
        for (index, title) in titles.enumerated() {
            list.append(SessionTask(title: title, space: "s", createdAt: Date(timeIntervalSince1970: Double(index))))
        }
        return list
    }

    func testTheCurrentTaskIsTheFirstUncheckedOne() {
        var list = list(["A", "B", "C"])
        XCTAssertEqual(list.current?.title, "A")
        list.check(list.open[0].id, at: Date())
        XCTAssertEqual(list.current?.title, "B", "the next task becomes current")
        XCTAssertEqual(list.finished.map(\.title), ["A"], "it moved to Done")
        XCTAssertEqual(list.open.map(\.title), ["B", "C"])
        XCTAssertFalse(list.allDone)
        list.check(list.open[0].id, at: Date())
        list.check(list.open[0].id, at: Date())
        XCTAssertTrue(list.allDone)
        XCTAssertNil(list.current)
    }

    func testReorderAndPin() {
        var list = list(["A", "B", "C"])
        let ids = list.open.map(\.id)
        list.reorder([ids[2], ids[0], ids[1]])
        XCTAssertEqual(list.open.map(\.title), ["C", "A", "B"])
        XCTAssertEqual(list.current?.title, "C")
        list.pin(ids[1])
        XCTAssertEqual(list.current?.title, "B", "a pinned task is current wherever it is")
        list.pin(ids[0])
        XCTAssertEqual(list.current?.title, "A", "only one pin at a time")
        XCTAssertEqual(list.tasks.filter(\.pinned).count, 1)
        list.pin(ids[0])
        XCTAssertEqual(list.current?.title, "C", "pinning again unpins")
        list.uncheck(ids[0])
        list.check(ids[2], at: Date())
        XCTAssertEqual(list.current?.title, "A")
    }
}

// MARK: - Pomodoro credit

final class PomodoroCreditTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_000_000)
    private func at(_ minutes: Double) -> Date { start.addingTimeInterval(minutes * 60) }

    func testCreditsTheTaskCurrentForMostOfThePomodoro() {
        let a = UUID(), b = UUID()
        var credit = PomodoroCredit()
        credit.begin(at: start, current: a)
        credit.current(b, at: at(10))
        XCTAssertEqual(credit.finish(at: at(25)), b, "15 min on B beats 10 on A")

        credit.begin(at: start, current: a)
        credit.current(b, at: at(20))
        XCTAssertEqual(credit.finish(at: at(25)), a)

        credit.begin(at: start, current: a)
        credit.current(b, at: at(5))
        credit.current(a, at: at(15))
        XCTAssertEqual(credit.finish(at: at(25)), a, "time on a task adds up across switches")
    }

    func testNoTaskOrMostlyNoTaskCreditsNothing() {
        var credit = PomodoroCredit()
        XCTAssertNil(credit.finish(at: at(25)), "nothing began")
        credit.begin(at: start, current: nil)
        credit.current(UUID(), at: at(20))
        XCTAssertNil(credit.finish(at: at(25)), "a task added at the end doesn't get the pomodoro")
    }
}

// MARK: - In study sessions

final class StudyTaskSessionTests: XCTestCase {
    private var time: TimeHarness!
    private var reminders: MockReminderStore!
    private var study: StudyModule!
    private var tasks: StudyTasks { study.tasks }
    private var sessions: StudySessions { study.sessions }
    private var completed: [AtlasEvent] = []
    private var subscription: EventBus.Subscription?

    override func setUp() async throws {
        time = try TimeHarness()
        reminders = MockReminderStore()
        study = try StudyModule(core: time.core, reminders: reminders)
        study.service.now = { [environment = time.environment] in environment.now() }
        var settings = study.service.settings
        settings.dayBoundaryHour = 0
        study.service.settings = settings
        subscription = time.core.events.subscribe(AtlasEvent.Name.sessionTaskCompleted) { [weak self] event in
            self?.completed.append(event)
        }
    }

    override func tearDown() {
        if let subscription { time.core.events.unsubscribe(subscription) }
    }

    private func advance(minutes: Double) {
        time.environment.advance(by: minutes * 60)
        time.environment.fireDueSchedules()
    }

    private func task(_ title: String) -> SessionTask? { tasks.list().tasks.first { $0.title == title } }

    /// The spec's "done when": three tasks with estimates, start, a fourth
    /// from quick add, two checked off, summary 2 of 4, carry the rest over.
    func testAStudySessionWithTasks() throws {
        let chem = try study.service.save(Course(name: "General Chemistry", code: "CHEM 101", color: "#34466B"))
        tasks.add("Outline essay x2")
        tasks.add("Lab report #CHEM101 🍅3")
        tasks.add("Flashcards")
        XCTAssertNil(tasks.sessionID)
        XCTAssertEqual(tasks.list().open.count, 3, "planned before the timer starts")
        XCTAssertEqual(task("Lab report")?.link?.id, chem.id)
        XCTAssertEqual(task("Lab report")?.estimatedPomodoros, 3)

        let session = try sessions.start(minutes: 50, pomodoro: true)
        XCTAssertEqual(tasks.list().tasks.count, 3, "the planned tasks joined the session")
        XCTAssertTrue(tasks.list().tasks.allSatisfy { $0.sessionID == session.id })
        tasks.add("Email TA")   // quick add, mid-session
        XCTAssertEqual(task("Email TA")?.sessionID, session.id)

        advance(minutes: 25)
        XCTAssertEqual(task("Outline essay")?.actualPomodoros, 1, "the first pomodoro went to the current task")
        tasks.check(try XCTUnwrap(task("Outline essay")).id)
        XCTAssertEqual(tasks.list().current?.title, "Lab report")
        tasks.check(try XCTUnwrap(task("Lab report")).id)
        XCTAssertEqual(completed.count, 2)
        XCTAssertEqual(completed.last?.payload["last"]?.boolValue, false)
        XCTAssertEqual(completed.last?.payload["celebrate"]?.boolValue, true)

        let summary = try XCTUnwrap(sessions.end(early: true))
        let tally = try XCTUnwrap(summary.tasks)
        XCTAssertEqual(tally.headline, "2 of 4 tasks done")
        XCTAssertTrue(summary.headline.contains("2 of 4 tasks done"))
        XCTAssertEqual(tally.finished.first?.text, "Outline essay: planned 2 🍅, took 1")
        XCTAssertEqual(tally.unfinished, 2, "asks before carrying over")

        tasks.carryOver(sessionID: session.id)
        let waiting = tasks.list()
        XCTAssertEqual(Set(waiting.open.map(\.title)), ["Flashcards", "Email TA"])
        XCTAssertTrue(waiting.open.allSatisfy(\.carriedOver))

        tasks.add("New thing")
        let next = try sessions.start(minutes: 25, pomodoro: true)
        let list = tasks.list()
        XCTAssertEqual(list.open.prefix(2).map(\.title).sorted(), ["Email TA", "Flashcards"], "carried-over tasks are at the top")
        XCTAssertEqual(list.open.last?.title, "New thing")
        XCTAssertTrue(list.tasks.allSatisfy { $0.sessionID == next.id })
        XCTAssertEqual(list.tasks.count, 3, "done tasks stay with their session")
    }

    func testAPomodoroGoesToTheTaskCurrentForMostOfIt() throws {
        tasks.add("A")
        tasks.add("B")
        try sessions.start(minutes: 90, pomodoro: true)
        advance(minutes: 10)
        tasks.check(try XCTUnwrap(task("A")).id)   // B current for the last 15 min
        advance(minutes: 15)
        XCTAssertEqual(task("A")?.actualPomodoros, 0)
        XCTAssertEqual(task("B")?.actualPomodoros, 1)
        advance(minutes: 5)   // break
        tasks.add("C")
        tasks.pin(try XCTUnwrap(task("C")).id)
        advance(minutes: 25)
        XCTAssertEqual(task("C")?.actualPomodoros, 1, "pinned: C was current all pomodoro")
        XCTAssertEqual(task("B")?.actualPomodoros, 1)
    }

    func testTheBreakAsksAboutTheCurrentTask() throws {
        var checkIns: [String] = []
        let token = time.core.events.subscribe(AtlasEvent.Name.sessionTaskCheckIn) { checkIns.append($0.payload["title"]?.stringValue ?? "") }
        defer { time.core.events.unsubscribe(token) }
        tasks.add("Outline essay")
        try sessions.start(minutes: 50, pomodoro: true)
        advance(minutes: 25)
        XCTAssertEqual(checkIns, ["Outline essay"])

        var settings = tasks.settings
        settings.breakCheckIn = false
        tasks.settings = settings
        advance(minutes: 5)
        advance(minutes: 25)
        XCTAssertEqual(checkIns.count, 1, "off in settings")
    }

    func testCheckingOffTheLastTaskSaysSo() throws {
        tasks.add("Only one")
        try sessions.start(minutes: 25, pomodoro: true)
        tasks.check(try XCTUnwrap(task("Only one")).id)
        XCTAssertEqual(completed.last?.payload["last"]?.boolValue, true)
        XCTAssertTrue(tasks.list().allDone)
    }

    func testCarryOverIsOnlyForTheSameKindOfSpace() throws {
        try time.store.saveSessionTask(SessionTask(title: "Sketch thumbnails", space: CreativeLoft.templateID, carriedOver: true))
        tasks.add("Read chapter 4")
        let session = try sessions.start(minutes: 25)
        XCTAssertEqual(tasks.list().tasks.map(\.title), ["Read chapter 4"])
        XCTAssertEqual(try time.store.waitingSessionTasks(space: CreativeLoft.templateID).map(\.title), ["Sketch thumbnails"],
                       "the Creative Studio's task waits for a Creative Studio session")
        sessions.end(early: true)
        tasks.clear(sessionID: session.id)
        XCTAssertTrue(tasks.list().tasks.isEmpty, "Clear drops unfinished tasks")
    }

    func testCarryOverSettingAlwaysAndNever() throws {
        var settings = tasks.settings
        settings.carryOver = .always
        tasks.settings = settings
        tasks.add("Keep me")
        try sessions.start(minutes: 25)
        XCTAssertEqual(sessions.end(early: true)?.tasks?.unfinished, 0, "nothing to ask")
        XCTAssertEqual(tasks.list().open.map(\.title), ["Keep me"])
        XCTAssertEqual(tasks.list().open.first?.carriedOver, true)

        settings.carryOver = .never
        tasks.settings = settings
        try sessions.start(minutes: 25)
        sessions.end(early: true)
        XCTAssertTrue(tasks.list().tasks.isEmpty)
    }

    func testAnAssignmentTaskChecksOffTheChalkboardAndReminders() async throws {
        var settings = study.service.settings
        settings.remindersListID = "School"
        study.service.settings = settings
        let due = time.environment.now().addingTimeInterval(86_400)
        reminders.items["School"] = [ReminderItem(id: "r1", title: "CS180 problem set 2", dueAt: due, isCompleted: false),
                                     ReminderItem(id: "r2", title: "Read chapter 5", dueAt: due, isCompleted: false)]
        await study.assignments.sync()
        let board = tasks.chalkboard()
        XCTAssertEqual(Set(board.map(\.title)), ["CS180 problem set 2", "Read chapter 5"])

        try sessions.start(minutes: 25)
        tasks.addAssignments(board.map(\.id))
        XCTAssertEqual(tasks.list().tasks.count, 2)
        XCTAssertTrue(tasks.chalkboard().isEmpty, "already tasks")
        let ps = try XCTUnwrap(task("CS180 problem set 2"))
        XCTAssertNotNil(ps.assignmentID)

        tasks.check(ps.id)
        XCTAssertEqual(reminders.completed, ["r1"], "completed in Reminders")
        XCTAssertFalse(study.board().rows.contains { $0.title == "CS180 problem set 2" }, "off the chalkboard")
        XCTAssertEqual(sessions.current?.completedAssignments.count, 1)

        var off = tasks.settings
        off.syncAssignments = false
        tasks.settings = off
        tasks.check(try XCTUnwrap(task("Read chapter 5")).id)
        XCTAssertEqual(reminders.completed, ["r1"], "not synced with the setting off")
        XCTAssertEqual(study.assignments.all().first { $0.title == "Read chapter 5" }?.isDone, true, "but done here")
    }

    func testTasksAreSavedAndCountedInStats() throws {
        let chem = try study.service.save(Course(name: "General Chemistry", code: "CHEM 101", color: "#34466B"))
        try sessions.start(minutes: 25)
        tasks.add("Titration #chem")
        tasks.add("Notes")
        for task in tasks.list().open { tasks.check(task.id) }
        XCTAssertEqual(tasks.completedPerDay().last?.count, 2)
        let perCourse = tasks.completedPerCourse()
        XCTAssertEqual(perCourse.first { $0.link?.id == chem.id }?.count, 1)
        XCTAssertEqual(perCourse.first { $0.link == nil }?.count, 1)
        let saved = try time.store.sessionTasks(sessionID: try XCTUnwrap(sessions.current).id)
        XCTAssertEqual(saved.count, 2)
        XCTAssertTrue(saved.allSatisfy(\.done))
    }

    func testTheAddTaskActionAndCommand() async throws {
        let parser = DeterministicParser(vocabulary: CommandVocabulary(spaces: [], workflows: [], apps: [], layouts: [], snapshots: []))
        for (text, title) in [("add task finish lab report", "finish lab report"), ("todo Outline essay x2 #ENG110", "Outline essay x2 #ENG110"),
                              ("Add a to-do: email the TA", "email the TA")] {
            let plan = try XCTUnwrap(parser.parse(text).plan, text)
            XCTAssertEqual(plan.kind, .actions([.init(DeterministicParser.addTaskActionID, ["title": .string(title)])]), text)
            XCTAssertFalse(plan.needsConfirmation)
        }
        XCTAssertEqual(DeterministicParser.addTaskActionID, AddSessionTaskAction.id)
        let result = await time.core.engine.invoke(AddSessionTaskAction.id, parameters: ["title": "finish lab report x2"], source: "test")
        XCTAssertEqual(result.state, .succeeded)
        XCTAssertEqual(task("finish lab report")?.estimatedPomodoros, 2)
    }
}
