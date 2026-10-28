import Foundation

/// An app lockdown keeps available. `bundleID` may be
/// `LockdownApp.claudeToken`, resolved when lockdown starts.
public struct LockdownApp: Codable, Hashable, Sendable, Identifiable {
    public var name: String
    public var bundleID: String
    public var id: String { bundleID }

    public init(name: String, bundleID: String) {
        self.name = name
        self.bundleID = bundleID
    }

    /// "Claude": the desktop app if it's installed, otherwise a Safari web
    /// app for claude.ai in ~/Applications (File → Add to Dock in Safari).
    public static let claudeToken = "atlas.lockdown.claude"
    public static let claudeDesktopBundleID = "com.anthropic.claudefordesktop"
    public static let claude = LockdownApp(name: "Claude", bundleID: claudeToken)
}

/// Pomodoro rhythm during a lockdown.
public struct PomodoroSettings: Codable, Equatable, Sendable {
    public var focusMinutes = 25
    public var shortBreakMinutes = 5
    public var longBreakMinutes = 15
    /// Every nth break is the long one.
    public var longBreakEvery = 4
    public var playsSounds = true
    /// Breaks normally keep other apps locked; this lets them out.
    public var unlockDuringBreaks = false

    public init() {}
}

/// A page lockdown opens, in a given browser (which is then allowed).
public struct LockdownLink: Codable, Hashable, Sendable, Identifiable {
    public var url: String
    public var browserBundleID: String
    public var browserName: String
    public var id: String { url + "|" + browserBundleID }

    public init(url: String, browserBundleID: String, browserName: String) {
        self.url = url
        self.browserBundleID = browserBundleID
        self.browserName = browserName
    }

    /// "leetcode.com"
    public var host: String { URL(string: url)?.host ?? url }
}

/// One way of locking in, e.g. "Vibe coding" or "LeetCode": the apps that
/// stay available and the pages that open.
public struct LockdownMode: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public var symbolName: String
    public var apps: [LockdownApp]
    public var links: [LockdownLink]

    public init(id: UUID = UUID(), name: String, symbolName: String = "lock", apps: [LockdownApp] = [], links: [LockdownLink] = []) {
        self.id = id
        self.name = name
        self.symbolName = symbolName
        self.apps = apps
        self.links = links
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Lockdown"
        symbolName = try c.decodeIfPresent(String.self, forKey: .symbolName) ?? "lock"
        apps = try c.decodeIfPresent([LockdownApp].self, forKey: .apps) ?? []
        links = try c.decodeIfPresent([LockdownLink].self, forKey: .links) ?? []
    }

    /// "Cursor, Obsidian +3 · leetcode.com"
    public var summary: String {
        var parts: [String] = []
        let names = apps.map(\.name)
        if !names.isEmpty {
            parts.append(names.count > 3 ? names.prefix(2).joined(separator: ", ") + " +\(names.count - 2)" : names.joined(separator: ", "))
        }
        parts += links.map(\.host)
        return parts.isEmpty ? "Only ATLAS and system apps" : parts.joined(separator: " · ")
    }
}

/// Lockdown settings for one activation profile (stored as a preference
/// keyed by the profile, so any Space can use lockdown).
public struct LockdownSettings: Codable, Equatable, Sendable {
    public var isEnabled = false
    public var defaultMinutes = 120
    /// The last choice in the "Lock in" prompt: minutes, or 0 for "No
    /// lockdown". Nil until the prompt is first used.
    public var lastChoiceMinutes: Int?
    /// Ways of locking in, offered in the prompt. The first is the default.
    public var modes: [LockdownMode] = []
    public var lastModeID: UUID?
    public var pomodoro = PomodoroSettings()
    /// Seconds before "Remove time" or "End lockdown" can be confirmed.
    public var exitCountdownSeconds = 10
    public var requiresPhrase = false
    public var phrase = "I'm done for now"
    /// Shortcuts to turn Do Not Disturb on and off; macOS doesn't let apps
    /// set a Focus directly, but a Shortcut can.
    public var shortcutOnStart: String?
    public var shortcutOnEnd: String?
    /// A workflow to run after lockdown ends.
    public var afterWorkflowID: UUID?

    public init() {}

    /// The mode with `id`, else the last one used, else the first.
    public func mode(id: UUID?) -> LockdownMode? {
        modes.first { $0.id == id } ?? modes.first { $0.id == lastModeID } ?? modes.first
    }

    private enum LegacyKeys: String, CodingKey { case apps }

