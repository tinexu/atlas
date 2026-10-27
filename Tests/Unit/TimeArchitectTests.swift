import XCTest
@testable import AtlasCompanion
@testable import AtlasCore
@testable import AtlasSpaces

// MARK: - Fixtures

/// An in-memory calendar.
final class MockCalendarStore: CalendarStore, @unchecked Sendable {
    private let lock = NSLock()
    var accessState: CalendarAccess = .granted
    var calendarList = [CalendarInfo(id: "work", title: "Work", source: "iCloud"), CalendarInfo(id: "home", title: "Home", source: "iCloud")]
    private(set) var stored: [String: CalendarEvent] = [:]
    private var handlers: [@Sendable () -> Void] = []
    private(set) var writes = 0

    func add(_ event: CalendarEvent) { lock.withLock { stored[event.id] = event } }
    func remove(_ id: String) { lock.withLock { _ = stored.removeValue(forKey: id) } }
    func moveOutside(_ id: String, by seconds: TimeInterval) {
        lock.withLock {
            stored[id]?.start += seconds
            stored[id]?.end += seconds
        }
    }
    func changed() { lock.withLock { handlers }.forEach { $0() } }

    func access() -> CalendarAccess { accessState }
    func requestAccess() async -> CalendarAccess { accessState }
    func calendars() -> [CalendarInfo] { calendarList }
    func events(from: Date, to: Date, calendarIDs: [String]) -> [CalendarEvent] {
        lock.withLock { stored.values.filter { calendarIDs.contains($0.calendarID) && $0.end > from && $0.start < to } }.sorted { $0.start < $1.start }
    }
    func event(id: String) -> CalendarEvent? { lock.withLock { stored[id] } }
    func createEvent(title: String, start: Date, end: Date, calendarID: String, notes: String) throws -> String {
        let id = "atlas-\(UUID().uuidString.prefix(6))"
        lock.withLock {
            stored[id] = CalendarEvent(id: id, calendarID: calendarID, title: title, start: start, end: end, notes: notes)
            writes += 1
        }
        return id
    }
    func updateEvent(id: String, start: Date, end: Date) throws {
        lock.withLock {
            stored[id]?.start = start
            stored[id]?.end = end
            writes += 1
        }
    }
    func deleteEvent(id: String) throws { lock.withLock { _ = stored.removeValue(forKey: id); writes += 1 } }
    func observeChanges(_ handler: @escaping @Sendable () -> Void) -> TriggerToken {
        lock.withLock { handlers.append(handler) }
        return TriggerToken {}
    }
}

/// A harness with triggers and Time Architect on a mock clock.
struct TimeHarness {
    let base: TestHarness
    let environment: MockTriggerEnvironment
    let calendarStore: MockCalendarStore
    let time: TimeServices
    var core: AtlasCore { base.core }
    var store: AtlasStore { base.store }
    var schedule: ScheduleService { time.schedule }
    var now: Date { environment.now() }

    init(calendar: Calendar = TimeHarness.utc) throws {
        base = try TestHarness()
        environment = base.startTriggers()
        calendarStore = MockCalendarStore()
        time = base.core.startScheduling(environment: environment, calendarStore: calendarStore, calendar: calendar)
    }

    static var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    /// Moves the clock and fires whatever came due.
    func advance(minutes: Double) {
        environment.advance(by: minutes * 60)
        environment.fireDueSchedules()
    }

    func addSpace(_ name: String, template: String = "coding-lab") throws -> UUID {
        let id = UUID()
        try store.database.run("INSERT INTO space (id, name, group_name, template_id, accent_color, created_at, updated_at) VALUES (?, ?, 'Work', ?, '#000000', 0, 0);",
                               [.from(id), .text(name), .text(template)])
        return id
    }

    func setActiveSpace(_ id: UUID?) throws { try store.setPreference(id, for: "spaces.activeSpaceID") }
}

private func date(_ text: String, _ zone: String = "UTC") -> Date {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(identifier: zone)
    formatter.dateFormat = "yyyy-MM-dd HH:mm"
    return formatter.date(from: text)!
}

private func calendar(_ zone: String) -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: zone)!
    return calendar
}

// MARK: - Recurrence and conflicts

final class RecurrenceTests: XCTestCase {
    func testDailyWeekdaysAndWeekly() {
        // Wednesday 2026-03-04 09:00 UTC.
        let start = date("2026-03-04 09:00")
        let range = DateInterval(start: date("2026-03-04 00:00"), end: date("2026-03-11 00:00"))
        func count(_ recurrence: Recurrence) -> Int {
            RecurrenceExpander.occurrences(of: ScheduleBlock(title: "B", start: start, end: start + 3_600, recurrence: recurrence),
                                           in: range, calendar: calendar("UTC")).count
        }
        XCTAssertEqual(count(.none), 1)
        XCTAssertEqual(count(.daily), 7)
        XCTAssertEqual(count(.weekdays), 5, "Wed, Thu, Fri, Mon, Tue")
        XCTAssertEqual(count(.weekly), 1)
    }

    func testRRules() {
        let start = date("2026-03-02 10:00") // a Monday
        let range = DateInterval(start: start, end: date("2026-04-01 00:00"))
        func starts(_ rule: String) -> [Date] {
            RecurrenceExpander.occurrences(of: ScheduleBlock(title: "B", start: start, end: start + 1_800, recurrence: .custom(rule)),
                                           in: range, calendar: calendar("UTC")).map(\.start)
        }
        let biweekly = starts("FREQ=WEEKLY;INTERVAL=2;BYDAY=MO,WE")
        XCTAssertEqual(biweekly, [date("2026-03-02 10:00"), date("2026-03-04 10:00"), date("2026-03-16 10:00"), date("2026-03-18 10:00"),
                                  date("2026-03-30 10:00")])
        XCTAssertEqual(starts("RRULE:FREQ=DAILY;COUNT=3").count, 3)
        XCTAssertEqual(starts("FREQ=DAILY;UNTIL=20260305").last, date("2026-03-05 10:00"))
        XCTAssertEqual(starts("FREQ=DAILY;INTERVAL=10"), [date("2026-03-02 10:00"), date("2026-03-12 10:00"), date("2026-03-22 10:00")])
        XCTAssertEqual(starts("FREQ=MONTHLY").count, 1)
        XCTAssertTrue(starts("FREQ=YEARLY").isEmpty, "Unsupported rules expand to nothing")
        XCTAssertThrowsError(try RecurrenceExpander.validate(.custom("FREQ=SOMETIMES")))
        XCTAssertNoThrow(try RecurrenceExpander.validate(.custom("FREQ=WEEKLY;BYDAY=TU,TH")))
        XCTAssertEqual(Recurrence.custom("FREQ=WEEKLY;BYDAY=MO,WE").title, "Every week on Mon, Wed")
    }

