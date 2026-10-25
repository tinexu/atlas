import Foundation

/// The typed ports of each node, derived from its kind, configuration and
/// (for actions) the registered descriptor.
public enum NodePorts {
    public static func ports(for node: WorkflowStep, registry: ActionRegistry) -> [NodePort] {
        var ports: [NodePort] = []
        func input(_ id: String, _ name: String, _ type: PortType, required: Bool = false) {
            ports.append(NodePort(id: id, name: name, direction: .input, type: type, isRequired: required))
        }
        func output(_ id: String, _ name: String, _ type: PortType) {
            ports.append(NodePort(id: id, name: name, direction: .output, type: type))
        }
        func flowOut(_ id: String = NodePort.controlOut, _ name: String = "Then") { output(id, name, .control) }

        if node.kind != .trigger { input(NodePort.controlIn, "Run", .control) }

        switch node.kind {
        case .trigger:
            flowOut()
            for spec in TriggerCatalog.type(id: node.config.triggerType ?? "")?.outputs ?? [] {
                output(spec.key, spec.label, spec.type)
            }
        case .condition:
            flowOut("true", "True")
            flowOut("false", "False")
        case .action:
            if let descriptor = registry.descriptor(for: node.actionID) {
                for spec in descriptor.parameters {
                    input(spec.key, spec.label, PortType(spec.kind), required: spec.isRequired && spec.defaultValue == nil)
                }
                flowOut()
                for spec in descriptor.allOutputs { output(spec.key, spec.label, spec.type) }
            } else {
                flowOut()
            }
        case .control:
            switch node.config.control {
            case .delay:
                input("seconds", "Seconds", .number)
                flowOut()
            case .switchValue:
                input("value", "Value", .any, required: true)
                for value in node.config.cases ?? [] { flowOut("case:\(value)", value) }
                flowOut("default", "Otherwise")
            case .loop:
                if node.config.loopMode == .repeatCount {
                    input("count", "Times", .number, required: true)
                } else {
                    input("items", "Items", .any, required: true)
                }
                flowOut("body", "Each time")
                flowOut("done", "When finished")
                output("item", "Item", .any)
                output("index", "Index", .number)
            case .subworkflow:
                for key in node.parameters.keys.sorted() { input(key, key, .any) }
                flowOut()
                output("state", "Result", .string)
            case .setVariable:
                input("value", "Value", .any)
                flowOut()
                output("value", "Value", .any)
            case .getVariable:
                flowOut()
                output("value", "Value", .any)
            case .errorHandler:
                flowOut("try", "Try")
                flowOut("catch", "If it fails")
                flowOut("done", "Afterwards")
                output("error", "Error", .string)
                output("failedNode", "Failed step", .string)
            case .parallel:
                flowOut("branches", "Branches")
                flowOut("done", "When all finish")
            case nil:
                flowOut()
            }
        }
        return ports
    }

    /// Fills in every node's cached ports.
    public static func refresh(_ workflow: inout Workflow, registry: ActionRegistry) {
        for index in workflow.steps.indices {
            workflow.steps[index].ports = ports(for: workflow.steps[index], registry: registry)
        }
    }

    /// The control outputs a node may follow.
    public static func controlOutputs(of node: WorkflowStep, registry: ActionRegistry) -> [String] {
        ports(for: node, registry: registry).filter { $0.direction == .output && $0.isControl }.map(\.id)
    }
}
