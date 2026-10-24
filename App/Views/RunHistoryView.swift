import AtlasCore
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
            .frame(minWidth: 260, idealWidth: 300, maxWidth: 380)
            .overlay {
                if model.runs.isEmpty {
                    ContentUnavailableView(
                        "No runs yet",
                        systemImage: "clock",
                        description: Text("Run an automation and its results will appear here.")
                    )
                }
            }

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
            if selectedRunID == nil { selectedRunID = model.runs.first?.id }
        }
    }
}

private struct RunDetail: View {
    @EnvironmentObject private var model: AppModel
    let run: WorkflowRun

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .firstTextBaseline) {
                    Text(run.workflowName).font(.title2.weight(.semibold))
                    StateBadge(state: run.state)
                    Spacer()
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
