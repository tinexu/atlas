import XCTest
@testable import AtlasCompanion
@testable import AtlasCore
@testable import AtlasSpaces

// MARK: - Fixtures

private func vocabulary(running: [CommandVocabulary.Named] = [], timers: [String] = []) -> CommandVocabulary {
    CommandVocabulary(
        spaces: [
            .init(id: UUID(), name: "Coding Lab", profiles: [(UUID(), "Deep Work", true), (UUID(), "Quick Review", false)]),
            .init(id: UUID(), name: "Study Library", profiles: [(UUID(), "Study Session", true)]),
            .init(id: UUID(), name: "Creative Studio", profiles: [(UUID(), "Create", true)]),
        ],
        workflows: [
            .init(id: UUID().uuidString, name: "Morning Setup"),
            .init(id: UUID().uuidString, name: "Coding Setup"),
            .init(id: UUID().uuidString, name: "Focus Reset"),
        ],
        apps: [
            .init(id: "com.apple.Safari", name: "Safari"),
            .init(id: "com.apple.Notes", name: "Notes"),
            .init(id: "com.apple.dt.Xcode", name: "Xcode"),
            .init(id: "com.microsoft.VSCode", name: "Visual Studio Code"),
        ],
        layouts: [.init(id: UUID().uuidString, name: "Interview"), .init(id: UUID().uuidString, name: "Programming")],
        snapshots: [.init(id: UUID().uuidString, name: "Friday afternoon")],
        runningWorkflows: running,
        timers: timers
    )
}

private func plan(_ text: String, _ vocab: CommandVocabulary = vocabulary(), file: StaticString = #filePath, line: UInt = #line) -> CommandPlan? {
    let outcome = DeterministicParser(vocabulary: vocab).parse(text)
    guard case .plan(let plan) = outcome else {
        XCTFail("“\(text)” gave \(outcome), not a plan", file: file, line: line)
        return nil
    }
    return plan
}

private func steps(_ plan: CommandPlan?) -> [CommandPlan.Step] {
    if case .actions(let steps) = plan?.kind { return steps }
    return []
}

// MARK: - Animation states

final class CompanionStateMachineTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_000_000)

    func testRunShowsExecutingThenSuccessThenIdle() {
        var machine = CompanionStateMachine(now: t0)
        let run = UUID()
        XCTAssertEqual(machine.handle(.runStarted(run), at: t0), .executing)
        // Finishing quickly: executing holds its minimum time first.
        XCTAssertNil(machine.handle(.runFinished(run, .succeeded), at: t0 + 0.2))
        XCTAssertEqual(machine.displayed, .executing)
        XCTAssertEqual(machine.tick(at: t0 + 0.8), .success)
        // Success lasts about 1.5 s.
        XCTAssertNil(machine.tick(at: t0 + 2.0))
        XCTAssertEqual(machine.tick(at: t0 + 2.3), .idle)
    }

    func testFailedAndPartialRunsShowFailure() {
        for state in [RunState.failed, .partiallySucceeded] {
            var machine = CompanionStateMachine(now: t0)
            let run = UUID()
            machine.handle(.runStarted(run), at: t0)
            machine.handle(.runFinished(run, state), at: t0 + 1)
            XCTAssertEqual(machine.displayed, .failure, "\(state)")
            XCTAssertEqual(machine.tick(at: t0 + 2.6), .idle)
        }
    }

    func testCancelledRunShowsNoVerdict() {
        var machine = CompanionStateMachine(now: t0)
        let run = UUID()
        machine.handle(.runStarted(run), at: t0)
        machine.handle(.runFinished(run, .canceled), at: t0 + 1)
        XCTAssertEqual(machine.displayed, .idle)
    }

    func testCommandBoxListensThenThinks() {
        var machine = CompanionStateMachine(now: t0)
        XCTAssertEqual(machine.handle(.commandOpened, at: t0), .listening)
        XCTAssertEqual(machine.handle(.commandParsing, at: t0 + 1), .thinking)
        XCTAssertEqual(machine.handle(.commandParsed, at: t0 + 2), .listening)
        XCTAssertEqual(machine.handle(.commandClosed, at: t0 + 3), .idle)
    }

    func testQuickFlickersAreHeldForTheMinimumTime() {
        var machine = CompanionStateMachine(now: t0)
        machine.handle(.commandOpened, at: t0)
        machine.handle(.commandParsing, at: t0 + 0.4)
        // Parsing finishes almost at once; thinking still shows for 0.5 s.
        XCTAssertNil(machine.handle(.commandParsed, at: t0 + 0.45))
        XCTAssertEqual(machine.displayed, .thinking)
        XCTAssertEqual(machine.nextDeadline(after: t0 + 0.45), t0 + 0.9)
        XCTAssertEqual(machine.tick(at: t0 + 0.9), .listening)
    }

    func testInteractionWinsOverWork() {
        var machine = CompanionStateMachine(now: t0)
        machine.handle(.runStarted(UUID()), at: t0)
        XCTAssertEqual(machine.handle(.commandOpened, at: t0 + 1), .listening)
        XCTAssertEqual(machine.handle(.commandClosed, at: t0 + 2), .executing, "Still working underneath")
    }

    func testSleepsAfterTenMinutesAndWakesOnActivity() {
        var machine = CompanionStateMachine(now: t0)
        XCTAssertEqual(machine.nextDeadline(after: t0), t0 + 600)
        XCTAssertNil(machine.tick(at: t0 + 599))
        XCTAssertEqual(machine.tick(at: t0 + 600), .sleeping)
        XCTAssertEqual(machine.handle(.activity, at: t0 + 700), .idle)
        XCTAssertEqual(machine.handle(.macIdle(true), at: t0 + 710), .sleeping)
        XCTAssertEqual(machine.handle(.macIdle(false), at: t0 + 720), .idle)
    }

    func testFocusIsCalmButWorkStillShows() {
        var machine = CompanionStateMachine(now: t0)
        XCTAssertEqual(machine.handle(.focus(true), at: t0), .focus)
        let run = UUID()
        XCTAssertEqual(machine.handle(.runStarted(run), at: t0 + 1), .executing)
        machine.handle(.runFinished(run, .succeeded), at: t0 + 2)
        XCTAssertEqual(machine.tick(at: t0 + 3.6), .focus)
    }

    func testEventsMapToInputs() {
        let run = UUID()
        XCTAssertEqual(CompanionStateMachine.input(for: AtlasEvent(AtlasEvent.Name.workflowStarted, payload: ["runId": .string(run.uuidString)])),
                       .runStarted(run))
        XCTAssertEqual(CompanionStateMachine.input(for: AtlasEvent(AtlasEvent.Name.workflowFinished,
                                                                   payload: ["runId": .string(run.uuidString), "state": "partiallySucceeded"])),
                       .runFinished(run, .partiallySucceeded))
        XCTAssertNil(CompanionStateMachine.input(for: AtlasEvent("file.created")))
    }

    func testReducedMotionUsesColourOnly() {
        let full = CharacterPresentation.make(for: .executing, intensity: .full, reduceMotion: false)
        XCTAssertFalse(full.isStill)
        let reducedSystem = CharacterPresentation.make(for: .executing, intensity: .full, reduceMotion: true)
        XCTAssertTrue(reducedSystem.isStill)
        XCTAssertEqual(reducedSystem.accent, full.accent, "The state still shows through colour")
        let reduced = CharacterPresentation.make(for: .failure, intensity: .reduced, reduceMotion: false)
        XCTAssertTrue(reduced.isStill)
        XCTAssertEqual(reduced.gesture, .none)
        XCTAssertNotEqual(reduced.accent, CharacterPresentation.make(for: .success, intensity: .reduced, reduceMotion: false).accent)
        XCTAssertEqual(CharacterPresentation.make(for: .idle, intensity: .still, reduceMotion: false).rendering, .staticImage)
        XCTAssertTrue(CharacterPresentation.make(for: .sleeping, intensity: .full, reduceMotion: false).eyesClosed)
    }
}

