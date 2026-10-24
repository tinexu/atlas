import CoreGraphics
import Foundation

/// A rectangle as fractions (0–1) of a display's visible frame, top-left
/// origin, so a layout works at any resolution.
public struct FractionalRect: Codable, Hashable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public static let full = FractionalRect(x: 0, y: 0, width: 1, height: 1)

    /// Keeps the rect inside 0…1 with a sensible minimum size.
    public var clamped: FractionalRect {
        let w = min(max(width, 0.05), 1)
        let h = min(max(height, 0.05), 1)
        return FractionalRect(x: min(max(x, 0), 1 - w), y: min(max(y, 0), 1 - h), width: w, height: h)
    }

    /// Absolute rect inside `visibleFrame`, rounded to whole points.
    public func absolute(in visibleFrame: CGRect) -> CGRect {
        CGRect(
            x: (visibleFrame.minX + x * visibleFrame.width).rounded(),
            y: (visibleFrame.minY + y * visibleFrame.height).rounded(),
            width: (width * visibleFrame.width).rounded(),
            height: (height * visibleFrame.height).rounded()
        )
    }

    /// The fractions `rect` occupies of `visibleFrame`.
    public init(_ rect: CGRect, in visibleFrame: CGRect) {
        let w = max(visibleFrame.width, 1), h = max(visibleFrame.height, 1)
        self.init(
            x: Double((rect.minX - visibleFrame.minX) / w),
            y: Double((rect.minY - visibleFrame.minY) / h),
            width: Double(rect.width / w),
            height: Double(rect.height / h)
        )
    }

    /// Sum of edge differences, used to find the nearest preset.
    public func distance(to other: FractionalRect) -> Double {
        abs(x - other.x) + abs(y - other.y)
            + abs((x + width) - (other.x + other.width)) + abs((y + height) - (other.y + other.height))
    }
}

/// Positions that need no setup.
public enum WindowPreset: String, Codable, CaseIterable, Sendable, Identifiable {
    case leftHalf, rightHalf
    case leftThird, centerThird, rightThird
    case leftTwoThirds, rightTwoThirds
    case centered
    case full

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .leftHalf: return "Left half"
        case .rightHalf: return "Right half"
        case .leftThird: return "Left third"
        case .centerThird: return "Center third"
        case .rightThird: return "Right third"
        case .leftTwoThirds: return "Left two-thirds"
        case .rightTwoThirds: return "Right two-thirds"
        case .centered: return "Centered"
        case .full: return "Full screen area"
        }
    }

    public var rect: FractionalRect {
        let third = 1.0 / 3
        switch self {
        case .leftHalf: return FractionalRect(x: 0, y: 0, width: 0.5, height: 1)
        case .rightHalf: return FractionalRect(x: 0.5, y: 0, width: 0.5, height: 1)
        case .leftThird: return FractionalRect(x: 0, y: 0, width: third, height: 1)
        case .centerThird: return FractionalRect(x: third, y: 0, width: third, height: 1)
        case .rightThird: return FractionalRect(x: 2 * third, y: 0, width: third, height: 1)
        case .leftTwoThirds: return FractionalRect(x: 0, y: 0, width: 2 * third, height: 1)
        case .rightTwoThirds: return FractionalRect(x: third, y: 0, width: 2 * third, height: 1)
        case .centered: return FractionalRect(x: 0.15, y: 0.1, width: 0.7, height: 0.8)
        case .full: return .full
        }
    }

    /// The preset whose rect is within `tolerance` of `rect`, if any.
    public static func matching(_ rect: FractionalRect, tolerance: Double = 0.02) -> WindowPreset? {
        allCases.first { $0.rect.distance(to: rect) <= tolerance }
    }

    /// Accepts the raw value or the title, ignoring case and spaces, so a
    /// shortcut can say "right half".
    public init?(loose text: String) {
        let key = text.lowercased().filter { $0.isLetter }
        guard let match = Self.allCases.first(where: {
            $0.rawValue.lowercased() == key || $0.title.lowercased().filter(\.isLetter) == key
        }) else { return nil }
        self = match
    }
}

/// How a rule picks out one of an app's windows by title.
public enum TitleMatch: Codable, Hashable, Sendable {
    case contains(String)
    case regex(String)

    public var pattern: String {
        switch self {
        case .contains(let text), .regex(let text): return text
        }
    }

    public func matches(_ title: String) -> Bool {
        switch self {
        case .contains(let text):
            let needle = text.trimmingCharacters(in: .whitespaces)
            return needle.isEmpty || title.localizedCaseInsensitiveContains(needle)
        case .regex(let pattern):
            return title.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
        }
    }

    /// Nil if the pattern is fine, otherwise why not.
    public var validationError: String? {
        guard case .regex(let pattern) = self else { return nil }
        do {
            _ = try NSRegularExpression(pattern: pattern)
            return nil
        } catch {
            return "“\(pattern)” isn't a valid regular expression."
        }
    }
}

/// Which display a rule puts its window on.
public enum DisplayTarget: Codable, Hashable, Sendable {
    /// The display with the menu bar.
    case main
    /// The first display that isn't the main one (leftmost first).
    case secondary
    /// A specific display by its stable ID.
    case display(id: String, name: String)
    /// Whichever display the window is on now.
    case sameAsBefore

