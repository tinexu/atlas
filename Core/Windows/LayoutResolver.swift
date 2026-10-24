import CoreGraphics
import Foundation

/// Where one window should go.
public struct WindowPlacement: Sendable, Hashable {
    public let windowID: WindowID
    public let ruleID: UUID
    public let bundleID: String
    public let appName: String
    public let title: String
    /// Accessibility coordinates, already clamped to the visible frame.
    public let frame: CGRect
    public let displayID: String
    public let displayName: String
    public let state: WindowState
    public let zOrder: Int
    /// The window is minimized now and must be restored first.
    public let needsUnminimize: Bool
    /// Something the user should know, e.g. a display fallback.
    public let note: String?
}

/// A window (or app) a rule couldn't place, and why.
public struct WindowSkip: Sendable, Hashable {
    public let bundleID: String
    public let appName: String
    public let title: String?
    public let reason: String

    public init(bundleID: String, appName: String, title: String?, reason: String) {
        self.bundleID = bundleID
        self.appName = appName
        self.title = title
        self.reason = reason
    }

    /// "Couldn't move Notes: the window is in full screen".
    public var message: String {
        let subject = title.map { $0.isEmpty ? appName : "\(appName) (“\($0)”)" } ?? appName
        return "Couldn't move \(subject): \(reason)"
    }
}

public struct PlacementPlan: Sendable, Hashable {
    public var placements: [WindowPlacement]
    public var skipped: [WindowSkip]
    /// Apps with rules that aren't running; launch them and plan again.
    public var appsToLaunch: [String]
    /// Running apps with rules but no windows yet; worth waiting for.
    public var appsWithoutWindows: [String]
}

/// Turns window rules into a placement plan. Pure: no system access, so
/// every decision is unit-tested.
///
/// - Rules with a title pattern are matched before bundle-only rules.
/// - Each window is placed at most once.
/// - Extra windows of an app with a bundle-only rule cascade slightly offset.
/// - A rule whose display is gone falls back to the main display, keeping
///   its relative position and size.
/// - Every frame is clamped to a display's visible frame: never off-screen.
/// - Full-screen and immovable windows are skipped with a reason.
public enum LayoutResolver {
    public static let cascadeStep: CGFloat = 26

    public static func plan(
        rules: [WindowRule],
        displays: [DisplayInfo],
        windows: [WindowInfo],
        runningBundleIDs: Set<String>
    ) -> PlacementPlan {
        var plan = PlacementPlan(placements: [], skipped: [], appsToLaunch: [], appsWithoutWindows: [])
        guard !displays.isEmpty else {
            plan.skipped = rules.map {
                WindowSkip(bundleID: $0.bundleID, appName: $0.displayName, title: nil, reason: "no displays were found")
            }
            return plan
        }

        let windowsByApp = Dictionary(grouping: windows.sorted { $0.zIndex < $1.zIndex }, by: \.bundleID)
        var used = Set<WindowID>()
        var notedApps = Set<String>()

        // Title rules first, then bundle-only rules; ties keep rule order.
        let ordered = rules.enumerated().sorted { a, b in
            let at = a.element.titleMatch == nil ? 1 : 0
            let bt = b.element.titleMatch == nil ? 1 : 0
            return at != bt ? at < bt : a.offset < b.offset
        }.map(\.element)

        for rule in ordered {
            let appWindows = windowsByApp[rule.bundleID] ?? []
            if appWindows.isEmpty {
                guard notedApps.insert(rule.bundleID).inserted else { continue }
                if runningBundleIDs.contains(rule.bundleID) {
                    plan.appsWithoutWindows.append(rule.bundleID)
                } else {
                    plan.appsToLaunch.append(rule.bundleID)
                }
                continue
            }
            let candidates = appWindows.filter { !used.contains($0.id) && (rule.titleMatch?.matches($0.title) ?? true) }
            guard let window = candidates.first else {
                let reason = rule.titleMatch.map { "no open window's title matches “\($0.pattern)”" }
                    ?? "every open window was already placed by another rule"
                plan.skipped.append(WindowSkip(bundleID: rule.bundleID, appName: appWindows[0].appName, title: nil, reason: reason))
                continue
            }
            used.insert(window.id)
            plan.append(place(window, rule: rule, displays: displays, offset: 0))
        }

        // Extra windows of apps with a bundle-only rule cascade from it.
        for rule in rules where rule.titleMatch == nil {
            let extras = (windowsByApp[rule.bundleID] ?? []).filter { !used.contains($0.id) }
            for (index, window) in extras.enumerated() {
                used.insert(window.id)
                plan.append(place(window, rule: rule, displays: displays, offset: CGFloat(index + 1)))
            }
        }
        return plan
    }

