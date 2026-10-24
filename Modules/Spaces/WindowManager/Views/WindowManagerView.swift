import AtlasCore
import AtlasSpaces
import SwiftUI

/// The Spatial Window Manager: saved layouts on the left; the selected
/// layout as a 3D miniature or flat 2D diagram of the real displays, with
/// its rules as an editable table underneath; snapshots below the list.
public struct WindowManagerView: View {
    @ObservedObject var model: WindowManagerModel
    let spaceName: (UUID) -> String?
    let openPermissions: () -> Void
    @State private var pendingDeletion: WindowLayout?
    @State private var showingResult = false

    public init(model: WindowManagerModel, spaceName: @escaping (UUID) -> String?, openPermissions: @escaping () -> Void) {
        self.model = model
        self.spaceName = spaceName
        self.openPermissions = openPermissions
    }

    public var body: some View {
        HSplitView {
            sidebar
                .frame(minWidth: 220, idealWidth: 260, maxWidth: 340)
            editor
                .frame(minWidth: 520, maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle("Windows")
        .toolbar { toolbar }
        .task { await model.refreshDisplays() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await model.refreshDisplays() }
        }
        .confirmationDialog(
            "Delete “\(pendingDeletion?.name ?? "")”?",
            isPresented: Binding(get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } }),
            presenting: pendingDeletion
        ) { layout in
            Button("Delete Layout", role: .destructive) { model.delete(layout) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Spaces using it will stop arranging windows. Your windows aren't affected.")
        }
        .alert("Something went wrong", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Layouts").font(.headline)
                        Spacer()
                        Button { model.newLayout() } label: { Image(systemName: "plus") }
                            .buttonStyle(.borderless)
                            .help("New empty layout")
                    }
                    if model.layouts.isEmpty {
                        Text("Arrange your windows, then choose Capture Current Windows to save them as a layout.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(model.layouts) { layout in
                        layoutRow(layout)
                    }
                }
                Divider()
                SnapshotListView(model: model, spaceName: spaceName)
            }
            .padding(14)
        }
    }

    private func layoutRow(_ layout: WindowLayout) -> some View {
        let isSelected = model.selectedLayoutID == layout.id
        return Button {
            model.selectedLayoutID = layout.id
        } label: {
            HStack {
                Image(systemName: "macwindow.on.rectangle")
                VStack(alignment: .leading, spacing: 1) {
                    Text(layout.name).fontWeight(.medium)
                    Text("\(layout.rules.count) window\(layout.rules.count == 1 ? "" : "s")")
                        .font(.caption)
                        .foregroundStyle(isSelected ? .primary : .secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
            .background(isSelected ? Color.accentColor.opacity(0.2) : .clear, in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Duplicate") { model.duplicate(layout) }
            Button("Delete…", role: .destructive) { pendingDeletion = layout }
        }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    // MARK: - Editor

    @ViewBuilder
    private var editor: some View {
        VStack(spacing: 0) {
            if !model.isTrusted {
                permissionBanner
            }
            if let draft = model.draft {
                header(draft)
                Divider()
                VSplitView {
                    canvas(draft)
                        .frame(minHeight: 240, idealHeight: 340)
                    VStack(spacing: 0) {
                        rulesHeader
                        RuleTable(model: model)
                    }
                    .frame(minHeight: 200)
                }
                if let run = model.lastRun {
                    resultBar(run)
                }
            } else {
                ContentUnavailableView {
                    Label("No layout selected", systemImage: "macwindow.on.rectangle")
                } description: {
                    Text("Arrange your windows the way you like, then capture them as a layout. Spaces can apply a layout when they're activated.")
                } actions: {
                    Button("Capture Current Windows") { model.captureCurrentWindows() }
                        .buttonStyle(.borderedProminent)
                        .disabled(!model.isTrusted || model.isBusy)
                }
            }
        }
    }

    private var permissionBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text("ATLAS needs Accessibility permission to read and move windows. You can still edit layouts.")
                .font(.callout)
            Spacer()
            Button("Open Permissions", action: openPermissions)
        }
        .padding(10)
        .background(Color.orange.opacity(0.12))
    }

    private func header(_ draft: WindowLayout) -> some View {
        HStack(spacing: 10) {
            TextField("Layout name", text: Binding(
                get: { model.draft?.name ?? "" },
                set: { model.draft?.name = $0 }
            ))
            .textFieldStyle(.plain)
            .font(.title2.weight(.semibold))
            Spacer()
            if let profile = draft.displayProfile, !profile.matches(model.displays) {
                Label("Made for \(profile.name)", systemImage: "display.2")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help("Windows on displays that aren't connected go to the main display, keeping their relative position.")
            }
            if model.isDirty {
                Button("Revert") { model.revert() }
                Button("Save") { model.save() }
                    .keyboardShortcut("s", modifiers: .command)
            }
        }
        .padding(12)
    }

    @ViewBuilder
    private func canvas(_ draft: WindowLayout) -> some View {
        let selection = Binding(get: { model.selectedRuleID }, set: { model.selectedRuleID = $0 })
        switch model.viewMode {
        case .world:
            MonitorWorldView(canvas: model.canvas, rules: draft.rules, selection: selection, onCommit: model.updateRule)
        case .flat:
            MonitorDiagramView(canvas: model.canvas, rules: draft.rules, selection: selection, onCommit: model.updateRule)
                .background(Color(nsColor: .windowBackgroundColor))
        }
    }

    private var rulesHeader: some View {
        HStack {
            Text("Windows").font(.headline)
            Spacer()
            Button {
                if let (id, name) = AppIcons.chooseApplication() { model.addRule(bundleID: id, appName: name) }
            } label: {
                Label("Add App…", systemImage: "plus")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func resultBar(_ run: WorkflowRun) -> some View {
        let step = run.steps.first
        return HStack(spacing: 8) {
            Image(systemName: run.state == .succeeded ? "checkmark.circle.fill"
                  : run.state == .partiallySucceeded ? "exclamationmark.circle.fill" : "xmark.octagon.fill")
                .foregroundStyle(run.state == .succeeded ? .green : run.state == .partiallySucceeded ? .orange : .red)
            Text(step?.message ?? step?.error ?? run.state.title)
                .lineLimit(1)
            Spacer()
            if step?.output["details"] != nil || step?.error != nil {
                Button("Details") { showingResult = true }
                    .popover(isPresented: $showingResult) {
                        ScrollView {
                            Text(step?.output["details"]?.stringValue ?? step?.error ?? "")
                                .font(.callout)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding()
                        }
                        .frame(width: 420, height: 260)
                    }
            }
        }
        .font(.callout)
        .padding(10)
        .background(.bar)
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem {
            Picker("View", selection: $model.viewMode) {
                ForEach(WindowManagerModel.ViewMode.allCases) { Label($0.title, systemImage: $0.symbol).tag($0) }
            }
            .pickerStyle(.segmented)
            .help("Show the displays as a 3D miniature or a flat diagram")
        }
        ToolbarItem {
            Button { model.captureCurrentWindows() } label: {
                Label("Capture Current Windows", systemImage: "camera.viewfinder")
            }
            .help("Fill this layout from where your windows are now")
            .disabled(!model.isTrusted || model.isBusy)
        }
        ToolbarItem {
            Button { model.showPreview() } label: {
                Label("Preview", systemImage: "eye")
            }
            .help("Briefly outline on screen where each window will go, without moving anything")
            .disabled(model.draft?.rules.isEmpty ?? true)
        }
        ToolbarItem {
            Button { model.apply() } label: {
                Label("Apply", systemImage: "play.fill")
            }
            .help("Move windows into this layout now")
            .disabled(model.draft?.rules.isEmpty ?? true || model.isBusy)
        }
    }
}
