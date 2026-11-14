import Foundation

/// A window chosen to stay usable while locked in.
public struct LockedWindow: Codable, Hashable, Sendable, Identifiable {
    /// The window adapter's ID (stable while the app runs).
    public var windowID: String
    public var bundleID: String
    public var appName: String
    public var title: String
    public var id: String { windowID }

    public init(windowID: String, bundleID: String, appName: String, title: String) {
        self.windowID = windowID
        self.bundleID = bundleID
        self.appName = appName
        self.title = title
    }

    public init(_ window: WindowInfo) {
        self.init(windowID: window.id.rawValue, bundleID: window.bundleID, appName: window.appName, title: window.title)
    }

    /// "Chrome — LeetCode", or just "Chrome" for an untitled window.
    public var label: String { title.isEmpty ? appName : "\(appName) — \(title)" }
}

/// A window lock in progress, saved so a crash doesn't drop it.
public struct WindowLockSession: Codable, Equatable, Sendable {
    public var id: UUID
    /// What it belongs to (a study session); it ends with it.
    public var ownerID: UUID
    public var startedAt: Date
    public var windows: [LockedWindow]
    /// Whether windows (not just apps) are being kept to: needs Accessibility.
    public var windowLevel: Bool
    public var unlockDuringBreaks: Bool
    public var onBreak = false
    /// Apps hidden and windows minimized by the lock, to bring back after.
    public var hiddenApps: [String] = []
    public var minimizedWindows: [String] = []
    /// App name → blocked attempts.
    public var blocked: [String: Int] = [:]

    public var allowedApps: [String] {
        var seen = Set<String>()
        return windows.map(\.bundleID).filter { seen.insert($0).inserted }
    }

    public var isEnforcing: Bool { !(onBreak && unlockDuringBreaks) }
    public var totalBlocked: Int { blocked.values.reduce(0, +) }

    /// "Chrome — LeetCode, Notes"
    public var summary: String { windows.map(\.label).joined(separator: ", ") }
}

extension AtlasEvent.Name {
    /// Payload: windows (labels, comma-separated), windowLevel.
    public static let windowLockStarted = "windowLock.started"
    /// Something was kept out. Payload: name, toast.
    public static let windowLockBlocked = "windowLock.blocked"
    /// Payload: blocked (count).
    public static let windowLockEnded = "windowLock.ended"
}

/// Keeps you to the windows you chose: every other app is hidden (never
/// quit, it may hold unsaved work), other windows of the chosen apps are
/// minimized, a blocked app that comes forward is hidden again, and a new
/// window in a chosen app is minimized as it appears.
///
/// If a chosen window closes, the app's next window takes its place, so
/// you're never locked out of the thing you meant to use. Quitting ATLAS
/// always ends it. Without Accessibility it falls back to whole apps.
public final class WindowLockService: @unchecked Sendable {
    static let sessionKey = "windowLock.session"
    static let toastInterval: TimeInterval = 20
    /// How often the front app's windows are checked.
    var pollInterval: Duration = .milliseconds(700)

    let store: AtlasStore
    let events: EventBus
    let environment: TriggerEnvironment
    let system: SystemAdapter
    let windows: WindowAdapter
    let ownBundleID: String?

    private let lock = NSLock()
    private var current: WindowLockSession?
    private var tokens: [TriggerToken] = []
    private var poller: Task<Void, Never>?
    private var lastToast: [String: Date] = [:]
    private var enforcing = false

    init(store: AtlasStore, events: EventBus, environment: TriggerEnvironment, system: SystemAdapter, windows: WindowAdapter,
         ownBundleID: String? = Bundle.main.bundleIdentifier) {
        self.store = store
        self.events = events
        self.environment = environment
        self.system = system
        self.windows = windows
        self.ownBundleID = ownBundleID
    }

    public var session: WindowLockSession? { lock.withLock { current } }
    public var isActive: Bool { session != nil }
    /// Whether windows can be locked (not just apps).
    public var canLockWindows: Bool { windows.isTrusted }