// MARK: - Deterministic parser

final class DeterministicParserTests: XCTestCase {
    func testSpecExampleCommands() {
        let coding = plan("Open my coding room")
        XCTAssertEqual(steps(coding).first?.actionID, SpaceActivateAction.id)
        XCTAssertEqual(steps(coding).first?.parameters["space"], "Coding Lab")
        XCTAssertEqual(coding?.summary, "Activate Coding Lab — Deep Work")
        XCTAssertTrue(coding?.needsConfirmation == true)

        if case .findFiles(let query) = plan("Find my project specifications")?.kind {
            XCTAssertEqual(query, "project specifications")
        } else { XCTFail("Expected a file search") }

        let timer = plan("Start my study timer")
        XCTAssertEqual(steps(timer).first?.actionID, StartTimerAction.id)
        XCTAssertEqual(steps(timer).first?.parameters["name"], "Study")
        XCTAssertEqual(steps(timer).first?.parameters["seconds"], .number(1_500))

        let layout = plan("Arrange my windows for an interview")
        XCTAssertEqual(steps(layout).first?.actionID, ApplyWindowLayoutAction.id)
        XCTAssertEqual(steps(layout).first?.parameters["layout"], "Interview")

        XCTAssertEqual(plan("Show me what's taking up storage")?.kind, .open(.largestFiles))
        XCTAssertEqual(plan("Show me what's taking up storage")?.needsConfirmation, false)

        if case .workflow(_, let name) = plan("Run my morning setup")?.kind {
            XCTAssertEqual(name, "Morning Setup")
        } else { XCTFail("Expected a workflow") }
    }

    func testSynonyms() {
        XCTAssertEqual(steps(plan("switch to study library")).first?.parameters["space"], "Study Library")
        XCTAssertEqual(steps(plan("go to the creative studio")).first?.parameters["space"], "Creative Studio")
        XCTAssertEqual(steps(plan("activate coding lab")).first?.parameters["space"], "Coding Lab")
        XCTAssertEqual(steps(plan("launch safari")).first?.actionID, LaunchApplicationAction.id)
        XCTAssertEqual(steps(plan("open visual studio code")).first?.parameters["bundleId"], "com.microsoft.VSCode")
        if case .workflow(_, let name) = plan("execute focus reset")?.kind { XCTAssertEqual(name, "Focus Reset") } else { XCTFail() }
        if case .findFiles(let query) = plan("where is my tax return")?.kind { XCTAssertEqual(query, "tax return") } else { XCTFail() }
        XCTAssertEqual(plan("pause automations")?.kind, .pauseAutomations(true))
        XCTAssertEqual(plan("resume")?.kind, .pauseAutomations(false))
        XCTAssertEqual(plan("please open the run history")?.kind, .open(.runHistory(nil)))
        XCTAssertEqual(steps(plan("restore friday afternoon")).first?.parameters["snapshot"], "Friday afternoon")
        XCTAssertEqual(steps(plan("quit notes")).first?.actionID, QuitApplicationAction.id)
    }

