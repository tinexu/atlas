import AtlasCore
import AtlasSpaces
import Foundation

public enum CreativeSessionError: Error, LocalizedError, Equatable {
    case timerUnavailable
    case lockedDown

    public var errorDescription: String? {
        switch self {
        case .timerUnavailable: return "The focus timer isn't available right now."
        case .lockedDown: return "Lockdown is on; end it before starting a creative session."
        }
    }
}

/// Creative sessions: the mug. A session is one long block on the Stage 07
/// focus timer (flow state, no pomodoro), with optional gentle reminders to
/// take a break that never pause anything. It ends when the time is up,
/// you end it, or you leave the Creative Studio. Never blocks or hides apps.
public final class CreativeSessions: @unchecked Sendable {
    static let activeKey = "creative.activeSession"
    static let summaryKey = "creative.lastSummary"

    struct Active: Codable {
        var session: CreativeSession
        var goalSeconds: TimeInterval
        var phase: PomodoroPhase
        /// Break reminders already sent (one per `breakEveryMinutes` of creating).
        var remindersSent = 0
    }

    let core: AtlasCore
    let service: CreativeService
    var store: AtlasStore { core.store }
    private let lock = NSLock()
    private var active: Active?
    private var cycle: PomodoroCycle?
    private var _lastSummary: CreativeSummary?
    private var _finished = 0
    private var subscriptions: [EventBus.Subscription] = []

    init(core: AtlasCore, service: CreativeService) {
        self.core = core
        self.service = service
        _lastSummary = try? store.preference(Self.summaryKey, as: CreativeSummary.self)
        subscriptions = [
            // Leaving the Creative Studio ends the session.
            core.events.subscribe(AtlasEvent.Name.spaceDeactivated) { [weak self] event in
                guard let self, self.current != nil,
                      let id = event.payload["spaceId"]?.stringValue.flatMap(UUID.init(uuidString:)),
                      (try? self.store.space(id: id))??.templateID == CreativeLoft.templateID
                else { return }
                self.end(early: true)
            },
            core.events.subscribe(AtlasEvent.Name.fileCreatedEvent) { [weak self] event in
                if let path = event.payload["path"]?.stringValue { self?.fileChanged(path, created: true) }
            },
            core.events.subscribe(AtlasEvent.Name.fileModifiedEvent) { [weak self] event in
                if let path = event.payload["path"]?.stringValue { self?.fileChanged(path, created: false) }
            },
        ]
    }

    deinit {
        subscriptions.forEach(core.events.unsubscribe)
    }

    private var now: Date { service.now() }
    private var focus: FocusService? { core.time?.focus }

    public var current: CreativeSession? { lock.withLock { active?.session } }
    public var lastSummary: CreativeSummary? { lock.withLock { _lastSummary } }
    public var isRunning: Bool { lock.withLock { cycle }?.isRunning ?? false }
    public var isPaused: Bool { lock.withLock { cycle }?.currentSession?.state == .paused }
    public var goalSeconds: TimeInterval? { lock.withLock { active?.goalSeconds } }
    /// Sessions finished since launch (refills the mug).
    public var finishedCount: Int { lock.withLock { _finished } }

    public func focusedSeconds() -> TimeInterval {
        lock.withLock { cycle }?.focusedSeconds(at: now) ?? 0
    }

    // MARK: - Control

    /// Starts a session on the current project (ending any running one).
    @discardableResult
    public func start(minutes: Double? = nil, projectID: UUID? = nil, kind: CreativeSession.Kind = .create) throws -> CreativeSession {
        guard let focus else { throw CreativeSessionError.timerUnavailable }
        if core.time?.lockdown.isActive == true { throw CreativeSessionError.lockedDown }
        if current != nil { end(early: true) }
        let goal = max(1, minutes ?? Double(service.settings.sessionMinutes)) * 60
        let session = CreativeSession(projectID: projectID ?? service.currentProject()?.id, kind: kind, startedAt: now)
        let active = Active(session: session, goalSeconds: goal, phase: PomodoroPhase())
        lock.withLock { self.active = active }
        save()
        makeCycle(focus: focus, active: active).start(.focus)
        publishChange()
        return session
    }

    public func pause() {
        lock.withLock { cycle }?.pause()
        publishChange()
    }

    public func resume() {
        lock.withLock { cycle }?.resume()
        publishChange()
    }

    @discardableResult
    public func end(early: Bool = true) -> CreativeSummary? {
        finish(early: early)
    }

