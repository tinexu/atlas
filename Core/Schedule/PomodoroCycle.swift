import Foundation

/// Where a pomodoro cycle is: the current phase and what's done so far.
/// Saved by its owner, so a cycle survives a relaunch.
public struct PomodoroPhase: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case focus, shortBreak, longBreak }
    public var kind: Kind
    /// Focus phases completed so far.
    public var completedFocus: Int
    /// The focus-timer session running this phase; nil while stopped.
    public var sessionID: UUID?
    /// Focus time in completed focus phases.
    public var focusedSeconds: TimeInterval

    public init(kind: Kind = .focus, completedFocus: Int = 0, sessionID: UUID? = nil, focusedSeconds: TimeInterval = 0) {
        self.kind = kind
        self.completedFocus = completedFocus
        self.sessionID = sessionID
        self.focusedSeconds = focusedSeconds
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decodeIfPresent(Kind.self, forKey: .kind) ?? .focus
        completedFocus = try c.decodeIfPresent(Int.self, forKey: .completedFocus) ?? 0
        sessionID = try c.decodeIfPresent(UUID.self, forKey: .sessionID)
        focusedSeconds = try c.decodeIfPresent(TimeInterval.self, forKey: .focusedSeconds) ?? 0
    }

    public var isBreak: Bool { kind != .focus }
    public var title: String {
        switch kind {
        case .focus: return "Focus"
        case .shortBreak: return "Short break"
        case .longBreak: return "Long break"
        }
    }
}

/// Focus and break phases run on the Stage 07 focus timer: each phase is
/// a focus session this cycle owns (so the menu bar and Companion count it
/// down), and the focus timer leaves its end to the cycle. Lockdown and
/// study sessions both use it, each with their own rules via the hooks.
public final class PomodoroCycle: @unchecked Sendable {
    public typealias Kind = PomodoroPhase.Kind

    let focus: FocusService
    let events: EventBus
    public let titlePrefix: String
    public let spaceID: UUID?
    public let settings: PomodoroSettings

    /// The longest the next phase of a kind may run, in seconds, or nil
    /// for no limit (lockdown: its time left; study: focus still to go).
    /// At 30 s or less the cycle stops and calls `onExhausted`.
    public var limit: ((Kind) -> TimeInterval?)?
    /// The phase changed: save it.
    public var onChange: ((PomodoroPhase) -> Void)?
    /// A phase began: the previous kind, the new kind, its minutes, and
    /// whether it follows the end of another phase (worth announcing).
    public var onPhase: ((Kind, Kind, Double, Bool) -> Void)?
    /// Nothing worth starting is left (see `limit`).
    public var onExhausted: (() -> Void)?
    /// A phase was stopped from elsewhere (e.g. the menu bar); the cycle
    /// waits for `resume()`.
    public var onStopped: (() -> Void)?

    private let lock = NSLock()
    private var _phase: PomodoroPhase
    private var starting = false
    private var skipping = false
    private var stopping: UUID?
    private var managerID: UUID?
    private var subscription: EventBus.Subscription?

    public init(focus: FocusService, events: EventBus, titlePrefix: String, settings: PomodoroSettings,
                phase: PomodoroPhase = PomodoroPhase(), spaceID: UUID? = nil) {
        self.focus = focus
        self.events = events
        self.titlePrefix = titlePrefix
        self.settings = settings
        self.spaceID = spaceID
        _phase = phase
        managerID = focus.addManager { [weak self] id in self?.manages(id) ?? false }
        subscription = events.subscribe(AtlasEvent.Name.focusEnded) { [weak self] event in self?.focusEnded(event) }
    }

    deinit {
        if let managerID { focus.removeManager(managerID) }
        if let subscription { events.unsubscribe(subscription) }
    }

    public var phase: PomodoroPhase { lock.withLock { _phase } }

    /// The focus session running the current phase, if any.
    public var currentSession: FocusSession? {
        guard let id = phase.sessionID, let session = focus.session, session.id == id else { return nil }
        return session
    }

    public var isRunning: Bool { currentSession?.state == .running }

