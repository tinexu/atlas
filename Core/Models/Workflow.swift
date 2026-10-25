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

/// A node in a workflow graph (Stage 04). The name is kept from Stage 01,
/// when workflows were ordered lists of steps; the table was always called
/// `workflow_node` so the data carries over.
///
/// Action nodes run `actionID`. Trigger, condition and control nodes keep
/// what they need in `config`; values they read at run time (which can be
/// typed in or connected from upstream) are in `parameters`.
public struct WorkflowStep: Identifiable, Hashable, Codable, Sendable {
    public var id: UUID
    public var kind: NodeKind
    /// For action nodes. Other kinds use a placeholder.
    public var actionID: ActionID
    public var parameters: ActionParameters
    public var config: NodeConfig
    public var position: NodePosition
    /// The node's typed ports, refreshed whenever the workflow is saved.
    public var ports: [NodePort]
    public var isEnabled: Bool
    /// Optional user-facing label. Falls back to the action title.
    public var label: String?
    /// Overrides the action's default timeout, in seconds.
    public var timeout: TimeInterval?
    /// Extra attempts after a failure. Only honoured for idempotent actions.
    public var maxRetries: Int
    /// Overrides the workflow's failure policy for this node.
    public var failurePolicy: FailurePolicy?

    public init(
        id: UUID = UUID(),
        kind: NodeKind = .action,
        actionID: ActionID,
        parameters: ActionParameters = [:],
        config: NodeConfig = NodeConfig(),
        position: NodePosition = NodePosition(),
        ports: [NodePort] = [],
        isEnabled: Bool = true,
        label: String? = nil,
        timeout: TimeInterval? = nil,
        maxRetries: Int = 0,
        failurePolicy: FailurePolicy? = nil
    ) {
        self.id = id
        self.kind = kind
        self.actionID = actionID
        self.parameters = parameters
        self.config = config
        self.position = position
        self.ports = ports
        self.isEnabled = isEnabled
        self.label = label
        self.timeout = timeout
        self.maxRetries = maxRetries
        self.failurePolicy = failurePolicy
    }

    /// Placeholder action ID for nodes that aren't actions.
    public static func placeholderActionID(for kind: NodeKind, config: NodeConfig) -> ActionID {
        switch kind {
        case .trigger: return ActionID("trigger.\(config.triggerType ?? "unknown")")
        case .condition: return "flow.condition"
        case .control: return ActionID("flow.\(config.control?.rawValue ?? "unknown")")
        case .action: return "flow.action"
        }
    }

    public static func trigger(_ type: String, parameters: ActionParameters = [:], id: UUID = UUID(), at position: NodePosition = NodePosition()) -> WorkflowStep {
        let config = NodeConfig(triggerType: type)
        return WorkflowStep(id: id, kind: .trigger, actionID: placeholderActionID(for: .trigger, config: config),
                            parameters: parameters, config: config, position: position)
    }

    public static func condition(_ group: ConditionGroup, id: UUID = UUID(), label: String? = nil, at position: NodePosition = NodePosition()) -> WorkflowStep {
        let config = NodeConfig(condition: group)
        return WorkflowStep(id: id, kind: .condition, actionID: placeholderActionID(for: .condition, config: config),
                            config: config, position: position, label: label)
    }

    public static func control(_ type: ControlType, parameters: ActionParameters = [:], config: NodeConfig = NodeConfig(),
                               id: UUID = UUID(), label: String? = nil, at position: NodePosition = NodePosition()) -> WorkflowStep {
        var config = config
        config.control = type
        return WorkflowStep(id: id, kind: .control, actionID: placeholderActionID(for: .control, config: config),
                            parameters: parameters, config: config, position: position, label: label)
    }
}

/// A saved automation: a graph of nodes joined by connections.
public struct Workflow: Identifiable, Hashable, Codable, Sendable {
    public var id: UUID
    public var name: String
    public var summary: String
    /// For workflows with triggers: whether they start on their own. A
    /// workflow with validation errors can be saved but not enabled.
    public var isEnabled: Bool
    public var failurePolicy: FailurePolicy
    /// The graph's nodes. Without connections they run top to bottom.
    public var steps: [WorkflowStep]
    public var connections: [WorkflowConnection]
    public var variables: [WorkflowVariable]
    public var settings: WorkflowSettings
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        name: String,
        summary: String = "",
        isEnabled: Bool = true,
        failurePolicy: FailurePolicy = .stopOnFailure,
        steps: [WorkflowStep] = [],
        connections: [WorkflowConnection] = [],
        variables: [WorkflowVariable] = [],
        settings: WorkflowSettings = .default,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.summary = summary
        self.isEnabled = isEnabled
        self.failurePolicy = failurePolicy
        self.steps = steps
        self.connections = connections
        self.variables = variables
        self.settings = settings
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
    /// The values the node ran with, after connections and templates.
    public var inputs: ActionParameters
    public var kind: NodeKind

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
        output: ActionParameters = [:],
        inputs: ActionParameters = [:],
        kind: NodeKind = .action
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
        self.inputs = inputs
        self.kind = kind
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
    /// What started the run: "manual", "menu-bar", "shortcut", "space.activated",
    /// or "trigger.<type>" for automatic runs, e.g. "trigger.file.created".
    public var trigger: String
    public var state: RunState
    public var startedAt: Date
    public var finishedAt: Date?
    public var error: String?
    public var steps: [StepRecord]
    /// What the trigger reported, e.g. the created file's path.
    public var triggerPayload: ActionParameters
    /// Connections the run followed, in order (repeats for loops).
    public var path: [UUID]

    public init(
        id: UUID = UUID(),
        workflowID: UUID,
        workflowName: String,
        trigger: String,
        state: RunState = .pending,
        startedAt: Date = Date(),
        finishedAt: Date? = nil,
        error: String? = nil,
        steps: [StepRecord] = [],
        triggerPayload: ActionParameters = [:],
        path: [UUID] = []
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
        self.triggerPayload = triggerPayload
        self.path = path
    }

    /// Started by a trigger rather than a person or a Space.
    public var isAutomatic: Bool { trigger.hasPrefix(RunTrigger.automaticPrefix) }

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

/// Run trigger names with special meaning.
public enum RunTrigger {
    public static let manual = "manual"
    /// "Run now" from the editor, with a sample trigger payload.
    public static let test = "test"
    public static let subworkflow = "subworkflow"
    /// Prefix of runs started by a trigger node.
    public static let automaticPrefix = "trigger."

    public static func automatic(_ triggerType: String) -> String { automaticPrefix + triggerType }

    /// Runs a person started explicitly; they run even if the workflow is off.
    public static func isExplicit(_ trigger: String) -> Bool {
        trigger == manual || trigger == test
    }
}
