import Foundation

/// Cancels a trigger listener when asked or when released.
public final class TriggerToken: @unchecked Sendable {
    private let lock = NSLock()
    private var onCancel: (() -> Void)?

    public init(_ onCancel: @escaping () -> Void) {
        self.onCancel = onCancel
    }

    public func cancel() {
        let action = lock.synchronized { () -> (() -> Void)? in
            defer { onCancel = nil }
            return onCancel
        }
        action?()
    }

    deinit { cancel() }
}

public struct FileChange: Sendable, Hashable {
    public enum Kind: String, Sendable {
        case created, modified, removed, renamed
        /// Too many changes to report one by one: look at everything under `path` again.
        case rescan
    }
    public let path: String
    public let kind: Kind
    public let isDirectory: Bool

    public init(path: String, kind: Kind, isDirectory: Bool = false) {
        self.path = path
        self.kind = kind
        self.isDirectory = isDirectory
    }
}

/// The macOS event sources triggers listen to, behind a protocol so tests
/// can fire events by hand.
public protocol TriggerEnvironment: Sendable {
    func observeApplications(_ handler: @escaping @Sendable (_ launched: Bool, _ bundleID: String, _ name: String) -> Void) -> TriggerToken
    /// Changes inside `path`, coalesced over about half a second.
    func watchFolder(_ path: String, _ handler: @escaping @Sendable ([FileChange]) -> Void) throws -> TriggerToken
    func registerHotKey(_ key: HotKey, _ handler: @escaping @Sendable () -> Void) throws -> TriggerToken
    func observePower(_ handler: @escaping @Sendable (PowerStatus) -> Void) -> TriggerToken
    func observeWake(_ handler: @escaping @Sendable () -> Void) -> TriggerToken
    /// A regular app came to the front (Cmd-Tab, Dock click, …).
    func observeActivations(_ handler: @escaping @Sendable (_ bundleID: String, _ name: String) -> Void) -> TriggerToken
    /// Fires once at `date` by the wall clock; late if the Mac was asleep.
    func schedule(at date: Date, _ handler: @escaping @Sendable () -> Void) -> TriggerToken
    func now() -> Date
}

extension AtlasEvent.Name {
    /// Payload: workflowId, nodeId, triggerType, plus the trigger's payload as `payload.<key>`.
    public static let triggerFired = "trigger.fired"
    /// Payload: workflowId, triggerType, reason.
    public static let triggerSuppressed = "trigger.suppressed"
    /// A trigger couldn't be set up. Payload: workflowId, nodeId, reason.
    public static let triggerFailed = "trigger.failed"
}

/// Starts workflows when their triggers fire, safely.
///
/// - Registers and unregisters listeners as workflows are enabled,
///   disabled, edited or deleted, and stops them all while paused.
/// - Debounces repeats of the same event, and rate-limits each workflow.
/// - Applies the workflow's re-entrancy mode while a run is in progress.
/// - Notices a workflow setting itself off (e.g. moving a file into the
///   folder it watches) and stops it after a few times in a row.
///
/// Every firing that doesn't become a run is recorded in Run History as
/// skipped, with the reason, so nothing ever happens or fails silently.
public final class TriggerManager: @unchecked Sendable {
    private let store: AtlasStore
    private let engine: AutomationEngine
    private let events: EventBus
    private let environment: TriggerEnvironment
    private let system: SystemAdapter
    private let registry: ActionRegistry
    private let fileAccess: FileAccessPolicy

    private struct Listener {
        let workflowID: UUID
        let nodeID: UUID
        let type: String
        let parameters: ActionParameters
        var tokens: [TriggerToken]
        let signature: String
    }

