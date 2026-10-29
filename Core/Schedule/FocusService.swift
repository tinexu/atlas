import Foundation

/// Settings for focus sessions, kept as a preference.
public struct FocusSettings: Codable, Equatable, Sendable {
    public enum EndAction: String, Codable, CaseIterable, Sendable, Identifiable {
        case nothing, restoreSnapshot, activateSpace
        public var id: Self { self }
        public var title: String {
            switch self {
            case .nothing: return "Nothing else"
            case .restoreSnapshot: return "Restore my windows from before"
            case .activateSpace: return "Activate a Space"
            }
        }
    }

    public var defaultMinutes = 25
    /// Space ID → minutes ("Make Deep Work 90 minutes by default").
    public var defaultMinutesBySpace: [String: Int] = [:]
    public var notifyAtEnd = true
    /// Adds a break block after a session; nil for none.
    public var breakMinutes: Int? = 5
    public var endAction: EndAction = .nothing
    public var endSpaceName: String?
    /// macOS doesn't let apps turn Focus on directly; these Shortcuts (run
    /// with the `shortcuts` tool) can, e.g. "Turn On Do Not Disturb".
    public var shortcutOnStart: String?
    public var shortcutOnEnd: String?

    public init() {}

    public func minutes(forSpace spaceID: UUID?) -> Int {
        spaceID.flatMap { defaultMinutesBySpace[$0.uuidString] } ?? defaultMinutes
    }
}

/// Runs focus sessions. A session appears on the timeline as a focus
/// block, counts down in the menu bar and on the Companion, and can be
/// paused, extended or stopped from anywhere. What happens when it ends
/// (notification, Focus shortcut, restoring windows) runs through the
/// engine like any other automation.
public final class FocusService: @unchecked Sendable {
    public static let settingsKey = "focus.settings"

    let store: AtlasStore
    let events: EventBus
    let environment: TriggerEnvironment
    let engine: AutomationEngine
    weak var schedule: ScheduleService?
    private let lock = NSLock()
    private var endTimer: TriggerToken?
    private var current: FocusSession?
    /// Sessions another service runs as phases (a pomodoro cycle). They
    /// count down like any session, but their end is left to that service:
    /// no end notification, Focus shortcut or break block from here.
    private var managers: [UUID: (UUID) -> Bool] = [:]

    /// Registers a check for sessions that service owns; returns a token for `removeManager`.
    func addManager(_ owns: @escaping (UUID) -> Bool) -> UUID {
        let id = UUID()
        lock.withLock { managers[id] = owns }
        return id
    }

    func removeManager(_ id: UUID) {
        lock.withLock { _ = managers.removeValue(forKey: id) }
    }

    private func isManaged(_ sessionID: UUID) -> Bool {
        lock.withLock { Array(managers.values) }.contains { $0(sessionID) }
    }

    init(store: AtlasStore, events: EventBus, environment: TriggerEnvironment, engine: AutomationEngine) {
        self.store = store
        self.events = events
        self.environment = environment
        self.engine = engine
    }

    /// Picks up a session that was running when ATLAS quit.
    func restore() {
        guard let session = try? store.activeFocusSession() else { return }
        lock.withLock { current = session }
        if session.state == .running, session.remaining(at: environment.now()) <= 0 {
            finish(completed: true)
        } else if session.state == .running {
            scheduleEnd(session)
        }
    }

    public var settings: FocusSettings {
        get { (try? store.preference(Self.settingsKey, as: FocusSettings.self)) ?? FocusSettings() }
        set { try? store.setPreference(newValue, for: Self.settingsKey) }
    }

    public var session: FocusSession? { lock.withLock { current } }

    // MARK: - Control

