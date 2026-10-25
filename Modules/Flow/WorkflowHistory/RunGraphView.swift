import AtlasCore
import SwiftUI

/// A past run drawn on its workflow's graph: each node in that run's state,
/// the connections the run followed highlighted. Click a node to see its
/// inputs, outputs, error and timing; a failed node offers "Fix".
public struct RunGraphView: View {
    let run: WorkflowRun
    let onFix: (UUID) -> Void
    @StateObject private var model: FlowEditorModel

    public init?(run: WorkflowRun, core: AtlasCore, onFix: @escaping (UUID) -> Void) {
        guard let workflow = try? core.store.workflow(id: run.workflowID), !workflow.steps.isEmpty else { return nil }
        self.run = run
        self.onFix = onFix
        _model = StateObject(wrappedValue: FlowEditorModel(workflow: workflow, core: core))
    }

    private var states: [UUID: RunState] {
        Dictionary(run.steps.map { ($0.nodeID, $0.state) }, uniquingKeysWith: { a, _ in a })
    }

    public var body: some View {
        HSplitView {
            FlowCanvasView(model: model, isEditable: false, states: states, taken: Set(run.path))
                .frame(minWidth: 360, minHeight: 260)
            Group {
                if let id = model.selection.first, let step = run.steps.first(where: { $0.nodeID == id }) {
                    NodeRunDetail(step: step, onFix: { onFix(id) })
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Click a step to see what it received and produced.")
                            .font(.callout).foregroundStyle(.secondary)
                        if !run.triggerPayload.isEmpty {
                            Text("Trigger reported").font(.headline).padding(.top, 8)
                            ValuesList(values: run.triggerPayload)
                        }
                        Spacer()
                    }
                    .padding(14)
                }
            }
            .frame(minWidth: 240, idealWidth: 300, maxWidth: 420)
        }
        .onAppear {
            // Start on the failed step, if any.
            if let failed = run.steps.first(where: { $0.state == .failed }) { model.selection = [failed.nodeID] }
        }
    }
}

/// One node's record from a run.
public struct NodeRunDetail: View {
    let step: StepRecord
    let onFix: (() -> Void)?

    public init(step: StepRecord, onFix: (() -> Void)? = nil) {
        self.step = step
        self.onFix = onFix
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Image(systemName: NodeCardView.symbol(for: step.state)).foregroundStyle(FlowStyle.color(for: step.state))
                    Text(step.label).font(.headline)
                    Spacer()
                    if step.state == .failed, let onFix {
                        Button("Fix", action: onFix)
                            .help("Open this step in the editor")
                    }
                }
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                    GridRow { Text("State").foregroundStyle(.secondary); Text(step.state.title) }
                    if let started = step.startedAt {
                        GridRow { Text("Started").foregroundStyle(.secondary); Text(started.formatted(date: .omitted, time: .standard)) }
                    }
                    if let duration = step.duration {
                        GridRow { Text("Took").foregroundStyle(.secondary); Text(duration < 1 ? "\(Int(duration * 1000)) ms" : String(format: "%.1f s", duration)) }
                    }
                    if step.attempts > 1 {
                        GridRow { Text("Attempts").foregroundStyle(.secondary); Text("\(step.attempts)") }
                    }
                }
                .font(.callout)
                if let message = step.message {
                    Text(message).font(.callout).textSelection(.enabled)
                }
                if let error = step.error {
                    Label(error, systemImage: "exclamationmark.octagon")
                        .foregroundStyle(.red)
                        .font(.callout)
                        .textSelection(.enabled)
                }
                if !step.inputs.isEmpty {
                    Text("Received").font(.subheadline.weight(.semibold))
                    ValuesList(values: step.inputs)
                }
                if !step.output.isEmpty {
                    Text("Produced").font(.subheadline.weight(.semibold))
                    ValuesList(values: step.output)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct ValuesList: View {
    let values: ActionParameters

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(values.keys.sorted(), id: \.self) { key in
                HStack(alignment: .firstTextBaseline) {
                    Text(key).font(.caption.monospaced()).foregroundStyle(.secondary).frame(minWidth: 70, alignment: .leading)
                    Text(values[key]?.displayString ?? "").font(.caption).textSelection(.enabled)
                }
            }
        }
    }
}

// MARK: - Filters

/// What Run History shows.
public struct RunFilters: Equatable {
    public enum Range: String, CaseIterable, Identifiable {
        case today = "Today", week = "Last 7 days", month = "Last 30 days", all = "All time", custom = "Dates…"
        public var id: Self { self }
    }

    public enum TriggerFilter: Hashable {
        case any
        case manual
        case automatic
        case spaces
        case trigger(String)
    }

    public var workflowID: UUID?
    public var trigger: TriggerFilter = .any
    public var state: RunState?
    public var range: Range = .all
    public var from = Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? Date()
    public var to = Date()

    public init() {}

    public var isFiltering: Bool { self != RunFilters() }

    public var query: RunQuery {
        var query = RunQuery(workflowID: workflowID)
        switch trigger {
        case .any: break
        case .manual: query.trigger = RunTrigger.manual
        case .automatic: query.trigger = RunTrigger.automaticPrefix + "*"
        case .spaces: query.trigger = "space.*"
        case .trigger(let type): query.trigger = RunTrigger.automatic(type)
        }
        if let state { query.states = [state] }
        let calendar = Calendar.current
        switch range {
        case .today: query.from = calendar.startOfDay(for: Date())
        case .week: query.from = calendar.date(byAdding: .day, value: -7, to: Date())
        case .month: query.from = calendar.date(byAdding: .day, value: -30, to: Date())
        case .all: break
        case .custom:
            query.from = calendar.startOfDay(for: from)
            query.to = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: to))
        }
        return query
    }
}

/// Filters for Run History: workflow, trigger type, state, date range.
public struct RunFilterBar: View {
    @Binding var filters: RunFilters
    let workflows: [Workflow]

    public init(filters: Binding<RunFilters>, workflows: [Workflow]) {
        self._filters = filters
        self.workflows = workflows
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Picker("Automation", selection: $filters.workflowID) {
                    Text("All automations").tag(UUID?.none)
                    ForEach(workflows) { Text($0.name).tag(Optional($0.id)) }
                }
                Picker("State", selection: $filters.state) {
                    Text("Any result").tag(RunState?.none)
                    ForEach([RunState.succeeded, .partiallySucceeded, .failed, .skipped, .canceled], id: \.self) {
                        Text($0.title).tag(Optional($0))
                    }
                }
            }
            HStack {
                Picker("Started by", selection: $filters.trigger) {
                    Text("Anything").tag(RunFilters.TriggerFilter.any)
                    Text("By hand").tag(RunFilters.TriggerFilter.manual)
                    Text("Any trigger").tag(RunFilters.TriggerFilter.automatic)
                    Text("Spaces").tag(RunFilters.TriggerFilter.spaces)
                    Divider()
                    ForEach(TriggerCatalog.all) { Text($0.title).tag(RunFilters.TriggerFilter.trigger($0.id)) }
                }
                Picker("When", selection: $filters.range) {
                    ForEach(RunFilters.Range.allCases) { Text($0.rawValue).tag($0) }
                }
            }
            if filters.range == .custom {
                HStack {
                    DatePicker("From", selection: $filters.from, displayedComponents: .date)
                    DatePicker("To", selection: $filters.to, displayedComponents: .date)
                }
            }
            if filters.isFiltering {
                Button("Clear Filters") { filters = RunFilters() }.buttonStyle(.link).font(.caption)
            }
        }
        .labelsHidden()
        .controlSize(.small)
    }
}
