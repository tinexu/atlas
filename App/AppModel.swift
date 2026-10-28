import AppKit
import AtlasCompanion
import AtlasCompanionUI
import AtlasCore
import AtlasFlow
import AtlasOrbit
import AtlasOrbitUI
import AtlasSpacesUI
import ServiceManagement
import SwiftUI
import UserNotifications

/// UI-facing state. Owns no logic of its own: everything real happens in
/// `AtlasCore`, and this object mirrors it for SwiftUI.
@MainActor
final class AppModel: ObservableObject {
    enum Section: String, Hashable, CaseIterable, Identifiable {
        case today, spaces, timeline, windows, orbit, health, automations, history, actions, companion, permissions
        var id: Self { self }

        var title: String {
            switch self {
            case .today: return "Today"
            case .spaces: return "Spaces"
            case .timeline: return "Time Architect"
            case .windows: return "Windows"
            case .orbit: return "Orbit"
            case .health: return "Mac Health"
            case .automations: return "Automations"
            case .history: return "Run History"
            case .actions: return "Action Library"
            case .companion: return "Companion"
            case .permissions: return "Permissions"
            }
        }

        var symbol: String {
            switch self {
            case .today: return "sun.max"
            case .spaces: return "cube.transparent"
            case .timeline: return "calendar.day.timeline.left"
            case .windows: return "macwindow.on.rectangle"
            case .orbit: return "globe.americas"
            case .health: return "heart.text.square"
            case .automations: return "bolt.horizontal.circle"
            case .history: return "clock.arrow.circlepath"
            case .actions: return "square.grid.2x2"
            case .companion: return "face.smiling"
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
    /// Set when the database was found damaged at launch (it's been set aside).
    @Published private(set) var corruptionBackup: DatabaseBackups.Backup?
    @Published var showEventLog = false

    let core: AtlasCore?
    let spaces: SpacesModel
    let windowManager: WindowManagerModel
    /// Stage 05 Orbit: files and Mac Health. Nil if it couldn't start.
    let orbit: OrbitViewModel?
    /// Stage 06 Companion: the desktop assistant. Nil if ATLAS couldn't start.
    let companion: CompanionController?
    /// Lockdown focus mode: prompt, pomodoro window and toasts.
    let lockdown: LockdownModel
    /// A run to select when Run History appears (the Companion's "Details").
    @Published var focusedRunID: UUID?
    /// Stage 07 Time Architect and Today. Nil if scheduling couldn't start.
    let timeArchitect: TimeArchitectModel?
    /// The running focus session, for the menu bar countdown.
    @Published private(set) var focusSession: FocusSession?
    @Published var showGenerator = false
    @Published var generatorPrompt = ""
    /// Opens the main window; set by the first view that has `openWindow`.
    var openMainWindow: (() -> Void)?
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
            orbit = nil
            companion = nil
            lockdown = LockdownModel(core: nil)
            timeArchitect = nil
            startupError = error.localizedDescription
            if case DataSafetyError.corrupted = error, let url = try? AtlasStore.defaultURL() {
                corruptionBackup = DatabaseBackups.list(in: DatabaseBackups.folder(for: url)).first
            }
            return
        }
        spaces = SpacesModel(core: core)
        windowManager = WindowManagerModel(core: core)
        var orbitError: Error?
        if let core, let module = try? OrbitModule.live(core: core) {
            module.start()
            orbit = OrbitViewModel(module: module)
        } else {
            orbit = nil
            orbitError = ActionError.failed("Orbit couldn't start, so file features are unavailable.")
        }
        companion = core.map(CompanionController.init)
        lockdown = LockdownModel(core: core)
        timeArchitect = core.flatMap { core in core.time.map { TimeArchitectModel(core: core, time: $0) } }
        focusSession = core?.time?.focus.session
        spaces.onError = { [weak self] message in self?.errorMessage = message }
        lockdown.activate = { [weak spaces] spaceID, profileID, minutes, modeID in
            spaces?.activate(spaceID, profileID: profileID, lockdownMinutes: minutes, lockdownModeID: modeID)
        }
        spaces.onLockdownPrompt = { [weak lockdown] pending in lockdown?.prompt(pending) }
        reloadWorkflows()
        reloadRuns()
        disabledActions = core?.permissions.disabledActions ?? []
        selectedWorkflowID = workflows.first?.id
        listenForEvents()
        installConfirmationHandler()
        Task { await refreshPermissions() }
        monitorAccessibility()
        launchesAtLogin = SMAppService.mainApp.status == .enabled
        connectOrbit()
        connectCompanion()
        if let orbitError { errorMessage = orbitError.localizedDescription }
    }