    /// Starts a session, ending any current one. It shows on the timeline as
    /// a focus block unless it belongs to a block already.
    @discardableResult
    public func start(minutes: Double? = nil, title: String? = nil, spaceID: UUID? = nil, blockID: UUID? = nil,
                      onTimeline: Bool = true) -> FocusSession {
        if session != nil { finish(completed: false, quietly: true) }
        let now = environment.now()
        let length = (minutes ?? Double(settings.minutes(forSpace: spaceID))) * 60
        var session = FocusSession(blockID: blockID, title: title ?? "Focus", plannedSeconds: length, startedAt: now, spaceID: spaceID)
        if blockID == nil, onTimeline, let schedule {
            let block = ScheduleBlock(title: session.title, start: now, end: now.addingTimeInterval(length), kind: .focus, spaceID: spaceID)
            if let saved = try? schedule.save(block) {
                session.blockID = saved.id
                // It's starting now: mark the occurrence active so it isn't "started" twice.
                try? store.saveOccurrence(BlockOccurrence(blockID: saved.id, start: saved.start, state: .active))
            }
        }
        try? store.saveFocusSession(session)
        lock.withLock { current = session }
        scheduleEnd(session)
        publish(AtlasEvent.Name.focusStarted, session)
        if isManaged(session.id) { return session }
        if let shortcut = settings.shortcutOnStart, !shortcut.isEmpty { runShortcut(shortcut, label: "Focus started") }
        return session
    }

    public func pause() {
        guard var session = session, session.state == .running else { return }
        session.pauses.append(.init(start: environment.now()))
        session.state = .paused
        update(session)
        endTimer?.cancel()
        publish(AtlasEvent.Name.focusPaused, session)
    }

    public func resume() {
        guard var session = session, session.state == .paused else { return }
        if let last = session.pauses.indices.last { session.pauses[last].end = environment.now() }
        session.state = .running
        update(session)
        scheduleEnd(session)
        publish(AtlasEvent.Name.focusResumed, session)
    }

    public func extend(minutes: Double) {
        guard var session = session else { return }
        session.extendedSeconds += minutes * 60
        update(session)
        if session.state == .running { scheduleEnd(session) }
        publish(AtlasEvent.Name.focusExtended, session, extra: ["minutes": .number(minutes)])
    }

    /// Ends the session now.
    public func stop() {
        finish(completed: false)
    }

    // MARK: - Internals

    private func update(_ session: FocusSession) {
        lock.withLock { current = session }
        try? store.saveFocusSession(session)
        // Keep its timeline block in step with when it will really end.
        if let blockID = session.blockID, let schedule, var block = try? store.block(id: blockID), block.kind == .focus {
            let end = session.state == .ended ? (session.endedAt ?? environment.now()) : session.endsAt(from: environment.now())
            if abs(block.end.timeIntervalSince(end)) > 30 {
                block.end = max(end, block.start.addingTimeInterval(60))
                _ = try? schedule.save(block)
            }
        }
    }

    private func scheduleEnd(_ session: FocusSession) {
        endTimer?.cancel()
        let id = session.id
        endTimer = environment.schedule(at: session.endsAt(from: environment.now())) { [weak self] in
            guard let self, self.session?.id == id, self.session?.state == .running else { return }
            if (self.session?.remaining(at: self.environment.now()) ?? 0) > 1 {
                if let session = self.session { self.scheduleEnd(session) }
            } else {
                self.finish(completed: true)
            }
        }
    }

    private func finish(completed: Bool, quietly: Bool = false) {
        guard var session = session else { return }
        // Decided before `focus.ended` goes out: its owner may move on to
        // its next session while handling it.
        let managed = isManaged(session.id)
        endTimer?.cancel()
        let now = environment.now()
        if session.state == .paused, let last = session.pauses.indices.last, session.pauses[last].end == nil {
            session.pauses[last].end = now
        }
        session.state = .ended
        session.endedAt = now
        update(session)
        lock.withLock { current = nil }
        if let blockID = session.blockID {
            try? store.saveOccurrence(BlockOccurrence(blockID: blockID, start: (try? store.block(id: blockID))?.start ?? session.startedAt,
                                                      state: .completed, updatedAt: now))
        }
        publish(AtlasEvent.Name.focusEnded, session, extra: ["completed": .bool(completed),
                                                             "elapsedMinutes": .number((session.elapsed(at: now) / 60).rounded()),
                                                             "elapsedSeconds": .number(session.elapsed(at: now))])
        guard !quietly, !managed else { return }
        afterSession(session, completed: completed)
    }