    func testDaylightSavingKeepsTheWallClockTime() {
        // US clocks go forward on 2026-03-08 and back on 2026-11-01.
        let newYork = calendar("America/New_York")
        for (first, last) in [("2026-03-06 09:00", "2026-03-11 00:00"), ("2026-10-30 09:00", "2026-11-04 00:00")] {
            let start = date(first, "America/New_York")
            let block = ScheduleBlock(title: "Standup", start: start, end: start + 900, recurrence: .daily)
            let occurrences = RecurrenceExpander.occurrences(of: block, in: DateInterval(start: start, end: date(last, "America/New_York")), calendar: newYork)
            XCTAssertGreaterThanOrEqual(occurrences.count, 4)
            for occurrence in occurrences {
                XCTAssertEqual(newYork.component(.hour, from: occurrence.start), 9, "Still 9:00 local after the change")
                XCTAssertEqual(occurrence.end.timeIntervalSince(occurrence.start), 900)
            }
        }
    }

    func testTimeZonesUseTheirOwnWallClock() {
        let start = date("2026-05-01 09:00", "Asia/Tokyo")
        let block = ScheduleBlock(title: "B", start: start, end: start + 3_600, recurrence: .daily)
        let range = DateInterval(start: start, end: start + 3 * 86_400)
        let tokyo = RecurrenceExpander.occurrences(of: block, in: range, calendar: calendar("Asia/Tokyo"))
        XCTAssertTrue(tokyo.allSatisfy { calendar("Asia/Tokyo").component(.hour, from: $0.start) == 9 })
    }

    func testOverlapsAreFoundWithAFix() {
        let t = date("2026-03-04 09:00")
        let a = ScheduleBlock(title: "Deep Work", start: t, end: t + 7_200)
        let b = ScheduleBlock(title: "Team Sync", start: t + 3_600, end: t + 5_400)
        let c = ScheduleBlock(title: "Lunch", start: t + 7_200, end: t + 9_000)
        let occurrences = RecurrenceExpander.occurrences(of: [a, b, c], in: DateInterval(start: t, end: t + 86_400), calendar: calendar("UTC"))
        let conflicts = ScheduleConflict.find(in: occurrences)
        XCTAssertEqual(conflicts.count, 1, "Back-to-back blocks don't conflict")
        XCTAssertEqual(conflicts.first?.movable.occurrence.block.title, "Team Sync")
        XCTAssertEqual(conflicts.first?.movable.newStart, t + 7_200)
        XCTAssertTrue(conflicts.first?.suggestion.hasPrefix("Move “Team Sync” to") == true)
    }
}

// MARK: - Schedule clock

final class ScheduleServiceTests: XCTestCase {
    func testStartingStartedAndEndedEventsOnTime() throws {
        let h = try TimeHarness()
        let recorder = EventRecorder(h.core.events, "schedule.block.*")
        let block = try h.schedule.save(ScheduleBlock(title: "Deep Work", start: h.now + 20 * 60, end: h.now + 80 * 60))
        h.advance(minutes: 15)   // 5 minutes before
        XCTAssertEqual(recorder.named(AtlasEvent.Name.blockStarting).map { Int($0.payload["minutesBefore"]?.numberValue ?? -1) }, [5])
        h.advance(minutes: 5)
        XCTAssertEqual(recorder.named(AtlasEvent.Name.blockStarted).count, 1)
        let occurrence = try XCTUnwrap(h.schedule.occurrences(in: DateInterval(start: h.now - 3_600, end: h.now + 3_600)).first)
        XCTAssertEqual(h.schedule.state(of: occurrence).state, .active)
        h.advance(minutes: 60)
        XCTAssertEqual(recorder.named(AtlasEvent.Name.blockEnded).count, 1)
        XCTAssertEqual(try h.store.occurrence(blockID: block.id, start: block.start)?.state, .completed)
        h.schedule.process()
        XCTAssertEqual(recorder.named(AtlasEvent.Name.blockStarted).count, 1, "Nothing repeats")
    }

    func testNeverStartsAfterTheBlockHasEnded() throws {
        let h = try TimeHarness()
        let recorder = EventRecorder(h.core.events, "schedule.block.*")
        let block = try h.schedule.save(ScheduleBlock(title: "Gym", start: h.now + 12 * 60, end: h.now + 40 * 60))
        // The Mac sleeps right through it.
        h.environment.advance(by: 3 * 3_600)
        h.environment.wake()
        XCTAssertTrue(recorder.named(AtlasEvent.Name.blockStarted).isEmpty)
        XCTAssertTrue(recorder.named(AtlasEvent.Name.blockStarting).isEmpty, "No stale reminders either")
        XCTAssertEqual(recorder.named(AtlasEvent.Name.blockMissed).first?.payload["reason"], "ended")
        XCTAssertEqual(try h.store.occurrence(blockID: block.id, start: block.start)?.state, .missed)
    }

