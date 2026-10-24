import Foundation
@testable import AtlasCore

/// Records every system call instead of touching the real Mac.
final class MockSystemAdapter: SystemAdapter, @unchecked Sendable {
    private let lock = NSLock()
    private var _calls: [String] = []
    private var _running: Set<String> = []

    var installedApps: [String: String] = [
        "com.apple.Terminal": "Terminal",
        "com.apple.Notes": "Notes",
        "com.apple.Music": "Music",
    ]
    var failingBundleIDs: Set<String> = []
    /// Number of times launches of a bundle should fail before succeeding.
    var transientFailures: [String: Int] = [:]
    var launchDelay: TimeInterval = 0
    var refusesToQuit = false
    var failsToOpenURLs = false
    var existingPaths: [String: FileKind] = [:]

    var calls: [String] { lock.synchronized { _calls } }

    private func record(_ call: String) {
        lock.synchronized { _calls.append(call) }
    }

    func markRunning(_ bundleID: String) {
        lock.synchronized { _ = _running.insert(bundleID) }
    }

    func launchApplication(bundleID: String, activate: Bool) async throws -> LaunchOutcome {
        record("launch:\(bundleID)")
        if launchDelay > 0 {
            try await Task.sleep(nanoseconds: UInt64(launchDelay * 1_000_000_000))
        }
        let shouldFailTransiently: Bool = lock.synchronized {
            guard let remaining = transientFailures[bundleID], remaining > 0 else { return false }
            transientFailures[bundleID] = remaining - 1
            return true
        }
        if shouldFailTransiently { throw SystemAdapterError.couldNotOpen(bundleID) }
        guard let name = installedApps[bundleID], !failingBundleIDs.contains(bundleID) else {
            throw SystemAdapterError.applicationNotFound(bundleID)
        }
        let wasRunning = lock.synchronized { !_running.insert(bundleID).inserted }
        return LaunchOutcome(bundleID: bundleID, displayName: name, processID: 42, wasAlreadyRunning: wasRunning)
    }

    func quitApplication(bundleID: String) async throws -> Bool {
        record("quit:\(bundleID)")
        if refusesToQuit { return false }
        lock.synchronized { _ = _running.remove(bundleID) }
        return true
    }

    func hideApplication(bundleID: String) async throws -> Bool {
        record("hide:\(bundleID)")
        return lock.synchronized { _running.contains(bundleID) }
    }

    func minimizeApplicationWindows(bundleID: String) async throws -> Int {
        record("minimize:\(bundleID)")
        return lock.synchronized { _running.contains(bundleID) ? 1 : 0 }
    }

    func open(url: URL, withApplication bundleID: String?) async throws {
        record("open-url:\(url.absoluteString)")
        if failsToOpenURLs { throw SystemAdapterError.couldNotOpen(url.absoluteString) }
    }

    func openFile(atPath path: String, withApplication bundleID: String?) async throws {
        record("open-file:\(path)")
    }

    func reveal(path: String) async throws {
        record("reveal:\(path)")
    }

    func postNotification(title: String, body: String) async throws {
        record("notify:\(title)")
    }

    func fileKind(atPath path: String) -> FileKind {
        existingPaths[path] ?? .missing
    }

    func applicationName(for bundleID: String) -> String? {
        installedApps[bundleID]
    }

    func runningApplications() -> [RunningApplication] {
        lock.synchronized {
            _running.map { RunningApplication(bundleID: $0, name: installedApps[$0] ?? $0, processID: 42, isActive: false) }
        }
    }
}

/// Permission states set directly by the test.
final class MockPermissionProvider: PermissionProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var statuses: [Permission: PermissionStatus]
    private var grantOnRequest: Bool
    private(set) var requestCount = 0

    init(statuses: [Permission: PermissionStatus] = [:], grantOnRequest: Bool = true) {
        self.statuses = statuses
        self.grantOnRequest = grantOnRequest
    }

    func status(of permission: Permission) async -> PermissionStatus {
        lock.synchronized { statuses[permission] ?? .granted }
    }

    func request(_ permission: Permission) async -> PermissionStatus {
        lock.synchronized {
            requestCount += 1
            let status: PermissionStatus = grantOnRequest ? .granted : .denied
            statuses[permission] = status
            return status
        }
    }
}

