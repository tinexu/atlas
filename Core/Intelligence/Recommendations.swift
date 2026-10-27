import Foundation

/// Read-only view of Spaces from Core (the Spaces module owns them).
public struct SpaceDirectory: Sendable {
    public struct Entry: Hashable, Sendable {
        public let id: UUID
        public let name: String
        public let templateID: String
    }

    let store: AtlasStore
    public init(store: AtlasStore) { self.store = store }

    public var all: [Entry] {
        ((try? store.database.query("SELECT id, name, template_id FROM space ORDER BY slot;")) ?? []).compactMap { row in
            guard let id = row.uuid("id"), let name = row.string("name") else { return nil }
            return Entry(id: id, name: name, templateID: row.string("template_id") ?? "")
        }
    }

    public func entry(_ id: UUID?) -> Entry? {
        guard let id else { return nil }
        return all.first { $0.id == id }
    }

    public var activeID: UUID? { (try? store.preference("spaces.activeSpaceID", as: UUID.self)) ?? nil }
    public var active: Entry? { entry(activeID) }

    /// A Space meant for meetings: a Meeting Room template, or "meeting" in the name.
    public var meetingSpace: Entry? {
        all.first { $0.templateID == "meeting-room" } ?? all.first { $0.name.localizedCaseInsensitiveContains("meeting") }
    }
}

/// A suggestion from the recommendation engine: what, why, how sure, and
/// one action. Nothing happens until the person accepts it.
public struct Recommendation: Identifiable, Hashable, Sendable {
    public enum Kind: String, Codable, CaseIterable, Sendable {
        case blockStarting, meetingSoon, calendarLink, repeatedFailure, extendFocus, scheduleRepeated

        public var title: String {
            switch self {
            case .blockStarting: return "Open a block's Space as it starts"
            case .meetingSoon: return "Switch to your meeting setup"
            case .calendarLink: return "Prepare for linked calendar events"
            case .repeatedFailure: return "Fix automations that keep failing"
            case .extendFocus: return "Adjust focus session lengths"
            case .scheduleRepeated: return "Schedule things you run by hand"
            }
        }

        /// Time-critical: shown even soon after another suggestion.
        var isTimely: Bool { self == .blockStarting || self == .meetingSoon || self == .calendarLink }
    }

    public enum Action: Codable, Hashable, Sendable {
        case activateSpace(name: String, profile: String?, blockID: UUID?, occurrenceStart: Date?)
        /// Save the current windows, then activate the meeting Space (nil: just save).
        case saveLayoutAndSwitch(snapshotName: String, spaceName: String?)
        case disableOrFix(workflowID: UUID, nodeID: UUID?)
        case setFocusDefault(spaceID: UUID?, minutes: Int)
        case scheduleWorkflow(workflowID: UUID, name: String, hour: Int, minute: Int)

        public var title: String {
            switch self {
            case .activateSpace(let name, _, _, _): return "Open \(name)"
            case .saveLayoutAndSwitch(_, let space): return space.map { "Save & Open \($0)" } ?? "Save Layout"
            case .disableOrFix: return "Fix It"
            case .setFocusDefault(_, let minutes): return "Make It \(minutes) min"
            case .scheduleWorkflow: return "Schedule It"
            }
        }
    }

    public let id: UUID
    public let kind: Kind
    public let title: String
    public let detail: String
    /// Why this appeared, in plain words ("Why am I seeing this?").
    public let reason: String
    /// 0…1, how sure the rule is.
    public let confidence: Double
    public let action: Action
    /// Same subject + kind isn't suggested again for a day after a dismissal.
    public let subject: String

    public init(id: UUID = UUID(), kind: Kind, title: String, detail: String = "", reason: String, confidence: Double, action: Action, subject: String) {
        self.id = id
        self.kind = kind
        self.title = title
        self.detail = detail
        self.reason = reason
        self.confidence = confidence
        self.action = action
        self.subject = subject
    }
}

