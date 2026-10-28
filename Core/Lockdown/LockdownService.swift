import Foundation

/// Lockdown: a self-control focus mode. While it's on, only the allowed
/// apps, ATLAS and the system essentials stay in reach. Apps that were
/// already running are hidden (never quit, they may hold unsaved work); a
/// blocked app opened during lockdown is asked to quit politely (it only
/// just opened) or hidden if it refuses; a hidden one brought forward is
/// hidden again. A pomodoro rhythm runs on the focus timer.
///
/// Everything goes through `SystemAdapter` and `TriggerEnvironment`, the
/// state is saved so a crash or relaunch resumes it, and it can always be
/// changed or ended. Quitting ATLAS ends it, so ATLAS can never lock you
/// out of your Mac.
public final class LockdownService: @unchecked Sendable {
    public static let trigger = "lockdown"
    /// Run History groups lockdown runs under this ID.
    public static let workflowID = UUID(uuidString: "6C0C4D00-0000-4000-8000-00000000AD00")!
    static let sessionKey = "lockdown.session"
    static let summaryKey = "lockdown.lastSummary"
    public static func settingsKey(profileID: UUID) -> String { "lockdown.profile.\(profileID.uuidString)" }
    /// The same app's toast at most this often.
    static let toastInterval: TimeInterval = 20
    /// A launch and the activation right after it count as one attempt.
    static let attemptWindow: TimeInterval = 3
    /// How long after hiding a blocked app to check it stayed hidden.
    var recheckDelay: Duration = .milliseconds(600)

    let store: AtlasStore
    let events: EventBus
    let environment: TriggerEnvironment
    let engine: AutomationEngine
    let system: SystemAdapter
    let focus: FocusService
    /// ATLAS itself, always allowed.
    let ownBundleID: String?
    /// Where to look for a Claude Safari web app.
    var appFolders: [URL] = [
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications"),
        URL(fileURLWithPath: "/Applications"),
    ]

    private let lock = NSLock()
    private var current: LockdownSession?
    private var tokens: [TriggerToken] = []
    private var endTimer: TriggerToken?
    private var focusSubscription: EventBus.Subscription?
    private var lastToast: [String: Date] = [:]
    private var lastAttempt: [String: Date] = [:]
    private var lastAllowed: String?
    /// The focus-timer session lockdown is starting or stopping right now.
    private var transientPhaseID: UUID?
    private var startingPhase = false
    private var skipping = false
    private var _lastSummary: LockdownSummary?
    /// The lockdown `load()` found on disk, which `resume()` picks up.
    private var loadedID: UUID?

    init(store: AtlasStore, events: EventBus, environment: TriggerEnvironment, engine: AutomationEngine,
         system: SystemAdapter, focus: FocusService, ownBundleID: String? = Bundle.main.bundleIdentifier) {
        self.store = store
        self.events = events
        self.environment = environment
        self.engine = engine
        self.system = system
        self.focus = focus
        self.ownBundleID = ownBundleID
        _lastSummary = try? store.preference(Self.summaryKey, as: LockdownSummary.self)
        focus.isManaged = { [weak self] id in self?.manages(id) ?? false }
        focusSubscription = events.subscribe(AtlasEvent.Name.focusEnded) { [weak self] event in self?.focusEnded(event) }
    }

    deinit {
        if let focusSubscription { events.unsubscribe(focusSubscription) }
    }

    public var session: LockdownSession? { lock.withLock { current } }
    public var isActive: Bool { session != nil }
    public var lastSummary: LockdownSummary? { lock.withLock { _lastSummary } }

    // MARK: - Settings

    public func settings(forProfile profileID: UUID) -> LockdownSettings? {
        try? store.preference(Self.settingsKey(profileID: profileID), as: LockdownSettings.self)
    }

    public func setSettings(_ settings: LockdownSettings?, forProfile profileID: UUID) {
        try? store.setPreference(settings, for: Self.settingsKey(profileID: profileID))
    }

    // MARK: - Starting

    /// For one mode: the allowed apps that are installed (including each
    /// link's browser), the links to open, and the names of what's missing.
    public struct Plan: Equatable, Sendable {
        public var modeName: String?
        public var apps: [LockdownApp]
        public var links: [LockdownLink]
        public var missing: [String]
    }

