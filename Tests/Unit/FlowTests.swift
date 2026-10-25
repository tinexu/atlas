import XCTest
@testable import AtlasCore

/// Builds graphs for tests.
struct GraphBuilder {
    var steps: [WorkflowStep] = []
    var connections: [WorkflowConnection] = []

    @discardableResult
    mutating func add(_ step: WorkflowStep) -> UUID {
        steps.append(step)
        return step.id
    }

    mutating func flow(_ from: UUID, _ port: String = NodePort.controlOut, to: UUID) {
        connections.append(WorkflowConnection(fromNode: from, fromPort: port, toNode: to))
    }

    mutating func data(_ from: UUID, _ port: String, to: UUID, _ input: String) {
        connections.append(WorkflowConnection(fromNode: from, fromPort: port, toNode: to, toPort: input))
    }

    func workflow(_ name: String = "W", policy: FailurePolicy = .stopOnFailure, settings: WorkflowSettings = .default,
                  variables: [WorkflowVariable] = []) -> Workflow {
        Workflow(name: name, failurePolicy: policy, steps: steps, connections: connections, variables: variables, settings: settings)
    }
}

extension WorkflowStep {
    static func notify(_ title: String) -> WorkflowStep {
        WorkflowStep(actionID: ShowNotificationAction.id, parameters: ["title": .string(title)])
    }

    static func move(to folder: String, path: String? = nil, label: String? = nil) -> WorkflowStep {
        var parameters: ActionParameters = ["destination": .string(folder)]
        if let path { parameters["path"] = .string(path) }
        return WorkflowStep(actionID: MoveFileAction.id, parameters: parameters, label: label)
    }

    static func delay(_ seconds: Double) -> WorkflowStep {
        .control(.delay, parameters: ["seconds": .number(seconds)])
    }
}

// MARK: - Migration & store

final class FlowStoreTests: XCTestCase {

    func testMigrationFromV3TurnsStepListsIntoChainsAndKeepsHistory() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("atlas-v3-\(UUID().uuidString).sqlite")
        defer { for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: url.path + suffix) } }
        let workflowID = UUID(), runID = UUID()
        let nodeIDs = [UUID(), UUID(), UUID()]
        let apps = ["com.apple.Terminal", "com.apple.Notes", "com.apple.Music"]

        // A Stage 03 database with a three-step list and a run of it.
        do {
            let db = try SQLiteDatabase(path: url.path)
            for (index, sql) in Schema.migrations.prefix(3).enumerated() {
                try db.transaction {
                    try db.execute(sql)
                    try db.setUserVersion(index + 1)
                }
            }
            try db.run("INSERT INTO workflow (id, name, created_at, updated_at) VALUES (?, 'Morning', 0, 0);", [.from(workflowID)])
            for (position, id) in nodeIDs.enumerated() {
                try db.run(
                    "INSERT INTO workflow_node (id, workflow_id, position, action_id, parameters_json) VALUES (?, ?, ?, 'application.launch', ?);",
                    [.from(id), .from(workflowID), .from(position), .text("{\"bundleId\":\"\(apps[position])\"}")]
                )
            }
            try db.run(
                "INSERT INTO workflow_run (id, workflow_id, workflow_name, trigger, state, started_at) VALUES (?, ?, 'Morning', 'manual', 'succeeded', 0);",
                [.from(runID), .from(workflowID)]
            )
            for (position, id) in nodeIDs.enumerated() {
                try db.run(
                    "INSERT INTO workflow_run_step (run_id, position, node_id, action_id, label, state) VALUES (?, ?, ?, 'application.launch', 'Launch', 'succeeded');",
                    [.from(runID), .from(position), .from(id)]
                )
            }
        }

        let store = try AtlasStore(database: SQLiteDatabase(path: url.path))

        XCTAssertEqual(store.database.userVersion, Schema.currentVersion)
        let workflow = try XCTUnwrap(try store.workflow(id: workflowID))
        XCTAssertEqual(workflow.steps.map(\.id), nodeIDs, "Node IDs kept")
        XCTAssertTrue(workflow.steps.allSatisfy { $0.kind == .action })
        XCTAssertFalse(workflow.hasTriggers)
        XCTAssertEqual(workflow.connections.count, 2)
        XCTAssertEqual(workflow.connections.map(\.fromNode), [nodeIDs[0], nodeIDs[1]])
        XCTAssertEqual(workflow.connections.map(\.toNode), [nodeIDs[1], nodeIDs[2]])
        XCTAssertTrue(workflow.connections.allSatisfy(\.isControl))
        XCTAssertNotNil(UUID(uuidString: workflow.connections[0].id.uuidString))
        XCTAssertEqual(workflow.steps.map(\.position.x), [0, 280, 560])
        XCTAssertTrue(workflow.isLinear)

        // Old history still opens and lines up with the nodes.
        let run = try XCTUnwrap(try store.run(id: runID))
        XCTAssertEqual(run.steps.map(\.nodeID), nodeIDs)

        // And the migrated graph runs exactly like the old list.
        let system = MockSystemAdapter()
        let core = AtlasCore(store: store, system: system, permissionProvider: MockPermissionProvider())
        let newRun = await core.engine.run(workflow)
        XCTAssertEqual(newRun.state, .succeeded)
        XCTAssertEqual(system.calls, apps.map { "launch:\($0)" })
    }

    func testGraphRoundTrip() throws {
        let store = try AtlasStore.inMemory()
        var g = GraphBuilder()
        let trigger = g.add(.trigger(TriggerCatalog.fileCreated, parameters: ["folder": "~/Downloads"], at: NodePosition(x: 1, y: 2, z: 3)))
        let check = g.add(.condition(ConditionGroup(.fileExtension(path: "{{trigger.path}}", extensions: "pdf"),
                                                    .timeInRange(start: "09:00", end: "17:00"), match: .any)))
        let loop = g.add(.control(.loop, parameters: ["items": "a,b"], config: NodeConfig(loopMode: .forEach, maxIterations: 50)))
        var move = WorkflowStep.move(to: "~/Documents/PDFs", label: "Move")
        move.failurePolicy = .continueOnFailure
        move.timeout = 12
        let moveID = g.add(move)
        g.flow(trigger, to: check)
        g.flow(check, "true", to: loop)
        g.flow(loop, "body", to: moveID)
        g.data(trigger, "path", to: moveID, "path")
        var workflow = g.workflow(
            "Tidy",
            settings: WorkflowSettings(reentrancy: .queueOne, minimumInterval: 5, maxRunsPerMinute: 3, selfTriggerLimit: 2,
                                       groups: [NodeGroup(name: "Sort", nodeIDs: [check, loop])]),
            variables: [WorkflowVariable(name: "count", initialValue: 0, isSaved: true), WorkflowVariable(name: "temp")]
        )
        workflow.createdAt = Date(timeIntervalSince1970: 100)
        workflow.updatedAt = Date(timeIntervalSince1970: 200)
        NodePorts.refresh(&workflow, registry: .standard())

        try store.saveWorkflow(workflow)

        let loaded = try XCTUnwrap(try store.workflow(id: workflow.id))
        XCTAssertEqual(loaded, workflow)
        XCTAssertEqual(loaded.steps[0].ports.first { $0.id == "path" }?.type, .filePath, "Typed ports stored")

        // Saved variable values survive re-saving the workflow.
        try store.setSavedVariableValue(7, name: "count", workflowID: workflow.id)
        try store.saveWorkflow(loaded)
        XCTAssertEqual(try store.savedVariableValues(workflowID: workflow.id), ["count": 7])

        // Deleting cascades.
        try store.deleteWorkflow(id: workflow.id)
        XCTAssertEqual(try store.database.query("SELECT COUNT(*) AS n FROM workflow_connection;").first?.int("n"), 0)
        XCTAssertEqual(try store.database.query("SELECT COUNT(*) AS n FROM workflow_variable;").first?.int("n"), 0)
    }

    func testRunRecordKeepsPayloadPathAndInputs() async throws {
        let h = try TestHarness()
        var g = GraphBuilder()
        let trigger = g.add(.trigger(TriggerCatalog.appLaunched))
        let log = g.add(.log("Hello {{trigger.appName}}"))
        g.flow(trigger, to: log)
        let workflow = try h.core.save(g.workflow())

        let run = await h.engine.run(workflow, trigger: RunTrigger.automatic(TriggerCatalog.appLaunched),
                                     payload: ["appName": "Blender"], entryNodeID: trigger)

        let stored = try XCTUnwrap(try h.store.run(id: run.id))
        XCTAssertEqual(stored.trigger, "trigger.app.launched")
        XCTAssertTrue(stored.isAutomatic)
        XCTAssertEqual(stored.triggerPayload, ["appName": "Blender"])
        XCTAssertEqual(stored.path, [workflow.connections[0].id])
        XCTAssertEqual(stored.steps[1].inputs["message"], "Hello Blender")
        XCTAssertEqual(stored.steps[0].kind, .trigger)
    }

    func testRunHistoryFilters() async throws {
        let h = try TestHarness()
        let a = try h.core.save(Workflow(name: "A", steps: [.log("a")]))
        let b = try h.core.save(Workflow(name: "B", steps: [.launch("com.example.Missing")]))
        _ = await h.engine.run(a)
        _ = await h.engine.run(a, trigger: RunTrigger.automatic(TriggerCatalog.woke))
        _ = await h.engine.run(b)

        XCTAssertEqual(try h.store.runs(matching: RunQuery(workflowID: a.id)).count, 2)
        XCTAssertEqual(try h.store.runs(matching: RunQuery(trigger: "trigger.*")).count, 1)
        XCTAssertEqual(try h.store.runs(matching: RunQuery(states: [.failed])).map(\.workflowName), ["B"])
        XCTAssertEqual(try h.store.runs(matching: RunQuery(from: Date().addingTimeInterval(60))).count, 0)
    }
}