    private let lock = NSLock()
    private var listeners: [UUID: Listener] = [:]        // by node ID
    private var problems: [UUID: String] = [:]           // by node ID
    private var isPaused = false
    private var isStarted = false
    private var subscriptions: [EventBus.Subscription] = []
    private var lastFireBySubject: [String: Date] = [:]
    private var recentFires: [UUID: [Date]] = [:]
    private var queued: [UUID: (node: UUID, type: String, payload: ActionParameters)] = [:]
    private var runWorkflows: [UUID: UUID] = [:]         // runID → workflowID
    private var effects: [UUID: [(value: String, at: Date)]] = [:]
    private var selfChains: [UUID: Int] = [:]
    private var stoppedForLooping: Set<UUID> = []
    private var lastSuppressionRecord: [String: Date] = [:]
    private var lastPower: [UUID: PowerStatus] = [:]   // by node ID

    /// How long an action's effect counts as the cause of a matching event.
    public var effectWindow: TimeInterval = 10
    /// How long the file trigger waits for a file to stop growing.
    public var fileSettleTimeout: TimeInterval = 10
    var fileSettleInterval: TimeInterval = 0.5

    public init(store: AtlasStore, engine: AutomationEngine, events: EventBus, environment: TriggerEnvironment,
                system: SystemAdapter, registry: ActionRegistry, fileAccess: FileAccessPolicy) {
        self.fileAccess = fileAccess
        self.store = store
        self.engine = engine
        self.events = events
        self.environment = environment
        self.system = system
        self.registry = registry
    }

    // MARK: - Lifecycle

    /// Subscribes to the engine's events and registers every enabled workflow's triggers.
    public func start() {
        let alreadyStarted = lock.synchronized { () -> Bool in
            defer { isStarted = true }
            return isStarted
        }
        guard !alreadyStarted else { return }
        let subscription = events.subscribe("*") { [weak self] event in self?.handle(event) }
        lock.synchronized { subscriptions.append(subscription) }
        Task {
            let paused = await engine.isPaused
            lock.synchronized { isPaused = paused }
            sync()
        }
    }

    public func stop() {
        let (subs, all) = lock.synchronized { () -> ([EventBus.Subscription], [Listener]) in
            defer { subscriptions = []; listeners = [:]; isStarted = false }
            return (subscriptions, Array(listeners.values))
        }
        subs.forEach(events.unsubscribe)
        all.flatMap(\.tokens).forEach { $0.cancel() }
    }

    /// Why a trigger node couldn't be set up, if it couldn't.
    public func problem(for nodeID: UUID) -> String? {
        lock.synchronized { problems[nodeID] }
    }

    public var activeTriggerCount: Int { lock.synchronized { listeners.count } }

    /// Orbit folders changed: folder triggers set up again, so one whose
    /// folder was just added starts watching and one whose folder was
    /// removed stops.
    public func fileAccessChanged() {
        let folderTypes: Set<String> = [TriggerCatalog.fileCreated, TriggerCatalog.folderChanged]
        let removed = lock.synchronized { () -> [Listener] in
            let matching = listeners.values.filter { folderTypes.contains($0.type) }
            for listener in matching { listeners[listener.nodeID] = nil }
            return Array(matching)
        }
        removed.flatMap(\.tokens).forEach { $0.cancel() }
        sync()
    }

