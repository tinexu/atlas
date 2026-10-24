import Foundation

/// What a workflow does when one of its steps fails.
public enum FailurePolicy: String, Codable, CaseIterable, Sendable {
    /// Skip all remaining steps once a step fails (the safe default).
    case stopOnFailure
    /// Keep going; the run ends as `partiallySucceeded` if anything worked.
    case continueOnFailure

    public var title: String {
        switch self {
        case .stopOnFailure: return "Stop at the first failure"
        case .continueOnFailure: return "Continue past failures"
        }
    }
}

/// One invocation of a registered action inside a workflow.
///
/// In Stage 01 workflows are ordered lists of steps. Stage 04 (Flow) turns
/// steps into graph nodes; the persisted table is already named
/// `workflow_node` so the data carries over.
public struct WorkflowStep: Identifiable, Hashable, Codable, Sendable {
    public var id: UUID
    public var actionID: ActionID
    public var parameters: ActionParameters
    public var isEnabled: Bool
    /// Optional user-facing label. Falls back to the action title.
    public var label: String?
    /// Overrides the action's default timeout, in seconds.
    public var timeout: TimeInterval?
    /// Extra attempts after a failure. Only honoured for idempotent actions.
    public var maxRetries: Int

    public init(
        id: UUID = UUID(),
        actionID: ActionID,
        parameters: ActionParameters = [:],
        isEnabled: Bool = true,
        label: String? = nil,
        timeout: TimeInterval? = nil,
        maxRetries: Int = 0
    ) {
        self.id = id
        self.actionID = actionID
        self.parameters = parameters
        self.isEnabled = isEnabled
        self.label = label
        self.timeout = timeout
        self.maxRetries = maxRetries
    }
}

/// A saved automation configuration.
public struct Workflow: Identifiable, Hashable, Codable, Sendable {
    public var id: UUID
    public var name: String
    public var summary: String
    public var isEnabled: Bool
    public var failurePolicy: FailurePolicy
    public var steps: [WorkflowStep]
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        name: String,
        summary: String = "",
        isEnabled: Bool = true,
        failurePolicy: FailurePolicy = .stopOnFailure,
        steps: [WorkflowStep] = [],
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.summary = summary
        self.isEnabled = isEnabled
        self.failurePolicy = failurePolicy
        self.steps = steps
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

/// Execution states, per spec section 5.7, plus `partiallySucceeded` so the
/// UI never reports a half-finished setup as a success (spec 7.4).
public enum RunState: String, Codable, CaseIterable, Sendable {
    case pending
    case running
    case succeeded
    case partiallySucceeded
    case failed
    case skipped
    case canceled

    public var isTerminal: Bool {
        switch self {
        case .pending, .running: return false
        default: return true
        }
    }

    public var title: String {
        switch self {
        case .pending: return "Pending"
        case .running: return "Running"
        case .succeeded: return "Succeeded"
        case .partiallySucceeded: return "Partially succeeded"
        case .failed: return "Failed"
        case .skipped: return "Skipped"
        case .canceled: return "Canceled"
        }
    }
}

/// The recorded outcome of a single step within a run.
public struct StepRecord: Identifiable, Hashable, Sendable {
    public var id: Int { position }
    public var position: Int
    public var nodeID: UUID
    public var actionID: ActionID
    public var label: String
    public var state: RunState
    public var attempts: Int
    public var startedAt: Date?
    public var finishedAt: Date?
    public var message: String?
    public var error: String?
    public var output: ActionParameters

    public init(
        position: Int,
        nodeID: UUID,
        actionID: ActionID,
        label: String,
        state: RunState = .pending,
        attempts: Int = 0,
        startedAt: Date? = nil,
        finishedAt: Date? = nil,
        message: String? = nil,
        error: String? = nil,
        output: ActionParameters = [:]
    ) {
        self.position = position
        self.nodeID = nodeID
        self.actionID = actionID
        self.label = label
        self.state = state
        self.attempts = attempts
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.message = message
        self.error = error
        self.output = output
    }

    public var duration: TimeInterval? {
        guard let startedAt, let finishedAt else { return nil }
        return finishedAt.timeIntervalSince(startedAt)
    }
}

/// An execution record: one invocation of a workflow.
public struct WorkflowRun: Identifiable, Hashable, Sendable {
    public var id: UUID
    public var workflowID: UUID
    public var workflowName: String
    /// What started the run: "manual", "menu-bar", "shortcut", "space.activated", …
    public var trigger: String
    public var state: RunState
    public var startedAt: Date
    public var finishedAt: Date?
    public var error: String?
    public var steps: [StepRecord]

    public init(
        id: UUID = UUID(),
        workflowID: UUID,
        workflowName: String,
        trigger: String,
        state: RunState = .pending,
        startedAt: Date = Date(),
        finishedAt: Date? = nil,
        error: String? = nil,
        steps: [StepRecord] = []
    ) {
        self.id = id
        self.workflowID = workflowID
        self.workflowName = workflowName
        self.trigger = trigger
        self.state = state
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.error = error
        self.steps = steps
    }

    public var duration: TimeInterval? {
        finishedAt.map { $0.timeIntervalSince(startedAt) }
    }

    public var summaryLine: String {
        let done = steps.filter { $0.state == .succeeded }.count
        let partial = steps.filter { $0.state == .partiallySucceeded }.count
        let failed = steps.filter { $0.state == .failed }.count
        var parts = ["\(done)/\(steps.count) steps succeeded"]
        if partial > 0 { parts.append("\(partial) partly done") }
        if failed > 0 { parts.append("\(failed) failed") }
        return parts.joined(separator: " · ")
    }
}
