import Foundation

/// What a node in a workflow graph is (Stage 04).
public enum NodeKind: String, Codable, CaseIterable, Sendable {
    /// Starts automatic runs when something happens on the Mac.
    case trigger
    /// Checks something and continues on its "true" or "false" output.
    case condition
    /// Runs one registered action.
    case action
    /// Delay, switch, loop, subworkflow, variables, error handler, parallel.
    case control
}

/// The control nodes. Branching (if/else) is a condition node.
public enum ControlType: String, Codable, CaseIterable, Sendable {
    case delay
    case switchValue
    case loop
    case subworkflow
    case setVariable
    case getVariable
    case errorHandler
    case parallel

    public var title: String {
        switch self {
        case .delay: return "Delay"
        case .switchValue: return "Switch"
        case .loop: return "Loop"
        case .subworkflow: return "Subworkflow"
        case .setVariable: return "Set Variable"
        case .getVariable: return "Get Variable"
        case .errorHandler: return "Error Handler"
        case .parallel: return "Parallel"
        }
    }

    public var symbolName: String {
        switch self {
        case .delay: return "hourglass"
        case .switchValue: return "arrow.triangle.branch"
        case .loop: return "repeat"
        case .subworkflow: return "square.stack.3d.down.right"
        case .setVariable: return "character.textbox"
        case .getVariable: return "text.magnifyingglass"
        case .errorHandler: return "cross.case"
        case .parallel: return "arrow.triangle.swap"
        }
    }
}

/// The type of value a port carries. `control` ports set the order nodes
/// run in; every other type passes a value.
public enum PortType: String, Codable, CaseIterable, Sendable {
    case control, string, number, bool, filePath, bundleId, url, any

    public var title: String {
        switch self {
        case .control: return "Flow"
        case .string: return "Text"
        case .number: return "Number"
        case .bool: return "On/Off"
        case .filePath: return "File path"
        case .bundleId: return "App"
        case .url: return "Link"
        case .any: return "Any value"
        }
    }

    public init(_ kind: ParameterSpec.Kind) {
        switch kind {
        case .text: self = .string
        case .bundleIdentifier: self = .bundleId
        case .url: self = .url
        case .filePath, .folderPath: self = .filePath
        case .number: self = .number
        case .boolean: self = .bool
        }
    }

    /// Nil if a value of type `self` may flow into an input of type
    /// `input`, otherwise why not.
    public func incompatibility(with input: PortType) -> String? {
        if self == input { return nil }
        if self == .control || input == .control {
            return "Flow connections only join flow ports (the arrows), not values."
        }
        if self == .any || input == .any { return nil }
        switch (self, input) {
        // Anything can be shown as text.
        case (_, .string): return nil
        // Text may hold a path, app or link; checked when the node runs.
        case (.string, .filePath), (.string, .bundleId), (.string, .url): return nil
        default: return "A \(title.lowercased()) can't go into a \(input.title.lowercased()) input."
        }
    }
}

public enum PortDirection: String, Codable, Sendable {
    case input, output
}

/// One connection point on a node.
public struct NodePort: Codable, Hashable, Sendable, Identifiable {
    /// Unique within its node and direction, e.g. "in", "true", "path".
    public var id: String
    public var name: String
    public var direction: PortDirection
    public var type: PortType
    /// For data inputs: the node can't run unless it's connected or filled in.
    public var isRequired: Bool

    public init(id: String, name: String, direction: PortDirection, type: PortType, isRequired: Bool = false) {
        self.id = id
        self.name = name
        self.direction = direction
        self.type = type
        self.isRequired = isRequired
    }

    public static let controlIn = "in"
    public static let controlOut = "out"

    public var isControl: Bool { type == .control }
}

/// Where a node sits in the editor. `z` is used by the 3D Automation Galaxy.
public struct NodePosition: Codable, Hashable, Sendable {
    public var x: Double
    public var y: Double
    public var z: Double

    public init(x: Double = 0, y: Double = 0, z: Double = 0) {
        self.x = x
        self.y = y
        self.z = z
    }
}

/// Settings that only some node kinds use. Values a node reads at run time
/// (and that can be connected from upstream) live in its `parameters`.
public struct NodeConfig: Codable, Hashable, Sendable {
    /// Trigger nodes: the trigger type, e.g. "file.created".
    public var triggerType: String?
    /// Condition nodes.
    public var condition: ConditionGroup?
    /// Control nodes.
    public var control: ControlType?
    /// Delay: wait until this time of day ("HH:mm") instead of a duration.
    public var delayUntil: String?
    /// Switch: the values to match, one output each.
    public var cases: [String]?
    /// Loop.
    public var loopMode: LoopMode?
    public var maxIterations: Int?
    /// Subworkflow.
    public var workflowID: UUID?
    /// Set/Get Variable.
    public var variableName: String?
    /// Free-form notes shown in the inspector.
    public var notes: String?