    /// Brings listeners in line with the saved workflows.
    public func sync() {
        let workflows = (try? store.workflows()) ?? []
        let paused = lock.synchronized { isPaused }
        let stopped = lock.synchronized { stoppedForLooping }
        var wanted: [UUID: (Workflow, WorkflowStep)] = [:]
        if !paused {
            for workflow in workflows where workflow.isEnabled && !stopped.contains(workflow.id) {
                for node in workflow.triggerNodes where node.isEnabled {
                    wanted[node.id] = (workflow, node)
                }
            }
        }

        // Drop listeners that are gone or changed.
        let removed = lock.synchronized { () -> [Listener] in
            var removed: [Listener] = []
            for (id, listener) in listeners {
                if let (workflow, node) = wanted[id], listener.signature == Self.signature(workflow, node) { continue }
                removed.append(listener)
                listeners[id] = nil
                problems[id] = nil
            }
            return removed
        }
        removed.flatMap(\.tokens).forEach { $0.cancel() }

        // Add new ones, outside the lock: registering can call into AppKit.
        for (id, (workflow, node)) in wanted where lock.synchronized({ listeners[id] == nil }) {
            do {
                let tokens = try register(node, in: workflow)
                let listener = Listener(workflowID: workflow.id, nodeID: node.id, type: node.config.triggerType ?? "",
                                        parameters: node.parameters, tokens: tokens, signature: Self.signature(workflow, node))
                lock.synchronized {
                    listeners[id] = listener
                    problems[id] = nil
                }
            } catch {
                let reason = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                lock.synchronized { problems[id] = reason }
                events.publish(AtlasEvent(AtlasEvent.Name.triggerFailed, payload: [
                    "workflowId": .string(workflow.id.uuidString), "nodeId": .string(id.uuidString), "reason": .string(reason),
                ]))
            }
        }
    }

    /// Why a folder trigger isn't watching.
    public static func unauthorizedMessage(_ folder: String) -> String {
        "Not watching \(folder.abbreviatedPath): it isn't in Orbit, so ATLAS couldn't move or change files there. Add it in Orbit → Folders to turn this trigger on."
    }

