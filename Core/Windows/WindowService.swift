import CoreGraphics
import Foundation
#if os(macOS)
import AppKit
#endif

extension AtlasEvent.Name {
    /// Payload: layoutId, layoutName, placed, skipped, launched.
    public static let windowLayoutApplied = "window.layoutApplied"
    /// A layout was created, changed or deleted. Payload: layoutId.
    public static let windowLayoutSaved = "window.layoutSaved"
    public static let windowLayoutDeleted = "window.layoutDeleted"
    /// Payload: snapshotId, spaceId (if any), automatic.
    public static let snapshotSaved = "snapshot.saved"
    /// Payload: snapshotId, placed, skipped, launched.
    public static let snapshotRestored = "snapshot.restored"
    /// Payload: displayCount, profileId, profileName.
    public static let displayChanged = "display.changed"
}

/// What arranging windows actually did. Never rounds up: a window that
/// couldn't be placed is listed with the reason.
public struct WindowArrangementResult: Sendable, Hashable {
    public struct Placed: Sendable, Hashable {
        public let bundleID: String
        public let appName: String
        public let title: String
        public let displayName: String
        public let frame: CGRect
        public let note: String?

        public var line: String {
            let subject = title.isEmpty ? appName : "\(appName) (“\(title)”)"
            let base = "Placed \(subject) on \(displayName)"
            return note.map { "\(base): \($0)" } ?? base
        }
    }

    public var placed: [Placed] = []
    public var skipped: [WindowSkip] = []
    /// Names of apps opened so their windows could be placed.
    public var launched: [String] = []

    public var total: Int { placed.count + skipped.count }

    /// "Placed 4 of 5 windows".
    public var summary: String {
        if total == 0 { return "No windows to arrange" }
        return "Placed \(placed.count) of \(total) window\(total == 1 ? "" : "s")"
    }

    /// One line per window, placed first, for run history.
    public var details: String {
        (launched.map { "Opened \($0)" } + placed.map(\.line) + skipped.map(\.message)).joined(separator: "\n")
    }

    /// The step result: success, partial success or failure, honestly.
    public func actionOutput(extra: ActionParameters = [:]) throws -> ActionOutput {
        var values = extra
        values["placed"] = .number(Double(placed.count))
        values["skipped"] = .number(Double(skipped.count))
        values["launched"] = .number(Double(launched.count))
        if !details.isEmpty { values["details"] = .string(details) }

        if placed.isEmpty, !skipped.isEmpty {
            throw ActionError.failed("\(summary). \(skipped.map(\.message).joined(separator: ". "))")
        }
        let partial = skipped.isEmpty ? nil : skipped.map(\.message).joined(separator: ". ")
        return ActionOutput(summary, values: values, partialFailure: partial)
    }
}

/// Arranges windows through a `WindowAdapter`: applies layouts, captures
/// the current arrangement, and saves and restores session snapshots.
/// Apps are opened only through the registered `application.launch`
/// action. Nothing here ever closes a window or quits an app.
public final class WindowService: @unchecked Sendable {
    public let adapter: WindowAdapter
    let store: AtlasStore
    private let system: SystemAdapter
    private let events: EventBus
    private let registry: ActionRegistry
    private let permissions: PermissionManager

    /// How long to wait for a just-opened app's first window.
    public var windowWaitTimeout: TimeInterval = 8
    /// Per Accessibility call, so an unresponsive app can't hang a run.
    public var operationTimeout: TimeInterval = 3
    /// How often to look for new windows while waiting.
    var pollInterval: TimeInterval = 0.25

    private let lock = NSLock()
    private var displayObserver: NSObjectProtocol?
    private var pendingDisplayChange: Task<Void, Never>?

    public init(
        adapter: WindowAdapter,
        store: AtlasStore,
        system: SystemAdapter,
        events: EventBus,
        registry: ActionRegistry,
        permissions: PermissionManager
    ) {
        self.adapter = adapter
        self.store = store
        self.system = system
        self.events = events
        self.registry = registry
        self.permissions = permissions
    }

