#if os(macOS)
import AppKit
import UserNotifications

/// Live macOS implementation backed by NSWorkspace and UserNotifications.
public struct MacSystemAdapter: SystemAdapter {
    public init() {}

    public func launchApplication(bundleID: String, activate: Bool) async throws -> LaunchOutcome {
        try await Self.launch(bundleID: bundleID, activate: activate)
    }

    @MainActor
    private static func launch(bundleID: String, activate: Bool) async throws -> LaunchOutcome {
        if let existing = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first {
            if activate { existing.activate() }
            return LaunchOutcome(
                bundleID: bundleID,
                displayName: existing.localizedName ?? bundleID,
                processID: existing.processIdentifier,
                wasAlreadyRunning: true
            )
        }
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            throw SystemAdapterError.applicationNotFound(bundleID)
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = activate
        let app = try await NSWorkspace.shared.openApplication(at: appURL, configuration: configuration)
        return LaunchOutcome(
            bundleID: bundleID,
            displayName: app.localizedName ?? appURL.deletingPathExtension().lastPathComponent,
            processID: app.processIdentifier,
            wasAlreadyRunning: false
        )
    }

    public func quitApplication(bundleID: String) async throws -> Bool {
        let asked = await MainActor.run { () -> Bool in
            let apps = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            guard !apps.isEmpty else { return false }
            // terminate() is the polite request: the app may show a
            // "save changes?" sheet or refuse. We never force-quit.
            apps.forEach { _ = $0.terminate() }
            return true
        }
        guard asked else { throw SystemAdapterError.applicationNotRunning(bundleID) }

        // Give the app a moment to wind down, then report what happened.
        for _ in 0..<20 {
            try await Task.sleep(nanoseconds: 250_000_000)
            let stillRunning = await MainActor.run {
                !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
            }
            if !stillRunning { return true }
        }
        return false
    }

    public func open(url: URL, withApplication bundleID: String?) async throws {
        try await Self.open(urls: [url], with: bundleID, description: url.absoluteString)
    }

    public func openFile(atPath path: String, withApplication bundleID: String?) async throws {
        try await Self.open(urls: [URL(fileURLWithPath: path)], with: bundleID, description: path)
    }

    @MainActor
    private static func open(urls: [URL], with bundleID: String?, description: String) async throws {
        let workspace = NSWorkspace.shared
        if let bundleID, !bundleID.isEmpty {
            guard let appURL = workspace.urlForApplication(withBundleIdentifier: bundleID) else {
                throw SystemAdapterError.applicationNotFound(bundleID)
            }
            _ = try await workspace.open(urls, withApplicationAt: appURL, configuration: NSWorkspace.OpenConfiguration())
        } else {
            for url in urls where !workspace.open(url) {
                throw SystemAdapterError.couldNotOpen(description)
            }
        }
    }

    public func reveal(path: String) async throws {
        let kind = fileKind(atPath: path)
        try await MainActor.run {
            let url = URL(fileURLWithPath: path)
            switch kind {
            case .missing:
                throw SystemAdapterError.couldNotOpen(path)
            case .directory:
                guard NSWorkspace.shared.open(url) else { throw SystemAdapterError.couldNotOpen(path) }
            case .file:
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
        }
    }

    public func postNotification(title: String, body: String) async throws {
        // UNUserNotificationCenter requires a real app bundle; calling it
        // from a bare `swift run` binary crashes, so check first.
        guard Bundle.main.bundleIdentifier != nil else {
            throw SystemAdapterError.notificationsUnavailable(
                "Notifications need ATLAS to run as an app bundle. Build it with scripts/build-app.sh."
            )
        }
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .notDetermined:
            let granted = try await center.requestAuthorization(options: [.alert, .sound])
            guard granted else { throw SystemAdapterError.permissionDenied("Notifications are turned off for ATLAS.") }
        case .denied:
            throw SystemAdapterError.permissionDenied("Notifications are turned off for ATLAS in System Settings.")
        default:
            break
        }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        try await center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    public func fileKind(atPath path: String) -> FileKind {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else { return .missing }
        return isDirectory.boolValue ? .directory : .file
    }

    public func applicationName(for bundleID: String) -> String? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        return FileManager.default.displayName(atPath: url.path)
            .replacingOccurrences(of: ".app", with: "")
    }

    public func runningApplications() -> [RunningApplication] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { app in
                guard let bundleID = app.bundleIdentifier else { return nil }
                return RunningApplication(
                    bundleID: bundleID,
                    name: app.localizedName ?? bundleID,
                    processID: app.processIdentifier,
                    isActive: app.isActive
                )
            }
    }
}
#endif