    /// The plan for the mode with `modeID` (else the last used, else the first).
    public func plan(for settings: LockdownSettings, modeID: UUID? = nil) -> Plan {
        let mode = settings.mode(id: modeID)
        var plan = Plan(modeName: mode?.name, apps: [], links: [], missing: [])
        for app in mode?.apps ?? [] {
            if app.bundleID == LockdownApp.claudeToken {
                if let claude = resolveClaude() { plan.apps.append(claude) } else { plan.missing.append(app.name) }
            } else if system.applicationName(for: app.bundleID) != nil {
                plan.apps.append(app)
            } else {
                plan.missing.append(app.name)
            }
        }
        // A link's browser has to stay available for the page to be usable.
        for link in mode?.links ?? [] {
            guard system.applicationName(for: link.browserBundleID) != nil else {
                plan.missing.append("\(link.browserName) (for \(link.host))")
                continue
            }
            if !plan.apps.contains(where: { $0.bundleID == link.browserBundleID }) {
                plan.apps.append(LockdownApp(name: link.browserName, bundleID: link.browserBundleID))
            }
            plan.links.append(link)
        }
        return plan
    }

    /// The Claude desktop app if it's installed, otherwise a Safari web app
    /// for claude.ai (a separate app, so blocking Safari doesn't block it).
    func resolveClaude() -> LockdownApp? {
        if system.applicationName(for: LockdownApp.claudeDesktopBundleID) != nil {
            return LockdownApp(name: "Claude", bundleID: LockdownApp.claudeDesktopBundleID)
        }
        for folder in appFolders {
            let apps = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
            for url in apps where url.pathExtension == "app" && url.lastPathComponent.localizedCaseInsensitiveContains("claude") {
                guard let bundleID = Bundle(url: url)?.bundleIdentifier, bundleID.hasPrefix("com.apple.Safari.WebApp") else { continue }
                return LockdownApp(name: url.deletingPathExtension().lastPathComponent, bundleID: bundleID)
            }
        }
        return nil
    }

    /// Starts lockdown once the Space's apps are open: hides everything
    /// else, starts watching, the end timer and the first focus phase.
    @discardableResult
    public func start(spaceID: UUID, spaceName: String, profileID: UUID, minutes: Double,
                      settings: LockdownSettings, plan: Plan) async -> LockdownSession? {
        if session != nil { finish(.early, quietly: true) }
        let now = environment.now()
        let session = LockdownSession(
            id: UUID(), spaceID: spaceID, spaceName: spaceName, profileID: profileID, startedAt: now,
            endsAt: now.addingTimeInterval(max(1, minutes) * 60), allowed: plan.apps.map(\.bundleID), skipped: plan.missing,
            hiddenAtStart: [], blocked: [:],
            names: Dictionary(plan.apps.map { ($0.bundleID, $0.name) }, uniquingKeysWith: { first, _ in first }),
            settings: settings, modeName: plan.modeName, phase: .init(kind: .focus, completedFocus: 0, sessionID: nil), runID: UUID()
        )
        lock.withLock {
            current = session
            lastAllowed = plan.apps.first?.bundleID
            lastToast = [:]
            lastAttempt = [:]
        }
        save()
        saveRun()
        let hidden = await hideOthers(includingFinder: true)
        mutate { session in
            session.hiddenAtStart = hidden.map(\.bundleID)
            for app in hidden { session.names[app.bundleID] = app.name }
        }
        observe()
        scheduleEnd()
        startPhase(.focus, announce: false)
        if let shortcut = settings.shortcutOnStart, !shortcut.isEmpty { runShortcut(shortcut) }
        publish(AtlasEvent.Name.lockdownStarted)
        return self.session
    }

    // MARK: - Changing

    /// Adding time is instant.
    public func addTime(minutes: Double) {
        change { $0.endsAt = $0.endsAt.addingTimeInterval(minutes * 60) }
    }

    /// Removing time never ends lockdown outright: at least a minute stays.
    /// (The UI asks for confirmation first.)
    public func removeTime(minutes: Double) {
        let floor = environment.now().addingTimeInterval(60)
        change { $0.endsAt = max(floor, $0.endsAt.addingTimeInterval(-minutes * 60)) }
    }

    /// A new end time, at least a minute from now.
    public func setEnd(_ date: Date) {
        let floor = environment.now().addingTimeInterval(60)
        change { $0.endsAt = max(floor, date) }
    }

    /// Ends lockdown now (the UI confirms first when it's early).
    @discardableResult
    public func end(early: Bool = true) -> LockdownSummary? {
        finish(early ? .early : .timer)
    }

    /// Quitting ATLAS ends lockdown immediately: the emergency exit that
    /// always works. Synchronous, for the app's termination.
    public func endBecauseATLASIsQuitting() {
        finish(.quit, quietly: true)
    }

