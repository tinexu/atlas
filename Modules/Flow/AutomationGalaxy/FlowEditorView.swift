import AtlasCore
import SwiftUI

/// The Automation Galaxy editor: node library on the left, the graph (2D
/// canvas, or the 3D galaxy) in the middle, the inspector on the right,
/// and problems underneath.
public struct FlowEditorView: View {
    @ObservedObject var model: FlowEditorModel
    @ObservedObject private var live: LiveRunMonitor
    @State private var showLibrary = true
    @State private var showInspector = true
    @State private var showIssues = false
    @State private var testPayload: [PayloadField]?

    struct PayloadField: Identifiable {
        let id = UUID()
        var key: String
        var value: String
    }

    public init(model: FlowEditorModel) {
        self.model = model
        self._live = ObservedObject(wrappedValue: model.live)
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HSplitView {
                if showLibrary {
                    NodeLibraryView(templates: model.templates) { model.add($0) }
                        .frame(minWidth: 190, idealWidth: 220, maxWidth: 300)
                }
                VStack(spacing: 0) {
                    switch model.viewMode {
                    case .canvas: FlowCanvasView(model: model)
                    case .galaxy: GalaxyView(model: model)
                    }
                    if showIssues || model.errorCount > 0 {
                        IssuesList(model: model, isExpanded: $showIssues)
                    }
                }
                .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
                if showInspector {
                    InspectorView(model: model)
                        .frame(minWidth: 280, idealWidth: 320, maxWidth: 420)
                }
            }
        }
        .toolbar { toolbar }
        .sheet(isPresented: Binding(get: { testPayload != nil }, set: { if !$0 { testPayload = nil } })) {
            TestRunSheet(fields: Binding(get: { testPayload ?? [] }, set: { testPayload = $0 }), hasTrigger: model.draft.hasTriggers) { payload in
                model.testRun(payload: payload)
                testPayload = nil
            }
        }
        .alert("Automation", isPresented: Binding(get: { model.message != nil }, set: { if !$0 { model.message = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.message ?? "")
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            TextField("Name", text: Binding(get: { model.draft.name }, set: { name in model.updateWorkflow("Rename") { $0.name = name } }))
                .textFieldStyle(.plain)
                .font(.title3.weight(.semibold))
                .frame(maxWidth: 320)
            if model.draft.hasTriggers {
                Toggle(isOn: Binding(get: { model.draft.isEnabled }, set: { model.setEnabled($0) })) {
                    Text(model.draft.isEnabled ? "Runs automatically" : "Off")
                }
                .toggleStyle(.switch)
                .controlSize(.small)
                .help("When on, its triggers start it automatically. A workflow with problems can be saved as a draft but not turned on.")
            } else {
                Text("Runs when you start it").font(.caption).foregroundStyle(.secondary)
            }
            if model.errorCount > 0 {
                Button { showIssues = true } label: {
                    Label("\(model.errorCount) problem\(model.errorCount == 1 ? "" : "s")", systemImage: "exclamationmark.octagon.fill")
                        .foregroundStyle(.red)
                }
                .buttonStyle(.borderless)
            }
            Spacer()
            runStatus
            if model.isDirty {
                Button("Revert") { model.revert() }
                Button("Save") { model.save() }
                    .keyboardShortcut("s", modifiers: .command)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var runStatus: some View {
        if live.isRunning {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Running…").font(.callout)
                Button("Stop") { model.cancelRun() }
            }
        } else if let run = live.lastRun {
            Label(run.state.title, systemImage: NodeCardView.symbol(for: run.state))
                .font(.caption)
                .foregroundStyle(FlowStyle.color(for: run.state))
                .help("Last run \(run.startedAt.formatted(.relative(presentation: .named))). Colours on the graph show the path it took.")
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem {
            Picker("View", selection: $model.viewMode) {
                ForEach(FlowEditorModel.ViewMode.allCases) { Label($0.title, systemImage: $0.symbol).tag($0) }
            }
            .pickerStyle(.segmented)
            .help("Edit as a 2D graph, or view it as a 3D galaxy")
        }
        ToolbarItem {
            Button {
                testPayload = model.samplePayload().sorted { $0.key < $1.key }.map { PayloadField(key: $0.key, value: $0.value.displayString) }
                if !model.draft.hasTriggers { model.testRun(payload: [:]); testPayload = nil }
            } label: {
                Label("Run Now", systemImage: "play.fill")
            }
            .help(model.draft.hasTriggers ? "Run with sample trigger values you can edit" : "Run this automation now")
            .disabled(live.isRunning || model.draft.steps.isEmpty)
        }
        ToolbarItem {
            Button { model.duplicateSelection() } label: { Label("Duplicate", systemImage: "plus.square.on.square") }
                .keyboardShortcut("d", modifiers: .command)
                .disabled(model.selection.isEmpty)
                .help("Duplicate the selected steps (⌘D)")
        }
        ToolbarItem {
            Button { model.groupSelection() } label: { Label("Group", systemImage: "rectangle.dashed") }
                .disabled(model.selection.count < 2)
                .help("Group the selected steps into a named box")
        }
        ToolbarItem {
            Toggle(isOn: $model.snapToGrid) { Label("Snap to Grid", systemImage: "grid") }
                .help("Snap steps to the grid when you move them")
        }
        ToolbarItem {
            Toggle(isOn: $showLibrary) { Label("Library", systemImage: "sidebar.left") }
        }
        ToolbarItem {
            Toggle(isOn: $showInspector) { Label("Inspector", systemImage: "sidebar.right") }
        }
    }
}

/// Problems, attached to their nodes. Click one to jump to it.
private struct IssuesList: View {
    @ObservedObject var model: FlowEditorModel
    @Binding var isExpanded: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Divider()
            Button {
                isExpanded.toggle()
            } label: {
                HStack {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    Text("Problems (\(model.issues.count))").font(.caption.weight(.semibold))
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            if isExpanded {
                List(model.issues) { issue in
                    HStack {
                        Button {
                            if let node = issue.nodeID { model.focus(on: node) }
                        } label: {
                            Label(issue.message, systemImage: issue.severity == .error ? "exclamationmark.octagon.fill" : "exclamationmark.triangle.fill")
                                .foregroundStyle(issue.severity == .error ? .red : .orange)
                        }
                        .buttonStyle(.plain)
                        if let folder = issue.folderToAdd {
                            Spacer()
                            Button("Add \(FileLocation.displayName(for: folder)) to Orbit") { model.addFolderToOrbit(folder) }
                                .controlSize(.small)
                        }
                    }
                }
                .listStyle(.plain)
                .frame(height: 130)
            }
        }
        .background(.bar)
    }
}

/// "Run now" with a fake trigger payload the user can edit.
private struct TestRunSheet: View {
    @Binding var fields: [FlowEditorView.PayloadField]
    let hasTrigger: Bool
    let run: (ActionParameters) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Run Now").font(.title2.weight(.semibold))
            Text("Runs the automation as it is in the editor, as if its trigger had fired with these values. Steps really run: files really move.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Form {
                ForEach($fields) { $field in
                    TextField("{{trigger.\(field.key)}}", text: $field.value)
                }
            }
            .formStyle(.grouped)
            .frame(minHeight: 140)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Run") {
                    var payload: ActionParameters = [:]
                    for field in fields {
                        payload[field.key] = Double(field.value).map(ActionValue.number) ?? .string(field.value)
                    }
                    run(payload)
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 480)
    }
}
