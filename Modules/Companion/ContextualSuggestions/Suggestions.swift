import AtlasCore
import Foundation

/// A gentle, dismissible offer from the Companion. Every one shown is logged
/// with its reason, so you can always see why it appeared.
public struct Suggestion: Identifiable, Equatable, Sendable {
    public enum Kind: String, CaseIterable, Sendable {
        case workflowFailed, reviewQueue, lowDisk, displayConnected, repetition

        public var title: String {
            switch self {
            case .workflowFailed: return "Explain failed automations"
            case .reviewQueue: return "Files waiting for review"
            case .lowDisk: return "Low disk space"
            case .displayConnected: return "Display connected"
            case .repetition: return "Save repeated app launches as a workflow"
            }
        }
    }

    /// What accepting does. Every option goes through the app's normal paths.
    public enum Action: Equatable, Sendable {
        case openWorkflowAt(workflowID: UUID, nodeID: UUID?)
        case openPermissions
        case openOrbitFolders
        case openReviewQueue
        case openLargestFiles
        case applyLayout(String)
        /// Pre-fills a new workflow launching these apps in order (not saved
        /// until you save it in the editor).
        case draftWorkflow(name: String, bundleIDs: [String])
        case openRunHistory(UUID)
    }

    public let id: UUID
    public let kind: Kind
    public let title: String
    public let detail: String
    /// Why this appeared, in plain words. Logged.
    public let reason: String
    public let actionTitle: String
    public let action: Action

    public init(id: UUID = UUID(), kind: Kind, title: String, detail: String = "", reason: String, actionTitle: String, action: Action) {
        self.id = id
        self.kind = kind
        self.title = title
        self.detail = detail
        self.reason = reason
        self.actionTitle = actionTitle
        self.action = action
    }
}

public struct SuggestionLogEntry: Identifiable, Equatable, Sendable {
    public enum State: String, Sendable { case shown, accepted, dismissed, muted }
    public let id: UUID
    public let kind: Suggestion.Kind
    public let title: String
    public let reason: String
    public let state: State
    public let createdAt: Date
    public let resolvedAt: Date?
}

/// Decides whether a suggestion may be shown: suggestions on, kind not
/// muted, and at most one every 15 minutes.
public struct SuggestionGate: Sendable {
    public static let minimumInterval: TimeInterval = 15 * 60

    public private(set) var lastShown: Date?
    public var muted: Set<String>
    public var enabled: Bool

    public init(lastShown: Date? = nil, muted: Set<String> = [], enabled: Bool = true) {
        self.lastShown = lastShown
        self.muted = muted
        self.enabled = enabled
    }

    public func allows(_ kind: Suggestion.Kind, at now: Date) -> Bool {
        guard enabled, !muted.contains(kind.rawValue) else { return false }
        if let lastShown, now.timeIntervalSince(lastShown) < Self.minimumInterval { return false }
        return true
    }

    /// Records the suggestion as shown if allowed. Returns whether it was.
    public mutating func offer(_ suggestion: Suggestion, at now: Date) -> Bool {
        guard allows(suggestion.kind, at: now) else { return false }
        lastShown = now
        return true
    }

    public mutating func mute(_ kind: Suggestion.Kind) {
        muted.insert(kind.rawValue)
    }
}

/// Turns a failed run into a plain explanation and, where possible, a fix.
public enum FailureExplainer {
    public struct Explanation: Equatable, Sendable {
        public let message: String
        public let fixTitle: String?
        public let fix: Suggestion.Action?
    }