    // MARK: - Displays

    public func displays() async -> [DisplayInfo] {
        await adapter.displays()
    }

    public func currentDisplayProfile() async -> DisplayProfile {
        DisplayProfile(displays: await adapter.displays())
    }

    /// Announces the current display set, e.g. after a monitor was plugged in.
    public func publishDisplayChange() async {
        let displays = await adapter.displays()
        let profile = DisplayProfile(displays: displays)
        events.publish(AtlasEvent(AtlasEvent.Name.displayChanged, payload: [
            "displayCount": .number(Double(displays.count)),
            "profileId": .string(profile.id),
            "profileName": .string(profile.name),
        ]))
    }

    #if os(macOS)
    /// Publishes `display.changed` whenever a display is connected,
    /// disconnected or rearranged. macOS sends a burst of notifications per
    /// change, so they're coalesced.
    public func startObservingDisplays() {
        lock.synchronized {
            guard displayObserver == nil else { return }
            displayObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: nil
            ) { [weak self] _ in
                self?.scheduleDisplayChange()
            }
        }
    }

    private func scheduleDisplayChange() {
        lock.synchronized {
            pendingDisplayChange?.cancel()
            pendingDisplayChange = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 400_000_000)
                guard !Task.isCancelled else { return }
                await self?.publishDisplayChange()
            }
        }
    }
    #endif

    // MARK: - Applying

    /// Places windows according to `layout`. Apps with rules that aren't
    /// running are opened first, then their first window is awaited.
    public func apply(_ layout: WindowLayout, launchMissing: Bool = true) async throws -> WindowArrangementResult {
        let result = try await arrange(rules: layout.rules, launchMissing: launchMissing)
        events.publish(AtlasEvent(AtlasEvent.Name.windowLayoutApplied, payload: [
            "layoutId": .string(layout.id.uuidString),
            "layoutName": .string(layout.name),
            "placed": .number(Double(result.placed.count)),
            "skipped": .number(Double(result.skipped.count)),
            "launched": .number(Double(result.launched.count)),
        ]))
        return result
    }

    /// One app's windows to a preset, e.g. Terminal on the right half.
    public func arrange(bundleID: String, preset: WindowPreset, display: DisplayTarget) async throws -> WindowArrangementResult {
        let name = system.applicationName(for: bundleID) ?? bundleID
        let rule = WindowRule(bundleID: bundleID, appName: name, preset: preset, display: display)
        return try await arrange(rules: [rule], launchMissing: true)
    }

    private func arrange(rules: [WindowRule], launchMissing: Bool) async throws -> WindowArrangementResult {
        guard adapter.isTrusted else { throw WindowAdapterError.accessibilityDenied }
        var result = WindowArrangementResult()
        guard !rules.isEmpty else { return result }

        let bundleIDs = Set(rules.map(\.bundleID))
        let names = Dictionary(rules.map { ($0.bundleID, $0.displayName) }, uniquingKeysWith: { first, _ in first })
        let displays = await adapter.displays()
        var plan = try await makePlan(rules: rules, displays: displays, bundleIDs: bundleIDs)

        // Open what isn't running, then wait for first windows.
        var launchedIDs = Set<String>()
        var failedLaunches = Set<String>()
        if launchMissing {
            for bundleID in plan.appsToLaunch {
                do {
                    let outcome = try await launch(bundleID)
                    launchedIDs.insert(bundleID)
                    result.launched.append(outcome)
                } catch {
                    failedLaunches.insert(bundleID)
                    result.skipped.append(WindowSkip(
                        bundleID: bundleID, appName: names[bundleID] ?? bundleID, title: nil,
                        reason: "ATLAS couldn't open it (\(error.localizedDescription))"
                    ))
                }
            }
        }
        let awaited = launchedIDs.union(plan.appsWithoutWindows)
        if !awaited.isEmpty {
            try await waitForWindows(of: awaited, among: bundleIDs)
            plan = try await makePlan(rules: rules, displays: displays, bundleIDs: bundleIDs)
        }

        for bundleID in plan.appsToLaunch where !failedLaunches.contains(bundleID) {
            let reason = launchedIDs.contains(bundleID) ? "it opened but didn't show a window in time" : "it isn't running"
            result.skipped.append(WindowSkip(bundleID: bundleID, appName: names[bundleID] ?? bundleID, title: nil, reason: reason))
        }
        for bundleID in plan.appsWithoutWindows {
            let reason = launchedIDs.contains(bundleID) ? "it opened but didn't show a window in time" : "it has no open windows"
            result.skipped.append(WindowSkip(bundleID: bundleID, appName: names[bundleID] ?? bundleID, title: nil, reason: reason))
        }
        result.skipped.append(contentsOf: plan.skipped)

        // Back to front, so raising afterwards leaves the frontmost on top.
        let ordered = plan.placements.sorted { $0.zOrder > $1.zOrder }
        var placedIDs: [WindowPlacement] = []
        for (index, placement) in ordered.enumerated() {
            guard adapter.isTrusted else {
                for rest in ordered[index...] {
                    result.skipped.append(skip(rest, "Accessibility permission was turned off while ATLAS was arranging windows"))
                }
                break
            }
            do {
                if placement.needsUnminimize {
                    try await timed(placement.appName) { try await self.adapter.setMinimized(false, window: placement.windowID) }
                }
                let actual = try await timed(placement.appName) {
                    try await self.adapter.setFrame(placement.frame, of: placement.windowID)
                }
                if abs(actual.minX - placement.frame.minX) > 12 || abs(actual.minY - placement.frame.minY) > 12 {
                    result.skipped.append(skip(placement, "the app didn't accept the new position"))
                    continue
                }
                var notes = [placement.note].compactMap { $0 }
                if abs(actual.width - placement.frame.width) > 12 || abs(actual.height - placement.frame.height) > 12,
                   placement.note == nil {
                    notes.append("\(placement.appName) kept a different size")
                }
                if placement.state == .minimized {
                    try await timed(placement.appName) { try await self.adapter.setMinimized(true, window: placement.windowID) }
                }
                placedIDs.append(placement)
                result.placed.append(WindowArrangementResult.Placed(
                    bundleID: placement.bundleID,
                    appName: placement.appName,
                    title: placement.title,
                    displayName: placement.displayName,
                    frame: actual,
                    note: notes.isEmpty ? nil : notes.joined(separator: "; ")
                ))
            } catch WindowAdapterError.accessibilityDenied {
                for rest in ordered[index...] {
                    result.skipped.append(skip(rest, "Accessibility permission was turned off while ATLAS was arranging windows"))
                }
                break
            } catch {
                result.skipped.append(skip(placement, Self.reason(for: error)))
            }
        }

        // Stack order. Raising is cosmetic, so failures here aren't reported.
        let visible = placedIDs.filter { $0.state == .normal }
        for placement in visible {
            try? await timed(placement.appName) { try await self.adapter.raise(placement.windowID) }
        }
        if let front = visible.last {
            try? await timed(front.appName) { try await self.adapter.focus(front.windowID) }
        }
        for bundleID in Set(placedIDs.filter { $0.state == .hidden }.map(\.bundleID)) {
            _ = try? await system.hideApplication(bundleID: bundleID)
        }
        return result
    }

    private func makePlan(rules: [WindowRule], displays: [DisplayInfo], bundleIDs: Set<String>) async throws -> PlacementPlan {
        let windows = try await timed("the window list") { try await self.adapter.windows(bundleIDs: bundleIDs) }
        let running = Set(system.runningApplications().map(\.bundleID))
        return LayoutResolver.plan(rules: rules, displays: displays, windows: windows, runningBundleIDs: running)
    }

    /// Polls until every app in `apps` has a window, or the timeout passes.
    private func waitForWindows(of apps: Set<String>, among bundleIDs: Set<String>) async throws {
        let deadline = Date().addingTimeInterval(windowWaitTimeout)
        while Date() < deadline {
            let windows = try await timed("the window list") { try await self.adapter.windows(bundleIDs: apps) }
            if apps.isSubset(of: Set(windows.map(\.bundleID))) { return }
            try await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
        }
    }

    /// Opens an app through the registered `application.launch` action, so
    /// it obeys the same switch in the Action Library as everywhere else.
    private func launch(_ bundleID: String) async throws -> String {
        guard let action = registry.action(for: LaunchApplicationAction.id) else {
            throw ActionError.unknownAction(LaunchApplicationAction.id)
        }
        try await permissions.authorize(action.descriptor)
        let parameters = try registry.validate(["bundleId": .string(bundleID), "activate": false], for: action.descriptor)
        let output = try await action.perform(parameters, context: ActionContext(system: system, events: events, runID: nil))
        return output.values["appName"]?.stringValue ?? bundleID
    }

    // MARK: - Capturing

    /// The current arrangement as rules. Layouts take visible windows only;
    /// snapshots also keep minimized windows and hidden apps.
    public func captureRules(includeHidden: Bool, apps: Set<String>? = nil) async throws -> (rules: [WindowRule], displays: [DisplayInfo]) {
        guard adapter.isTrusted else { throw WindowAdapterError.accessibilityDenied }
        let displays = await adapter.displays()
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let ownBundle = Bundle.main.bundleIdentifier
        let windows = try await timed("the window list") { try await self.adapter.windows(bundleIDs: apps) }
            .filter { $0.processID != ownPID && $0.bundleID != ownBundle && !$0.isFullScreen }
            .filter { includeHidden || (!$0.isMinimized && !$0.isAppHidden) }
            .sorted { $0.zIndex < $1.zIndex }

        let countByApp = Dictionary(grouping: windows, by: \.bundleID).mapValues(\.count)
        let main = displays.main
        let rules = windows.enumerated().map { index, window -> WindowRule in
            let display = displays.first { $0.id == window.displayID } ?? displays.display(containing: window.frame) ?? main
            let target: DisplayTarget = if let display, display.id != main?.id {
                .display(id: display.id, name: display.name)
            } else {
                .main
            }
            let fraction = display.map { FractionalRect(window.frame, in: $0.visibleFrame).clamped } ?? WindowPreset.centered.rect
            let state: WindowState = window.isAppHidden ? .hidden : (window.isMinimized ? .minimized : .normal)
            // Titles tell several windows of one app apart; a lone window
            // matches by app alone so a changed title doesn't break it.
            let match: TitleMatch? = (countByApp[window.bundleID] ?? 0) > 1 && !window.title.isEmpty ? .contains(window.title) : nil
            return WindowRule(bundleID: window.bundleID, appName: window.appName, titleMatch: match,
                              display: target, frame: fraction, state: state, zOrder: index)
        }
        return (rules, displays)
    }

    /// Saves the current windows as a layout. Capturing again under the same
    /// name updates that layout, so Spaces using it pick up the change.
    @discardableResult
    public func captureLayout(named name: String, apps: Set<String>? = nil) async throws -> WindowLayout {
        let (rules, displays) = try await captureRules(includeHidden: false, apps: apps)
        let cleaned = name.trimmingCharacters(in: .whitespacesAndNewlines)
        var layout = try store.windowLayout(reference: cleaned)
            ?? WindowLayout(name: cleaned.isEmpty ? "Untitled Layout" : cleaned)
        layout.rules = rules
        layout.displayProfile = DisplayProfile(displays: displays)
        return try save(layout)
    }

    @discardableResult
    public func save(_ layout: WindowLayout) throws -> WindowLayout {
        var saved = layout
        saved.updatedAt = Date()
        if saved.name.trimmingCharacters(in: .whitespaces).isEmpty { saved.name = "Untitled Layout" }
        try store.saveWindowLayout(saved)
        events.publish(AtlasEvent(AtlasEvent.Name.windowLayoutSaved, payload: ["layoutId": .string(saved.id.uuidString)]))
        return saved
    }

    public func deleteLayout(id: UUID) throws {
        try store.deleteWindowLayout(id: id)
        events.publish(AtlasEvent(AtlasEvent.Name.windowLayoutDeleted, payload: ["layoutId": .string(id.uuidString)]))
    }

    // MARK: - Snapshots

    /// Records every window and running app.
    @discardableResult
    public func saveSnapshot(name: String?, spaceID: UUID? = nil, automatic: Bool = false) async throws -> SessionSnapshot {
        let (rules, displays) = try await captureRules(includeHidden: true)
        let ownBundle = Bundle.main.bundleIdentifier
        let snapshot = SessionSnapshot(
            name: name?.trimmingCharacters(in: .whitespaces).nilIfEmpty
                ?? "Snapshot \(Date().formatted(date: .abbreviated, time: .shortened))",
            spaceID: spaceID,
            isAutomatic: automatic,
            runningApps: system.runningApplications().map(\.bundleID).filter { $0 != ownBundle }.sorted(),
            rules: rules,
            displayProfile: DisplayProfile(displays: displays)
        )
        try store.saveSnapshot(snapshot)
        if automatic, let spaceID {
            try store.pruneAutomaticSnapshots(spaceID: spaceID, keepingLatest: 5)
        }
        var payload: ActionParameters = [
            "snapshotId": .string(snapshot.id.uuidString),
            "automatic": .bool(automatic),
            "windows": .number(Double(rules.count)),
        ]
        if let spaceID { payload["spaceId"] = .string(spaceID.uuidString) }
        events.publish(AtlasEvent(AtlasEvent.Name.snapshotSaved, payload: payload))
        return snapshot
    }

    /// Reopens apps that were running and puts windows back. Window contents
    /// (tabs, documents, unsaved work) are up to each app.
    public func restore(_ snapshot: SessionSnapshot) async throws -> WindowArrangementResult {
        guard adapter.isTrusted else { throw WindowAdapterError.accessibilityDenied }
        let running = Set(system.runningApplications().map(\.bundleID))
        var launched: [String] = []
        var failed: [WindowSkip] = []
        let withRules = Set(snapshot.rules.map(\.bundleID))
        // Apps with windows are opened by `arrange`; this covers the rest.
        for bundleID in snapshot.runningApps where !running.contains(bundleID) && !withRules.contains(bundleID) {
            do {
                launched.append(try await launch(bundleID))
            } catch {
                failed.append(WindowSkip(bundleID: bundleID, appName: system.applicationName(for: bundleID) ?? bundleID,
                                         title: nil, reason: "ATLAS couldn't open it (\(error.localizedDescription))"))
            }
        }
        var result = try await arrange(rules: snapshot.rules, launchMissing: true)
        result.launched.insert(contentsOf: launched, at: 0)
        result.skipped.append(contentsOf: failed)
        events.publish(AtlasEvent(AtlasEvent.Name.snapshotRestored, payload: [
            "snapshotId": .string(snapshot.id.uuidString),
            "placed": .number(Double(result.placed.count)),
            "skipped": .number(Double(result.skipped.count)),
            "launched": .number(Double(result.launched.count)),
        ]))
        return result
    }

    public func deleteSnapshot(id: UUID) throws {
        try store.deleteSnapshot(id: id)
        events.publish(AtlasEvent(AtlasEvent.Name.snapshotSaved, payload: ["snapshotId": .string(id.uuidString), "deleted": true]))
    }

    // MARK: - Helpers

    /// Runs one Accessibility call with a deadline.
    private func timed<T: Sendable>(_ subject: String, _ body: @escaping @Sendable () async throws -> T) async throws -> T {
        do {
            return try await withTimeout(seconds: operationTimeout, operation: body)
        } catch ActionError.timedOut {
            throw WindowAdapterError.appNotResponding(subject)
        }
    }

    private func skip(_ placement: WindowPlacement, _ reason: String) -> WindowSkip {
        WindowSkip(bundleID: placement.bundleID, appName: placement.appName, title: placement.title, reason: reason)
    }

    static func reason(for error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
