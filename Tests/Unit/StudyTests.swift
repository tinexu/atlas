import RealityKit
import XCTest
@testable import AtlasCore
@testable import AtlasSpaces
@testable import AtlasSpacesUI
@testable import AtlasStudy
@testable import AtlasOrbit

final class CourseCodeTests: XCTestCase {

    func testFindsCodesInTheUsualSpellings() {
        for text in ["CHEM101", "CHEM 101", "Chem-101", "chem_101", "CHEM.101", "Lecture: CHEM 101 (Room 4)"] {
            XCTAssertEqual(CourseCode.find(in: text).map(\.canonical), ["CHEM101"], text)
        }
        XCTAssertEqual(CourseCode.find(in: "CS180A and MATH 2001").map(\.canonical), ["CS180A", "MATH2001"])
        XCTAssertEqual(CourseCode.parse("cs 180")?.display, "CS 180")
    }

    func testIgnoresThingsThatOnlyLookLikeCodes() {
        for text in ["ROOM 101", "Room 101", "Bldg 2040", "Page 123", "Fall 2026", "Spring 2027", "Zoom 4432", "Suite 300",
                     "iPhone 1500", "Order 12345", "CHEMISTRY101", "1101", "Meeting with Sam", "AB12"] {
            XCTAssertTrue(CourseCode.find(in: text).isEmpty, text)
        }
    }

    func testCourseMatchesCodesNameAndTerms() {
        var course = Course(name: "General Chemistry", code: "chem 101", aliases: ["CHM101"], color: "#34466B", matchTerms: ["Dr. Patel"])
        XCTAssertEqual(course.code, "CHEM101")
        XCTAssertTrue(course.matches("CHEM-101 Lecture"))
        XCTAssertTrue(course.matches("chm 101 lab"))
        XCTAssertTrue(course.matches("General Chemistry review"))
        XCTAssertTrue(course.matches("Office hours with Dr. Patel"))
        XCTAssertFalse(course.matches("CHEM 102 Lecture"))
        XCTAssertFalse(course.matches("Room 101"))
        course.matchTerms = []
        XCTAssertFalse(course.matches("Office hours with Dr. Patel"))
    }

    func testNameGuessDropsCodeAndFillerWords() {
        let code = CourseCode(subject: "CHEM", number: "101")
        XCTAssertEqual(CourseDiscovery.nameGuess("CHEM 101 – General Chemistry Lecture", code: code), "General Chemistry")
        XCTAssertNil(CourseDiscovery.nameGuess("CHEM101 Lecture", code: code))
    }

    func testSuggestionsNeedARecurringEventOrAFolder() {
        let now = Date()
        func event(_ title: String, day: Double) -> CalendarEvent {
            CalendarEvent(id: UUID().uuidString, calendarID: "work", title: title,
                          start: now.addingTimeInterval(day * 86_400), end: now.addingTimeInterval(day * 86_400 + 3600))
        }
        let events = [event("CHEM 101 Lecture", day: 1), event("CHEM101 Lecture", day: 3), event("CS 180 Discussion", day: 2),
                      event("CS180 Discussion", day: 9), event("PHYS 7 review", day: 1), event("HIST 210 guest talk", day: 4),
                      event("Room 101 booking", day: 1), event("Room 101 booking", day: 2)]
        let existing = [Course(name: "Old", code: "MATH 220", color: "#34466B")]
        let suggestions = CourseDiscovery.suggest(
            events: events,
            folders: ["/Users/me/Documents/School/CHEM 101", "/Users/me/Documents/School/Math-220", "/Users/me/Documents/ECON 1A"],
            vaultFolders: ["/Users/me/Vault/CS180"],
            existing: existing, ignored: []
        )
        XCTAssertEqual(suggestions.map(\.code.canonical), ["CHEM101", "CS180"], "one-off events, existing courses and rooms are skipped")
        let chem = suggestions[0]
        XCTAssertEqual(chem.folderPath, "/Users/me/Documents/School/CHEM 101")
        XCTAssertEqual(chem.summary, "calendar (2×) + /Users/me/Documents/School/CHEM 101")
        XCTAssertEqual(suggestions[1].vaultPath, "/Users/me/Vault/CS180")
        XCTAssertTrue(CourseDiscovery.suggest(events: events, folders: [], existing: [], ignored: ["CHEM101", "CS180"]).isEmpty)
    }
}

final class StudyServiceTests: XCTestCase {
    private var time: TimeHarness!
    private var study: StudyModule!
    private var service: StudyService { study.service }
    private var folder: URL!

