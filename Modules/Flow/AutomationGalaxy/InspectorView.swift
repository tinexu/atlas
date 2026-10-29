import AtlasCore
import AtlasSpaces
import SwiftUI

/// Settings for the selected node, shared by the 2D canvas and the 3D
/// galaxy: its parameters (from `ParameterSpec`), what's connected to its
/// inputs, timeout, retries, failure handling and notes.
struct InspectorView: View {
    @ObservedObject var model: FlowEditorModel

    var body: some View {
        Group {
            if model.selection.count == 1, let id = model.selection.first, let node = model.node(id) {
                NodeInspector(model: model, node: node)
                    .id(id)
            } else if model.selection.count > 1 {
                ContentUnavailableView {
                    Label("\(model.selection.count) steps selected", systemImage: "square.on.square")
                } actions: {
                    Button("Group") { model.groupSelection() }
                    Button("Duplicate") { model.duplicateSelection() }
                    Button("Delete", role: .destructive) { model.deleteSelection() }
                }
            } else {
                WorkflowInspector(model: model)
            }
        }
    }
}

/// Shown with nothing selected: the automation's own settings.
private struct WorkflowInspector: View {
    @ObservedObject var model: FlowEditorModel

    var body: some View {
        Form {
            Section("Automation") {
                TextField("Name", text: Binding(get: { model.draft.name }, set: { name in model.updateWorkflow("Rename") { $0.name = name } }))
                TextField("Description", text: Binding(get: { model.draft.summary }, set: { text in model.updateWorkflow { $0.summary = text } }),
                          axis: .vertical)
                Picker("When a step fails", selection: Binding(get: { model.draft.failurePolicy },
                                                              set: { policy in model.updateWorkflow { $0.failurePolicy = policy } })) {
                    ForEach(FailurePolicy.allCases, id: \.self) { Text($0.title).tag($0) }
                }
            }
            if model.draft.hasTriggers {
                Section {
                    Picker("If it's still running", selection: setting(\.reentrancy)) {
                        ForEach(ReentrancyMode.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    Stepper("Ignore repeats within \(ActionValue.number(model.draft.settings.minimumInterval).displayString) s",
                            value: setting(\.minimumInterval), in: 0...600, step: 1)
                    Stepper("At most \(model.draft.settings.maxRunsPerMinute) runs a minute", value: setting(\.maxRunsPerMinute), in: 1...120)
                    Stepper("Stop after setting itself off \(model.draft.settings.selfTriggerLimit) times", value: setting(\.selfTriggerLimit), in: 1...20)
                } header: {
                    Text("Triggers")
                } footer: {
                    Text("Firings that don't run are listed in Run History as skipped, with the reason.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section {
                ForEach(model.draft.variables) { variable in
                    HStack {
                        Text(variable.name).font(.body.monospaced())
                        Spacer()
                        Text(variable.initialValue.displayString).foregroundStyle(.secondary)
                        Toggle("Saved", isOn: Binding(get: { variable.isSaved }, set: { saved in
                            model.updateWorkflow { w in
                                if let i = w.variables.firstIndex(where: { $0.name == variable.name }) { w.variables[i].isSaved = saved }
                            }
                        }))
                        .help("Saved variables keep their value between runs")
                        Button(role: .destructive) {
                            model.updateWorkflow("Remove Variable") { $0.variables.removeAll { $0.name == variable.name } }
                        } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless)
                    }
                }
                Button("Add Variable") {
                    var n = 1
                    while model.draft.variables.contains(where: { $0.name == "variable\(n)" }) { n += 1 }
                    model.updateWorkflow("Add Variable") { $0.variables.append(WorkflowVariable(name: "variable\(n)")) }
                }
            } header: {
                Text("Variables")
            } footer: {
                Text("Use them in text as {{var.name}}. Variables last for one run unless saved.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func setting<T>(_ keyPath: WritableKeyPath<WorkflowSettings, T>) -> Binding<T> {
        Binding(get: { model.draft.settings[keyPath: keyPath] }, set: { value in model.updateWorkflow { $0.settings[keyPath: keyPath] = value } })
    }
}

private struct NodeInspector: View {
    @ObservedObject var model: FlowEditorModel
    let node: WorkflowStep

    var body: some View {
        Form {
            Section {
                HStack(spacing: 8) {
                    Image(systemName: model.symbol(of: node))
                        .foregroundStyle(.white)
                        .frame(width: 26, height: 26)
                        .background(FlowStyle.color(for: node.kind), in: RoundedRectangle(cornerRadius: 6))
                    Text(model.title(of: node)).font(.headline)
                }
                TextField("Label", text: binding(\.label, default: ""), prompt: Text("Optional, used in {{node.label.key}}"))
                Toggle("Step is on", isOn: binding(\.isEnabled))
            }
            if !model.issues(for: node.id).isEmpty {
                Section("Problems") {
                    ForEach(model.issues(for: node.id)) { issue in
                        Label(issue.message, systemImage: issue.severity == .error ? "exclamationmark.octagon.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(issue.severity == .error ? .red : .orange)
                            .font(.callout)
                        if let folder = issue.folderToAdd {
                            Button("Add \(FileLocation.displayName(for: folder)) to Orbit") { model.addFolderToOrbit(folder) }
                                .help("Opens the folder picker at \(folder.abbreviatedPath). Choosing it lets ATLAS watch and change files there.")
                        }
                    }
                }
            }

            switch node.kind {
            case .trigger: TriggerInspector(model: model, node: node)
            case .condition: ConditionInspector(model: model, node: node)
            case .action: ActionInspector(model: model, node: node)
            case .control: ControlInspector(model: model, node: node)
            }

            ConnectionsSection(model: model, node: node)

            Section("Running") {
                if node.kind == .action {
                    TextField("Timeout (seconds)", value: binding(\.timeout), format: .number,
                              prompt: Text(model.registry.descriptor(for: node.actionID).map { "\(Int($0.defaultTimeout))" } ?? "Default"))
                    if model.registry.descriptor(for: node.actionID)?.isIdempotent == true {
                        Stepper("Retries: \(node.maxRetries)", value: binding(\.maxRetries), in: 0...AutomationEngine.maxRetries)
                    } else {
                        Text("Not retried: running it twice could repeat its effect.").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Picker("If this step fails", selection: binding(\.failurePolicy)) {
                    Text("Use the automation's setting").tag(FailurePolicy?.none)
                    ForEach(FailurePolicy.allCases, id: \.self) { Text($0.title).tag(Optional($0)) }
                }
            }
            Section("Notes") {
                TextField("Notes", text: Binding(
                    get: { node.config.notes ?? "" },
                    set: { text in model.updateNode(node.id, "Edit Notes") { $0.config.notes = text.isEmpty ? nil : text } }
                ), axis: .vertical)
                .lineLimit(2...6)
            }
        }
        .formStyle(.grouped)
    }

    private func binding<T>(_ keyPath: WritableKeyPath<WorkflowStep, T>) -> Binding<T> {
        Binding(get: { model.node(node.id)?[keyPath: keyPath] ?? node[keyPath: keyPath] },
                set: { value in model.updateNode(node.id) { $0[keyPath: keyPath] = value } })
    }

    private func binding(_ keyPath: WritableKeyPath<WorkflowStep, String?>, default fallback: String) -> Binding<String> {
        Binding(get: { model.node(node.id)?[keyPath: keyPath] ?? fallback },
                set: { value in model.updateNode(node.id) { $0[keyPath: keyPath] = value.isEmpty ? nil : value } })
    }
}

/// Typed-in parameter fields for any node, driven by ParameterSpecs.
struct ParameterFields: View {
    @ObservedObject var model: FlowEditorModel
    let node: WorkflowStep
    let specs: [ParameterSpec]

    var body: some View {
        ForEach(specs, id: \.key) { spec in
            LabeledContent {
                ParameterInput(spec: spec, value: value(spec.key), connectedFrom: connectedFrom(spec.key),
                               choices: SpaceParameterChoices.choices(for: spec, parameters: model.node(node.id)?.parameters ?? [:],
                                                                      store: model.core.store))
            } label: {
                Text(spec.label + (spec.isRequired && spec.defaultValue == nil ? " *" : ""))
            }
            .help(spec.help ?? "")
        }
    }

    func value(_ key: String) -> Binding<ActionValue?> {
        Binding(
            get: { model.node(node.id)?.parameters[key] },
            set: { value in model.updateNode(node.id) { step in
                if let value { step.parameters[key] = value } else { step.parameters.removeValue(forKey: key) }
            } }
        )
    }

    func connectedFrom(_ key: String) -> String? {
        guard let connection = model.draft.connections.first(where: { $0.toNode == node.id && $0.toPort == key }),
              let source = model.node(connection.fromNode)
        else { return nil }
        let port = model.ports(for: source).first { $0.id == connection.fromPort }?.name ?? connection.fromPort
        return "\(model.title(of: source)) · \(port)"
    }
}

/// What's connected to this node, with a way to disconnect each.
private struct ConnectionsSection: View {
    @ObservedObject var model: FlowEditorModel
    let node: WorkflowStep

    var body: some View {
        let connections = model.draft.connections.filter { $0.toNode == node.id || $0.fromNode == node.id }
        if !connections.isEmpty {
            Section("Connections") {
                ForEach(connections) { connection in
                    HStack {
                        Image(systemName: connection.isControl ? "arrow.right" : "link")
                            .foregroundStyle(.secondary)
                        Text(describe(connection)).font(.callout).lineLimit(2)
                        Spacer()
                        Button { model.disconnect(connection.id) } label: { Image(systemName: "xmark.circle") }
                            .buttonStyle(.borderless)
                            .help("Disconnect")
                    }
                }
            }
        }
    }

    private func describe(_ c: WorkflowConnection) -> String {
        func name(_ id: UUID, _ port: String, _ direction: PortDirection) -> String {
            guard let n = model.node(id) else { return "?" }
            let portName = model.ports(for: n).first { $0.id == port && $0.direction == direction }?.name ?? port
            return "\(model.title(of: n)) · \(portName)"
        }
        return "\(name(c.fromNode, c.fromPort, .output)) → \(name(c.toNode, c.toPort, .input))"
    }
}