    /// Focus time so far, including the focus phase in progress.
    public func focusedSeconds(at now: Date) -> TimeInterval {
        let phase = self.phase
        guard phase.kind == .focus, let current = currentSession else { return phase.focusedSeconds }
        return phase.focusedSeconds + current.elapsed(at: now)
    }

    // MARK: - Control

    /// Starts a phase (the current kind if none is given).
    public func start(_ kind: Kind? = nil, announce: Bool = false) {
        let previous = phase.kind
        let kind = kind ?? previous
        var minutes = Double(Self.minutes(kind, settings))
        if let cap = limit?(kind) {
            guard cap > 30 else {
                setPhase { $0.sessionID = nil }
                onExhausted?()
                return
            }
            minutes = min(minutes, max(1, cap / 60))
        }
        let title = "\(titlePrefix) · \(PomodoroPhase(kind: kind).title)"
        lock.withLock { starting = true }
        let session = focus.start(minutes: minutes, title: title, spaceID: spaceID, onTimeline: kind == .focus)
        lock.withLock { starting = false }
        setPhase {
            $0.kind = kind
            $0.sessionID = session.id
        }
        onPhase?(previous, kind, minutes, announce)
    }

    public func pause() {
        guard isRunning else { return }
        focus.pause()
    }

    /// Resumes a paused phase, or starts the current one again after it was stopped.
    public func resume() {
        if let current = currentSession {
            if current.state == .paused { focus.resume() }
        } else {
            start()
        }
    }

    /// Ends the current phase now and moves on to the next.
    public func skip() {
        if currentSession != nil {
            lock.withLock { skipping = true }
            focus.stop()
        } else {
            advance(elapsed: 0)
        }
    }

    /// Ends the current phase without moving on, and without the focus
    /// timer's own wrap-up (notification, break block).
    public func stop() {
        guard let current = currentSession else { return }
        lock.withLock { stopping = current.id }
        focus.stop()
        lock.withLock { stopping = nil }
        setPhase {
            if $0.kind == .focus { $0.focusedSeconds += current.elapsed(at: focus.environment.now()) }
            $0.sessionID = nil
        }
    }

    // MARK: - Internals

    public static func minutes(_ kind: Kind, _ settings: PomodoroSettings) -> Int {
        switch kind {
        case .focus: return settings.focusMinutes
        case .shortBreak: return settings.shortBreakMinutes
        case .longBreak: return settings.longBreakMinutes
        }
    }

    private func manages(_ id: UUID) -> Bool {
        lock.withLock { starting || stopping == id || _phase.sessionID == id }
    }

    private func setPhase(_ body: (inout PomodoroPhase) -> Void) {
        let updated = lock.withLock { () -> PomodoroPhase in
            body(&_phase)
            return _phase
        }
        onChange?(updated)
    }

    private func focusEnded(_ event: AtlasEvent) {
        guard let id = event.payload["sessionId"]?.stringValue.flatMap(UUID.init(uuidString:)),
              lock.withLock({ _phase.sessionID == id && stopping != id })
        else { return }
        let completed = event.payload["completed"]?.boolValue ?? false
        let elapsed = event.payload["elapsedSeconds"]?.numberValue ?? 0
        let skipped = lock.withLock { () -> Bool in
            defer { skipping = false }
            return skipping
        }
        if completed || skipped {
            advance(elapsed: elapsed)
        } else {
            setPhase {
                if $0.kind == .focus { $0.focusedSeconds += elapsed }
                $0.sessionID = nil
            }
            onStopped?()
        }
    }

    private func advance(elapsed: TimeInterval) {
        let finished = phase
        var next = Kind.focus
        if finished.kind == .focus {
            let completed = finished.completedFocus + 1
            next = completed % max(1, settings.longBreakEvery) == 0 ? .longBreak : .shortBreak
            setPhase {
                $0.completedFocus = completed
                $0.focusedSeconds += elapsed
                $0.sessionID = nil
            }
            // The focus still wanted is done (or nearly): stop here, not at a break.
            if let left = limit?(.focus), left <= 30 {
                onExhausted?()
                return
            }
        } else {
            setPhase { $0.sessionID = nil }
        }
        start(next, announce: true)
    }
}