    public var title: String {
        switch self {
        case .main: return "Main display"
        case .secondary: return "Secondary display"
        case .display(_, let name): return name
        case .sameAsBefore: return "Same as before"
        }
    }
}

public enum WindowState: String, Codable, CaseIterable, Sendable {
    case normal
    case minimized
    /// Hides the whole app (windows can't be hidden one by one).
    case hidden

    public var title: String {
        switch self {
        case .normal: return "Normal"
        case .minimized: return "Minimized"
        case .hidden: return "Hidden (whole app)"
        }
    }
}

/// Where one app window goes.
public struct WindowRule: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var bundleID: String
    /// Display name remembered for when the app isn't installed.
    public var appName: String
    public var titleMatch: TitleMatch?
    public var display: DisplayTarget
    public var frame: FractionalRect
    public var state: WindowState
    /// 0 is frontmost.
    public var zOrder: Int

    public init(
        id: UUID = UUID(),
        bundleID: String,
        appName: String = "",
        titleMatch: TitleMatch? = nil,
        display: DisplayTarget = .main,
        frame: FractionalRect,
        state: WindowState = .normal,
        zOrder: Int = 0
    ) {
        self.id = id
        self.bundleID = bundleID
        self.appName = appName
        self.titleMatch = titleMatch
        self.display = display
        self.frame = frame
        self.state = state
        self.zOrder = zOrder
    }

    public init(bundleID: String, appName: String = "", preset: WindowPreset, display: DisplayTarget = .main, zOrder: Int = 0) {
        self.init(bundleID: bundleID, appName: appName, display: display, frame: preset.rect, zOrder: zOrder)
    }

    public var displayName: String { appName.isEmpty ? bundleID : appName }
}

/// A set of displays, used to tell "laptop only" from "laptop + external".
public struct DisplayProfile: Codable, Hashable, Sendable, Identifiable {
    public struct Display: Codable, Hashable, Sendable {
        public var id: String
        public var name: String
        public var width: Double
        public var height: Double
        /// Position in the arrangement (top-left, points).
        public var x: Double
        public var y: Double
        public var isMain: Bool

        public init(id: String, name: String, width: Double, height: Double, x: Double, y: Double, isMain: Bool) {
            self.id = id
            self.name = name
            self.width = width
            self.height = height
            self.x = x
            self.y = y
            self.isMain = isMain
        }
    }

    /// Derived from the displays' stable IDs, so the same set of displays
    /// always has the same profile ID.
    public var id: String
    public var name: String
    public var displays: [Display]

    public init(id: String, name: String, displays: [Display]) {
        self.id = id
        self.name = name
        self.displays = displays
    }

    public init(displays: [DisplayInfo]) {
        let ordered = displays.sorted { ($0.isMain ? 0 : 1, $0.frame.minX) < ($1.isMain ? 0 : 1, $1.frame.minX) }
        self.init(
            id: ordered.map(\.id).sorted().joined(separator: "+"),
            name: ordered.isEmpty ? "No displays" : ordered.map(\.name).joined(separator: " + "),
            displays: ordered.map {
                Display(id: $0.id, name: $0.name, width: Double($0.frame.width), height: Double($0.frame.height),
                        x: Double($0.frame.minX), y: Double($0.frame.minY), isMain: $0.isMain)
            }
        )
    }

    public func matches(_ displays: [DisplayInfo]) -> Bool {
        DisplayProfile(displays: displays).id == id
    }
}

/// A named arrangement of windows, e.g. "Programming".
public struct WindowLayout: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var rules: [WindowRule]
    /// The displays it was captured or designed on, for reference.
    public var displayProfile: DisplayProfile?
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        name: String,
        rules: [WindowRule] = [],
        displayProfile: DisplayProfile? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.rules = rules
        self.displayProfile = displayProfile
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// Apps this layout places, in rule order, without duplicates.
    public var bundleIDs: [String] {
        var seen = Set<String>()
        return rules.map(\.bundleID).filter { seen.insert($0).inserted }
    }
}

/// Every window as it was at one moment, so it can be put back later.
/// Restores positions and reopens apps; it can't bring back unsaved
/// content inside apps.
public struct SessionSnapshot: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var createdAt: Date
    /// The Space that was active, if any.
    public var spaceID: UUID?
    /// Saved automatically when leaving a Space, rather than by hand.
    public var isAutomatic: Bool
    public var runningApps: [String]
    public var rules: [WindowRule]
    public var displayProfile: DisplayProfile?

    public init(
        id: UUID = UUID(),
        name: String,
        createdAt: Date = Date(),
        spaceID: UUID? = nil,
        isAutomatic: Bool = false,
        runningApps: [String] = [],
        rules: [WindowRule] = [],
        displayProfile: DisplayProfile? = nil
    ) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.spaceID = spaceID
        self.isAutomatic = isAutomatic
        self.runningApps = runningApps
        self.rules = rules
        self.displayProfile = displayProfile
    }

    public var asLayout: WindowLayout {
        WindowLayout(id: id, name: name, rules: rules, displayProfile: displayProfile, createdAt: createdAt, updatedAt: createdAt)
    }
}