// MARK: - Validation

final class WorkflowValidatorTests: XCTestCase {
    let registry = ActionRegistry.standard()

    private func errors(_ workflow: Workflow) -> [String] {
        WorkflowValidator.validate(workflow, registry: registry).filter { $0.severity == .error }.map(\.message)
    }

    func testPlainStepListIsValid() {
        XCTAssertEqual(errors(Workflow(name: "W", steps: [.launch("com.apple.Terminal"), .log("ok")])), [])
    }

    func testMissingRequiredInput() {
        var g = GraphBuilder()
        let trigger = g.add(.trigger(TriggerCatalog.fileCreated, parameters: ["folder": "/in"]))
        let open = g.add(WorkflowStep(actionID: OpenFileAction.id))
        g.flow(trigger, to: open)
        XCTAssertTrue(errors(g.workflow()).contains { $0.contains("needs “File”") })

        // Connecting the input satisfies it.
        g.data(trigger, "path", to: open, "path")
        XCTAssertEqual(errors(g.workflow()), [])
    }

    func testTypeMismatch() {
        var g = GraphBuilder()
        let trigger = g.add(.trigger(TriggerCatalog.batteryLow))
        let launch = g.add(.launch("com.apple.Notes"))
        g.flow(trigger, to: launch)
        g.data(trigger, "batteryPercent", to: launch, "bundleId")
        let issue = WorkflowValidator.validate(g.workflow(), registry: registry).first { $0.connectionID != nil }
        XCTAssertNotNil(issue)
        XCTAssertTrue(issue?.message.contains("number can't go into a app input") ?? false, issue?.message ?? "")
        XCTAssertEqual(PortType.number.incompatibility(with: .string), nil, "Numbers can be shown as text")
        XCTAssertNotNil(PortType.control.incompatibility(with: .string))
    }