    override func setUp() async throws {
        time = try TimeHarness()
        study = try StudyModule(core: time.core)
        service.now = { [environment = time.environment] in environment.now() }
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("study-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("School/CHEM 101"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("School/CS-180"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("Taxes 2025"), withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: folder)
    }

    func testMigrationCreatesTheStudyTables() throws {
        for table in ["course", "assignment", "study_session"] {
            XCTAssertFalse(try time.store.database.query("SELECT name FROM sqlite_master WHERE type = 'table' AND name = ?;",
                                                         [.text(table)]).isEmpty, table)
        }
    }

    func testFindsCoursesFromCalendarAndFoldersAndAddsThemWithDistinctColours() async throws {
        _ = await time.time.calendar.enable()
        let now = time.environment.now()
        for day in [1.0, 3.0] {
            time.calendarStore.add(CalendarEvent(id: "chem-\(day)", calendarID: "work", title: "CHEM 101 Lecture",
                                                 start: now.addingTimeInterval(day * 86_400), end: now.addingTimeInterval(day * 86_400 + 3600)))
        }
        let suggestions = service.suggestions(extraFolders: [folder.path])
        XCTAssertEqual(suggestions.map(\.code.canonical), ["CHEM101", "CS180"])
        let added = try service.add(suggestions)
        XCTAssertTrue(service.hasFinishedSetup)
        XCTAssertEqual(added.map(\.code), ["CHEM101", "CS180"])
        XCTAssertEqual(Set(added.map(\.color)).count, 2, "each course a different colour")
        XCTAssertEqual(added.map(\.color), Array(CourseColors.palette.prefix(2)))
        XCTAssertEqual(added.map(\.position), [0, 1])
        XCTAssertEqual(added[0].folderPath, folder.appendingPathComponent("School/CHEM 101").path)
        XCTAssertNotNil(added[0].folderBookmark)
        XCTAssertEqual(added[0].term, AcademicTerm.name(for: now))
        // Once added, they aren't suggested again.
        XCTAssertTrue(service.suggestions(extraFolders: [folder.path]).isEmpty)
        // The next class shows on hover.
        XCTAssertTrue(service.roomState().books[0].detail.contains("Next class"))
    }

    func testIgnoredCodesStayIgnored() throws {
        service.ignoredCodes.insert("CS180")
        XCTAssertEqual(service.suggestions(extraFolders: [folder.path]).map(\.code.canonical), ["CHEM101"])
    }

    func testArchivingReorderingAndColours() throws {
        let a = try service.save(Course(name: "A", code: "AAA 100", color: ""))
        let b = try service.save(Course(name: "B", code: "BBB 200", color: ""))
        let c = try service.save(Course(name: "C", code: "CCC 300", color: ""))
        XCTAssertEqual([a, b, c].map(\.color), Array(CourseColors.palette.prefix(3)))
        try service.reorder([c.id, a.id, b.id])
        XCTAssertEqual(service.courses().map(\.name), ["C", "A", "B"])
        try service.setArchived(true, courseID: a.id)
        XCTAssertEqual(service.roomState().books.map(\.name), ["C", "B"], "archived courses leave the shelf")
        XCTAssertEqual(service.courses(includingArchived: true).count, 3)
        // An archived course's colour is free again.
        XCTAssertEqual(CourseColors.next(after: service.courses(includingArchived: true)), CourseColors.palette[0])
        XCTAssertEqual(service.course(reference: "ccc-300")?.id, c.id)
    }

    func testClickingABookOpensFolderNotesAndSite() async throws {
        let chem = folder.appendingPathComponent("School/CHEM 101").path
        var course = Course(name: "Chemistry", code: "CHEM 101", color: "#34466B", folderPath: chem,
                            notes: .obsidian(vaultPath: "/Users/me/Vault", relativePath: "Chem/CHEM101"),
                            links: [Course.Link(kind: .site, url: "https://canvas.example.edu/courses/1")])
        course = try service.save(course)
        let run = await time.core.engine.invoke(OpenCourseAction.id, parameters: ["course": "CHEM101"], source: "test")
        XCTAssertEqual(run.state, .succeeded)
        let calls = time.base.system.calls
        XCTAssertTrue(calls.contains("open-file:\(chem)"))
        XCTAssertTrue(calls.contains("open-url:obsidian://open?vault=Vault&file=Chem/CHEM101"))
        XCTAssertTrue(calls.contains("open-url:https://canvas.example.edu/courses/1"))

        // Each is a toggle; notes on an iPad simply aren't opened.
        course.opens.site = false
        course.notes = .none(remark: "Notability on iPad")
        try service.save(course)
        let before = time.base.system.calls.count
        _ = await time.core.engine.invoke(OpenCourseAction.id, parameters: ["course": .string(course.id.uuidString)], source: "test")
        XCTAssertEqual(Array(time.base.system.calls.dropFirst(before)), ["open-file:\(chem)"])
    }

    func testAMovedFolderIsFoundThroughItsBookmark() throws {
        let original = folder.appendingPathComponent("School/CHEM 101")
        let course = try service.save(Course(name: "Chemistry", code: "CHEM 101", color: "#34466B", folderPath: original.path))
        let moved = folder.appendingPathComponent("Chemistry 101 (moved)")
        try FileManager.default.moveItem(at: original, to: moved)
        XCTAssertEqual(service.resolvedFolder(of: course).map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path },
                       moved.resolvingSymlinksInPath().path)
        XCTAssertEqual(service.course(id: course.id)?.folderPath.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path },
                       moved.resolvingSymlinksInPath().path)
    }
}

final class StudyRoomTests: XCTestCase {

    @MainActor
    func testCourseBooksStandOnTheShelfWithinTheBudget() throws {
        let space = Space(name: "Study Library", group: .school, templateID: StudyLibrary.templateID, accentColor: "#6F8A6E", slot: 0)
        let template = SpaceTemplates.studyLibrary
        let objects = template.objects.map { SpaceObject(spaceID: space.id, kind: $0.kind, label: $0.label, actionID: $0.actionID) }
        let books = (0..<6).map { index in
            StudyRoomState.Book(id: UUID(), code: "CHEM \(101 + index)", name: "Course \(index)",
                                color: CourseColors.palette[index], detail: "detail")
        }
        let study = StudyRoomState(books: books)
        func count(_ entity: Entity) -> Int { 1 + entity.children.reduce(0) { $0 + count($1) } }

        let full = RoomBuilder.build(space: space, room: template.room, objects: objects, detail: true, study: study)
        for book in books {
            let entity = try XCTUnwrap(full.findEntity(named: StudyRoomState.courseName(book.id)))
            XCTAssertNotNil(entity.components[CollisionComponent.self], "clickable")
        }
        XCTAssertLessThan(count(full), 150)
        let miniature = RoomBuilder.build(space: space, room: template.room, objects: objects, detail: false, study: study)
        XCTAssertLessThan(count(miniature), 40)
        XCTAssertNil(miniature.findEntity(named: StudyRoomState.courseName(books[0].id)))
        XCTAssertEqual(StudyLibraryBuilder.courseBookSlots(count: 6).count, 6)
    }

