import AppKit
import AtlasCore
import AtlasCreative
import AtlasSpaces
import SwiftUI

/// UI state for the Creative Studio: projects, the room's easel and
/// monitor, the "here are the projects I found" prompt and the switcher.
/// The rules live in `CreativeService`; this only presents them.
@MainActor
final class CreativeModel: ObservableObject {
    struct SetupRequest: Identifiable {
        let id = UUID()
        var suggestions: [ProjectSuggestion]
        /// The first open (everything found) rather than a new folder showing up later.
        let isFirstRun: Bool
    }

    let core: AtlasCore?
    let module: CreativeModule?
    var service: CreativeService? { module?.service }
    /// Told when the room's state changes, so the 3D view refreshes.
    weak var spaces: SpacesModel?
    /// "Add <folder> to Orbit" (the folder picker, opened there).
    var addFolderToOrbit: ((String) -> Bool)?
    /// The window's sky and weather (the Study Library's weather city).
    var windowInfo: (() -> StudyRoomState.WindowView?)?
    /// The Companion as the painter at its tiny easel (nil: not painting).
    var painterInfo: (() -> CreativeRoomState.Painter?)?
    /// The window was clicked (set the weather city); the painter was clicked (show what's waiting).
    var onWindowClicked: (() -> Void)?
    var onPainterClicked: (() -> Void)?
    /// The weather city, shared with the Study Library.
    var weatherCity: (() -> String)?
    var setWeatherCity: ((String) -> Void)?

    @Published private(set) var projects: [Project] = []
    @Published private(set) var roomState = CreativeRoomState()
    @Published var setup: SetupRequest?
    /// The end-of-session card's contents.
    @Published private(set) var summary: CreativeSummary?

    private var subscription: EventBus.Subscription?
    private var ticker: Timer?
    private var setupPanel: NSPanel?
    private var switcherPanel: NSPanel?
    private var cardPanel: NSPanel?
    private var tickInterval: TimeInterval = 0

    init(core: AtlasCore?) {
        self.core = core
        module = core.flatMap { try? CreativeModule(core: $0) }
        do {
            try module?.rules.install()
            try module?.automations.install()
        } catch {
            AtlasLog.persistence.error("Couldn't set up Creative Studio file rules: \(error.localizedDescription, privacy: .public)")
        }
        reload()
        subscription = core?.events.subscribe { [weak self] event in
            guard event.name.hasPrefix("creative.") || event.name == AtlasEvent.Name.spaceActivated
                || event.name == AtlasEvent.Name.fileAccessChanged else { return }
            Task { @MainActor in self?.handle(event) }
        }
        schedule()
    }

    var sessions: CreativeSessions? { module?.sessions }

