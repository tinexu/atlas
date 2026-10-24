import AtlasCore
import SwiftUI

/// One step of a workflow. Its fields are generated from the action's
/// `ParameterSpec`s, so new actions get an editor for free.
struct StepCard: View {
    @EnvironmentObject private var model: AppModel

    let number: Int
    @Binding var step: WorkflowStep
    let canMoveUp: Bool
    let canMoveDown: Bool
    let move: (Int) -> Void
    let remove: () -> Void

    @State private var showsAdvanced = false

    private var descriptor: ActionDescriptor? { model.registry?.descriptor(for: step.actionID) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if let descriptor {
                if !descriptor.parameters.isEmpty {
                    Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 10) {
                        ForEach(descriptor.parameters, id: \.key) { spec in
                            GridRow {
                                Text(spec.label)
                                    .foregroundStyle(.secondary)
                                    .gridColumnAlignment(.trailing)
                                ParameterField(spec: spec, value: binding(for: spec))
                            }
                        }
                    }
                }
                badges(for: descriptor)
                DisclosureGroup("Advanced", isExpanded: $showsAdvanced) {
                    advanced(for: descriptor)
                }
                .font(.callout)
            } else {
                Label("ATLAS doesn't recognise the action “\(step.actionID.rawValue)”. This step will fail until it's removed.",
                      systemImage: "questionmark.diamond")
                    .foregroundStyle(.orange)
            }
        }
        .padding(14)
        .background(.background, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator))
        .opacity(step.isEnabled ? 1 : 0.55)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text("\(number)")
                .font(.caption.monospacedDigit().weight(.semibold))
                .frame(width: 22, height: 22)
                .background(Color.accentColor.opacity(0.15), in: Circle())
            Image(systemName: descriptor?.symbolName ?? "questionmark")
                .foregroundStyle(Color.accentColor)
            Text(descriptor?.title ?? step.actionID.rawValue)
                .font(.headline)
            if let descriptor, !model.isActionEnabled(descriptor.id) {
                Pill(text: "Turned off in Action Library", tint: .orange)
            }
            Spacer()
            Toggle("Enabled", isOn: $step.isEnabled)
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
                .help(step.isEnabled ? "Skip this step" : "Run this step")
            Menu {
                Button("Move Up") { move(-1) }.disabled(!canMoveUp)
                Button("Move Down") { move(1) }.disabled(!canMoveDown)
                Divider()
                Button("Remove Step", role: .destructive) { remove() }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
    }

    @ViewBuilder
    private func badges(for descriptor: ActionDescriptor) -> some View {
        let effects = descriptor.sideEffects.sorted { $0.rawValue < $1.rawValue }
        let permissions = descriptor.permissions.sorted { $0.rawValue < $1.rawValue }
        if descriptor.confirmationRequired || !effects.isEmpty || !permissions.isEmpty {
            HStack(spacing: 6) {
                if descriptor.confirmationRequired {
                    Pill(text: "Asks before running", tint: .orange)
                }
                ForEach(permissions) { Pill(text: $0.title, tint: .blue) }
                ForEach(effects, id: \.self) { Pill(text: $0.title) }
            }
        }
    }

    @ViewBuilder
    private func advanced(for descriptor: ActionDescriptor) -> some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 10) {
            GridRow {
                Text("Label").foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                TextField(model.registry?.displayLabel(for: WorkflowStep(actionID: step.actionID, parameters: step.parameters)) ?? "",
                          text: Binding(get: { step.label ?? "" }, set: { step.label = $0.isEmpty ? nil : $0 }))
            }
            GridRow {
                Text("Timeout").foregroundStyle(.secondary)
                HStack {
                    TextField("\(Int(descriptor.defaultTimeout))",
                              value: Binding(get: { step.timeout }, set: { step.timeout = $0 }),
                              format: .number)
                        .frame(width: 80)
                    Text("seconds").foregroundStyle(.secondary)
                }
            }
            GridRow {
                Text("Retries").foregroundStyle(.secondary)
                if descriptor.isIdempotent {
                    Stepper(value: $step.maxRetries, in: 0...AutomationEngine.maxRetries) {
                        Text(step.maxRetries == 0 ? "None" : "Up to \(step.maxRetries)")
                    }
                } else {
                    Text("Not retried automatically, since repeating it could duplicate work.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.top, 6)
    }

    private func binding(for spec: ParameterSpec) -> Binding<ActionValue?> {
        Binding(
            get: { step.parameters[spec.key] },
            set: { newValue in
                if let newValue, !newValue.isEmpty {
                    step.parameters[spec.key] = newValue
                } else {
                    step.parameters.removeValue(forKey: spec.key)
                }
            }
        )
    }
}

/// An input control chosen by parameter kind.
private struct ParameterField: View {
    let spec: ParameterSpec
    @Binding var value: ActionValue?

    private var placeholder: String {
        if let fallback = spec.defaultValue { return fallback.displayString }
        return spec.help ?? (spec.isRequired ? "Required" : "Optional")
    }

    private var text: Binding<String> {
        Binding(
            get: { value?.stringValue ?? "" },
            set: { value = $0.isEmpty ? nil : .string($0) }
        )
    }

    var body: some View {
        switch spec.kind {
        case .boolean:
            Toggle(spec.label, isOn: Binding(
                get: { value?.boolValue ?? spec.defaultValue?.boolValue ?? false },
                set: { value = .bool($0) }
            ))
            .labelsHidden()

        case .number:
            TextField(placeholder, value: Binding(
                get: { value?.numberValue },
                set: { value = $0.map(ActionValue.number) }
            ), format: .number)
            .frame(maxWidth: 120)

        case .bundleIdentifier:
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    if let id = value?.stringValue, let icon = Pickers.applicationIcon(for: id) {
                        Image(nsImage: icon).resizable().frame(width: 18, height: 18)
                    }
                    TextField(placeholder, text: text)
                        .font(.body.monospaced())
                    Button("Choose App…") {
                        if let id = Pickers.chooseApplication() { value = .string(id) }
                    }
                }
                appHint
            }

        case .filePath, .folderPath:
            HStack {
                TextField(placeholder, text: text)
                Button("Choose…") {
                    if let path = Pickers.choosePath(folders: spec.kind == .folderPath) { value = .string(path) }
                }
            }

        case .url, .text:
            TextField(placeholder, text: text)
        }
    }

    @ViewBuilder
    private var appHint: some View {
        if let id = value?.stringValue, !id.isEmpty, Pickers.applicationName(for: id) == nil {
            Text("No installed app with this identifier")
                .font(.caption2)
                .foregroundStyle(.orange)
        }
    }
}