    func testMissedWhileAsleepFollowsTheBlocksChoice() throws {
        let h = try TimeHarness()
        let recorder = EventRecorder(h.core.events, "schedule.block.*")
        let late = try h.schedule.save(ScheduleBlock(title: "Run on wake", start: h.now + 10 * 60, end: h.now + 120 * 60, missedPolicy: .runIfStillInBlock))
        let strict = try h.schedule.save(ScheduleBlock(title: "Mark missed", start: h.now + 10 * 60, end: h.now + 120 * 60, missedPolicy: .markMissed))
        h.environment.advance(by: 40 * 60)   // woke 30 minutes into both
        h.environment.wake()
        let started = recorder.named(AtlasEvent.Name.blockStarted)
        XCTAssertEqual(started.map { $0.payload["title"]?.stringValue }, ["Run on wake"])
        XCTAssertEqual(started.first?.payload["late"], true)
        XCTAssertEqual(try h.store.occurrence(blockID: late.id, start: late.start)?.state, .active)
        XCTAssertEqual(try h.store.occurrence(blockID: strict.id, start: strict.start)?.state, .missed)
        XCTAssertEqual(recorder.named(AtlasEvent.Name.blockMissed).first?.payload["reason"], "asleep")
    }

    func testABlockThatDoesSomethingIsAFlowWorkflowAndRecordsItsRuns() async throws {
        let h = try TimeHarness()
        let block = try h.schedule.save(ScheduleBlock(title: "Study", start: h.now + 10 * 60, end: h.now + 70 * 60, reminderMinutes: 5,
                                                       startBehavior: .notify, endBehavior: .notify))
        let workflow = try XCTUnwrap(h.store.workflow(id: XCTUnwrap(block.automationWorkflowID)))
        h.core.triggers?.sync()
        XCTAssertEqual(workflow.name, "Schedule: Study")
        XCTAssertTrue(workflow.isEnabled)
        let triggers = workflow.steps.filter { $0.kind == .trigger }
        XCTAssertEqual(Set(triggers.compactMap(\.config.triggerType)), [TriggerCatalog.blockStarting, TriggerCatalog.blockEnded])
        XCTAssertEqual(triggers.compactMap { $0.parameters["minutesBefore"]?.numberValue }.sorted(), [0, 5])
        XCTAssertFalse(WorkflowValidator.hasErrors(h.core.validate(workflow)))

        h.advance(minutes: 5)   // reminder
        h.advance(minutes: 5)   // start
        let linked = await h.base.waitUntil {
            let occurrence = Occurrence(block: block, start: block.start, end: block.end)
            return h.schedule.runs(for: occurrence).count == 2
        }
        XCTAssertTrue(linked, "The reminder and start runs are linked to the occurrence")
        let runs = h.schedule.runs(for: Occurrence(block: block, start: block.start, end: block.end))
        XCTAssertTrue(runs.allSatisfy { $0.trigger == RunTrigger.automatic(TriggerCatalog.blockStarting) })
        XCTAssertTrue(h.base.system.calls.contains { $0.contains("Study is starting") })

        // Nothing to do any more: the generated workflow goes away.
        var quiet = block
        quiet.reminderMinutes = nil
        quiet.startBehavior = .nothing
        quiet.endBehavior = .nothing
        let saved = try h.schedule.save(quiet)
        XCTAssertNil(saved.automationWorkflowID)
        XCTAssertNil(try h.store.workflow(id: XCTUnwrap(block.automationWorkflowID)))
    }

    func testActivateAndRestoreCompile() {
        let space = UUID()
        let block = ScheduleBlock(title: "Coding", start: Date(), end: Date() + 3_600, spaceID: space, startBehavior: .activate, endBehavior: .restoreSnapshot)
        let workflow = ScheduleAutomation.compile(block, names: .init(space: "Coding Lab", profile: "Deep Work"))
        let actions = workflow.steps.filter { $0.kind == .action }.map(\.actionID.rawValue)
        XCTAssertEqual(actions, ["window.snapshot.save", "space.activate", "window.snapshot.restore"])
        XCTAssertEqual(workflow.steps.first { $0.actionID == "space.activate" }?.parameters["profile"], "Deep Work")
    }

    func testRepeatingBlocksAndSkipping() throws {
        let h = try TimeHarness()
        let block = try h.schedule.save(ScheduleBlock(title: "Standup", start: h.now + 3_600, end: h.now + 4_500, recurrence: .daily))
        let week = h.schedule.occurrences(in: DateInterval(start: h.now, end: h.now + 7 * 86_400))
        XCTAssertEqual(week.count, 7)
        try h.schedule.skip(week[1])
        XCTAssertEqual(h.schedule.state(of: week[1]).state, .skipped)
        XCTAssertThrowsError(try h.schedule.save(ScheduleBlock(title: "Bad", start: h.now, end: h.now + 60, recurrence: .custom("FREQ=NEVER"))))
        let moved = try h.schedule.move(block.id, by: 15 * 60)
        XCTAssertEqual(moved.start, block.start + 900)
        let resized = try h.schedule.move(block.id, by: 30 * 60, resizeOnly: true)
        XCTAssertEqual(resized.duration, block.duration + 1_800)
    }
}

// MARK: - Focus sessions

final class FocusServiceTests: XCTestCase {
    func testSessionLifecycleAppearsOnTheTimeline() throws {
        let h = try TimeHarness()
        let recorder = EventRecorder(h.core.events, "focus.*")
        let focus = h.time.focus
        var settings = focus.settings
        settings.notifyAtEnd = false
        settings.breakMinutes = 5
        focus.settings = settings
        let session = focus.start(minutes: 30, title: "Deep Work")
        let block = try XCTUnwrap(h.store.block(id: XCTUnwrap(session.blockID)))
        XCTAssertEqual(block.kind, .focus)
        XCTAssertEqual(block.duration, 1_800)

        h.advance(minutes: 10)
        focus.pause()
        h.advance(minutes: 5)
        XCTAssertEqual(focus.session?.remaining(at: h.now) ?? 0, 20 * 60, accuracy: 1, "Paused time doesn't count")
        focus.resume()
        focus.extend(minutes: 10)
        XCTAssertEqual(focus.session?.remaining(at: h.now) ?? 0, 30 * 60, accuracy: 1)
        XCTAssertEqual(try h.store.block(id: block.id)?.end.timeIntervalSince(h.now) ?? 0, 30 * 60, accuracy: 31, "The block follows")

        h.advance(minutes: 31)
        XCTAssertNil(focus.session)
        let ended = try XCTUnwrap(recorder.named(AtlasEvent.Name.focusEnded).first)
        XCTAssertEqual(ended.payload["completed"], true)
        XCTAssertEqual(ended.payload["extendedMinutes"], .number(10))
        XCTAssertEqual(recorder.all.map(\.name), [AtlasEvent.Name.focusStarted, AtlasEvent.Name.focusPaused, AtlasEvent.Name.focusResumed,
                                                  AtlasEvent.Name.focusExtended, AtlasEvent.Name.focusEnded])
        XCTAssertTrue(h.schedule.blocks().contains { $0.kind == .breakTime }, "A break block follows")
    }

