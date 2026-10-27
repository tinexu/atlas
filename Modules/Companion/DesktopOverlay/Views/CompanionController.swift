import AppKit
import AtlasCompanion
import AtlasCore
import AtlasOrbit
import AtlasSpaces
import Combine
import CoreGraphics
import SwiftUI

/// What the Companion asks the app to do: navigation inside ATLAS. Anything
/// that changes the Mac goes through the engine instead.
@MainActor
public struct CompanionHost {
    public var openSection: (String) -> Void = { _ in }
    public var openRunHistory: (UUID?) -> Void = { _ in }
    public var openWorkflowAt: (UUID, UUID?) -> Void = { _, _ in }
    public var showLargestFiles: () -> Void = {}
    public var showCleanup: () -> Void = {}
    public var showReviewQueue: () -> Void = {}
    public var showOrbitFolders: () -> Void = {}
    /// Opens a new, unsaved-looking draft in the editor (saved disabled).
    public var draftWorkflow: (String, [String]) -> Void = { _, _ in }
    public var isPaused: () -> Bool = { false }
    /// Opens "Describe an Automation" with the text typed.
    public var describeAutomation: (String) -> Void = { _ in }

    public init() {}
}

/// The speech bubble's content.
public struct StatusBubble: Identifiable, Equatable {
    public let id = UUID()
    public var text: String
    public var detail: String?
    public var isFailure: Bool
    public var runID: UUID?
    public var fixTitle: String?
    public var fix: Suggestion.Action?
    public var suggestion: Suggestion?
    public var recommendation: Recommendation?
}

/// Glues the Companion together on the main actor: settings, the state
/// machine fed by the event bus, the overlay, quick controls, the palette,
/// suggestions and global shortcuts. Holds no automation logic of its own.
@MainActor
public final class CompanionController: ObservableObject {
    @Published public private(set) var settings: CompanionSettings
    @Published public private(set) var state: CompanionState = .idle
    @Published public private(set) var bubble: StatusBubble?
    @Published public private(set) var isRenderingPaused = false
    @Published public private(set) var isInteractive = false
    @Published public private(set) var apps: [CommandVocabulary.Named] = []
    @Published public private(set) var aiStatus: String?
    @Published public private(set) var hotKeyProblems: [String] = []
    @Published public var paletteVisible = false
    /// The running focus session, for the countdown under the character.
    @Published public private(set) var focusSession: FocusSession?

    public let core: AtlasCore
    public let runner: CommandRunner
    public let suggestions: SuggestionCenter
    public var host = CompanionHost()
    let files: FileSearch?

    private var machine = CompanionStateMachine()
    private var bubblePolicy = BubblePolicy()
    private var tickWork: DispatchWorkItem?
    private var bubbleWork: DispatchWorkItem?
    private var eventTask: Task<Void, Never>?
    private var hotKeys: [TriggerToken] = []
    private var appObserver: TriggerToken?
    private var observers: [NSObjectProtocol] = []
    private var idleTimer: Timer?
    private var interactiveWork: DispatchWorkItem?
    /// Apps ATLAS itself launched recently (bundle ID → when), so they aren't
    /// counted as the person's own launches.
    private var atlasLaunches: [String: Date] = [:]
    private var isScreenLocked = false
    private let environment = MacTriggerEnvironment()
    lazy var overlay = CompanionOverlay(controller: self)
    lazy var palette = PaletteWindowController(controller: self)

    public init(core: AtlasCore) {
        self.core = core
        runner = CommandRunner(core: core)
        let settings = (try? core.store.companionSettings()) ?? CompanionSettings()
        self.settings = settings
        suggestions = SuggestionCenter(store: core.store, events: core.events, settings: settings)
        files = FileSearch(store: core.store)
    }

    // MARK: - Lifecycle

    public func start() {
        listen()
        registerHotKeys()
        observeSystem()
        suggestions.onSuggestion = { [weak self] suggestion in
            Task { @MainActor in self?.show(suggestion) }
        }
        core.time?.recommendations.onRecommendation = { [weak self] recommendation in
            Task { @MainActor in self?.show(recommendation) }
        }
        applySources()
        focusSession = core.time?.focus.session
        Task.detached(priority: .utility) { [weak self] in
            let apps = InstalledApps.scan()
            await self?.received(apps)
        }
        updateFocus()
        overlay.apply(settings)
        Task { await refreshAIStatus() }
    }