    /// Something to tell the user without blocking anything.
    public func notice(_ message: String) {
        events.publish(AtlasEvent(AtlasEvent.Name.lockdownNotice, payload: ["message": .string(message)]))
    }

    /// Unhides the apps tidied away when the last lockdown started.
    public func bringBackHiddenApps() async {
        guard var summary = lastSummary else { return }
        for bundleID in summary.hiddenAtStart {
            _ = try? await system.unhideApplication(bundleID: bundleID)
        }
        summary.hiddenAtStart = []
        lock.withLock { _lastSummary = summary }
        try? store.setPreference(summary, for: Self.summaryKey)
    }

    // MARK: - Pomodoro

    public func pausePhase() {
        guard let id = session?.phase.sessionID, focus.session?.id == id else { return }
        focus.pause()
        publish(AtlasEvent.Name.lockdownChanged)
    }

    /// Resumes a paused phase, or starts the current one again after it was stopped.
    public func resumePhase() {
        guard let session else { return }
        if let id = session.phase.sessionID, focus.session?.id == id {
            focus.resume()
            publish(AtlasEvent.Name.lockdownChanged)
        } else {
            startPhase(session.phase.kind, announce: false)
        }
    }

    public func skipPhase() {
        guard let session else { return }
        if let id = session.phase.sessionID, focus.session?.id == id {
            lock.withLock { skipping = true }
            focus.stop()
        } else {
            advance()
        }
    }

    private func phaseMinutes(_ kind: LockdownSession.Phase.Kind, _ settings: PomodoroSettings) -> Int {
        switch kind {
        case .focus: return settings.focusMinutes
        case .shortBreak: return settings.shortBreakMinutes
        case .longBreak: return settings.longBreakMinutes
        }
    }

    private func startPhase(_ kind: LockdownSession.Phase.Kind, announce: Bool) {
        guard let session else { return }
        let wasBreak = session.phase.isBreak
        let remaining = session.remaining(at: environment.now()) / 60
        let minutes = min(Double(phaseMinutes(kind, session.settings.pomodoro)), max(1, remaining))
        let title = kind == .focus ? "Lockdown · Focus" : "Lockdown · \(LockdownSession.Phase(kind: kind, completedFocus: 0).title)"
        lock.withLock { startingPhase = true }
        let phaseSession = focus.start(minutes: minutes, title: title, spaceID: session.spaceID, onTimeline: kind == .focus)
        lock.withLock { startingPhase = false }
        mutate {
            $0.phase.kind = kind
            $0.phase.sessionID = phaseSession.id
        }
        events.publish(AtlasEvent(AtlasEvent.Name.lockdownPhase, payload: [
            "phase": .string(kind.rawValue), "minutes": .number(minutes), "announce": .bool(announce),
        ]))
        if announce {
            let body = kind == .focus ? "Back to focus for \(Int(minutes)) min." : "Take \(Int(minutes)) min. Other apps stay locked."
            let unlocked = kind != .focus && session.settings.pomodoro.unlockDuringBreaks
            let system = self.system
            Task { try? await system.postNotification(title: kind == .focus ? "Focus" : "Break time",
                                                      body: unlocked ? "Take \(Int(minutes)) min. Other apps are unlocked until it ends." : body) }
        }
        // Back from a break that let other apps out: lock them away again.
        if kind == .focus, wasBreak, session.settings.pomodoro.unlockDuringBreaks {
            Task { _ = await hideOthers(includingFinder: false) }
        }
    }

    private func advance() {
        guard let session else { return }
        let every = max(1, session.settings.pomodoro.longBreakEvery)
        var next = LockdownSession.Phase.Kind.focus
        var completed = session.phase.completedFocus
        if session.phase.kind == .focus {
            completed += 1
            next = completed % every == 0 ? .longBreak : .shortBreak
        }
        mutate {
            $0.phase.completedFocus = completed
            $0.phase.sessionID = nil
        }
        // Not worth a new phase in the last half minute.
        guard session.remaining(at: environment.now()) > 30 else { return }
        startPhase(next, announce: true)
    }

    private func manages(_ id: UUID) -> Bool {
        lock.withLock { startingPhase || transientPhaseID == id || current?.phase.sessionID == id }
    }

