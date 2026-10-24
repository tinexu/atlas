import XCTest
@testable import AtlasCore

final class AutomationEngineTests: XCTestCase {

    func testRunsStepsInOrderAndSucceeds() async throws {
        let h = try TestHarness()
        let workflow = Workflow(name: "Setup", steps: [.launch("com.apple.Terminal"), .launch("com.apple.Notes")])

        let run = await h.engine.run(workflow)

        XCTAssertEqual(run.state, .succeeded)
        XCTAssertEqual(run.steps.map(\.state), [.succeeded, .succeeded])
        XCTAssertEqual(h.system.calls, ["launch:com.apple.Terminal", "launch:com.apple.Notes"])
        XCTAssertEqual(run.steps[0].message, "Launched Terminal")
        XCTAssertEqual(run.steps[0].output["wasAlreadyRunning"], .bool(false))
    }

    func testAlreadyRunningAppIsReportedNotRelaunched() async throws {
        let h = try TestHarness()
        h.system.markRunning("com.apple.Terminal")

        let run = await h.engine.run(Workflow(name: "W", steps: [.launch("com.apple.Terminal")]))

        XCTAssertEqual(run.steps[0].message, "Terminal was already running")
    }

    func testStopOnFailureSkipsRemainingSteps() async throws {
        let h = try TestHarness()
        let workflow = Workflow(name: "W", failurePolicy: .stopOnFailure, steps: [
            .launch("com.apple.Terminal"), .launch("com.example.Missing"), .launch("com.apple.Notes"),
        ])

        let run = await h.engine.run(workflow)

        XCTAssertEqual(run.steps.map(\.state), [.succeeded, .failed, .skipped])
        XCTAssertEqual(run.state, .partiallySucceeded, "Partial results must not be reported as success")
        XCTAssertFalse(h.system.calls.contains("launch:com.apple.Notes"))
        XCTAssertNotNil(run.error)
    }

    func testContinueOnFailureRunsEverything() async throws {
        let h = try TestHarness()
        let workflow = Workflow(name: "W", failurePolicy: .continueOnFailure, steps: [
            .launch("com.example.Missing"), .launch("com.apple.Notes"),
        ])

        let run = await h.engine.run(workflow)

        XCTAssertEqual(run.steps.map(\.state), [.failed, .succeeded])
        XCTAssertEqual(run.state, .partiallySucceeded)
    }

    func testAllStepsFailingIsFailed() async throws {
        let h = try TestHarness()
        let run = await h.engine.run(Workflow(name: "W", steps: [.launch("com.example.Missing")]))
        XCTAssertEqual(run.state, .failed)
    }

    func testDisabledStepIsSkipped() async throws {
        let h = try TestHarness()
        var off = WorkflowStep.launch("com.apple.Notes")
        off.isEnabled = false

        let run = await h.engine.run(Workflow(name: "W", steps: [.launch("com.apple.Terminal"), off]))

        XCTAssertEqual(run.steps.map(\.state), [.succeeded, .skipped])
        XCTAssertEqual(run.state, .succeeded)
        XCTAssertEqual(h.system.calls, ["launch:com.apple.Terminal"])
    }

    func testMissingParameterFailsWithoutCallingSystem() async throws {
        let h = try TestHarness()
        let step = WorkflowStep(actionID: LaunchApplicationAction.id)

        let run = await h.engine.run(Workflow(name: "W", steps: [step]))

        XCTAssertEqual(run.state, .failed)
        XCTAssertTrue(h.system.calls.isEmpty)
    }

    func testUnknownActionFails() async throws {
        let h = try TestHarness()
        let run = await h.engine.run(Workflow(name: "W", steps: [WorkflowStep(actionID: "plugin.missing")]))
        XCTAssertEqual(run.state, .failed)
        XCTAssertEqual(run.steps[0].error, ActionError.unknownAction("plugin.missing").errorDescription)
    }