    /// Sends a gentle break reminder when another `breakEveryMinutes` of
    /// creating has passed (if they're on). Called a few times a minute.
    public func tick() {
        let settings = service.settings
        guard settings.breakReminders, isRunning, settings.breakEveryMinutes > 0 else { return }
        let due = Int(focusedSeconds() / Double(settings.breakEveryMinutes * 60))
        let send = lock.withLock { () -> Bool in
            guard let sent = active?.remindersSent, due > sent else { return false }
            active?.remindersSent = due
            return true
        }
        guard send else { return }
        save()
        let hours = CreativeMath.duration(Double(due * settings.breakEveryMinutes * 60))
        let system = core.system
        Task { try? await system.postNotification(title: "\(hours) of creating", body: "Maybe stretch, drink some water, rest your eyes. The timer keeps going.") }
    }

    // MARK: - Stats

    /// Creating time today (the day boundary applies), including the running session.
    public func createdToday() -> TimeInterval {
        let day = service.settings.day
        let start = day.start(of: now)
        let done = ((try? store.creativeSessions(in: DateInterval(start: start, end: day.next(after: start)))) ?? [])
            .filter { $0.kind == .create }.reduce(0) { $0 + $1.focusedSeconds }
        let running = current.map { $0.kind == .create && $0.startedAt >= start ? focusedSeconds() : 0 } ?? 0
        return done + running
    }

    /// Days in a row with at least `streakMinutes` of creating.
    public func streak() -> Int {
        let settings = service.settings
        let day = settings.day
        var totals: [Date: TimeInterval] = [:]
        let since = day.start(of: now).addingTimeInterval(-400 * 86_400)
        for session in (try? store.creativeSessions(in: DateInterval(start: since, end: now.addingTimeInterval(1)))) ?? [] where session.kind == .create {
            totals[day.start(of: session.startedAt), default: 0] += session.focusedSeconds
        }
        if let current, current.kind == .create, current.startedAt >= day.start(of: now) {
            totals[day.start(of: now), default: 0] += focusedSeconds()
        }
        return Streaks.count(totals: totals, now: now, day: day, minimum: Double(settings.streakMinutes) * 60)
    }

    /// Hours per project per week for the last `weeks` weeks (oldest first);
    /// watch time separately, under `watch`.
    public func weeklyHours(weeks: Int = 8) -> [(weekStart: Date, projectID: UUID?, kind: CreativeSession.Kind, hours: Double)] {
        let calendar = Calendar.current
        let thisWeek = calendar.dateInterval(of: .weekOfYear, for: now)?.start ?? now
        let first = calendar.date(byAdding: .weekOfYear, value: -(weeks - 1), to: thisWeek) ?? thisWeek
        struct Key: Hashable { let week: Date; let project: UUID?; let kind: CreativeSession.Kind }
        var hours: [Key: Double] = [:]
        for session in (try? store.creativeSessions(in: DateInterval(start: first, end: now.addingTimeInterval(1)))) ?? [] {
            let week = calendar.dateInterval(of: .weekOfYear, for: session.startedAt)?.start ?? first
            hours[Key(week: week, project: session.projectID, kind: session.kind), default: 0] += session.focusedSeconds / 3600
        }
        return hours.sorted { $0.key.week < $1.key.week }.map { ($0.key.week, $0.key.project, $0.key.kind, $0.value) }
    }

    /// A month's creative days: each day with at least `streakMinutes` of
    /// creating, coloured from that day's palette (a fresh rug each month).
    public func rug(for month: Date? = nil) -> [CreativeRoomState.Splash] {
        let settings = service.settings
        let calendar = Calendar.current
        guard let range = calendar.dateInterval(of: .month, for: month ?? now) else { return [] }
        let day = settings.day
        var totals: [Int: TimeInterval] = [:]
        var colors: [Int: String] = [:]
        let sessions = (try? store.creativeSessions(in: range)) ?? []
        for session in sessions where session.kind == .create {
            let dayStart = day.start(of: session.startedAt)
            let number = calendar.component(.day, from: dayStart)
            totals[number, default: 0] += session.focusedSeconds
            if colors[number] == nil || !session.palette.isEmpty {
                colors[number] = session.palette.first ?? colors[number]
            }
        }
        if let current, current.kind == .create, range.contains(current.startedAt) {
            totals[calendar.component(.day, from: day.start(of: now)), default: 0] += focusedSeconds()
        }
        let minimum = Double(settings.streakMinutes) * 60
        return totals.filter { $0.value >= minimum }.keys.sorted().map { number in
            CreativeRoomState.Splash(day: number, color: colors[number] ?? CreativeService.palette[number % CreativeService.palette.count])
        }
    }

