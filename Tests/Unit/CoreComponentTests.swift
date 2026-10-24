import XCTest
@testable import AtlasCore

final class ActionRegistryTests: XCTestCase {

    func testStandardRegistryContainsBuiltIns() {
        let registry = ActionRegistry.standard()
        for id in [LaunchApplicationAction.id, OpenURLAction.id, OpenFileAction.id, DelayAction.id] {
            XCTAssertNotNil(registry.descriptor(for: id), "\(id) missing")
        }
    }

    func testDuplicateRegistrationThrows() {
        let registry = ActionRegistry.standard()
        XCTAssertThrowsError(try registry.register(LaunchApplicationAction())) { error in
            XCTAssertEqual(error as? ActionError, .duplicateRegistration(LaunchApplicationAction.id))
        }
    }

    func testValidationFillsDefaultsAndDropsUnknownKeys() throws {
        let registry = ActionRegistry.standard()
        let descriptor = try XCTUnwrap(registry.descriptor(for: LaunchApplicationAction.id))

        let resolved = try registry.validate(["bundleId": "com.apple.Notes", "junk": "x"], for: descriptor)

        XCTAssertEqual(resolved["bundleId"], "com.apple.Notes")
        XCTAssertEqual(resolved["activate"], .bool(true))
        XCTAssertNil(resolved["junk"])
    }

    func testValidationRejectsBadValues() throws {
        let registry = ActionRegistry.standard()
        let launch = try XCTUnwrap(registry.descriptor(for: LaunchApplicationAction.id))
        let url = try XCTUnwrap(registry.descriptor(for: OpenURLAction.id))
        let wait = try XCTUnwrap(registry.descriptor(for: DelayAction.id))
        let file = try XCTUnwrap(registry.descriptor(for: OpenFileAction.id))

        XCTAssertThrowsError(try registry.validate([:], for: launch))
        XCTAssertThrowsError(try registry.validate(["bundleId": "   "], for: launch))
        XCTAssertThrowsError(try registry.validate(["bundleId": "not a bundle id"], for: launch))
        XCTAssertThrowsError(try registry.validate(["url": "example.com"], for: url))
        XCTAssertThrowsError(try registry.validate(["seconds": 99_999], for: wait))
        XCTAssertThrowsError(try registry.validate(["seconds": "soon"], for: wait))
        XCTAssertThrowsError(try registry.validate(["path": "relative/path"], for: file))
        XCTAssertNoThrow(try registry.validate(["path": "~/Documents/a.pdf"], for: file))
    }

    func testDisplayLabelUsesFirstParameter() {
        let registry = ActionRegistry.standard()
        XCTAssertEqual(registry.displayLabel(for: .launch("com.apple.Notes")), "Launch App · com.apple.Notes")
        var labelled = WorkflowStep.launch("com.apple.Notes")
        labelled.label = "Open my notes"
        XCTAssertEqual(registry.displayLabel(for: labelled), "Open my notes")
    }
}

final class EventBusTests: XCTestCase {

    func testPatternMatching() {
        XCTAssertTrue(EventBus.matches(pattern: "*", name: "anything"))
        XCTAssertTrue(EventBus.matches(pattern: "workflow.*", name: "workflow.started"))
        XCTAssertFalse(EventBus.matches(pattern: "workflow.*", name: "workflows.started"))
        XCTAssertTrue(EventBus.matches(pattern: "space.activated", name: "space.activated"))
        XCTAssertFalse(EventBus.matches(pattern: "space.activated", name: "space.deactivated"))
    }

    func testSubscribeAndUnsubscribe() {
        let bus = EventBus()
        let collected = EventCollector()
        let subscription = bus.subscribe("file.*") { collected.append($0.name) }

        bus.publish(AtlasEvent("file.created"))
        bus.publish(AtlasEvent("space.activated"))
        bus.unsubscribe(subscription)
        bus.publish(AtlasEvent("file.deleted"))

        XCTAssertEqual(collected.names, ["file.created"])
    }

    func testHandlerMayPublishWithoutDeadlock() {
        let bus = EventBus()
        let collected = EventCollector()
        bus.subscribe("a") { _ in bus.publish(AtlasEvent("b")) }
        bus.subscribe("b") { collected.append($0.name) }

        bus.publish(AtlasEvent("a"))

        XCTAssertEqual(collected.names, ["b"])
    }

    func testStreamDeliversEvents() async {
        let bus = EventBus()
        let stream = bus.stream("x.*")
        let reader = Task { () -> String? in
            for await event in stream { return event.name }
            return nil
        }
        // Give the subscription a moment to register before publishing.
        try? await Task.sleep(nanoseconds: 50_000_000)
        bus.publish(AtlasEvent("y.ignored"))
        bus.publish(AtlasEvent("x.hit"))
        let name = await reader.value
        XCTAssertEqual(name, "x.hit")
    }

    func testHistoryIsBounded() {
        let bus = EventBus(historyLimit: 3)
        (1...5).forEach { bus.publish(AtlasEvent("e\($0)")) }
        XCTAssertEqual(bus.recentEvents.map(\.name), ["e3", "e4", "e5"])
    }
}

final class AtlasStoreTests: XCTestCase {

    func testSchemaVersionIsCurrent() throws {
        let store = try AtlasStore.inMemory()
        XCTAssertEqual(store.database.userVersion, Schema.currentVersion)
    }

    func testMigrationIsIdempotent() throws {
        let db = try SQLiteDatabase(path: ":memory:")
        _ = try AtlasStore(database: db)
        XCTAssertNoThrow(try AtlasStore(database: db))
    }

