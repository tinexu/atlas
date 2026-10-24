import Foundation

/// macOS authorisations ATLAS may need. Every action declares the ones it
/// uses, and the engine checks them before running it (spec 7.6).
public enum Permission: String, Codable, CaseIterable, Sendable, Identifiable {
    case accessibility
    case automation
    case notifications
    case fileAccess

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .accessibility: return "Accessibility"
        case .automation: return "Automation (Apple Events)"
        case .notifications: return "Notifications"
        case .fileAccess: return "Files & Folders"
        }
    }

    public var symbolName: String {
        switch self {
        case .accessibility: return "figure.wave"
        case .automation: return "gearshape.2"
        case .notifications: return "bell.badge"
        case .fileAccess: return "folder"
        }
    }

    /// Plain-language reason shown on the permissions dashboard.
    public var explanation: String {
        switch self {
        case .accessibility:
            return "Lets ATLAS move, resize, raise and minimize other apps' windows, so activating a Space can put its windows back where you saved them. ATLAS never closes windows or quits apps. Hiding apps doesn't need it."
        case .automation:
            return "Lets ATLAS send Apple Events to a specific app, e.g. telling Terminal which folder to open. macOS asks separately for each app the first time it's needed."
        case .notifications:
            return "Lets workflows tell you when something finished or needs your attention."
        case .fileAccess:
            return "ATLAS only touches files and folders you point it at. macOS asks the first time ATLAS reaches into protected places like Desktop, Documents or Downloads."
        }
    }

    /// Whether the engine may ask for this permission in the middle of a
    /// run. Accessibility can only be granted in System Settings, so a run
    /// fails with a clear message instead of popping the system prompt;
    /// the Permissions screen's Request Access button shows it.
    public var isRequestedDuringRuns: Bool {
        self != .accessibility
    }

    public var systemSettingsURL: URL? {
        switch self {
        case .accessibility:
            return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
        case .automation:
            return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")
        case .notifications:
            return URL(string: "x-apple.systempreferences:com.apple.preference.notifications")
        case .fileAccess:
            return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders")
        }
    }
}

public enum PermissionStatus: String, Sendable {
    case granted
    case denied
    case notDetermined
    /// macOS prompts on first use; there is nothing to pre-authorise.
    case managedBySystem
    /// Cannot be used in the current run mode (e.g. notifications when
    /// running unbundled via `swift run`).
    case unavailable

    public var title: String {
        switch self {
        case .granted: return "Granted"
        case .denied: return "Denied"
        case .notDetermined: return "Not requested"
        case .managedBySystem: return "Asked on first use"
        case .unavailable: return "Unavailable"
        }
    }

    /// Whether an action requiring this permission may proceed.
    public var allowsUse: Bool {
        self == .granted || self == .managedBySystem
    }
}

/// Reads and requests macOS authorisations. Swappable for tests.
public protocol PermissionProvider: Sendable {
    func status(of permission: Permission) async -> PermissionStatus
    func request(_ permission: Permission) async -> PermissionStatus
}