    /// Past months' rugs, newest first (for the Stats panel).
    public func rugHistory(months: Int = 6) -> [(month: Date, splashes: [CreativeRoomState.Splash])] {
        let calendar = Calendar.current
        guard let thisMonth = calendar.dateInterval(of: .month, for: now)?.start else { return [] }
        return (1...months).compactMap { back in
            guard let month = calendar.date(byAdding: .month, value: -back, to: thisMonth) else { return nil }
            let splashes = rug(for: month)
            return splashes.isEmpty ? nil : (month, splashes)
        }
    }

    // MARK: - Internals

    @discardableResult
    private func makeCycle(focus: FocusService, active: Active) -> PomodoroCycle {
        var settings = PomodoroSettings()
        settings.focusMinutes = max(1, Int((active.goalSeconds / 60).rounded(.up)))
        let title = active.session.kind == .watch ? "Watch" : "Create"
        let cycle = PomodoroCycle(focus: focus, events: core.events, titlePrefix: title, settings: settings,
                                  phase: active.phase, spaceID: nil)
        cycle.limit = { [weak self, weak cycle] kind in
            guard kind == .focus, let self, let cycle, let goal = self.goalSeconds else { return nil }
            return goal - cycle.focusedSeconds(at: self.now)
        }
        cycle.onChange = { [weak self] phase in
            guard let self else { return }
            self.lock.withLock { self.active?.phase = phase }
            self.save()
        }
        cycle.onExhausted = { [weak self] in self?.finish(early: false) }
        cycle.onStopped = { [weak self] in self?.finish(early: true) }
        lock.withLock { self.cycle = cycle }
        return cycle
    }

    private func fileChanged(_ path: String, created: Bool) {
        guard let projectID = current?.projectID, let info = service.project(id: projectID)?.creative,
              let role = CreativeMath.role(of: path, in: info, created: created) else { return }
        lock.withLock {
            guard active != nil else { return }
            if !(active?.session.files.contains(path) ?? true) { active?.session.files.append(path) }
            switch role {
            case .export where !(active?.session.exports.contains(path) ?? true): active?.session.exports.append(path)
            case .reference where !(active?.session.references.contains(path) ?? true): active?.session.references.append(path)
            default: break
            }
        }
        save()
    }

    @discardableResult
    private func finish(early: Bool) -> CreativeSummary? {
        let taken = lock.withLock { () -> (Active, PomodoroCycle?)? in
            guard let active else { return nil }
            defer {
                self.active = nil
                cycle = nil
            }
            return (active, cycle)
        }
        guard let (active, cycle) = taken else { return nil }
        cycle?.stop()
        var session = active.session
        session.endedAt = now
        session.focusedSeconds = (cycle?.phase ?? active.phase).focusedSeconds
        // Today's palette: from the session's newest export, else the project's picture.
        let project = session.projectID.flatMap { service.project(id: $0) }
        let latestExport = session.exports.last { FileManager.default.fileExists(atPath: $0) }
        if let source = latestExport ?? project.flatMap(service.latestVisual) {
            session.palette = service.palette(of: source)
        }
        try? store.saveCreativeSession(session)
        try? store.setPreference(Active?.none, for: Self.activeKey)

        let summary = CreativeSummary(
            sessionID: session.id, kind: session.kind, focusedSeconds: session.focusedSeconds, projectName: project?.name,
            exports: session.exports.count, references: session.references.count, streak: streak(),
            latestExport: latestExport, palette: session.palette, endedEarly: early
        )
        lock.withLock {
            _lastSummary = summary
            _finished += 1
        }
        try? store.setPreference(summary, for: Self.summaryKey)
        core.events.publish(AtlasEvent(AtlasEvent.Name.creativeSessionEnded, payload: [
            "sessionId": .string(session.id.uuidString), "headline": .string(summary.headline), "early": .bool(early),
        ]))
        service.changed()
        return summary
    }

    private func save() {
        guard let active = lock.withLock({ active }) else { return }
        try? store.setPreference(active, for: Self.activeKey)
    }

    private func publishChange() {
        let session = current
        core.events.publish(AtlasEvent(AtlasEvent.Name.creativeSessionChanged, payload: [
            "sessionId": .string(session?.id.uuidString ?? ""), "kind": .string(session?.kind.rawValue ?? ""),
        ]))
        service.changed()
    }

    /// Picks up a session that was running when ATLAS closed, or wraps it up.
    func restore() {
        guard let saved = try? store.preference(Self.activeKey, as: Active.self) else { return }
        lock.withLock { active = saved }
        guard let focus, let id = saved.phase.sessionID, let running = focus.session, running.id == id else {
            finish(early: true)
            return
        }
        makeCycle(focus: focus, active: saved)
        publishChange()
    }
}
