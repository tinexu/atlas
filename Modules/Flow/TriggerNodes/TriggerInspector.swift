import AtlasCore
import SwiftUI

/// Settings for a trigger node: its type, parameters, what it reports to
/// later steps, how reliable it is, and any problem setting it up.
struct TriggerInspector: View {
    @ObservedObject var model: FlowEditorModel
    let node: WorkflowStep

    var body: some View {
        let type = TriggerCatalog.type(id: node.config.triggerType ?? "")
        Section("Trigger") {
            Picker("When", selection: Binding(
                get: { node.config.triggerType ?? "" },
                set: { id in
                    model.updateNode(node.id, "Change Trigger") { step in
                        step.config.triggerType = id
                        step.actionID = WorkflowStep.placeholderActionID(for: .trigger, config: step.config)
                        step.parameters = [:]
                        for spec in TriggerCatalog.type(id: id)?.parameters ?? [] {
                            if let value = spec.defaultValue { step.parameters[spec.key] = value }
                        }
                    }
                }
            )) {
                ForEach(TriggerCatalog.all) { Label($0.title, systemImage: $0.symbolName).tag($0.id) }
            }
            if let type {
                Text(type.summary).font(.callout).foregroundStyle(.secondary)
                ParameterFields(model: model, node: node, specs: type.parameters)
            }
        }
        if let type {
            if let problem = model.core.triggers?.problem(for: node.id) {
                Section {
                    Label(problem, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
            }
            Section("Reliability") {
                Label(type.reliability, systemImage: "info.circle").font(.callout)
                if !type.permissions.isEmpty {
                    Text("Needs: \(type.permissions.map(\.title).sorted().joined(separator: ", "))")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if !type.outputs.isEmpty {
                Section {
                    ForEach(type.outputs, id: \.key) { output in
                        HStack {
                            Text("{{trigger.\(output.key)}}").font(.callout.monospaced()).textSelection(.enabled)
                            Spacer()
                            Text("\(output.label) · \(output.type.title)").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("Reports")
                } footer: {
                    Text("Connect these outputs to later steps, or type them into any text field.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}
