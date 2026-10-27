import Foundation

/// A planned stretch of time on the Time Architect timeline (Stage 07).
///
/// The time and what happens at that time are separate: a block can be
/// "on time" while the automation it starts failed or was skipped. What a
/// block *does* is a generated Flow workflow with schedule triggers, so
/// there's no second scheduler engine.
public struct ScheduleBlock: Identifiable, Codable, Hashable, Sendable {
    public enum Kind: String, Codable, CaseIterable, Sendable, Identifiable {
        case focus, task, appointment, breakTime = "break"
        public var id: Self { self }
        public var title: String {
            switch self {
            case .focus: return "Focus Session"
            case .task: return "Task"
            case .appointment: return "Appointment"
            case .breakTime: return "Break"
            }
        }
        public var symbolName: String {
            switch self {
            case .focus: return "scope"
            case .task: return "checklist"
            case .appointment: return "person.2"
            case .breakTime: return "cup.and.saucer"
            }
        }
    }

    public enum StartBehavior: String, Codable, CaseIterable, Sendable, Identifiable {
        case nothing, notify, ask, activate
        public var id: Self { self }
        public var title: String {
            switch self {
            case .nothing: return "Do nothing"
            case .notify: return "Notify me"
            case .ask: return "Ask via the Companion"
            case .activate: return "Activate automatically"
            }
        }
    }

    public enum EndBehavior: String, Codable, CaseIterable, Sendable, Identifiable {
        case nothing, notify, restoreSnapshot, activateSpace
        public var id: Self { self }
        public var title: String {
            switch self {
            case .nothing: return "Nothing"
            case .notify: return "Notify me"
            case .restoreSnapshot: return "Restore my windows from before"
            case .activateSpace: return "Activate another Space"
            }
        }
    }

    /// What to do when the Mac was asleep or ATLAS wasn't running at the start.
    public enum MissedPolicy: String, Codable, CaseIterable, Sendable, Identifiable {
        case runIfStillInBlock, markMissed
        public var id: Self { self }
        public var title: String {
            self == .runIfStillInBlock ? "Start on wake if the block hasn't ended" : "Mark it missed"
        }
    }

    public enum Source: String, Codable, Sendable {
        case atlas, calendar
    }

    public var id: UUID
    public var title: String
    public var start: Date
    public var end: Date
    public var kind: Kind
    /// "#RRGGBB"; nil uses the Space's or project's colour.
    public var color: String?
    public var spaceID: UUID?
    public var profileID: UUID?
    /// A workflow to run when the block starts (with "Activate automatically").
    public var workflowID: UUID?
    public var projectID: UUID?
    public var recurrence: Recurrence
    /// Minutes before the start to remind you; nil for no reminder.
    public var reminderMinutes: Int?
    public var startBehavior: StartBehavior
    public var endBehavior: EndBehavior
    /// For `.activateSpace` at the end.
    public var endSpaceID: UUID?
    public var missedPolicy: MissedPolicy
    public var source: Source
    public var externalEventID: String?
    public var calendarID: String?
    /// The generated workflow that carries out the start/end behaviour.
    public var automationWorkflowID: UUID?
    public var notes: String
    public var createdAt: Date
    public var updatedAt: Date

