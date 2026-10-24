#if os(macOS)
import AppKit
import ApplicationServices

/// Live window control through the public Accessibility API (AXUIElement)
/// and NSScreen. No private APIs: windows are identified by their
/// Accessibility element, which ATLAS remembers between listing them and
/// moving them.
///
/// Every call has a messaging timeout so an unresponsive app fails fast
/// instead of hanging, and every change first checks the permission is
/// still granted, so revoking it mid-run fails cleanly.
public final class MacWindowAdapter: WindowAdapter, @unchecked Sendable {
    /// Seconds an app gets to answer one Accessibility message.
    public static let messagingTimeout: Float = 1.0

    private struct Entry {
        let element: AXUIElement
        let processID: pid_t
        let appName: String
    }

    private let lock = NSLock()
    private var entries: [WindowID: Entry] = [:]

    public init() {
        // Applies to every element unless overridden.
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), Self.messagingTimeout)
    }

    public var isTrusted: Bool { AXIsProcessTrusted() }

    // MARK: - Displays

    public func displays() async -> [DisplayInfo] {
        await MainActor.run { Self.currentDisplays() }
    }

    @MainActor
    static func currentDisplays() -> [DisplayInfo] {
        let screens = NSScreen.screens
        // screens[0] is the primary display; AppKit's origin is its bottom-left.
        guard let primary = screens.first else { return [] }
        let height = primary.frame.height
        return screens.map { screen in
            let key = NSDeviceDescriptionKey("NSScreenNumber")
            let number = (screen.deviceDescription[key] as? NSNumber)?.uint32Value ?? 0
            return DisplayInfo(
                id: stableID(for: number),
                name: screen.localizedName,
                frame: ScreenCoordinates.axRect(fromAppKit: screen.frame, primaryHeight: height),
                visibleFrame: ScreenCoordinates.axRect(fromAppKit: screen.visibleFrame, primaryHeight: height),
                scale: Double(screen.backingScaleFactor),
                isMain: screen == primary
            )
        }
    }

    /// Survives reboots and reconnecting, unlike `CGDirectDisplayID`.
    static func stableID(for displayID: CGDirectDisplayID) -> String {
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue(),
              let string = CFUUIDCreateString(nil, uuid)
        else { return "display-\(displayID)" }
        return string as String
    }

    // MARK: - Windows

    private struct AppRecord: Sendable {
        let processID: pid_t
        let bundleID: String
        let name: String
        let isHidden: Bool
    }

    public func windows(bundleIDs: Set<String>?) async throws -> [WindowInfo] {
        guard isTrusted else { throw WindowAdapterError.accessibilityDenied }
        let (apps, displays) = await MainActor.run { () -> ([AppRecord], [DisplayInfo]) in
            let apps = NSWorkspace.shared.runningApplications.compactMap { app -> AppRecord? in
                guard app.activationPolicy == .regular, let bundleID = app.bundleIdentifier else { return nil }
                return AppRecord(processID: app.processIdentifier, bundleID: bundleID,
                                 name: app.localizedName ?? bundleID, isHidden: app.isHidden)
            }
            return (apps, Self.currentDisplays())
        }
        let stacking = Self.onScreenStacking()

        var result: [WindowInfo] = []
        var found: [WindowID: Entry] = [:]
        for app in apps where bundleIDs?.contains(app.bundleID) ?? true {
            let appElement = AXUIElementCreateApplication(app.processID)
            AXUIElementSetMessagingTimeout(appElement, Self.messagingTimeout)
            var value: CFTypeRef?
            let error = AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &value)
            if error == .apiDisabled { throw WindowAdapterError.accessibilityDenied }
            // An app that doesn't answer is left out rather than failing the list.
            guard error == .success, let windows = value as? [AXUIElement] else { continue }

            for (index, window) in windows.enumerated() {
                // Skip palettes, sheets and other non-document windows.
                guard Self.string(window, kAXSubroleAttribute) == kAXStandardWindowSubrole as String,
                      let frame = Self.frame(of: window)
                else { continue }
                let id = WindowID("\(app.processID)-\(CFHash(window))")
                found[id] = Entry(element: window, processID: app.processID, appName: app.name)
                let isMinimized = Self.bool(window, kAXMinimizedAttribute) ?? false
                let zIndex = stacking.firstIndex { $0.pid == app.processID && Self.roughlyEqual($0.bounds, frame) }
                result.append(WindowInfo(
                    id: id,
                    bundleID: app.bundleID,
                    appName: app.name,
                    processID: app.processID,
                    title: Self.string(window, kAXTitleAttribute) ?? "",
                    frame: frame,
                    displayID: displays.display(containing: frame)?.id,
                    isMinimized: isMinimized,
                    isFullScreen: Self.bool(window, "AXFullScreen") ?? false,
                    isAppHidden: app.isHidden,
                    isMovable: Self.isSettable(window, kAXPositionAttribute),
                    isResizable: Self.isSettable(window, kAXSizeAttribute),
                    // Off-screen windows (minimized, hidden) go behind the rest.
                    zIndex: zIndex ?? (10_000 + index)
                ))
            }
        }
        lock.synchronized {
            if bundleIDs == nil { entries = found } else { entries.merge(found) { _, new in new } }
        }
        return result.sorted { $0.zIndex < $1.zIndex }
    }

    public func setFrame(_ frame: CGRect, of window: WindowID) async throws -> CGRect {
        let entry = try entry(for: window)
        try set(entry, kAXPositionAttribute, point: frame.origin)
        try set(entry, kAXSizeAttribute, size: frame.size)
        // Growing a window near a screen edge can shift it; set the origin again.
        try set(entry, kAXPositionAttribute, point: frame.origin)
        guard let actual = Self.frame(of: entry.element) else { throw WindowAdapterError.windowGone(entry.appName) }
        return actual
    }

    public func raise(_ window: WindowID) async throws {
        let entry = try entry(for: window)
        try check(AXUIElementPerformAction(entry.element, kAXRaiseAction as CFString), entry)
    }

    public func setMinimized(_ minimized: Bool, window: WindowID) async throws {
        let entry = try entry(for: window)
        let value: CFBoolean = minimized ? kCFBooleanTrue : kCFBooleanFalse
        try check(AXUIElementSetAttributeValue(entry.element, kAXMinimizedAttribute as CFString, value), entry)
    }

    public func focus(_ window: WindowID) async throws {
        let entry = try entry(for: window)
        await MainActor.run {
            _ = NSRunningApplication(processIdentifier: entry.processID)?.activate()
        }
        try check(AXUIElementPerformAction(entry.element, kAXRaiseAction as CFString), entry)
        _ = AXUIElementSetAttributeValue(entry.element, kAXMainAttribute as CFString, kCFBooleanTrue)
    }

    // MARK: - Helpers

    private func entry(for window: WindowID) throws -> Entry {
        guard isTrusted else { throw WindowAdapterError.accessibilityDenied }
        guard let entry = lock.synchronized({ entries[window] }) else {
            throw WindowAdapterError.windowGone("app")
        }
        return entry
    }

    private func set(_ entry: Entry, _ attribute: String, point: CGPoint) throws {
        var point = point
        guard let value = AXValueCreate(.cgPoint, &point) else { throw WindowAdapterError.refused("couldn't encode the position") }
        try check(AXUIElementSetAttributeValue(entry.element, attribute as CFString, value), entry)
    }

    private func set(_ entry: Entry, _ attribute: String, size: CGSize) throws {
        var size = size
        guard let value = AXValueCreate(.cgSize, &size) else { throw WindowAdapterError.refused("couldn't encode the size") }
        try check(AXUIElementSetAttributeValue(entry.element, attribute as CFString, value), entry)
    }

    private func check(_ error: AXError, _ entry: Entry) throws {
        switch error {
        case .success:
            return
        case .apiDisabled:
            throw WindowAdapterError.accessibilityDenied
        case .invalidUIElement:
            throw WindowAdapterError.windowGone(entry.appName)
        case .cannotComplete:
            if !isTrusted { throw WindowAdapterError.accessibilityDenied }
            throw WindowAdapterError.appNotResponding(entry.appName)
        case .attributeUnsupported, .actionUnsupported, .notImplemented:
            throw WindowAdapterError.refused("\(entry.appName) doesn't support moving its windows")
        case .illegalArgument:
            throw WindowAdapterError.refused("\(entry.appName) refused the new position or size")
        default:
            throw WindowAdapterError.refused("\(entry.appName) refused (Accessibility error \(error.rawValue))")
        }
    }

    static func frame(of element: AXUIElement) -> CGRect? {
        guard let origin: CGPoint = axValue(element, kAXPositionAttribute, .cgPoint),
              let size: CGSize = axValue(element, kAXSizeAttribute, .cgSize)
        else { return nil }
        return CGRect(origin: origin, size: size)
    }

    private static func axValue<T>(_ element: AXUIElement, _ attribute: String, _ type: AXValueType) -> T? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &ref) == .success,
              let ref, CFGetTypeID(ref) == AXValueGetTypeID()
        else { return nil }
        let value = ref as! AXValue // Type checked above.
        let pointer = UnsafeMutablePointer<T>.allocate(capacity: 1)
        defer { pointer.deallocate() }
        return AXValueGetValue(value, type, pointer) ? pointer.pointee : nil
    }

    private static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &ref) == .success else { return nil }
        return ref as? String
    }

    private static func bool(_ element: AXUIElement, _ attribute: String) -> Bool? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &ref) == .success else { return nil }
        return (ref as? NSNumber)?.boolValue
    }

    private static func isSettable(_ element: AXUIElement, _ attribute: String) -> Bool {
        var settable = DarwinBoolean(false)
        guard AXUIElementIsAttributeSettable(element, attribute as CFString, &settable) == .success else { return false }
        return settable.boolValue
    }

    /// On-screen windows front to back, from the public window list. Bounds
    /// and owner don't need Screen Recording permission (titles would).
    private static func onScreenStacking() -> [(pid: pid_t, bounds: CGRect)] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return [] }
        return list.compactMap { info in
            guard (info[kCGWindowLayer as String] as? Int) == 0,
                  let pid = info[kCGWindowOwnerPID as String] as? pid_t,
                  let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict)
            else { return nil }
            return (pid, bounds)
        }
    }

    private static func roughlyEqual(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) < 3 && abs(a.minY - b.minY) < 3 && abs(a.width - b.width) < 3 && abs(a.height - b.height) < 3
    }
}
#endif
