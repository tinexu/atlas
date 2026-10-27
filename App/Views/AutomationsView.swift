import AtlasCompanion
import AtlasCore
import AtlasFlow
import SwiftUI

struct AutomationsView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        HSplitView {
            WorkflowList()
                .frame(minWidth: 230, idealWidth: 260, maxWidth: 340)
            Group {
                if let workflow = model.workflow(id: model.selectedWorkflowID) {
                    AutomationDetail(workflow: workflow)
                        .id(workflow.id)
                } else {
                    ContentUnavailableView {
                        Label("No automation selected", systemImage: "bolt.horizontal.circle")
                    } description: {
                        Text("An automation is a set of steps ATLAS runs for you, by hand or when something happens on your Mac, like a file arriving in Downloads.")
                    } actions: {
                        Button("New Automation") { model.createWorkflow() }
                    }
                }
            }
            .frame(minWidth: 520, maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle("Automations")
        .sheet(isPresented: $model.showGenerator) {
            if let core = model.core {
                GenerateWorkflowSheet(core: core, apps: model.companion?.apps.map { ($0.id, $0.name) } ?? [],
                                      provider: model.companion?.generationProvider(), prompt: model.generatorPrompt) { saved in
                    model.reloadWorkflows()
                    model.selectedWorkflowID = saved.id
                }
            }
        }
    }
}

/// An automation as a graph (the full editor), or as the Stage 01 step
/// list when it's a plain sequence of actions.
private struct AutomationDetail: View {
    @EnvironmentObject private var model: AppModel
    let workflow: Workflow
    @State private var showSteps = false
    @State private var explanation: String?

    var body: some View {
        let editor = model.editor(for: workflow)
        VStack(spacing: 0) {
            if let core = model.core {
                DraftBanner(core: core, workflow: workflow) { model.reloadWorkflows() }
                    .id(workflow.id)
            }
            if workflow.isLinear {
                HStack {
                    Picker("Edit as", selection: $showSteps) {
                        Text("Graph").tag(false)
                        Text("Step List").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .fixedSize()
                    .disabled(editor?.isDirty ?? false)
                    .help(editor?.isDirty ?? false ? "Save or revert the graph first" : "A plain list of steps can also be edited as a list")
                    Spacer()
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                Divider()
            }
            if showSteps && workflow.isLinear {
                WorkflowEditor(original: workflow)
            } else if let editor {
                FlowEditorView(model: editor)
            }
        }
        .onAppear {
            if let focus = model.pendingFocus, focus.workflowID == workflow.id {
                showSteps = false
                model.pendingFocus = nil
            }
        }
        .toolbar {
            ToolbarItem {
                Button { explanation = model.explain(workflow) } label: { Label("Explain", systemImage: "text.bubble") }
                    .help("Explain this workflow in plain words")
            }
        }
        .sheet(item: Binding(get: { explanation.map(TextItem.init) }, set: { explanation = $0?.text })) { item in
            ExplanationSheet(title: "What “\(workflow.name)” does", text: item.text)
        }
    }
}

struct TextItem: Identifiable {
    let text: String
    var id: String { text }
}

// MARK: - List

private struct WorkflowList: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        List(selection: $model.selectedWorkflowID) {
            ForEach(model.workflows) { workflow in
                WorkflowRow(workflow: workflow)
                    .contextMenu {
                        Button("Run") { model.run(workflow) }
                            .disabled(model.isRunning(workflow.id))
                        Button("Duplicate") { model.duplicate(workflow) }
                        Divider()
                        Button("Delete", role: .destructive) { model.delete(workflow) }
                    }
            }
        }
        .listStyle(.inset)
        .safeAreaInset(edge: .bottom) {
            HStack {
                Button { model.createWorkflow() } label: { Label("New Automation", systemImage: "plus") }
                    .buttonStyle(.borderless)
                Spacer()
                Button { model.showGenerator = true } label: { Label("Describe…", systemImage: "wand.and.stars") }
                    .buttonStyle(.borderless)
                    .help("Describe an automation in a sentence and get a draft")
            }
            .padding(10)
            .background(.bar)
        }
    }
}

private struct WorkflowRow: View {
    @EnvironmentObject private var model: AppModel
    let workflow: Workflow