public struct RecommendationLogEntry: Identifiable, Hashable, Sendable {
    public enum State: String, Sendable { case shown, accepted, dismissed, muted }
    public let id: UUID
    public let kind: Recommendation.Kind
    public let title: String
    public let reason: String
    public let confidence: Double
    public let state: State
    public let createdAt: Date
    public let resolvedAt: Date?
}

/// Which signals the engine may use. Mirrors the Companion's context
/// switches (Stage 06), so turning a source off there turns it off here.
public struct RecommendationSources: Equatable, Sendable {
    public var schedule = true
    public var activeSpace = true
    public var runs = true
    public var health = true
    public var reviews = true
    public var displays = true
    public init() {}
}

/// Per-kind tuning from how suggestions were answered. Local only.
public struct RecommendationTuning: Codable, Equatable, Sendable {
    public var scores: [String: Double] = [:]
    public var muted: Set<String> = []
    /// "kind|subject" → when it was dismissed.
    public var dismissedSubjects: [String: Date] = [:]
    public var enabled = true

    public init() {}

    public static let threshold = 0.4

    public func score(_ kind: Recommendation.Kind) -> Double { scores[kind.rawValue] ?? 1 }

    public mutating func accepted(_ kind: Recommendation.Kind) {
        scores[kind.rawValue] = min(1.5, score(kind) + 0.2)
    }

    public mutating func dismissed(_ recommendation: Recommendation, at date: Date) {
        scores[recommendation.kind.rawValue] = max(0, score(recommendation.kind) - 0.25)
        dismissedSubjects["\(recommendation.kind.rawValue)|\(recommendation.subject)"] = date
    }

    /// Whether a recommendation clears muting, scoring and recent dismissals.
    public func allows(_ recommendation: Recommendation, at date: Date) -> Bool {
        guard enabled, !muted.contains(recommendation.kind.rawValue) else { return false }
        if let when = dismissedSubjects["\(recommendation.kind.rawValue)|\(recommendation.subject)"], date.timeIntervalSince(when) < 86_400 { return false }
        return recommendation.confidence * score(recommendation.kind) >= Self.threshold
    }
}

/// Collects signals from the event bus and the store and turns them into
/// at most one recommendation at a time (spec 6):
/// - a block with a Space starts in 5 minutes → "Open Study Library?"
/// - a calendar event in 10 minutes while in another Space → save the
///   layout and switch to the meeting Space
/// - a calendar event matching a link rule → open its Space beforehand
/// - the same workflow failed 3 times in a row → turn it off or fix it
/// - focus sessions keep getting extended → change the default length
/// - a workflow run by hand at the same time on several days → schedule it
public final class RecommendationEngine: @unchecked Sendable {
    public static let tuningKey = "recommendations.tuning"
    public static let minimumInterval: TimeInterval = 10 * 60

    let store: AtlasStore
    let events: EventBus
    let now: @Sendable () -> Date
    let spaces: SpaceDirectory
    private let lock = NSLock()
    private var current: Recommendation?
    private var lastShown: Date?
    public var sources = RecommendationSources()
    /// Called with a recommendation to show (the Companion shows it).
    public var onRecommendation: (@Sendable (Recommendation) -> Void)?
    /// Carries out accepted actions (set by AtlasCore; UI-only actions return false).
    var perform: (@Sendable (Recommendation) async -> RecommendationOutcome)?

    init(store: AtlasStore, events: EventBus, now: @escaping @Sendable () -> Date) {
        self.store = store
        self.events = events
        self.now = now
        spaces = SpaceDirectory(store: store)
    }

    public var tuning: RecommendationTuning {
        get { (try? store.preference(Self.tuningKey, as: RecommendationTuning.self)) ?? RecommendationTuning() }
        set { try? store.setPreference(newValue, for: Self.tuningKey) }
    }