    func testProfilesAndTimerLengths() {
        let review = plan("open coding lab quick review")
        XCTAssertEqual(steps(review).first?.parameters["profile"], "Quick Review")
        XCTAssertEqual(review?.summary, "Activate Coding Lab — Quick Review")
        XCTAssertEqual(steps(plan("start a 50 minute focus timer")).first?.parameters["seconds"], .number(3_000))
        XCTAssertEqual(steps(plan("set a timer for 1 hour 30 min")).first?.parameters["seconds"], .number(5_400))
        XCTAssertEqual(steps(plan("start a break timer")).first?.parameters["seconds"], .number(300))
        let stop = plan("stop the study timer", vocabulary(timers: ["Study"]))
        XCTAssertEqual(steps(stop).first?.actionID, StopTimerAction.id)
        XCTAssertEqual(steps(stop).first?.parameters["name"], "Study")
    }

    func testTypos() {
        XCTAssertEqual(steps(plan("opne my codng room")).first?.parameters["space"], "Coding Lab")
        if case .workflow(_, let name) = plan("run mornign setup")?.kind { XCTAssertEqual(name, "Morning Setup") } else { XCTFail() }
        XCTAssertEqual(steps(plan("swtich to studdy library")).first?.parameters["space"], "Study Library")
        XCTAssertEqual(steps(plan("arange windows for interveiw")).first?.parameters["layout"], "Interview")
    }

    func testAmbiguityAsksInsteadOfGuessing() {
        let outcome = DeterministicParser(vocabulary: vocabulary()).parse("open coding")
        guard case .choices(_, let plans) = outcome else { return XCTFail("Expected choices, got \(outcome)") }
        let summaries = Set(plans.map(\.summary))
        XCTAssertTrue(summaries.contains("Activate Coding Lab — Deep Work"))
        XCTAssertTrue(summaries.contains("Run Coding Setup"))
        // A hint word settles it.
        XCTAssertEqual(steps(plan("open coding room")).first?.actionID, SpaceActivateAction.id)
        if case .workflow = plan("run coding")?.kind {} else { XCTFail("“run” prefers workflows") }
    }

    func testUnknownCommands() {
        let parser = DeterministicParser(vocabulary: vocabulary())
        for text in ["make me a sandwich", "", "switch to the moon base", "arrange windows for karaoke", "quit photoshop"] {
            if case .unknown(let message) = parser.parse(text) {
                XCTAssertFalse(message.isEmpty)
            } else {
                XCTFail("“\(text)” should be unknown, got \(parser.parse(text))")
            }
        }
        if case .unknown(let message) = parser.parse("arrange windows for karaoke") {
            XCTAssertTrue(message.contains("Interview"), "Lists the layouts that do exist")
        }
    }

    func testStopRunning() {
        let runID = UUID()
        let vocab = vocabulary(running: [.init(id: runID.uuidString, name: "Morning Setup")])
        XCTAssertEqual(plan("stop morning setup", vocab)?.kind, .stopRun(runID))
        XCTAssertEqual(plan("stop everything", vocab)?.kind, .stopRun(nil))
        if case .unknown = DeterministicParser(vocabulary: vocabulary()).parse("stop everything") {} else { XCTFail("Nothing is running") }
    }
}

// MARK: - AI plans

/// Answers with canned text, and counts calls.
private final class MockModelProvider: IntentModelProvider, @unchecked Sendable {
    var answer: String
    var error: Error?
    var unavailable: String?
    private(set) var requests: [AIRequest] = []

    init(answer: String) { self.answer = answer }
    var displayName: String { "Mock model" }
    func unavailableReason() async -> String? { unavailable }
    func complete(_ request: AIRequest) async throws -> String {
        requests.append(request)
        if let error { throw error }
        return answer
    }
}

private func answer(kind: String, steps: [(String, [(String, String)])] = [], target: String = "", profile: String = "",
                    query: String = "", destination: String = "none", summary: String = "", message: String = "") -> String {
    let stepJSON = steps.map { action, parameters in
        "{\"action\": \"\(action)\", \"parameters\": [" + parameters.map { "{\"key\": \"\($0.0)\", \"value\": \"\($0.1)\"}" }.joined(separator: ",") + "]}"
    }.joined(separator: ",")
    return """
    {"kind": "\(kind)", "summary": "\(summary)", "steps": [\(stepJSON)], "target": "\(target)", "profile": "\(profile)",
     "query": "\(query)", "destination": "\(destination)", "message": "\(message)"}
    """
}

final class AIPlanValidationTests: XCTestCase {
    private func setup(authorized: [String] = ["/Users/test/Downloads"]) throws -> (SpacesHarness, CommandVocabulary) {
        let h = try SpacesHarness()
        h.core.fileAccess.setRoots(authorized)
        try h.makeSpace("Coding Lab", steps: [WorkflowStep(actionID: LaunchApplicationAction.id, parameters: ["bundleId": "com.apple.Terminal"])])
        let vocab = CommandVocabularyBuilder.build(store: h.store, apps: [.init(id: "com.apple.Notes", name: "Notes")])
        return (h, vocab)
    }

    private func validator(_ h: SpacesHarness, _ vocab: CommandVocabulary) -> PlanValidator {
        PlanValidator(registry: h.core.registry, vocabulary: vocab, fileAccess: h.core.fileAccess)
    }

    func testRejectsUnregisteredActions() throws {
        let (h, vocab) = try setup()
        for id in ["shell.run", "applescript.execute", "orbit.organize", "file.undo"] {
            XCTAssertThrowsError(try validator(h, vocab).validate(try AIPlanResponse.decode(answer(kind: "actions", steps: [(id, [])])))) {
                XCTAssertTrue(($0 as? PlanRejection)?.reason.contains(id) == true, "\(id): \($0)")
            }
        }
    }