    /// Every field is optional when reading, so settings saved by an older
    /// version still load; a single saved app list becomes one mode.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = LockdownSettings()
        isEnabled = try c.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? defaults.isEnabled
        defaultMinutes = try c.decodeIfPresent(Int.self, forKey: .defaultMinutes) ?? defaults.defaultMinutes
        lastChoiceMinutes = try c.decodeIfPresent(Int.self, forKey: .lastChoiceMinutes)
        modes = try c.decodeIfPresent([LockdownMode].self, forKey: .modes) ?? []
        lastModeID = try c.decodeIfPresent(UUID.self, forKey: .lastModeID)
        pomodoro = try c.decodeIfPresent(PomodoroSettings.self, forKey: .pomodoro) ?? defaults.pomodoro
        exitCountdownSeconds = try c.decodeIfPresent(Int.self, forKey: .exitCountdownSeconds) ?? defaults.exitCountdownSeconds
        requiresPhrase = try c.decodeIfPresent(Bool.self, forKey: .requiresPhrase) ?? defaults.requiresPhrase
        phrase = try c.decodeIfPresent(String.self, forKey: .phrase) ?? defaults.phrase
        shortcutOnStart = try c.decodeIfPresent(String.self, forKey: .shortcutOnStart)
        shortcutOnEnd = try c.decodeIfPresent(String.self, forKey: .shortcutOnEnd)
        afterWorkflowID = try c.decodeIfPresent(UUID.self, forKey: .afterWorkflowID)
        if modes.isEmpty, let apps = try decoder.container(keyedBy: LegacyKeys.self).decodeIfPresent([LockdownApp].self, forKey: .apps),
           !apps.isEmpty {
            modes = [LockdownMode(name: "Lockdown", apps: apps)]
        }
    }

    public static let vibeCoding = LockdownMode(
        name: "Vibe coding", symbolName: "sparkles",
        apps: [
            LockdownApp(name: "Cursor", bundleID: "com.todesktop.230313mzl4w4u92"),
            LockdownApp(name: "Obsidian", bundleID: "md.obsidian"),
            LockdownApp(name: "Spotify", bundleID: "com.spotify.client"),
            LockdownApp(name: "Terminal", bundleID: "com.apple.Terminal"),
            .claude,
        ]
    )

    public static let leetCode = LockdownMode(
        name: "LeetCode", symbolName: "brain.head.profile",
        apps: [
            LockdownApp(name: "IDLE", bundleID: "org.python.IDLE"),
            LockdownApp(name: "Spotify", bundleID: "com.spotify.client"),
        ],
        links: [LockdownLink(url: "https://leetcode.com/problemset/", browserBundleID: "com.google.Chrome", browserName: "Google Chrome")]
    )

    /// The Coding Lab's defaults: vibe coding or LeetCode, two-hour sessions.
    public static var codingLab: LockdownSettings {
        var settings = LockdownSettings()
        settings.isEnabled = true
        settings.modes = [vibeCoding, leetCode]
        return settings
    }
}

/// System apps lockdown never quits, hides or blocks, so the Mac always
/// stays usable: settings, search, the Dock and menu bar, the lock screen
/// and every password prompt. The one list, shown in settings.
public enum LockdownEssentials {
    public static let apps: [LockdownApp] = [
        LockdownApp(name: "Finder", bundleID: "com.apple.finder"),
        LockdownApp(name: "System Settings", bundleID: "com.apple.systempreferences"),
        LockdownApp(name: "Spotlight", bundleID: "com.apple.Spotlight"),
        LockdownApp(name: "Activity Monitor", bundleID: "com.apple.ActivityMonitor"),
        LockdownApp(name: "Login window", bundleID: "com.apple.loginwindow"),
        LockdownApp(name: "Dock", bundleID: "com.apple.dock"),
        LockdownApp(name: "Control Center", bundleID: "com.apple.controlcenter"),
        LockdownApp(name: "Notification Center", bundleID: "com.apple.notificationcenterui"),
        LockdownApp(name: "SystemUIServer", bundleID: "com.apple.systemuiserver"),
        LockdownApp(name: "Screen saver", bundleID: "com.apple.ScreenSaver.Engine"),
        LockdownApp(name: "Password prompts (SecurityAgent)", bundleID: "com.apple.SecurityAgent"),
        LockdownApp(name: "Touch ID & password prompts (coreautha)", bundleID: "com.apple.LocalAuthentication.UIAgent"),
    ]

    /// Essentials that are tidied away (hidden) at the start, but never
    /// quit or hidden again, so clicking the desktop still works.
    public static let hiddenAtStart: Set<String> = ["com.apple.finder"]

    public static func contains(_ bundleID: String) -> Bool {
        apps.contains { $0.bundleID == bundleID } || bundleID.hasPrefix("com.apple.systempreferences")
            || bundleID.hasPrefix("com.apple.dock.")
    }
}

/// A lockdown in progress, saved so it survives a crash or relaunch.
public struct LockdownSession: Codable, Equatable, Sendable, Identifiable {
    public struct Phase: Codable, Equatable, Sendable {
        public enum Kind: String, Codable, Sendable { case focus, shortBreak, longBreak }
        public var kind: Kind
        /// Focus phases completed so far.
        public var completedFocus: Int
        /// The focus-timer session running this phase; nil while stopped.
        public var sessionID: UUID?

        public var isBreak: Bool { kind != .focus }
        public var title: String {
            switch kind {
            case .focus: return "Focus"
            case .shortBreak: return "Short break"
            case .longBreak: return "Long break"
            }
        }
    }

