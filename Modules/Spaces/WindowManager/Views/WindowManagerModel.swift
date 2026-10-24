import AppKit
import AtlasCore
import AtlasSpaces
import SwiftUI

/// UI state for the Spatial Window Manager. Owns no window logic: applying,
/// capturing and snapshots go through the engine's registered actions, so
/// they get permission checks and appear in Run History.
@MainActor
public final class WindowManagerModel: ObservableObject {
    public enum ViewMode: String, CaseIterable, Identifiable {
        case world, flat
        public var id: Self { self }
        public var title: String { self == .world ? "3D" : "2D" }
        public var symbol: String { self == .world ? "cube" : "rectangle.split.2x1" }
    }

    @Published public private(set) var layouts: [WindowLayout] = []
    @Published public private(set) var snapshots: [SessionSnapshot] = []
    @Published public private(set) var displays: [DisplayInfo] = []
    @Published public private(set) var isTrusted = false
    @Published public var selectedLayoutID: UUID? {
        didSet { if selectedLayoutID != oldValue { loadDraft() } }
    }
    /// The layout being edited; saved explicitly.
    @Published public var draft: WindowLayout?
    @Published public var selectedRuleID: UUID?
    @Published public var viewMode: ViewMode = .world {
        didSet { try? core?.store.setPreference(viewMode.rawValue, for: Self.viewModeKey) }
    }
    @Published public private(set) var isBusy = false
    /// The outcome of the last apply, capture or restore, as shown to the user.
    @Published public private(set) var lastRun: WorkflowRun?
    @Published public var errorMessage: String?

    private let core: AtlasCore?
    private var eventTask: Task<Void, Never>?
    private let preview = LayoutPreviewOverlay()
    private static let viewModeKey = "windows.viewMode"
    /// Run history trigger for things started here.
    public static let trigger = "window-manager"

    public init(core: AtlasCore?) {
        self.core = core
        if let mode = (try? core?.store.preference(Self.viewModeKey, as: String.self)).flatMap({ $0 }).flatMap(ViewMode.init) {
            viewMode = mode
        }
        reload()
        Task { await refreshDisplays() }
        listenForEvents()
    }

    public var isAvailable: Bool { core != nil }
    public var canvas: LayoutCanvas { LayoutCanvas(displays: displays) }
    public var isDirty: Bool {
        guard let draft else { return false }
        return layouts.first { $0.id == draft.id } != draft
    }

    // MARK: - Loading