    func testRejectsMissingAndUnknownParameters() throws {
        let (h, vocab) = try setup()
        let missing = answer(kind: "actions", steps: [("file.move", [("source", "/Users/test/Downloads/a.pdf")])])
        XCTAssertThrowsError(try validator(h, vocab).validate(try AIPlanResponse.decode(missing)))
        let unknown = answer(kind: "actions", steps: [("application.launch", [("bundleId", "com.apple.Notes"), ("sudo", "true")])])
        XCTAssertThrowsError(try validator(h, vocab).validate(try AIPlanResponse.decode(unknown)))
    }

    func testRejectsPathsOutsideAuthorizedFolders() throws {
        let (h, vocab) = try setup()
        let outside = answer(kind: "actions", steps: [("file.trash", [("path", "/etc/hosts")])])
        XCTAssertThrowsError(try validator(h, vocab).validate(try AIPlanResponse.decode(outside))) {
            XCTAssertTrue(($0 as? PlanRejection)?.reason.contains("Orbit") == true)
        }
        let inside = answer(kind: "actions", steps: [("file.trash", [("path", "/Users/test/Downloads/old.dmg")])])
        let plan = try validator(h, vocab).validate(try AIPlanResponse.decode(inside))
        XCTAssertTrue(plan.fromAI)
        XCTAssertTrue(plan.needsConfirmation)
    }

    func testRejectsMadeUpNamesAndAcceptsRealOnes() throws {
        let (h, vocab) = try setup()
        XCTAssertThrowsError(try validator(h, vocab).validate(try AIPlanResponse.decode(answer(kind: "space", target: "Moon Base"))))
        XCTAssertThrowsError(try validator(h, vocab).validate(try AIPlanResponse.decode(answer(kind: "workflow", target: "Hack the Planet"))))
        XCTAssertThrowsError(try validator(h, vocab).validate(try AIPlanResponse.decode(answer(kind: "none", message: "Can't do that"))))
        XCTAssertThrowsError(try AIPlanResponse.decode("I think you should open Safari"))
        let space = try validator(h, vocab).validate(try AIPlanResponse.decode(answer(kind: "space", target: "coding lab")))
        XCTAssertEqual(steps(space).first?.parameters["space"], "Coding Lab")
        XCTAssertTrue(space.fromAI && space.needsConfirmation)
    }

    func testRequestOnlyContainsAllowedContext() throws {
        let (h, vocab) = try setup()
        var context = CompanionContext()
        context.activeSpace = "Coding Lab"
        let request = AIRequest.make(text: "get ready for my interview", registry: h.core.registry, vocabulary: vocab, context: context)
        XCTAssertTrue(request.preview.contains("Active Space: Coding Lab"))
        XCTAssertFalse(request.preview.contains("Frontmost app"), "Nothing that wasn't allowed")
        XCTAssertFalse(request.instructions.contains("orbit.organize"), "Internal actions aren't offered")
        XCTAssertTrue(request.instructions.contains("space.activate"))
    }

    func testAIPlansNeverRunWithoutConfirmation() async throws {
        let (h, vocab) = try setup()
        let provider = MockModelProvider(answer: answer(kind: "space", target: "Coding Lab"))
        let resolver = IntentResolver(parser: DeterministicParser(vocabulary: vocab), validator: validator(h, vocab), provider: provider)
        let result = await resolver.resolve("get my programming stuff going", context: CompanionContext())
        XCTAssertTrue(result.usedAI)
        guard let plan = result.outcome.plan else { return XCTFail("Expected a plan: \(result.outcome)") }
        XCTAssertTrue(plan.needsConfirmation)
        XCTAssertEqual(try h.store.runs(limit: 10).count, 0, "Resolving never runs anything")
        XCTAssertTrue(h.system.calls.isEmpty)

        // Running is a separate, explicit step, through the engine.
        guard case .run(let run) = await CommandRunner(core: h.core).run(plan, text: "get my programming stuff going", source: .palette) else {
            return XCTFail("Expected a run")
        }
        XCTAssertEqual(run.trigger, RunTrigger.companion)
        XCTAssertEqual(run.state, .succeeded)
    }

    func testFallsBackToBuiltInParserWhenAIFails() async throws {
        let (h, vocab) = try setup()
        let provider = MockModelProvider(answer: answer(kind: "actions", steps: [("shell.run", [("cmd", "rm -rf ~")])]))
        let resolver = IntentResolver(parser: DeterministicParser(vocabulary: vocab), validator: validator(h, vocab), provider: provider)

        let rejected = await resolver.resolve("tidy up everything", context: CompanionContext())
        XCTAssertFalse(rejected.usedAI)
        XCTAssertTrue(rejected.note?.contains("rejected") == true, rejected.note ?? "")

        provider.error = URLError(.notConnectedToInternet)
        let offline = await resolver.resolve("tidy up everything", context: CompanionContext())
        XCTAssertTrue(offline.note?.contains("Used built-in commands") == true)

        provider.unavailable = "No key."
        let unavailable = await resolver.resolve("tidy up everything", context: CompanionContext())
        XCTAssertTrue(unavailable.note?.hasPrefix("No key.") == true)

        // A confident built-in match never calls the model.
        let before = provider.requests.count
        let builtIn = await resolver.resolve("open my coding room", context: CompanionContext())
        XCTAssertEqual(provider.requests.count, before)
        XCTAssertFalse(builtIn.usedAI)
        XCTAssertEqual(steps(builtIn.outcome.plan).first?.parameters["space"], "Coding Lab")
    }
}