    private func focusEnded(_ event: AtlasEvent) {
        guard let id = event.payload["sessionId"]?.stringValue.flatMap(UUID.init(uuidString:)),
              let session, session.phase.sessionID == id
        else { return }
        let completed = event.payload["completed"]?.boolValue ?? false
        let skipped = lock.withLock { () -> Bool in
            defer { skipping = false }
            return skipping
        }
        if completed || skipped {
            advance()
        } else {
            // Stopped from elsewhere (e.g. the menu bar): the pomodoro waits for Start.
            mutate { $0.phase.sessionID = nil }
            publish(AtlasEvent.Name.lockdownChanged)
        }
    }

    // MARK: - Enforcement

    private func observe() {
        stopObserving()
        let tokens = [
            environment.observeApplications { [weak self] launched, bundleID, name in
                guard launched, let self else { return }
                let at = self.environment.now()
                Task { await self.handleLaunch(bundleID, name: name, at: at) }
            },
            environment.observeActivations { [weak self] bundleID, name in
                guard let self else { return }
                let at = self.environment.now()
                Task { await self.handleActivation(bundleID, name: name, at: at) }
            },
            environment.observeWake { [weak self] in
                guard let self else { return }
                Task { await self.handleWake() }
            },
        ]
        lock.withLock { self.tokens = tokens }
    }

    private func stopObserving() {
        let old = lock.withLock { () -> [TriggerToken] in
            defer { tokens = []; endTimer = nil }
            return tokens + [endTimer].compactMap { $0 }
        }
        old.forEach { $0.cancel() }
    }

    private func verdict(_ bundleID: String, in session: LockdownSession) -> LockdownPolicy.Verdict {
        LockdownPolicy.verdict(for: bundleID, allowed: session.allowed, ownBundleID: ownBundleID)
    }

    /// A blocked app opened during lockdown: it has no unsaved work yet, so
    /// ask it to quit (never force); hide it if it won't.
    func handleLaunch(_ bundleID: String, name: String, at date: Date) async {
        guard let session, session.isEnforcing, verdict(bundleID, in: session) == .blocked else { return }
        countAttempt(bundleID, name: name, at: date)
        let quit = (try? await system.quitApplication(bundleID: bundleID)) ?? false
        if !quit { _ = try? await system.hideApplication(bundleID: bundleID) }
        await bringForwardAllowed()
    }

    /// A blocked app came to the front (Cmd-Tab, Dock): hide it again and
    /// bring back the last allowed app.
    func handleActivation(_ bundleID: String, name: String, at date: Date) async {
        guard let session else { return }
        switch verdict(bundleID, in: session) {
        case .allowed:
            if bundleID != ownBundleID { lock.withLock { lastAllowed = bundleID } }
        case .essential:
            break
        case .blocked:
            guard session.isEnforcing else { return }
            countAttempt(bundleID, name: name, at: date)
            await keepHidden(bundleID)
        }
    }

    /// Hides a blocked app and brings an allowed one forward, then checks
    /// shortly after that it stayed in the background; some apps reopen a
    /// window as they come forward.
    private func keepHidden(_ bundleID: String) async {
        for attempt in 0..<3 {
            _ = try? await system.hideApplication(bundleID: bundleID)
            await bringForwardAllowed()
            if attempt == 2 { return }
            try? await Task.sleep(for: recheckDelay)
            guard let session, session.isEnforcing else { return }
            let front = system.runningApplications().first(where: \.isActive)?.bundleID
            guard front == bundleID else { return }
        }
    }

    /// After sleep: end if time ran out, otherwise tidy away anything that
    /// slipped through.
    func handleWake() async {
        guard let session else { return }
        if session.remaining(at: environment.now()) <= 0 {
            finish(.timer)
        } else if session.isEnforcing {
            _ = await hideOthers(includingFinder: false)
        }
    }

    private func bringForwardAllowed() async {
        guard let bundleID = lock.withLock({ lastAllowed }) else { return }
        _ = try? await system.activateApplication(bundleID: bundleID)
    }

    /// Hides every running app lockdown doesn't allow (and Finder, at the start).
    private func hideOthers(includingFinder: Bool) async -> [RunningApplication] {
        guard let session else { return [] }
        var hidden: [RunningApplication] = []
        for app in system.runningApplications() {
            let tidy = verdict(app.bundleID, in: session) == .blocked
                || (includingFinder && LockdownEssentials.hiddenAtStart.contains(app.bundleID))
            guard tidy else { continue }
            if (try? await system.hideApplication(bundleID: app.bundleID)) == true { hidden.append(app) }
        }
        return hidden
    }