    func testRoomGeometryChangesOnlyWithTheBooks() {
        let id = UUID()
        var a = StudyRoomState(books: [.init(id: id, code: "CHEM 101", name: "Chem", color: "#34466B", detail: "Next class Tue")])
        let geometry = a.geometry
        a.books[0].detail = "Next class Thu"
        XCTAssertEqual(a.geometry, geometry, "hover text alone doesn't rebuild the room")
        a.books[0].color = "#7D3B45"
        XCTAssertNotEqual(a.geometry, geometry)
    }
}

// MARK: - Phase 2: sessions, candle, streak

final class StudyMathTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private func date(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
    }

    func testLateNightsCountForTheDayTheyStarted() {
        let day = StudyDay(boundaryHour: 4, calendar: calendar)
        XCTAssertEqual(day.start(of: date(28, 2)), date(27, 4), "2 AM is still yesterday's study day")
        XCTAssertEqual(day.start(of: date(28, 4)), date(28, 4))
        XCTAssertEqual(day.start(of: date(28, 23, 59)), date(28, 4))
        XCTAssertEqual(StudyDay(boundaryHour: 0, calendar: calendar).start(of: date(28, 2)), date(28, 0))
    }

    func testCandleBurnsWithStudyTimeUpToTheGoal() {
        XCTAssertEqual(StudyMath.candle(studied: 0, goal: 3 * 3600).burned, 0)
        XCTAssertEqual(StudyMath.candle(studied: 1.5 * 3600, goal: 3 * 3600).burned, 0.5, accuracy: 0.0001)
        XCTAssertFalse(StudyMath.candle(studied: 1.5 * 3600, goal: 3 * 3600).goalReached)
        let done = StudyMath.candle(studied: 4 * 3600, goal: 3 * 3600)
        XCTAssertEqual(done.burned, 1)
        XCTAssertTrue(done.goalReached)
    }

    func testStreakCountsDaysWithHalfAnHour() {
        let day = StudyDay(boundaryHour: 4, calendar: calendar)
        var totals: [Date: TimeInterval] = [:]
        for d in [24, 25, 26, 27] { totals[date(d, 4)] = 45 * 60 }
        totals[date(23, 4)] = 10 * 60  // too short: the streak starts after it
        // Today (the 28th) has nothing yet: yesterday's streak still stands.
        XCTAssertEqual(StudyMath.streak(totals: totals, now: date(28, 15), day: day), 4)
        totals[date(28, 4)] = 31 * 60
        XCTAssertEqual(StudyMath.streak(totals: totals, now: date(28, 15), day: day), 5)
        // 1 AM on the 29th still belongs to the 28th.
        XCTAssertEqual(StudyMath.streak(totals: totals, now: date(29, 1), day: day), 5)
        // A missed day ends it.
        XCTAssertEqual(StudyMath.streak(totals: totals, now: date(30, 15), day: day), 0)
    }

    func testCourseGuessOrder() {
        let start = Date(timeIntervalSince1970: 1_000_000)
        let clicked = UUID(), now = UUID(), files = UUID()
        XCTAssertEqual(CourseGuess.guess(clicked: (clicked, start.addingTimeInterval(-600)), sessionStart: start, classNow: now,
                                         fileCounts: [files: 3]), CourseGuess(courseID: clicked, reason: .clicked))
        XCTAssertEqual(CourseGuess.guess(clicked: (clicked, start.addingTimeInterval(-3600)), sessionStart: start, classNow: now,
                                         fileCounts: [files: 3]), CourseGuess(courseID: now, reason: .classNow), "an old click doesn't count")
        XCTAssertEqual(CourseGuess.guess(clicked: nil, sessionStart: start, classNow: nil, fileCounts: [files: 3, clicked: 1]),
                       CourseGuess(courseID: files, reason: .files))
        XCTAssertNil(CourseGuess.guess(clicked: nil, sessionStart: start, classNow: nil, fileCounts: [:]))
    }

    func testSummaryHeadline() {
        let summary = StudySummary(sessionID: UUID(), focusedSeconds: 100 * 60, pomodoros: 3, courseCode: "CHEM101", guessReason: .clicked,
                                   notesUpdated: ["CHEM101"], assignmentsCompleted: 2, streak: 5, endedEarly: false)
        XCTAssertEqual(summary.headline, "1 h 40 m studied · 3 pomodoros · CHEM101 notes updated · 2 assignments checked off · streak 5 days")
    }
}

final class StudySessionTests: XCTestCase {
    private var time: TimeHarness!
    private var study: StudyModule!
    private var sessions: StudySessions { study.sessions }
    private var ended: [String] = []

    override func setUp() async throws {
        time = try TimeHarness()
        study = try StudyModule(core: time.core)
        study.service.now = { [environment = time.environment] in environment.now() }
        var settings = study.service.settings
        settings.dayBoundaryHour = 0
        study.service.settings = settings
    }

    private func advance(minutes: Double) {
        time.environment.advance(by: minutes * 60)
        time.environment.fireDueSchedules()
    }

    func testAPomodoroSessionRunsToItsGoalAndSavesItself() throws {
        try sessions.start(minutes: 50, pomodoro: true)
        XCTAssertEqual(time.time.focus.session?.title, "Study · Focus")
        XCTAssertEqual(time.time.focus.session?.plannedSeconds, 25 * 60)
        advance(minutes: 25)
        XCTAssertEqual(time.time.focus.session?.title, "Study · Short break")
        XCTAssertEqual(study.liveState().hourglass.drained, 0.5, accuracy: 0.01)
        advance(minutes: 5)
        XCTAssertEqual(time.time.focus.session?.title, "Study · Focus")
        advance(minutes: 25)
        XCTAssertNil(sessions.current, "done at 50 minutes of focus, without a trailing break")
        XCTAssertNil(time.time.focus.session)
        let summary = try XCTUnwrap(sessions.lastSummary)
        XCTAssertEqual(summary.focusedSeconds, 50 * 60, accuracy: 1)
        XCTAssertEqual(summary.pomodoros, 2)
        XCTAssertFalse(summary.endedEarly)
        XCTAssertEqual(summary.streak, 1)
        let saved = try time.store.studySessions(in: DateInterval(start: .distantPast, end: .distantFuture))
        XCTAssertEqual(saved.count, 1)
        XCTAssertEqual(saved[0].focusedSeconds, 50 * 60, accuracy: 1)
        XCTAssertEqual(sessions.studiedToday(), 50 * 60, accuracy: 1)
        XCTAssertFalse(time.base.system.calls.contains { $0.hasPrefix("notify:Study · Focus") },
                       "the focus timer's own end notification doesn't fire for study phases")
    }