    /// Notification, Focus shortcut, break block and end action, as one run.
    private func afterSession(_ session: FocusSession, completed: Bool) {
        let settings = self.settings
        var steps: [WorkflowStep] = []
        if settings.notifyAtEnd {
            let minutes = Int((session.elapsed(at: environment.now()) / 60).rounded())
            steps.append(WorkflowStep(actionID: ShowNotificationAction.id, parameters: [
                "title": .string(completed ? "\(session.title) done" : "\(session.title) stopped"),
                "body": .string("\(minutes) min of focus.\(settings.breakMinutes.map { " Take a \($0)-minute break." } ?? "")"),
            ]))
        }
        if let shortcut = settings.shortcutOnEnd, !shortcut.isEmpty {
            steps.append(WorkflowStep(actionID: ShortcutRunAction.id, parameters: ["name": .string(shortcut)]))
        }
        switch settings.endAction {
        case .restoreSnapshot:
            if let blockID = session.blockID, let block = try? store.block(id: blockID) {
                steps.append(WorkflowStep(actionID: "window.snapshot.restore", parameters: ["snapshot": .string(ScheduleAutomation.snapshotName(for: block))]))
            }
        case .activateSpace:
            if let space = settings.endSpaceName { steps.append(WorkflowStep(actionID: "space.activate", parameters: ["space": .string(space)])) }
        case .nothing:
            break
        }
        if completed, let minutes = settings.breakMinutes, minutes > 0, let schedule {
            let now = environment.now()
            _ = try? schedule.save(ScheduleBlock(title: "Break", start: now, end: now.addingTimeInterval(Double(minutes) * 60), kind: .breakTime))
        }
        guard !steps.isEmpty else { return }
        let workflow = Workflow(name: "After \(session.title)", summary: "When a focus session ends", failurePolicy: .continueOnFailure, steps: steps)
        let engine = self.engine
        Task { _ = await engine.run(workflow, trigger: "focus") }
    }

    private func runShortcut(_ name: String, label: String) {
        let engine = self.engine
        Task { _ = await engine.invoke(ShortcutRunAction.id, parameters: ["name": .string(name)], source: "focus") }
    }

    private func publish(_ name: String, _ session: FocusSession, extra: ActionParameters = [:]) {
        let now = environment.now()
        var payload: ActionParameters = [
            "sessionId": .string(session.id.uuidString),
            "title": .string(session.title),
            "seconds": .number(session.totalSeconds),
            "remaining": .number(session.remaining(at: now)),
            "endsAt": .number(session.endsAt(from: now).timeIntervalSince1970),
            "spaceId": .string(session.spaceID?.uuidString ?? ""),
            "blockId": .string(session.blockID?.uuidString ?? ""),
            "plannedMinutes": .number(session.plannedSeconds / 60),
            "extendedMinutes": .number(session.extendedSeconds / 60),
        ]
        payload.merge(extra) { $1 }
        events.publish(AtlasEvent(name, payload: payload))
    }
}

// MARK: - Actions

/// `timer.focus.start`: starts a focus session from a workflow, a room
/// object or the Companion.
public struct StartFocusAction: AtlasAction {
    public static let id: ActionID = "timer.focus.start"
    final class Ref: @unchecked Sendable { weak var focus: FocusService?; weak var store: AtlasStore? }
    let ref = Ref()

    public let descriptor = ActionDescriptor(
        id: StartFocusAction.id,
        title: "Start Focus Session",
        summary: "Starts a timed focus session, shown on the timeline, in the menu bar and on the Companion.",
        category: "Timing",
        symbolName: "scope",
        parameters: [
            ParameterSpec(key: "minutes", label: "Minutes", kind: .number, isRequired: false,
                          help: "Leave empty for the default (or the Space's default)", minimum: 1, maximum: 600),
            ParameterSpec(key: "space", label: "Space", kind: .text, isRequired: false, help: "Name of the Space it's for",
                          choicesFrom: "spaces"),
            ParameterSpec(key: "title", label: "Title", kind: .text, isRequired: false, help: "e.g. Deep Work"),
        ],
        isIdempotent: false,
        defaultTimeout: 5,
        outputs: [OutputSpec(key: "endsAt", label: "Ends at", type: .string)]
    )