    public var id: UUID
    public var spaceID: UUID
    public var spaceName: String
    public var profileID: UUID
    public var startedAt: Date
    public var endsAt: Date
    /// Bundle IDs allowed besides ATLAS and the essentials.
    public var allowed: [String]
    /// Allowed apps that weren't installed, by name.
    public var skipped: [String]
    /// Apps hidden when lockdown started (to bring back afterwards).
    public var hiddenAtStart: [String]
    /// Bundle ID → blocked attempts.
    public var blocked: [String: Int]
    public var names: [String: String]
    public var settings: LockdownSettings
    /// The mode chosen when it started, e.g. "LeetCode".
    public var modeName: String?
    public var phase: Phase
    public var runID: UUID

    public func remaining(at now: Date) -> TimeInterval { max(0, endsAt.timeIntervalSince(now)) }

    /// Whether blocked apps are being kept out right now.
    public var isEnforcing: Bool { !(phase.isBreak && settings.pomodoro.unlockDuringBreaks) }

    public func name(of bundleID: String) -> String { names[bundleID] ?? bundleID }
}

/// What a finished lockdown did, for the notification and the panel.
public struct LockdownSummary: Codable, Equatable, Sendable {
    public enum Reason: String, Codable, Sendable { case timer, early, quit, expiredWhileClosed }
    public var spaceName: String
    public var focusedSeconds: TimeInterval
    public var blocked: [(name: String, count: Int)] {
        blockedCounts.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }.map { ($0.key, $0.value) }
    }
    /// App name → attempts.
    public var blockedCounts: [String: Int]
    public var skipped: [String]
    public var hiddenAtStart: [String]
    public var reason: Reason
    public var endedAt: Date

    public var totalBlocked: Int { blockedCounts.values.reduce(0, +) }

    /// "Lockdown complete — 2 h focused, blocked 7 attempts (Safari ×5, Messages ×2)."
    public var headline: String {
        let focused = LockdownFormat.duration(focusedSeconds)
        var text = reason == .early ? "Lockdown ended early — \(focused) focused" : "Lockdown complete — \(focused) focused"
        if totalBlocked > 0 {
            let detail = blocked.map { "\($0.name) ×\($0.count)" }.joined(separator: ", ")
            text += ", blocked \(totalBlocked) attempt\(totalBlocked == 1 ? "" : "s") (\(detail))"
        } else {
            text += ", nothing blocked"
        }
        if !skipped.isEmpty { text += ". Not installed: \(skipped.joined(separator: ", "))" }
        return text + "."
    }
}

public enum LockdownFormat {
    /// "2 h", "1 h 30 min", "52 min".
    public static func duration(_ seconds: TimeInterval) -> String {
        let minutes = Int((seconds / 60).rounded())
        let hours = minutes / 60, rest = minutes % 60
        if hours == 0 { return "\(minutes) min" }
        return rest == 0 ? "\(hours) h" : "\(hours) h \(rest) min"
    }
}

/// Decides what lockdown does with an app. Pure, so it's easy to test.
public enum LockdownPolicy {
    public enum Verdict: Equatable, Sendable { case allowed, essential, blocked }

    public static func verdict(for bundleID: String, allowed: [String], ownBundleID: String?) -> Verdict {
        if bundleID == ownBundleID { return .allowed }
        if LockdownEssentials.contains(bundleID) { return .essential }
        return allowed.contains(bundleID) ? .allowed : .blocked
    }
}

extension AtlasEvent.Name {
    /// Payload: sessionId, spaceName, endsAt (seconds since 1970).
    public static let lockdownStarted = "lockdown.started"
    /// Time or phase changed. Payload: endsAt, phase.
    public static let lockdownChanged = "lockdown.changed"
    /// A pomodoro phase began. Payload: phase, minutes.
    public static let lockdownPhase = "lockdown.phase"
    /// A blocked app was kept out. Payload: bundleId, name, count, toast (message, empty when throttled).
    public static let lockdownBlocked = "lockdown.blocked"
    /// Something lockdown wants to say. Payload: message.
    public static let lockdownNotice = "lockdown.notice"
    /// Payload: headline, reason.
    public static let lockdownEnded = "lockdown.ended"
}

/// The friction before removing time or ending lockdown early: a countdown
/// before the button works, and optionally a typed phrase. A decision,
/// not an accident.
public struct LockdownExitGate: Equatable, Sendable {
    public let openedAt: Date
    public let countdownSeconds: Int
    /// Must be typed exactly (ignoring case and surrounding spaces); nil if not required.
    public let phrase: String?

    public init(openedAt: Date, settings: LockdownSettings) {
        self.openedAt = openedAt
        countdownSeconds = max(0, settings.exitCountdownSeconds)
        phrase = settings.requiresPhrase ? settings.phrase : nil
    }

    public func secondsLeft(at now: Date) -> Int {
        max(0, Int(ceil(Double(countdownSeconds) - now.timeIntervalSince(openedAt))))
    }

    public func phraseMatches(_ typed: String) -> Bool {
        guard let phrase else { return true }
        return typed.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare(phrase) == .orderedSame
    }

    public func canConfirm(at now: Date, typed: String) -> Bool {
        secondsLeft(at: now) == 0 && phraseMatches(typed)
    }
}