    func testASingleBlockSessionHasNoBreaks() throws {
        try sessions.start(minutes: 30, pomodoro: false)
        XCTAssertEqual(time.time.focus.session?.plannedSeconds, 30 * 60)
        advance(minutes: 30)
        XCTAssertNil(sessions.current)
        XCTAssertEqual(sessions.lastSummary?.focusedSeconds ?? 0, 30 * 60, accuracy: 1)
    }

    func testEndingEarlyKeepsWhatWasDone() throws {
        try sessions.start(minutes: 50)
        advance(minutes: 10)
        XCTAssertEqual(study.liveState().candle.burned, 10.0 / 180, accuracy: 0.01)
        XCTAssertTrue(study.liveState().candle.flickers)
        let summary = try XCTUnwrap(sessions.end(early: true))
        XCTAssertEqual(summary.focusedSeconds, 10 * 60, accuracy: 1)
        XCTAssertEqual(summary.pomodoros, 0)
        XCTAssertTrue(summary.endedEarly)
        XCTAssertFalse(study.liveState().candle.flickers, "calm once the session ends")
        XCTAssertEqual(study.liveState().hourglass.flips, 1)
    }

    func testPauseStopsTheClock() throws {
        try sessions.start(minutes: 50)
        advance(minutes: 5)
        sessions.pause()
        XCTAssertTrue(sessions.isPaused)
        advance(minutes: 20)
        XCTAssertEqual(sessions.focusedSeconds(), 5 * 60, accuracy: 1)
        sessions.resume()
        advance(minutes: 5)
        XCTAssertEqual(sessions.focusedSeconds(), 10 * 60, accuracy: 1)
    }

    func testStoppingFromTheMenuBarEndsTheSession() throws {
        try sessions.start(minutes: 50)
        advance(minutes: 12)
        time.time.focus.stop()
        XCTAssertNil(sessions.current)
        XCTAssertEqual(sessions.lastSummary?.focusedSeconds ?? 0, 12 * 60, accuracy: 1)
    }

    func testLeavingTheStudyLibraryEndsTheSession() throws {
        let h = time!
        let space = Space(name: "Study Library", group: .school, templateID: StudyLibrary.templateID, accentColor: "#6F8A6E", slot: 0)
        try h.store.saveSpace(space)
        try sessions.start(minutes: 50)
        advance(minutes: 3)
        h.core.events.publish(AtlasEvent(AtlasEvent.Name.spaceDeactivated, payload: ["spaceId": .string(space.id.uuidString)]))
        XCTAssertNil(sessions.current)
    }

    func testNoSessionDuringLockdown() async throws {
        var settings = LockdownSettings()
        settings.modes = [LockdownMode(name: "Test")]
        await time.time.lockdown.start(spaceID: UUID(), spaceName: "Coding Lab", profileID: UUID(), minutes: 60, settings: settings,
                                       plan: time.time.lockdown.plan(for: settings))
        XCTAssertThrowsError(try sessions.start()) { XCTAssertEqual($0 as? StudySessionError, .lockedDown) }
        time.time.lockdown.end()
    }

    func testCourseAndNotesFromTheBookYouOpenedAndFilesYouChanged() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("chem-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let chem = try study.service.save(Course(name: "Chemistry", code: "CHEM 101", color: "", folderPath: folder.path))
        let cs = try study.service.save(Course(name: "CS", code: "CS 180", color: ""))
        _ = cs
        study.service.courseOpened?(chem.id)
        try sessions.start(minutes: 50)
        time.core.events.publish(AtlasEvent(AtlasEvent.Name.fileModifiedEvent, payload: ["path": .string(folder.appendingPathComponent("notes.md").path)]))
        time.core.events.publish(AtlasEvent(AtlasEvent.Name.fileModifiedEvent, payload: ["path": "/Users/me/Downloads/other.pdf"]))
        advance(minutes: 20)
        let summary = try XCTUnwrap(sessions.end())
        XCTAssertEqual(summary.courseCode, "CHEM101")
        XCTAssertEqual(summary.guessReason, .clicked)
        XCTAssertEqual(summary.notesUpdated, ["CHEM101"])
        let saved = try XCTUnwrap(time.store.studySession(id: summary.sessionID))
        XCTAssertEqual(saved.files, [folder.appendingPathComponent("notes.md").path], "only course files are kept")

        try sessions.setCourse(cs.id, forSession: summary.sessionID)
        XCTAssertEqual(try time.store.studySession(id: summary.sessionID)?.guess, CourseGuess(courseID: cs.id, reason: .chosen))
        XCTAssertEqual(sessions.lastSummary?.courseCode, "CS180")
    }

    func testARelaunchWrapsUpASessionWhoseTimerIsGone() throws {
        try sessions.start(minutes: 50)
        advance(minutes: 15)
        // As after a crash: the focus timer's session ended while ATLAS was closed.
        time.time.focus.stop()
        let saved = try XCTUnwrap(time.store.studySessions(in: DateInterval(start: .distantPast, end: .distantFuture)).first)
        XCTAssertEqual(saved.focusedSeconds, 15 * 60, accuracy: 1)
        let relaunched = try StudyModule(core: time.core)
        XCTAssertNil(relaunched.sessions.current)
    }