    private func received(_ apps: [CommandVocabulary.Named]) {
        self.apps = apps
        let names = Dictionary(apps.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
        suggestions.appName = { names[$0] }
    }

    // MARK: - Settings

    public func update(_ change: (inout CompanionSettings) -> Void) {
        var next = settings
        change(&next)
        guard next != settings else { return }
        let hotKeysChanged = next.companionHotKey != settings.companionHotKey || next.paletteHotKey != settings.paletteHotKey
        let aiChanged = next.aiProvider != settings.aiProvider || next.cloudModel != settings.cloudModel
        settings = next
        do {
            try core.store.saveCompanionSettings(next)
        } catch {
            AtlasLog.engine.error("Couldn't save Companion settings: \(error.localizedDescription, privacy: .public)")
        }
        suggestions.update(settings: next)
        applySources()
        overlay.apply(next)
        if hotKeysChanged { registerHotKeys() }
        if aiChanged { Task { await refreshAIStatus() } }
        updateFocus()
        core.events.publish(AtlasEvent(AtlasEvent.Name.companionSettingsChanged))
    }

    public var isVisible: Bool { settings.overlayMode != .hidden }

    public func setVisible(_ visible: Bool) {
        update { $0.overlayMode = visible ? ($0.overlayMode == .hidden ? .onTop : $0.overlayMode) : .hidden }
    }

    /// Remembers where the character was dragged, for this display arrangement.
    func savePosition(_ origin: CGPoint, arrangement: String) {
        update { $0.positions[arrangement] = StoredPoint(x: origin.x, y: origin.y) }
    }

    // MARK: - Presentation

    /// Idle, focus and sleep show a rendered still, so an idle Companion uses almost no CPU.
    var isAnimating: Bool { state.usesLiveRendering }

    var presentation: CharacterPresentation {
        CharacterPresentation.make(for: state, intensity: settings.intensity,
                                   reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
    }

    private func feed(_ input: CompanionStateMachine.Input) {
        let previous = machine.displayed
        if let changed = machine.handle(input, at: Date()) { publish(changed, previous: previous) }
        scheduleTick()
    }

    private func scheduleTick() {
        tickWork?.cancel()
        guard let deadline = machine.nextDeadline(after: Date()) else { return }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                let previous = self.machine.displayed
                if let changed = self.machine.tick(at: Date()) { self.publish(changed, previous: previous) }
                self.scheduleTick()
            }
        }
        tickWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0.05, deadline.timeIntervalSinceNow), execute: work)
    }

    private func publish(_ state: CompanionState, previous: CompanionState) {
        self.state = state
        core.events.publish(AtlasEvent(AtlasEvent.Name.companionStateChanged,
                                       payload: ["state": .string(state.rawValue), "previous": .string(previous.rawValue)]))
    }

    // MARK: - Events

    private func listen() {
        let stream = core.events.stream()
        eventTask = Task { [weak self] in
            for await event in stream {
                guard let self else { return }
                self.handle(event)
            }
        }
    }

    private func handle(_ event: AtlasEvent) {
        if let input = CompanionStateMachine.input(for: event) { feed(input) }
        suggestions.handle(event)
        switch event.name {
        case AtlasEvent.Name.workflowFinished:
            showResult(of: event)
        case AtlasEvent.Name.actionEffect where event.payload["kind"]?.stringValue == "app":
            if let bundleID = event.payload["value"]?.stringValue { atlasLaunches[bundleID] = Date() }
        case _ where event.name.hasPrefix("focus."):
            focusSession = core.time?.focus.session
            updateFocus()
            if event.name == AtlasEvent.Name.focusEnded {
                let minutes = Int(event.payload["elapsedMinutes"]?.numberValue ?? 0)
                showBubble(StatusBubble(text: "\(event.payload["title"]?.stringValue ?? "Focus") \(event.payload["completed"]?.boolValue == true ? "done" : "stopped") · \(minutes) min",
                                        isFailure: false), seconds: 8)
            }
        case AtlasEvent.Name.timerStarted, AtlasEvent.Name.timerCompleted, AtlasEvent.Name.timerStopped, AtlasEvent.Name.spaceActivatedEvent:
            updateFocus()
            if event.name == AtlasEvent.Name.timerCompleted, let name = event.payload["name"]?.stringValue {
                showBubble(StatusBubble(text: "“\(name)” timer is done", isFailure: false), seconds: 8)
            }
        default:
            break
        }
    }

    /// Bubble for a finished run. Activation internals and nested runs are
    /// skipped so one command shows one result.
    private func showResult(of event: AtlasEvent) {
        let trigger = event.payload["trigger"]?.stringValue ?? ""
        guard let runID = event.payload["runId"]?.stringValue.flatMap(UUID.init(uuidString:)),
              let run = try? core.store.run(id: runID),
              bubblePolicy.shouldShow(workflowID: run.workflowID, trigger: trigger, state: run.state, at: Date())
        else { return }
        let failed = run.state == .failed || run.state == .partiallySucceeded
        var bubble = StatusBubble(text: StatusMessages.message(for: run, store: core.store), isFailure: failed, runID: run.id)
        if failed {
            let names = Dictionary(apps.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
            let explanation = FailureExplainer.explain(run) { names[$0] }
            bubble.detail = explanation.message
            bubble.fixTitle = explanation.fixTitle
            bubble.fix = explanation.fix
        }
        showBubble(bubble, seconds: failed ? 20 : 6)
    }

    func showBubble(_ bubble: StatusBubble, seconds: TimeInterval) {
        guard isVisible else { return }
        self.bubble = bubble
        bubbleWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                if self?.bubble?.id == bubble.id { self?.bubble = nil }
            }
        }
        bubbleWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    public func dismissBubble() {
        bubble = nil
    }

    /// Clicking the bubble opens the run in Run History.
    func openBubble() {
        guard let bubble else { return }
        if let suggestion = bubble.suggestion {
            accept(suggestion)
        } else if let runID = bubble.runID {
            host.openRunHistory(runID)
        }
        dismissBubble()
    }

    // MARK: - Suggestions

    private func show(_ suggestion: Suggestion) {
        showBubble(StatusBubble(text: suggestion.title, detail: suggestion.detail, isFailure: suggestion.kind == .workflowFailed,
                                fixTitle: suggestion.actionTitle, fix: suggestion.action, suggestion: suggestion), seconds: 25)
    }

    // MARK: - Recommendations (Stage 07)

    /// Which signals recommendations may use, from the context switches.
    private func applySources() {
        var sources = RecommendationSources()
        sources.activeSpace = settings.context.activeSpace
        sources.runs = settings.context.runs
        sources.schedule = settings.context.timers
        sources.health = settings.context.health
        sources.reviews = settings.context.reviews
        core.time?.recommendations.sources = sources
    }

    private func show(_ recommendation: Recommendation) {
        showBubble(StatusBubble(text: recommendation.title, detail: recommendation.detail, isFailure: recommendation.kind == .repeatedFailure,
                                fixTitle: recommendation.action.title, recommendation: recommendation), seconds: 45)
    }

    func accept(_ recommendation: Recommendation) {
        dismissBubble()
        guard let engine = core.time?.recommendations else { return }
        Task {
            switch await engine.accept(recommendation) {
            case .ran:
                break   // The run's own bubble follows.
            case .done(let message):
                showBubble(StatusBubble(text: message, isFailure: false), seconds: 8)
            case .failed(let message):
                showBubble(StatusBubble(text: message, isFailure: true), seconds: 10)
            case .needsUI(let action):
                if case .disableOrFix(let workflowID, let nodeID) = action { host.openWorkflowAt(workflowID, nodeID) }
            }
        }
    }

    func dismiss(_ recommendation: Recommendation, forever: Bool) {
        core.time?.recommendations.dismiss(recommendation, forever: forever)
        dismissBubble()
    }

    /// The same provider the palette uses, for "Describe an Automation".
    public func generationProvider() -> (any IntentModelProvider)? { provider() }

    func accept(_ suggestion: Suggestion) {
        suggestions.accepted(suggestion)
        perform(suggestion.action)
        dismissBubble()
    }

    func dismiss(_ suggestion: Suggestion, forever: Bool) {
        suggestions.dismissed(suggestion, forever: forever)
        if forever { update { $0.mutedSuggestions.insert(suggestion.kind.rawValue) } }
        dismissBubble()
    }

    func perform(_ action: Suggestion.Action) {
        switch action {
        case .openWorkflowAt(let workflowID, let nodeID): host.openWorkflowAt(workflowID, nodeID)
        case .openPermissions: host.openSection("permissions")
        case .openOrbitFolders: host.showOrbitFolders()
        case .openReviewQueue: host.showReviewQueue()
        case .openLargestFiles: host.showLargestFiles()
        case .openRunHistory(let id): host.openRunHistory(id)
        case .draftWorkflow(let name, let bundleIDs): host.draftWorkflow(name, bundleIDs)
        case .applyLayout(let name):
            let plan = DeterministicParser(vocabulary: vocabulary()).layoutApplyPlan(name)
            Task { _ = await runner.run(plan, text: "", source: .click) }
        }
    }

    // MARK: - Commands

    func vocabulary() -> CommandVocabulary {
        CommandVocabularyBuilder.build(store: core.store, apps: apps)
    }

    func catalog() -> PaletteCatalog {
        PaletteCatalog(vocabulary: vocabulary(), registry: core.registry, files: files)
    }

    func resolver(for vocabulary: CommandVocabulary) -> IntentResolver {
        IntentResolver(parser: DeterministicParser(vocabulary: vocabulary),
                       validator: PlanValidator(registry: core.registry, vocabulary: vocabulary, fileAccess: core.fileAccess),
                       provider: provider())
    }

    func provider() -> (any IntentModelProvider)? {
        switch settings.aiProvider {
        case .off: return nil
        case .onDevice: return OnDeviceModelProvider()
        case .cloud: return CloudModelProvider(model: settings.cloudModel)
        }
    }

    func refreshAIStatus() async {
        guard let provider = provider() else {
            aiStatus = nil
            return
        }
        if let reason = await provider.unavailableReason() {
            aiStatus = reason
        } else {
            aiStatus = "Active: \(provider.displayName)"
        }
    }

    /// Context allowed in settings, for AI requests.
    func context() -> CompanionContext {
        var context = CompanionContext()
        let options = settings.context
        if options.activeSpace, let id = try? core.store.activeSpaceID(), let space = try? core.store.space(id: id) {
            context.activeSpace = space.name
        }
        if options.frontmostApp { context.frontmostApp = NSWorkspace.shared.frontmostApplication?.localizedName }
        if options.runs {
            let runs = (try? core.store.runs(limit: 5)) ?? []
            context.runningWorkflows = runs.filter { $0.state == .running }.map(\.workflowName)
            context.recentResults = runs.filter(\.state.isTerminal).prefix(3).map { "\($0.workflowName): \($0.state.rawValue)" }
        }
        if options.timers {
            context.timers = TimerCenter.shared.active.map { "\($0.name) ends \($0.endsAt.formatted(date: .omitted, time: .shortened))" }
        }
        if options.health, let sample = try? core.store.healthSamples(from: Date().addingTimeInterval(-120)).last {
            context.health = "CPU \(Int(sample.cpu))%, memory \(Int(sample.memoryPercent))%, \(ByteCountFormatter.string(fromByteCount: sample.diskFree, countStyle: .file)) disk free"
        }
        if options.reviews { context.reviewCount = (try? core.store.reviewItems(state: .pending).count) ?? 0 }
        return context
    }

    func commandOpened() { feed(.commandOpened) }
    func commandParsing() { feed(.commandParsing) }
    func commandParsed() { feed(.commandParsed) }
    func commandClosed() { feed(.commandClosed) }

    /// Runs a confirmed plan and handles what it returns.
    func execute(_ plan: CommandPlan, text: String, source: CommandInputSource) {
        Task {
            let outcome = await runner.run(plan, text: text, source: source)
            switch outcome {
            case .run:
                break   // The bubble comes from the run's workflow.finished event.
            case .open(let destination):
                open(destination)
            case .findFiles:
                break   // The palette shows results itself.
            case .paused(let paused):
                showBubble(StatusBubble(text: paused ? "Automations paused" : "Automations resumed", isFailure: false), seconds: 5)
            case .stopped(let count):
                showBubble(StatusBubble(text: count == 0 ? "Nothing was running" : "Stopped \(count) run\(count == 1 ? "" : "s")", isFailure: false), seconds: 5)
            case .failed(let message):
                showBubble(StatusBubble(text: message, isFailure: true), seconds: 10)
            }
        }
    }

    func open(_ destination: CommandPlan.Destination) {
        switch destination {
        case .largestFiles: host.showLargestFiles()
        case .cleanup: host.showCleanup()
        case .reviewQueue: host.showReviewQueue()
        case .search: host.openSection("orbit")
        case .runHistory(let id): host.openRunHistory(id)
        case .section(let name): host.openSection(name)
        case .companionSettings: host.openSection("companion")
        case .health: host.openSection("health")
        case .describeAutomation(let text): host.describeAutomation(text)
        case .today: host.openSection("today")
        case .timeline: host.openSection("timeline")
        }
    }

    func history() -> [String] {
        ((try? core.store.companionCommands()) ?? []).map(\.text)
    }

    // MARK: - Interactivity

    /// ⌥Space: make the character clickable and open the command box.
    public func summon() {
        setInteractive(true)
        showPalette()
    }

    public func showPalette() {
        if !isVisible { overlay.apply(settings) }
        palette.show(near: overlay.characterFrame)
    }

    func setInteractive(_ interactive: Bool) {
        interactiveWork?.cancel()
        isInteractive = interactive
        overlay.updateMouseHandling()
    }

    /// Goes back to click-through a little after the palette closes.
    func scheduleClickThrough() {
        guard settings.clickThrough else { return }
        interactiveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.setInteractive(false) }
        }
        interactiveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: work)
    }

    // MARK: - System

    private func registerHotKeys() {
        hotKeys.forEach { $0.cancel() }
        hotKeys = []
        var problems: [String] = []
        let pairs: [(String, String, () -> Void)] = [
            ("Companion", settings.companionHotKey, { [weak self] in self?.summon() }),
            ("Command palette", settings.paletteHotKey, { [weak self] in self?.showPalette() }),
        ]
        for (label, text, action) in pairs where !text.isEmpty {
            switch HotKey.parse(text) {
            case .success(let key):
                do {
                    hotKeys.append(try environment.registerHotKey(key) {
                        DispatchQueue.main.async { MainActor.assumeIsolated(action) }
                    })
                } catch {
                    problems.append("\(label) shortcut \(key.display): \(error.localizedDescription)")
                }
            case .failure(let error):
                problems.append("\(label) shortcut: \(error.message)")
            }
        }
        hotKeyProblems = problems
    }

    private func observeSystem() {
        // Apps the person opens, for repetition detection. Bundle IDs only.
        appObserver = environment.observeApplications { [weak self] launched, bundleID, _ in
            guard launched else { return }
            Task { @MainActor in self?.appLaunched(bundleID) }
        }
        let distributed = DistributedNotificationCenter.default()
        observers.append(distributed.addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.isScreenLocked = true; self?.updateRendering() }
        })
        observers.append(distributed.addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.isScreenLocked = false; self?.updateRendering(); self?.feed(.activity) }
        })
        observers.append(NotificationCenter.default.addObserver(forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateRendering() }
        })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.objectWillChange.send() }
        })
        // Mac idle → sleeping. One cheap check a minute.
        idleTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkIdle() }
        }
        idleTimer?.tolerance = 15
        updateRendering()
    }

    private func appLaunched(_ bundleID: String) {
        guard bundleID != Bundle.main.bundleIdentifier else { return }
        // Launched by ATLAS within the last 15 s: not the person's own.
        if let when = atlasLaunches[bundleID], Date().timeIntervalSince(when) < 15 { return }
        atlasLaunches = atlasLaunches.filter { Date().timeIntervalSince($0.value) < 60 }
        suggestions.recordManualLaunch(bundleID: bundleID)
    }

    private func checkIdle() {
        let kinds: [CGEventType] = [.mouseMoved, .keyDown, .leftMouseDown, .rightMouseDown, .scrollWheel, .flagsChanged]
        let idle = kinds.map { CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: $0) }.min() ?? 0
        feed(.macIdle(idle >= CompanionStateMachine.sleepAfter))
    }

    private func updateRendering() {
        isRenderingPaused = isScreenLocked || ProcessInfo.processInfo.isLowPowerModeEnabled || !isVisible
    }

    /// Focus: a Space marked as a focus Space is active, or a focus-like timer runs.
    private func updateFocus() {
        let focusWords = ["focus", "study", "deep work", "pomodoro"]
        let timerFocus = TimerCenter.shared.active.contains { timer in focusWords.contains { timer.name.lowercased().contains($0) } }
        let spaceFocus = (try? core.store.activeSpaceID()).flatMap { $0 }.map(settings.focusSpaceIDs.contains) ?? false
        let session = core.time?.focus.session?.state == .running
        feed(.focus(timerFocus || spaceFocus || session))
        updateRendering()
    }
}