    public init(id: UUID = UUID(), title: String, start: Date, end: Date, kind: Kind = .focus, color: String? = nil,
                spaceID: UUID? = nil, profileID: UUID? = nil, workflowID: UUID? = nil, projectID: UUID? = nil,
                recurrence: Recurrence = .none, reminderMinutes: Int? = nil, startBehavior: StartBehavior = .nothing,
                endBehavior: EndBehavior = .nothing, endSpaceID: UUID? = nil, missedPolicy: MissedPolicy = .runIfStillInBlock,
                source: Source = .atlas, externalEventID: String? = nil, calendarID: String? = nil,
                automationWorkflowID: UUID? = nil, notes: String = "", createdAt: Date = Date(), updatedAt: Date = Date()) {
        self.id = id
        self.title = title
        self.start = start
        self.end = max(end, start.addingTimeInterval(60))
        self.kind = kind
        self.color = color
        self.spaceID = spaceID
        self.profileID = profileID
        self.workflowID = workflowID
        self.projectID = projectID
        self.recurrence = recurrence
        self.reminderMinutes = reminderMinutes
        self.startBehavior = startBehavior
        self.endBehavior = endBehavior
        self.endSpaceID = endSpaceID
        self.missedPolicy = missedPolicy
        self.source = source
        self.externalEventID = externalEventID
        self.calendarID = calendarID
        self.automationWorkflowID = automationWorkflowID
        self.notes = notes
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public var duration: TimeInterval { end.timeIntervalSince(start) }

    /// Whether anything happens automatically, so it needs a generated workflow.
    public var needsAutomation: Bool {
        reminderMinutes != nil || startBehavior == .notify || startBehavior == .activate || endBehavior != .nothing
    }

    /// Calendar events are read-only on the timeline unless writing is on.
    public var isExternal: Bool { source == .calendar }
}

/// How a block repeats. Custom rules use a subset of iCalendar RRULE:
/// FREQ=DAILY|WEEKLY|MONTHLY, INTERVAL, BYDAY, COUNT, UNTIL.
public enum Recurrence: Hashable, Sendable, Codable {
    case none, daily, weekdays, weekly
    case custom(String)

    public var rawValue: String {
        switch self {
        case .none: return "none"
        case .daily: return "daily"
        case .weekdays: return "weekdays"
        case .weekly: return "weekly"
        case .custom(let rule): return rule
        }
    }

    public init(rawValue: String) {
        switch rawValue.lowercased() {
        case "none", "": self = .none
        case "daily": self = .daily
        case "weekdays": self = .weekdays
        case "weekly": self = .weekly
        default: self = .custom(rawValue)
        }
    }