    func testWeeklyHoursByCourse() throws {
        let chem = try study.service.save(Course(name: "Chemistry", code: "CHEM 101", color: ""))
        try sessions.start(minutes: 60, pomodoro: false, courseID: chem.id)
        advance(minutes: 60)
        let rows = sessions.weeklyHours()
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].courseID, chem.id)
        XCTAssertEqual(rows[0].hours, 1, accuracy: 0.01)
    }
}

final class StudyRoomSessionTests: XCTestCase {
    @MainActor
    func testHourglassAndCandleFollowTheRoomState() throws {
        let built = StudyLibraryBuilder.build(objects: [], detail: true, study: StudyRoomState())
        let parts = built.parts
        let hourglass = try XCTUnwrap(parts.hourglass)
        XCTAssertEqual(hourglass.container.name, "studyitem:hourglass")
        XCTAssertNotNil(hourglass.container.components[CollisionComponent.self])
        let motion = StudyLibraryMotion(parts: parts, reduceMotion: true)
        motion.update(StudyRoomState(hourglass: .init(drained: 0.5, isRunning: true), candle: .init(burned: 0.5, flickers: true)))
        XCTAssertEqual(hourglass.topSand.scale.x, cbrt(0.5), accuracy: 0.001)
        XCTAssertEqual(hourglass.pile.scale.x, cbrt(0.5), accuracy: 0.001)
        XCTAssertTrue(hourglass.stream.isEnabled)
        XCTAssertEqual(parts.candleWax?.scale.y ?? 0, 1 - 0.85 * 0.5, accuracy: 0.001)
        motion.update(StudyRoomState(hourglass: .init(drained: 0.5, isRunning: true, isPaused: true)))
        XCTAssertFalse(hourglass.stream.isEnabled, "pausing stops the stream")
        XCTAssertEqual(parts.candleWax?.scale.y ?? 0, 1, accuracy: 0.001, "a fresh candle")
    }
}

// MARK: - Phase 3: assignments, chalkboard, desk calendar

final class MockReminderStore: ReminderStore, @unchecked Sendable {
    private let lock = NSLock()
    var accessState: CalendarAccess = .granted
    var items: [String: [ReminderItem]] = [:]
    private(set) var completed: [String] = []

    func access() -> CalendarAccess { accessState }
    func requestAccess() async -> CalendarAccess { accessState }
    func lists() -> [ReminderList] { items.keys.sorted().map { ReminderList(id: $0, title: $0) } }
    func reminders(listID: String) async -> [ReminderItem] { lock.withLock { items[listID] ?? [] } }
    func complete(id: String) throws {
        lock.withLock {
            completed.append(id)
            for (list, reminders) in items {
                items[list] = reminders.map { var r = $0; if r.id == id { r.isCompleted = true }; return r }
            }
        }
    }
    func observeChanges(_ handler: @escaping @Sendable () -> Void) -> TriggerToken { TriggerToken {} }
}

final class AssignmentTests: XCTestCase {
    private var time: TimeHarness!
    private var reminders: MockReminderStore!
    private var study: StudyModule!
    private var service: AssignmentService { study.assignments }
    private var chem: Course!
    private var cs: Course!
    private var now: Date { time.environment.now() }

    override func setUp() async throws {
        time = try TimeHarness()
        reminders = MockReminderStore()
        study = try StudyModule(core: time.core, reminders: reminders)
        study.service.now = { [environment = time.environment] in environment.now() }
        chem = try study.service.save(Course(name: "General Chemistry", code: "CHEM 101", color: ""))
        cs = try study.service.save(Course(name: "Programming", code: "CS 180", color: ""))
        _ = await time.time.calendar.enable()
        time.calendarStore.calendarList.append(CalendarInfo(id: "canvas", title: "Canvas", source: "Subscribed"))
        var calendar = time.time.calendar.settings
        calendar.visibleCalendarIDs.append("canvas")
        time.time.calendar.settings = calendar
        var settings = study.service.settings
        settings.assignmentCalendarIDs = ["canvas"]
        settings.remindersListID = "School"
        study.service.settings = settings
    }

    private func event(_ id: String, _ title: String, days: Double, calendar: String = "work", allDay: Bool = false) {
        let start = now.addingTimeInterval(days * 86_400)
        time.calendarStore.add(CalendarEvent(id: id, calendarID: calendar, title: title, start: start, end: start.addingTimeInterval(3600), isAllDay: allDay))
    }

    func testDueAndExamWords() {
        XCTAssertTrue(Assignment.isExam("CHEM101 Midterm"))
        XCTAssertTrue(Assignment.isExam("Quiz 3"))
        XCTAssertFalse(Assignment.isExam("Testing lab setup"), "whole words only")
        XCTAssertTrue(Assignment.isDue("Problem Set 4 due"))
        XCTAssertTrue(Assignment.isDue("HW 2"))
        XCTAssertFalse(Assignment.isDue("CHEM 101 Lecture"))
    }

    func testMergesTheSameThingFromTwoSources() {
        let due = now.addingTimeInterval(2 * 86_400)
        let a = Assignment(courseID: chem.id, title: "CHEM 101: Problem Set 3 due", dueAt: due, source: .calendar, externalID: "e1")
        let b = Assignment(courseID: chem.id, title: "Problem set 3", dueAt: due.addingTimeInterval(3600), source: .reminders, externalID: "r1")
        let c = Assignment(courseID: cs.id, title: "Problem set 3", dueAt: due, source: .reminders, externalID: "r2")
        let d = Assignment(courseID: chem.id, title: "Problem set 3", dueAt: due.addingTimeInterval(3 * 86_400), source: .manual, externalID: "m1")
        let merged = AssignmentMerge.merge([a, b, c, d])
        XCTAssertEqual(merged.count, 3, "other course and other day stay separate")
        let chemPS3 = merged.first { $0.all.contains { $0.externalID == "e1" } }!
        XCTAssertEqual(chemPS3.primary.source, .reminders, "a reminder leads, so checking off completes it")
        XCTAssertEqual(Set(chemPS3.sources), [.reminders, .calendar])
    }