// MARK: - Running commands

final class CommandRunnerTests: XCTestCase {
    func testRunsThroughTheEngineAndPublishesTheCommand() async throws {
        let h = try SpacesHarness()
        try h.makeSpace("Coding Lab", steps: [WorkflowStep(actionID: LaunchApplicationAction.id, parameters: ["bundleId": "com.apple.Terminal"])])
        let recorder = EventRecorder(h.core.events, "companion.*")
        let vocab = CommandVocabularyBuilder.build(store: h.store, apps: [])
        let coding = try XCTUnwrap(DeterministicParser(vocabulary: vocab).parse("open my coding room").plan)

        guard case .run(let run) = await CommandRunner(core: h.core).run(coding, text: "open my coding room", source: .palette) else {
            return XCTFail("Expected a run")
        }
        XCTAssertEqual(run.state, .succeeded)
        XCTAssertEqual(run.trigger, RunTrigger.companion)
        XCTAssertEqual(StatusMessages.message(for: run, store: h.store), "Coding Lab ready · 1 of 1 steps")
        XCTAssertTrue(h.system.calls.contains { $0.contains("com.apple.Terminal") })
        let event = try XCTUnwrap(recorder.all.first { $0.name == AtlasEvent.Name.companionCommand })
        XCTAssertEqual(event.payload["summary"], "Activate Coding Lab — Default")
        XCTAssertEqual(event.payload["source"], "palette")
        XCTAssertEqual(try h.store.companionCommands().first?.text, "open my coding room")
    }

    func testRunsTurnedOffWorkflowsLikeAManualRun() async throws {
        let h = try TestHarness()
        let workflow = try h.core.save(Workflow(name: "Off", isEnabled: false, steps: [WorkflowStep(actionID: LogMessageAction.id, parameters: ["message": "hi"])]))
        let plan = CommandPlan(kind: .workflow(workflow.id, name: "Off"), summary: "Run Off", hasSideEffects: true)
        guard case .run(let run) = await CommandRunner(core: h.core).run(plan, text: "run off", source: .palette) else { return XCTFail() }
        XCTAssertEqual(run.state, .succeeded, "A confirmed Companion command is an explicit run")
    }

    func testTimersCanBeListedAndStopped() async throws {
        let h = try TestHarness()
        let name = "Study \(UUID().uuidString.prefix(4))"
        let start = CommandPlan(kind: .actions([.init(StartTimerAction.id, ["name": .string(name), "seconds": 600])]), summary: "", hasSideEffects: true)
        _ = await CommandRunner(core: h.core).run(start, text: "", source: .click)
        XCTAssertTrue(TimerCenter.shared.active.contains { $0.name == name })
        let stop = CommandPlan(kind: .actions([.init(StopTimerAction.id, ["name": .string(name)])]), summary: "", hasSideEffects: true)
        guard case .run(let run) = await CommandRunner(core: h.core).run(stop, text: "", source: .click) else { return XCTFail() }
        XCTAssertEqual(run.state, .succeeded)
        XCTAssertFalse(TimerCenter.shared.active.contains { $0.name == name })
        guard case .run(let again) = await CommandRunner(core: h.core).run(stop, text: "", source: .click) else { return XCTFail() }
        XCTAssertEqual(again.state, .failed, "Stopping a timer that isn't running says so")
    }

    func testPauseAndStop() async throws {
        let h = try TestHarness()
        _ = await CommandRunner(core: h.core).run(CommandPlan(kind: .pauseAutomations(true), summary: "", hasSideEffects: true), text: "", source: .click)
        let paused = await h.engine.isPaused
        XCTAssertTrue(paused)
        _ = await CommandRunner(core: h.core).run(CommandPlan(kind: .pauseAutomations(false), summary: "", hasSideEffects: true), text: "", source: .click)
        let resumed = await h.engine.isPaused
        XCTAssertFalse(resumed)
    }
}

// MARK: - Suggestions

private final class Clock: @unchecked Sendable {
    var now = Date(timeIntervalSince1970: 1_700_000_000)
}

final class SuggestionTests: XCTestCase {
    private func suggestion(_ kind: Suggestion.Kind) -> Suggestion {
        Suggestion(kind: kind, title: kind.title, reason: "test", actionTitle: "OK", action: .openReviewQueue)
    }

    func testGateRateLimitsToOneEveryFifteenMinutes() {
        var gate = SuggestionGate()
        let t0 = Date(timeIntervalSince1970: 0)
        XCTAssertTrue(gate.offer(suggestion(.reviewQueue), at: t0))
        XCTAssertFalse(gate.offer(suggestion(.lowDisk), at: t0 + 60))
        XCTAssertFalse(gate.offer(suggestion(.lowDisk), at: t0 + 14 * 60))
        XCTAssertTrue(gate.offer(suggestion(.lowDisk), at: t0 + 15 * 60))
    }

    func testDontSuggestAgainMutesThatKindOnly() {
        var gate = SuggestionGate()
        gate.mute(.reviewQueue)
        XCTAssertFalse(gate.allows(.reviewQueue, at: Date()))
        XCTAssertTrue(gate.allows(.lowDisk, at: Date()))
        gate.enabled = false
        XCTAssertFalse(gate.allows(.lowDisk, at: Date()))
    }