    func testCycleIsRejected() {
        var g = GraphBuilder()
        let a = g.add(.log("a"))
        let b = g.add(.log("b"))
        let c = g.add(.log("c"))
        g.flow(a, to: b)
        g.flow(b, to: c)
        g.flow(c, to: b)
        XCTAssertTrue(errors(g.workflow()).contains { $0.contains("in a circle") })
    }

    func testUnreachableAndExtraStarts() {
        var g = GraphBuilder()
        let trigger = g.add(.trigger(TriggerCatalog.woke))
        let a = g.add(.log("a"))
        g.flow(trigger, to: a)
        let island1 = g.add(.log("x"))
        let island2 = g.add(.log("y"))
        g.flow(island1, to: island2)
        g.flow(island2, to: island1)
        XCTAssertTrue(errors(g.workflow()).contains { $0.contains("can't be reached") })

        var two = GraphBuilder()
        two.add(.log("one"))
        two.add(.log("two"))
        two.connections = [WorkflowConnection(fromNode: UUID(), toNode: UUID())] // force graph mode
        XCTAssertTrue(errors(two.workflow()).contains { $0.contains("only one start") })
    }

    func testNodeLevelChecks() {
        var g = GraphBuilder()
        let trigger = g.add(.trigger(TriggerCatalog.hotKey, parameters: ["shortcut": "k"]))
        let loop = g.add(.control(.loop, parameters: ["items": "a"], config: NodeConfig(maxIterations: 5_000)))
        let variable = g.add(.control(.setVariable))
        g.flow(trigger, to: loop)
        g.flow(loop, "done", to: variable)
        let messages = errors(g.workflow())
        XCTAssertTrue(messages.contains { $0.contains("need ⌘, ⌃ or ⌥") }, "\(messages)")
        XCTAssertTrue(messages.contains { $0.contains("between 1 and 1000") })
        XCTAssertTrue(messages.contains { $0.contains("needs a variable name") })
    }

    func testSubworkflowCallingItselfIsAnError() {
        let id = UUID()
        var workflow = Workflow(id: id, name: "Self", steps: [.control(.subworkflow, config: NodeConfig(workflowID: id))])
        workflow.connections = []
        XCTAssertTrue(errors(workflow).contains { $0.contains("calls this same workflow") })
    }

    func testUnknownTriggerOutputInTemplateIsAWarning() {
        var g = GraphBuilder()
        let trigger = g.add(.trigger(TriggerCatalog.woke))
        let log = g.add(.log("{{trigger.path}}"))
        g.flow(trigger, to: log)
        let warnings = WorkflowValidator.validate(g.workflow(), registry: registry).filter { $0.severity == .warning }
        XCTAssertTrue(warnings.contains { $0.message.contains("{{trigger.path}}") })
    }

    func testWorkflowWithErrorsIsSavedAsADraft() throws {
        let h = try TestHarness()
        var g = GraphBuilder()
        let trigger = g.add(.trigger(TriggerCatalog.fileCreated, parameters: ["folder": "/in"]))
        let open = g.add(WorkflowStep(actionID: OpenFileAction.id))
        g.flow(trigger, to: open)

        let saved = try h.core.save(g.workflow())

        XCTAssertFalse(saved.isEnabled, "Can't be enabled with errors")
        XCTAssertEqual(try h.store.workflow(id: saved.id)?.isEnabled, false)
        XCTAssertFalse(saved.steps[1].ports.isEmpty, "Ports are filled in on save")
    }
}

// MARK: - Runner

final class FlowRunnerTests: XCTestCase {

    /// Tidy Downloads, run by hand with a sample payload.
    private func tidyDownloads() -> (Workflow, trigger: UUID, move: UUID, otherwise: UUID) {
        var g = GraphBuilder()
        let trigger = g.add(.trigger(TriggerCatalog.fileCreated, parameters: ["folder": "/dl"]))
        let check = g.add(.condition(ConditionGroup(.fileExtension(path: "{{trigger.path}}", extensions: "pdf"))))
        let move = g.add(.move(to: "/docs/PDFs", label: "Move"))
        let notify = g.add(.notify("Moved {{trigger.fileName}} to {{node.Move.folder}}"))
        let otherwise = g.add(.log("Left {{trigger.fileName}} alone"))
        g.flow(trigger, to: check)
        g.flow(check, "true", to: move)
        g.flow(move, to: notify)
        g.flow(check, "false", to: otherwise)
        g.data(trigger, "path", to: move, "path")
        return (g.workflow("Tidy Downloads"), trigger, move, otherwise)
    }

    func testBranchingDataPassingAndTemplates() async throws {
        let h = try TestHarness()
        h.system.existingPaths["/dl/report.pdf"] = .file
        let (workflow, trigger, move, otherwise) = tidyDownloads()

        let run = await h.engine.run(workflow, trigger: RunTrigger.test,
                                     payload: TriggerManager.filePayload(FileChange(path: "/dl/report.pdf", kind: .created)),
                                     entryNodeID: trigger)

        XCTAssertEqual(run.state, .succeeded, run.error ?? "")
        XCTAssertEqual(h.system.calls, ["mkdir:/docs/PDFs", "move:/dl/report.pdf->/docs/PDFs/report.pdf", "notify:Moved report.pdf to /docs/PDFs"])
        let moveRecord = try XCTUnwrap(run.steps.first { $0.nodeID == move })
        XCTAssertEqual(moveRecord.inputs["path"], "/dl/report.pdf", "Connected from the trigger")
        XCTAssertEqual(moveRecord.output["path"], "/docs/PDFs/report.pdf")
        let skipped = try XCTUnwrap(run.steps.first { $0.nodeID == otherwise })
        XCTAssertEqual(skipped.state, .skipped)
        XCTAssertEqual(skipped.message, "Not on the path this run took.")
        XCTAssertEqual(run.path.count, 3)
    }