    func testCalendarSyncTakesTheFeedAndDueEventsButNotLectures() async throws {
        event("lec1", "CHEM 101 Lecture", days: 1)
        event("lec2", "CHEM 101 Lecture", days: 3)
        event("mid", "CHEM101 Midterm", days: 4)
        event("canvas1", "Lab report 2 [CHEM 101]", days: 2, calendar: "canvas")
        event("canvas2", "CS180: Project 1", days: 6, calendar: "canvas", allDay: true)
        event("dentist", "Dentist", days: 2)
        await service.sync()
        let all = service.all()
        XCTAssertEqual(Set(all.map(\.title)), ["CHEM101 Midterm", "Lab report 2 [CHEM 101]", "CS180: Project 1"])
        XCTAssertEqual(all.first { $0.title == "CHEM101 Midterm" }?.kind, .exam)
        XCTAssertEqual(all.first { $0.title == "CHEM101 Midterm" }?.courseID, chem.id)
        XCTAssertEqual(all.first { $0.title == "CS180: Project 1" }?.courseID, cs.id)
        XCTAssertEqual(time.calendarStore.writes, 0, "calendar events are never edited")

        // Done is kept across syncs; a deleted event leaves.
        let lab = try XCTUnwrap(all.first { $0.title == "Lab report 2 [CHEM 101]" })
        try service.setDone(true, assignmentID: lab.id)
        time.calendarStore.remove("canvas2")
        await service.sync()
        XCTAssertEqual(service.all().first { $0.title == "Lab report 2 [CHEM 101]" }?.isDone, true)
        XCTAssertNil(service.all().first { $0.title == "CS180: Project 1" })
        XCTAssertEqual(time.calendarStore.writes, 0)
    }

    func testRemindersSyncAndCheckingOffCompletesTheReminder() async throws {
        let due = now.addingTimeInterval(86_400)
        reminders.items["School"] = [
            ReminderItem(id: "r1", title: "CS180 problem set 2", dueAt: due, isCompleted: false),
            ReminderItem(id: "r2", title: "Buy flashcards", dueAt: nil, isCompleted: false),
            ReminderItem(id: "r3", title: "CHEM101 reading", dueAt: due, isCompleted: true),
        ]
        reminders.items["Groceries"] = [ReminderItem(id: "g1", title: "Milk", dueAt: nil, isCompleted: false)]
        event("feed", "CS180 Problem Set 2", days: 1, calendar: "canvas")
        await service.sync()
        let all = service.all()
        XCTAssertFalse(all.contains { $0.title == "Milk" }, "only the chosen list")
        XCTAssertEqual(all.first { $0.title == "CHEM101 reading" }?.isDone, true)
        let ps2 = try XCTUnwrap(all.first { $0.title == "CS180 problem set 2" })
        XCTAssertEqual(ps2.courseID, cs.id)
        XCTAssertEqual(Set(ps2.sources), [.reminders, .calendar], "the feed event and the reminder are one thing")

        try sessionsStart()
        try service.setDone(true, assignmentID: ps2.id)
        XCTAssertEqual(reminders.completed, ["r1"])
        XCTAssertTrue(service.all().first { $0.id == ps2.id }!.isDone)
        XCTAssertEqual(time.calendarStore.writes, 0)
        let summary = try XCTUnwrap(study.sessions.end())
        XCTAssertEqual(summary.assignmentsCompleted, 2, "both source rows are credited to the session")

        await service.sync()
        XCTAssertTrue(service.all().first { $0.title == "CS180 problem set 2" }!.isDone, "stays done after the next sync")
    }

    private func sessionsStart() throws {
        try study.sessions.start(minutes: 50)
    }

    func testManualAssignmentsAndTheBoard() async throws {
        for index in 0..<10 {
            try service.add(title: "Reading \(index + 1)", courseID: index.isMultiple(of: 2) ? chem.id : nil,
                            dueAt: now.addingTimeInterval(Double(index % 6 + 1) * 3600 * 20))
        }
        try service.add(title: "Next month", courseID: nil, dueAt: now.addingTimeInterval(30 * 86_400))
        let board = study.board(now: now)
        XCTAssertEqual(board.rows.count, 8)
        XCTAssertEqual(board.more, 2)
        XCTAssertEqual(board.rows.first?.color, chem.color)
        XCTAssertFalse(board.rows.contains { $0.title == "Next month" })

        let manual = try XCTUnwrap(service.all().first { $0.title == "Next month" })
        try service.delete(assignmentID: manual.id)
        XCTAssertNil(service.all().first { $0.title == "Next month" })
    }

    func testDeskCalendarCountsDownAndChangesColour() throws {
        XCTAssertEqual(study.deskCalendar(now: now).caption, "", "nothing due: today's date")
        let calendar = Calendar.current
        let inFive = calendar.date(byAdding: .day, value: 5, to: calendar.startOfDay(for: now))!.addingTimeInterval(12 * 3600)
        try service.add(title: "Midterm", courseID: chem.id, dueAt: inFive)
        var desk = study.deskCalendar(now: now)
        XCTAssertEqual(desk.text, "5")
        XCTAssertEqual(desk.tone, .calm)
        XCTAssertEqual(desk.ribbon, chem.color)
        XCTAssertEqual(desk.detail, "CHEM101 Midterm — 5 days")
        desk = study.deskCalendar(now: calendar.date(byAdding: .day, value: 3, to: now)!)
        XCTAssertEqual(desk.tone, .soon)
        desk = study.deskCalendar(now: inFive.addingTimeInterval(-3600))
        XCTAssertEqual(desk.tone, .today)
        XCTAssertEqual(desk.detail, "CHEM101 Midterm — today")
    }
}