    func testCenterLogsEverySuggestionWithItsReason() throws {
        let h = try TestHarness()
        let clock = Clock()
        let center = SuggestionCenter(store: h.store, events: h.core.events, settings: CompanionSettings(), now: { clock.now })
        let recorder = EventRecorder(h.core.events, "companion.suggestion.*")
        var shown: [Suggestion] = []
        center.onSuggestion = { shown.append($0) }

        center.handle(AtlasEvent(AtlasEvent.Name.healthThreshold, payload: ["metric": "diskFree", "message": "Only 9 GB free"]))
        XCTAssertEqual(shown.map(\.kind), [.lowDisk])
        // Within 15 minutes: held back.
        clock.now += 300
        center.handle(AtlasEvent(AtlasEvent.Name.healthThreshold, payload: ["metric": "diskFree", "message": "Only 8 GB free"]))
        XCTAssertEqual(shown.count, 1)
        // Other health warnings aren't disk suggestions.
        clock.now += 1_000
        center.handle(AtlasEvent(AtlasEvent.Name.healthThreshold, payload: ["metric": "cpu"]))
        XCTAssertEqual(shown.count, 1)

        center.dismissed(shown[0], forever: true)
        center.handle(AtlasEvent(AtlasEvent.Name.healthThreshold, payload: ["metric": "diskFree", "message": "Only 7 GB free"]))
        XCTAssertEqual(shown.count, 1, "Don't suggest this again")

        let log = try h.store.suggestionLog()
        XCTAssertEqual(log.count, 1)
        XCTAssertEqual(log.first?.reason, "Only 9 GB free")
        XCTAssertEqual(log.first?.state, .muted)
        XCTAssertEqual(recorder.all.map(\.name), [AtlasEvent.Name.companionSuggestionShown, AtlasEvent.Name.companionSuggestionDismissed])
    }

    func testDisplayConnectedOffersTheMatchingLayout() throws {
        let h = try TestHarness()
        let profile = DisplayProfile(displays: [MockWindowAdapter.builtIn, MockWindowAdapter.external])
        try h.store.saveWindowLayout(WindowLayout(name: "Programming", displayProfile: profile))
        let center = SuggestionCenter(store: h.store, events: h.core.events, settings: CompanionSettings())
        var shown: [Suggestion] = []
        center.onSuggestion = { shown.append($0) }
        center.handle(AtlasEvent(AtlasEvent.Name.displayChanged, payload: ["displayCount": 1, "profileId": "single"]))
        XCTAssertTrue(shown.isEmpty, "The first report only sets the baseline")
        center.handle(AtlasEvent(AtlasEvent.Name.displayChanged, payload: ["displayCount": 2, "profileId": .string(profile.id)]))
        XCTAssertEqual(shown.first?.title, "Apply your Programming layout?")
        XCTAssertEqual(shown.first?.action, .applyLayout("Programming"))
    }

    func testFailedAutomaticRunIsExplained() throws {
        let h = try TestHarness()
        let center = SuggestionCenter(store: h.store, events: h.core.events, settings: CompanionSettings())
        var shown: [Suggestion] = []
        center.onSuggestion = { shown.append($0) }
        var run = WorkflowRun(workflowID: UUID(), workflowName: "Morning Setup", trigger: "trigger.time", state: .failed)
        let node = UUID()
        run.steps = [StepRecord(position: 0, nodeID: node, actionID: LaunchApplicationAction.id, label: "Launch Notz", state: .failed,
                                error: "No installed app has the bundle identifier “com.apple.Notz”.", inputs: ["bundleId": "com.apple.Notz"])]
        try h.store.saveRun(run)
        center.handle(AtlasEvent(AtlasEvent.Name.workflowFinished, payload: ["runId": .string(run.id.uuidString), "state": "failed", "trigger": "trigger.time"]))
        XCTAssertEqual(shown.first?.kind, .workflowFailed)
        XCTAssertTrue(shown.first?.detail.contains("isn't installed") == true, shown.first?.detail ?? "")
        XCTAssertEqual(shown.first?.action, .openWorkflowAt(workflowID: run.workflowID, nodeID: node))
    }

    func testFailureExplainer() {
        func run(_ error: String, inputs: ActionParameters = [:]) -> WorkflowRun {
            var run = WorkflowRun(workflowID: UUID(), workflowName: "W", trigger: "companion", state: .failed)
            run.steps = [StepRecord(position: 0, nodeID: UUID(), actionID: "x", label: "Step", state: .failed, error: error, inputs: inputs)]
            return run
        }
        let missing = FailureExplainer.explain(run("No installed app has the bundle identifier “com.bad.app”.")) { $0 == "com.bad.app" ? nil : "?" }
        XCTAssertTrue(missing.message.hasPrefix("com.bad.app isn't installed"))
        XCTAssertEqual(missing.fixTitle, "Fix the Step")
        XCTAssertEqual(FailureExplainer.explain(run("ATLAS doesn't have Accessibility permission yet.")).fix, .openPermissions)
        XCTAssertEqual(FailureExplainer.explain(run("/Users/x isn't in Orbit. Add it in Orbit → Folders.")).fix, .openOrbitFolders)
        let other = FailureExplainer.explain(run("Something odd"))
        XCTAssertEqual(other.fix, .openRunHistory(other.fix.flatMap { if case .openRunHistory(let id) = $0 { return id } else { return nil } }!))
    }
}