    /// Counts a blocked attempt (a launch and its activation count once) and
    /// sends a toast, at most every `toastInterval` per app.
    /// `now` is when the event arrived, not when it's handled.
    private func countAttempt(_ bundleID: String, name: String, at now: Date) {
        let result = lock.withLock { () -> (LockdownSession, String)? in
            guard var session = current else { return nil }
            if let last = lastAttempt[bundleID], abs(now.timeIntervalSince(last)) < Self.attemptWindow { return nil }
            lastAttempt[bundleID] = now
            session.blocked[bundleID, default: 0] += 1
            session.names[bundleID] = name
            var toast = ""
            if lastToast[bundleID].map({ now.timeIntervalSince($0) >= Self.toastInterval }) ?? true {
                lastToast[bundleID] = now
                toast = Self.toast(for: name, session: session, now: now)
            }
            current = session
            return (session, toast)
        }
        guard let (session, toast) = result else { return }
        save(session)
        events.publish(AtlasEvent(AtlasEvent.Name.lockdownBlocked, payload: [
            "bundleId": .string(bundleID), "name": .string(name),
            "count": .number(Double(session.blocked[bundleID] ?? 0)), "toast": .string(toast),
        ]))
    }

    /// "Safari is locked until 3:40 PM — 52 min left."
    static func toast(for name: String, session: LockdownSession, now: Date) -> String {
        let until = session.endsAt.formatted(date: .omitted, time: .shortened)
        return "\(name) is locked until \(until) — \(LockdownFormat.duration(session.remaining(at: now))) left."
    }

    // MARK: - Ending

    private func scheduleEnd() {
        guard let session else { return }
        let id = session.id
        let token = environment.schedule(at: session.endsAt) { [weak self] in self?.endTimerFired(id) }
        let old = lock.withLock { () -> TriggerToken? in
            defer { endTimer = token }
            return endTimer
        }
        old?.cancel()
    }

    private func endTimerFired(_ id: UUID) {
        guard let session, session.id == id else { return }
        if session.remaining(at: environment.now()) > 1 {
            scheduleEnd()
        } else {
            finish(.timer)
        }
    }

    @discardableResult
    private func finish(_ reason: LockdownSummary.Reason, quietly: Bool = false) -> LockdownSummary? {
        guard let session = lock.withLock({ () -> LockdownSession? in
            defer { current = nil }
            return current
        }) else { return nil }
        stopObserving()
        // Its pomodoro phase is ours: stop it without the focus timer's own wrap-up.
        if let id = session.phase.sessionID, focus.session?.id == id {
            lock.withLock { transientPhaseID = id }
            focus.stop()
            lock.withLock { transientPhaseID = nil }
        }
        let now = environment.now()
        var counts: [String: Int] = [:]
        for (bundleID, count) in session.blocked { counts[session.name(of: bundleID), default: 0] += count }
        let summary = LockdownSummary(
            spaceName: session.spaceName, focusedSeconds: min(now, session.endsAt).timeIntervalSince(session.startedAt),
            blockedCounts: counts, skipped: session.skipped, hiddenAtStart: session.hiddenAtStart, reason: reason, endedAt: now
        )
        lock.withLock { _lastSummary = summary }
        try? store.setPreference(summary, for: Self.summaryKey)
        try? store.setPreference(LockdownSession?.none, for: Self.sessionKey)
        saveRun(session, summary: summary)
        events.publish(AtlasEvent(AtlasEvent.Name.lockdownEnded, payload: [
            "headline": .string(summary.headline), "reason": .string(reason.rawValue),
            "spaceId": .string(session.spaceID.uuidString),
        ]))
        guard !quietly else { return summary }

        let system = self.system
        let title = reason == .early ? "Lockdown ended" : "Lockdown complete"
        Task { try? await system.postNotification(title: title, body: summary.headline) }
        if let shortcut = session.settings.shortcutOnEnd, !shortcut.isEmpty { runShortcut(shortcut) }
        if let afterID = session.settings.afterWorkflowID, let workflow = try? store.workflow(id: afterID) {
            let engine = self.engine
            Task { _ = await engine.run(workflow, trigger: Self.trigger) }
        }
        return summary
    }

    // MARK: - Relaunch

    /// Loads a lockdown that was on when ATLAS last closed. Called before
    /// the focus timer restores, so a phase that ended meanwhile advances.
    func load() {
        guard let saved = try? store.preference(Self.sessionKey, as: LockdownSession.self) else { return }
        lock.withLock {
            current = saved
            lastAllowed = saved.allowed.first
            loadedID = saved.id
        }
    }

