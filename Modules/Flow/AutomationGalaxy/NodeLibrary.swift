import AtlasCore
import SwiftUI

/// Something that can be added to a workflow from the library.
public struct NodeTemplate: Identifiable, Hashable {
    public enum Category: String, CaseIterable, Identifiable {
        case triggers = "Triggers", conditions = "Conditions", actions = "Actions", control = "Control"
        public var id: String { rawValue }
    }

    public let id: String
    public let title: String
    public let summary: String
    public let symbolName: String
    public let category: Category
    let make: @Sendable () -> WorkflowStep

    public static func == (a: NodeTemplate, b: NodeTemplate) -> Bool { a.id == b.id }
    public func hash(into hasher: inout Hasher) { hasher.combine(id) }

    /// Every template, grouped by category.
    public static func all(registry: ActionRegistry) -> [NodeTemplate] {
        var templates: [NodeTemplate] = TriggerCatalog.all.map { type in
            NodeTemplate(id: "trigger:\(type.id)", title: type.title, summary: type.summary, symbolName: type.symbolName,
                         category: .triggers) {
                var defaults: ActionParameters = [:]
                for spec in type.parameters { if let value = spec.defaultValue { defaults[spec.key] = value } }
                return .trigger(type.id, parameters: defaults)
            }
        }
        templates.append(NodeTemplate(id: "condition", title: "Condition", summary: "Continue on “True” or “False” after checking something.",
                                      symbolName: "questionmark.diamond", category: .conditions) {
            .condition(ConditionGroup(.fileExtension(path: "{{trigger.path}}", extensions: "pdf")))
        })
        templates.append(NodeTemplate(id: "branch", title: "Branch (if/else)", summary: "Compare two values and take one of two paths.",
                                      symbolName: "arrow.triangle.branch", category: .conditions) {
            .condition(ConditionGroup(.compare(left: "{{var.value}}", op: .equals, right: "")), label: "Branch")
        })
        templates += registry.descriptors.map { descriptor in
            NodeTemplate(id: "action:\(descriptor.id.rawValue)", title: descriptor.title, summary: descriptor.summary,
                         symbolName: descriptor.symbolName, category: .actions) {
                var defaults: ActionParameters = [:]
                for spec in descriptor.parameters { if let value = spec.defaultValue { defaults[spec.key] = value } }
                return WorkflowStep(actionID: descriptor.id, parameters: defaults)
            }
        }
        templates += ControlType.allCases.map { type in
            NodeTemplate(id: "control:\(type.rawValue)", title: type.title, summary: Self.summary(type), symbolName: type.symbolName,
                         category: .control) {
                switch type {
                case .delay: return .control(.delay, parameters: ["seconds": 5])
                case .switchValue: return .control(.switchValue, parameters: ["value": "{{trigger.extension}}"], config: NodeConfig(cases: ["pdf", "png"]))
                case .loop: return .control(.loop, parameters: ["items": ""], config: NodeConfig(loopMode: .forEach, maxIterations: 100))
                case .setVariable: return .control(.setVariable, parameters: ["value": ""], config: NodeConfig(variableName: "result"))
                case .getVariable: return .control(.getVariable, config: NodeConfig(variableName: "result"))
                default: return .control(type)
                }
            }
        }
        return templates
    }

    static func summary(_ type: ControlType) -> String {
        switch type {
        case .delay: return "Wait some seconds, or until a time of day."
        case .switchValue: return "Take a different path for each value."
        case .loop: return "Repeat steps for each item, or a number of times (at most 1,000)."
        case .subworkflow: return "Run another automation, passing values in and getting results back."
        case .setVariable: return "Remember a value for later steps, or for the next run."
        case .getVariable: return "Read a remembered value."
        case .errorHandler: return "Try some steps; if one fails, run recovery steps instead of stopping."
        case .parallel: return "Run branches at the same time, when that's safe."
        }
    }
}

/// The searchable node library. Drag a node onto the canvas, or double-click to add it.
struct NodeLibraryView: View {
    let templates: [NodeTemplate]
    let add: (NodeTemplate) -> Void
    @State private var search = ""

    var body: some View {
        VStack(spacing: 0) {
            TextField("Search nodes", text: $search)
                .textFieldStyle(.roundedBorder)
                .padding(10)
            List {
                ForEach(NodeTemplate.Category.allCases) { category in
                    let items = filtered.filter { $0.category == category }
                    if !items.isEmpty {
                        Section(category.rawValue) {
                            ForEach(items) { template in
                                row(template)
                            }
                        }
                    }
                }
            }
            .listStyle(.sidebar)
        }
    }

    private var filtered: [NodeTemplate] {
        let query = search.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return templates }
        return templates.filter { $0.title.localizedCaseInsensitiveContains(query) || $0.summary.localizedCaseInsensitiveContains(query) }
    }

    private func row(_ template: NodeTemplate) -> some View {
        HStack(spacing: 8) {
            Image(systemName: template.symbolName)
                .foregroundStyle(FlowStyle.color(for: template.category))
                .frame(width: 18)
            Text(template.title)
            Spacer()
        }
        .contentShape(Rectangle())
        .help(template.summary)
        .onTapGesture(count: 2) { add(template) }
        .draggable(template.id)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: "Add to workflow") { add(template) }
    }
}