    private func connectOrbit() {
        guard let orbit else { return }
        orbit.spaces = { [weak self] in self?.spaces.spaces.map { (id: $0.id, name: $0.name) } ?? [] }
        orbit.onError = { [weak self] message in self?.errorMessage = message }
        orbit.openWorkflow = { [weak self] id in
            guard let self else { return }
            self.reloadWorkflows()
            self.selectedWorkflowID = id
            self.section = .automations
        }
    }

    // MARK: - Companion

    private func connectCompanion() {
        guard let companion else { return }
        var host = CompanionHost()
        host.openSection = { [weak self] name in
            guard let self else { return }
            if let section = Section(rawValue: name) { self.section = section }
            self.bringForward()
        }
        host.openRunHistory = { [weak self] runID in
            guard let self else { return }
            self.runFilters = RunFilters()
            self.reloadRuns()
            self.focusedRunID = runID
            self.section = .history
            self.bringForward()
        }
        host.openWorkflowAt = { [weak self] workflowID, nodeID in
            guard let self else { return }
            self.reloadWorkflows()
            if let nodeID {
                self.openForFixing(workflowID: workflowID, nodeID: nodeID)
            } else {
                self.selectedWorkflowID = workflowID
                self.section = .automations
            }
            self.bringForward()
        }
        host.showLargestFiles = { [weak self] in
            self?.orbit?.showLargestFiles()
            self?.section = .orbit
            self?.bringForward()
        }
        host.showCleanup = { [weak self] in
            self?.orbit?.tab = .browser
            self?.section = .orbit
            self?.bringForward()
            self?.orbit?.showCleanup = true
        }
        host.showReviewQueue = { [weak self] in
            self?.orbit?.tab = .rules
            self?.section = .orbit
            self?.bringForward()
        }
        host.showOrbitFolders = { [weak self] in
            self?.orbit?.tab = .folders
            self?.section = .orbit
            self?.bringForward()
        }
        host.draftWorkflow = { [weak self] name, bundleIDs in
            self?.draftWorkflow(named: name, launching: bundleIDs)
        }
        host.isPaused = { [weak self] in self?.isPaused ?? false }
        host.describeAutomation = { [weak self] prompt in self?.describeAutomation(prompt) }
        companion.host = host
        companion.start()
    }

    /// Shows the main window, opening it again if it was closed.
    func bringForward() {
        NSApp.activate(ignoringOtherApps: true)
        if let window = NSApp.windows.first(where: { $0.identifier?.rawValue.hasPrefix("main") == true && $0.canBecomeMain }) {
            window.makeKeyAndOrderFront(nil)
        } else {
            openMainWindow?()
        }
    }

    /// A suggested workflow from repeated app launches: saved turned off and
    /// opened in the editor for the person to review, rename and keep or delete.
    private func draftWorkflow(named name: String, launching bundleIDs: [String]) {
        let workflow = Workflow(
            name: "Open \(name)",
            summary: "Suggested by the Companion because you often open these apps together. Review it, then save or delete it.",
            isEnabled: false,
            steps: bundleIDs.map { WorkflowStep(actionID: LaunchApplicationAction.id, parameters: ["bundleId": .string($0)]) }
        )
        if let saved = save(workflow) {
            selectedWorkflowID = saved.id
            section = .automations
            bringForward()
        }
    }

    // MARK: - Data safety (Stage 08)

    /// Puts the latest daily backup in place, then restarts ATLAS.
    func restoreLatestBackup() {
        guard let backup = corruptionBackup, let url = try? AtlasStore.defaultURL() else { return }
        do {
            try DatabaseBackups.restore(backup, to: url)
            relaunch()
        } catch {
            errorMessage = "Couldn't restore the backup: \(error.localizedDescription)"
        }
    }

    /// Opens a new copy of ATLAS and quits this one.
    func relaunch() {
        let path = Bundle.main.bundlePath
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "sleep 1; /usr/bin/open \"\(path)\""]
        try? process.run()
        NSApp.terminate(nil)
    }

