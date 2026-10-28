import Foundation

public struct LaunchOutcome: Sendable, Equatable {
    public let bundleID: String
    public let displayName: String
    public let processID: Int32
    public let wasAlreadyRunning: Bool

    public init(bundleID: String, displayName: String, processID: Int32, wasAlreadyRunning: Bool) {
        self.bundleID = bundleID
        self.displayName = displayName
        self.processID = processID
        self.wasAlreadyRunning = wasAlreadyRunning
    }
}

public struct RunningApplication: Sendable, Hashable, Identifiable {
    public var id: Int32 { processID }
    public let bundleID: String
    public let name: String
    public let processID: Int32
    public let isActive: Bool

    public init(bundleID: String, name: String, processID: Int32, isActive: Bool) {
        self.bundleID = bundleID
        self.name = name
        self.processID = processID
        self.isActive = isActive
    }
}

/// Battery and power adapter state. Nil from `powerStatus()` on Macs
/// without a battery.
public struct PowerStatus: Sendable, Equatable {
    public let batteryPercent: Int
    public let isOnAdapter: Bool
    public let isCharging: Bool

    public init(batteryPercent: Int, isOnAdapter: Bool, isCharging: Bool) {
        self.batteryPercent = batteryPercent
        self.isOnAdapter = isOnAdapter
        self.isCharging = isCharging
    }
}

/// What rule conditions can learn about a file without reading it.
public struct FileInfo: Sendable, Equatable {
    public var createdAt: Date?
    public var modifiedAt: Date?
    public var typeIdentifier: String?
    /// Where it came from: download URLs and the creating app, as macOS recorded them.
    public var sources: [String]

    public init(createdAt: Date? = nil, modifiedAt: Date? = nil, typeIdentifier: String? = nil, sources: [String] = []) {
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
        self.typeIdentifier = typeIdentifier
        self.sources = sources
    }
}

public enum FileKind: Sendable, Equatable {
    case missing
    case file
    case directory
}

public enum SystemAdapterError: Error, LocalizedError, Equatable, Sendable {
    case applicationNotFound(String)
    case applicationNotRunning(String)
    case couldNotOpen(String)
    case notificationsUnavailable(String)
    case permissionDenied(String)

    public var errorDescription: String? {
        switch self {
        case .applicationNotFound(let id):
            return "No installed app has the bundle identifier “\(id)”."
        case .applicationNotRunning(let id):
            return "“\(id)” isn't running."
        case .couldNotOpen(let what):
            return "macOS couldn't open \(what)."
        case .notificationsUnavailable(let reason):
            return reason
        case .permissionDenied(let reason):
            return reason
        }
    }
}

/// The only place ATLAS touches the operating system. Actions talk to this
/// protocol, never to AppKit directly, which keeps the engine testable and
/// lets later stages add adapters (Accessibility windows, FSEvents, …).
public protocol SystemAdapter: Sendable {
    func launchApplication(bundleID: String, activate: Bool) async throws -> LaunchOutcome
    /// Politely asks an app to quit; the app still prompts about unsaved
    /// work. Returns false if the app refused or is still running.
    func quitApplication(bundleID: String) async throws -> Bool
    /// Hides every window of a running app without quitting it. Returns
    /// false if the app wasn't running.
    func hideApplication(bundleID: String) async throws -> Bool
    /// Shows a hidden app's windows again. Returns false if it wasn't running.
    func unhideApplication(bundleID: String) async throws -> Bool
    /// Brings a running app to the front. Returns false if it wasn't running.
    func activateApplication(bundleID: String) async throws -> Bool
    /// Minimizes a running app's windows into the Dock (needs
    /// Accessibility). Returns how many windows were minimized.
    func minimizeApplicationWindows(bundleID: String) async throws -> Int
    func open(url: URL, withApplication bundleID: String?) async throws
    func openFile(atPath path: String, withApplication bundleID: String?) async throws
    func reveal(path: String) async throws
    func postNotification(title: String, body: String) async throws
    func fileKind(atPath path: String) -> FileKind
    /// Bytes, or nil if nothing is there.
    func fileSize(atPath path: String) -> Int64?
    /// Moves or renames an item. Fails if something is already at `destination`.
    func moveItem(atPath path: String, toPath destination: String) async throws
    func copyItem(atPath path: String, toPath destination: String) async throws
    func createFolder(atPath path: String) async throws
    /// Moves an item to the Trash (never deletes outright). Returns where it went.
    func trashItem(atPath path: String) async throws -> String
    /// Dates, type and origin; nil if nothing is there.
    func fileInfo(atPath path: String) -> FileInfo?
    func fileTags(atPath path: String) -> [String]
    /// Replaces the item's Finder tags.
    func setFileTags(_ tags: [String], atPath path: String) async throws
    func powerStatus() -> PowerStatus?
    func applicationName(for bundleID: String) -> String?
    func runningApplications() -> [RunningApplication]
}