    func testFalseBranch() async throws {
        let h = try TestHarness()
        let (workflow, trigger, _, otherwise) = tidyDownloads()

        let run = await h.engine.run(workflow, trigger: RunTrigger.test,
                                     payload: TriggerManager.filePayload(FileChange(path: "/dl/photo.png", kind: .created)),
                                     entryNodeID: trigger)

        XCTAssertEqual(run.state, .succeeded)
        XCTAssertTrue(h.system.calls.isEmpty)
        XCTAssertEqual(run.steps.first { $0.nodeID == otherwise }?.inputs["message"], "Left photo.png alone")
    }

    func testLoopRunsBodyPerItemThenDone() async throws {
        let h = try TestHarness()
        let logs = EventPayloadCollector()
        h.core.events.subscribe(AtlasEvent.Name.log) { logs.append($0) }
        var g = GraphBuilder()
        let loop = g.add(.control(.loop, parameters: ["items": "red, green, blue"], config: NodeConfig(loopMode: .forEach)))
        let body = g.add(.log("{{loop.index}}: {{loop.item}}"))
        let done = g.add(.log("done"))
        g.flow(loop, "body", to: body)
        g.flow(loop, "done", to: done)

        let run = await h.engine.run(g.workflow())

        XCTAssertEqual(run.state, .succeeded)
        XCTAssertEqual(logs.events.map { $0.payload["message"]?.stringValue ?? "" }, ["1: red", "2: green", "3: blue", "done"])
        XCTAssertEqual(run.steps[0].message, "Ran 3 times")
    }

    func testLoopLimitFailsTheRun() async throws {
        let h = try TestHarness()
        var g = GraphBuilder()
        let loop = g.add(.control(.loop, parameters: ["count": 5], config: NodeConfig(loopMode: .repeatCount, maxIterations: 3)))
        let body = g.add(.log("x"))
        let after = g.add(.log("after"))
        g.flow(loop, "body", to: body)
        g.flow(loop, "done", to: after)

        let run = await h.engine.run(g.workflow(policy: .continueOnFailure))

        XCTAssertEqual(run.state, .failed, "A loop over its limit fails the run even when continuing past failures")
        XCTAssertTrue(run.error?.contains("more than its limit of 3") ?? false, run.error ?? "")
        XCTAssertEqual(run.steps[1].state, .skipped)

        var huge = GraphBuilder()
        huge.add(.control(.loop, parameters: ["count": 5_000], config: NodeConfig(loopMode: .repeatCount, maxIterations: 9_999)))
        let hugeRun = await h.engine.run(huge.workflow())
        XCTAssertTrue(hugeRun.error?.contains("limit of 1000") ?? false, "Hard maximum of 1,000")
    }

    func testCancellationMidLoop() async throws {
        let h = try TestHarness()
        var g = GraphBuilder()
        let loop = g.add(.control(.loop, parameters: ["count": 50], config: NodeConfig(loopMode: .repeatCount)))
        let wait = g.add(.delay(0.05))
        g.flow(loop, "body", to: wait)

        let runID = await h.engine.start(g.workflow())
        try await Task.sleep(nanoseconds: 180_000_000)
        await h.engine.cancel(runID: runID)
        let run = try await XCTUnwrapAsync(await h.engine.result(of: runID))

        XCTAssertEqual(run.state, .canceled)
        XCTAssertEqual(run.steps[0].state, .canceled)
        XCTAssertTrue(run.steps[0].message?.contains("of 50") ?? false, run.steps[0].message ?? "")
    }

    func testSwitchMatchesACase() async throws {
        let h = try TestHarness()
        var g = GraphBuilder()
        let trigger = g.add(.trigger(TriggerCatalog.fileCreated, parameters: ["folder": "/dl"]))
        let choose = g.add(.control(.switchValue, parameters: ["value": "{{trigger.extension}}"], config: NodeConfig(cases: ["pdf", "png"])))
        let pdf = g.add(.log("pdf"))
        let png = g.add(.log("png"))
        let other = g.add(.log("other"))
        g.flow(trigger, to: choose)
        g.flow(choose, "case:pdf", to: pdf)
        g.flow(choose, "case:png", to: png)
        g.flow(choose, "default", to: other)

        let run = await h.engine.run(g.workflow(), trigger: RunTrigger.test, payload: ["extension": "PNG"], entryNodeID: trigger)

        XCTAssertEqual(run.steps.first { $0.nodeID == png }?.state, .succeeded)
        XCTAssertEqual(run.steps.first { $0.nodeID == pdf }?.state, .skipped)
        XCTAssertEqual(run.steps.first { $0.nodeID == other }?.state, .skipped)
    }

    func testVariablesAndSavedVariablesPersistBetweenRuns() async throws {
        let h = try TestHarness()
        var g = GraphBuilder()
        let read = g.add(.control(.getVariable, config: NodeConfig(variableName: "last")))
        let set = g.add(.control(.setVariable, parameters: ["value": "{{input.name}}"], config: NodeConfig(variableName: "last")))
        let log = g.add(.log("was {{var.last}}"))
        g.flow(read, to: set)
        g.flow(set, to: log)
        let workflow = try h.core.save(g.workflow(variables: [WorkflowVariable(name: "last", initialValue: "nobody", isSaved: true)]))
        let changes = EventPayloadCollector()
        h.core.events.subscribe(AtlasEvent.Name.variableChanged) { changes.append($0) }

        let first = await h.engine.run(workflow, payload: ["name": "Ada"])
        let second = await h.engine.run(workflow, payload: ["name": "Grace"])

        XCTAssertEqual(first.steps[0].output["value"], "nobody")
        XCTAssertEqual(second.steps[0].output["value"], "Ada", "Saved between runs")
        XCTAssertEqual(second.steps[2].inputs["message"], "was Grace")
        XCTAssertEqual(changes.events.count, 2)
        XCTAssertEqual(try h.store.savedVariableValues(workflowID: workflow.id), ["last": "Grace"])
    }