    func exportData() {
        guard let core else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "ATLAS Export \(Date().formatted(.iso8601.year().month().day())).json"
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try AtlasExport.make(from: core.store).data().write(to: url, options: .atomic)
        } catch {
            errorMessage = "Couldn't export: \(error.localizedDescription)"
        }
    }

    func importData() {
        guard let core else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.message = "Workflows, Spaces, rules and settings in the file are added. Items with the same ID are replaced; nothing else is removed."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try DatabaseBackups.backUp(core.store.database, to: DatabaseBackups.folder(for: AtlasStore.defaultURL())
                .appendingPathComponent("atlas-before-import-\(Int(Date().timeIntervalSince1970)).sqlite"))
            let summary = try AtlasExport.read(Data(contentsOf: url)).apply(to: core.store)
            reloadWorkflows()
            spaces.reload()
            orbit?.reload()
            timeArchitect?.reload()
            errorMessage = "Imported \(summary.workflows) workflows and \(summary.rows) other items. A backup from just before is in the Backups folder."
        } catch {
            errorMessage = "Couldn't import: \(error.localizedDescription)"
        }
    }

    func openDatabaseFolder() {
        if let url = try? AtlasStore.defaultURL() { NSWorkspace.shared.activateFileViewerSelecting([url]) }
    }

    func backUpNow() {
        guard let core, let url = try? AtlasStore.defaultURL() else { return }
        do {
            let target = DatabaseBackups.folder(for: url).appendingPathComponent("atlas-manual-\(Int(Date().timeIntervalSince1970)).sqlite")
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try DatabaseBackups.backUp(core.store.database, to: target)
            NSWorkspace.shared.activateFileViewerSelecting([target])
        } catch {
            errorMessage = "Backup failed: \(error.localizedDescription)"
        }
    }

    /// Forgets that onboarding ran, so starter content is offered again next launch.
    func resetOnboarding() {
        guard let core else { return }
        try? core.store.database.run("DELETE FROM user_preference WHERE key LIKE 'onboarding.%' OR key LIKE 'orbit.seeded%';")
        errorMessage = "Onboarding reset. Starter items are added again the next time ATLAS starts (only where you have none)."
    }

    /// The last two hours of ATLAS's log, to the clipboard.
    func copyLogs() {
        Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/log")
            process.arguments = ["show", "--last", "2h", "--style", "compact", "--predicate", "subsystem == \"app.atlas\""]
            let pipe = Pipe()
            process.standardOutput = pipe
            try? process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let text = String(data: data, encoding: .utf8) ?? ""
            await MainActor.run {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                self.errorMessage = "Copied \(text.split(separator: "\n").count) log lines to the clipboard."
            }
        }
    }

    /// Whether the Debug menu shows: debug builds, or `defaults write app.atlas.ATLAS DebugMenu -bool YES`.
    var showsDebugMenu: Bool {
        #if DEBUG
        return true
        #else
        return UserDefaults.standard.bool(forKey: "DebugMenu")
        #endif
    }

    // MARK: - Time Architect

    func explain(_ workflow: Workflow) -> String {
        guard let core else { return "" }
        return WorkflowExplainer.explain(workflow, registry: core.registry)
    }

    /// Opens "Describe an Automation", optionally with text already typed.
    func describeAutomation(_ prompt: String = "") {
        generatorPrompt = prompt
        section = .automations
        showGenerator = true
        bringForward()
    }

    // MARK: - Undo

    /// File changes in a run that can still be undone.
    func undoableOperations(in run: WorkflowRun) -> [FileOperation] {
        ((try? core?.store.operations(runID: run.id)) ?? []).filter { $0.kind.isUndoable && $0.undoneAt == nil && $0.state == .done }
    }

    /// Reverses a run's file changes, newest first, as one run of its own.
    func undoFileChanges(of run: WorkflowRun) {
        guard let core else { return }
        let operations = undoableOperations(in: run).reversed()
        guard !operations.isEmpty else { return }
        let workflow = Workflow(
            name: "Undo: \(run.workflowName)",
            summary: "Reverses the file changes made by a run on \(run.startedAt.formatted(date: .abbreviated, time: .shortened)).",
            failurePolicy: .continueOnFailure,
            steps: operations.map {
                WorkflowStep(actionID: UndoFileOperationAction.id, parameters: ["operationId": .string($0.id.uuidString)],
                             label: "Undo: \($0.summary)")
            }
        )
        Task {
            let result = await core.engine.run(workflow, trigger: "undo")
            if result.state != .succeeded {
                errorMessage = "Some changes couldn't be undone: \(result.error ?? "see Run History for details.")"
            }
            reloadRuns()
        }
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
        case _ where event.name.hasPrefix("focus."):
            focusSession = core?.time?.focus.session
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