    /// Lists windows without Accessibility (the public window list), for
    /// when the adapter can't: the app sets it on macOS.
    public var listedWindows: @Sendable () -> [WindowInfo] = { [] }

    /// The windows you can pick: other apps' standard windows, frontmost
    /// first. Apps Accessibility couldn't read (or all of them, without
    /// the permission) come from the public window list.
    public func candidates() async -> [WindowInfo] {
        var all = (try? await windows.windows(bundleIDs: nil)) ?? []
        let read = Set(all.map(\.bundleID))
        all += listedWindows().filter { !read.contains($0.bundleID) }
        return all.filter { window in
            window.bundleID != ownBundleID
                && (!LockdownEssentials.contains(window.bundleID) || LockdownEssentials.hiddenAtStart.contains(window.bundleID))
        }
    }

    // MARK: - Starting and ending

    /// Locks you to `chosen` until `end()`: hides other apps, minimizes the
    /// chosen apps' other windows and brings the first chosen window forward.
    @discardableResult
    public func start(_ chosen: [LockedWindow], ownerID: UUID, unlockDuringBreaks: Bool = false) async -> WindowLockSession? {
        guard !chosen.isEmpty else { return nil }
        if session != nil { await end() }
        let session = WindowLockSession(id: UUID(), ownerID: ownerID, startedAt: environment.now(), windows: chosen,
                                        windowLevel: windows.isTrusted, unlockDuringBreaks: unlockDuringBreaks)
        lock.withLock {
            current = session
            lastToast = [:]
        }
        save()
        await hideOthers(atStart: true)
        await enforceWindows()
        await focusChosen()
        observe()
        events.publish(AtlasEvent(AtlasEvent.Name.windowLockStarted, payload: [
            "windows": .string(session.summary), "windowLevel": .bool(session.windowLevel),
        ]))
        if !session.windowLevel {
            notice("ATLAS doesn't have Accessibility permission, so it's locking whole apps instead of windows.")
        }
        return self.session
    }

    /// Unlocks and brings back what the lock tidied away.
    @discardableResult
    public func end() async -> WindowLockSession? {
        guard let ended = takeSession() else { return nil }
        for bundleID in ended.hiddenApps { _ = try? await system.unhideApplication(bundleID: bundleID) }
        if ended.windowLevel, !ended.minimizedWindows.isEmpty {
            let open = (try? await windows.windows(bundleIDs: Set(ended.allowedApps))) ?? []
            let minimized = Set(ended.minimizedWindows)
            for window in open where minimized.contains(window.id.rawValue) && window.isMinimized {
                try? await windows.setMinimized(false, window: window.id)
            }
        }
        await focusChosen(ended)
        return ended
    }

    /// Quitting ATLAS: unlock at once (nothing is brought back).
    public func endBecauseATLASIsQuitting() {
        _ = takeSession()
    }

    private func takeSession() -> WindowLockSession? {
        let taken = lock.withLock { () -> (WindowLockSession, [TriggerToken], Task<Void, Never>?)? in
            guard let session = current else { return nil }
            defer { current = nil; tokens = []; poller = nil }
            return (session, tokens, poller)
        }
        guard let (session, tokens, poller) = taken else { return nil }
        tokens.forEach { $0.cancel() }
        poller?.cancel()
        try? store.setPreference(WindowLockSession?.none, for: Self.sessionKey)
        events.publish(AtlasEvent(AtlasEvent.Name.windowLockEnded, payload: ["blocked": .number(Double(session.totalBlocked))]))
        return session
    }

    /// A break began (true) or focus came back (false).
    public func setOnBreak(_ onBreak: Bool) {
        guard let session, session.onBreak != onBreak else { return }
        mutate { $0.onBreak = onBreak }
        guard session.unlockDuringBreaks else { return }
        if onBreak {
            notice("Break: other apps are unlocked until it ends.")
        } else {
            Task {
                await hideOthers()
                await enforceWindows()
                await focusChosen()
            }
        }
    }