    public func reload() {
        guard let store = core?.store else { return }
        do {
            layouts = try store.windowLayouts()
            snapshots = try store.snapshots(limit: 100)
            if selectedLayoutID == nil || !layouts.contains(where: { $0.id == selectedLayoutID }) {
                if draft.map({ d in !layouts.contains { $0.id == d.id } }) != true {
                    selectedLayoutID = layouts.first?.id
                }
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func refreshDisplays() async {
        guard let core else { return }
        displays = await core.windows.displays()
        isTrusted = core.windows.adapter.isTrusted
    }

    private func loadDraft() {
        draft = layouts.first { $0.id == selectedLayoutID }
        selectedRuleID = draft?.rules.first?.id
    }

    private func listenForEvents() {
        guard let core else { return }
        let stream = core.events.stream()
        eventTask = Task { [weak self] in
            for await event in stream {
                guard let self else { return }
                switch event.name {
                case AtlasEvent.Name.displayChanged:
                    await self.refreshDisplays()
                case AtlasEvent.Name.windowLayoutSaved, AtlasEvent.Name.windowLayoutDeleted,
                     AtlasEvent.Name.snapshotSaved, AtlasEvent.Name.snapshotRestored:
                    self.reloadKeepingDraft()
                default:
                    break
                }
            }
        }
    }

    /// Reloads lists without throwing away unsaved edits.
    private func reloadKeepingDraft() {
        let edited = isDirty ? draft : nil
        reload()
        if let edited { draft = edited } else { loadDraft() }
    }

    // MARK: - Editing

    public func newLayout() {
        let layout = WindowLayout(name: uniqueName("New Layout"), displayProfile: DisplayProfile(displays: displays))
        saveDraft(layout)
    }

    public func duplicate(_ layout: WindowLayout) {
        var copy = layout
        copy.id = UUID()
        copy.name = uniqueName(layout.name + " Copy")
        copy.rules = layout.rules.map { var rule = $0; rule.id = UUID(); return rule }
        copy.createdAt = Date()
        saveDraft(copy)
    }

    public func delete(_ layout: WindowLayout) {
        guard let core else { return }
        do {
            try core.windows.deleteLayout(id: layout.id)
            if selectedLayoutID == layout.id { selectedLayoutID = nil }
            reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func save() {
        guard let draft else { return }
        saveDraft(draft)
    }

    public func revert() {
        loadDraft()
    }

    private func saveDraft(_ layout: WindowLayout) {
        guard let core else { return }
        do {
            let saved = try core.windows.save(layout)
            reload()
            selectedLayoutID = saved.id
            draft = saved
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func updateRule(_ rule: WindowRule) {
        guard let index = draft?.rules.firstIndex(where: { $0.id == rule.id }) else { return }
        draft?.rules[index] = rule
    }

    public func addRule(bundleID: String, appName: String) {
        guard draft != nil else { return }
        let rule = WindowRule(bundleID: bundleID, appName: appName, preset: .centered, zOrder: draft?.rules.count ?? 0)
        draft?.rules.append(rule)
        selectedRuleID = rule.id
    }

    public func removeRule(_ id: UUID) {
        draft?.rules.removeAll { $0.id == id }
        if selectedRuleID == id { selectedRuleID = draft?.rules.first?.id }
    }

    /// Moves a rule one step toward the front (lower z-order) or back.
    public func reorder(_ id: UUID, toFront: Bool) {
        guard var rules = draft?.rules else { return }
        // Normalize to 0…n-1 in current stacking order first.
        let stacked = rules.indices.sorted { rules[$0].zOrder < rules[$1].zOrder }
        for (z, index) in stacked.enumerated() { rules[index].zOrder = z }
        guard let index = rules.firstIndex(where: { $0.id == id }) else { return }
        let target = rules[index].zOrder + (toFront ? -1 : 1)
        guard let other = rules.firstIndex(where: { $0.zOrder == target }) else { return }
        rules[other].zOrder = rules[index].zOrder
        rules[index].zOrder = target
        draft?.rules = rules
    }

    private func uniqueName(_ base: String) -> String {
        let names = Set(layouts.map { $0.name.lowercased() })
        if !names.contains(base.lowercased()) { return base }
        var n = 2
        while names.contains("\(base) \(n)".lowercased()) { n += 1 }
        return "\(base) \(n)"
    }

    // MARK: - Engine actions

    /// Fills the selected layout (or a new one) from the real desktop.
    public func captureCurrentWindows() {
        guard core != nil else { return }
        let name = draft?.name ?? uniqueName("Captured Layout")
        if let draft, isDirty { saveDraft(draft) }
        invoke(CaptureWindowLayoutAction.id, ["name": .string(name)]) { [weak self] run in
            guard let self, run.state == .succeeded, let id = run.steps.first?.output["layoutId"]?.stringValue.flatMap(UUID.init) else { return }
            self.reload()
            self.selectedLayoutID = nil
            self.selectedLayoutID = id
        }
    }

    /// Saves pending edits, then applies the layout through the engine.
    public func apply() {
        guard let draft else { return }
        if isDirty { saveDraft(draft) }
        invoke(ApplyWindowLayoutAction.id, ["layout": .string(draft.id.uuidString)])
    }

    /// Briefly outlines on screen where each window will go. Moves nothing.
    public func showPreview() {
        guard let draft else { return }
        let targets = draft.rules.compactMap { rule -> LayoutPreviewOverlay.Target? in
            guard let frame = canvas.frame(of: rule) else { return nil }
            return LayoutPreviewOverlay.Target(frame: frame, title: rule.displayName, bundleID: rule.bundleID)
        }
        preview.show(targets, displays: displays)
    }

    public func saveSnapshot(named name: String?) {
        var parameters: ActionParameters = [:]
        if let name, !name.trimmingCharacters(in: .whitespaces).isEmpty { parameters["name"] = .string(name) }
        invoke(SaveSnapshotAction.id, parameters)
    }

    public func restore(_ snapshot: SessionSnapshot) {
        invoke(RestoreSnapshotAction.id, ["snapshot": .string(snapshot.id.uuidString)])
    }

    public func delete(_ snapshot: SessionSnapshot) {
        guard let core else { return }
        do {
            try core.windows.deleteSnapshot(id: snapshot.id)
            reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Saves a snapshot as an editable layout.
    public func makeLayout(from snapshot: SessionSnapshot) {
        var layout = snapshot.asLayout
        layout.id = UUID()
        layout.name = uniqueName(snapshot.name)
        layout.rules = layout.rules.filter { $0.state != .hidden }
        saveDraft(layout)
    }

    private func invoke(_ id: ActionID, _ parameters: ActionParameters, then completion: ((WorkflowRun) -> Void)? = nil) {
        guard let core else { return }
        isBusy = true
        Task {
            let run = await core.engine.invoke(id, parameters: parameters, source: Self.trigger)
            isBusy = false
            lastRun = run
            await refreshDisplays()
            completion?(run)
        }
    }
}