    func testFocusStartActionAndEndedTrigger() async throws {
        let h = try TimeHarness()
        let spaceID = try h.addSpace("Coding Lab")
        let trigger = WorkflowStep.trigger(TriggerCatalog.focusEnded, parameters: ["completedOnly": true], at: NodePosition())
        let log = WorkflowStep(actionID: LogMessageAction.id, parameters: ["message": "done {{trigger.elapsedMinutes}}"])
        let after = try h.core.save(Workflow(name: "After focus", steps: [trigger, log],
                                             connections: [WorkflowConnection(fromNode: trigger.id, fromPort: NodePort.controlOut, toNode: log.id)]))
        h.core.triggers?.sync()
        let run = await h.core.engine.invoke(StartFocusAction.id, parameters: ["minutes": 25, "space": "coding lab"], source: "test")
        XCTAssertEqual(run.state, .succeeded)
        XCTAssertEqual(h.time.focus.session?.spaceID, spaceID)
        h.time.focus.stop()
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertTrue(try h.base.runs(of: after).isEmpty, "Stopped early: “only when it ran to the end” doesn't fire")
        h.time.focus.start(minutes: 1)
        h.advance(minutes: 1.1)
        let fired = await h.base.waitUntil { (try? h.base.runs(of: after).count) == 1 }
        XCTAssertTrue(fired)
    }
}

// MARK: - Calendar

final class CalendarServiceTests: XCTestCase {
    func testReadOnlyByDefaultAndOnlyChosenCalendars() async throws {
        let h = try TimeHarness()
        h.calendarStore.add(CalendarEvent(id: "e1", calendarID: "work", title: "Team Sync", start: h.now + 3_600, end: h.now + 5_400))
        h.calendarStore.add(CalendarEvent(id: "e2", calendarID: "home", title: "Dentist", start: h.now + 7_200, end: h.now + 9_000))
        let range = DateInterval(start: h.now, end: h.now + 86_400)
        XCTAssertTrue(h.schedule.occurrences(in: range).isEmpty, "Off until turned on")

        await h.time.calendar.enable()
        var settings = h.time.calendar.settings
        settings.visibleCalendarIDs = ["work"]
        h.time.calendar.settings = settings
        let shown = h.schedule.occurrences(in: range)
        XCTAssertEqual(shown.map(\.block.title), ["Team Sync"])
        XCTAssertTrue(shown[0].block.isExternal)
        XCTAssertThrowsError(try h.schedule.move(shown[0].block.id, by: 900)) { XCTAssertEqual($0 as? ScheduleError, .notFound) }
        XCTAssertThrowsError(try h.time.calendar.move(eventID: "e1", start: h.now, end: h.now + 600, confirmed: true)) {
            XCTAssertEqual($0 as? CalendarError, .readOnly("Work"))
        }
        XCTAssertEqual(h.calendarStore.writes, 0, "Nothing was written")
    }

    func testWritingNeedsPermissionPerCalendarConfirmationAndCanBeUndone() async throws {
        let h = try TimeHarness()
        await h.time.calendar.enable()
        let block = try h.schedule.save(ScheduleBlock(title: "Deep Work", start: h.now + 3_600, end: h.now + 7_200))
        XCTAssertThrowsError(try h.time.calendar.write(block, to: "work", confirmed: true)) { XCTAssertEqual($0 as? CalendarError, .readOnly("Work")) }

        var settings = h.time.calendar.settings
        settings.writableCalendarIDs = ["work"]
        h.time.calendar.settings = settings
        XCTAssertThrowsError(try h.time.calendar.write(block, to: "work", confirmed: false)) {
            XCTAssertEqual($0 as? CalendarError, .needsConfirmation("Work"))
        }
        XCTAssertEqual(h.calendarStore.writes, 0)
        let link = try h.time.calendar.write(block, to: "work", confirmed: true)
        XCTAssertEqual(h.calendarStore.writes, 1)
        XCTAssertEqual(try h.store.block(id: block.id)?.externalEventID, link.eventID)
        // Confirmed once per calendar.
        let second = try h.schedule.save(ScheduleBlock(title: "Review", start: h.now + 9_000, end: h.now + 9_900))
        XCTAssertNoThrow(try h.time.calendar.write(second, to: "work", confirmed: false))
        XCTAssertEqual(h.time.calendar.writeLog().count, 2, "Every write is logged")
        XCTAssertFalse(h.schedule.occurrences(in: DateInterval(start: h.now, end: h.now + 86_400)).contains { $0.block.isExternal },
                       "ATLAS's own events aren't shown twice")

        try h.time.calendar.undo(link)
        XCTAssertNil(h.calendarStore.event(id: try XCTUnwrap(link.eventID)))
        XCTAssertNil(try h.store.block(id: block.id)?.externalEventID)
        XCTAssertNotNil(h.time.calendar.writeLog().first { $0.id == link.id }?.undoneAt)
    }