    public init(
        triggerType: String? = nil,
        condition: ConditionGroup? = nil,
        control: ControlType? = nil,
        delayUntil: String? = nil,
        cases: [String]? = nil,
        loopMode: LoopMode? = nil,
        maxIterations: Int? = nil,
        workflowID: UUID? = nil,
        variableName: String? = nil,
        notes: String? = nil
    ) {
        self.triggerType = triggerType
        self.condition = condition
        self.control = control
        self.delayUntil = delayUntil
        self.cases = cases
        self.loopMode = loopMode
        self.maxIterations = maxIterations
        self.workflowID = workflowID
        self.variableName = variableName
        self.notes = notes
    }
}

public enum LoopMode: String, Codable, CaseIterable, Sendable {
    /// Once per item of the "items" input (one per line, or comma-separated).
    case forEach
    /// "count" times.
    case repeatCount

    public var title: String { self == .forEach ? "For each item" : "Repeat N times" }
}

/// Joins an output port of one node to an input port of another. A
/// connection into the "in" port is a control connection and sets the
/// order; any other is a data connection and passes a value.
public struct WorkflowConnection: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var fromNode: UUID
    public var fromPort: String
    public var toNode: UUID
    public var toPort: String

    public init(id: UUID = UUID(), fromNode: UUID, fromPort: String = NodePort.controlOut, toNode: UUID, toPort: String = NodePort.controlIn) {
        self.id = id
        self.fromNode = fromNode
        self.fromPort = fromPort
        self.toNode = toNode
        self.toPort = toPort
    }

    public var isControl: Bool { toPort == NodePort.controlIn }
}

/// A named value a run can set and read. Saved variables keep their value
/// between runs of the workflow; others start from `initialValue` each run.
public struct WorkflowVariable: Codable, Hashable, Sendable, Identifiable {
    public var id: String { name }
    public var name: String
    public var initialValue: ActionValue
    public var isSaved: Bool

    public init(name: String, initialValue: ActionValue = .null, isSaved: Bool = false) {
        self.name = name
        self.initialValue = initialValue
        self.isSaved = isSaved
    }
}

/// What happens when a trigger fires while the workflow is still running.
public enum ReentrancyMode: String, Codable, CaseIterable, Sendable {
    case ignoreWhileRunning
    case queueOne
    case runInParallel

    public var title: String {
        switch self {
        case .ignoreWhileRunning: return "Ignore while running"
        case .queueOne: return "Queue one more run"
        case .runInParallel: return "Run in parallel"
        }
    }
}

/// A named, collapsible box around some nodes in the editor.
public struct NodeGroup: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public var nodeIDs: [UUID]
    public var isCollapsed: Bool

    public init(id: UUID = UUID(), name: String, nodeIDs: [UUID], isCollapsed: Bool = false) {
        self.id = id
        self.name = name
        self.nodeIDs = nodeIDs
        self.isCollapsed = isCollapsed
    }
}

/// Per-workflow trigger behaviour and editor state.
public struct WorkflowSettings: Codable, Hashable, Sendable {
    public var reentrancy: ReentrancyMode
    /// A trigger can't start the workflow again within this many seconds.
    public var minimumInterval: Double
    /// …nor more than this many times in a minute.
    public var maxRunsPerMinute: Int
    /// Runs this workflow may trigger of itself in a row before ATLAS stops it.
    public var selfTriggerLimit: Int
    public var groups: [NodeGroup]

    public init(
        reentrancy: ReentrancyMode = .ignoreWhileRunning,
        minimumInterval: Double = 2,
        maxRunsPerMinute: Int = 10,
        selfTriggerLimit: Int = 3,
        groups: [NodeGroup] = []
    ) {
        self.reentrancy = reentrancy
        self.minimumInterval = minimumInterval
        self.maxRunsPerMinute = maxRunsPerMinute
        self.selfTriggerLimit = selfTriggerLimit
        self.groups = groups
    }

    public static let `default` = WorkflowSettings()