    /// Where a rule puts a window on the current displays, without needing
    /// the window itself. Used for previews and the editor.
    public static func target(
        for rule: WindowRule,
        displays: [DisplayInfo],
        currentDisplayID: String? = nil
    ) -> (frame: CGRect, display: DisplayInfo, note: String?)? {
        guard let (display, note) = resolveDisplay(rule.display, displays: displays, currentDisplayID: currentDisplayID) else {
            return nil
        }
        let frame = clamp(rule.frame.absolute(in: display.visibleFrame), to: display.visibleFrame)
        return (frame, display, note)
    }

    /// Keeps `rect` fully inside `bounds`, shrinking it if it's too big.
    public static func clamp(_ rect: CGRect, to bounds: CGRect) -> CGRect {
        let width = min(max(rect.width, 1), bounds.width)
        let height = min(max(rect.height, 1), bounds.height)
        let x = min(max(rect.minX, bounds.minX), bounds.maxX - width)
        let y = min(max(rect.minY, bounds.minY), bounds.maxY - height)
        return CGRect(x: x, y: y, width: width, height: height)
    }

    // MARK: - Helpers

    fileprivate static func place(_ window: WindowInfo, rule: WindowRule, displays: [DisplayInfo], offset: CGFloat) -> Resolution {
        if let reason = window.immovableReason {
            return .skipped(WindowSkip(bundleID: window.bundleID, appName: window.appName, title: window.title, reason: reason))
        }
        guard let target = target(for: rule, displays: displays, currentDisplayID: window.displayID) else {
            return .skipped(WindowSkip(bundleID: window.bundleID, appName: window.appName, title: window.title,
                                       reason: "no displays were found"))
        }
        var frame = target.frame
        var notes = [target.note].compactMap { $0 }
        if !window.isResizable {
            // Fixed-size windows keep their size and move to the rule's origin.
            frame.size = window.frame.size
            notes.append("kept its size because \(window.appName) doesn't allow resizing it")
        }
        if offset > 0 {
            frame = frame.offsetBy(dx: cascadeStep * offset, dy: cascadeStep * offset)
        }
        frame = clamp(frame, to: target.display.visibleFrame)
        return .placed(WindowPlacement(
            windowID: window.id,
            ruleID: rule.id,
            bundleID: window.bundleID,
            appName: window.appName,
            title: window.title,
            frame: frame,
            displayID: target.display.id,
            displayName: target.display.name,
            state: rule.state,
            zOrder: rule.zOrder,
            needsUnminimize: window.isMinimized && rule.state != .minimized,
            note: notes.isEmpty ? nil : notes.joined(separator: "; ")
        ))
    }

    private static func resolveDisplay(
        _ target: DisplayTarget,
        displays: [DisplayInfo],
        currentDisplayID: String?
    ) -> (DisplayInfo, String?)? {
        guard let main = displays.main else { return nil }
        switch target {
        case .main:
            return (main, nil)
        case .secondary:
            if let secondary = displays.filter({ $0.id != main.id }).min(by: { $0.frame.minX < $1.frame.minX }) {
                return (secondary, nil)
            }
            return (main, "moved to \(main.name) because there's no second display")
        case .display(let id, let name):
            if let match = displays.first(where: { $0.id == id }) { return (match, nil) }
            return (main, "moved to \(main.name) because \(name) isn't connected")
        case .sameAsBefore:
            if let currentDisplayID, let match = displays.first(where: { $0.id == currentDisplayID }) {
                return (match, nil)
            }
            return (main, nil)
        }
    }
}

private enum Resolution {
    case placed(WindowPlacement)
    case skipped(WindowSkip)
}

private extension PlacementPlan {
    mutating func append(_ resolution: Resolution) {
        switch resolution {
        case .placed(let placement): placements.append(placement)
        case .skipped(let skip): skipped.append(skip)
        }
    }
}
