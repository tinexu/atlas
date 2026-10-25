import AtlasCore
import AtlasFlow
import AtlasSpaces
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
                                ParameterField(spec: spec, value: binding(for: spec), parameters: step.parameters)
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

/// An input control chosen by parameter kind: the same field the graph
/// editor uses, including menus of Spaces and profiles.
struct ParameterField: View {
    @EnvironmentObject private var model: AppModel
    let spec: ParameterSpec
    @Binding var value: ActionValue?
    /// The step's other values, for menus that depend on them (profiles of the chosen Space).
    var parameters: ActionParameters = [:]

    var body: some View {
        ParameterInput(spec: spec, value: $value, choices: model.core.flatMap {
            SpaceParameterChoices.choices(for: spec, parameters: parameters, store: $0.store)
        })
    }
}