    func testChangesOutsideATLASFollowLinkedBlocks() async throws {
        let h = try TimeHarness()
        await h.time.calendar.enable()
        var settings = h.time.calendar.settings
        settings.writableCalendarIDs = ["work"]
        settings.confirmedCalendarIDs = ["work"]
        h.time.calendar.settings = settings
        let block = try h.schedule.save(ScheduleBlock(title: "Deep Work", start: h.now + 3_600, end: h.now + 7_200))
        let link = try h.time.calendar.write(block, to: "work", confirmed: false)
        let eventID = try XCTUnwrap(link.eventID)

        h.calendarStore.moveOutside(eventID, by: 1_800)
        h.calendarStore.changed()
        XCTAssertEqual(try h.store.block(id: block.id)?.start, block.start + 1_800, "Moved in Calendar: the block follows")

        h.calendarStore.remove(eventID)
        h.calendarStore.changed()
        let unlinked = try XCTUnwrap(h.store.block(id: block.id))
        XCTAssertNil(unlinked.externalEventID)
        XCTAssertTrue(unlinked.notes.contains("deleted outside ATLAS"))
    }

    func testApproachingEventsAndTheirTrigger() async throws {
        let h = try TimeHarness()
        h.calendarStore.add(CalendarEvent(id: "sync", calendarID: "work", title: "Team Sync", start: h.now + 30 * 60, end: h.now + 60 * 60))
        await h.time.calendar.enable()
        let trigger = WorkflowStep.trigger(TriggerCatalog.calendarEventApproaching, parameters: ["minutesBefore": 10, "titleContains": "sync"])
        let log = WorkflowStep(actionID: LogMessageAction.id, parameters: ["message": "{{trigger.title}}"])
        let workflow = try h.core.save(Workflow(name: "Before meetings", steps: [trigger, log],
                                                connections: [WorkflowConnection(fromNode: trigger.id, fromPort: NodePort.controlOut, toNode: log.id)]))
        h.core.triggers?.sync()
        h.time.calendar.process()
        let recorder = EventRecorder(h.core.events, AtlasEvent.Name.calendarEventApproaching)
        h.advance(minutes: 15)   // 15 before
        h.advance(minutes: 5)    // 10 before
        XCTAssertEqual(recorder.all.compactMap { $0.payload["minutesBefore"]?.numberValue }, [15, 10])
        let ran = await h.base.waitUntil { (try? h.base.runs(of: workflow).count) == 1 }
        XCTAssertTrue(ran)
    }
}

// MARK: - Recommendations

final class RecommendationTests: XCTestCase {
    func testBlockStartingSuggestsItsSpace() throws {
        let h = try TimeHarness()
        let study = try h.addSpace("Study Library", template: "study-library")
        let engine = h.time.recommendations
        var shown: [Recommendation] = []
        engine.onRecommendation = { shown.append($0) }
        _ = try h.schedule.save(ScheduleBlock(title: "Exam prep", start: h.now + 10 * 60, end: h.now + 70 * 60, spaceID: study, startBehavior: .ask))
        h.advance(minutes: 5)
        XCTAssertEqual(shown.first?.title, "Open Study Library?")
        XCTAssertEqual(shown.first?.kind, .blockStarting)
        XCTAssertTrue(shown.first?.reason.contains("Exam prep") == true, "Why am I seeing this?")
        if case .activateSpace(let name, _, let blockID, _) = shown.first?.action {
            XCTAssertEqual(name, "Study Library")
            XCTAssertNotNil(blockID)
        } else { XCTFail() }
        // Already there: nothing to suggest.
        try h.setActiveSpace(study)
        XCTAssertNil(engine.evaluate(AtlasEvent(AtlasEvent.Name.blockStarting, payload: [
            "minutesBefore": 5, "spaceName": "Study Library", "blockId": .string(UUID().uuidString), "startBehavior": "ask",
        ])))
    }

    func testMeetingSoonOffersToSaveAndSwitch() throws {
        let h = try TimeHarness()
        let coding = try h.addSpace("Coding Lab")
        _ = try h.addSpace("Meeting Room", template: "meeting-room")
        try h.setActiveSpace(coding)
        let event = AtlasEvent(AtlasEvent.Name.calendarEventApproaching, payload: ["title": "Team Sync", "minutesBefore": 10, "eventId": "sync"])
        let recommendation = try XCTUnwrap(h.time.recommendations.evaluate(event))
        XCTAssertEqual(recommendation.title, "Save your Coding Lab layout and switch to Meeting Room?")
        XCTAssertEqual(recommendation.action, .saveLayoutAndSwitch(snapshotName: "Coding Lab before Team Sync", spaceName: "Meeting Room"))
        // Five minutes out, or in the meeting room already: no.
        XCTAssertNil(h.time.recommendations.evaluate(AtlasEvent(AtlasEvent.Name.calendarEventApproaching, payload: ["title": "Team Sync", "minutesBefore": 5])))
    }

    func testRepeatedFailuresAndRepeatedManualRuns() throws {
        let h = try TimeHarness()
        let workflow = try h.core.save(Workflow(name: "Morning Setup", steps: [WorkflowStep(actionID: LogMessageAction.id, parameters: ["message": "x"])]))
        for i in 0..<3 {
            var run = WorkflowRun(workflowID: workflow.id, workflowName: workflow.name, trigger: "trigger.time.reached", state: .failed,
                                  startedAt: h.now - Double(3 - i) * 60)
            run.steps = [StepRecord(position: 0, nodeID: UUID(), actionID: "application.launch", label: "Launch Notz", state: .failed, error: "No installed app")]
            try h.store.saveRun(run)
        }
        let failure = try XCTUnwrap(h.time.recommendations.repeatedFailure(workflow.id))
        XCTAssertEqual(failure.kind, .repeatedFailure)
        XCTAssertTrue(failure.detail.contains("Launch Notz"))

        let calendar = Calendar.current
        let other = try h.core.save(Workflow(name: "Inbox Zero", steps: [WorkflowStep(actionID: LogMessageAction.id, parameters: ["message": "x"])]))
        for day in 0..<3 {
            let start = calendar.date(bySettingHour: 9, minute: 5 + day * 5, second: 0, of: h.now - Double(day) * 86_400)!
            try h.store.saveRun(WorkflowRun(workflowID: other.id, workflowName: other.name, trigger: RunTrigger.manual, state: .succeeded, startedAt: start))
        }
        let schedule = try XCTUnwrap(h.time.recommendations.repeatedByHand(other.id))
        XCTAssertEqual(schedule.action, .scheduleWorkflow(workflowID: other.id, name: "Inbox Zero", hour: 9, minute: 15))
    }

