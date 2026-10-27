import AtlasCore
import AtlasFlow
import SwiftUI

/// Every run, newest first, with a per-step breakdown (spec 5.8).
struct RunHistoryView: View {
    @EnvironmentObject private var model: AppModel
    @State private var selectedRunID: UUID?

    private var selectedRun: WorkflowRun? {
        model.runs.first { $0.id == selectedRunID }
    }

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
            RunFilterBar(filters: $model.runFilters, workflows: model.workflows)
                .padding(10)
            Divider()
            List(selection: $selectedRunID) {
                ForEach(model.runs) { run in
                    HStack(spacing: 10) {
                        StateIcon(state: run.state).frame(width: 18)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(run.workflowName).fontWeight(.medium)
                            Text("\(run.startedAt.formatted(date: .abbreviated, time: .shortened)) · \(Formatting.trigger(run.trigger))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(Formatting.duration(run.duration))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)
                }
            }
            .listStyle(.inset)
            .overlay {
                if model.runs.isEmpty {
                    ContentUnavailableView(
                        model.runFilters.isFiltering ? "No matching runs" : "No runs yet",
                        systemImage: "clock",
                        description: Text(model.runFilters.isFiltering
                                          ? "Try clearing some filters."
                                          : "Run an automation and its results will appear here.")
                    )
                }
            }
            }
            .frame(minWidth: 280, idealWidth: 320, maxWidth: 400)

            Group {
                if let run = selectedRun {
                    RunDetail(run: run)
                } else {
                    ContentUnavailableView("Select a run", systemImage: "list.bullet.rectangle")
                }
            }
            .frame(minWidth: 460, maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle("Run History")
        .toolbar {
            Button { model.reloadRuns() } label: { Label("Refresh", systemImage: "arrow.clockwise") }
        }
        .onAppear {
            if let focused = model.focusedRunID {
                selectedRunID = focused
                model.focusedRunID = nil
            }
            if selectedRunID == nil { selectedRunID = model.runs.first?.id }
        }
        .onChange(of: model.focusedRunID) { _, focused in
            guard let focused else { return }
            selectedRunID = focused
            model.focusedRunID = nil
        }
    }
}

private struct RunDetail: View {
    @EnvironmentObject private var model: AppModel
    let run: WorkflowRun
    @State private var showGraph = true
    @State private var explanation: String?

    var body: some View {
        VStack(spacing: 0) {
            if let core = model.core, showGraph, let graph = RunGraphView(run: run, core: core, onFix: { node in
                model.openForFixing(workflowID: run.workflowID, nodeID: node)
            }) {
                header
                Divider()
                graph.id(run.id)
            } else {
                stepList
            }
        }
        .sheet(item: Binding(get: { explanation.map(TextItem.init) }, set: { explanation = $0?.text })) { item in
            ExplanationSheet(title: "Why did this run fail?", text: item.text)
        }
    }

    @ViewBuilder
    private var whyButton: some View {
        if [.failed, .partiallySucceeded, .skipped, .canceled].contains(run.state) {
            Button("Why Did This Fail?") {
                explanation = WorkflowExplainer.explainFailure(run, workflow: model.workflow(id: run.workflowID))
            }
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(run.workflowName).font(.title3.weight(.semibold))
            StateBadge(state: run.state)
            Text("\(run.startedAt.formatted(date: .abbreviated, time: .standard)) · \(Formatting.trigger(run.trigger)) · \(Formatting.duration(run.duration))")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            whyButton
            UndoButton(run: run)
            Button("Show Steps") { showGraph = false }
        }
        .padding(12)
    }

    private var stepList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .firstTextBaseline) {
                    Text(run.workflowName).font(.title2.weight(.semibold))
                    StateBadge(state: run.state)
                    Spacer()
                    whyButton
                    UndoButton(run: run)
                    if model.core.flatMap({ try? $0.store.workflow(id: run.workflowID) }) != nil {
                        Button("Show Graph") { showGraph = true }
                    }
                    if let workflow = model.workflow(id: run.workflowID) {
                        Button("Open Automation") {
                            model.selectedWorkflowID = workflow.id
                            model.section = .automations
                        }
                    }
                }

                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                    GridRow {
                        Text("Started").foregroundStyle(.secondary)
                        Text(run.startedAt.formatted(date: .complete, time: .standard))
                    }
                    GridRow {
                        Text("Duration").foregroundStyle(.secondary)
                        Text(Formatting.duration(run.duration))
                    }
                    GridRow {
                        Text("Started by").foregroundStyle(.secondary)
                        Text(Formatting.trigger(run.trigger))
                    }
                    GridRow {
                        Text("Result").foregroundStyle(.secondary)
                        Text(run.summaryLine)
                    }
                    if !run.triggerPayload.isEmpty {
                        GridRow {
                            Text("Trigger reported").foregroundStyle(.secondary)
                            Text(run.triggerPayload.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value.displayString)" }.joined(separator: " · "))
                                .textSelection(.enabled)
                        }
                    }
                }
                .font(.callout)

                if let error = run.error, run.state != .succeeded {
                    Label(error, systemImage: "info.circle")
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(run.state.tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text("Steps").font(.headline)
                    ForEach(run.steps) { step in
                        StepResultRow(step: step)
                        // Per-window results and similar lists, one per line.
                        if let details = step.output["details"]?.stringValue, !details.isEmpty {
                            VStack(alignment: .leading, spacing: 3) {
                                ForEach(Array(details.split(separator: "\n").enumerated()), id: \.offset) { _, line in
                                    Label(String(line), systemImage: line.hasPrefix("Couldn't") ? "xmark.circle" : "checkmark.circle")
                                        .foregroundStyle(line.hasPrefix("Couldn't") ? Color.orange : Color.secondary)
                                }
                            }
                            .font(.callout)
                            .padding(.leading, 24)
                            .textSelection(.enabled)
                        }
                        let values = step.output.filter { $0.key != "details" }
                        if !values.isEmpty {
                            Text(values.sorted { $0.key < $1.key }
                                .map { "\($0.key): \($0.value.displayString)" }
                                .joined(separator: "   "))
                                .font(.caption.monospaced())
                                .foregroundStyle(.tertiary)
                                .padding(.leading, 24)
                                .textSelection(.enabled)
                        }
                        Divider()
                    }
                }
            }
            .padding(24)
        }
    }
}

/// Reverses the file changes a run made, when that's still possible.
private struct UndoButton: View {
    @EnvironmentObject private var model: AppModel
    let run: WorkflowRun
    @State private var confirming = false

    var body: some View {
        let operations = model.undoableOperations(in: run)
        if !operations.isEmpty && run.state.isTerminal {
            Button {
                confirming = true
            } label: {
                Label(operations.count == 1 ? "Undo File Change" : "Undo \(operations.count) File Changes", systemImage: "arrow.uturn.backward")
            }
            .help(operations.map(\.summary).joined(separator: "\n"))
            .confirmationDialog("Undo these changes?", isPresented: $confirming) {
                Button("Undo") { model.undoFileChanges(of: run) }
            } message: {
                Text(operations.map(\.summary).joined(separator: "\n") + "\n\nAnything changed since then is left alone and reported.")
            }
        }
    }
}
