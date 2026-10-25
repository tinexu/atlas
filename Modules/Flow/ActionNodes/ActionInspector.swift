import AtlasCore
import SwiftUI

/// Settings for an action node: which registered action it runs, its
/// parameters (typed in or connected from upstream) and what it reports.
struct ActionInspector: View {
    @ObservedObject var model: FlowEditorModel
    let node: WorkflowStep

    var body: some View {
        let descriptor = model.registry.descriptor(for: node.actionID)
        Section("Action") {
            Picker("Action", selection: Binding(
                get: { node.actionID },
                set: { id in
                    model.updateNode(node.id, "Change Action") { step in
                        step.actionID = id
                        step.parameters = [:]
                        for spec in model.registry.descriptor(for: id)?.parameters ?? [] {
                            if let value = spec.defaultValue { step.parameters[spec.key] = value }
                        }
                    }
                }
            )) {
                ForEach(Dictionary(grouping: model.registry.descriptors, by: \.category).sorted { $0.key < $1.key }, id: \.key) { category, items in
                    Section(category) {
                        ForEach(items) { Label($0.title, systemImage: $0.symbolName).tag($0.id) }
                    }
                }
            }
            if let descriptor {
                Text(descriptor.summary).font(.callout).foregroundStyle(.secondary)
                ParameterFields(model: model, node: node, specs: descriptor.parameters)
                if descriptor.confirmationRequired {
                    Label("You confirm each run. Automatic runs ask with a notification and give up after 2 minutes.",
                          systemImage: "hand.raised").font(.caption).foregroundStyle(.secondary)
                }
                if !descriptor.permissions.isEmpty {
                    Text("Needs: \(descriptor.permissions.map(\.title).sorted().joined(separator: ", "))")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Label("This action isn't available in this version of ATLAS.", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
        }
        if let descriptor {
            Section {
                ForEach(descriptor.allOutputs, id: \.key) { output in
                    HStack {
                        Text(output.label)
                        Spacer()
                        Text(output.type.title).font(.caption).foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Reports")
            } footer: {
                Text(node.label.map { "Use as {{node.\($0).key}}, e.g. {{node.\($0).\(descriptor.allOutputs.first?.key ?? "message")}}." }
                     ?? "Give this step a label to use its results in text, or connect its outputs.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

/// Settings for control nodes.
struct ControlInspector: View {
    @ObservedObject var model: FlowEditorModel
    let node: WorkflowStep

    var body: some View {
        let fields = ParameterFields(model: model, node: node, specs: [])
        switch node.config.control {
        case .delay:
            Section("Delay") {
                Picker("Wait", selection: Binding(
                    get: { node.config.delayUntil == nil ? "seconds" : "until" },
                    set: { mode in model.updateNode(node.id) { $0.config.delayUntil = mode == "until" ? "17:00" : nil } }
                )) {
                    Text("For a number of seconds").tag("seconds")
                    Text("Until a time of day").tag("until")
                }
                if let until = node.config.delayUntil {
                    TextField("Time (24-hour)", text: Binding(get: { until }, set: { t in model.updateNode(node.id) { $0.config.delayUntil = t } }))
                } else {
                    ParameterFields(model: model, node: node, specs: [ParameterSpec(key: "seconds", label: "Seconds", kind: .number, minimum: 0, maximum: 86_400)])
                }
            }
        case .switchValue:
            Section {
                ParameterFields(model: model, node: node, specs: [ParameterSpec(key: "value", label: "Value", kind: .text, help: "e.g. {{trigger.extension}}")])
                ForEach(Array((node.config.cases ?? []).enumerated()), id: \.offset) { index, value in
                    HStack {
                        TextField("Case", text: Binding(get: { value }, set: { text in
                            model.updateNode(node.id, "Edit Case") { if $0.config.cases?.indices.contains(index) == true { $0.config.cases?[index] = text } }
                        }))
                        Button(role: .destructive) {
                            model.updateNode(node.id, "Remove Case") { $0.config.cases?.remove(at: index) }
                        } label: { Image(systemName: "minus.circle") }.buttonStyle(.borderless)
                    }
                }
                Button("Add Case") { model.updateNode(node.id, "Add Case") { $0.config.cases = ($0.config.cases ?? []) + ["value"] } }
            } header: {
                Text("Switch")
            } footer: {
                Text("Matches ignore upper and lower case. Anything else goes to “Otherwise”.").font(.caption).foregroundStyle(.secondary)
            }
        case .loop:
            Section {
                Picker("Repeat", selection: Binding(get: { node.config.loopMode ?? .forEach },
                                                    set: { mode in model.updateNode(node.id) { $0.config.loopMode = mode } })) {
                    ForEach(LoopMode.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                if node.config.loopMode == .repeatCount {
                    ParameterFields(model: model, node: node, specs: [ParameterSpec(key: "count", label: "Times", kind: .number, minimum: 1, maximum: 1_000)])
                } else {
                    ParameterFields(model: model, node: node, specs: [ParameterSpec(key: "items", label: "Items", kind: .text, help: "One per line, or separated by commas")])
                }
                Stepper("Stop if more than \(node.config.maxIterations ?? 1_000) times",
                        value: Binding(get: { node.config.maxIterations ?? 1_000 },
                                       set: { n in model.updateNode(node.id) { $0.config.maxIterations = n } }),
                        in: 1...WorkflowValidator.maxLoopIterations, step: 10)
            } header: {
                Text("Loop")
            } footer: {
                Text("Steps connected to “Each time” run once per item, with {{loop.item}} and {{loop.index}}. A loop over its limit (at most 1,000) fails the run.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        case .subworkflow:
            Section {
                Picker("Automation", selection: Binding(
                    get: { node.config.workflowID },
                    set: { id in model.updateNode(node.id, "Choose Automation") { $0.config.workflowID = id } }
                )) {
                    Text("Choose…").tag(UUID?.none)
                    ForEach(((try? model.core.store.workflows()) ?? []).filter { $0.id != model.draft.id }) { workflow in
                        Text(workflow.name).tag(Optional(workflow.id))
                    }
                }
                ForEach(node.parameters.keys.sorted(), id: \.self) { key in
                    HStack {
                        Text(key).font(.body.monospaced())
                        ParameterInput(spec: ParameterSpec(key: key, label: key, kind: .text), value: fields.value(key),
                                       connectedFrom: fields.connectedFrom(key))
                        Button(role: .destructive) {
                            model.updateNode(node.id, "Remove Input") { $0.parameters.removeValue(forKey: key) }
                        } label: { Image(systemName: "minus.circle") }.buttonStyle(.borderless)
                    }
                }
                Button("Add Input") {
                    var n = 1
                    while node.parameters["input\(n)"] != nil { n += 1 }
                    model.updateNode(node.id, "Add Input") { $0.parameters["input\(n)"] = "" }
                }
            } header: {
                Text("Subworkflow")
            } footer: {
                Text("The called automation reads inputs as {{input.name}}; its variables come back as this step's results. Calls can nest 5 deep and never loop back.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        case .setVariable, .getVariable:
            Section("Variable") {
                TextField("Name", text: Binding(get: { node.config.variableName ?? "" },
                                                set: { name in model.updateNode(node.id) { $0.config.variableName = name } }))
                    .font(.body.monospaced())
                if node.config.control == .setVariable {
                    ParameterFields(model: model, node: node, specs: [ParameterSpec(key: "value", label: "Value", kind: .text, isRequired: false)])
                    let name = node.config.variableName ?? ""
                    let saved = model.draft.variables.first { $0.name == name }?.isSaved ?? false
                    Toggle("Keep between runs", isOn: Binding(get: { saved }, set: { on in
                        model.updateWorkflow("Save Variable") { w in
                            if let i = w.variables.firstIndex(where: { $0.name == name }) { w.variables[i].isSaved = on }
                            else { w.variables.append(WorkflowVariable(name: name, isSaved: on)) }
                        }
                    }))
                    .disabled(name.isEmpty)
                }
            }
        case .errorHandler:
            Section("Error Handler") {
                Text("Steps connected to “Try” run first. If one fails, the steps on “If it fails” run instead of stopping the automation, with {{error.message}} available. “Afterwards” runs either way.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        case .parallel:
            Section("Parallel") {
                Text("Branches connected to “Branches” run at the same time when every step in them is safe to (waits, notifications, links, log messages). Otherwise they run one after another, and the run history says why.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        case nil:
            EmptyView()
        }
    }
}