    public var pending: Recommendation? { lock.withLock { current } }

    // MARK: - Signals

    public func handle(_ event: AtlasEvent) {
        guard let recommendation = evaluate(event) else { return }
        offer(recommendation)
    }

    /// The rule that matches an event, if any (no rate limiting here).
    public func evaluate(_ event: AtlasEvent) -> Recommendation? {
        let p = event.payload
        switch event.name {
        case AtlasEvent.Name.blockStarting where sources.schedule:
            guard p["minutesBefore"]?.numberValue == 5, let spaceName = p["spaceName"]?.stringValue, !spaceName.isEmpty,
                  p["startBehavior"]?.stringValue != ScheduleBlock.StartBehavior.activate.rawValue,
                  let blockID = p["blockId"]?.stringValue.flatMap(UUID.init(uuidString:))
            else { return nil }
            if sources.activeSpace, let active = spaces.active, active.name == spaceName { return nil }
            let title = p["title"]?.stringValue ?? "Your block"
            let start = p["start"]?.numberValue.map(Date.init(timeIntervalSince1970:))
            let ask = p["startBehavior"]?.stringValue == ScheduleBlock.StartBehavior.ask.rawValue
            return Recommendation(kind: .blockStarting, title: "Open \(spaceName)?", detail: "“\(title)” starts in 5 minutes.",
                                  reason: "“\(title)” is on your timeline\(start.map { " at \($0.formatted(date: .omitted, time: .shortened))" } ?? "") and is linked to \(spaceName)\(ask ? ", and you asked to be asked when it starts" : "").",
                                  confidence: ask ? 0.95 : 0.8,
                                  action: .activateSpace(name: spaceName, profile: nil, blockID: blockID, occurrenceStart: start),
                                  subject: "\(blockID)|\(Int(start?.timeIntervalSince1970 ?? 0))")

        case AtlasEvent.Name.calendarEventApproaching where sources.schedule:
            let title = p["title"]?.stringValue ?? "An event"
            let minutes = Int(p["minutesBefore"]?.numberValue ?? 0)
            let eventID = p["eventId"]?.stringValue ?? title
            // A link rule for this event, at its own lead time.
            if let linked = p["linkedSpaceId"]?.stringValue.flatMap(UUID.init(uuidString:)), minutes == Int(p["linkMinutes"]?.numberValue ?? -1),
               let space = spaces.entry(linked) {
                if sources.activeSpace, spaces.activeID == space.id { return nil }
                return Recommendation(kind: .calendarLink, title: "Open \(space.name) for “\(title)”?", detail: "It starts in \(minutes) minutes.",
                                      reason: "A calendar link says events like “\(title)” go with \(space.name), \(minutes) minutes before.",
                                      confidence: 0.9, action: .activateSpace(name: space.name, profile: nil, blockID: nil, occurrenceStart: nil),
                                      subject: eventID)
            }
            guard minutes == 10, sources.activeSpace, let active = spaces.active else { return nil }
            let meeting = spaces.meetingSpace
            if let meeting, meeting.id == active.id { return nil }
            let snapshot = "\(active.name) before \(title)"
            return Recommendation(
                kind: .meetingSoon,
                title: meeting.map { "Save your \(active.name) layout and switch to \($0.name)?" } ?? "Save your \(active.name) layout?",
                detail: "“\(title)” starts in 10 minutes.\(meeting == nil ? " Add a Meeting Room Space to switch to it too." : "")",
                reason: "You're in \(active.name) and “\(title)” is on your calendar in 10 minutes. Saving the layout lets you come back to it afterwards.",
                confidence: meeting == nil ? 0.6 : 0.85,
                action: .saveLayoutAndSwitch(snapshotName: snapshot, spaceName: meeting?.name),
                subject: eventID
            )

        case AtlasEvent.Name.workflowFinished where sources.runs:
            guard let workflowID = p["workflowId"]?.stringValue.flatMap(UUID.init(uuidString:)) else { return nil }
            let state = p["state"]?.stringValue
            if state == RunState.failed.rawValue { return repeatedFailure(workflowID) }
            if state == RunState.succeeded.rawValue, let trigger = p["trigger"]?.stringValue, RunTrigger.isExplicit(trigger) || trigger == "menu-bar" || trigger == "shortcut" {
                return repeatedByHand(workflowID)
            }
            return nil

        case AtlasEvent.Name.focusEnded:
            return extendedFocus(spaceID: p["spaceId"]?.stringValue.flatMap(UUID.init(uuidString:)))

        default:
            return nil
        }
    }

