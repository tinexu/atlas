import Foundation

/// A problem in a workflow graph, attached to a node or connection where
/// possible so the editor can outline it.
public struct ValidationIssue: Hashable, Sendable, Identifiable {
    public enum Severity: String, Sendable {
        /// The workflow can be saved as a draft but not enabled.
        case error
        /// Worth a look; doesn't block anything.
        case warning
    }

    public let id = UUID()
    public let severity: Severity
    public let message: String
    public let nodeID: UUID?
    public let connectionID: UUID?

    public init(_ severity: Severity, _ message: String, node: UUID? = nil, connection: UUID? = nil) {
        self.severity = severity
        self.message = message
        self.nodeID = node
        self.connectionID = connection
    }

    public static func == (a: ValidationIssue, b: ValidationIssue) -> Bool {
        a.severity == b.severity && a.message == b.message && a.nodeID == b.nodeID && a.connectionID == b.connectionID
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(severity)
        hasher.combine(message)
        hasher.combine(nodeID)
        hasher.combine(connectionID)
    }
}

/// Checks a graph before it's saved or enabled: required inputs connected,
/// port types compatible, no cycles (loops repeat with a Loop node),
/// everything reachable from a trigger or the start, at most one start.
public enum WorkflowValidator {
    public static let maxLoopIterations = 1_000