    func testActionTurnedOffByUserIsRefused() async throws {
        let h = try TestHarness()
        try h.core.permissions.setEnabled(false, for: LaunchApplicationAction.id)

        let run = await h.engine.run(Workflow(name: "W", steps: [.launch("com.apple.Terminal")]))

        XCTAssertEqual(run.state, .failed)
        XCTAssertTrue(h.system.calls.isEmpty)
    }

    func testDeniedPermissionBlocksAction() async throws {
        let h = try TestHarness(permissions: MockPermissionProvider(statuses: [.notifications: .denied]))
        let step = WorkflowStep(actionID: ShowNotificationAction.id, parameters: ["title": "Hi"])

        let run = await h.engine.run(Workflow(name: "W", steps: [step]))

        XCTAssertEqual(run.state, .failed)
        XCTAssertTrue(h.system.calls.isEmpty)
    }

    func testUndeterminedPermissionIsRequestedOnce() async throws {
        let provider = MockPermissionProvider(statuses: [.notifications: .notDetermined])
        let h = try TestHarness(permissions: provider)
        let step = WorkflowStep(actionID: ShowNotificationAction.id, parameters: ["title": "Hi"])

        let run = await h.engine.run(Workflow(name: "W", steps: [step, step]))

        XCTAssertEqual(run.state, .succeeded)
        XCTAssertEqual(provider.requestCount, 1)
    }

    func testConfirmationRequiredStepRefusedWithoutHandler() async throws {
        let h = try TestHarness()
        h.system.markRunning("com.apple.Music")
        let step = WorkflowStep(actionID: QuitApplicationAction.id, parameters: ["bundleId": "com.apple.Music"])

        let run = await h.engine.run(Workflow(name: "W", steps: [step]))

        XCTAssertEqual(run.state, .failed)
        XCTAssertFalse(h.system.calls.contains("quit:com.apple.Music"), "Never quit an app without approval")
    }

    func testConfirmationApprovedRunsStep() async throws {
        let h = try TestHarness()
        h.system.markRunning("com.apple.Music")
        await h.engine.setConfirmationHandler { request in
            request.descriptor.id == QuitApplicationAction.id
        }
        let step = WorkflowStep(actionID: QuitApplicationAction.id, parameters: ["bundleId": "com.apple.Music"])

        let run = await h.engine.run(Workflow(name: "W", steps: [step]))

        XCTAssertEqual(run.state, .succeeded)
        XCTAssertEqual(h.system.calls, ["quit:com.apple.Music"])
    }

    func testConfirmationDeclinedStopsWorkflow() async throws {
        let h = try TestHarness()
        h.system.markRunning("com.apple.Music")
        await h.engine.setConfirmationHandler { _ in false }
        let quit = WorkflowStep(actionID: QuitApplicationAction.id, parameters: ["bundleId": "com.apple.Music"])

        let run = await h.engine.run(Workflow(name: "W", steps: [quit, .launch("com.apple.Notes")]))

        XCTAssertEqual(run.steps.map(\.state), [.failed, .skipped])
        XCTAssertTrue(h.system.calls.isEmpty)
    }

    func testTimeoutFailsSlowStep() async throws {
        let h = try TestHarness()
        let start = Date()

        let run = await h.engine.run(Workflow(name: "W", steps: [.wait(10, timeout: 0.2)]))

        XCTAssertEqual(run.state, .failed)
        XCTAssertEqual(run.steps[0].error, ActionError.timedOut(0.2).errorDescription)
        XCTAssertLessThan(Date().timeIntervalSince(start), 3, "Timeout must return promptly")
    }

    func testIdempotentActionRetriesUntilSuccess() async throws {
        let system = MockSystemAdapter()
        system.transientFailures["com.apple.Terminal"] = 2
        let h = try TestHarness(system: system)
        await h.engine.setRetryBackoff(0.01)

        let run = await h.engine.run(Workflow(name: "W", steps: [.launch("com.apple.Terminal", retries: 3)]))

        XCTAssertEqual(run.state, .succeeded)
        XCTAssertEqual(run.steps[0].attempts, 3)
    }