    var body: some View {
        HStack(spacing: 10) {
            Group {
                if model.isRunning(workflow.id) {
                    StateIcon(state: .running)
                } else if let last = model.latestRun(for: workflow.id) {
                    StateIcon(state: last.state)
                } else {
                    Image(systemName: "circle").foregroundStyle(.tertiary)
                }
            }
            .frame(width: 18)

            VStack(alignment: .leading, spacing: 2) {
                Text(workflow.name)
                    .fontWeight(.medium)
                    .foregroundStyle(workflow.isEnabled ? .primary : .secondary)
                Text("\(workflow.steps.count) step\(workflow.steps.count == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 3)
    }
}

// MARK: - Editor

struct WorkflowEditor: View {
    @EnvironmentObject private var model: AppModel
    let original: Workflow
    @State private var draft: Workflow

    init(original: Workflow) {
        self.original = original
        _draft = State(initialValue: original)
    }

    private var isDirty: Bool {
        draft.name != original.name
            || draft.summary != original.summary
            || draft.isEnabled != original.isEnabled
            || draft.failurePolicy != original.failurePolicy
            || draft.steps != original.steps
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header
                    stepsSection
                    if let run = model.latestRun(for: draft.id) {
                        LatestRunPanel(run: run, isLive: model.isRunning(draft.id))
                    }
                }
                .padding(24)
                .frame(maxWidth: 820, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            Divider()
            footer
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Name", text: $draft.name)
                .textFieldStyle(.plain)
                .font(.title2.weight(.semibold))
            TextField("What this automation is for", text: $draft.summary, axis: .vertical)
                .textFieldStyle(.plain)
                .foregroundStyle(.secondary)
                .lineLimit(1...3)
            HStack(spacing: 16) {
                Picker("If a step fails", selection: $draft.failurePolicy) {
                    ForEach(FailurePolicy.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .fixedSize()
                Toggle("Enabled", isOn: $draft.isEnabled)
                    .help("Disabled automations can still be run by hand, but triggers won't start them.")
            }
            .controlSize(.small)
        }
    }

    private var stepsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Steps").font(.headline)
                Spacer()
                AddStepMenu { descriptor in
                    draft.steps.append(WorkflowStep(actionID: descriptor.id))
                }
            }
            if draft.steps.isEmpty {
                Text("Add a step to get started. Steps run top to bottom.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 80)
                    .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
            }
            ForEach($draft.steps) { $step in
                let index = draft.steps.firstIndex { $0.id == step.id } ?? 0
                StepCard(
                    number: index + 1,
                    step: $step,
                    canMoveUp: index > 0,
                    canMoveDown: index < draft.steps.count - 1,
                    move: { offset in move(step.id, by: offset) },
                    remove: { removeStep(step.id) }
                )
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if isDirty {
                Text("Unsaved changes").font(.callout).foregroundStyle(.secondary)
                Button("Revert") { draft = original }
            }
            Spacer()
            Button("Save") { save() }
                .keyboardShortcut("s")
                .disabled(!isDirty)
            if model.isRunning(draft.id) {
                Button(role: .destructive) { model.cancelRun(for: draft.id) } label: {
                    Label("Stop", systemImage: "stop.fill")
                }
                .keyboardShortcut(".")
            } else {
                Button {
                    // Always run what's on screen: save first so history
                    // matches the configuration that actually ran.
                    if let saved = save() { model.run(saved) }
                } label: {
                    Label("Run", systemImage: "play.fill")
                }
                .keyboardShortcut("r")
                .buttonStyle(.borderedProminent)
                .disabled(draft.steps.isEmpty)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.bar)
    }

    @discardableResult
    private func save() -> Workflow? {
        guard isDirty else { return original }
        // The list's order is the run order.
        var list = draft
        list.rechainLinearSteps()
        guard let saved = model.save(list) else { return nil }
        draft = saved
        return saved
    }

    private func move(_ stepID: UUID, by offset: Int) {
        guard let index = draft.steps.firstIndex(where: { $0.id == stepID }) else { return }
        let target = index + offset
        guard draft.steps.indices.contains(target) else { return }
        withAnimation(.snappy) { draft.steps.swapAt(index, target) }
    }

    private func removeStep(_ stepID: UUID) {
        withAnimation(.snappy) { draft.steps.removeAll { $0.id == stepID } }
    }
}

private struct AddStepMenu: View {
    @EnvironmentObject private var model: AppModel
    let onAdd: (ActionDescriptor) -> Void

    var body: some View {
        let descriptors = model.registry?.descriptors ?? []
        let categories = Array(Set(descriptors.map(\.category))).sorted()
        Menu {
            ForEach(categories, id: \.self) { category in
                Section(category) {
                    ForEach(descriptors.filter { $0.category == category }) { descriptor in
                        Button {
                            onAdd(descriptor)
                        } label: {
                            Label(descriptor.title, systemImage: descriptor.symbolName)
                        }
                        .disabled(!model.isActionEnabled(descriptor.id))
                    }
                }
            }
        } label: {
            Label("Add Step", systemImage: "plus")
        }
        .fixedSize()
    }
}

// MARK: - Latest run

private struct LatestRunPanel: View {
    let run: WorkflowRun
    let isLive: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(isLive ? "Running now" : "Last run").font(.headline)
                StateBadge(state: run.state)
                Spacer()
                Text("\(run.startedAt, style: .relative) ago")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 6) {
                ForEach(run.steps) { step in
                    StepResultRow(step: step)
                }
            }
            if let error = run.error, run.state != .succeeded {
                Text(error).font(.callout).foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
    }
}

struct StepResultRow: View {
    let step: StepRecord

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            StateIcon(state: step.state).frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(step.label)
                if let error = step.error {
                    Text(error).font(.caption).foregroundStyle(.red)
                } else if let message = step.message {
                    Text(message).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if step.attempts > 1 {
                Pill(text: "\(step.attempts) attempts", tint: .orange)
            }
            Text(Formatting.duration(step.duration))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }
}