    func testAlwaysExtendingFocusSuggestsALongerDefault() throws {
        let h = try TimeHarness()
        let deep = try h.addSpace("Deep Work Lab")
        for i in 0..<4 {
            try h.store.saveFocusSession(FocusSession(plannedSeconds: 3_600, extendedSeconds: i == 3 ? 0 : 1_800, startedAt: h.now - Double(i + 1) * 86_400,
                                                      endedAt: h.now - Double(i + 1) * 86_400 + 5_400, spaceID: deep, state: .ended))
        }
        let recommendation = try XCTUnwrap(h.time.recommendations.extendedFocus(spaceID: deep))
        XCTAssertEqual(recommendation.title, "Make Deep Work Lab 90 minutes by default?")
    }

    func testRateLimitsTuningAndSuppression() async throws {
        let h = try TimeHarness()
        let engine = h.time.recommendations
        func make(_ kind: Recommendation.Kind, _ subject: String, confidence: Double = 0.8) -> Recommendation {
            Recommendation(kind: kind, title: "\(kind)", reason: "test", confidence: confidence, action: .setFocusDefault(spaceID: nil, minutes: 30), subject: subject)
        }
        let first = make(.extendFocus, "a")
        XCTAssertTrue(engine.offer(first))
        XCTAssertFalse(engine.offer(make(.scheduleRepeated, "b")), "One at a time")
        engine.dismiss(first, forever: false)
        XCTAssertFalse(engine.offer(make(.scheduleRepeated, "b")), "And not too often")
        XCTAssertTrue(engine.offer(make(.blockStarting, "c")), "Time-critical ones still get through")
        engine.dismiss(make(.blockStarting, "c"), forever: false)
        h.environment.advance(by: 11 * 60)
        XCTAssertFalse(engine.offer(make(.extendFocus, "a")), "The same thing isn't suggested again the same day")
        XCTAssertTrue(engine.offer(make(.scheduleRepeated, "b")))

        // Dismissals lower a kind's score until weak suggestions stop.
        var tuning = engine.tuning
        tuning.dismissed(make(.scheduleRepeated, "x"), at: h.now)
        tuning.dismissed(make(.scheduleRepeated, "y"), at: h.now)
        XCTAssertFalse(tuning.allows(make(.scheduleRepeated, "z", confidence: 0.75), at: h.now))
        tuning.accepted(.scheduleRepeated)
        tuning.accepted(.scheduleRepeated)
        XCTAssertTrue(tuning.allows(make(.scheduleRepeated, "z", confidence: 0.75), at: h.now))
        tuning.muted.insert(Recommendation.Kind.scheduleRepeated.rawValue)
        XCTAssertFalse(tuning.allows(make(.scheduleRepeated, "z", confidence: 1), at: h.now), "Don't suggest this")

        let log = try h.store.recommendationLog()
        XCTAssertEqual(log.count, 3)
        XCTAssertTrue(log.contains { $0.state == .dismissed })
    }

    func testAcceptingRunsThroughTheEngine() async throws {
        let h = try TimeHarness()
        let outcome = await h.time.recommendations.accept(Recommendation(
            kind: .meetingSoon, title: "Save layout", reason: "test", confidence: 0.9,
            action: .saveLayoutAndSwitch(snapshotName: "Before sync", spaceName: nil), subject: "s"))
        guard case .ran(let run) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(run.trigger, "recommendation")
        XCTAssertEqual(run.steps.first?.actionID, "window.snapshot.save")
        let focus = await h.time.recommendations.accept(Recommendation(kind: .extendFocus, title: "", reason: "", confidence: 1,
                                                                       action: .setFocusDefault(spaceID: nil, minutes: 50), subject: "f"))
        XCTAssertEqual(h.time.focus.settings.defaultMinutes, 50)
        if case .done = focus {} else { XCTFail() }
        let fix = await h.time.recommendations.accept(Recommendation(kind: .repeatedFailure, title: "", reason: "", confidence: 1,
                                                                     action: .disableOrFix(workflowID: UUID(), nodeID: nil), subject: "w"))
        if case .needsUI = fix {} else { XCTFail("Fixing opens the editor") }
    }
}

// MARK: - Workflow generation

private final class MockGenerationProvider: IntentModelProvider, @unchecked Sendable {
    var answer: String
    init(_ answer: String) { self.answer = answer }
    var displayName: String { "Mock" }
    func unavailableReason() async -> String? { nil }
    func complete(_ request: ModelRequest) async throws -> String { answer }
}

final class WorkflowGenerationTests: XCTestCase {
    private func context(folders: [String] = ["/Users/test/Downloads"]) -> GenerationContext {
        GenerationContext(spaces: ["Coding Lab", "Creative Studio", "Study Library"],
                          workflows: [(UUID(), "Morning Setup")], layouts: ["Programming"], folders: folders,
                          apps: [("org.blenderfoundation.blender", "Blender"), ("com.apple.Music", "Music"), ("com.apple.MobileSMS", "Messages"),
                                 ("com.apple.Safari", "Safari")],
                          granted: [.notifications, .fileAccess])
    }

    private func generator(_ h: TestHarness) -> WorkflowGenerator { WorkflowGenerator(core: h.core) }

    func testTheDemoSentenceWithoutAI() async throws {
        let h = try TestHarness()
        _ = try SpacesModule(core: h.core)
        let proposal = try await generator(h).generate("When I open Blender, activate Creative Studio and hide distracting apps",
                                                       context: context(), provider: nil)
        XCTAssertEqual(proposal.source, .rules)
        XCTAssertFalse(proposal.workflow.isEnabled, "Drafts start off")
        let trigger = try XCTUnwrap(proposal.workflow.steps.first { $0.kind == .trigger })
        XCTAssertEqual(trigger.config.triggerType, TriggerCatalog.appLaunched)
        XCTAssertEqual(trigger.parameters["app"], "org.blenderfoundation.blender")
        let actions = proposal.workflow.steps.filter { $0.kind == .action }
        XCTAssertEqual(actions.map(\.actionID.rawValue), ["space.activate", "application.hide", "application.hide"])
        XCTAssertEqual(actions.first?.parameters["space"], "Creative Studio")
        XCTAssertTrue(proposal.assumptions.contains { $0.contains("distracting apps") && $0.contains("Music") })
        XCTAssertFalse(proposal.hasErrors, "\(proposal.issues.map(\.message))")
        XCTAssertEqual(proposal.workflow.connections.count, 3)
        XCTAssertTrue(proposal.summary.hasPrefix("When Blender opens"))
    }