    func testNonIdempotentActionIsNeverRetried() async throws {
        let system = MockSystemAdapter()
        system.failsToOpenURLs = true
        let h = try TestHarness(system: system)
        await h.engine.setRetryBackoff(0.01)
        // url.open is not idempotent: a retry could open a duplicate tab.
        let step = WorkflowStep(actionID: OpenURLAction.id, parameters: ["url": "https://example.com"], maxRetries: 3)

        let run = await h.engine.run(Workflow(name: "W", steps: [step]))

        XCTAssertEqual(run.state, .failed)
        XCTAssertEqual(run.steps[0].attempts, 1)
        XCTAssertEqual(system.calls.filter { $0.hasPrefix("open-url:") }.count, 1)
    }

    func testCancelStopsRunAndMarksRemainingSteps() async throws {
        let h = try TestHarness()
        let workflow = Workflow(name: "W", steps: [.wait(5), .launch("com.apple.Notes")])

        let runID = await h.engine.start(workflow)
        try await Task.sleep(nanoseconds: 100_000_000)
        await h.engine.cancel(runID: runID)
        try await Task.sleep(nanoseconds: 300_000_000)

        let stored = try XCTUnwrap(try h.store.runs().first { $0.id == runID })
        XCTAssertEqual(stored.state, .canceled)
        XCTAssertEqual(stored.steps.map(\.state), [.canceled, .canceled])
        XCTAssertFalse(h.system.calls.contains("launch:com.apple.Notes"))
        let stillRunning = await h.engine.isRunning(workflowID: workflow.id)
        XCTAssertFalse(stillRunning)
    }

    func testPausedEngineSkipsRuns() async throws {
        let h = try TestHarness()
        await h.engine.setPaused(true)

        let run = await h.engine.run(Workflow(name: "W", steps: [.launch("com.apple.Terminal")]))

        XCTAssertEqual(run.state, .skipped)
        XCTAssertTrue(h.system.calls.isEmpty)
    }

    func testRunsArePersistedWithSteps() async throws {
        let h = try TestHarness()
        let workflow = Workflow(name: "Persisted", steps: [.launch("com.apple.Terminal"), .log("done")])

        let run = await h.engine.run(workflow, trigger: "test")

        let stored = try XCTUnwrap(try h.store.runs(workflowID: workflow.id).first)
        XCTAssertEqual(stored.id, run.id)
        XCTAssertEqual(stored.trigger, "test")
        XCTAssertEqual(stored.state, .succeeded)
        XCTAssertEqual(stored.steps.count, 2)
        XCTAssertEqual(stored.steps[1].message, "done")
        XCTAssertNotNil(stored.finishedAt)
    }

    func testEventsArePublishedInOrder() async throws {
        let h = try TestHarness()
        let collected = EventCollector()
        h.core.events.subscribe("*") { collected.append($0.name) }

        _ = await h.engine.run(Workflow(name: "W", steps: [.launch("com.apple.Terminal")]))

        XCTAssertEqual(collected.names, [
            AtlasEvent.Name.workflowStarted,
            AtlasEvent.Name.stepStarted,
            AtlasEvent.Name.stepFinished,
            AtlasEvent.Name.workflowFinished,
        ])
    }

    func testInvokeRunsSingleActionThroughEngine() async throws {
        let h = try TestHarness()

        let run = await h.engine.invoke(LaunchApplicationAction.id, parameters: ["bundleId": "com.apple.Notes"], source: "shortcut")

        XCTAssertEqual(run.state, .succeeded)
        XCTAssertEqual(run.trigger, "shortcut")
        XCTAssertEqual(h.system.calls, ["launch:com.apple.Notes"])
    }
}

final class EventCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var _names: [String] = []
    var names: [String] { lock.synchronized { _names } }
    func append(_ name: String) { lock.synchronized { _names.append(name) } }
}