    // Tolerate settings saved by older builds with fewer keys.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        reentrancy = try c.decodeIfPresent(ReentrancyMode.self, forKey: .reentrancy) ?? .ignoreWhileRunning
        minimumInterval = try c.decodeIfPresent(Double.self, forKey: .minimumInterval) ?? 2
        maxRunsPerMinute = try c.decodeIfPresent(Int.self, forKey: .maxRunsPerMinute) ?? 10
        selfTriggerLimit = try c.decodeIfPresent(Int.self, forKey: .selfTriggerLimit) ?? 3
        groups = try c.decodeIfPresent([NodeGroup].self, forKey: .groups) ?? []
    }
}

// MARK: - Graph helpers

extension Workflow {
    /// The connections the engine follows. A workflow saved without any
    /// (built in code, or a plain step list) runs its steps top to bottom.
    public var effectiveConnections: [WorkflowConnection] {
        if !connections.isEmpty || steps.count < 2 { return connections }
        return Self.chain(steps)
    }

    static func chain(_ steps: [WorkflowStep]) -> [WorkflowConnection] {
        zip(steps, steps.dropFirst()).map { WorkflowConnection(fromNode: $0.id, toNode: $1.id) }
    }

    public var triggerNodes: [WorkflowStep] { steps.filter { $0.kind == .trigger } }
    public var hasTriggers: Bool { steps.contains { $0.kind == .trigger } }

    /// A plain list of actions run top to bottom: what the Stage 01 step
    /// editor can show and edit.
    public var isLinear: Bool {
        guard steps.allSatisfy({ $0.kind == .action }) else { return false }
        let control = connections.filter(\.isControl)
        if control.isEmpty { return true }
        let expected = Self.chain(steps)
        guard control.count == expected.count else { return false }
        return zip(control.sorted(by: order), expected).allSatisfy { $0.fromNode == $1.fromNode && $0.toNode == $1.toNode }
    }

    private func order(_ a: WorkflowConnection, _ b: WorkflowConnection) -> Bool {
        let ia = steps.firstIndex { $0.id == a.fromNode } ?? 0
        let ib = steps.firstIndex { $0.id == b.fromNode } ?? 0
        return ia < ib
    }

    /// Rebuilds the control chain from step order, keeping data connections.
    /// Used when a plain list is edited in the step editor.
    public mutating func rechainLinearSteps() {
        let data = connections.filter { !$0.isControl && stepIDs.contains($0.fromNode) && stepIDs.contains($0.toNode) }
        connections = Self.chain(steps) + data
        for (index, _) in steps.enumerated() where steps[index].position == NodePosition() && index > 0 {
            steps[index].position = NodePosition(x: Double(index) * 280, y: 0)
        }
    }

    /// Adds a step after the workflow's last step that has nothing after
    /// it, connecting the two. Used to append a Space's window layout.
    public mutating func appendStep(_ step: WorkflowStep) {
        connections = effectiveConnections
        let hasNext = Set(connections.filter(\.isControl).map(\.fromNode))
        var step = step
        if let last = steps.last(where: { !hasNext.contains($0.id) && $0.kind == .action })
            ?? steps.last(where: { !hasNext.contains($0.id) }) {
            step.position = NodePosition(x: last.position.x + 280, y: last.position.y)
            connections.append(WorkflowConnection(fromNode: last.id, toNode: step.id))
        }
        steps.append(step)
    }

    /// A copy with fresh IDs for the workflow, its nodes and connections,
    /// so it can be saved and edited independently.
    public func duplicate(named name: String) -> Workflow {
        var copy = self
        copy.id = UUID()
        copy.name = name
        copy.createdAt = Date()
        copy.updatedAt = Date()
        copy.steps = steps.map { step in
            var step = step
            step.id = UUID()
            return step
        }
        let map = Dictionary(zip(steps.map(\.id), copy.steps.map(\.id)), uniquingKeysWith: { first, _ in first })
        copy.connections = connections.compactMap { connection in
            guard let from = map[connection.fromNode], let to = map[connection.toNode] else { return nil }
            return WorkflowConnection(fromNode: from, fromPort: connection.fromPort, toNode: to, toPort: connection.toPort)
        }
        copy.settings.groups = settings.groups.map { group in
            NodeGroup(name: group.name, nodeIDs: group.nodeIDs.compactMap { map[$0] }, isCollapsed: group.isCollapsed)
        }
        return copy
    }

    var stepIDs: Set<UUID> { Set(steps.map(\.id)) }

    public func step(id: UUID) -> WorkflowStep? { steps.first { $0.id == id } }
}