final class StudyBoardRoomTests: XCTestCase {
    @MainActor
    func testChalkRowsAreClickableAndStrikeThrough() throws {
        let rows = (0..<3).map { StudyRoomState.BoardRow(id: UUID(), title: "Row \($0)", due: "Thu", color: "#34466B") }
        var study = StudyRoomState(board: .init(rows: rows, more: 0), deskCalendar: .init(text: "4", caption: "days", tone: .soon))
        let built = StudyLibraryBuilder.build(objects: [], detail: true, study: study)
        let content = try XCTUnwrap(built.parts.boardContent)
        let checkbox = try XCTUnwrap(content.findEntity(named: StudyRoomState.Item.boardRow(rows[1].id).entityName))
        XCTAssertNotNil(checkbox.components[CollisionComponent.self])
        XCTAssertEqual(StudyRoomState.Item(entityName: checkbox.name), .boardRow(rows[1].id))
        XCTAssertFalse(built.parts.calendarFace?.children.isEmpty ?? true)

        let motion = StudyLibraryMotion(parts: built.parts, reduceMotion: true)
        motion.update(study)
        let before = content.children.count
        study.board.rows[1].isStruck = true
        motion.update(study)
        XCTAssertEqual(content.children.count, before + 1, "a strike line is added, the board isn't redrawn")
        study.board.rows.remove(at: 1)
        motion.update(study)
        XCTAssertNil(content.findEntity(named: StudyRoomState.Item.boardRow(rows[1].id).entityName))
    }
}

// MARK: - Phase 4: automations

final class StudyAutomationTests: XCTestCase {
    private var h: SpacesHarness!
    private var time: TimeServices!
    private var environment: MockTriggerEnvironment!
    private var study: StudyModule!
    private var library: Space!
    private var offers: OfferCollector!

    override func setUp() async throws {
        h = try SpacesHarness()
        environment = h.base.startTriggers()
        time = h.core.startScheduling(environment: environment, calendarStore: MockCalendarStore(), calendar: TimeHarness.utc)
        study = try StudyModule(core: h.core, reminders: MockReminderStore())
        study.service.now = { [environment] in environment!.now() }
        library = try h.library.createSpace(from: SpaceTemplates.studyLibrary)
        offers = OfferCollector()
        let offers = self.offers!
        _ = h.core.events.subscribe(AtlasEvent.Name.companionOffer) { offers.append($0) }
    }

    private var now: Date { environment.now() }

    func testInstallsVisibleEditableWorkflowsOnce() throws {
        try study.automations.install()
        for kind in StudyAutomations.Kind.allCases {
            let workflow = try XCTUnwrap(study.automations.workflow(kind), kind.rawValue)
            XCTAssertEqual(workflow.isEnabled, kind != .morningCheck, "\(kind) on by default; morning check off")
            XCTAssertFalse(workflow.triggerNodes.isEmpty)
        }
        XCTAssertEqual(study.automations.workflow(.classSoon)?.triggerNodes.first?.actionID.rawValue,
                       WorkflowStep.trigger(TriggerCatalog.calendarEventApproaching).actionID.rawValue)
        XCTAssertEqual(study.automations.workflow(.examMode)?.triggerNodes.count, 2, "daily and on entering the Study Library")
        let ids = StudyAutomations.Kind.allCases.compactMap { study.automations.workflow($0)?.id }
        // Install again: nothing new; a deleted one stays deleted.
        try h.core.delete(workflowID: ids[1])
        try study.automations.install()
        XCTAssertNil(study.automations.workflow(.weekAhead))
        XCTAssertEqual(StudyAutomations.Kind.allCases.compactMap { study.automations.workflow($0)?.id }, ids.enumerated().filter { $0.offset != 1 }.map(\.element))
        XCTAssertEqual(try h.store.profiles(spaceID: library.id).filter { $0.name == "Exam cram" }.count, 1)
    }

    func testClassSoonOffersTheBookOnlyForClasses() async throws {
        let chem = try study.service.save(Course(name: "Chemistry", code: "CHEM 101", color: ""))
        let run = await h.core.engine.invoke(ClassSoonAction.id, parameters: ["title": "CHEM101 Lecture"], source: "test")
        XCTAssertEqual(run.state, .succeeded)
        let offer = try XCTUnwrap(offers.values.first)
        XCTAssertEqual(offer.payload["message"]?.stringValue, "CHEM 101 starts soon — open its book?")
        XCTAssertEqual(offer.payload["actionId"]?.stringValue, OpenCourseAction.id.rawValue)
        XCTAssertEqual(offer.payload["param.course"]?.stringValue, chem.id.uuidString)
        _ = await h.core.engine.invoke(ClassSoonAction.id, parameters: ["title": "Dentist"], source: "test")
        XCTAssertEqual(offers.values.count, 1)
    }

    func testWeekAheadCountsAssignmentsAndExams() async throws {
        let chem = try study.service.save(Course(name: "Chemistry", code: "CHEM 101", color: ""))
        try study.assignments.add(title: "PS 3", courseID: chem.id, dueAt: now.addingTimeInterval(2 * 86_400))
        try study.assignments.add(title: "Essay", courseID: nil, dueAt: now.addingTimeInterval(3 * 86_400))
        try study.assignments.add(title: "CHEM101 Midterm", courseID: chem.id, dueAt: now.addingTimeInterval(4 * 86_400))
        try study.assignments.add(title: "Later", courseID: nil, dueAt: now.addingTimeInterval(20 * 86_400))
        let run = await h.core.engine.invoke(WeekAheadAction.id, source: "test")
        XCTAssertEqual(run.steps.first?.message, "Your week: 2 assignments, 1 exam.")
        XCTAssertTrue(h.system.calls.contains("notify:Week ahead"))
    }

