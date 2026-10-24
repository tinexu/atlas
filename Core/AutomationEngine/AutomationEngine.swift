import Foundation

/// Shown to the user before a step marked `confirmationRequired` runs.
public struct ConfirmationRequest: Sendable, Identifiable {
    public let id = UUID()
    public let workflowName: String
    public let stepLabel: String
    public let descriptor: ActionDescriptor
    public let parameters: ActionParameters
}

public typealias ConfirmationHandler = @Sendable (ConfirmationRequest) async -> Bool

/// Runs workflows (spec 5.7).
///
/// Every invocation produces a persisted `WorkflowRun` that records what
/// was attempted and what actually happened, step by step. The engine:
/// - validates parameters and checks permissions before each step,
/// - asks for confirmation where an action requires it (and refuses if no
///   one is there to ask),
/// - enforces per-step timeouts,
/// - retries only actions declared idempotent, with a hard cap,
/// - supports cancelling a run mid-way,
/// - and never depends on any UI being open.
public actor AutomationEngine {
    public static let maxRetries = 5

    private let registry: ActionRegistry
    private let permissions: PermissionManager
    private let system: SystemAdapter
    private let events: EventBus
    private let store: AtlasStore?

    private var confirmationHandler: ConfirmationHandler?
    private var activeRuns: [UUID: Task<WorkflowRun, Never>] = [:]
    private var activeWorkflowIDs: [UUID: UUID] = [:]   // runID → workflowID
    public private(set) var isPaused = false

    /// Base delay between retry attempts; tests shorten it.
    private var retryBackoff: TimeInterval = 0.5

    func setRetryBackoff(_ seconds: TimeInterval) {
        retryBackoff = seconds
    }

    public init(
        registry: ActionRegistry,
        permissions: PermissionManager,
        system: SystemAdapter,
        events: EventBus,
        store: AtlasStore?
    ) {
        self.registry = registry
        self.permissions = permissions
        self.system = system
        self.events = events
        self.store = store
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
    @discardableResult
    public func start(_ workflow: Workflow, trigger: String = "manual") -> UUID {
        let runID = UUID()
        activeWorkflowIDs[runID] = workflow.id
        activeRuns[runID] = Task { await self.execute(workflow, runID: runID, trigger: trigger) }
        return runID
    }

    /// Runs a workflow and waits for the finished record.
    public func run(_ workflow: Workflow, trigger: String = "manual") async -> WorkflowRun {
        let runID = start(workflow, trigger: trigger)
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
        source: String
    ) async -> WorkflowRun {
        let title = registry.descriptor(for: actionID)?.title ?? actionID.rawValue
        let workflow = Workflow(
            name: title,
            summary: "Single action invoked from \(source)",
            steps: [WorkflowStep(actionID: actionID, parameters: parameters)]
        )
        return await run(workflow, trigger: source)
    }

    // MARK: - Execution

    private func execute(_ workflow: Workflow, runID: UUID, trigger: String) async -> WorkflowRun {
        defer {
            activeRuns[runID] = nil
            activeWorkflowIDs[runID] = nil
        }

        var run = WorkflowRun(
            id: runID,
            workflowID: workflow.id,
            workflowName: workflow.name,
            trigger: trigger,
            state: .running,
            startedAt: Date(),
            steps: workflow.steps.enumerated().map { position, step in
                StepRecord(
                    position: position,
                    nodeID: step.id,
                    actionID: step.actionID,
                    label: registry.displayLabel(for: step)
                )
            }
        )

        if isPaused {
            return finish(&run, state: .skipped, error: "Automations are paused.")
        }
        if !workflow.isEnabled && trigger != "manual" {
            return finish(&run, state: .skipped, error: "This workflow is turned off.")
        }

        persist(run)
        events.publish(AtlasEvent(AtlasEvent.Name.workflowStarted, payload: payload(for: run)))
        AtlasLog.engine.info("Run \(runID.uuidString, privacy: .public) started: \(workflow.name, privacy: .public)")

        var stopReason: String?
        var wasCanceled = false

        for index in workflow.steps.indices {
            let step = workflow.steps[index]

            if Task.isCancelled {
                wasCanceled = true
                markRemaining(&run, from: index, as: .canceled, message: "Run was canceled.")
                break
            }
            if let stopReason {
                run.steps[index].state = .skipped
                run.steps[index].message = stopReason
                continue
            }
            if !step.isEnabled {
                run.steps[index].state = .skipped
                run.steps[index].message = "Step is turned off."
                continue
            }

            run.steps[index].state = .running
            run.steps[index].startedAt = Date()
            persist(run)
            events.publish(AtlasEvent(AtlasEvent.Name.stepStarted, payload: payload(for: run, step: index)))

            let outcome = await perform(step, workflowName: workflow.name, label: run.steps[index].label, runID: runID)

            run.steps[index].state = outcome.state
            run.steps[index].attempts = outcome.attempts
            run.steps[index].finishedAt = Date()
            run.steps[index].message = outcome.message
            run.steps[index].error = outcome.error
            run.steps[index].output = outcome.output
            persist(run)
            events.publish(AtlasEvent(AtlasEvent.Name.stepFinished, payload: payload(for: run, step: index)))

            if outcome.state == .canceled {
                wasCanceled = true
                markRemaining(&run, from: index + 1, as: .canceled, message: "Run was canceled.")
                break
            }
            if outcome.state == .failed, workflow.failurePolicy == .stopOnFailure {
                stopReason = "Skipped because “\(run.steps[index].label)” failed."
            }
        }

        let ran = run.steps.filter { $0.state == .succeeded || $0.state == .failed }
        let failures = ran.filter { $0.state == .failed }
        let state: RunState
        if wasCanceled {
            state = .canceled
        } else if ran.isEmpty {
            state = .skipped
        } else if failures.isEmpty {
            state = .succeeded
        } else if failures.count < ran.count {
            state = .partiallySucceeded
        } else {
            state = .failed
        }
        let firstError = failures.first.map { "\($0.label): \($0.error ?? "failed")" }
        return finish(&run, state: state, error: wasCanceled ? "Run was canceled." : firstError)
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

    private func perform(_ step: WorkflowStep, workflowName: String, label: String, runID: UUID) async -> StepOutcome {
        guard let action = registry.action(for: step.actionID) else {
            return .failed(ActionError.unknownAction(step.actionID))
        }
        let descriptor = action.descriptor

        let parameters: ActionParameters
        do {
            parameters = try registry.validate(step.parameters, for: descriptor)
            try await permissions.authorize(descriptor)
        } catch {
            return .failed(error)
        }

        if descriptor.confirmationRequired {
            // No handler means nobody can approve: refuse rather than guess.
            let approved: Bool
            if let handler = confirmationHandler {
                approved = await handler(ConfirmationRequest(
                    workflowName: workflowName, stepLabel: label, descriptor: descriptor, parameters: parameters
                ))
            } else {
                approved = false
            }
            guard approved else { return .failed(ActionError.confirmationDeclined) }
        }

        let timeout = max(0.1, step.timeout ?? descriptor.defaultTimeout)
        let maxAttempts = descriptor.isIdempotent ? 1 + min(max(0, step.maxRetries), Self.maxRetries) : 1
        let context = ActionContext(system: system, events: events, runID: runID)

        var lastError: Error = ActionError.failed("Did not run.")
        for attempt in 1...maxAttempts {
            if Task.isCancelled {
                return StepOutcome(state: .canceled, attempts: attempt - 1, message: "Run was canceled.")
            }
            do {
                let output = try await withTimeout(seconds: timeout) {
                    try await action.perform(parameters, context: context)
                }
                return StepOutcome(state: .succeeded, attempts: attempt, message: output.message, output: output.values)
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

    // MARK: - Helpers

    private func markRemaining(_ run: inout WorkflowRun, from index: Int, as state: RunState, message: String) {
        guard index < run.steps.count else { return }
        for i in index..<run.steps.count where !run.steps[i].state.isTerminal {
            run.steps[i].state = state
            run.steps[i].message = message
        }
    }

    private func finish(_ run: inout WorkflowRun, state: RunState, error: String?) -> WorkflowRun {
        run.state = state
        run.error = error
        run.finishedAt = Date()
        if state == .skipped {
            for i in run.steps.indices where run.steps[i].state == .pending {
                run.steps[i].state = .skipped
            }
        }
        persist(run)
        events.publish(AtlasEvent(AtlasEvent.Name.workflowFinished, payload: payload(for: run)))
        let runID = run.id.uuidString
        AtlasLog.engine.info("Run \(runID, privacy: .public) finished: \(state.rawValue, privacy: .public)")
        return run
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
            if let message = step.message { payload["message"] = .string(message) }
            if let error = step.error { payload["error"] = .string(error) }
        }
        return payload
    }
}