final class RepetitionDetectorTests: XCTestCase {
    let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    private func day(_ n: Int, _ apps: [String], start: TimeInterval = 9 * 3_600, gap: TimeInterval = 40) -> [AppLaunch] {
        let base = Date(timeIntervalSince1970: 1_700_000_000 - 1_700_000_000.truncatingRemainder(dividingBy: 86_400)) + Double(n) * 86_400 + start
        return apps.enumerated().map { AppLaunch(bundleID: $1, date: base + Double($0) * gap) }
    }

    func testThreeDaysOfTheSameRoutineIsDetected() {
        let routine = ["com.apple.Safari", "com.apple.Notes", "com.apple.dt.Xcode"]
        let launches = day(0, routine) + day(2, routine) + day(5, routine) + day(5, ["com.spotify.client"], start: 15 * 3_600)
        let pattern = RepetitionDetector.detect(launches, calendar: calendar)
        XCTAssertEqual(pattern?.bundleIDs, routine)
        XCTAssertEqual(pattern?.days, 3)
    }

    func testTwoDaysIsNotEnough() {
        let routine = ["com.apple.Safari", "com.apple.Notes"]
        XCTAssertNil(RepetitionDetector.detect(day(0, routine) + day(1, routine), calendar: calendar))
    }

    func testSameDayRepeatsCountOnce() {
        let routine = ["com.apple.Safari", "com.apple.Notes"]
        let launches = day(0, routine) + day(0, routine, start: 12 * 3_600) + day(0, routine, start: 18 * 3_600)
        XCTAssertNil(RepetitionDetector.detect(launches, calendar: calendar))
    }

    func testOrderAndTimingMatter() {
        let a = ["com.apple.Safari", "com.apple.Notes", "com.apple.Music"]
        let shuffled = day(0, a) + day(1, a.reversed()) + day(2, [a[1], a[0], a[2]])
        XCTAssertNil(RepetitionDetector.detect(shuffled, calendar: calendar), "Different order each day")
        let spread = day(0, a, gap: 900) + day(1, a, gap: 900) + day(2, a, gap: 900)
        XCTAssertNil(RepetitionDetector.detect(spread, calendar: calendar), "Not within a few minutes")
    }

    func testRoutinesAlreadyInAWorkflowAreSkipped() {
        let routine = ["com.apple.Safari", "com.apple.Notes"]
        let workflow = Workflow(name: "Mine", steps: routine.map { WorkflowStep(actionID: LaunchApplicationAction.id, parameters: ["bundleId": .string($0)]) })
        let known = RepetitionDetector.knownSequences(in: [workflow])
        XCTAssertNil(RepetitionDetector.detect(day(0, routine) + day(1, routine) + day(2, routine), calendar: calendar, excluding: known))
    }

    func testLaunchHistoryIsKeptForFourteenDays() throws {
        let h = try TestHarness()
        let clock = Clock()
        let center = SuggestionCenter(store: h.store, events: h.core.events, settings: CompanionSettings(), now: { clock.now })
        try h.store.recordAppLaunch(bundleID: "old.app", at: clock.now - 15 * 86_400)
        center.recordManualLaunch(bundleID: "com.apple.Safari")
        let kept = try h.store.appLaunches(since: .distantPast)
        XCTAssertEqual(kept.map(\.bundleID), ["com.apple.Safari"])

        var settings = CompanionSettings()
        settings.repetitionDetection = false
        center.update(settings: settings)
        center.recordManualLaunch(bundleID: "com.apple.Notes")
        XCTAssertEqual(try h.store.appLaunches(since: .distantPast).count, 1, "Off means nothing is recorded")
        try h.store.clearAppLaunches()
        XCTAssertTrue(try h.store.appLaunches(since: .distantPast).isEmpty)
    }
}

// MARK: - Overlay geometry

final class OverlayGeometryTests: XCTestCase {
    // AppKit coordinates: y up, main display at the origin.
    let laptop = OverlayGeometry.Screen(frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
                                        visibleFrame: CGRect(x: 0, y: 70, width: 1440, height: 805), isMain: true)
    let external = OverlayGeometry.Screen(frame: CGRect(x: 1440, y: 0, width: 2560, height: 1440),
                                          visibleFrame: CGRect(x: 1440, y: 0, width: 2560, height: 1415), isMain: false)
    let size = CGSize(width: 116, height: 116)

    func testDefaultsToTheBottomRightOfTheMainDisplay() {
        let origin = OverlayGeometry.restore(saved: [:], size: size, screens: [laptop, external])
        XCTAssertEqual(origin, CGPoint(x: 1440 - 116 - 16, y: 70 + 16))
    }

    func testRestoresThePositionSavedForThisArrangement() {
        let both = OverlayGeometry.arrangementKey([laptop, external])
        let alone = OverlayGeometry.arrangementKey([laptop])
        XCTAssertNotEqual(both, alone)
        XCTAssertEqual(both, OverlayGeometry.arrangementKey([external, laptop]), "Order doesn't matter")
        let saved = [both: CGPoint(x: 3000, y: 600), alone: CGPoint(x: 100, y: 200)]
        XCTAssertEqual(OverlayGeometry.restore(saved: saved, size: size, screens: [laptop, external]), CGPoint(x: 3000, y: 600))
        XCTAssertEqual(OverlayGeometry.restore(saved: saved, size: size, screens: [laptop]), CGPoint(x: 100, y: 200))
    }

    func testSnapsBackWhenADisplayIsUnplugged() {
        // Saved on the external display, which is now gone: nearest screen, fully visible.
        let clamped = OverlayGeometry.clamp(origin: CGPoint(x: 3000, y: 600), size: size, screens: [laptop])
        XCTAssertEqual(clamped, CGPoint(x: 1440 - 116, y: 600))
        XCTAssertTrue(laptop.visibleFrame.contains(CGRect(origin: clamped, size: size)))
    }