    private static func signature(_ workflow: Workflow, _ node: WorkflowStep) -> String {
        let params = node.parameters.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value.displayString)" }.joined(separator: "&")
        return "\(workflow.id)|\(node.config.triggerType ?? "")|\(params)"
    }

    // MARK: - Registration

    private func register(_ node: WorkflowStep, in workflow: Workflow) throws -> [TriggerToken] {
        let workflowID = workflow.id, nodeID = node.id
        let type = node.config.triggerType ?? ""
        let params = node.parameters
        func fire(_ payload: ActionParameters, subject: String? = nil) {
            Task { await self.fire(workflowID: workflowID, nodeID: nodeID, type: type, payload: payload, subject: subject) }
        }

        switch type {
        case TriggerCatalog.appLaunched, TriggerCatalog.appQuit:
            let wantLaunch = type == TriggerCatalog.appLaunched
            let app = params["app"]?.stringValue?.trimmingCharacters(in: .whitespaces) ?? ""
            return [environment.observeApplications { launched, bundleID, name in
                guard launched == wantLaunch, app.isEmpty || app.caseInsensitiveCompare(bundleID) == .orderedSame else { return }
                fire(["bundleId": .string(bundleID), "appName": .string(name)], subject: bundleID)
            }]

        case TriggerCatalog.fileCreated, TriggerCatalog.folderChanged:
            let folder = (params["folder"]?.stringValue ?? "").trimmingCharacters(in: .whitespaces)
            let path = (folder as NSString).expandingTildeInPath
            guard !folder.isEmpty, system.fileKind(atPath: path) == .directory else {
                throw TriggerError("The folder “\(folder)” doesn't exist.")
            }
            guard fileAccess.isAllowed(path) else {
                throw TriggerError(Self.unauthorizedMessage(folder))
            }
            let extensions = Set((params["extensions"]?.stringValue ?? "").lowercased()
                .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ".", with: "") }
                .filter { !$0.isEmpty })
            let created = type == TriggerCatalog.fileCreated
            return [try environment.watchFolder(path) { [weak self] changes in
                guard let self else { return }
                if created {
                    for change in changes where self.isNewFile(change, extensions: extensions) {
                        Task {
                            guard await self.waitUntilSettled(change.path) else { return }
                            await self.fire(workflowID: workflowID, nodeID: nodeID, type: type,
                                            payload: Self.filePayload(change), subject: change.path)
                        }
                    }
                } else if let change = changes.first(where: { !Self.isHidden($0.path) }) {
                    var payload = Self.filePayload(change)
                    payload["change"] = .string(change.kind.rawValue)
                    fire(payload, subject: change.path)
                }
            }]

        case TriggerCatalog.hotKey:
            switch HotKey.parse(params["shortcut"]?.stringValue ?? "") {
            case .failure(let problem): throw TriggerError(problem.message)
            case .success(let key): return [try environment.registerHotKey(key) { fire([:]) }]
            }

        case TriggerCatalog.timeReached:
            let schedule = TimeSchedule(parameters: params)
            if let problem = schedule.validationError { throw TriggerError(problem) }
            return [scheduleNext(schedule, workflowID: workflowID, nodeID: nodeID)].compactMap { $0 }

        case TriggerCatalog.batteryLow, TriggerCatalog.powerConnected, TriggerCatalog.powerDisconnected:
            let threshold = Int(params["percent"]?.numberValue ?? 20)
            return [environment.observePower { [weak self] status in
                guard let self else { return }
                let previous = self.lock.synchronized { () -> PowerStatus? in
                    defer { self.lastPower[nodeID] = status }
                    return self.lastPower[nodeID]
                }
                // The first reading is only a baseline.
                guard let previous else { return }
                let payload: ActionParameters = ["batteryPercent": .number(Double(status.batteryPercent))]
                switch type {
                case TriggerCatalog.batteryLow:
                    if previous.batteryPercent >= threshold, status.batteryPercent < threshold { fire(payload) }
                case TriggerCatalog.powerConnected:
                    if !previous.isOnAdapter, status.isOnAdapter { fire(payload) }
                default:
                    if previous.isOnAdapter, !status.isOnAdapter { fire(payload) }
                }
            }]

        case TriggerCatalog.woke:
            return [environment.observeWake { fire([:]) }]

        case TriggerCatalog.spaceActivated, TriggerCatalog.spaceDeactivated, TriggerCatalog.displayChanged, TriggerCatalog.timerCompleted, TriggerCatalog.healthWarning,
             TriggerCatalog.blockStarting, TriggerCatalog.blockEnded, TriggerCatalog.focusEnded, TriggerCatalog.calendarEventApproaching:
            // Delivered through the event bus; see `handle(_:)`.
            return []

        default:
            throw TriggerError("This trigger type isn't known to this version of ATLAS.")
        }
    }

    private func scheduleNext(_ schedule: TimeSchedule, workflowID: UUID, nodeID: UUID) -> TriggerToken? {
        guard let next = schedule.nextFireDate(after: environment.now()) else { return nil }
        return environment.schedule(at: next) { [weak self] in
            guard let self else { return }
            let late = self.environment.now().timeIntervalSince(next)
            let payload: ActionParameters = ["scheduledFor": .string(next.formatted(date: .abbreviated, time: .shortened))]
            if late > 60 && !schedule.runIfMissed {
                Task { await self.suppress(workflowID: workflowID, type: TriggerCatalog.timeReached, payload: payload,
                                           reason: "Skipped: the Mac was asleep at \(next.formatted(date: .omitted, time: .shortened)).") }
            } else {
                Task { await self.fire(workflowID: workflowID, nodeID: nodeID, type: TriggerCatalog.timeReached, payload: payload) }
            }
            // Next occurrence, replacing this listener's token.
            if let token = self.scheduleNext(schedule, workflowID: workflowID, nodeID: nodeID) {
                self.lock.synchronized { self.listeners[nodeID]?.tokens = [token] }
            }
        }
    }

    private func isNewFile(_ change: FileChange, extensions: Set<String>) -> Bool {
        guard change.kind == .created || change.kind == .renamed, !change.isDirectory, !Self.isHidden(change.path) else { return false }
        let ext = (change.path as NSString).pathExtension.lowercased()
        if Self.partialExtensions.contains(ext) { return false }
        if !extensions.isEmpty && !extensions.contains(ext) { return false }
        return system.fileKind(atPath: change.path) == .file
    }

    /// Waits for a download or copy to finish: the size stops changing.
    private func waitUntilSettled(_ path: String) async -> Bool {
        let deadline = Date().addingTimeInterval(fileSettleTimeout)
        var last = system.fileSize(atPath: path)
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: UInt64(fileSettleInterval * 1_000_000_000))
            let size = system.fileSize(atPath: path)
            guard let size else { return false }  // Gone again (a temp file).
            if size == last { return true }
            last = size
        }
        return system.fileKind(atPath: path) == .file
    }

    static let partialExtensions: Set<String> = ["crdownload", "download", "part", "partial", "tmp", "opdownload"]

    static func isHidden(_ path: String) -> Bool {
        (path as NSString).lastPathComponent.hasPrefix(".")
    }

    static func filePayload(_ change: FileChange) -> ActionParameters {
        [
            "path": .string(change.path),
            "fileName": .string((change.path as NSString).lastPathComponent),
            "extension": .string((change.path as NSString).pathExtension.lowercased()),
            "folder": .string((change.path as NSString).deletingLastPathComponent),
        ]
    }

    // MARK: - Events

    private func handle(_ event: AtlasEvent) {
        let p = event.payload
        switch event.name {
        case AtlasEvent.Name.workflowSaved, AtlasEvent.Name.workflowDeleted:
            if let id = p["workflowId"]?.stringValue.flatMap(UUID.init(uuidString:)) {
                // Editing a workflow clears a loop stop and starts counting afresh.
                lock.synchronized {
                    stoppedForLooping.remove(id)
                    selfChains[id] = 0
                }
            }
            Task { self.sync() }
        case AtlasEvent.Name.automationPaused:
            lock.synchronized { isPaused = true }
            Task { self.sync() }
        case AtlasEvent.Name.automationResumed:
            lock.synchronized { isPaused = false }
            Task { self.sync() }
        case AtlasEvent.Name.workflowStarted:
            if let run = p["runId"]?.stringValue.flatMap(UUID.init(uuidString:)),
               let workflow = p["workflowId"]?.stringValue.flatMap(UUID.init(uuidString:)) {
                lock.synchronized { runWorkflows[run] = workflow }
            }
        case AtlasEvent.Name.workflowFinished:
            guard p["recordOnly"] == nil, let workflow = p["workflowId"]?.stringValue.flatMap(UUID.init(uuidString:)) else { return }
            let next = lock.synchronized { () -> (node: UUID, type: String, payload: ActionParameters)? in
                defer { queued[workflow] = nil }
                return queued[workflow]
            }
            if let next {
                Task { await self.startRun(workflowID: workflow, nodeID: next.node, type: next.type, payload: next.payload) }
            }
        case AtlasEvent.Name.actionEffect:
            guard let run = p["runId"]?.stringValue.flatMap(UUID.init(uuidString:)), let value = p["value"]?.stringValue else { return }
            let now = environment.now()
            lock.synchronized {
                guard let workflow = runWorkflows[run] else { return }
                effects[workflow, default: []].append((value, now))
                effects[workflow]?.removeAll { now.timeIntervalSince($0.at) > effectWindow }
            }
        case AtlasEvent.Name.spaceActivatedEvent:
            deliver(TriggerCatalog.spaceActivated) { params in
                let wanted = params["space"]?.stringValue?.trimmingCharacters(in: .whitespaces) ?? ""
                let name = p["spaceName"]?.stringValue ?? "", id = p["spaceId"]?.stringValue ?? ""
                guard wanted.isEmpty || wanted.caseInsensitiveCompare(name) == .orderedSame || wanted == id else { return nil }
                return ["spaceId": .string(id), "spaceName": .string(name), "profileId": p["profileId"] ?? .string("")]
            }
        case AtlasEvent.Name.spaceDeactivatedEvent:
            deliver(TriggerCatalog.spaceDeactivated) { params in
                let wanted = params["space"]?.stringValue?.trimmingCharacters(in: .whitespaces) ?? ""
                let name = p["spaceName"]?.stringValue ?? "", id = p["spaceId"]?.stringValue ?? ""
                guard wanted.isEmpty || wanted.caseInsensitiveCompare(name) == .orderedSame || wanted == id else { return nil }
                return ["spaceId": .string(id), "spaceName": .string(name), "nextSpaceId": p["nextSpaceId"] ?? .string("")]
            }
        case AtlasEvent.Name.healthThreshold:
            deliver(TriggerCatalog.healthWarning) { params in
                let wanted = params["metric"]?.stringValue ?? "any"
                let metric = p["metric"]?.stringValue ?? ""
                guard wanted == "any" || wanted.isEmpty || wanted == metric else { return nil }
                return ["metric": .string(metric), "value": p["value"] ?? .number(0), "threshold": p["threshold"] ?? .number(0),
                        "message": p["message"] ?? .string("")]
            }
        case AtlasEvent.Name.displayChanged:
            deliver(TriggerCatalog.displayChanged) { _ in
                ["displayCount": p["displayCount"] ?? .number(0), "profileId": p["profileId"] ?? .string("")]
            }
        case AtlasEvent.Name.blockStarting, AtlasEvent.Name.blockEnded:
            let type = event.name == AtlasEvent.Name.blockStarting ? TriggerCatalog.blockStarting : TriggerCatalog.blockEnded
            let occurrence = "\(p["blockId"]?.stringValue ?? "")|\(p["start"]?.displayString ?? "")|\(p["minutesBefore"]?.displayString ?? "end")"
            deliver(type, subject: occurrence) { params in
                let wanted = params["block"]?.stringValue?.trimmingCharacters(in: .whitespaces) ?? ""
                let title = p["title"]?.stringValue ?? "", id = p["blockId"]?.stringValue ?? ""
                guard wanted.isEmpty || wanted == id || wanted.caseInsensitiveCompare(title) == .orderedSame else { return nil }
                if type == TriggerCatalog.blockStarting {
                    let minutes = params["minutesBefore"]?.numberValue ?? 0
                    guard minutes == (p["minutesBefore"]?.numberValue ?? 0) else { return nil }
                    let kind = params["kind"]?.stringValue ?? "any"
                    guard kind == "any" || kind.isEmpty || kind == p["kind"]?.stringValue else { return nil }
                }
                return ["blockId": .string(id), "title": .string(title), "spaceName": p["spaceName"] ?? .string(""),
                        "start": p["start"] ?? .number(0), "end": p["end"] ?? .number(0)]
            }
        case AtlasEvent.Name.focusEnded:
            deliver(TriggerCatalog.focusEnded) { params in
                let completed = p["completed"]?.boolValue ?? false
                if params["completedOnly"]?.boolValue == true, !completed { return nil }
                return ["title": p["title"] ?? .string(""), "elapsedMinutes": p["elapsedMinutes"] ?? .number(0), "completed": .bool(completed)]
            }
        case AtlasEvent.Name.calendarEventApproaching:
            deliver(TriggerCatalog.calendarEventApproaching,
                    subject: "\(p["eventId"]?.stringValue ?? "")|\(p["start"]?.displayString ?? "")|\(p["minutesBefore"]?.displayString ?? "")") { params in
                guard (params["minutesBefore"]?.numberValue ?? 10) == (p["minutesBefore"]?.numberValue ?? -1) else { return nil }
                let calendar = params["calendar"]?.stringValue?.trimmingCharacters(in: .whitespaces) ?? ""
                guard calendar.isEmpty || calendar.caseInsensitiveCompare(p["calendar"]?.stringValue ?? "") == .orderedSame else { return nil }
                let contains = params["titleContains"]?.stringValue?.trimmingCharacters(in: .whitespaces) ?? ""
                let title = p["title"]?.stringValue ?? ""
                guard contains.isEmpty || title.localizedCaseInsensitiveContains(contains) else { return nil }
                return ["title": .string(title), "calendar": p["calendar"] ?? .string(""), "eventId": p["eventId"] ?? .string("")]
            }
        case AtlasEvent.Name.timerCompleted:
            deliver(TriggerCatalog.timerCompleted) { params in
                let wanted = params["name"]?.stringValue?.trimmingCharacters(in: .whitespaces) ?? ""
                let name = p["name"]?.stringValue ?? ""
                guard wanted.isEmpty || wanted.caseInsensitiveCompare(name) == .orderedSame else { return nil }
                return ["name": .string(name)]
            }
        default:
            break
        }
    }

    /// Fires every listener of an event-bus trigger type whose filter matches.
    /// `subject` keeps distinct happenings (another occurrence, another lead
    /// time) from being taken for a repeat of the same event.
    private func deliver(_ type: String, subject: String? = nil, payload: (ActionParameters) -> ActionParameters?) {
        let matching = lock.synchronized { listeners.values.filter { $0.type == type } }
        for listener in matching {
            guard let values = payload(listener.parameters) else { continue }
            Task { await self.fire(workflowID: listener.workflowID, nodeID: listener.nodeID, type: type, payload: values, subject: subject) }
        }
    }

    // MARK: - Firing

    /// Applies every guard, then starts the run or records why not.
    func fire(workflowID: UUID, nodeID: UUID, type: String, payload: ActionParameters, subject: String? = nil) async {
        guard let workflow = try? store.workflow(id: workflowID), workflow.isEnabled else { return }
        let settings = workflow.settings
        let now = environment.now()

        let paused = lock.synchronized { isPaused || stoppedForLooping.contains(workflowID) }
        if paused { return }

        events.publish(AtlasEvent(AtlasEvent.Name.triggerFired, payload: firedPayload(workflowID, nodeID, type, payload)))

        // Repeats of the same event.
        let subjectKey = "\(workflowID)|\(subject ?? "")"
        let tooSoon = lock.synchronized { () -> Bool in
            if let last = lastFireBySubject[subjectKey], now.timeIntervalSince(last) < settings.minimumInterval { return true }
            lastFireBySubject[subjectKey] = now
            return false
        }
        if tooSoon {
            await suppress(workflowID: workflowID, type: type, payload: payload,
                           reason: "Skipped: the same trigger fired again within \(ActionValue.number(settings.minimumInterval).displayString) seconds.")
            return
        }

        // Rate limit.
        let overLimit = lock.synchronized { () -> Bool in
            var fires = (recentFires[workflowID] ?? []).filter { now.timeIntervalSince($0) < 60 }
            guard fires.count < settings.maxRunsPerMinute else { return true }
            fires.append(now)
            recentFires[workflowID] = fires
            return false
        }
        if overLimit {
            await suppress(workflowID: workflowID, type: type, payload: payload,
                           reason: "Skipped: this workflow already ran \(settings.maxRunsPerMinute) times in the last minute.")
            return
        }

        // Did this workflow cause the event itself?
        let values = [payload["path"], payload["bundleId"]].compactMap { $0?.stringValue }
        let loop = lock.synchronized { () -> (selfCaused: Bool, count: Int) in
            let recent = (effects[workflowID] ?? []).filter { now.timeIntervalSince($0.at) <= effectWindow }
            let caused = values.contains { value in recent.contains { $0.value == value } }
            selfChains[workflowID] = caused ? (selfChains[workflowID] ?? 0) + 1 : 0
            return (caused, selfChains[workflowID] ?? 0)
        }
        if loop.selfCaused && loop.count > settings.selfTriggerLimit {
            lock.synchronized { stoppedForLooping.insert(workflowID) }
            sync()
            await suppress(workflowID: workflowID, type: type, payload: payload, state: .failed, force: true,
                           reason: "Stopped: “\(workflow.name)” kept setting off its own trigger (\(loop.count) times in a row), so ATLAS turned its triggers off. Change the workflow so its actions don't trigger it again, then save it to turn them back on.")
            return
        }

        // Re-entrancy.
        if await engine.isRunning(workflowID: workflowID) {
            switch settings.reentrancy {
            case .ignoreWhileRunning:
                await suppress(workflowID: workflowID, type: type, payload: payload, reason: "Skipped: the previous run hadn't finished.")
                return
            case .queueOne:
                let accepted = lock.synchronized { () -> Bool in
                    guard queued[workflowID] == nil else { return false }
                    queued[workflowID] = (nodeID, type, payload)
                    return true
                }
                if !accepted {
                    await suppress(workflowID: workflowID, type: type, payload: payload,
                                   reason: "Skipped: one run was already waiting for the current one to finish.")
                }
                return
            case .runInParallel:
                break
            }
        }
        await startRun(workflowID: workflowID, nodeID: nodeID, type: type, payload: payload)
    }

    private func startRun(workflowID: UUID, nodeID: UUID, type: String, payload: ActionParameters) async {
        guard let workflow = try? store.workflow(id: workflowID) else { return }
        await engine.start(workflow, trigger: RunTrigger.automatic(type), payload: payload, entryNodeID: nodeID)
    }

    /// Records a firing that didn't become a run. Repeats of the same reason
    /// within 30 seconds only publish the event, so a burst can't flood history.
    private func suppress(workflowID: UUID, type: String, payload: ActionParameters, state: RunState = .skipped,
                          force: Bool = false, reason: String) async {
        events.publish(AtlasEvent(AtlasEvent.Name.triggerSuppressed, payload: [
            "workflowId": .string(workflowID.uuidString), "triggerType": .string(type), "reason": .string(reason),
        ]))
        let key = "\(workflowID)|\(reason.prefix(40))"
        let now = environment.now()
        let record = lock.synchronized { () -> Bool in
            if !force, let last = lastSuppressionRecord[key], now.timeIntervalSince(last) < 30 { return false }
            lastSuppressionRecord[key] = now
            return true
        }
        guard record, let workflow = try? store.workflow(id: workflowID) else { return }
        let run = WorkflowRun(
            workflowID: workflow.id,
            workflowName: workflow.name,
            trigger: RunTrigger.automatic(type),
            state: state,
            startedAt: now,
            finishedAt: now,
            error: reason,
            steps: workflow.steps.enumerated().map { position, step in
                StepRecord(position: position, nodeID: step.id, actionID: step.actionID,
                           label: WorkflowValidator.displayName(step, registry: registry).trimmingCharacters(in: CharacterSet(charactersIn: "“”")),
                           state: .skipped, message: reason, kind: step.kind)
            },
            triggerPayload: payload
        )
        do {
            try store.saveRun(run)
        } catch {
            AtlasLog.persistence.error("Couldn't record skipped trigger: \(error.localizedDescription, privacy: .public)")
        }
        events.publish(AtlasEvent(AtlasEvent.Name.workflowFinished, payload: [
            "runId": .string(run.id.uuidString), "workflowId": .string(workflow.id.uuidString), "state": .string(state.rawValue),
            "trigger": .string(run.trigger), "recordOnly": true,
        ]))
    }

    private func firedPayload(_ workflowID: UUID, _ nodeID: UUID, _ type: String, _ payload: ActionParameters) -> ActionParameters {
        var values: ActionParameters = [
            "workflowId": .string(workflowID.uuidString), "nodeId": .string(nodeID.uuidString), "triggerType": .string(type),
        ]
        for (key, value) in payload { values["payload.\(key)"] = value }
        return values
    }
}

struct TriggerError: Error, LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

extension AtlasEvent.Name {
    /// Spaces publishes `space.activated`; triggers listen for it here.
    public static let spaceActivatedEvent = "space.activated"
    /// Spaces publishes `space.deactivated` when you switch to another Space.
    public static let spaceDeactivatedEvent = "space.deactivated"
}