    /// The mug and last-edited times: every 20 s while creating, every
    /// 2 minutes otherwise, never per frame.
    private func schedule() {
        let interval: TimeInterval = sessions?.current != nil ? 20 : 120
        guard interval != tickInterval else { return }
        tickInterval = interval
        ticker?.invalidate()
        ticker = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.sessions?.tick()
                self?.refreshRoom()
            }
        }
        ticker?.tolerance = interval / 4
    }

    var activeProjects: [Project] { projects.filter { $0.creative?.isArchived == false } }
    var currentProject: Project? { service?.currentProject() }
    var settings: CreativeSettings {
        get { service?.settings ?? CreativeSettings() }
        set { service?.settings = newValue }
    }

    func reload() {
        projects = service?.projects(includingArchived: true) ?? []
        // Render rules follow projects and their render folders.
        let signature = projects.map { "\($0.id)|\($0.name)|\(service?.renderFolder(of: $0) ?? "")" }
        if signature != renderSignature {
            renderSignature = signature
            try? module?.rules.syncRenders()
        }
        refreshRoom()
    }

    private var renderSignature: [String] = []
    var rules: CreativeRules? { module?.rules }

    func refreshRoom() {
        guard let module else { return }
        var state = module.roomState()
        if let window = windowInfo?() {
            state.window = window
            state.windowDetail = window.detail
        }
        state.painter = painterInfo?()
        if state != roomState {
            roomState = state
            spaces?.objectWillChange.send()
        }
    }

    private func handle(_ event: AtlasEvent) {
        if event.name == AtlasEvent.Name.creativePickProject {
            let ids = (event.payload["projectIds"]?.stringValue ?? "").split(separator: ",").compactMap { UUID(uuidString: String($0)) }
            pickerChoices = ids.compactMap { id in projects.first { $0.id == id } }
            showCard(ProjectPickerView())
        }
        if event.name == AtlasEvent.Name.creativeSessionEnded {
            NSSound(named: "Glass")?.play()
            summary = sessions?.lastSummary
            showCard(CreativeSummaryCard())
        }
        if event.name == AtlasEvent.Name.spaceActivated,
           let id = event.payload["spaceId"]?.stringValue.flatMap(UUID.init(uuidString:)),
           spaces?.space(id: id)?.templateID == CreativeLoft.templateID {
            enteredStudio()
        }
        reload()
        schedule()
    }

    // MARK: - Finding projects

    /// First open: propose what was found. Later: offer any new folder.
    func enteredStudio() {
        guard let service else { return }
        let suggestions = service.suggestions()
        if !service.hasFinishedSetup {
            present(SetupRequest(suggestions: suggestions, isFirstRun: true))
        } else if !suggestions.isEmpty {
            present(SetupRequest(suggestions: suggestions, isFirstRun: false))
        }
    }

    /// "Find Projects…" from settings.
    func findProjects() {
        guard let service else { return }
        present(SetupRequest(suggestions: service.suggestions(), isFirstRun: true))
    }

    func add(_ suggestions: [ProjectSuggestion]) {
        _ = try? service?.add(suggestions)
        closeSetup()
    }

    func ignore(_ suggestion: ProjectSuggestion) {
        service?.ignore(suggestion)
        setup?.suggestions.removeAll { $0.id == suggestion.id }
        if setup?.suggestions.isEmpty == true, setup?.isFirstRun == false { closeSetup() }
    }

    func skipSetup() {
        service?.hasFinishedSetup = true
        closeSetup()
    }

    func closeSetup() {
        setup = nil
        setupPanel?.orderOut(nil)
        reload()
    }

    /// After adding a folder to Orbit from the setup sheet: look again.
    func rescan() {
        guard var setup, let service else { return }
        setup.suggestions = service.suggestions()
        self.setup = setup
    }

    private func present(_ request: SetupRequest) {
        setup = request
        setupPanel?.orderOut(nil)
        let panel = FloatingPanel.make(title: "", content: ProjectSetupView().environmentObject(self))
        setupPanel = panel
        panel.center()
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    // MARK: - The room

    /// The easel opens the current project (or finds projects when there
    /// are none); the monitor opens its app.
    func objectClicked(_ object: SpaceObject) -> Bool {
        switch object.kind {
        case .easel:
            if activeProjects.isEmpty {
                findProjects()
            } else {
                invoke(OpenCreativeProjectAction.id, source: "creative.easel")
            }
            return true
        case .monitor:
            invoke(OpenDesignAppAction.id, source: "creative.monitor")
            return true
        case .mug:
            mugClicked()
            return true
        case .poster:
            invoke(OpenInspirationAction.id, source: "creative.pegboard")
            return true
        case .bookshelf:
            invoke(OpenAssetsAction.id, source: "creative.shelves")
            return true
        default:
            return false
        }
    }

    /// Right-click or long-press: the easel's project switcher.
    func objectOptions(_ object: SpaceObject) {
        switch object.kind {
        case .easel: showSwitcher()
        case .mug: showCard(MugOptionsView())
        default: break
        }
    }

    // MARK: - Project picker

    /// Projects active in the last 24 hours, offered when entering.
    @Published private(set) var pickerChoices: [Project] = []

    /// Picks today's project (remembered for the day) and opens it.
    func pick(_ project: Project?) {
        service?.pick(project?.id)
        closeCard()
        reload()
        if project != nil { invoke(OpenCreativeProjectAction.id, source: "creative.picker") }
    }

    var automations: CreativeAutomations? { module?.automations }

    // MARK: - Jars, gallery, pegboard

    @Published private(set) var copiedHex: String?

    /// A paint jar copies its colour; a gallery frame opens that project's exports.
    func itemClicked(_ item: CreativeRoomState.Item) {
        switch item {
        case .jar(let index):
            guard roomState.jars.indices.contains(index) else { return }
            let hex = roomState.jars[index]
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(hex, forType: .string)
            copiedHex = hex
            NSSound(named: "Pop")?.play()
        case .window:
            onWindowClicked?()
        case .rug:
            showStats()
        case .painter:
            onPainterClicked?()
        case .frame(let projectID):
            guard let core, let project = projects.first(where: { $0.id == projectID }),
                  let folder = project.creative?.resolvedExportsFolder ?? project.creative?.folder else { return }
            let path = FileManager.default.fileExists(atPath: folder) ? folder : (project.creative?.folder ?? folder)
            Task { _ = await core.engine.invoke(OpenFileAction.id, parameters: ["path": .string(path)], source: "creative.gallery") }
        }
    }

    /// Finished projects that no longer fit on the gallery wall.
    var pastWork: [Project] { service?.pastWork() ?? [] }

    func showPastWork() { showCard(PastWorkView()) }

    /// Images dropped on the ATLAS window while in the Creative Studio:
    /// saved into the inspiration folder (through the engine, so it's
    /// undoable) and pinned on the pegboard.
    func dropped(_ urls: [URL]) {
        guard let core, let service else { return }
        service.ensureInspirationFolder()
        let folder = service.inspirationFolder
        guard service.isAuthorized(folder) else {
            if addFolderToOrbit?(folder) != true { return }
            return dropped(urls)
        }
        Task {
            for url in urls where url.isFileURL {
                _ = await core.engine.invoke(CopyFileAction.id, parameters: ["path": .string(url.path), "destination": .string(folder)],
                                             source: "creative.drop")
            }
            reload()
        }
    }

    /// Whether the Creative Studio is the active Space (drops go to its pegboard).
    var isStudioActive: Bool { service?.isStudioActive ?? false }

    // MARK: - Sessions

    /// Starts a session, or pauses / resumes the running one.
    func mugClicked() {
        if let sessions, sessions.current != nil {
            sessions.isPaused ? sessions.resume() : sessions.pause()
        } else {
            startSession()
        }
        reload()
    }

    func startSession(minutes: Double? = nil) {
        do {
            try sessions?.start(minutes: minutes)
            closeCard()
        } catch {
            core?.events.publish(AtlasEvent(AtlasEvent.Name.lockdownNotice, payload: ["message": .string(error.localizedDescription)]))
        }
        reload()
        schedule()
    }

    func endSession() {
        sessions?.end(early: true)
        closeCard()
    }

    func showStats() { showCard(CreativeStatsView()) }

    func showCard(_ content: some View) {
        cardPanel?.orderOut(nil)
        let panel = FloatingPanel.make(title: "", content: content.environmentObject(self))
        cardPanel = panel
        // On the display you clicked on (the mouse's), top right.
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        if let frame = screen?.visibleFrame {
            panel.setFrameTopLeftPoint(NSPoint(x: frame.maxX - panel.frame.width - 24, y: frame.maxY - 24))
        }
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    func closeCard() { cardPanel?.orderOut(nil) }

    /// A picture file's thumbnail (the export in the summary).
    func picture(_ path: String) -> NSImage? {
        if let cached = service?.thumbnails.cached(path) { return NSImage(contentsOfFile: cached) }
        return NSImage(contentsOfFile: path)
    }

    func projectName(_ id: UUID?) -> String {
        id.flatMap { id in projects.first { $0.id == id }?.name } ?? "No project"
    }

    func projectColor(_ id: UUID?) -> String {
        id.flatMap { id in projects.first { $0.id == id }?.color } ?? "#C9B8BE"
    }

    func showSwitcher() {
        switcherPanel?.orderOut(nil)
        let panel = FloatingPanel.make(title: "Current project", content: ProjectSwitcherView().environmentObject(self))
        switcherPanel = panel
        let mouse = NSEvent.mouseLocation
        panel.setFrameTopLeftPoint(NSPoint(x: mouse.x - panel.frame.width / 2, y: mouse.y + 20))
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    func closeSwitcher() { switcherPanel?.orderOut(nil) }

    /// Makes `project` current (as if just opened from the room).
    func makeCurrent(_ project: Project) {
        service?.noteOpened(project.id)
        if settings.pinnedProjectID != nil, settings.pinnedProjectID != project.id { settings.pinnedProjectID = nil }
        reload()
    }

    func setPinned(_ pinned: Bool, _ project: Project) {
        settings.pinnedProjectID = pinned ? project.id : nil
        reload()
    }

    private func invoke(_ action: ActionID, source: String) {
        guard let core else { return }
        Task { _ = await core.engine.invoke(action, source: source) }
    }

    // MARK: - Projects

    /// A project's picture (cached thumbnail), made in the background if missing.
    func thumbnail(for project: Project) -> NSImage? {
        guard let service, let source = service.latestVisual(project) else { return nil }
        if let cached = service.thumbnails.cached(source) { return NSImage(contentsOfFile: cached) }
        let thumbnails = service.thumbnails
        Task {
            if await thumbnails.make(source) { self.objectWillChange.send() }
        }
        return nil
    }

    @discardableResult
    func save(_ project: Project) -> Project? {
        try? service?.save(project)
    }

    func delete(_ project: Project) {
        try? service?.delete(projectID: project.id)
    }

    func isAuthorized(_ folder: String) -> Bool { service?.isAuthorized(folder) ?? false }

    func appName(_ bundleID: String) -> String { service?.appName(bundleID) ?? bundleID }

    func lastEdited(_ project: Project) -> String? {
        service?.lastChanged(project).map { $0.formatted(.relative(presentation: .named)) }
    }
}