    func testSubworkflowPassesInputsAndOutputs() async throws {
        let h = try TestHarness()
        var child = GraphBuilder()
        child.add(.control(.setVariable, parameters: ["value": "Hello {{input.who}}"], config: NodeConfig(variableName: "greeting")))
        let childWorkflow = try h.core.save(child.workflow("Greeter"))

        var parent = GraphBuilder()
        let call = parent.add(.control(.subworkflow, parameters: ["who": "Ada"], config: NodeConfig(workflowID: childWorkflow.id), label: "Greet"))
        let log = parent.add(.log("{{node.Greet.greeting}}"))
        parent.flow(call, to: log)

        let run = await h.engine.run(parent.workflow("Parent"))

        XCTAssertEqual(run.state, .succeeded, run.error ?? "")
        XCTAssertEqual(run.steps[1].inputs["message"], "Hello Ada")
        let childRuns = try h.store.runs(workflowID: childWorkflow.id)
        XCTAssertEqual(childRuns.first?.trigger, "subworkflow", "The child's run is in history too")
    }

    func testSubworkflowRecursionIsStopped() async throws {
        let h = try TestHarness()
        let aID = UUID(), bID = UUID()
        try h.core.save(Workflow(id: aID, name: "A", steps: [.control(.subworkflow, config: NodeConfig(workflowID: bID))]))
        try h.core.save(Workflow(id: bID, name: "B", steps: [.control(.subworkflow, config: NodeConfig(workflowID: aID))]))

        let run = await h.engine.run(try XCTUnwrap(try h.store.workflow(id: aID)))

        XCTAssertEqual(run.state, .failed)
        XCTAssertTrue(run.error?.contains("would repeat forever (A → B → A)") ?? false, run.error ?? "")
    }

    func testSubworkflowNestingDepthLimit() async throws {
        let h = try TestHarness()
        let ids = (0...6).map { _ in UUID() }
        for (index, id) in ids.enumerated() {
            let step: WorkflowStep = index == ids.count - 1
                ? .log("bottom")
                : .control(.subworkflow, config: NodeConfig(workflowID: ids[index + 1]))
            try h.core.save(Workflow(id: id, name: "W\(index)", steps: [step]))
        }

        let run = await h.engine.run(try XCTUnwrap(try h.store.workflow(id: ids[0])))

        XCTAssertEqual(run.state, .failed)
        XCTAssertTrue(run.error?.contains("nested more than 5 deep") ?? false, run.error ?? "")
    }

    func testErrorHandlerRoutesFailuresToRecovery() async throws {
        let h = try TestHarness()
        var g = GraphBuilder()
        let handler = g.add(.control(.errorHandler))
        let risky = g.add(.launch("com.example.Missing"))
        let neverRuns = g.add(.log("after risky"))
        let recover = g.add(.log("Recovered from: {{error.message}}"))
        let after = g.add(.log("afterwards"))
        g.flow(handler, "try", to: risky)
        g.flow(risky, to: neverRuns)
        g.flow(handler, "catch", to: recover)
        g.flow(handler, "done", to: after)

        let run = await h.engine.run(g.workflow())

        XCTAssertEqual(run.state, .succeeded, "A handled failure doesn't fail the run")
        XCTAssertEqual(run.steps[1].state, .failed)
        XCTAssertEqual(run.steps[1].message, "Handled by the error handler")
        XCTAssertEqual(run.steps[2].state, .skipped)
        XCTAssertTrue(run.steps[3].inputs["message"]?.stringValue?.hasPrefix("Recovered from: No installed app") ?? false)
        XCTAssertEqual(run.steps[4].state, .succeeded)
    }

    func testParallelOnlyRunsSafeActionsConcurrently() async throws {
        let h = try TestHarness()
        var safe = GraphBuilder()
        let fork = safe.add(.control(.parallel))
        let a = safe.add(.delay(0.2))
        let b = safe.add(.delay(0.2))
        safe.flow(fork, "branches", to: a)
        safe.flow(fork, "branches", to: b)
        let start = Date()
        let run = await h.engine.run(safe.workflow())
        XCTAssertEqual(run.state, .succeeded)
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.35, "Two 0.2 s waits ran at the same time")
        XCTAssertTrue(run.steps[0].message?.contains("at the same time") ?? false)