    func testExamModeSwitchesTheDefaultProfileAndBack() throws {
        try study.automations.install()
        let usual = try XCTUnwrap(h.store.profiles(spaceID: library.id).first(where: \.isDefault))
        XCTAssertEqual(try study.automations.syncExamMode(), "No exam within 3 days")
        let exam = try study.assignments.add(title: "CHEM101 Final exam", courseID: nil, dueAt: now.addingTimeInterval(2 * 86_400))
        try study.automations.syncExamMode()
        XCTAssertEqual(try h.store.profiles(spaceID: library.id).first(where: \.isDefault)?.name, "Exam cram")
        XCTAssertEqual(study.deskCalendar(now: now).tone, .soon, "the desk calendar is rose")
        // Running it again changes nothing.
        try study.automations.syncExamMode()
        XCTAssertEqual(try h.store.profiles(spaceID: library.id).first(where: \.isDefault)?.name, "Exam cram")
        try study.assignments.setDone(true, assignmentID: exam.id)
        try study.automations.syncExamMode()
        XCTAssertEqual(try h.store.profiles(spaceID: library.id).first(where: \.isDefault)?.id, usual.id, "back to the usual profile")
    }

    func testMorningCheckOncePerDay() async throws {
        try study.assignments.add(title: "PS 3", courseID: nil, dueAt: now.addingTimeInterval(3600))
        let first = await h.core.engine.invoke(MorningCheckAction.id, parameters: ["space": .string(library.id.uuidString)], source: "test")
        XCTAssertEqual(first.steps.first?.message, "Due today: PS 3")
        XCTAssertEqual(offers.values.first?.payload["actionId"]?.stringValue, StartStudySessionAction.id.rawValue)
        let second = await h.core.engine.invoke(MorningCheckAction.id, parameters: ["space": .string(library.id.uuidString)], source: "test")
        XCTAssertEqual(second.steps.first?.message, "Already checked today")
        XCTAssertEqual(offers.values.count, 1)
        let other = await h.core.engine.invoke(MorningCheckAction.id, parameters: ["space": .string(UUID().uuidString)], source: "test")
        XCTAssertEqual(other.steps.first?.message, "Not the Study Library")
    }

    func testCoursePDFRulesMatchClearlyOrAskWhenTwoCoursesMatch() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("pdfs-\(UUID().uuidString)")
        for name in ["Chem", "CS"] { try FileManager.default.createDirectory(at: base.appendingPathComponent(name), withIntermediateDirectories: true) }
        defer { try? FileManager.default.removeItem(at: base) }
        let chem = try study.service.save(Course(name: "Chemistry", code: "CHEM 101", color: "", folderPath: base.appendingPathComponent("Chem").path))
        _ = try study.service.save(Course(name: "Programming", code: "CS 180", color: "", folderPath: base.appendingPathComponent("CS").path))
        try study.automations.syncCourseRules()
        let rules = FileOrganizer(core: h.core).rules().filter { $0.starterID?.hasPrefix("study.coursePDF.") == true }
        XCTAssertEqual(rules.count, 4)
        let chemClear = try XCTUnwrap(rules.first { $0.starterID == "study.coursePDF.\(chem.id.uuidString)" })
        let chemShared = try XCTUnwrap(rules.first { $0.starterID == "study.coursePDF.\(chem.id.uuidString).shared" })
        XCTAssertEqual(chemClear.mode, .automatic)
        XCTAssertEqual(chemShared.mode, .askFirst)
        XCTAssertNotNil(chemClear.workflowID, "it runs as a Flow workflow")
        guard case .moveTo(let folder) = chemClear.action else { return XCTFail() }
        XCTAssertTrue(folder.hasSuffix("Chem/Downloads"))

        func matches(_ rule: FileRule, _ name: String) async -> Bool {
            let path = "/Users/me/Downloads/\(name)"
            h.system.existingPaths[path] = .file
            return await RuleMatcher.matches(rule, path: path, system: h.system)
        }
        for (name, clear, shared) in [("CHEM101 Lab 3.pdf", true, false), ("chem-101_syllabus.pdf", true, false),
                                      ("CS180 and CHEM 101 crossover.pdf", false, true), ("CHEM101 notes.docx", false, false),
                                      ("Room 101 map.pdf", false, false), ("CHEM1011.pdf", false, false)] {
            let isClear = await matches(chemClear, name)
            let isShared = await matches(chemShared, name)
            XCTAssertEqual(isClear, clear, name)
            XCTAssertEqual(isShared, shared, name)
        }

        // A course's rules follow it: archived → gone.
        try study.service.setArchived(true, courseID: chem.id)
        try study.automations.syncCourseRules()
        let remaining = FileOrganizer(core: h.core).rules().filter { $0.starterID?.hasPrefix("study.coursePDF.") == true }
        XCTAssertEqual(remaining.map(\.name), ["Course PDFs: CS 180"])
    }

    func testTimingSettingsEditTheWorkflows() throws {
        try study.automations.install()
        study.automations.classSoonMinutes = 15
        study.automations.weekAheadTime = "18:30"
        XCTAssertEqual(study.automations.workflow(.classSoon)?.triggerNodes.first?.parameters["minutesBefore"], 15)
        XCTAssertEqual(study.automations.weekAheadTime, "18:30")
        try study.automations.setEnabled(true, .morningCheck)
        XCTAssertEqual(study.automations.workflow(.morningCheck)?.isEnabled, true)
    }
}

private final class OfferCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [AtlasEvent] = []
    func append(_ event: AtlasEvent) { lock.withLock { items.append(event) } }
    var values: [AtlasEvent] { lock.withLock { items } }
}