    func testWorkflowRoundTrip() throws {
        let store = try AtlasStore.inMemory()
        var original = Workflow(name: "Round trip", summary: "s", failurePolicy: .continueOnFailure, steps: [
            WorkflowStep(actionID: OpenURLAction.id, parameters: ["url": "https://a.example", "n": 3, "flag": true],
                         isEnabled: false, label: "Docs", timeout: 12, maxRetries: 2),
            .launch("com.apple.Notes"),
        ])
        original.createdAt = Date(timeIntervalSince1970: 1_000)
        original.updatedAt = Date(timeIntervalSince1970: 2_000)

        try store.saveWorkflow(original)
        let loaded = try XCTUnwrap(try store.workflow(id: original.id))

        XCTAssertEqual(loaded, original)
    }

    func testSavingReplacesSteps() throws {
        let store = try AtlasStore.inMemory()
        var workflow = Workflow(name: "W", steps: [.launch("com.apple.Notes"), .launch("com.apple.Terminal")])
        try store.saveWorkflow(workflow)

        workflow.steps.removeFirst()
        workflow.name = "Renamed"
        try store.saveWorkflow(workflow)

        let loaded = try XCTUnwrap(try store.workflows().first)
        XCTAssertEqual(loaded.name, "Renamed")
        XCTAssertEqual(loaded.steps.map(\.id), workflow.steps.map(\.id))
        XCTAssertEqual(try store.workflows().count, 1)
    }

    func testDeletingWorkflowKeepsHistory() async throws {
        let h = try TestHarness()
        let workflow = Workflow(name: "Temp", steps: [.launch("com.apple.Notes")])
        try h.store.saveWorkflow(workflow)
        _ = await h.engine.run(workflow)

        try h.core.delete(workflowID: workflow.id)

        XCTAssertNil(try h.store.workflow(id: workflow.id))
        XCTAssertEqual(try h.store.runs(workflowID: workflow.id).count, 1)
    }

    func testInterruptedRunsAreClosed() throws {
        let store = try AtlasStore.inMemory()
        let run = WorkflowRun(workflowID: UUID(), workflowName: "W", trigger: "manual", state: .running, steps: [
            StepRecord(position: 0, nodeID: UUID(), actionID: "x", label: "x", state: .running),
        ])
        try store.saveRun(run)

        try store.closeInterruptedRuns()

        let closed = try XCTUnwrap(try store.runs().first)
        XCTAssertEqual(closed.state, .canceled)
        XCTAssertEqual(closed.steps.first?.state, .canceled)
        XCTAssertNotNil(closed.error)
    }

    func testPruneKeepsNewestRuns() throws {
        let store = try AtlasStore.inMemory()
        for i in 0..<5 {
            try store.saveRun(WorkflowRun(workflowID: UUID(), workflowName: "r\(i)", trigger: "t", state: .succeeded,
                                          startedAt: Date(timeIntervalSince1970: Double(i))))
        }
        try store.pruneRuns(keepingLatest: 2)
        XCTAssertEqual(try store.runs().map(\.workflowName), ["r4", "r3"])
    }

    func testPreferencesRoundTrip() throws {
        let store = try AtlasStore.inMemory()
        try store.setPreference(["a", "b"], for: "list")
        XCTAssertEqual(try store.preference("list", as: [String].self), ["a", "b"])
        try store.setPreference(Optional<[String]>.none, for: "list")
        XCTAssertNil(try store.preference("list", as: [String].self))
    }

    func testDisabledActionsPersist() throws {
        let store = try AtlasStore.inMemory()
        let first = PermissionManager(provider: MockPermissionProvider(), store: store)
        try first.setEnabled(false, for: OpenURLAction.id)

        let second = PermissionManager(provider: MockPermissionProvider(), store: store)
        XCTAssertFalse(second.isEnabled(OpenURLAction.id))
        XCTAssertTrue(second.isEnabled(LaunchApplicationAction.id))
    }

    func testSamplesSeedOnlyOnce() throws {
        let h = try TestHarness()
        try h.core.seedSampleWorkflowsIfNeeded()
        let seeded = try h.store.workflows()
        XCTAssertEqual(seeded.count, SampleWorkflows.all.count)

        for workflow in seeded { try h.core.delete(workflowID: workflow.id) }
        try h.core.seedSampleWorkflowsIfNeeded()
        XCTAssertTrue(try h.store.workflows().isEmpty, "Deleted samples must not come back")
    }

    func testSampleWorkflowsAreValid() throws {
        let registry = ActionRegistry.standard()
        for workflow in SampleWorkflows.all {
            for step in workflow.steps {
                let descriptor = try XCTUnwrap(registry.descriptor(for: step.actionID), "\(workflow.name)")
                XCTAssertNoThrow(try registry.validate(step.parameters, for: descriptor), "\(workflow.name): \(step.actionID)")
            }
        }
    }
}

final class ActionValueTests: XCTestCase {

    func testCodableRoundTrip() throws {
        let params: ActionParameters = ["s": "text", "n": 2.5, "i": 3, "b": true, "z": .null]
        let data = try JSONEncoder().encode(params)
        let decoded = try JSONDecoder().decode(ActionParameters.self, from: data)
        XCTAssertEqual(decoded, params)
    }

    func testConversions() {
        XCTAssertEqual(ActionValue.number(3).displayString, "3")
        XCTAssertEqual(ActionValue.number(2.5).displayString, "2.5")
        XCTAssertEqual(ActionValue.string("4").numberValue, 4)
        XCTAssertEqual(ActionValue.string("yes").boolValue, true)
        XCTAssertTrue(ActionValue.string("  ").isEmpty)
    }
}