/// Bundles a fully wired engine around the mocks.
struct TestHarness {
    let store: AtlasStore
    let system: MockSystemAdapter
    let windows: MockWindowAdapter
    let permissionProvider: MockPermissionProvider
    let core: AtlasCore

    var engine: AutomationEngine { core.engine }

    init(
        system: MockSystemAdapter = MockSystemAdapter(),
        windows: MockWindowAdapter = MockWindowAdapter(),
        permissions: MockPermissionProvider = MockPermissionProvider()
    ) throws {
        self.store = try AtlasStore.inMemory()
        self.system = system
        self.windows = windows
        self.permissionProvider = permissions
        windows.system = system
        self.core = AtlasCore(store: store, system: system, permissionProvider: permissions, windowAdapter: windows)
        core.windows.windowWaitTimeout = 0.5
        core.windows.pollInterval = 0.02
    }
}

/// Displays and windows set up by the test. Records every change so tests
/// can assert that nothing was touched, and never closes anything because
/// the protocol can't.
final class MockWindowAdapter: WindowAdapter, @unchecked Sendable {
    private let lock = NSLock()
    private var _calls: [String] = []
    private var _windows: [WindowInfo] = []
    private var _pending: [String: [WindowInfo]] = [:]
    private var _trusted = true
    private var movesBeforeRevoking: Int?

    /// When set, only running apps' windows are listed, and pending windows
    /// appear once their app runs.
    weak var system: MockSystemAdapter?
    var displayList: [DisplayInfo] = [MockWindowAdapter.builtIn]
    /// Windows that accept a move but snap back.
    var refusesToMove: Set<String> = []

    /// 1440×900 laptop with a 25 pt menu bar.
    static let builtIn = DisplayInfo(
        id: "BUILTIN", name: "Built-in Display",
        frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
        visibleFrame: CGRect(x: 0, y: 25, width: 1440, height: 875),
        isMain: true
    )
    /// 2560×1440 external to the right, its top 200 pt higher.
    static let external = DisplayInfo(
        id: "EXTERNAL", name: "Studio Display",
        frame: CGRect(x: 1440, y: -200, width: 2560, height: 1440),
        visibleFrame: CGRect(x: 1440, y: -200, width: 2560, height: 1440),
        isMain: false
    )

    var calls: [String] { lock.synchronized { _calls } }
    var mutatingCalls: [String] { calls.filter { !$0.hasPrefix("list") } }

    var trusted: Bool {
        get { lock.synchronized { _trusted } }
        set { lock.synchronized { _trusted = newValue } }
    }

    /// Turns the permission off after `count` successful moves.
    func revokeAfter(moves count: Int) {
        lock.synchronized { movesBeforeRevoking = count }
    }

    @discardableResult
    func addWindow(
        _ bundleID: String, app: String, title: String = "", frame: CGRect = CGRect(x: 100, y: 100, width: 600, height: 400),
        minimized: Bool = false, fullScreen: Bool = false, movable: Bool = true, resizable: Bool = true,
        appHidden: Bool = false, untilLaunched: Bool = false
    ) -> WindowInfo {
        lock.synchronized {
            let window = WindowInfo(
                id: WindowID("\(app)-\(_windows.count + _pending.values.joined().count)"),
                bundleID: bundleID, appName: app, title: title, frame: frame,
                displayID: displayList.display(containing: frame)?.id,
                isMinimized: minimized, isFullScreen: fullScreen, isAppHidden: appHidden,
                isMovable: movable, isResizable: resizable,
                zIndex: _windows.count + _pending.values.joined().count
            )
            if untilLaunched { _pending[bundleID, default: []].append(window) } else { _windows.append(window) }
            return window
        }
    }

    func frame(of id: WindowID) -> CGRect? {
        lock.synchronized { _windows.first { $0.id == id }?.frame }
    }