    func testPartlyOffScreenMovesFullyOn() {
        let clamped = OverlayGeometry.clamp(origin: CGPoint(x: 1400, y: 10), size: size, screens: [laptop])
        XCTAssertEqual(clamped, CGPoint(x: 1324, y: 70), "Above the Dock, inside the right edge")
        // Mostly on the external display: stays there.
        let spanning = OverlayGeometry.clamp(origin: CGPoint(x: 1420, y: 300), size: size, screens: [laptop, external])
        XCTAssertEqual(spanning, CGPoint(x: 1440, y: 300))
    }

    func testBubbleSitsBesideTheCharacterOnScreen() {
        let character = CGRect(x: 1308, y: 86, width: 116, height: 116)
        let bubble = OverlayGeometry.bubbleOrigin(character: character, bubble: CGSize(width: 280, height: 80), screens: [laptop])
        XCTAssertLessThan(bubble.x + 280, character.minX + 1, "To the left when the right edge is near")
        let leftEdge = OverlayGeometry.bubbleOrigin(character: CGRect(x: 10, y: 300, width: 116, height: 116),
                                                    bubble: CGSize(width: 280, height: 80), screens: [laptop])
        XCTAssertGreaterThanOrEqual(leftEdge.x, 126)
    }
}

// MARK: - Settings, storage and migration

final class CompanionStoreTests: XCTestCase {
    func testSettingsRoundTrip() throws {
        let store = try AtlasStore.inMemory()
        XCTAssertEqual(try store.companionSettings(), CompanionSettings(), "Defaults before anything is saved")
        var settings = CompanionSettings()
        settings.character = .orb
        settings.primaryColor = "#FF0000"
        settings.accessory = .headphones
        settings.size = .large
        settings.intensity = .reduced
        settings.overlayMode = .normal
        settings.clickThrough = false
        settings.positions = ["0,0,1440x900": StoredPoint(x: 10, y: 20)]
        settings.aiProvider = .cloud
        settings.context.frontmostApp = false
        settings.mutedSuggestions = ["lowDisk"]
        settings.favoriteWorkflowIDs = [UUID()]
        settings.paletteHotKey = "ctrl+opt+k"
        try store.saveCompanionSettings(settings)
        XCTAssertEqual(try store.companionSettings(), settings)
    }

    func testCommandHistoryKeepsTheLastFifty() throws {
        let store = try AtlasStore.inMemory()
        for i in 0..<60 {
            try store.recordCompanionCommand(text: "command \(i)", summary: "", source: "palette", at: Date(timeIntervalSince1970: Double(i)))
        }
        let commands = try store.companionCommands(limit: 100)
        XCTAssertEqual(commands.count, 50)
        XCTAssertEqual(commands.first?.text, "command 59")
        try store.clearCompanionCommands()
        XCTAssertTrue(try store.companionCommands().isEmpty)
    }

    func testCharacterLimits() {
        XCTAssertNil(CharacterLimits.problem(with: .init(fileBytes: 2_000_000, triangles: 12_000, extent: 1.8)))
        XCTAssertNotNil(CharacterLimits.problem(with: .init(fileBytes: 90_000_000, triangles: 12_000, extent: 1.8)))
        XCTAssertTrue(CharacterLimits.problem(with: .init(fileBytes: 1_000, triangles: 250_000, extent: 1))?.contains("polygons") == true)
        XCTAssertNotNil(CharacterLimits.problem(with: .init(fileBytes: 1_000, triangles: 0, extent: 1)))
        XCTAssertNotNil(CharacterLimits.problem(with: .init(fileBytes: 1_000, triangles: 100, extent: 4_000)))
    }

    func testV5DatabaseMigratesToV6() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("atlas-v5-\(UUID().uuidString).sqlite")
        defer {
            for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: url.path + suffix) }
        }
        let workflowID = UUID()
        do {
            let db = try SQLiteDatabase(path: url.path)
            for (index, sql) in Schema.migrations.prefix(5).enumerated() {
                try db.transaction {
                    try db.execute(sql)
                    try db.setUserVersion(index + 1)
                }
            }
            try db.run("INSERT INTO workflow (id, name, created_at, updated_at) VALUES (?, 'Old', 0, 0);", [.from(workflowID)])
            try db.run("INSERT INTO health_sample (taken_at, cpu, memory_used, memory_total, disk_free, disk_total) VALUES (1, 5, 1, 2, 1, 2);")
        }

        let store = try AtlasStore(database: SQLiteDatabase(path: url.path))
        XCTAssertEqual(store.database.userVersion, 6)
        XCTAssertEqual(try store.workflow(id: workflowID)?.name, "Old", "Existing data survives")
        XCTAssertEqual(try store.healthSamples(from: .distantPast).count, 1)
        XCTAssertEqual(try store.companionSettings(), CompanionSettings())
        var settings = CompanionSettings()
        settings.character = .creature
        try store.saveCompanionSettings(settings)
        try store.recordCompanionCommand(text: "open my coding room", summary: "Activate Coding Lab", source: "palette")
        try store.recordAppLaunch(bundleID: "com.apple.Safari")
        try store.logSuggestion(Suggestion(kind: .reviewQueue, title: "t", reason: "r", actionTitle: "a", action: .openReviewQueue))
        XCTAssertEqual(try store.companionSettings().character, .creature)
        XCTAssertEqual(try store.companionCommands().count, 1)
        XCTAssertEqual(try store.suggestionLog().count, 1)
    }
}
