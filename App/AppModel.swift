import AppKit
import AtlasCore
import AtlasFlow
import AtlasSpacesUI
import ServiceManagement
import SwiftUI
import UserNotifications

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
    /// One editor per open automation, so drafts and undo survive switching.
    private var editors: [UUID: FlowEditorModel] = [:]
    /// Run History filters.
    @Published var runFilters = RunFilters() {
        didSet { reloadRuns() }
    }
    /// A node to centre when an automation's editor opens ("Fix" in Run History).
    @Published var pendingFocus: (workflowID: UUID, nodeID: UUID)?
    @Published private(set) var launchesAtLogin = false
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
        launchesAtLogin = SMAppService.mainApp.status == .enabled
    }

    // MARK: - Flow editor

    func editor(for workflow: Workflow) -> FlowEditorModel? {
        guard let core else { return nil }
        if let existing = editors[workflow.id] { return existing }
        let editor = FlowEditorModel(workflow: workflow, core: core) { [weak self] _ in self?.reloadWorkflows() }
        editors[workflow.id] = editor
        return editor
    }

    /// Opens an automation with one of its steps centred and selected.
    func openForFixing(workflowID: UUID, nodeID: UUID) {
        pendingFocus = (workflowID, nodeID)
        selectedWorkflowID = workflowID
        section = .automations
        if let workflow = workflow(id: workflowID), let editor = editor(for: workflow) {
            editor.viewMode = .canvas
            Task { @MainActor in
                // Let the editor lay out first.
                try? await Task.sleep(nanoseconds: 150_000_000)
                editor.focus(on: nodeID)
            }
        }
    }

    // MARK: - Background

    /// Registers ATLAS as a login item so triggers keep working after a
    /// restart. Needs the app bundle (scripts/build-app.sh).
    func setLaunchesAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            errorMessage = Bundle.main.bundleIdentifier == nil
                ? "Starting at login needs ATLAS to run as an app bundle. Build it with scripts/build-app.sh."
                : "Couldn't change the login item: \(error.localizedDescription)"
        }
        launchesAtLogin = SMAppService.mainApp.status == .enabled
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
            for workflow in workflows { editors[workflow.id]?.reload(from: workflow) }
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
        if let saved = save(workflow.duplicate(named: workflow.name + " Copy")) { selectedWorkflowID = saved.id }
    }

    func delete(_ workflow: Workflow) {
        guard let core else { return }
        do {
            try core.delete(workflowID: workflow.id)
            editors[workflow.id] = nil
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
            runs = try core.store.runs(matching: runFilters.query, limit: 300)
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
        // Automatic runs may happen with no window open: ask with a
        // notification. The engine stops waiting after its timeout.
        if request.isAutomatic, Bundle.main.bundleIdentifier != nil {
            return await ConfirmationNotifications.shared.ask(request)
        }
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

/// Asks to approve a step of an automatic run with an actionable
/// notification, so it works with every window closed.
final class ConfirmationNotifications: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    static let shared = ConfirmationNotifications()
    private static let category = "atlas.confirm"
    private let lock = NSLock()
    private var waiting: [String: CheckedContinuation<Bool, Never>] = [:]

    func install() {
        guard Bundle.main.bundleIdentifier != nil else { return }
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.setNotificationCategories([UNNotificationCategory(
            identifier: Self.category,
            actions: [
                UNNotificationAction(identifier: "allow", title: "Allow", options: []),
                UNNotificationAction(identifier: "deny", title: "Don't Allow", options: [.destructive]),
            ],
            intentIdentifiers: []
        )])
    }

    func ask(_ request: ConfirmationRequest) async -> Bool {
        let id = request.id.uuidString
        let content = UNMutableNotificationContent()
        content.title = "“\(request.workflowName)” wants to \(request.stepLabel)"
        content.body = "\(request.descriptor.summary) It won't run unless you allow it."
        content.categoryIdentifier = Self.category
        content.sound = .default
        do {
            try await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
        } catch {
            return false
        }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                lock.withLock { waiting[id] = continuation }
            }
        } onCancel: {
            // The engine gave up waiting: decline and tidy the notification away.
            self.resolve(id, false)
            UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [id])
        }
    }

    private func resolve(_ id: String, _ approved: Bool) {
        let continuation = lock.withLock { waiting.removeValue(forKey: id) }
        continuation?.resume(returning: approved)
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        resolve(response.notification.request.identifier, response.actionIdentifier == "allow")
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}
