#if os(macOS)
import AppKit
import CoreServices
import IOKit.ps
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

    public func hideApplication(bundleID: String) async throws -> Bool {
        await MainActor.run {
            let apps = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            guard !apps.isEmpty else { return false }
            // Always ask: `isHidden` is a cached value that lags behind, e.g.
            // just after a Dock click unhid the app. Hiding twice is harmless.
            apps.forEach { _ = $0.hide() }
            return true
        }
    }

    public func unhideApplication(bundleID: String) async throws -> Bool {
        await MainActor.run {
            let apps = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            guard !apps.isEmpty else { return false }
            apps.filter(\.isHidden).forEach { _ = $0.unhide() }
            return true
        }
    }

    public func activateApplication(bundleID: String) async throws -> Bool {
        await MainActor.run {
            guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else { return false }
            if app.isHidden { _ = app.unhide() }
            return app.activate()
        }
    }

    public func minimizeApplicationWindows(bundleID: String) async throws -> Int {
        try await MainActor.run {
            let apps = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            guard !apps.isEmpty else { return 0 }
            guard AXIsProcessTrusted() else {
                throw SystemAdapterError.permissionDenied(
                    "Minimizing another app's windows needs Accessibility permission. Grant it on the Permissions screen."
                )
            }
            var minimized = 0
            for app in apps {
                let element = AXUIElementCreateApplication(app.processIdentifier)
                var value: CFTypeRef?
                guard AXUIElementCopyAttributeValue(element, kAXWindowsAttribute as CFString, &value) == .success,
                      let windows = value as? [AXUIElement]
                else { continue }
                for window in windows
                where AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanTrue) == .success {
                    minimized += 1
                }
            }
            return minimized
        }
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

    public func fileSize(atPath path: String) -> Int64? {
        (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.int64Value
    }

    public func moveItem(atPath path: String, toPath destination: String) async throws {
        try FileManager.default.moveItem(atPath: path, toPath: destination)
    }

    public func copyItem(atPath path: String, toPath destination: String) async throws {
        try FileManager.default.copyItem(atPath: path, toPath: destination)
    }

    public func createFolder(atPath path: String) async throws {
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    }

    public func trashItem(atPath path: String) async throws -> String {
        var resulting: NSURL?
        try FileManager.default.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: &resulting)
        return resulting?.path ?? path
    }

    public func fileInfo(atPath path: String) -> FileInfo? {
        let url = URL(fileURLWithPath: path)
        guard let values = try? url.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey, .typeIdentifierKey])
        else { return nil }
        var sources: [String] = []
        if let item = MDItemCreateWithURL(nil, url as CFURL) {
            if let whereFroms = MDItemCopyAttribute(item, kMDItemWhereFroms) as? [String] { sources += whereFroms }
            if let creator = MDItemCopyAttribute(item, kMDItemCreator) as? String { sources.append(creator) }
        }
        return FileInfo(createdAt: values.creationDate, modifiedAt: values.contentModificationDate,
                        typeIdentifier: values.typeIdentifier, sources: sources)
    }

    public func fileTags(atPath path: String) -> [String] {
        (try? URL(fileURLWithPath: path).resourceValues(forKeys: [.tagNamesKey]).tagNames) ?? []
    }

    public func setFileTags(_ tags: [String], atPath path: String) async throws {
        try (URL(fileURLWithPath: path) as NSURL).setResourceValue(tags, forKey: .tagNamesKey)
    }

    public func powerStatus() -> PowerStatus? {
        PowerSources.current()
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
/// Reads battery and power adapter state from IOKit.
enum PowerSources {
    static func current() -> PowerStatus? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef]
        else { return nil }
        let adapter = (IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String?) == kIOPMACPowerKey
        for source in list {
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  (description[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType,
                  let current = description[kIOPSCurrentCapacityKey] as? Int,
                  let maximum = description[kIOPSMaxCapacityKey] as? Int, maximum > 0
            else { continue }
            return PowerStatus(
                batteryPercent: Int((Double(current) / Double(maximum) * 100).rounded()),
                isOnAdapter: adapter,
                isCharging: description[kIOPSIsChargingKey] as? Bool ?? false
            )
        }
        return nil
    }
}
#endif