        var unsafe = GraphBuilder()
        let fork2 = unsafe.add(.control(.parallel))
        let launch = unsafe.add(.launch("com.apple.Notes"))
        let log = unsafe.add(.log("x"))
        unsafe.flow(fork2, "branches", to: launch)
        unsafe.flow(fork2, "branches", to: log)
        let sequential = await h.engine.run(unsafe.workflow())
        XCTAssertEqual(sequential.state, .succeeded)
        XCTAssertTrue(sequential.steps[0].message?.contains("one after another") ?? false, sequential.steps[0].message ?? "")
    }

    func testPerNodeFailurePolicyOverride() async throws {
        let h = try TestHarness()
        var g = GraphBuilder()
        var risky = WorkflowStep.launch("com.example.Missing")
        risky.failurePolicy = .continueOnFailure
        let a = g.add(risky)
        let b = g.add(.log("still runs"))
        g.flow(a, to: b)

        let run = await h.engine.run(g.workflow(policy: .stopOnFailure))

        XCTAssertEqual(run.state, .partiallySucceeded)
        XCTAssertEqual(run.steps[1].state, .succeeded)
    }

    func testAutomaticRunsStopWaitingForConfirmation() async throws {
        let h = try TestHarness()
        h.system.existingPaths["/dl/x.pdf"] = .file
        await h.engine.setConfirmationTimeout(0.2)
        await h.engine.setConfirmationHandler { _ in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            return true
        }
        var g = GraphBuilder()
        let trigger = g.add(.trigger(TriggerCatalog.fileCreated, parameters: ["folder": "/dl"]))
        let trash = g.add(WorkflowStep(actionID: TrashFileAction.id, parameters: ["path": "{{trigger.path}}"]))
        g.flow(trigger, to: trash)

        let start = Date()
        let run = await h.engine.run(g.workflow(), trigger: RunTrigger.automatic(TriggerCatalog.fileCreated),
                                     payload: ["path": "/dl/x.pdf"], entryNodeID: trigger)

        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
        XCTAssertEqual(run.state, .failed)
        XCTAssertTrue(run.steps[1].error?.contains("No one approved") ?? false, run.steps[1].error ?? "")
        XCTAssertFalse(h.system.calls.contains { $0.hasPrefix("trash:") })
    }

    func testFileActions() async throws {
        let h = try TestHarness()
        h.system.existingPaths["/a/report.pdf"] = .file
        h.system.existingPaths["/b"] = .directory
        h.system.existingPaths["/b/report.pdf"] = .file

        let copy = await h.engine.invoke(CopyFileAction.id, parameters: ["path": "/a/report.pdf", "destination": "/b"], source: "test")
        XCTAssertEqual(copy.steps[0].output["path"], "/b/report 2.pdf", "Never overwrites")
        let rename = await h.engine.invoke(RenameFileAction.id, parameters: ["path": "/a/report.pdf", "name": "final.pdf"], source: "test")
        XCTAssertEqual(rename.steps[0].output["path"], "/a/final.pdf")
        let folder = await h.engine.invoke(CreateFolderAction.id, parameters: ["path": "/c/d"], source: "test")
        XCTAssertEqual(folder.state, .succeeded)
        let trash = await h.engine.invoke(TrashFileAction.id, parameters: ["path": "/a/final.pdf"], source: "test")
        XCTAssertEqual(trash.state, .failed, "Trash always asks first")
        for id in [MoveFileAction.id, CopyFileAction.id, RenameFileAction.id, CreateFolderAction.id, TrashFileAction.id] {
            let descriptor = try XCTUnwrap(h.core.registry.descriptor(for: id))
            XCTAssertTrue(descriptor.permissions.contains(.fileAccess), id.rawValue)
            XCTAssertTrue(descriptor.sideEffects.contains(.modifiesFiles), id.rawValue)
        }
    }

    func testTemplates() {
        let scope: [String: ActionValue] = ["trigger.fileName": "a.pdf", "var.count": 3]
        XCTAssertEqual(Templates.resolve("Moved {{trigger.fileName}}", scope: scope).0, "Moved a.pdf")
        XCTAssertEqual(Templates.resolve(.string("{{count}}"), scope: scope).0, .number(3), "A lone placeholder keeps its type")
        let (text, missing) = Templates.resolve("x{{ nope }}y", scope: scope)
        XCTAssertEqual(text, "xy")
        XCTAssertEqual(missing, ["nope"])
    }
}

func XCTUnwrapAsync<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) throws -> T {
    try XCTUnwrap(value, file: file, line: line)
}

// MARK: - Triggers

final class TriggerManagerTests: XCTestCase {

    private func appWorkflow(_ h: TestHarness, app: String = "", settings: WorkflowSettings = .default,
                             body: WorkflowStep = .log("hi {{trigger.appName}}")) throws -> Workflow {
        var g = GraphBuilder()
        let trigger = g.add(.trigger(TriggerCatalog.appLaunched, parameters: app.isEmpty ? [:] : ["app": .string(app)]))
        let action = g.add(body)
        g.flow(trigger, to: action)
        return try h.core.save(g.workflow("On launch", settings: settings))
    }

    func testAppLaunchStartsTheWorkflowWithItsPayload() async throws {
        let h = try TestHarness()
        let env = h.startTriggers()
        let workflow = try appWorkflow(h, app: "org.blenderfoundation.blender")
        _ = await h.waitUntil { env.listenerCount == 1 }
        let fired = EventPayloadCollector()
        h.core.events.subscribe(AtlasEvent.Name.triggerFired) { fired.append($0) }

        env.launch("com.apple.Notes", name: "Notes")
        env.launch("org.blenderfoundation.blender", name: "Blender")

        try await h.expect(h.waitUntil { try h.runs(of: workflow).first?.state == .succeeded })
        let run = try XCTUnwrap(try h.runs(of: workflow).first)
        XCTAssertEqual(try h.runs(of: workflow).count, 1, "Filtered to Blender")
        XCTAssertEqual(run.trigger, "trigger.app.launched")
        XCTAssertEqual(run.triggerPayload["appName"], "Blender")
        XCTAssertEqual(run.steps[1].inputs["message"], "hi Blender")
        XCTAssertEqual(fired.events.first?.payload["payload.bundleId"], "org.blenderfoundation.blender")
    }

    func testRepeatsAreDebouncedAndRecordedAsSkipped() async throws {
        let h = try TestHarness()
        let env = h.startTriggers()
        let workflow = try appWorkflow(h)
        _ = await h.waitUntil { env.listenerCount == 1 }

        env.launch("com.apple.Notes", name: "Notes")
        env.launch("com.apple.Notes", name: "Notes")

        try await h.expect(h.waitUntil { try h.runs(of: workflow).count == 2 })
        let runs = try h.runs(of: workflow)
        XCTAssertEqual(runs.filter { $0.state == .succeeded }.count, 1)
        let skipped = try XCTUnwrap(runs.first { $0.state == .skipped })
        XCTAssertTrue(skipped.error?.contains("fired again within 2 seconds") ?? false, skipped.error ?? "")
        XCTAssertEqual(skipped.trigger, "trigger.app.launched")
    }

    func testRateLimit() async throws {
        let h = try TestHarness()
        let env = h.startTriggers()
        let workflow = try appWorkflow(h, settings: WorkflowSettings(minimumInterval: 0, maxRunsPerMinute: 2, reentrancyRunInParallel: true))
        _ = await h.waitUntil { env.listenerCount == 1 }

        for app in ["a.one", "b.two", "c.three"] { env.launch(app, name: app) }

        try await h.expect(h.waitUntil { try h.runs(of: workflow).count == 3 })
        let skipped = try h.runs(of: workflow).filter { $0.state == .skipped }
        XCTAssertEqual(skipped.count, 1)
        XCTAssertTrue(skipped[0].error?.contains("2 times in the last minute") ?? false)
    }

