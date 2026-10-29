import Foundation

/// Shown to the user before a step marked `confirmationRequired` runs.
public struct ConfirmationRequest: Sendable, Identifiable {
    public let id = UUID()
    public let workflowName: String
    public let stepLabel: String
    public let descriptor: ActionDescriptor
    public let parameters: ActionParameters
    /// What started the run. Automatic runs ask with a notification.
    public let trigger: String
    public var isAutomatic: Bool { trigger.hasPrefix(RunTrigger.automaticPrefix) }
}

public typealias ConfirmationHandler = @Sendable (ConfirmationRequest) async -> Bool

extension AtlasEvent.Name {
    /// Payload: runId, workflowId, nodeId, kind, stepLabel, stepState.
    public static let nodeStarted = "node.started"
    public static let nodeFinished = "node.finished"
    /// Payload: workflowId, runId, name, value, saved.
    public static let variableChanged = "variable.changed"
}

/// Runs workflows (spec 5.7), now as graphs (Stage 04).
///
/// A run starts at the trigger that fired (or the workflow's start node),
/// follows control connections, and fills each node's inputs from upstream
/// outputs, variables and `{{templates}}`. Every run produces a persisted
/// `WorkflowRun` with each node's state, inputs, outputs, attempts and
/// errors, plus the trigger and its payload. The engine:
/// - validates parameters and checks permissions before each action,
/// - asks for confirmation where an action requires it (automatic runs
///   wait a limited time, then decline),
/// - enforces per-node timeouts and loop limits,
/// - retries only actions declared idempotent, with a hard cap,
/// - supports cancelling a run mid-way, including mid-loop,
/// - and never depends on any UI being open.
///
/// A workflow without connections (a plain step list) runs top to bottom,
/// exactly as in Stage 01.
public actor AutomationEngine {
    public static let maxRetries = 5
    public static let maxSubworkflowDepth = 5

    private let registry: ActionRegistry
    private let permissions: PermissionManager
    private let system: SystemAdapter
    private let events: EventBus
    private let store: AtlasStore?
    private let windows: WindowAdapter?
    private let files: FileServices

    private var confirmationHandler: ConfirmationHandler?
    private var activeRuns: [UUID: Task<WorkflowRun, Never>] = [:]
    private var activeWorkflowIDs: [UUID: UUID] = [:]   // runID → workflowID
    /// Runs whose steps the person already approved in a review screen
    /// (runID → where), so they aren't asked again step by step.
    private var preapproved: [UUID: String] = [:]
    public private(set) var isPaused = false

    /// Base delay between retry attempts; tests shorten it.
    private var retryBackoff: TimeInterval = 0.5
    /// How long an automatic run waits for someone to approve a step.
    public private(set) var confirmationTimeout: TimeInterval = 120

    func setRetryBackoff(_ seconds: TimeInterval) {
        retryBackoff = seconds
    }

    public func setConfirmationTimeout(_ seconds: TimeInterval) {
        confirmationTimeout = seconds
    }

    public init(
        registry: ActionRegistry,
        permissions: PermissionManager,
        system: SystemAdapter,
        events: EventBus,
        store: AtlasStore?,
        windows: WindowAdapter? = nil,
        files: FileServices = .none
    ) {
        self.registry = registry
        self.permissions = permissions
        self.system = system
        self.events = events
        self.store = store
        self.windows = windows
        self.files = files
    }

    // MARK: - Control

    public func setConfirmationHandler(_ handler: ConfirmationHandler?) {
        confirmationHandler = handler
    }

    /// While paused, new runs are recorded as skipped. Runs already in
    /// progress continue; cancel them explicitly if needed.
    public func setPaused(_ paused: Bool) {
        guard paused != isPaused else { return }
        isPaused = paused
        events.publish(AtlasEvent(paused ? AtlasEvent.Name.automationPaused : AtlasEvent.Name.automationResumed))
    }

    public var runningRunIDs: [UUID] { Array(activeRuns.keys) }

    public func isRunning(workflowID: UUID) -> Bool {
        activeWorkflowIDs.values.contains(workflowID)
    }

    public func cancel(runID: UUID) {
        activeRuns[runID]?.cancel()
    }

    public func cancelAll() {
        activeRuns.values.forEach { $0.cancel() }
    }

    // MARK: - Running

    /// Starts a run in the background and returns its identifier at once.
    ///
    /// - Parameters:
    ///   - payload: what the trigger reported, available as `{{trigger.<key>}}`.
    ///   - entryNodeID: the trigger node to start from; nil starts at the
    ///     workflow's start node.
    ///   - approvedIn: set only after the person explicitly confirmed these
    ///     exact steps in a preview (e.g. Cleanup Review), so steps that
    ///     need confirmation don't ask again one by one. Never set for
    ///     automatic runs.
    @discardableResult
    public func start(
        _ workflow: Workflow,
        trigger: String = RunTrigger.manual,
        payload: ActionParameters = [:],
        entryNodeID: UUID? = nil,
        approvedIn: String? = nil
    ) -> UUID {
        let runID = UUID()
        activeWorkflowIDs[runID] = workflow.id
        if let approvedIn, !trigger.hasPrefix(RunTrigger.automaticPrefix) { preapproved[runID] = approvedIn }
        activeRuns[runID] = Task {
            await self.execute(workflow, runID: runID, trigger: trigger, payload: payload, entryNodeID: entryNodeID)
        }
        return runID
    }

    /// Runs a workflow and waits for the finished record.
    public func run(
        _ workflow: Workflow,
        trigger: String = RunTrigger.manual,
        payload: ActionParameters = [:],
        entryNodeID: UUID? = nil,
        approvedIn: String? = nil
    ) async -> WorkflowRun {
        let runID = start(workflow, trigger: trigger, payload: payload, entryNodeID: entryNodeID, approvedIn: approvedIn)
        guard let task = activeRuns[runID] else {
            // Unreachable: start() stores the task synchronously.
            return WorkflowRun(workflowID: workflow.id, workflowName: workflow.name, trigger: trigger, state: .failed)
        }
        return await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    /// Waits for a run begun with `start(_:trigger:)` and returns its
    /// finished record. Lets a caller learn the run ID straight away (to show
    /// progress) and still collect the outcome later.
    public func result(of runID: UUID) async -> WorkflowRun? {
        if let task = activeRuns[runID] {
            return await task.value
        }
        // Already finished: history has it.
        return try? store?.run(id: runID)
    }

    /// Invokes a single registered action through the full engine path.
    /// This is how a 3D room object, a keyboard shortcut or a Companion
    /// command runs an action, so all of them get the same validation,
    /// permission checks and history.
    public func invoke(
        _ actionID: ActionID,
        parameters: ActionParameters = [:],
        source: String,
        approvedIn: String? = nil
    ) async -> WorkflowRun {
        let title = registry.descriptor(for: actionID)?.title ?? actionID.rawValue
        let workflow = Workflow(
            name: title,
            summary: "Single action invoked from \(source)",
            steps: [WorkflowStep(actionID: actionID, parameters: parameters)]
        )
        return await run(workflow, trigger: source, approvedIn: approvedIn)
    }

    /// Runs the steps that failed in `runID` again, as a new run of the
    /// same workflow (as it is now), with the inputs they had then. Steps
    /// that worked aren't repeated: their results carry over, so the steps
    /// after a failed one (skipped because of it) run too. File steps are
    /// safe to repeat: they check the file is still there first.
    ///
    /// Returns nil when there's nothing to retry.
    public func retryFailedSteps(of runID: UUID) async -> WorkflowRun? {
        guard let old = try? store?.run(id: runID), let workflow = try? store?.workflow(id: old.workflowID) else { return nil }
        let failed = old.steps.filter { $0.state == .failed && workflow.step(id: $0.nodeID) != nil }
        guard !failed.isEmpty else { return nil }
        let newID = UUID()
        activeWorkflowIDs[newID] = workflow.id
        let task = Task { () -> WorkflowRun in
            defer {
                activeRuns[newID] = nil
                activeWorkflowIDs[newID] = nil
            }
            return await executeRetry(workflow, of: old, failed: failed.map(\.nodeID), runID: newID)
        }
        activeRuns[newID] = task
        return await task.value
    }

    private func executeRetry(_ workflow: Workflow, of old: WorkflowRun, failed: [UUID], runID: UUID) async -> WorkflowRun {
        let ctx = RunContext(
            workflow: workflow,
            run: WorkflowRun(
                id: runID, workflowID: workflow.id, workflowName: workflow.name, trigger: RunTrigger.retry, state: .running,
                startedAt: Date(),
                steps: workflow.steps.enumerated().map { position, step in
                    StepRecord(position: position, nodeID: step.id, actionID: step.actionID, label: label(for: step), kind: step.kind)
                },
                triggerPayload: old.triggerPayload
            ),
            callStack: [workflow.id]
        )
        if isPaused { return finish(ctx, state: .skipped, error: "Automations are paused.") }

        // What worked last time carries over, outputs and all.
        for record in old.steps where record.state == .succeeded || record.state == .partiallySucceeded {
            guard let index = ctx.index[record.nodeID] else { continue }
            ctx.run.steps[index].state = record.state
            ctx.run.steps[index].message = "Done in the earlier run"
            ctx.run.steps[index].inputs = record.inputs
            ctx.run.steps[index].output = record.output
            ctx.run.steps[index].startedAt = record.startedAt
            ctx.run.steps[index].finishedAt = record.finishedAt
            ctx.outputs[record.nodeID] = record.kind == .trigger ? old.triggerPayload : record.output
        }
        for record in old.steps where failed.contains(record.nodeID) {
            ctx.inputOverrides[record.nodeID] = record.inputs
        }
        ctx.variables = initialVariables(for: workflow)
        persist(ctx.run)
        var started = payload(for: ctx.run)
        started["retryOf"] = .string(old.id.uuidString)
        events.publish(AtlasEvent(AtlasEvent.Name.workflowStarted, payload: started))

        for nodeID in failed {
            // An earlier retried step may already have reached this one.
            guard let index = ctx.index[nodeID], ctx.run.steps[index].state == .pending else { continue }
            let result = await runChain(from: nodeID, ctx: ctx, scope: Scope())
            if case .stopped = result { break }
        }
        return conclude(ctx)
    }

    // MARK: - Execution

    private func execute(
        _ workflow: Workflow, runID: UUID, trigger: String, payload: ActionParameters, entryNodeID: UUID?
    ) async -> WorkflowRun {
        defer {
            activeRuns[runID] = nil
            activeWorkflowIDs[runID] = nil
            preapproved[runID] = nil
        }
        return await executeGraph(workflow, runID: runID, trigger: trigger, payload: payload, entryNodeID: entryNodeID,
                                  callStack: [workflow.id]).run
    }

    /// Runs one workflow to the end. Subworkflows call this recursively.
    private func executeGraph(
        _ workflow: Workflow, runID: UUID, trigger: String, payload: ActionParameters, entryNodeID: UUID?, callStack: [UUID]
    ) async -> (run: WorkflowRun, variables: [String: ActionValue]) {
        let ctx = RunContext(
            workflow: workflow,
            run: WorkflowRun(
                id: runID,
                workflowID: workflow.id,
                workflowName: workflow.name,
                trigger: trigger,
                state: .running,
                startedAt: Date(),
                steps: workflow.steps.enumerated().map { position, step in
                    StepRecord(position: position, nodeID: step.id, actionID: step.actionID,
                               label: label(for: step), kind: step.kind)
                },
                triggerPayload: payload
            ),
            callStack: callStack
        )

        if isPaused {
            return (finish(ctx, state: .skipped, error: "Automations are paused."), [:])
        }
        if !workflow.isEnabled && !RunTrigger.isExplicit(trigger) && trigger != RunTrigger.subworkflow {
            return (finish(ctx, state: .skipped, error: "This workflow is turned off."), [:])
        }

        ctx.variables = initialVariables(for: workflow)
        persist(ctx.run)
        var started = self.payload(for: ctx.run)
        if let entryNodeID { started["entryNodeId"] = .string(entryNodeID.uuidString) }
        events.publish(AtlasEvent(AtlasEvent.Name.workflowStarted, payload: started))
        AtlasLog.engine.info("Run \(runID.uuidString, privacy: .public) started: \(workflow.name, privacy: .public)")

        for start in entryNodes(of: workflow, entry: entryNodeID) {
            let result = await runChain(from: start, ctx: ctx, scope: Scope())
            if case .stopped = result { break }
        }

        return (conclude(ctx), ctx.variables)
    }

    /// Marks what didn't run, works out the run's state and finishes it.
    private func conclude(_ ctx: RunContext) -> WorkflowRun {
        // Whatever didn't run.
        let leftover: String
        let leftoverState: RunState
        if ctx.canceled {
            (leftover, leftoverState) = ("Run was canceled.", .canceled)
        } else if let reason = ctx.stopReason {
            (leftover, leftoverState) = (reason, .skipped)
        } else {
            (leftover, leftoverState) = ("Not on the path this run took.", .skipped)
        }
        for i in ctx.run.steps.indices where !ctx.run.steps[i].state.isTerminal {
            ctx.run.steps[i].state = leftoverState
            ctx.run.steps[i].message = ctx.run.steps[i].message ?? leftover
        }

        // Triggers and conditions don't count toward success; actions do.
        let counted = ctx.run.steps.filter { $0.kind != .trigger }
        let ran = counted.filter { $0.state == .succeeded || $0.state == .partiallySucceeded || $0.state == .failed }
        let failures = ran.filter { $0.state == .failed && !ctx.caught.contains($0.nodeID) }
        let partials = ran.filter { $0.state == .partiallySucceeded }
        let state: RunState
        if ctx.canceled {
            state = .canceled
        } else if ran.isEmpty {
            state = ctx.run.steps.contains { $0.kind == .trigger && $0.state == .succeeded } ? .succeeded : .skipped
        } else if failures.isEmpty && partials.isEmpty {
            state = .succeeded
        } else if failures.count < ran.count {
            state = .partiallySucceeded
        } else {
            state = .failed
        }
        let firstError = (failures.first ?? partials.first).map { "\($0.label): \($0.error ?? "failed")" }
        let error = ctx.canceled ? "Run was canceled." : (ctx.fatalError ?? firstError)
        persistSavedVariables(ctx)
        return finish(ctx, state: state, error: error)
    }

    /// Where a run begins: the trigger that fired, or the start node(s).
    private func entryNodes(of workflow: Workflow, entry: UUID?) -> [UUID] {
        if let entry, workflow.step(id: entry) != nil { return [entry] }
        let incoming = Set(workflow.effectiveConnections.filter(\.isControl).map(\.toNode))
        let starts = workflow.steps.filter { $0.kind != .trigger && !incoming.contains($0.id) }.map(\.id)
        if !starts.isEmpty { return starts }
        // Only triggers: a manual or test run starts at the first one.
        return workflow.triggerNodes.prefix(1).map(\.id)
    }

    // MARK: - Graph traversal

    private struct Scope: Sendable {
        /// Inside an error handler's "try" branch: failures propagate to it.
        var inTry = false
        /// loop.item, loop.index, error.message.
        var values: [String: ActionValue] = [:]
    }

    private enum ChainResult: Sendable {
        case completed
        case failed(node: UUID, label: String, error: String)
        case stopped
    }

    /// Runs a node and everything downstream of it, following control
    /// connections in order.
    private func runChain(from nodeID: UUID, ctx: RunContext, scope: Scope) async -> ChainResult {
        guard let node = ctx.workflow.step(id: nodeID), let index = ctx.index[nodeID] else { return .completed }
        if ctx.canceled { return .stopped }
        if Task.isCancelled {
            ctx.canceled = true
            return .stopped
        }
        if ctx.stopReason != nil { return .stopped }

        if !node.isEnabled {
            ctx.run.steps[index].state = .skipped
            ctx.run.steps[index].message = "Step is turned off."
            // A turned-off action is stepped over; anything else ends its branch.
            return node.kind == .action ? await follow(NodePort.controlOut, of: node, ctx: ctx, scope: scope) : .completed
        }

        begin(index, ctx: ctx)
        let result = await runNode(node, ctx: ctx, scope: scope)
        end(index, result, ctx: ctx)

        if result.state == .canceled {
            ctx.canceled = true
            return .stopped
        }
        if let chain = result.chain { return chain }
        if result.state == .failed {
            if scope.inTry && !result.isFatal {
                return .failed(node: node.id, label: ctx.run.steps[index].label, error: result.error ?? "failed")
            }
            if result.isFatal || (node.failurePolicy ?? ctx.workflow.failurePolicy) == .stopOnFailure {
                ctx.stopReason = "Skipped because “\(ctx.run.steps[index].label)” failed."
                if result.isFatal { ctx.fatalError = "\(ctx.run.steps[index].label): \(result.error ?? "failed")" }
                return .stopped
            }
        }
        for port in result.next {
            let outcome = await follow(port, of: node, ctx: ctx, scope: scope)
            if case .completed = outcome { continue }
            return outcome
        }
        return .completed
    }

    /// Runs every branch leaving `port`, one after another.
    private func follow(_ port: String, of node: WorkflowStep, ctx: RunContext, scope: Scope) async -> ChainResult {
        for connection in ctx.outgoing[node.id, default: []] where connection.fromPort == port {
            ctx.run.path.append(connection.id)
            let outcome = await runChain(from: connection.toNode, ctx: ctx, scope: scope)
            if case .completed = outcome { continue }
            return outcome
        }
        return .completed
    }

    private struct NodeResult {
        var state: RunState
        /// Control outputs to follow next.
        var next: [String] = []
        var outputs: ActionParameters = [:]
        var inputs: ActionParameters = [:]
        var message: String?
        var error: String?
        var attempts = 1
        /// Stops the run whatever the failure policy (e.g. a loop limit).
        var isFatal = false
        /// Set by nodes that ran their own branches and already know the outcome.
        var chain: ChainResult?
    }

    private func runNode(_ node: WorkflowStep, ctx: RunContext, scope: Scope) async -> NodeResult {
        let inputs = resolveInputs(of: node, ctx: ctx, scope: scope)
        var result: NodeResult
        switch node.kind {
        case .trigger:
            let type = TriggerCatalog.type(id: node.config.triggerType ?? "")
            ctx.outputs[node.id] = ctx.run.triggerPayload
            let what = ctx.run.isAutomatic ? "Fired" : (ctx.run.trigger == RunTrigger.test ? "Test run" : "Started by hand")
            result = NodeResult(state: .succeeded, next: [NodePort.controlOut], outputs: ctx.run.triggerPayload,
                                message: "\(what): \(type?.title ?? "Trigger")")
        case .condition:
            result = await runCondition(node, ctx: ctx, scope: scope)
        case .action:
            result = await runAction(node, inputs: inputs, ctx: ctx)
        case .control:
            result = await runControl(node, inputs: inputs, ctx: ctx, scope: scope)
        }
        result.inputs = inputs
        if result.state == .succeeded || result.state == .partiallySucceeded {
            var outputs = ctx.outputs[node.id] ?? [:]
            outputs.merge(result.outputs) { _, new in new }
            ctx.outputs[node.id] = outputs
        }
        return result
    }

    // MARK: Inputs

    /// Typed-in parameters, overridden by data connections, with templates filled.
    private func resolveInputs(of node: WorkflowStep, ctx: RunContext, scope: Scope) -> ActionParameters {
        // A retried step gets exactly what it had the first time.
        if let inputs = ctx.inputOverrides.removeValue(forKey: node.id) { return inputs }
        var values = node.parameters
        for connection in ctx.incomingData[node.id, default: []] {
            if let value = ctx.outputs[connection.fromNode]?[connection.fromPort] {
                values[connection.toPort] = value
            }
        }
        let templateScope = self.templateScope(ctx: ctx, scope: scope)
        for (key, value) in values {
            values[key] = Templates.resolve(value, scope: templateScope).0
        }
        return values
    }

    private func templateScope(ctx: RunContext, scope: Scope) -> [String: ActionValue] {
        var values: [String: ActionValue] = [:]
        for (key, value) in ctx.run.triggerPayload {
            values["trigger.\(key)"] = value
            values["input.\(key)"] = value
        }
        for (name, value) in ctx.variables { values["var.\(name)"] = value }
        for (id, outputs) in ctx.outputs {
            guard let node = ctx.workflow.step(id: id) else { continue }
            let names = [node.label?.trimmingCharacters(in: .whitespaces), id.uuidString].compactMap { $0 }.filter { !$0.isEmpty }
            for name in names {
                for (key, value) in outputs { values["node.\(name).\(key)"] = value }
            }
        }
        values.merge(scope.values) { _, new in new }
        return values
    }

    // MARK: Conditions

    private func runCondition(_ node: WorkflowStep, ctx: RunContext, scope: Scope) async -> NodeResult {
        let group = node.config.condition ?? ConditionGroup()
        let templateValues = templateScope(ctx: ctx, scope: scope)
        let windows = self.windows
        let context = ConditionContext(
            system: system,
            displayCount: { await windows?.displays().count ?? 1 },
            activeSpaceID: (try? store?.preference(ConditionCheck.activeSpacePreferenceKey, as: UUID.self)) ?? nil,
            resolve: { Templates.resolve($0, scope: templateValues).0 }
        )
        let (passed, lines) = await ConditionEvaluator.evaluate(group, in: context)
        return NodeResult(
            state: .succeeded,
            next: [passed ? "true" : "false"],
            outputs: ["result": .bool(passed)],
            message: "\(passed ? "True" : "False") · \(lines.joined(separator: "; "))"
        )
    }

    // MARK: Actions

    private func runAction(_ node: WorkflowStep, inputs: ActionParameters, ctx: RunContext) async -> NodeResult {
        let outcome = await perform(node, parameters: inputs, ctx: ctx)
        var result = NodeResult(state: outcome.state, outputs: outcome.output, message: outcome.message,
                                error: outcome.error, attempts: outcome.attempts)
        if outcome.state == .succeeded || outcome.state == .partiallySucceeded {
            if let message = outcome.message { result.outputs["message"] = .string(message) }
            result.next = [NodePort.controlOut]
        } else if outcome.state == .failed {
            // With "continue past failures" the flow goes on as if it had run.
            result.next = [NodePort.controlOut]
        }
        return result
    }

    private struct StepOutcome {
        var state: RunState
        var attempts: Int
        var message: String?
        var error: String?
        var output: ActionParameters = [:]

        static func failed(_ error: Error, attempts: Int = 0) -> StepOutcome {
            StepOutcome(state: .failed, attempts: attempts, message: nil, error: error.localizedDescription)
        }
    }

    private func perform(_ step: WorkflowStep, parameters raw: ActionParameters, ctx: RunContext) async -> StepOutcome {
        guard let action = registry.action(for: step.actionID) else {
            return .failed(ActionError.unknownAction(step.actionID))
        }
        let descriptor = action.descriptor

        let parameters: ActionParameters
        do {
            parameters = try registry.validate(raw, for: descriptor)
            try await permissions.authorize(descriptor)
        } catch {
            return .failed(error)
        }

        if descriptor.confirmationRequired, preapproved[ctx.run.id] == nil {
            let request = ConfirmationRequest(
                workflowName: ctx.workflow.name, stepLabel: label(for: step), descriptor: descriptor,
                parameters: parameters, trigger: ctx.run.trigger
            )
            guard await confirm(request) else {
                if request.isAutomatic {
                    return .failed(ActionError.failed("No one approved this step within \(Int(confirmationTimeout)) seconds, so it didn't run."))
                }
                return .failed(ActionError.confirmationDeclined)
            }
        }

        let timeout = max(0.1, step.timeout ?? descriptor.defaultTimeout)
        let maxAttempts = descriptor.isIdempotent ? 1 + min(max(0, step.maxRetries), Self.maxRetries) : 1
        let context = ActionContext(system: system, events: events, runID: ctx.run.id, files: files)
        // The Orbit folders these paths are in, for security-scoped access.
        let paths = descriptor.permissions.contains(.fileAccess)
            ? descriptor.parameters.filter { $0.kind == .filePath || $0.kind == .folderPath }.compactMap { parameters[$0.key]?.stringValue }
            : []

        var lastError: Error = ActionError.failed("Did not run.")
        for attempt in 1...maxAttempts {
            if Task.isCancelled {
                return StepOutcome(state: .canceled, attempts: attempt - 1, message: "Run was canceled.")
            }
            do {
                let output = try await withTimeout(seconds: timeout) { [files] in
                    try await files.access.withAccess(to: paths) {
                        try await action.perform(parameters, context: context)
                    }
                }
                let approval = descriptor.confirmationRequired ? preapproved[ctx.run.id].map { " (approved in \($0))" } ?? "" : ""
                return StepOutcome(
                    state: output.partialFailure == nil ? .succeeded : .partiallySucceeded,
                    attempts: attempt,
                    message: output.message + approval,
                    error: output.partialFailure,
                    output: output.values
                )
            } catch is CancellationError {
                return StepOutcome(state: .canceled, attempts: attempt, message: "Run was canceled.")
            } catch {
                lastError = error
                AtlasLog.engine.error(
                    "\(descriptor.id.rawValue, privacy: .public) attempt \(attempt) failed: \(error.localizedDescription, privacy: .public)"
                )
            }
            if attempt < maxAttempts {
                let delay = retryBackoff * Double(attempt)
                do {
                    try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                } catch {
                    return StepOutcome(state: .canceled, attempts: attempt, message: "Run was canceled.")
                }
            }
        }
        return .failed(lastError, attempts: maxAttempts)
    }

    /// No handler means nobody can approve: refuse rather than guess.
    /// Automatic runs wait a limited time for an answer.
    private func confirm(_ request: ConfirmationRequest) async -> Bool {
        guard let handler = confirmationHandler else { return false }
        guard request.isAutomatic else { return await handler(request) }
        return (try? await withTimeout(seconds: confirmationTimeout) { await handler(request) }) ?? false
    }

    // MARK: Control nodes

    private func runControl(_ node: WorkflowStep, inputs: ActionParameters, ctx: RunContext, scope: Scope) async -> NodeResult {
        switch node.config.control {
        case .delay:
            return await runDelay(node, inputs: inputs)
        case .switchValue:
            let value = inputs["value"]?.displayString ?? ""
            let match = (node.config.cases ?? []).first { $0.caseInsensitiveCompare(value.trimmingCharacters(in: .whitespaces)) == .orderedSame }
            return NodeResult(state: .succeeded, next: [match.map { "case:\($0)" } ?? "default"], outputs: ["value": .string(value)],
                              message: match.map { "Matched “\($0)”" } ?? "No case matched “\(value)”")
        case .loop:
            return await runLoop(node, inputs: inputs, ctx: ctx, scope: scope)
        case .subworkflow:
            return await runSubworkflow(node, inputs: inputs, ctx: ctx)
        case .setVariable:
            let name = (node.config.variableName ?? "").trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { return NodeResult(state: .failed, error: "No variable name.") }
            let value = inputs["value"] ?? .null
            ctx.variables[name] = value
            let saved = ctx.workflow.variables.first { $0.name == name }?.isSaved ?? false
            events.publish(AtlasEvent(AtlasEvent.Name.variableChanged, payload: [
                "workflowId": .string(ctx.workflow.id.uuidString), "runId": .string(ctx.run.id.uuidString),
                "name": .string(name), "value": .string(value.displayString), "saved": .bool(saved),
            ]))
            return NodeResult(state: .succeeded, next: [NodePort.controlOut], outputs: ["value": value],
                              message: "\(name) = \(value.displayString)\(saved ? " (saved)" : "")")
        case .getVariable:
            let name = (node.config.variableName ?? "").trimmingCharacters(in: .whitespaces)
            let value = ctx.variables[name] ?? .null
            return NodeResult(state: .succeeded, next: [NodePort.controlOut], outputs: ["value": value],
                              message: "\(name) is \(value == .null ? "empty" : value.displayString)")
        case .errorHandler:
            return await runErrorHandler(node, ctx: ctx, scope: scope)
        case .parallel:
            return await runParallel(node, ctx: ctx, scope: scope)
        case nil:
            return NodeResult(state: .failed, error: "This control node has no type.")
        }
    }

    private func runDelay(_ node: WorkflowStep, inputs: ActionParameters) async -> NodeResult {
        var seconds = inputs["seconds"]?.numberValue ?? 0
        if let until = node.config.delayUntil.flatMap(TimeOfDay.init) {
            let next = Calendar.current.nextDate(after: Date(), matching: DateComponents(hour: until.hour, minute: until.minute),
                                                 matchingPolicy: .nextTime)
            seconds = next.map { $0.timeIntervalSinceNow } ?? 0
        }
        seconds = min(max(0, seconds), 86_400)
        do {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        } catch {
            return NodeResult(state: .canceled, message: "Run was canceled.")
        }
        return NodeResult(state: .succeeded, next: [NodePort.controlOut], message: "Waited \(ActionValue.number(seconds.rounded()).displayString)s")
    }

    private func runLoop(_ node: WorkflowStep, inputs: ActionParameters, ctx: RunContext, scope: Scope) async -> NodeResult {
        let limit = min(node.config.maxIterations ?? WorkflowValidator.maxLoopIterations, WorkflowValidator.maxLoopIterations)
        let items: [ActionValue]
        if node.config.loopMode == .repeatCount {
            let count = Int(inputs["count"]?.numberValue ?? 0)
            items = count > 0 ? (1...max(count, 1)).map { .number(Double($0)) } : []
        } else {
            items = Self.listItems(inputs["items"])
        }
        guard items.count <= limit else {
            return NodeResult(state: .failed, error: "This loop would run \(items.count) times, more than its limit of \(limit).",
                              isFatal: true)
        }
        for (index, item) in items.enumerated() {
            if Task.isCancelled || ctx.canceled {
                ctx.canceled = true
                return NodeResult(state: .canceled, message: "Run was canceled during pass \(index + 1) of \(items.count).")
            }
            var inner = scope
            inner.values["loop.item"] = item
            inner.values["loop.index"] = .number(Double(index + 1))
            ctx.outputs[node.id] = ["item": item, "index": .number(Double(index + 1))]
            let outcome = await follow("body", of: node, ctx: ctx, scope: inner)
            switch outcome {
            case .completed: continue
            case .stopped:
                // The step that stopped it is recorded as failed; the loop itself didn't fail.
                let state: RunState = ctx.canceled ? .canceled : .skipped
                return NodeResult(state: state, message: "Stopped during pass \(index + 1) of \(items.count).", chain: .stopped)
            case .failed:
                return NodeResult(state: .failed, error: "A step failed during pass \(index + 1).", chain: outcome)
            }
        }
        return NodeResult(state: .succeeded, next: ["done"], outputs: ["count": .number(Double(items.count))],
                          message: "Ran \(items.count) time\(items.count == 1 ? "" : "s")")
    }

    /// One per line if there are line breaks, otherwise comma-separated.
    static func listItems(_ value: ActionValue?) -> [ActionValue] {
        guard let value, !value.isEmpty else { return [] }
        let text = value.displayString
        let parts = text.contains("\n") ? text.split(separator: "\n") : text.split(separator: ",")
        return parts.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.map { .string($0) }
    }

    private func runSubworkflow(_ node: WorkflowStep, inputs: ActionParameters, ctx: RunContext) async -> NodeResult {
        guard let id = node.config.workflowID, let child = try? store?.workflow(id: id) else {
            return NodeResult(state: .failed, error: "The automation it calls was deleted.")
        }
        if ctx.callStack.contains(id) {
            let names = (ctx.callStack + [id]).compactMap { (try? store?.workflow(id: $0))??.name }
            return NodeResult(state: .failed, error: "Stopped: calling “\(child.name)” here would repeat forever (\(names.joined(separator: " → "))).",
                              isFatal: true)
        }
        guard ctx.callStack.count <= Self.maxSubworkflowDepth else {
            return NodeResult(state: .failed, error: "Stopped: subworkflows are nested more than \(Self.maxSubworkflowDepth) deep.",
                              isFatal: true)
        }
        let (childRun, variables) = await executeGraph(child, runID: UUID(), trigger: RunTrigger.subworkflow, payload: inputs,
                                                       entryNodeID: nil, callStack: ctx.callStack + [id])
        var outputs = variables
        outputs["state"] = .string(childRun.state.rawValue)
        outputs["runId"] = .string(childRun.id.uuidString)
        switch childRun.state {
        case .succeeded:
            return NodeResult(state: .succeeded, next: [NodePort.controlOut], outputs: outputs, message: "“\(child.name)” finished")
        case .partiallySucceeded:
            return NodeResult(state: .partiallySucceeded, next: [NodePort.controlOut], outputs: outputs,
                              message: "“\(child.name)” partly finished", error: childRun.error)
        case .canceled:
            return NodeResult(state: .canceled, message: "Run was canceled.")
        default:
            return NodeResult(state: .failed, next: [NodePort.controlOut], outputs: outputs,
                              error: "“\(child.name)” \(childRun.state.title.lowercased()): \(childRun.error ?? "")")
        }
    }

    private func runErrorHandler(_ node: WorkflowStep, ctx: RunContext, scope: Scope) async -> NodeResult {
        var inner = scope
        inner.inTry = true
        let attempt = await follow("try", of: node, ctx: ctx, scope: inner)
        switch attempt {
        case .stopped:
            return NodeResult(state: ctx.canceled ? .canceled : .succeeded, message: "Stopped", chain: .stopped)
        case .completed:
            return NodeResult(state: .succeeded, next: ["done"], message: "Nothing failed")
        case .failed(let failedNode, let label, let error):
            ctx.caught.insert(failedNode)
            if let index = ctx.index[failedNode] {
                ctx.run.steps[index].message = "Handled by the error handler"
            }
            let caught: ActionParameters = ["error": .string(error), "failedNode": .string(label)]
            ctx.outputs[node.id] = caught
            var recovery = scope
            recovery.values["error.message"] = .string(error)
            recovery.values["error.node"] = .string(label)
            let recovered = await follow("catch", of: node, ctx: ctx, scope: recovery)
            if case .completed = recovered {
                return NodeResult(state: .succeeded, next: ["done"], outputs: caught, message: "Caught a failure in \(label)")
            }
            return NodeResult(state: .succeeded, outputs: caught, message: "Caught a failure in \(label)", chain: recovered)
        }
    }

    private func runParallel(_ node: WorkflowStep, ctx: RunContext, scope: Scope) async -> NodeResult {
        let branches = ctx.outgoing[node.id, default: []].filter { $0.fromPort == "branches" }
        let unsafe = branches.flatMap { unsafeNodes(from: $0.toNode, ctx: ctx) }
        var results: [ChainResult] = []
        if unsafe.isEmpty && branches.count > 1 {
            for branch in branches { ctx.run.path.append(branch.id) }
            results = await withTaskGroup(of: ChainResult.self) { group in
                for branch in branches {
                    group.addTask { await self.runChain(from: branch.toNode, ctx: ctx, scope: scope) }
                }
                var collected: [ChainResult] = []
                for await result in group { collected.append(result) }
                return collected
            }
        } else {
            for branch in branches {
                ctx.run.path.append(branch.id)
                results.append(await runChain(from: branch.toNode, ctx: ctx, scope: scope))
            }
        }
        let message = unsafe.isEmpty
            ? "Ran \(branches.count) branch\(branches.count == 1 ? "" : "es") at the same time"
            : "Ran branches one after another because \(Set(unsafe).sorted().joined(separator: ", ")) isn't safe to run at the same time"
        if let failure = results.first(where: { if case .failed = $0 { return true } else { return false } }) {
            return NodeResult(state: .succeeded, message: message, chain: failure)
        }
        if results.contains(where: { if case .stopped = $0 { return true } else { return false } }) {
            return NodeResult(state: .succeeded, message: message, chain: .stopped)
        }
        return NodeResult(state: .succeeded, next: ["done"], message: message)
    }

    /// Names of nodes in a branch that mustn't run concurrently.
    private func unsafeNodes(from start: UUID, ctx: RunContext) -> [String] {
        var seen = Set<UUID>()
        var queue = [start]
        var unsafe: [String] = []
        while let id = queue.popLast() {
            guard seen.insert(id).inserted, let node = ctx.workflow.step(id: id) else { continue }
            switch node.kind {
            case .action:
                if registry.descriptor(for: node.actionID)?.isConcurrencySafe != true { unsafe.append(label(for: node)) }
            case .control:
                if ![.delay, .getVariable].contains(node.config.control) { unsafe.append(label(for: node)) }
            case .condition, .trigger:
                break
            }
            queue.append(contentsOf: ctx.outgoing[id, default: []].map(\.toNode))
        }
        return unsafe
    }

    // MARK: - Records

    private func begin(_ index: Int, ctx: RunContext) {
        ctx.run.steps[index].state = .running
        ctx.run.steps[index].startedAt = Date()
        ctx.run.steps[index].message = nil
        ctx.run.steps[index].error = nil
        persist(ctx.run)
        let payload = self.payload(for: ctx.run, step: index)
        events.publish(AtlasEvent(AtlasEvent.Name.stepStarted, payload: payload))
        events.publish(AtlasEvent(AtlasEvent.Name.nodeStarted, payload: payload))
    }

    private func end(_ index: Int, _ result: NodeResult, ctx: RunContext) {
        ctx.run.steps[index].state = result.state
        ctx.run.steps[index].attempts = result.attempts
        ctx.run.steps[index].finishedAt = Date()
        ctx.run.steps[index].message = result.message
        ctx.run.steps[index].error = result.error
        ctx.run.steps[index].output = result.outputs
        ctx.run.steps[index].inputs = result.inputs
        persist(ctx.run)
        let payload = self.payload(for: ctx.run, step: index)
        events.publish(AtlasEvent(AtlasEvent.Name.stepFinished, payload: payload))
        events.publish(AtlasEvent(AtlasEvent.Name.nodeFinished, payload: payload))
    }

    private func label(for step: WorkflowStep) -> String {
        switch step.kind {
        case .action:
            return registry.displayLabel(for: step)
        default:
            return WorkflowValidator.displayName(step, registry: registry).trimmingCharacters(in: CharacterSet(charactersIn: "“”"))
        }
    }

    private func initialVariables(for workflow: Workflow) -> [String: ActionValue] {
        var values: [String: ActionValue] = [:]
        let saved = (try? store?.savedVariableValues(workflowID: workflow.id)) ?? [:]
        for variable in workflow.variables {
            values[variable.name] = variable.isSaved ? (saved[variable.name] ?? variable.initialValue) : variable.initialValue
        }
        return values
    }

    private func persistSavedVariables(_ ctx: RunContext) {
        for variable in ctx.workflow.variables where variable.isSaved {
            guard let value = ctx.variables[variable.name] else { continue }
            do {
                try store?.setSavedVariableValue(value, name: variable.name, workflowID: ctx.workflow.id)
            } catch {
                AtlasLog.persistence.error("Couldn't save variable: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func finish(_ ctx: RunContext, state: RunState, error: String?) -> WorkflowRun {
        ctx.run.state = state
        ctx.run.error = error
        ctx.run.finishedAt = Date()
        if state == .skipped {
            for i in ctx.run.steps.indices where ctx.run.steps[i].state == .pending {
                ctx.run.steps[i].state = .skipped
            }
        }
        persist(ctx.run)
        events.publish(AtlasEvent(AtlasEvent.Name.workflowFinished, payload: payload(for: ctx.run)))
        let runID = ctx.run.id.uuidString
        AtlasLog.engine.info("Run \(runID, privacy: .public) finished: \(state.rawValue, privacy: .public)")
        return ctx.run
    }

    private func persist(_ run: WorkflowRun) {
        do {
            try store?.saveRun(run)
        } catch {
            // History is important but must never break a running workflow.
            AtlasLog.persistence.error("Couldn't save run: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func payload(for run: WorkflowRun, step index: Int? = nil) -> ActionParameters {
        var payload: ActionParameters = [
            "runId": .string(run.id.uuidString),
            "workflowId": .string(run.workflowID.uuidString),
            "workflowName": .string(run.workflowName),
            "state": .string(run.state.rawValue),
            "trigger": .string(run.trigger),
        ]
        if let index, run.steps.indices.contains(index) {
            let step = run.steps[index]
            payload["stepIndex"] = .number(Double(index))
            payload["stepLabel"] = .string(step.label)
            payload["stepState"] = .string(step.state.rawValue)
            payload["nodeId"] = .string(step.nodeID.uuidString)
            payload["kind"] = .string(step.kind.rawValue)
            if let message = step.message { payload["message"] = .string(message) }
            if let error = step.error { payload["error"] = .string(error) }
        }
        return payload
    }
}

/// Mutable state of one run. Only touched from the engine actor; parallel
/// branches interleave at suspension points, never at the same time.
private final class RunContext: @unchecked Sendable {
    let workflow: Workflow
    var run: WorkflowRun
    let callStack: [UUID]
    let index: [UUID: Int]
    /// Control connections by source node, in connection order.
    let outgoing: [UUID: [WorkflowConnection]]
    let incomingData: [UUID: [WorkflowConnection]]
    var outputs: [UUID: ActionParameters] = [:]
    var variables: [String: ActionValue] = [:]
    var stopReason: String?
    var fatalError: String?
    var canceled = false
    /// Failed nodes an error handler dealt with.
    var caught = Set<UUID>()
    /// Inputs for steps being retried, from the earlier run.
    var inputOverrides: [UUID: ActionParameters] = [:]

    init(workflow: Workflow, run: WorkflowRun, callStack: [UUID]) {
        self.workflow = workflow
        self.run = run
        self.callStack = callStack
        self.index = Dictionary(workflow.steps.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { a, _ in a })
        let connections = workflow.effectiveConnections
        self.outgoing = Dictionary(grouping: connections.filter(\.isControl), by: \.fromNode)
        self.incomingData = Dictionary(grouping: connections.filter { !$0.isControl }, by: \.toNode)
    }
}

extension ConditionCheck {
    /// Where Spaces records the active Space.
    public static let activeSpacePreferenceKey = "spaces.activeSpaceID"
}