    public init(from decoder: Decoder) throws {
        self.init(rawValue: try decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public var title: String {
        switch self {
        case .none: return "Doesn't repeat"
        case .daily: return "Every day"
        case .weekdays: return "Every weekday"
        case .weekly: return "Every week"
        case .custom(let rule): return RRule(rule)?.summary ?? rule
        }
    }

    public var isRepeating: Bool { self != .none }
}

/// One time a block happens.
public struct Occurrence: Identifiable, Hashable, Sendable {
    public let block: ScheduleBlock
    public let start: Date
    public let end: Date

    public init(block: ScheduleBlock, start: Date, end: Date) {
        self.block = block
        self.start = start
        self.end = end
    }

    public var id: String { "\(block.id.uuidString)|\(Int(start.timeIntervalSince1970))" }

    public func overlaps(_ other: Occurrence) -> Bool {
        start < other.end && other.start < end
    }
}

/// What happened to one occurrence, kept so a restart doesn't repeat it.
public struct BlockOccurrence: Hashable, Sendable {
    public enum State: String, Codable, Sendable, CaseIterable {
        case upcoming, active, completed, skipped, missed
        public var title: String { rawValue.capitalized }
    }

    public var blockID: UUID
    public var start: Date
    public var state: State
    /// Runs this occurrence caused (its generated workflow, a Companion accept…).
    public var runIDs: [UUID]
    public var updatedAt: Date

    public init(blockID: UUID, start: Date, state: State = .upcoming, runIDs: [UUID] = [], updatedAt: Date = Date()) {
        self.blockID = blockID
        self.start = start
        self.state = state
        self.runIDs = runIDs
        self.updatedAt = updatedAt
    }
}

/// A timed stretch of focus, planned or ad hoc.
public struct FocusSession: Identifiable, Hashable, Sendable {
    public struct Pause: Codable, Hashable, Sendable {
        public var start: Date
        public var end: Date?
        public init(start: Date, end: Date? = nil) {
            self.start = start
            self.end = end
        }
    }

    public enum State: String, Codable, Sendable { case running, paused, ended }

    public var id: UUID
    public var blockID: UUID?
    public var title: String
    public var plannedSeconds: TimeInterval
    /// Added with "Extend".
    public var extendedSeconds: TimeInterval
    public var startedAt: Date
    public var endedAt: Date?
    public var pauses: [Pause]
    public var spaceID: UUID?
    public var state: State

    public init(id: UUID = UUID(), blockID: UUID? = nil, title: String = "Focus", plannedSeconds: TimeInterval,
                extendedSeconds: TimeInterval = 0, startedAt: Date, endedAt: Date? = nil, pauses: [Pause] = [],
                spaceID: UUID? = nil, state: State = .running) {
        self.id = id
        self.blockID = blockID
        self.title = title
        self.plannedSeconds = plannedSeconds
        self.extendedSeconds = extendedSeconds
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.pauses = pauses
        self.spaceID = spaceID
        self.state = state
    }

    public var totalSeconds: TimeInterval { plannedSeconds + extendedSeconds }

    public func pausedSeconds(at now: Date) -> TimeInterval {
        pauses.reduce(0) { $0 + (($1.end ?? now).timeIntervalSince($1.start)) }
    }

    /// Focused time so far, not counting pauses.
    public func elapsed(at now: Date) -> TimeInterval {
        max(0, (endedAt ?? now).timeIntervalSince(startedAt) - pausedSeconds(at: endedAt ?? now))
    }

    public func remaining(at now: Date) -> TimeInterval {
        max(0, totalSeconds - elapsed(at: now))
    }

    /// When it ends if it isn't paused again.
    public func endsAt(from now: Date) -> Date {
        now.addingTimeInterval(remaining(at: now))
    }
}

/// Overlapping blocks, with a fix.
public struct ScheduleConflict: Identifiable, Hashable, Sendable {
    public let first: Occurrence
    public let second: Occurrence
    public var id: String { first.id + "~" + second.id }

    /// Move the later-starting one to begin when the other ends.
    public var suggestion: String {
        let later = first.start <= second.start ? second : first
        let earlier = later == second ? first : second
        return "Move “\(later.block.title)” to \(earlier.end.formatted(date: .omitted, time: .shortened))"
    }

    public var movable: (occurrence: Occurrence, newStart: Date) {
        let later = first.start <= second.start ? second : first
        let earlier = later == second ? first : second
        return (later, earlier.end)
    }

    public static func find(in occurrences: [Occurrence]) -> [ScheduleConflict] {
        let sorted = occurrences.sorted { $0.start < $1.start }
        var conflicts: [ScheduleConflict] = []
        for (index, a) in sorted.enumerated() {
            for b in sorted[(index + 1)...] {
                if b.start >= a.end { break }
                if a.block.id != b.block.id, a.overlaps(b) { conflicts.append(ScheduleConflict(first: a, second: b)) }
            }
        }
        return conflicts
    }
}

extension AtlasEvent.Name {
    /// Payload: blockId, title, start, end (seconds since 1970), minutesBefore, kind, spaceId.
    public static let blockStarting = "schedule.block.starting"
    public static let blockStarted = "schedule.block.started"
    public static let blockEnded = "schedule.block.ended"
    public static let blockMissed = "schedule.block.missed"
    /// Blocks were added, edited or removed.
    public static let scheduleChanged = "schedule.changed"
    /// Payload: sessionId, title, seconds, endsAt, spaceId, blockId.
    public static let focusStarted = "focus.started"
    public static let focusPaused = "focus.paused"
    public static let focusResumed = "focus.resumed"
    public static let focusExtended = "focus.extended"
    /// Payload: sessionId, title, elapsed, planned, completed (bool).
    public static let focusEnded = "focus.ended"
    /// Payload: eventId, title, calendar, start, minutesBefore.
    public static let calendarEventApproaching = "calendar.event.approaching"
    public static let calendarChanged = "calendar.changed"
    /// Payload: recommendationId, kind, title, reason.
    public static let recommendationShown = "recommendation.shown"
    public static let recommendationAccepted = "recommendation.accepted"
    public static let recommendationDismissed = "recommendation.dismissed"
    /// Payload: workflowId, source (ai / rules / template), prompt.
    public static let workflowGenerated = "workflow.generated"
}