    func window(_ id: WindowID) -> WindowInfo? {
        lock.synchronized { _windows.first { $0.id == id } }
    }

    private func record(_ call: String) {
        lock.synchronized { _calls.append(call) }
    }

    var isTrusted: Bool { trusted }

    func displays() async -> [DisplayInfo] { displayList }

    func windows(bundleIDs: Set<String>?) async throws -> [WindowInfo] {
        guard trusted else { throw WindowAdapterError.accessibilityDenied }
        record("list")
        let running = system.map { Set($0.runningApplications().map(\.bundleID)) }
        return lock.synchronized {
            if let running {
                for (bundleID, pending) in _pending where running.contains(bundleID) {
                    _windows.append(contentsOf: pending)
                    _pending[bundleID] = nil
                }
            }
            return _windows.filter { window in
                (bundleIDs?.contains(window.bundleID) ?? true) && (running?.contains(window.bundleID) ?? true)
            }
        }
    }

    func setFrame(_ frame: CGRect, of window: WindowID) async throws -> CGRect {
        guard trusted else { throw WindowAdapterError.accessibilityDenied }
        return try lock.synchronized {
            guard let index = _windows.firstIndex(where: { $0.id == window }) else { throw WindowAdapterError.windowGone("app") }
            let old = _windows[index]
            _calls.append("frame:\(old.appName):\(Int(frame.minX)),\(Int(frame.minY)),\(Int(frame.width)),\(Int(frame.height))")
            if let remaining = movesBeforeRevoking {
                if remaining <= 1 { _trusted = false; movesBeforeRevoking = nil } else { movesBeforeRevoking = remaining - 1 }
            }
            if refusesToMove.contains(old.appName) { return old.frame }
            let size = old.isResizable ? frame.size : old.frame.size
            let newFrame = CGRect(origin: frame.origin, size: size)
            _windows[index] = old.with(frame: newFrame, displayID: displayList.display(containing: newFrame)?.id)
            return newFrame
        }
    }

    func raise(_ window: WindowID) async throws {
        guard trusted else { throw WindowAdapterError.accessibilityDenied }
        record("raise:\(name(of: window))")
    }

    func setMinimized(_ minimized: Bool, window: WindowID) async throws {
        guard trusted else { throw WindowAdapterError.accessibilityDenied }
        record("\(minimized ? "minimize" : "unminimize"):\(name(of: window))")
        lock.synchronized {
            if let index = _windows.firstIndex(where: { $0.id == window }) {
                _windows[index] = _windows[index].with(minimized: minimized)
            }
        }
    }

    func focus(_ window: WindowID) async throws {
        guard trusted else { throw WindowAdapterError.accessibilityDenied }
        record("focus:\(name(of: window))")
    }

    private func name(of window: WindowID) -> String {
        lock.synchronized { _windows.first { $0.id == window }?.appName ?? window.rawValue }
    }
}

extension WindowInfo {
    func with(frame: CGRect? = nil, displayID: String? = nil, minimized: Bool? = nil) -> WindowInfo {
        WindowInfo(
            id: id, bundleID: bundleID, appName: appName, processID: processID, title: title,
            frame: frame ?? self.frame, displayID: displayID ?? self.displayID,
            isMinimized: minimized ?? isMinimized, isFullScreen: isFullScreen, isAppHidden: isAppHidden,
            isMovable: isMovable, isResizable: isResizable, zIndex: zIndex
        )
    }
}

extension WorkflowStep {
    static func launch(_ bundleID: String, retries: Int = 0) -> WorkflowStep {
        WorkflowStep(actionID: LaunchApplicationAction.id, parameters: ["bundleId": .string(bundleID)], maxRetries: retries)
    }

    static func log(_ message: String) -> WorkflowStep {
        WorkflowStep(actionID: LogMessageAction.id, parameters: ["message": .string(message)])
    }

    static func wait(_ seconds: Double, timeout: TimeInterval? = nil) -> WorkflowStep {
        WorkflowStep(actionID: DelayAction.id, parameters: ["seconds": .number(seconds)], timeout: timeout)
    }
}
