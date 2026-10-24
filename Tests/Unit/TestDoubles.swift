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
    let permissionProvider: MockPermissionProvider
    let core: AtlasCore

    var engine: AutomationEngine { core.engine }

    init(
        system: MockSystemAdapter = MockSystemAdapter(),
        permissions: MockPermissionProvider = MockPermissionProvider()
    ) throws {
        self.store = try AtlasStore.inMemory()
        self.system = system
        self.permissionProvider = permissions
        self.core = AtlasCore(store: store, system: system, permissionProvider: permissions)
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