    func repeatedFailure(_ workflowID: UUID) -> Recommendation? {
        let runs = ((try? store.runs(workflowID: workflowID, limit: 3)) ?? [])
        guard runs.count == 3, runs.allSatisfy({ $0.state == .failed }), let latest = runs.first else { return nil }
        let failed = latest.steps.first { $0.state == .failed }
        let cause = failed?.error.map { " The last error: \($0)" } ?? ""
        return Recommendation(kind: .repeatedFailure, title: "“\(latest.workflowName)” failed 3 times in a row",
                              detail: "Turn it off, or fix \(failed.map { "“\($0.label)”" } ?? "it")?",
                              reason: "Its last three runs all failed.\(cause)", confidence: 0.9,
                              action: .disableOrFix(workflowID: workflowID, nodeID: failed?.nodeID), subject: workflowID.uuidString)
    }

    /// The same workflow run by hand at about the same time on 3+ days in two weeks.
    func repeatedByHand(_ workflowID: UUID) -> Recommendation? {
        guard let workflow = try? store.workflow(id: workflowID),
              !workflow.steps.contains(where: { $0.kind == .trigger && $0.config.triggerType == TriggerCatalog.timeReached })
        else { return nil }
        let since = now().addingTimeInterval(-14 * 86_400)
        let manual = ((try? store.runs(workflowID: workflowID, limit: 60)) ?? [])
            .filter { $0.startedAt >= since && (RunTrigger.isExplicit($0.trigger) || $0.trigger == "menu-bar" || $0.trigger == "shortcut") }
        let calendar = Calendar.current
        let minutes = manual.map { calendar.component(.hour, from: $0.startedAt) * 60 + calendar.component(.minute, from: $0.startedAt) }
        guard let latest = minutes.first else { return nil }
        let close = zip(manual, minutes).filter { abs($0.1 - latest) <= 30 }
        let days = Set(close.map { calendar.startOfDay(for: $0.0.startedAt) })
        guard days.count >= 3 else { return nil }
        let average = close.map(\.1).reduce(0, +) / close.count
        let rounded = (average + 7) / 15 * 15
        let hour = rounded / 60 % 24, minute = rounded % 60
        let time = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: now())?.formatted(date: .omitted, time: .shortened) ?? ""
        return Recommendation(kind: .scheduleRepeated, title: "Schedule “\(workflow.name)” at \(time) every day?",
                              detail: "You've run it by hand around then on \(days.count) days.",
                              reason: "In the last two weeks you started “\(workflow.name)” yourself around \(time) on \(days.count) different days.",
                              confidence: min(0.9, 0.5 + Double(days.count) * 0.1),
                              action: .scheduleWorkflow(workflowID: workflowID, name: workflow.name, hour: hour, minute: minute),
                              subject: workflowID.uuidString)
    }

    /// 3 of the last 4 sessions (in the same Space) were extended.
    func extendedFocus(spaceID: UUID?) -> Recommendation? {
        let sessions = ((try? store.focusSessions(since: now().addingTimeInterval(-30 * 86_400))) ?? [])
            .filter { $0.state == .ended && $0.spaceID == spaceID }.prefix(4)
        guard sessions.count >= 3 else { return nil }
        let extended = sessions.filter { $0.extendedSeconds > 0 }
        guard extended.count >= 3 else { return nil }
        let average = extended.map(\.totalSeconds).reduce(0, +) / Double(extended.count) / 60
        let minutes = max(15, Int((average / 15).rounded()) * 15)
        let name = spaces.entry(spaceID)?.name ?? "Focus sessions"
        let planned = Int((sessions.first?.plannedSeconds ?? 0) / 60)
        guard minutes != planned else { return nil }
        return Recommendation(kind: .extendFocus, title: "Make \(name) \(minutes) minutes by default?",
                              detail: "You extended \(extended.count) of your last \(sessions.count) sessions.",
                              reason: "You extended \(extended.count) of your last \(sessions.count) focus sessions\(spaceID == nil ? "" : " in \(name)"), to about \(minutes) minutes on average.",
                              confidence: 0.75, action: .setFocusDefault(spaceID: spaceID, minutes: minutes),
                              subject: spaceID?.uuidString ?? "default")
    }

    // MARK: - Showing and answering

    /// Shows a recommendation if nothing else is showing, the rate limit
    /// allows it, and tuning doesn't suppress it. Returns whether it showed.
    @discardableResult
    public func offer(_ recommendation: Recommendation) -> Bool {
        let date = now()
        let tuning = self.tuning
        guard tuning.allows(recommendation, at: date) else { return false }
        let allowed = lock.withLock { () -> Bool in
            if let current, date.timeIntervalSince(lastShown ?? .distantPast) < 5 * 60, current.id != recommendation.id { return false }
            if !recommendation.kind.isTimely, let lastShown, date.timeIntervalSince(lastShown) < Self.minimumInterval { return false }
            current = recommendation
            lastShown = date
            return true
        }
        guard allowed else { return false }
        try? store.logRecommendation(recommendation, at: date)
        events.publish(AtlasEvent(AtlasEvent.Name.recommendationShown, payload: payload(recommendation)))
        onRecommendation?(recommendation)
        return true
    }

    /// Carries out the action through the engine.
    @discardableResult
    public func accept(_ recommendation: Recommendation) async -> RecommendationOutcome {
        resolve(recommendation, state: .accepted)
        var tuning = self.tuning
        tuning.accepted(recommendation.kind)
        self.tuning = tuning
        events.publish(AtlasEvent(AtlasEvent.Name.recommendationAccepted, payload: payload(recommendation)))
        return await perform?(recommendation) ?? .needsUI(recommendation.action)
    }

    /// "Not now" (`forever` false) or "Don't suggest this" (true).
    public func dismiss(_ recommendation: Recommendation, forever: Bool) {
        resolve(recommendation, state: forever ? .muted : .dismissed)
        var tuning = self.tuning
        tuning.dismissed(recommendation, at: now())
        if forever { tuning.muted.insert(recommendation.kind.rawValue) }
        self.tuning = tuning
        events.publish(AtlasEvent(AtlasEvent.Name.recommendationDismissed,
                                  payload: payload(recommendation).merging(["forever": .bool(forever)]) { $1 }))
    }

    private func resolve(_ recommendation: Recommendation, state: RecommendationLogEntry.State) {
        lock.withLock { if current?.id == recommendation.id { current = nil } }
        try? store.resolveRecommendation(id: recommendation.id, state: state, at: now())
    }

    private func payload(_ recommendation: Recommendation) -> ActionParameters {
        ["recommendationId": .string(recommendation.id.uuidString), "kind": .string(recommendation.kind.rawValue),
         "title": .string(recommendation.title), "reason": .string(recommendation.reason),
         "confidence": .number(recommendation.confidence)]
    }
}

public enum RecommendationOutcome: Sendable, Equatable {
    case ran(WorkflowRun)
    case done(String)
    /// Something the app has to show (e.g. open the workflow to fix it).
    case needsUI(Recommendation.Action)
    case failed(String)
}