    func testOtherPhrasings() async throws {
        let h = try TestHarness()
        _ = try SpacesModule(core: h.core)
        let morning = try await generator(h).generate("Every weekday at 9am open Safari and run Morning Setup", context: context(), provider: nil)
        let trigger = try XCTUnwrap(morning.workflow.steps.first { $0.kind == .trigger })
        XCTAssertEqual(trigger.parameters["days"], "mon, tue, wed, thu, fri")
        XCTAssertEqual(trigger.parameters["time"], "09:00")
        XCTAssertEqual(morning.workflow.steps.last?.config.control, .subworkflow)

        let files = try await generator(h).generate("When a PDF arrives in Downloads, move it to Papers", context: context(), provider: nil)
        XCTAssertEqual(files.workflow.steps.first?.parameters["extensions"], "pdf")
        XCTAssertEqual(files.workflow.steps.last?.parameters["destination"], "/Users/test/Downloads/Papers")

        do {
            _ = try await generator(h).generate("make me a sandwich", context: context(), provider: nil)
            XCTFail("Nothing understood")
        } catch let error as GenerationError {
            XCTAssertTrue(error.localizedDescription.contains("template"))
        }
    }

    func testAIGraphsAreCheckedBeforeTheyBecomeDrafts() async throws {
        let h = try TestHarness()
        h.core.fileAccess.setRoots(["/Users/test/Downloads"])
        _ = try SpacesModule(core: h.core)
        let valid = """
        {"name": "Blender studio", "summary": "When Blender opens, activate Creative Studio.", "assumptions": ["I assumed you meant Blender."],
         "trigger": {"type": "app.launched", "parameters": [{"key": "app", "value": "Blender"}]}, "conditions": [{"type": "dayOfWeek", "value": "weekdays"}],
         "steps": [{"action": "space.activate", "parameters": [{"key": "space", "value": "Creative Studio"}], "label": ""}]}
        """
        let proposal = try await generator(h).generate("blender", context: context(), provider: MockGenerationProvider(valid))
        XCTAssertEqual(proposal.source, .ai)
        XCTAssertFalse(proposal.workflow.isEnabled)
        XCTAssertEqual(proposal.workflow.steps.first?.parameters["app"], "org.blenderfoundation.blender", "App names become bundle IDs")
        XCTAssertEqual(proposal.workflow.steps.map(\.kind), [.trigger, .condition, .action])
        XCTAssertFalse(proposal.hasErrors)

        func rejected(_ json: String) -> GenerationError? {
            do { _ = try generator(h).proposal(from: JSONDecoder().decode(WorkflowBlueprint.self, from: Data(json.utf8)), prompt: "", source: .ai, context: context()); return nil }
            catch { return error as? GenerationError }
        }
        XCTAssertNotNil(rejected(#"{"steps": [{"action": "shell.run", "parameters": [], "label": ""}]}"#), "Unknown action")
        XCTAssertNotNil(rejected(#"{"trigger": {"type": "telepathy", "parameters": []}, "steps": [{"action": "atlas.log", "parameters": [{"key": "message", "value": "x"}], "label": ""}]}"#))
        XCTAssertNotNil(rejected(#"{"steps": [{"action": "application.launch", "parameters": [{"key": "sudo", "value": "1"}], "label": ""}]}"#), "Unknown parameter")
        XCTAssertNotNil(rejected(#"{"steps": [{"action": "file.move", "parameters": [{"key": "path", "value": "/x"}], "label": ""}]}"#), "Missing parameter")
        XCTAssertNotNil(rejected(#"{"steps": [{"action": "file.trash", "parameters": [{"key": "path", "value": "/etc/hosts"}], "label": ""}]}"#), "Outside Orbit")
        XCTAssertNotNil(rejected(#"{"steps": [{"action": "workflow.run", "parameters": [{"key": "workflow", "value": "Nope"}], "label": ""}]}"#))

        // Needs a permission ATLAS lacks: flagged, not hidden.
        let windows = try generator(h).proposal(from: WorkflowBlueprint(name: "W", summary: "", steps: [.init(action: "window.applyLayout", parameters: [.init("layout", "Programming")])]),
                                                prompt: "", source: .ai, context: context())
        XCTAssertTrue(windows.assumptions.contains { $0.contains("Accessibility") })

        // A broken answer falls back to the built-in parser, and says so.
        let fallback = try await generator(h).generate("When I open Blender, activate Creative Studio", context: context(),
                                                       provider: MockGenerationProvider("not json"))
        XCTAssertEqual(fallback.source, .rules)
        XCTAssertTrue(fallback.note?.contains("built-in") == true)
    }

    func testTemplatesAreValidDrafts() throws {
        let h = try TestHarness()
        h.core.fileAccess.setRoots(["/Users/test/Downloads"])
        _ = try SpacesModule(core: h.core)
        for template in WorkflowGenerator.templates(context: context()) {
            let proposal = try generator(h).proposal(from: template.blueprint, prompt: template.title, source: .template, context: context())
            XCTAssertFalse(proposal.workflow.isEnabled)
            XCTAssertFalse(proposal.hasErrors, "\(template.title): \(proposal.issues.map(\.message))")
        }
    }

    func testExplanations() throws {
        let h = try TestHarness()
        let trigger = WorkflowStep.trigger(TriggerCatalog.appLaunched, parameters: ["app": "org.blenderfoundation.blender"])
        let hide = WorkflowStep(actionID: HideApplicationAction.id, parameters: ["bundleId": "com.apple.Music"])
        let workflow = Workflow(name: "Studio", isEnabled: false, steps: [trigger, hide],
                                connections: [WorkflowConnection(fromNode: trigger.id, fromPort: NodePort.controlOut, toNode: hide.id)])
        let text = WorkflowExplainer.explain(workflow, registry: h.core.registry)
        XCTAssertTrue(text.contains("when an app opens"), text)
        XCTAssertTrue(text.contains("turned off"))
        XCTAssertTrue(text.contains("1. "))

        var run = WorkflowRun(workflowID: workflow.id, workflowName: "Studio", trigger: "trigger.app.launched", state: .failed)
        run.steps = [StepRecord(position: 0, nodeID: hide.id, actionID: hide.actionID, label: "Hide Music", state: .failed,
                                error: "No installed app has the bundle identifier “com.apple.Music”.")]
        let why = WorkflowExplainer.explainFailure(run, workflow: workflow)
        XCTAssertTrue(why.contains("Hide Music"))
        XCTAssertTrue(why.contains("install the app"))
    }
}

// MARK: - Companion and storage

final class TimeArchitectMiscTests: XCTestCase {
    func testCompanionPlansAWorkSession() {
        let vocab = CommandVocabulary(spaces: [
            .init(id: UUID(), name: "Coding Lab", profiles: [(UUID(), "Deep Work", true)], templateID: "coding-lab"),
            .init(id: UUID(), name: "Study Library", profiles: [], templateID: "study-library"),
        ])
        let parser = DeterministicParser(vocabulary: vocab)
        guard case .plan(let plan) = parser.parse("I'm going to work on my app for the next two hours"),
              case .actions(let steps) = plan.kind else { return XCTFail() }
        XCTAssertEqual(plan.summary, "Activate Coding Lab — Deep Work and start a 2 h focus block")
        XCTAssertEqual(steps.map(\.actionID), [SpaceActivateAction.id, StartFocusAction.id])
        XCTAssertEqual(steps[1].parameters["minutes"], .number(120))
        XCTAssertTrue(plan.needsConfirmation)
        guard case .plan(let study) = parser.parse("study for 45 minutes"), case .actions(let studySteps) = study.kind else { return XCTFail() }
        XCTAssertEqual(studySteps.first?.parameters["space"], "Study Library")
    }

    func testCompanionHandsAutomationIdeasToTheDrafter() {
        let parser = DeterministicParser(vocabulary: CommandVocabulary())
        let idea = parser.parse("When I open Blender, activate Creative Studio").plan
        XCTAssertEqual(idea?.kind, .open(.describeAutomation("When I open Blender, activate Creative Studio")))
        XCTAssertEqual(idea?.needsConfirmation, false, "Drafting changes nothing")
        guard case .actions(let steps) = parser.parse("stop my focus session").plan?.kind else { return XCTFail() }
        XCTAssertEqual(steps.first?.actionID, StopFocusAction.id)
        XCTAssertEqual(parser.parse("open today").plan?.kind, .open(.today))
    }

    func testDailyOverview() throws {
        let h = try TimeHarness()
        _ = try h.schedule.save(ScheduleBlock(title: "Deep Work", start: h.now + 3_600, end: h.now + 7_200, kind: .focus))
        try h.store.saveRun(WorkflowRun(workflowID: UUID(), workflowName: "Broken", trigger: "manual", state: .failed, startedAt: h.now))
        let overview = DailyOverview.make(store: h.store, schedule: h.schedule, events: h.core.events, now: h.now, calendar: TimeHarness.utc)
        XCTAssertEqual(overview.plannedFocus, 3_600)
        XCTAssertEqual(overview.failures.count, 1)
        XCTAssertTrue(overview.text.contains("Deep Work"))
        XCTAssertNotNil(try h.store.workflows().first { $0.name == "Morning Summary" && !$0.isEnabled }, "Built in, off by default")
    }

    func testV6DatabaseMigratesToV7() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("atlas-v6-\(UUID().uuidString).sqlite")
        defer { for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: url.path + suffix) } }
        let workflowID = UUID()
        do {
            let db = try SQLiteDatabase(path: url.path)
            for (index, sql) in Schema.migrations.prefix(6).enumerated() {
                try db.transaction {
                    try db.execute(sql)
                    try db.setUserVersion(index + 1)
                }
            }
            try db.run("INSERT INTO workflow (id, name, created_at, updated_at) VALUES (?, 'Old', 0, 0);", [.from(workflowID)])
            try db.run("INSERT INTO companion_command (id, text, source, created_at) VALUES (?, 'open my coding room', 'palette', 0);", [.from(UUID())])
        }
        let store = try AtlasStore(database: SQLiteDatabase(path: url.path))
        XCTAssertEqual(store.database.userVersion, Schema.currentVersion)
        XCTAssertEqual(try store.workflow(id: workflowID)?.name, "Old")
        XCTAssertEqual(try store.companionCommands().count, 1)
        let block = ScheduleBlock(title: "B", start: Date(timeIntervalSince1970: 1_000), end: Date(timeIntervalSince1970: 4_600),
                                  recurrence: .custom("FREQ=WEEKLY;BYDAY=MO"), reminderMinutes: 10, startBehavior: .ask,
                                  createdAt: Date(timeIntervalSince1970: 500), updatedAt: Date(timeIntervalSince1970: 600))
        try store.saveBlock(block)
        XCTAssertEqual(try store.block(id: block.id), block)
        try store.saveFocusSession(FocusSession(plannedSeconds: 60, startedAt: Date(timeIntervalSince1970: 1)))
        try store.saveCalendarLink(CalendarLink(kind: .rule, titleContains: "Interview"))
        try store.saveDraft(GeneratedDraft(workflowID: workflowID, prompt: "p", summary: "s", assumptions: ["a"], source: .ai))
        XCTAssertEqual(try store.draft(workflowID: workflowID)?.assumptions, ["a"])
        XCTAssertEqual(try store.calendarLinks(kind: .rule).count, 1)
    }
}
