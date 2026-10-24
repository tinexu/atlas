import AtlasCore
import AtlasSpaces
import SwiftUI

/// Assigns an action or automation to a room object and places it. The
/// parameter fields come from the action's `ParameterSpec`s, exactly as in
/// a workflow step.
struct ObjectEditor: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var spaces: SpacesModel
    @Environment(\.dismiss) private var dismiss

    enum Assignment: String, CaseIterable, Identifiable {
        case nothing, action, automation
        var id: Self { self }
        var title: String {
            switch self {
            case .nothing: return "Nothing (decoration)"
            case .action: return "Run an action"
            case .automation: return "Run an automation"
            }
        }
    }

    let original: SpaceObject
    @State private var draft: SpaceObject
    @State private var assignment: Assignment
    @State private var validationError: String?

    init(original: SpaceObject) {
        self.original = original
        _draft = State(initialValue: original)
        _assignment = State(initialValue: original.workflowID != nil ? .automation : original.actionID != nil ? .action : .nothing)
    }

    private var descriptor: ActionDescriptor? {
        draft.actionID.flatMap { model.registry?.descriptor(for: $0) }
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("Object") {
                    TextField("Label", text: Binding(
                        get: { draft.label ?? "" },
                        set: { draft.label = $0.isEmpty ? nil : $0 }
                    ), prompt: Text(draft.kind.title))
                    Picker("Kind", selection: $draft.kind) {
                        ForEach(SpaceObjectKind.allCases, id: \.self) { kind in
                            Label(kind.title, systemImage: kind.symbolName).tag(kind)
                        }
                    }
                }

                Section("When clicked") {
                    Picker("Does", selection: $assignment) {
                        ForEach(Assignment.allCases) { Text($0.title).tag($0) }
                    }
                    switch assignment {
                    case .nothing:
                        EmptyView()
                    case .action:
                        actionFields
                    case .automation:
                        Picker("Automation", selection: Binding(
                            get: { draft.workflowID },
                            set: { draft.workflowID = $0 }
                        )) {
                            Text("Choose…").tag(UUID?.none)
                            ForEach(model.workflows) { Text($0.name).tag(Optional($0.id)) }
                        }
                    }
                    if let validationError {
                        Label(validationError, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                }

                Section("Placement") {
                    slider("Left – right", value: $draft.transform.position.x, in: -1...1)
                    slider("Back – front", value: $draft.transform.position.z, in: -1...1)
                    slider("Height", value: $draft.transform.position.y, in: 0...1.1)
                    slider("Turn", value: $draft.transform.rotation.y, in: -180...180, format: "%.0f°")
                    slider("Size", value: Binding(
                        get: { draft.transform.scale.x },
                        set: { draft.transform.scale = [$0, $0, $0] }
                    ), in: 0.3...2.5, format: "%.1f×")
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                Button("Remove Object", role: .destructive) {
                    spaces.delete(original)
                    dismiss()
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(14)
        }
        .frame(minWidth: 520, idealWidth: 560, minHeight: 520, idealHeight: 620)
    }

    @ViewBuilder
    private var actionFields: some View {
        let descriptors = model.registry?.descriptors ?? []
        Picker("Action", selection: Binding(
            get: { draft.actionID },
            set: { newID in
                if newID != draft.actionID { draft.parameters = [:] }
                draft.actionID = newID
            }
        )) {
            Text("Choose…").tag(ActionID?.none)
            ForEach(Array(Set(descriptors.map(\.category))).sorted(), id: \.self) { category in
                Section(category) {
                    ForEach(descriptors.filter { $0.category == category }) { descriptor in
                        Text(descriptor.title).tag(Optional(descriptor.id))
                    }
                }
            }
        }
        if let descriptor {
            Text(descriptor.summary).font(.caption).foregroundStyle(.secondary)
            ForEach(descriptor.parameters, id: \.key) { spec in
                LabeledContent(spec.label) {
                    ParameterField(spec: spec, value: Binding(
                        get: { draft.parameters[spec.key] },
                        set: { newValue in
                            if let newValue, !newValue.isEmpty {
                                draft.parameters[spec.key] = newValue
                            } else {
                                draft.parameters.removeValue(forKey: spec.key)
                            }
                        }
                    ))
                }
            }
            if !model.isActionEnabled(descriptor.id) {
                Label("This action is turned off in the Action Library.", systemImage: "nosign")
                    .foregroundStyle(.orange)
            }
        }
    }

    private func slider(_ title: String, value: Binding<Float>, in range: ClosedRange<Float>, format: String = "%.2f") -> some View {
        LabeledContent(title) {
            HStack {
                Slider(value: value, in: range)
                Text(String(format: format, value.wrappedValue))
                    .font(.caption.monospacedDigit())
                    .frame(width: 48, alignment: .trailing)
            }
        }
    }

    private func save() {
        var object = draft
        switch assignment {
        case .nothing:
            object.actionID = nil
            object.workflowID = nil
            object.parameters = [:]
        case .action:
            object.workflowID = nil
            guard let descriptor, let registry = model.registry else {
                validationError = "Choose an action."
                return
            }
            do {
                // Same validation the engine applies, so a broken object is
                // caught here rather than on click.
                _ = try registry.validate(object.parameters, for: descriptor)
            } catch {
                validationError = error.localizedDescription
                return
            }
        case .automation:
            object.actionID = nil
            object.parameters = [:]
            guard object.workflowID != nil else {
                validationError = "Choose an automation."
                return
            }
        }
        spaces.save(object)
        dismiss()
    }
}
