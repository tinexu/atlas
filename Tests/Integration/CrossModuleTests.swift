import XCTest
@testable import AtlasCompanion
@testable import AtlasCore
@testable import AtlasOrbit
@testable import AtlasSpaces

/// Stage 08: flows that cross modules, end to end, with mock adapters.
final class CrossModuleTests: XCTestCase {
    let terminal = "com.apple.Terminal"
    let notes = "com.apple.Notes"

    /// Spaces + triggers + Time Architect on one core and a mock clock.
    struct World {
        let spaces: SpacesHarness
        let environment: MockTriggerEnvironment
        let calendarStore = MockCalendarStore()
        let time: TimeServices
        var core: AtlasCore { spaces.core }
        var store: AtlasStore { spaces.store }

        init() throws {
            spaces = try SpacesHarness()
            environment = spaces.base.startTriggers()
            time = spaces.core.startScheduling(environment: environment, calendarStore: calendarStore, calendar: TimeHarness.utc)
        }

        func advance(minutes: Double) {
            environment.advance(by: minutes * 60)
            environment.fireDueSchedules()
        }
    }

    // Companion command → Space activation → window layout → focus block.
    func testCompanionCommandActivatesTheSpaceArrangesWindowsAndStartsAFocusBlock() async throws {
        let w = try World()
        w.spaces.windows.addWindow(terminal, app: "Terminal", untilLaunched: true)
        w.spaces.windows.addWindow(notes, app: "Notes", untilLaunched: true)
        let (space, profile, _) = try w.spaces.makeSpace("Coding Lab", steps: [.launch(terminal), .launch(notes)])
        let layout = WindowLayout(name: "Programming", rules: [
            WindowRule(bundleID: terminal, appName: "Terminal", preset: .leftHalf),
            WindowRule(bundleID: notes, appName: "Notes", preset: .rightHalf),
        ])
        try w.store.saveWindowLayout(layout)
        var withLayout = profile
        withLayout.windowLayoutID = layout.id
        try w.store.saveProfile(withLayout)

        let vocabulary = CommandVocabularyBuilder.build(store: w.store, apps: [])
        let text = "I'm going to work on my app for the next two hours"
        let plan = try XCTUnwrap(DeterministicParser(vocabulary: vocabulary).parse(text).plan)
        XCTAssertTrue(plan.needsConfirmation, "Shown before it runs")
        guard case .run(let run) = await CommandRunner(core: w.core).run(plan, text: text, source: .palette) else { return XCTFail() }

        XCTAssertEqual(run.state, .succeeded, run.error ?? "")
        XCTAssertEqual(run.trigger, RunTrigger.companion)
        XCTAssertTrue(w.spaces.system.calls.contains { $0.contains(terminal) })
        XCTAssertTrue(w.spaces.windows.calls.contains("frame:Terminal:0,25,720,875"), "The layout was applied")
        XCTAssertEqual(try w.store.activeSpaceID(), space.id)
        let session = try XCTUnwrap(w.time.focus.session)
        XCTAssertEqual(session.plannedSeconds, 7_200)
        XCTAssertEqual(session.spaceID, space.id)
        let block = try XCTUnwrap(w.store.block(id: XCTUnwrap(session.blockID)))
        XCTAssertEqual(block.spaceID, space.id)
        XCTAssertTrue(w.time.schedule.occurrences(in: DateInterval(start: block.start, end: block.end)).contains { $0.block.id == block.id },
                      "On the timeline")
    }

    // File created → rule → move → Orbit updates → notification (the Companion's bubble text).
    func testNewFileIsMovedByARuleAndTheIndexFollows() async throws {
        let folder = try TempFolder()
        let core = AtlasCore(store: try AtlasStore.inMemory(), system: MacSystemAdapter(), permissionProvider: MockPermissionProvider(),
                             windowAdapter: MockWindowAdapter())
        let watcher = MockTreeWatcher()
        let indexer = FileIndexer(store: core.store, events: core.events, watcher: watcher)
        indexer.throttle = 0
        let location = FileLocation(path: folder.path)
        try core.store.saveLocation(location)
        core.refreshFileAccess()
        indexer.watch(location)
        indexer.index(locationID: location.id)
        await indexer.waitUntilIdle()

        let environment = MockTriggerEnvironment()
        core.startTriggers(environment: environment)
        core.triggers?.fileSettleInterval = 0.01
        try core.registry.register(OrganizeFileAction(store: core.store, registry: core.registry))
        var rule = FileOrganizer.starterRules()[0]
        rule.folders = [folder.path]
        rule.isEnabled = true
        let saved = try FileOrganizer(core: core).save(rule)
        let workflow = try XCTUnwrap(core.store.workflow(id: XCTUnwrap(saved.workflowID)))
        let deadline = Date().addingTimeInterval(3)
        while environment.listenerCount == 0, Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }

        let shot = try folder.file("Screenshot 2026-10-25 at 10.00.00.png", bytes: 64)
        environment.fileCreated(shot)
        let target = folder.path + "/Screenshots/Screenshot 2026-10-25 at 10.00.00.png"
        var finished: WorkflowRun?
        for _ in 0..<150 {
            if let run = try core.store.runs(workflowID: workflow.id).first, run.state.isTerminal { finished = run; break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let run = try XCTUnwrap(finished)
        XCTAssertEqual(run.state, .succeeded, run.error ?? "")
        XCTAssertTrue(FileManager.default.fileExists(atPath: target))
        XCTAssertFalse(try core.store.operations(runID: run.id).isEmpty, "Logged for undo")
        XCTAssertTrue(try core.store.pendingOperations().isEmpty, "Nothing left half-done")

        // FSEvents would report both paths; the index follows.
        watcher.send([FileChange(path: shot, kind: .renamed), FileChange(path: target, kind: .renamed)], under: folder.path)
        await indexer.waitUntilIdle()
        XCTAssertNil(try core.store.entry(at: shot))
        XCTAssertNotNil(try core.store.entry(at: target))
        XCTAssertTrue(StatusMessages.message(for: run, store: core.store).contains("Screenshots"), StatusMessages.message(for: run, store: core.store))
    }

    // Calendar event → recommendation → Space switch, keeping the previous layout.
    func testCalendarEventLeadsToARecommendationThatSwitchesSpaces() async throws {
        let w = try World()
        let (coding, _, _) = try w.spaces.makeSpace("Coding Lab", steps: [.launch(terminal)])
        let (meeting, _, _) = try w.spaces.makeSpace("Meeting Room", steps: [.launch(notes)])
        try w.store.setActiveSpace(coding.id, profileID: nil)
        w.calendarStore.add(CalendarEvent(id: "sync", calendarID: "work", title: "Team Sync",
                                          start: w.environment.now() + 30 * 60, end: w.environment.now() + 60 * 60))
        await w.time.calendar.enable()
        let shown = RecommendationBox()
        w.time.recommendations.onRecommendation = { shown.add($0) }

        w.advance(minutes: 20)
        let recommendation = try XCTUnwrap(shown.items.first { $0.kind == .meetingSoon })
        XCTAssertEqual(recommendation.title, "Save your Coding Lab layout and switch to Meeting Room?")
        XCTAssertEqual(try w.store.activeSpaceID(), coding.id, "Nothing happens until it's accepted")

        guard case .ran(let run) = await w.time.recommendations.accept(recommendation) else { return XCTFail() }
        XCTAssertEqual(run.state, .succeeded, run.error ?? "")
        XCTAssertEqual(try w.store.activeSpaceID(), meeting.id)
        XCTAssertNotNil(try w.store.snapshot(reference: "Coding Lab before Team Sync"), "The coding layout was saved first")
        XCTAssertEqual(try w.store.recommendationLog().first?.state, .accepted)
    }

    // Modules at the same time: a Space switch while a file rule's run is still going.
    func testSpaceSwitchWhileAnotherRunIsInProgress() async throws {
        let w = try World()
        let (space, _, _) = try w.spaces.makeSpace("Coding Lab", steps: [.launch(terminal)])
        let slow = try w.core.save(Workflow(name: "Slow rule", steps: [
            WorkflowStep(actionID: DelayAction.id, parameters: ["seconds": 0.3]), .log("done"),
        ]))
        async let rule = w.core.engine.run(slow, trigger: "trigger.file.created")
        async let activation = w.core.engine.invoke(SpaceActivateAction.id, parameters: ["space": "Coding Lab"], source: RunTrigger.companion)
        let (ruleRun, activationRun) = await (rule, activation)
        XCTAssertEqual(ruleRun.state, .succeeded)
        XCTAssertEqual(activationRun.state, .succeeded, activationRun.error ?? "")
        XCTAssertEqual(try w.store.activeSpaceID(), space.id)
        let running = try w.store.runs(matching: RunQuery(states: [.running]))
        XCTAssertTrue(running.isEmpty, "Nothing left marked as running")
    }

    // A scheduled block that activates its Space at the start, while a focus session runs.
    func testScheduledBlockActivatesItsSpaceAndRecordsTheRun() async throws {
        let w = try World()
        let (space, _, _) = try w.spaces.makeSpace("Study Library", steps: [.launch(notes)])
        let now = w.environment.now()
        let block = try w.time.schedule.save(ScheduleBlock(title: "Exam prep", start: now + 600, end: now + 4_200, spaceID: space.id,
                                                           startBehavior: .activate))
        w.core.triggers?.sync()
        w.time.focus.start(minutes: 60, title: "Something else")
        w.advance(minutes: 10)
        let occurrence = Occurrence(block: block, start: block.start, end: block.end)
        var linked = false
        for _ in 0..<150 where !linked {
            linked = w.time.schedule.runs(for: occurrence).contains { $0.state == .succeeded }
            if !linked { try await Task.sleep(nanoseconds: 20_000_000) }
        }
        XCTAssertTrue(linked, "Scheduled 0:10 · Activated Study Library")
        XCTAssertEqual(try w.store.activeSpaceID(), space.id)
        XCTAssertNotNil(w.time.focus.session, "The focus session carries on")
    }
}

final class RecommendationBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _items: [Recommendation] = []
    var items: [Recommendation] { lock.withLock { _items } }
    func add(_ item: Recommendation) { lock.withLock { _items.append(item) } }
}