    func testReentrancyModes() async throws {
        for mode in ReentrancyMode.allCases {
            let h = try TestHarness()
            let env = h.startTriggers()
            let workflow = try appWorkflow(h, settings: WorkflowSettings(reentrancy: mode, minimumInterval: 0), body: .delay(0.3))
            _ = await h.waitUntil { env.listenerCount == 1 }
            let suppressed = EventPayloadCollector()
            h.core.events.subscribe(AtlasEvent.Name.triggerSuppressed) { suppressed.append($0) }

            env.launch("a.one", name: "One")
            _ = await h.waitUntil { await h.engine.isRunning(workflowID: workflow.id) }
            env.launch("b.two", name: "Two")
            try await Task.sleep(nanoseconds: 50_000_000)
            env.launch("c.three", name: "Three")

            // Skips with the same reason within 30 s are one history record
            // (two suppressed events), so a burst can't flood Run History.
            let expected: (succeeded: Int, skipped: Int, suppressed: Int) = switch mode {
            case .ignoreWhileRunning: (1, 1, 2)
            case .queueOne: (2, 1, 1)
            case .runInParallel: (3, 0, 0)
            }
            try await h.expect(h.waitUntil(timeout: 4) {
                let runs = try h.runs(of: workflow)
                return runs.filter { $0.state == .succeeded }.count == expected.succeeded
                    && runs.filter { $0.state == .skipped }.count == expected.skipped
            }, "\(mode): \(try h.runs(of: workflow).map(\.state))")
            XCTAssertEqual(suppressed.events.count, expected.suppressed, "\(mode)")
        }
    }

    func testSelfTriggeringLoopIsStopped() async throws {
        let h = try TestHarness()
        h.system.existingPaths["/in"] = .directory
        h.system.existingPaths["/in/seed.txt"] = .file
        let env = h.startTriggers()
        // Simulate FSEvents: files ATLAS writes into /in appear as new files.
        h.core.events.subscribe(AtlasEvent.Name.actionEffect) { event in
            if let path = event.payload["value"]?.stringValue, path.hasPrefix("/in/"), h.system.fileKind(atPath: path) == .file {
                env.fileCreated(path)
            }
        }
        var g = GraphBuilder()
        let trigger = g.add(.trigger(TriggerCatalog.fileCreated, parameters: ["folder": "/in"]))
        let copy = g.add(WorkflowStep(actionID: CopyFileAction.id, parameters: ["path": "{{trigger.path}}", "destination": "/in"]))
        g.flow(trigger, to: copy)
        let workflow = try h.core.save(g.workflow("Copier", settings: WorkflowSettings(minimumInterval: 0, maxRunsPerMinute: 50)))
        _ = await h.waitUntil { env.listenerCount == 1 }

        env.fileCreated("/in/seed.txt")

        try await h.expect(h.waitUntil(timeout: 5) { try h.runs(of: workflow).contains { $0.state == .failed } })
        let runs = try h.runs(of: workflow)
        let stop = try XCTUnwrap(runs.first { $0.state == .failed })
        XCTAssertTrue(stop.error?.contains("kept setting off its own trigger") ?? false, stop.error ?? "")
        XCTAssertEqual(runs.filter { $0.state == .succeeded }.count, 4, "The outside event plus 3 allowed repeats")
        XCTAssertEqual(env.listenerCount, 0, "Its triggers are turned off")

        // Saving the workflow again turns them back on.
        try h.core.save(workflow)
        try await h.expect(h.waitUntil { env.listenerCount == 1 })
    }

    func testPauseStopsAllTriggers() async throws {
        let h = try TestHarness()
        let env = h.startTriggers()
        let workflow = try appWorkflow(h)
        _ = await h.waitUntil { env.listenerCount == 1 }

        await h.engine.setPaused(true)
        try await h.expect(h.waitUntil { env.listenerCount == 0 })
        env.launch("com.apple.Notes", name: "Notes")
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertTrue(try h.runs(of: workflow).isEmpty, "Nothing fires while paused")

        await h.engine.setPaused(false)
        try await h.expect(h.waitUntil { env.listenerCount == 1 })
    }

    func testListenersFollowEnableEditAndDelete() async throws {
        let h = try TestHarness()
        let env = h.startTriggers()
        var workflow = try appWorkflow(h, app: "a.one")
        try await h.expect(h.waitUntil { env.listenerCount == 1 })

        workflow.isEnabled = false
        workflow = try h.core.save(workflow)
        try await h.expect(h.waitUntil { env.listenerCount == 0 })

        workflow.isEnabled = true
        workflow.steps[0].parameters["app"] = "b.two"
        workflow = try h.core.save(workflow)
        try await h.expect(h.waitUntil { env.listenerCount == 1 })
        env.launch("b.two", name: "Two")
        try await h.expect(h.waitUntil { try h.runs(of: workflow).count == 1 })

        try h.core.delete(workflowID: workflow.id)
        try await h.expect(h.waitUntil { env.listenerCount == 0 })
    }

    func testFileCreatedIgnoresHiddenPartialAndOtherExtensions() async throws {
        let h = try TestHarness()
        h.system.existingPaths["/dl"] = .directory
        for name in [".DS_Store", "big.zip.crdownload", "photo.png", "report.pdf"] { h.system.existingPaths["/dl/\(name)"] = .file }
        let env = h.startTriggers()
        var g = GraphBuilder()
        let trigger = g.add(.trigger(TriggerCatalog.fileCreated, parameters: ["folder": "/dl", "extensions": "pdf"]))
        let log = g.add(.log("{{trigger.fileName}}"))
        g.flow(trigger, to: log)
        let workflow = try h.core.save(g.workflow())
        _ = await h.waitUntil { env.listenerCount == 1 }

        for name in [".DS_Store", "big.zip.crdownload", "photo.png", "report.pdf"] { env.fileCreated("/dl/\(name)") }

        try await h.expect(h.waitUntil { try h.runs(of: workflow).count == 1 })
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(try h.runs(of: workflow).map { $0.triggerPayload["fileName"] }, ["report.pdf"])
    }

