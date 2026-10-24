import AppKit
import AtlasCore
import AtlasSpacesUI
import SwiftUI

/// UI-facing state. Owns no logic of its own: everything real happens in
/// `AtlasCore`, and this object mirrors it for SwiftUI.
@MainActor
final class AppModel: ObservableObject {
    enum Section: String, Hashable, CaseIterable, Identifiable {
        case spaces, windows, automations, history, actions, permissions
        var id: Self { self }

        var title: String {
            switch self {
            case .spaces: return "Spaces"
            case .windows: return "Windows"
            case .automations: return "Automations"
            case .history: return "Run History"
            case .actions: return "Action Library"
            case .permissions: return "Permissions"
            }
        }

        var symbol: String {
            switch self {
            case .spaces: return "cube.transparent"
            case .windows: return "macwindow.on.rectangle"
            case .automations: return "bolt.horizontal.circle"
            case .history: return "clock.arrow.circlepath"
            case .actions: return "square.grid.2x2"
            case .permissions: return "lock.shield"
            }
        }
    }

    struct PendingConfirmation: Identifiable {
        let request: ConfirmationRequest
        let continuation: CheckedContinuation<Bool, Never>
        var id: UUID { request.id }
    }

    @Published var section: Section = .spaces
    @Published private(set) var workflows: [Workflow] = []
    @Published var selectedWorkflowID: UUID?
    @Published private(set) var runs: [WorkflowRun] = []
    /// workflowID → runID for runs in progress.
    @Published private(set) var activeRuns: [UUID: UUID] = [:]
    @Published private(set) var permissionStatuses: [Permission: PermissionStatus] = [:]
    @Published private(set) var disabledActions: Set<ActionID> = []
    @Published private(set) var isPaused = false
    @Published var pendingConfirmation: PendingConfirmation?
    @Published var errorMessage: String?
    @Published private(set) var startupError: String?

    let core: AtlasCore?
    let spaces: SpacesModel
    let windowManager: WindowManagerModel
    private var eventTask: Task<Void, Never>?
    private var accessibilityMonitor: Timer?
    private var hadAccessibility = false

    init() {
        do {
            core = try AtlasCore.live()
        } catch {
            core = nil
            spaces = SpacesModel(core: nil)
            windowManager = WindowManagerModel(core: nil)
            startupError = error.localizedDescription
            return
        }
        spaces = SpacesModel(core: core)
        windowManager = WindowManagerModel(core: core)
        spaces.onError = { [weak self] message in self?.errorMessage = message }
        reloadWorkflows()
        reloadRuns()
        disabledActions = core?.permissions.disabledActions ?? []
        selectedWorkflowID = workflows.first?.id
        listenForEvents()
        installConfirmationHandler()
        Task { await refreshPermissions() }
        monitorAccessibility()
    }

    var registry: ActionRegistry? { core?.registry }

    // MARK: - Workflows

    func workflow(id: UUID?) -> Workflow? {
        guard let id else { return nil }
        return workflows.first { $0.id == id }
    }

    func reloadWorkflows() {
        guard let core else { return }
        do {
            workflows = try core.store.workflows()
        } catch {
            report(error)
        }
    }

    @discardableResult
    func save(_ workflow: Workflow) -> Workflow? {
        guard let core else { return nil }
        do {
            let saved = try core.save(workflow)
            reloadWorkflows()
            return saved
        } catch {
            report(error)
            return nil
        }
    }

    func createWorkflow() {
        let workflow = Workflow(name: "New Automation", steps: [
            WorkflowStep(actionID: LaunchApplicationAction.id, parameters: ["bundleId": "com.apple.Terminal"]),
        ])
        if let saved = save(workflow) {
            selectedWorkflowID = saved.id
            section = .automations
        }
    }

    func duplicate(_ workflow: Workflow) {
        var copy = workflow
        copy.id = UUID()
        copy.name = workflow.name + " Copy"
        copy.createdAt = Date()
        copy.steps = workflow.steps.map { step in
            var step = step
            step.id = UUID()
            return step
        }
        if let saved = save(copy) { selectedWorkflowID = saved.id }
    }

    func delete(_ workflow: Workflow) {
        guard let core else { return }
        do {
            try core.delete(workflowID: workflow.id)
            reloadWorkflows()
            if selectedWorkflowID == workflow.id { selectedWorkflowID = workflows.first?.id }
        } catch {
            report(error)
        }
    }

    // MARK: - Running

    func run(_ workflow: Workflow, trigger: String = "manual") {
        guard let core else { return }
        Task { await core.engine.start(workflow, trigger: trigger) }
    }