    /// Resumes a loaded lockdown if time remains, or ends it cleanly.
    func resume() async {
        // Only the lockdown loaded from disk, once (not one started since).
        let loaded = lock.withLock { () -> UUID? in
            defer { loadedID = nil }
            return loadedID
        }
        guard let session, session.id == loaded else { return }
        guard session.remaining(at: environment.now()) > 0 else {
            finish(.expiredWhileClosed)
            return
        }
        observe()
        scheduleEnd()
        if session.isEnforcing { _ = await hideOthers(includingFinder: false) }
        if let id = self.session?.phase.sessionID, focus.session?.id == id {
            // The phase is still running on the focus timer.
        } else if let kind = self.session?.phase.kind {
            startPhase(kind, announce: false)
        }
        publish(AtlasEvent.Name.lockdownStarted)
    }

    // MARK: - Bookkeeping

    private func mutate(_ body: (inout LockdownSession) -> Void) {
        let updated = lock.withLock { () -> LockdownSession? in
            guard var session = current else { return nil }
            body(&session)
            current = session
            return session
        }
        if let updated { save(updated) }
    }

    private func change(_ body: (inout LockdownSession) -> Void) {
        guard session != nil else { return }
        mutate(body)
        scheduleEnd()
        publish(AtlasEvent.Name.lockdownChanged)
    }

    private func save(_ session: LockdownSession? = nil) {
        guard let session = session ?? self.session else { return }
        try? store.setPreference(session, for: Self.sessionKey)
    }

    private func publish(_ name: String) {
        guard let session else { return }
        events.publish(AtlasEvent(name, payload: [
            "sessionId": .string(session.id.uuidString), "spaceName": .string(session.spaceName),
            "endsAt": .number(session.endsAt.timeIntervalSince1970), "phase": .string(session.phase.kind.rawValue),
        ]))
    }

    private func runShortcut(_ name: String) {
        let engine = self.engine
        Task { _ = await engine.invoke(ShortcutRunAction.id, parameters: ["name": .string(name)], source: Self.trigger) }
    }

    /// One Run History entry per lockdown (trigger "lockdown"): saved when
    /// it starts, completed with what was blocked when it ends.
    private func saveRun(_ session: LockdownSession? = nil, summary: LockdownSummary? = nil) {
        guard let session = session ?? self.session else { return }
        let end = summary?.endedAt
        var steps: [StepRecord] = []
        func step(_ label: String, _ state: RunState = .succeeded, message: String? = nil) {
            steps.append(StepRecord(position: steps.count, nodeID: UUID(), actionID: "lockdown", label: label, state: state,
                                    attempts: 1, startedAt: session.startedAt, finishedAt: end ?? session.startedAt, message: message))
        }
        let allowedNames = session.allowed.map(session.name(of:)).joined(separator: ", ")
        step("Locked in \(session.spaceName)\(session.modeName.map { " (\($0))" } ?? "") until \(session.endsAt.formatted(date: .omitted, time: .shortened))",
             message: allowedNames.isEmpty ? "Only ATLAS and system apps allowed" : "Allowed: \(allowedNames)")
        if !session.skipped.isEmpty {
            step("Skipped (not installed): \(session.skipped.joined(separator: ", "))", .skipped)
        }
        if !session.hiddenAtStart.isEmpty {
            step("Hid \(session.hiddenAtStart.count) app\(session.hiddenAtStart.count == 1 ? "" : "s")",
                 message: session.hiddenAtStart.map(session.name(of:)).joined(separator: ", "))
        }
        for (name, count) in summary?.blocked ?? [] {
            step("Blocked \(name) ×\(count)")
        }
        if let summary {
            let how: String
            switch summary.reason {
            case .timer: how = "Ended on time"
            case .early: how = "Ended early"
            case .quit: how = "Ended because ATLAS quit"
            case .expiredWhileClosed: how = "Ended while ATLAS was closed"
            }
            step(how, message: summary.headline)
        }
        let run = WorkflowRun(
            id: session.runID, workflowID: Self.workflowID, workflowName: "Lockdown · \(session.spaceName)", trigger: Self.trigger,
            state: summary == nil ? .running : .succeeded, startedAt: session.startedAt, finishedAt: end, steps: steps,
            triggerPayload: ["spaceId": .string(session.spaceID.uuidString),
                             "minutes": .number((session.endsAt.timeIntervalSince(session.startedAt) / 60).rounded())]
        )
        try? store.saveRun(run)
    }
}