    init(focus: FocusService, store: AtlasStore) {
        ref.focus = focus
        ref.store = store
    }

    public func perform(_ parameters: ActionParameters, context: ActionContext) async throws -> ActionOutput {
        guard let focus = ref.focus else { throw ActionError.failed("Focus sessions aren't available right now.") }
        var spaceID: UUID?
        if let name = parameters.optionalString("space"), !name.isEmpty {
            guard let id = (try? ref.store?.database.query("SELECT id FROM space WHERE name = ? COLLATE NOCASE;", [.text(name)]))?.first?.uuid("id") else {
                throw ActionError.invalidParameter("Space", reason: "no Space is called “\(name)”.")
            }
            spaceID = id
        }
        let session = focus.start(minutes: parameters["minutes"]?.numberValue, title: parameters.optionalString("title") ?? parameters.optionalString("space"),
                                  spaceID: spaceID)
        let ends = session.endsAt(from: Date()).formatted(date: .omitted, time: .shortened)
        return ActionOutput("Focus until \(ends)", values: ["endsAt": .string(ends)])
    }
}

public struct StopFocusAction: AtlasAction {
    public static let id: ActionID = "timer.focus.stop"
    let ref = StartFocusAction.Ref()

    public let descriptor = ActionDescriptor(
        id: StopFocusAction.id,
        title: "Stop Focus Session",
        summary: "Ends the current focus session early.",
        category: "Timing",
        symbolName: "stop.circle",
        isIdempotent: true,
        defaultTimeout: 5
    )

    init(focus: FocusService) { ref.focus = focus }

    public func perform(_ parameters: ActionParameters, context: ActionContext) async throws -> ActionOutput {
        guard let focus = ref.focus, focus.session != nil else { throw ActionError.failed("No focus session is running.") }
        focus.stop()
        return ActionOutput("Stopped the focus session")
    }
}

/// `shortcut.run`: runs one of your Shortcuts by name with the `shortcuts`
/// tool. This is how a focus session can turn on a macOS Focus, which apps
/// can't do directly.
public struct ShortcutRunAction: AtlasAction {
    public static let id: ActionID = "shortcut.run"
    /// Replaced in tests.
    nonisolated(unsafe) static var runner: @Sendable (String) async throws -> Void = { name in
        #if os(macOS)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
        process.arguments = ["run", name]
        let errors = Pipe()
        process.standardError = errors
        // Wait without blocking a thread; a timeout or cancel ends the shortcut.
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                process.terminationHandler = { _ in continuation.resume() }
                do { try process.run() } catch {
                    process.terminationHandler = nil
                    continuation.resume(throwing: error)
                }
            }
        } onCancel: {
            if process.isRunning { process.terminate() }
        }
        guard process.terminationStatus == 0 else {
            let message = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw ActionError.failed(message.isEmpty ? "The shortcut “\(name)” didn't run. Check its name in the Shortcuts app." : message)
        }
        #endif
    }

    public let descriptor = ActionDescriptor(
        id: ShortcutRunAction.id,
        title: "Run Shortcut",
        summary: "Runs one of your Shortcuts by name, e.g. “Turn On Do Not Disturb”.",
        category: "Automation",
        symbolName: "square.2.layers.3d",
        parameters: [ParameterSpec(key: "name", label: "Shortcut name", kind: .text, help: "Exactly as it appears in the Shortcuts app")],
        sideEffects: [.showsUI],
        isIdempotent: false,
        defaultTimeout: 60
    )

    public init() {}

    public func perform(_ parameters: ActionParameters, context: ActionContext) async throws -> ActionOutput {
        let name = try parameters.requiredString("name")
        try await Self.runner(name)
        return ActionOutput("Ran the “\(name)” shortcut")
    }
}
