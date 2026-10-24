import CoreGraphics
import Foundation

/// A connected display. Frames are in Accessibility coordinates (top-left
/// origin, see `ScreenCoordinates`).
public struct DisplayInfo: Sendable, Hashable, Codable, Identifiable {
    /// Stable across reboots and reconnections
    /// (`CGDisplayCreateUUIDFromDisplayID`).
    public let id: String
    public let name: String
    public let frame: CGRect
    /// The frame minus the menu bar and Dock: where windows should go.
    public let visibleFrame: CGRect
    public let scale: Double
    /// The primary display, the one with the menu bar.
    public let isMain: Bool

    public init(id: String, name: String, frame: CGRect, visibleFrame: CGRect, scale: Double = 2, isMain: Bool) {
        self.id = id
        self.name = name
        self.frame = frame
        self.visibleFrame = visibleFrame
        self.scale = scale
        self.isMain = isMain
    }
}

/// Identifies a window for the lifetime of a window list. Opaque: only the
/// adapter that produced it can interpret it.
public struct WindowID: RawRepresentable, Hashable, Sendable, Codable, CustomStringConvertible {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public var description: String { rawValue }
}

/// One on-screen window of a regular app.
public struct WindowInfo: Sendable, Hashable, Identifiable {
    public let id: WindowID
    public let bundleID: String
    public let appName: String
    public let processID: Int32
    public let title: String
    /// Accessibility coordinates.
    public let frame: CGRect
    /// The display holding most of the window, if any.
    public let displayID: String?
    public let isMinimized: Bool
    public let isFullScreen: Bool
    /// Whether the app is hidden (Cmd-H).
    public let isAppHidden: Bool
    public let isMovable: Bool
    public let isResizable: Bool
    /// 0 is frontmost.
    public let zIndex: Int

    public init(
        id: WindowID,
        bundleID: String,
        appName: String,
        processID: Int32 = 0,
        title: String,
        frame: CGRect,
        displayID: String?,
        isMinimized: Bool = false,
        isFullScreen: Bool = false,
        isAppHidden: Bool = false,
        isMovable: Bool = true,
        isResizable: Bool = true,
        zIndex: Int = 0
    ) {
        self.id = id
        self.bundleID = bundleID
        self.appName = appName
        self.processID = processID
        self.title = title
        self.frame = frame
        self.displayID = displayID
        self.isMinimized = isMinimized
        self.isFullScreen = isFullScreen
        self.isAppHidden = isAppHidden
        self.isMovable = isMovable
        self.isResizable = isResizable
        self.zIndex = zIndex
    }

    /// Why this window can't be moved, or nil if it can.
    public var immovableReason: String? {
        if isFullScreen { return "the window is in full screen" }
        if !isMovable { return "the app doesn't let its window be moved" }
        return nil
    }
}

public enum WindowAdapterError: Error, LocalizedError, Equatable, Sendable {
    /// Accessibility isn't granted, or was turned off while ATLAS was running.
    case accessibilityDenied
    case windowGone(String)
    case appNotResponding(String)
    case refused(String)

    public var errorDescription: String? {
        switch self {
        case .accessibilityDenied:
            return "ATLAS needs Accessibility permission to arrange windows. Grant it on the Permissions screen, then try again."
        case .windowGone(let app):
            return "the \(app) window closed before ATLAS could move it"
        case .appNotResponding(let app):
            return "\(app) isn't responding"
        case .refused(let reason):
            return reason
        }
    }
}

/// Reads and arranges other apps' windows. Like `SystemAdapter`, this is the
/// only way ATLAS touches windows, so the engine and tests never depend on
/// AppKit or Accessibility directly.
///
/// It can move, resize, raise, minimize and focus windows. It has no way to
/// close a window or quit an app, by design.
public protocol WindowAdapter: Sendable {
    /// Whether ATLAS may control windows right now. Checked before every
    /// change, so revoking the permission mid-run fails cleanly.
    var isTrusted: Bool { get }
    func displays() async -> [DisplayInfo]
    /// Standard windows of running regular apps, frontmost first. Pass
    /// bundle IDs to limit the search (much cheaper).
    func windows(bundleIDs: Set<String>?) async throws -> [WindowInfo]
    /// Moves and resizes a window. Returns the frame the window actually
    /// ended up with, which apps with size limits may change.
    func setFrame(_ frame: CGRect, of window: WindowID) async throws -> CGRect
    func raise(_ window: WindowID) async throws
    func setMinimized(_ minimized: Bool, window: WindowID) async throws
    /// Brings the window's app to the front with this window on top.
    func focus(_ window: WindowID) async throws
}

/// Used when no window control is available (e.g. tests that don't need it).
public struct UnavailableWindowAdapter: WindowAdapter {
    public init() {}
    public var isTrusted: Bool { false }
    public func displays() async -> [DisplayInfo] { [] }
    public func windows(bundleIDs: Set<String>?) async throws -> [WindowInfo] { throw WindowAdapterError.accessibilityDenied }
    public func setFrame(_ frame: CGRect, of window: WindowID) async throws -> CGRect { throw WindowAdapterError.accessibilityDenied }
    public func raise(_ window: WindowID) async throws { throw WindowAdapterError.accessibilityDenied }
    public func setMinimized(_ minimized: Bool, window: WindowID) async throws { throw WindowAdapterError.accessibilityDenied }
    public func focus(_ window: WindowID) async throws { throw WindowAdapterError.accessibilityDenied }
}

extension Array where Element == DisplayInfo {
    /// The primary display, or the first one if none is marked.
    public var main: DisplayInfo? { first(where: \.isMain) ?? first }

    /// The display holding the center of `rect`, else the one it overlaps
    /// most, else nil.
    public func display(containing rect: CGRect) -> DisplayInfo? {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        if let hit = first(where: { $0.frame.contains(center) }) { return hit }
        let best = self
            .map { ($0, $0.frame.intersection(rect)) }
            .filter { !$0.1.isNull }
            .max { $0.1.width * $0.1.height < $1.1.width * $1.1.height }
        return best?.0
    }
}