    // MARK: - Relaunch

    /// Picks up a lock saved before a crash, if what it belongs to is
    /// still running; otherwise drops it.
    public func resume(ownerID: UUID?) async {
        guard current == nil, let saved = try? store.preference(Self.sessionKey, as: WindowLockSession.self) else { return }
        guard saved.ownerID == ownerID else {
            try? store.setPreference(WindowLockSession?.none, for: Self.sessionKey)
            return
        }
        lock.withLock { current = saved }
        // Window IDs don't survive a relaunch of the app that owns them; enforcing re-finds them by title.
        await hideOthers()
        await enforceWindows()
        observe()
    }

    // MARK: - Enforcement

    private func observe() {
        let tokens = [
            environment.observeApplications { [weak self] launched, bundleID, name in
                guard launched, let self else { return }
                Task { await self.handleLaunch(bundleID, name: name) }
            },
            environment.observeActivations { [weak self] bundleID, name in
                guard let self else { return }
                Task { await self.handleActivation(bundleID, name: name) }
            },
            environment.observeWake { [weak self] in
                guard let self else { return }
                Task { await self.hideOthers() }
            },
        ]
        let interval = pollInterval
        let poller = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard let self, !Task.isCancelled else { return }
                await self.tick()
            }
        }
        lock.withLock {
            self.tokens = tokens
            self.poller = poller
        }
    }

    private func allowed(_ bundleID: String, in session: WindowLockSession) -> Bool {
        bundleID == ownBundleID || LockdownEssentials.contains(bundleID) || session.allowedApps.contains(bundleID)
    }

    /// A blocked app opened: it has no unsaved work yet, so ask it to quit; hide it if it won't.
    func handleLaunch(_ bundleID: String, name: String) async {
        guard let session, session.isEnforcing, !allowed(bundleID, in: session) else { return }
        blocked(name)
        let quit = (try? await system.quitApplication(bundleID: bundleID)) ?? false
        if !quit { _ = try? await system.hideApplication(bundleID: bundleID) }
        await focusChosen()
    }

    /// Something came forward: a blocked app is hidden again; a chosen
    /// app's other windows are minimized.
    func handleActivation(_ bundleID: String, name: String) async {
        guard let session, session.isEnforcing else { return }
        if allowed(bundleID, in: session) {
            if session.allowedApps.contains(bundleID) { await enforceWindows(bundleIDs: [bundleID]) }
            return
        }
        blocked(name)
        _ = try? await system.hideApplication(bundleID: bundleID)
        await focusChosen()
    }

    /// One check of the front app: what activation events can miss (a
    /// new window, Cmd-` between windows, an app that ignored hiding).
    func tick() async {
        guard let session, session.isEnforcing else { return }
        guard let front = system.runningApplications().first(where: \.isActive) else { return }
        if allowed(front.bundleID, in: session) {
            if session.allowedApps.contains(front.bundleID) { await enforceWindows(bundleIDs: [front.bundleID]) }
        } else {
            await handleActivation(front.bundleID, name: front.name)
        }
    }

    /// Minimizes every window of the chosen apps that wasn't chosen. A
    /// chosen window that's gone is replaced by the app's window with the
    /// same title, else its frontmost one.
    func enforceWindows(bundleIDs: Set<String>? = nil) async {
        guard let session, session.windowLevel, session.isEnforcing else { return }
        // One pass at a time; the poller and activations can overlap.
        guard lock.withLock({ () -> Bool in
            defer { enforcing = true }
            return !enforcing
        }) else { return }
        defer { lock.withLock { enforcing = false } }

        let apps = bundleIDs ?? Set(session.allowedApps)
        guard let open = try? await windows.windows(bundleIDs: apps) else { return }
        var chosen = session.windows
        var replaced: [String] = []
        for bundleID in apps {
            let appWindows = open.filter { $0.bundleID == bundleID }
            let ids = Set(appWindows.map(\.id.rawValue))
            for index in chosen.indices where chosen[index].bundleID == bundleID && !ids.contains(chosen[index].windowID) {
                let taken = Set(chosen.map(\.windowID))
                let free = appWindows.filter { !taken.contains($0.id.rawValue) }
                guard let next = free.first(where: { $0.title == chosen[index].title && !$0.isMinimized })
                    ?? free.first(where: { !$0.isMinimized }) ?? free.first else { continue }
                if next.title != chosen[index].title { replaced.append(next.appName) }
                chosen[index] = LockedWindow(next)
            }
        }
        let keep = Set(chosen.map(\.windowID))
        var minimized: [String] = []
        var stray: [String] = []
        for window in open where !keep.contains(window.id.rawValue) && !window.isMinimized && !window.isFullScreen {
            guard (try? await windows.setMinimized(true, window: window.id)) != nil else { continue }
            minimized.append(window.id.rawValue)
            stray.append(window.appName)
        }
        if chosen != session.windows || !minimized.isEmpty {
            mutate { session in
                session.windows = chosen
                session.minimizedWindows += minimized.filter { !session.minimizedWindows.contains($0) }
            }
        }
        // At the start it's tidying; after that it's a window you opened.
        if environment.now().timeIntervalSince(session.startedAt) > 2 {
            for name in Set(stray) { blocked("Another \(name) window") }
        }
        for name in Set(replaced) { notice("Your \(name) window closed, so the lock moved to its new one.") }
    }

    /// Hides every running app that isn't chosen (or ATLAS, or essential),
    /// and Finder's windows at the start.
    private func hideOthers(atStart: Bool = false) async {
        guard let session, session.isEnforcing else { return }
        var hidden: [String] = []
        for app in system.runningApplications() where !allowed(app.bundleID, in: session)
            || (atStart && LockdownEssentials.hiddenAtStart.contains(app.bundleID) && !session.allowedApps.contains(app.bundleID)) {
            if (try? await system.hideApplication(bundleID: app.bundleID)) == true { hidden.append(app.bundleID) }
        }
        guard !hidden.isEmpty else { return }
        mutate { session in session.hiddenApps += hidden.filter { !session.hiddenApps.contains($0) } }
    }

    /// Brings the first chosen window (or its app) to the front.
    private func focusChosen(_ session: WindowLockSession? = nil) async {
        guard let session = session ?? self.session, let first = session.windows.first else { return }
        if session.windowLevel, (try? await windows.focus(WindowID(first.windowID))) != nil { return }
        _ = try? await system.activateApplication(bundleID: first.bundleID)
    }

    // MARK: - Bookkeeping

    private func blocked(_ name: String) {
        let now = environment.now()
        let toast = lock.withLock { () -> String? in
            guard current != nil else { return nil }
            current?.blocked[name, default: 0] += 1
            guard lastToast[name].map({ now.timeIntervalSince($0) >= Self.toastInterval }) ?? true else { return "" }
            lastToast[name] = now
            return "\(name) is locked until your study session ends."
        }
        guard let toast else { return }
        save()
        events.publish(AtlasEvent(AtlasEvent.Name.windowLockBlocked, payload: ["name": .string(name), "toast": .string(toast)]))
    }

    private func notice(_ message: String) {
        events.publish(AtlasEvent(AtlasEvent.Name.lockdownNotice, payload: ["message": .string(message)]))
    }

    private func mutate(_ body: (inout WindowLockSession) -> Void) {
        let updated = lock.withLock { () -> WindowLockSession? in
            guard var session = current else { return nil }
            body(&session)
            current = session
            return session
        }
        if updated != nil { save() }
    }

    private func save() {
        guard let session else { return }
        try? store.setPreference(session, for: Self.sessionKey)
    }
}