    public static func explain(_ run: WorkflowRun, appName: (String) -> String? = { _ in nil }) -> Explanation {
        let failed = run.steps.first { $0.state == .failed } ?? run.steps.last { $0.state == .partiallySucceeded }
        let error = failed?.error ?? run.error ?? "It stopped without saying why."
        let lower = error.lowercased()
        let stepName = failed?.label ?? "A step"
        let openStep = Suggestion.Action.openWorkflowAt(workflowID: run.workflowID, nodeID: failed?.nodeID)

        if lower.contains("no installed app") || lower.contains("isn't installed") || lower.contains("not installed")
            || lower.contains("couldn't find an app") || lower.contains("unable to find application") {
            // From the step's inputs, or quoted in the message (a Space's activation reports its inner step).
            let quoted = error.range(of: #"“[^”]+”"#, options: .regularExpression).map { String(error[$0].dropFirst().dropLast()) }
            let bundleID = failed?.inputs["bundleId"]?.stringValue ?? quoted
            let name = bundleID.flatMap(appName) ?? bundleID ?? "That app"
            return Explanation(message: "\(name) isn't installed, so “\(stepName)” couldn't open it. Remove that step, or pick an installed app.",
                               fixTitle: "Fix the Step", fix: openStep)
        }
        if lower.contains("accessibility") {
            return Explanation(message: "ATLAS needs Accessibility permission to move windows. Grant it, then run “\(run.workflowName)” again.",
                               fixTitle: "Grant Accessibility", fix: .openPermissions)
        }
        if lower.contains("isn't in orbit") || lower.contains("not in orbit") || lower.contains("add it in orbit") || lower.contains("authorized") {
            return Explanation(message: "“\(stepName)” works on a folder you haven't added to Orbit, so ATLAS won't change files there. Add the folder in Orbit → Folders.",
                               fixTitle: "Add the Folder", fix: .openOrbitFolders)
        }
        if lower.contains("permission") {
            return Explanation(message: "A permission is missing: \(error)", fixTitle: "Open Permissions", fix: .openPermissions)
        }
        if lower.contains("declined") {
            return Explanation(message: "You declined “\(stepName)”, so the rest didn't run.", fixTitle: nil, fix: nil)
        }
        if lower.contains("no such file") || lower.contains("doesn't exist") || lower.contains("couldn't find") || lower.contains("not found") {
            return Explanation(message: "“\(stepName)” couldn't find what it needed: \(error)", fixTitle: "Fix the Step", fix: openStep)
        }
        if lower.contains("didn't finish within") || lower.contains("timed out") {
            return Explanation(message: "“\(stepName)” took too long and was stopped. The app may be slow to open; try a longer timeout on that step.",
                               fixTitle: "Fix the Step", fix: openStep)
        }
        return Explanation(message: "“\(stepName)” failed: \(error)", fixTitle: "Show Details", fix: .openRunHistory(run.id))
    }
}

/// An app the person opened themselves (not one ATLAS launched).
public struct AppLaunch: Equatable, Sendable {
    public let bundleID: String
    public let date: Date
    public init(bundleID: String, date: Date) {
        self.bundleID = bundleID
        self.date = date
    }
}

/// Spec 6.7, basic version: the same 2–4 apps opened in the same order
/// within a few minutes, on 3 or more separate days, is worth offering as a
/// workflow. Only bundle IDs and times are used; nothing is created
/// automatically.
public enum RepetitionDetector {
    public static let sessionGap: TimeInterval = 5 * 60
    public static let requiredDays = 3

    public struct Pattern: Equatable, Sendable {
        public let bundleIDs: [String]
        public let days: Int
    }

    /// The most useful repeated sequence, ignoring ones already covered.
    public static func detect(_ launches: [AppLaunch], calendar: Calendar = .current,
                              excluding known: Set<[String]> = []) -> Pattern? {
        // Bursts of launches with no gap longer than `sessionGap`.
        var sessions: [[AppLaunch]] = []
        for launch in launches.sorted(by: { $0.date < $1.date }) {
            if let last = sessions.last?.last, launch.date.timeIntervalSince(last.date) <= sessionGap {
                sessions[sessions.count - 1].append(launch)
            } else {
                sessions.append([launch])
            }
        }
        // Sequence → the days it happened on.
        var days: [[String]: Set<DateComponents>] = [:]
        for session in sessions {
            var order: [String] = []
            for launch in session where !order.contains(launch.bundleID) { order.append(launch.bundleID) }
            guard order.count >= 2, let day = session.first.map({ calendar.dateComponents([.year, .month, .day], from: $0.date) }) else { continue }
            var seen = Set<[String]>()
            for length in 2...min(4, order.count) {
                for start in 0...(order.count - length) {
                    let sequence = Array(order[start..<(start + length)])
                    if seen.insert(sequence).inserted { days[sequence, default: []].insert(day) }
                }
            }
        }
        let candidates = days.filter { $0.value.count >= requiredDays && !known.contains($0.key) }
        // Longest first, then most days.
        guard let best = candidates.max(by: { ($0.key.count, $0.value.count) < ($1.key.count, $1.value.count) }) else { return nil }
        return Pattern(bundleIDs: best.key, days: best.value.count)
    }

    /// App sequences existing workflows already launch, in order.
    public static func knownSequences(in workflows: [Workflow]) -> Set<[String]> {
        var known = Set<[String]>()
        for workflow in workflows {
            let apps = workflow.steps.filter { $0.actionID == LaunchApplicationAction.id }.compactMap { $0.parameters["bundleId"]?.stringValue }
            guard apps.count >= 2 else { continue }
            for length in 2...min(4, apps.count) {
                for start in 0...(apps.count - length) { known.insert(Array(apps[start..<(start + length)])) }
            }
        }
        return known
    }
}