    public static func validate(
        _ workflow: Workflow,
        registry: ActionRegistry,
        workflowExists: (UUID) -> Bool = { _ in true }
    ) -> [ValidationIssue] {
        var issues: [ValidationIssue] = []
        let nodes = Dictionary(workflow.steps.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let ports = nodes.mapValues { NodePorts.ports(for: $0, registry: registry) }
        let connections = workflow.effectiveConnections
        func name(_ id: UUID) -> String { nodes[id].map { displayName($0, registry: registry) } ?? "a deleted step" }

        if workflow.steps.isEmpty {
            issues.append(ValidationIssue(.warning, "This workflow has no steps yet."))
        }

        // Connections: endpoints, directions, types.
        var dataInputs: [String: Int] = [:]
        for connection in connections {
            guard let from = ports[connection.fromNode], let to = ports[connection.toNode] else {
                issues.append(ValidationIssue(.error, "A connection points to a step that no longer exists.", connection: connection.id))
                continue
            }
            guard let out = from.first(where: { $0.id == connection.fromPort && $0.direction == .output }) else {
                issues.append(ValidationIssue(.error, "\(name(connection.fromNode)) has no output “\(connection.fromPort)” any more.",
                                              node: connection.fromNode, connection: connection.id))
                continue
            }
            guard let input = to.first(where: { $0.id == connection.toPort && $0.direction == .input }) else {
                issues.append(ValidationIssue(.error, "\(name(connection.toNode)) has no input “\(connection.toPort)” any more.",
                                              node: connection.toNode, connection: connection.id))
                continue
            }
            if let problem = out.type.incompatibility(with: input.type) {
                issues.append(ValidationIssue(.error, "\(out.name) → \(input.name): \(problem)", node: connection.toNode, connection: connection.id))
            }
            if connection.fromNode == connection.toNode {
                issues.append(ValidationIssue(.error, "\(name(connection.toNode)) is connected to itself.", node: connection.toNode, connection: connection.id))
            }
            if !input.isControl {
                let key = "\(connection.toNode)/\(connection.toPort)"
                dataInputs[key, default: 0] += 1
                if dataInputs[key] == 2 {
                    issues.append(ValidationIssue(.error, "“\(input.name)” on \(name(connection.toNode)) has more than one connection.",
                                                  node: connection.toNode, connection: connection.id))
                }
            }
        }

        // Required inputs: connected, typed in, or defaulted.
        for node in workflow.steps where node.isEnabled {
            for port in ports[node.id] ?? [] where port.direction == .input && port.isRequired && !port.isControl {
                let connected = connections.contains { $0.toNode == node.id && $0.toPort == port.id }
                let filled = node.parameters[port.id].map { !$0.isEmpty } ?? false
                if !connected && !filled {
                    issues.append(ValidationIssue(.error, "\(name(node.id)) needs “\(port.name)”: type it in or connect it.", node: node.id))
                }
            }
            issues.append(contentsOf: nodeIssues(node, registry: registry, workflow: workflow, workflowExists: workflowExists))
        }

        // Cycles.
        if let cycle = findCycle(nodes: workflow.steps.map(\.id), connections: connections) {
            issues.append(ValidationIssue(.error, "Steps are connected in a circle (\(cycle.map(name).joined(separator: " → "))). Use a Loop node to repeat steps.",
                                          node: cycle.first))
        }

        // Starts and reachability.
        let control = connections.filter(\.isControl)
        let hasIncoming = Set(control.map(\.toNode))
        let starts = workflow.steps.filter { $0.kind != .trigger && !hasIncoming.contains($0.id) }
        if starts.count > 1 {
            for start in starts {
                issues.append(ValidationIssue(.error, "\(name(start.id)) isn't connected to anything before it. A workflow can have only one start; connect it after another step or a trigger.",
                                              node: start.id))
            }
        }
        var reachable = Set<UUID>()
        var queue = workflow.triggerNodes.map(\.id) + starts.prefix(1).map(\.id)
        while let id = queue.popLast() {
            guard reachable.insert(id).inserted else { continue }
            queue.append(contentsOf: control.filter { $0.fromNode == id }.map(\.toNode))
        }
        if starts.count <= 1 {
            for node in workflow.steps where !reachable.contains(node.id) {
                issues.append(ValidationIssue(.error, "\(name(node.id)) can't be reached. Connect it after a trigger or the first step.", node: node.id))
            }
        }

        // Data should come from a step that has already run.
        for connection in connections where !connection.isControl {
            guard nodes[connection.fromNode] != nil, nodes[connection.toNode] != nil else { continue }
            if !isUpstream(connection.fromNode, of: connection.toNode, control: control) {
                issues.append(ValidationIssue(.warning, "\(name(connection.toNode)) uses a value from \(name(connection.fromNode)), which doesn't run before it.",
                                              node: connection.toNode, connection: connection.id))
            }
        }

        // Template placeholders pointing at outputs no trigger provides.
        let triggerKeys = Set(workflow.triggerNodes.flatMap { TriggerCatalog.type(id: $0.config.triggerType ?? "")?.outputs.map(\.key) ?? [] })
        if workflow.hasTriggers {
            for node in workflow.steps {
                for value in node.parameters.values {
                    guard case .string(let text) = value else { continue }
                    for placeholder in Templates.placeholders(in: text) where placeholder.name.hasPrefix("trigger.") {
                        let key = String(placeholder.name.dropFirst("trigger.".count))
                        if !triggerKeys.contains(key) {
                            issues.append(ValidationIssue(.warning, "{{\(placeholder.name)}} in \(name(node.id)): no trigger here reports “\(key)”.", node: node.id))
                        }
                    }
                }
            }
        }
        return issues
    }

    public static func hasErrors(_ issues: [ValidationIssue]) -> Bool {
        issues.contains { $0.severity == .error }
    }

    /// The label a person sees for a node.
    public static func displayName(_ node: WorkflowStep, registry: ActionRegistry) -> String {
        if let label = node.label, !label.trimmingCharacters(in: .whitespaces).isEmpty { return "“\(label)”" }
        switch node.kind {
        case .trigger: return "“\(TriggerCatalog.type(id: node.config.triggerType ?? "")?.title ?? "Trigger")”"
        case .condition: return "“Condition”"
        case .control: return "“\(node.config.control?.title ?? "Control")”"
        case .action: return "“\(registry.descriptor(for: node.actionID)?.title ?? node.actionID.rawValue)”"
        }
    }

    // MARK: - Per node

    private static func nodeIssues(_ node: WorkflowStep, registry: ActionRegistry, workflow: Workflow,
                                   workflowExists: (UUID) -> Bool) -> [ValidationIssue] {
        var issues: [ValidationIssue] = []
        let label = displayName(node, registry: registry)
        func error(_ message: String) { issues.append(ValidationIssue(.error, message, node: node.id)) }
        func warning(_ message: String) { issues.append(ValidationIssue(.warning, message, node: node.id)) }

        switch node.kind {
        case .action:
            if registry.descriptor(for: node.actionID) == nil {
                error("“\(node.actionID)” isn't an action this version of ATLAS knows.")
            }
        case .trigger:
            guard let type = TriggerCatalog.type(id: node.config.triggerType ?? "") else {
                error("This trigger type isn't known to this version of ATLAS.")
                break
            }
            for spec in type.parameters where spec.isRequired && spec.defaultValue == nil {
                if node.parameters[spec.key].map({ $0.isEmpty }) ?? true { error("\(label) needs “\(spec.label)”.") }
            }
            if type.id == TriggerCatalog.hotKey, let text = node.parameters["shortcut"]?.stringValue, !text.isEmpty,
               case .failure(let problem) = HotKey.parse(text) {
                error(problem.message)
            }
            if type.id == TriggerCatalog.timeReached {
                if let problem = TimeSchedule(parameters: node.parameters).validationError { error(problem) }
            }
        case .condition:
            let group = node.config.condition ?? ConditionGroup()
            if group.items.isEmpty { warning("\(label) has no checks, so it's always true.") }
            for item in group.items { if let problem = item.check.validationError { error(problem) } }
        case .control:
            switch node.config.control {
            case .delay:
                if let until = node.config.delayUntil, !until.isEmpty {
                    if TimeOfDay(until) == nil { error("Delay until “\(until)”: times look like 17:30.") }
                } else if node.parameters["seconds"].map({ $0.isEmpty }) ?? true,
                          !workflow.connections.contains(where: { $0.toNode == node.id && $0.toPort == "seconds" }) {
                    error("\(label) needs a number of seconds or a time to wait until.")
                }
            case .switchValue:
                if (node.config.cases ?? []).isEmpty { warning("\(label) has no cases, so it always goes to “Otherwise”.") }
            case .loop:
                if let max = node.config.maxIterations, max > maxLoopIterations || max < 1 {
                    error("A loop's limit must be between 1 and \(maxLoopIterations).")
                }
            case .subworkflow:
                if let id = node.config.workflowID {
                    if id == workflow.id { error("\(label) calls this same workflow, which would never end.") }
                    else if !workflowExists(id) { error("\(label) calls an automation that was deleted.") }
                } else {
                    error("\(label) needs an automation to call.")
                }
            case .setVariable, .getVariable:
                if (node.config.variableName ?? "").trimmingCharacters(in: .whitespaces).isEmpty {
                    error("\(label) needs a variable name.")
                }
            case .errorHandler, .parallel:
                break
            case nil:
                error("This control node has no type.")
            }
        }
        return issues
    }

    // MARK: - Graph checks

    /// A cycle in the graph formed by all connections, if any.
    public static func findCycle(nodes: [UUID], connections: [WorkflowConnection]) -> [UUID]? {
        let edges = Dictionary(grouping: connections, by: \.fromNode).mapValues { $0.map(\.toNode) }
        var state: [UUID: Int] = [:] // 1 visiting, 2 done
        var stack: [UUID] = []
        func visit(_ id: UUID) -> [UUID]? {
            state[id] = 1
            stack.append(id)
            for next in edges[id] ?? [] {
                if state[next] == 1, let start = stack.firstIndex(of: next) { return Array(stack[start...]) }
                if state[next] == nil, let cycle = visit(next) { return cycle }
            }
            stack.removeLast()
            state[id] = 2
            return nil
        }
        for id in nodes where state[id] == nil {
            if let cycle = visit(id) { return cycle }
        }
        return nil
    }

    static func isUpstream(_ source: UUID, of target: UUID, control: [WorkflowConnection]) -> Bool {
        var seen = Set<UUID>()
        var queue = [target]
        while let id = queue.popLast() {
            for edge in control where edge.toNode == id && seen.insert(edge.fromNode).inserted {
                if edge.fromNode == source { return true }
                queue.append(edge.fromNode)
            }
        }
        return false
    }
}