    func testEventBusTriggersSpaceDisplayAndTimer() async throws {
        let h = try TestHarness()
        let env = h.startTriggers()
        func make(_ type: String, _ parameters: ActionParameters = [:]) throws -> Workflow {
            var g = GraphBuilder()
            let trigger = g.add(.trigger(type, parameters: parameters))
            let log = g.add(.log(type))
            g.flow(trigger, to: log)
            return try h.core.save(g.workflow(type))
        }
        let space = try make(TriggerCatalog.spaceActivated, ["space": "Coding Lab"])
        let display = try make(TriggerCatalog.displayChanged)
        let timer = try make(TriggerCatalog.timerCompleted, ["name": "Break"])
        _ = await h.waitUntil { h.core.triggers?.activeTriggerCount == 3 }
        _ = env

        h.core.events.publish(AtlasEvent("space.activated", payload: ["spaceId": "1", "spaceName": "Study Library"]))
        h.core.events.publish(AtlasEvent("space.activated", payload: ["spaceId": "2", "spaceName": "coding lab"]))
        h.core.events.publish(AtlasEvent(AtlasEvent.Name.displayChanged, payload: ["displayCount": 2, "profileId": "A+B"]))
        _ = await h.engine.invoke(StartTimerAction.id, parameters: ["name": "Break", "seconds": 1], source: "test")

        try await h.expect(h.waitUntil { try h.runs(of: space).count == 1 && h.runs(of: display).count == 1 })
        XCTAssertEqual(try h.runs(of: space).first?.triggerPayload["spaceName"], "coding lab")
        XCTAssertEqual(try h.runs(of: display).first?.triggerPayload["displayCount"], 2)
        try await h.expect(h.waitUntil(timeout: 3) { try h.runs(of: timer).count == 1 })
    }

    func testTimeReachedRunsOrSkipsWhenMissed() async throws {
        let h = try TestHarness()
        let env = h.startTriggers()
        let calendar = Calendar.current
        env.setNow(calendar.date(from: DateComponents(year: 2026, month: 10, day: 26, hour: 8, minute: 0))!)
        func make(_ ifMissed: String) throws -> Workflow {
            var g = GraphBuilder()
            let trigger = g.add(.trigger(TriggerCatalog.timeReached, parameters: ["repeat": "daily", "time": "09:00", "ifMissed": .string(ifMissed)]))
            let log = g.add(.log("morning"))
            g.flow(trigger, to: log)
            return try h.core.save(g.workflow(ifMissed))
        }
        let runOnWake = try make("runOnWake")
        let skip = try make("skip")
        try await h.expect(h.waitUntil { env.scheduledDates.count == 2 })
        XCTAssertEqual(calendar.component(.hour, from: env.scheduledDates[0]), 9)

        // The Mac slept through 09:00 and woke at 09:30.
        env.advance(by: 90 * 60)
        env.fireDueSchedules()

        try await h.expect(h.waitUntil { try h.runs(of: runOnWake).count == 1 && h.runs(of: skip).count == 1 })
        XCTAssertEqual(try h.runs(of: runOnWake).first?.state, .succeeded)
        let skipped = try XCTUnwrap(try h.runs(of: skip).first)
        XCTAssertEqual(skipped.state, .skipped)
        XCTAssertTrue(skipped.error?.contains("asleep") ?? false)
        try await h.expect(h.waitUntil { env.scheduledDates.count == 2 }, "Tomorrow is scheduled")
    }

    func testBatteryLowFiresOnceEachTimeItCrosses() async throws {
        let h = try TestHarness()
        let env = h.startTriggers()
        var g = GraphBuilder()
        let trigger = g.add(.trigger(TriggerCatalog.batteryLow, parameters: ["percent": 20]))
        let log = g.add(.log("low"))
        g.flow(trigger, to: log)
        let workflow = try h.core.save(g.workflow(settings: WorkflowSettings(minimumInterval: 0)))
        _ = await h.waitUntil { env.listenerCount == 1 }

        for level in [15, 25, 19, 10, 30, 18] {
            env.power(PowerStatus(batteryPercent: level, isOnAdapter: false, isCharging: false))
            try await Task.sleep(nanoseconds: 30_000_000)
        }

        try await h.expect(h.waitUntil { try h.runs(of: workflow).count == 2 })
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(try h.runs(of: workflow).map { $0.triggerPayload["batteryPercent"] }, [19, 18],
                       "15 was the starting reading; 10 didn't cross again")
    }

    func testShortcutProblemsAreReported() async throws {
        let h = try TestHarness()
        let env = h.startTriggers()
        env.takenShortcuts = ["⌘K"]
        var g = GraphBuilder()
        let trigger = g.add(.trigger(TriggerCatalog.hotKey, parameters: ["shortcut": "cmd+k"]))
        let log = g.add(.log("pressed"))
        g.flow(trigger, to: log)
        _ = try h.core.save(g.workflow())

        try await h.expect(h.waitUntil { h.core.triggers?.problem(for: trigger) != nil })
        XCTAssertTrue(h.core.triggers?.problem(for: trigger)?.contains("already used") ?? false)
        XCTAssertEqual(HotKey.parse("ctrl+option+F5").map(\.display), .success("⌃⌥F5"))
    }
}

private extension WorkflowSettings {
    init(minimumInterval: Double, maxRunsPerMinute: Int, reentrancyRunInParallel: Bool) {
        self.init(reentrancy: reentrancyRunInParallel ? .runInParallel : .ignoreWhileRunning,
                  minimumInterval: minimumInterval, maxRunsPerMinute: maxRunsPerMinute)
    }
}