    func cancelRun(for workflowID: UUID) {
        guard let core, let runID = activeRuns[workflowID] else { return }
        Task { await core.engine.cancel(runID: runID) }
    }

    func isRunning(_ workflowID: UUID) -> Bool { activeRuns[workflowID] != nil }

    func latestRun(for workflowID: UUID) -> WorkflowRun? {
        runs.first { $0.workflowID == workflowID }
    }

    func reloadRuns() {
        guard let core else { return }
        do {
            runs = try core.store.runs(limit: 200)
        } catch {
            report(error)
        }
    }

    func setPaused(_ paused: Bool) {
        guard let core else { return }
        isPaused = paused
        Task { await core.engine.setPaused(paused) }
    }

    // MARK: - Permissions & action switches

    func refreshPermissions() async {
        guard let core else { return }
        permissionStatuses = await core.permissions.allStatuses()
    }

    func request(_ permission: Permission) {
        guard let core else { return }
        Task {
            _ = await core.permissions.request(permission)
            await refreshPermissions()
        }
    }

    /// Notices Accessibility being turned off (or on) while ATLAS runs.
    /// Runs in progress already fail cleanly on their own; this keeps the
    /// UI honest and tells the user why window control stopped.
    private func monitorAccessibility() {
        guard let core else { return }
        hadAccessibility = core.windows.adapter.isTrusted
        accessibilityMonitor = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkAccessibility() }
        }
        accessibilityMonitor?.tolerance = 1
    }

    private func checkAccessibility() {
        guard let core else { return }
        let trusted = core.windows.adapter.isTrusted
        guard trusted != hadAccessibility else { return }
        hadAccessibility = trusted
        if !trusted {
            errorMessage = "Accessibility permission was turned off, so ATLAS can't arrange windows. Apps still open when you activate a Space. Turn it back on in System Settings to restore window layouts."
        }
        Task {
            await refreshPermissions()
            await windowManager.refreshDisplays()
        }
    }

    func openSystemSettings(for permission: Permission) {
        if let url = permission.systemSettingsURL { NSWorkspace.shared.open(url) }
    }

    func isActionEnabled(_ id: ActionID) -> Bool { !disabledActions.contains(id) }

    func setAction(_ id: ActionID, enabled: Bool) {
        guard let core else { return }
        do {
            try core.permissions.setEnabled(enabled, for: id)
            disabledActions = core.permissions.disabledActions
        } catch {
            report(error)
        }
    }

    // MARK: - Confirmation

    func resolveConfirmation(_ approved: Bool) {
        guard let pending = pendingConfirmation else { return }
        pendingConfirmation = nil
        pending.continuation.resume(returning: approved)
    }

    private func installConfirmationHandler() {
        guard let core else { return }
        let handler: ConfirmationHandler = { [weak self] request in
            guard let self else { return false }
            return await self.askForConfirmation(request)
        }
        Task { await core.engine.setConfirmationHandler(handler) }
    }

    private func askForConfirmation(_ request: ConfirmationRequest) async -> Bool {
        // Only one prompt at a time; a second concurrent request is declined
        // rather than silently replacing the first.
        guard pendingConfirmation == nil else { return false }
        NSApp.activate(ignoringOtherApps: true)
        return await withCheckedContinuation { continuation in
            pendingConfirmation = PendingConfirmation(request: request, continuation: continuation)
        }
    }

    // MARK: - Events

    private func listenForEvents() {
        guard let core else { return }
        let stream = core.events.stream()
        eventTask = Task { [weak self] in
            for await event in stream {
                guard let self else { return }
                self.handle(event)
            }
        }
    }

    private func handle(_ event: AtlasEvent) {
        let workflowID = event.payload["workflowId"]?.stringValue.flatMap(UUID.init(uuidString:))
        let runID = event.payload["runId"]?.stringValue.flatMap(UUID.init(uuidString:))

        switch event.name {
        case AtlasEvent.Name.workflowStarted:
            if let workflowID, let runID { activeRuns[workflowID] = runID }
            reloadRuns()
        case AtlasEvent.Name.workflowFinished:
            if let workflowID, activeRuns[workflowID] == runID { activeRuns[workflowID] = nil }
            reloadRuns()
        case AtlasEvent.Name.stepStarted, AtlasEvent.Name.stepFinished:
            reloadRuns()
        case AtlasEvent.Name.automationPaused:
            isPaused = true
        case AtlasEvent.Name.automationResumed:
            isPaused = false
        default:
            break
        }
    }

    private func report(_ error: Error) {
        errorMessage = error.localizedDescription
    }
}
