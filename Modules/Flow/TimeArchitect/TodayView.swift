import AtlasCore
import SwiftUI

/// Today (spec 8): what's next, focus planned vs done, what ran, what needs
/// attention. Everything links to where it can be dealt with.
public struct TodayView: View {
    @ObservedObject var model: TimeArchitectModel
    let openRun: (UUID) -> Void
    let openReviews: () -> Void
    let openTimeline: () -> Void
    let openWorkflow: (UUID) -> Void
    @State private var explanation: String?

    public init(model: TimeArchitectModel, openRun: @escaping (UUID) -> Void, openReviews: @escaping () -> Void,
                openTimeline: @escaping () -> Void, openWorkflow: @escaping (UUID) -> Void) {
        self.model = model
        self.openRun = openRun
        self.openReviews = openReviews
        self.openTimeline = openTimeline
        self.openWorkflow = openWorkflow
    }

    public var body: some View {
        let _ = model.revision
        let overview = DailyOverview.make(store: model.core.store, schedule: model.time.schedule, events: model.core.events)
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text(Date().formatted(.dateTime.weekday(.wide).month(.wide).day())).font(.largeTitle.weight(.semibold))
                Text(overview.text).foregroundStyle(.secondary)

                HStack(alignment: .top, spacing: 14) {
                    card("Focus", symbol: "scope") {
                        let planned = overview.plannedFocus, done = overview.completedFocus
                        Text("\(Int(done / 60)) of \(Int(planned / 60)) min").font(.title2.weight(.semibold)).monospacedDigit()
                        ProgressView(value: planned > 0 ? min(1, done / planned) : 0)
                        if let session = model.focus {
                            HStack {
                                Text(session.title)
                                Spacer()
                                if session.state == .running {
                                    Text(timerInterval: Date()...session.endsAt(from: Date()), countsDown: true).monospacedDigit()
                                } else {
                                    Text("Paused").foregroundStyle(.secondary)
                                }
                            }
                            .font(.callout)
                        } else {
                            Button("Start 25 min Focus") { model.startFocus(minutes: 25) }.controlSize(.small)
                        }
                    }
                    card("Automations", symbol: "bolt.horizontal.circle") {
                        Text("\(overview.runsToday) run\(overview.runsToday == 1 ? "" : "s") today").font(.title2.weight(.semibold))
                        Text(overview.failures.isEmpty ? "Nothing needs attention." : "\(overview.failures.count) need attention")
                            .foregroundStyle(overview.failures.isEmpty ? Color.secondary : .orange)
                    }
                    card("Files & Mac", symbol: "tray.full") {
                        Button { openReviews() } label: {
                            Text("\(overview.reviewCount) file\(overview.reviewCount == 1 ? "" : "s") waiting for review")
                        }
                        .buttonStyle(.link)
                        .disabled(overview.reviewCount == 0)
                        ForEach(overview.healthWarnings, id: \.self) { Label($0, systemImage: "exclamationmark.triangle").font(.caption) }
                        if overview.healthWarnings.isEmpty { Text("No health warnings today.").foregroundStyle(.secondary) }
                    }
                }

                GroupBox {
                    VStack(alignment: .leading, spacing: 8) {
                        if overview.upcoming.isEmpty {
                            Text("Nothing else planned today.").foregroundStyle(.secondary)
                        }
                        ForEach(overview.upcoming) { occurrence in
                            HStack(spacing: 10) {
                                RoundedRectangle(cornerRadius: 2).fill(model.color(for: occurrence.block)).frame(width: 4, height: 28)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(occurrence.block.title).fontWeight(.medium)
                                    Text("\(occurrence.start.formatted(date: .omitted, time: .shortened)) – \(occurrence.end.formatted(date: .omitted, time: .shortened))\(model.space(occurrence.block.spaceID).map { " · \($0.name)" } ?? "")")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if occurrence.start <= Date() { Text("Now").font(.caption.weight(.bold)).foregroundStyle(.green) }
                            }
                        }
                        Button("Open Time Architect") { openTimeline() }.buttonStyle(.link)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                } label: { Label("Coming up", systemImage: "calendar.day.timeline.left") }

                if !overview.failures.isEmpty {
                    GroupBox {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(overview.failures.prefix(8)) { run in
                                HStack {
                                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(run.workflowName)
                                        Text(run.error ?? run.steps.first { $0.state == .failed }?.error ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                    Spacer()
                                    Button("Why?") {
                                        explanation = WorkflowExplainer.explainFailure(run, workflow: try? model.core.store.workflow(id: run.workflowID))
                                    }
                                    Button("Fix") { openWorkflow(run.workflowID) }
                                    Button("Details") { openRun(run.id) }
                                }
                                .controlSize(.small)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    } label: { Label("Needs attention", systemImage: "wrench.and.screwdriver") }
                }

                GroupBox {
                    let morning = (try? model.core.store.workflows())?.first { $0.name == "Morning Summary" }
                    HStack {
                        Text("A notification each morning with this summary, as an ordinary workflow you can edit.")
                            .font(.callout).foregroundStyle(.secondary)
                        Spacer()
                        if let morning {
                            Toggle("On", isOn: Binding(get: { morning.isEnabled }, set: { on in
                                var updated = morning
                                updated.isEnabled = on
                                _ = try? model.core.save(updated)
                                model.reload()
                            }))
                            .toggleStyle(.switch)
                            Button("Edit") { openWorkflow(morning.id) }
                        }
                    }
                } label: { Label("Morning summary", systemImage: "sun.max") }
            }
            .padding(24)
            .frame(maxWidth: 900, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Today")
        .sheet(item: Binding(get: { explanation.map(ExplanationText.init) }, set: { explanation = $0?.text })) { item in
            ExplanationSheet(title: "Why did this fail?", text: item.text)
        }
    }

    private func card<Content: View>(_ title: String, symbol: String, @ViewBuilder content: () -> Content) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 6) { content() }
                .frame(maxWidth: .infinity, minHeight: 90, alignment: .topLeading)
        } label: { Label(title, systemImage: symbol) }
    }
}

struct ExplanationText: Identifiable {
    let text: String
    var id: String { text }
}

/// Plain-language explanation, from the graph or a run record.
public struct ExplanationSheet: View {
    let title: String
    let text: String
    @Environment(\.dismiss) private var dismiss

    public init(title: String, text: String) {
        self.title = title
        self.text = text
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            ScrollView {
                Text(text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 520, height: 380)
    }
}
