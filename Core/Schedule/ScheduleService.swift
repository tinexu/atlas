import Foundation

/// Plans blocks and keeps time for them (Stage 07).
///
/// It doesn't run anything itself. At the right moments it publishes
/// `schedule.block.starting` (with minutes before), `.started`, `.ended`
/// and `.missed`; what a block *does* lives in a generated Flow workflow
/// whose triggers listen for those events. So a block's time and its
/// automation are separate: an occurrence can be on time while its run
/// failed or was skipped, and the inspector shows both.
///
/// Missed while asleep or with ATLAS closed: depending on the block, it
/// starts on wake if the block hasn't ended, or is marked missed. A start
/// is never published after the block has ended.
public final class ScheduleService: @unchecked Sendable {
    /// How late a start may be and still count as on time.
    public static let onTimeGrace: TimeInterval = 120
    /// Reminder leads always published, so triggers and the Companion can use them.
    public static let standardLeads = [5, 10, 15]

    let store: AtlasStore
    let events: EventBus
    let environment: TriggerEnvironment
    let registry: ActionRegistry
    var calendar: Calendar
    /// Calendar events, as read-only blocks (set by `CalendarService`).
    var externalBlocks: @Sendable (DateInterval) -> [ScheduleBlock] = { _ in [] }
    /// Saves generated workflows (AtlasCore.save, so they're validated and announced).
    var saveWorkflow: @Sendable (Workflow) throws -> Void = { _ in }
    var deleteWorkflow: @Sendable (UUID) throws -> Void = { _ in }

    private let lock = NSLock()
    private var timer: TriggerToken?
    private var wakeToken: TriggerToken?
    private var subscription: EventBus.Subscription?
    private var firedLeads = Set<String>()

    init(store: AtlasStore, events: EventBus, environment: TriggerEnvironment, registry: ActionRegistry, calendar: Calendar = .current) {
        self.store = store
        self.events = events
        self.environment = environment
        self.registry = registry
        self.calendar = calendar
    }

    func start() {
        wakeToken = environment.observeWake { [weak self] in self?.process() }
        subscription = events.subscribe("workflow.finished") { [weak self] event in self?.linkRun(from: event) }
        process()
    }

    func stop() {
        timer?.cancel()
        wakeToken?.cancel()
        if let subscription { events.unsubscribe(subscription) }
    }

    // MARK: - Blocks

    public func blocks() -> [ScheduleBlock] {
        (try? store.blocks()) ?? []
    }

    /// Saves a block and its generated workflow, then re-plans the clock.
    @discardableResult
    public func save(_ block: ScheduleBlock) throws -> ScheduleBlock {
        try RecurrenceExpander.validate(block.recurrence)
        guard block.end > block.start else { throw ScheduleError.endBeforeStart }
        var saved = block
        saved.updatedAt = environment.now()
        if saved.needsAutomation {
            let workflow = ScheduleAutomation.compile(saved, names: names(for: saved))
            saved.automationWorkflowID = workflow.id
            try saveWorkflow(workflow)
        } else if let old = saved.automationWorkflowID {
            try? deleteWorkflow(old)
            saved.automationWorkflowID = nil
        }
        try store.saveBlock(saved)
        changed()
        return saved
    }

    public func delete(_ blockID: UUID) throws {
        if let block = try store.block(id: blockID), let workflowID = block.automationWorkflowID {
            try? deleteWorkflow(workflowID)
        }
        try store.deleteBlock(id: blockID)
        changed()
    }

    /// Moves one block (all its repeats keep the same time of day).
    @discardableResult
    public func move(_ blockID: UUID, by seconds: TimeInterval, resizeOnly: Bool = false) throws -> ScheduleBlock {
        guard var block = try store.block(id: blockID) else { throw ScheduleError.notFound }
        guard !block.isExternal else { throw ScheduleError.readOnly }
        if resizeOnly {
            block.end = max(block.start.addingTimeInterval(5 * 60), block.end.addingTimeInterval(seconds))
        } else {
            block.start = block.start.addingTimeInterval(seconds)
            block.end = block.end.addingTimeInterval(seconds)
        }
        return try save(block)
    }

    public func skip(_ occurrence: Occurrence) throws {
        var record = (try store.occurrence(blockID: occurrence.block.id, start: occurrence.start))
            ?? BlockOccurrence(blockID: occurrence.block.id, start: occurrence.start)
        record.state = .skipped
        record.updatedAt = environment.now()
        try store.saveOccurrence(record)
        changed()
    }

    /// ATLAS blocks plus visible calendar events in a range, sorted.
    public func occurrences(in range: DateInterval) -> [Occurrence] {
        let own = RecurrenceExpander.occurrences(of: blocks(), in: range, calendar: calendar)
        let external = externalBlocks(range).map { Occurrence(block: $0, start: $0.start, end: $0.end) }
        return (own + external).sorted { $0.start < $1.start }
    }

    public func conflicts(in range: DateInterval) -> [ScheduleConflict] {
        ScheduleConflict.find(in: occurrences(in: range).filter { $0.block.kind != .breakTime })
    }

    public func state(of occurrence: Occurrence) -> BlockOccurrence {
        (try? store.occurrence(blockID: occurrence.block.id, start: occurrence.start))
            ?? BlockOccurrence(blockID: occurrence.block.id, start: occurrence.start,
                               state: occurrence.end <= environment.now() ? .completed : occurrence.start <= environment.now() ? .active : .upcoming)
    }

    /// The runs an occurrence caused, newest last.
    public func runs(for occurrence: Occurrence) -> [WorkflowRun] {
        state(of: occurrence).runIDs.compactMap { try? store.run(id: $0) }.sorted { $0.startedAt < $1.startedAt }
    }

    /// Links a run to an occurrence (e.g. the Companion's "Open Study Library?").
    public func link(runID: UUID, blockID: UUID, start: Date) {
        var record = (try? store.occurrence(blockID: blockID, start: start)) ?? BlockOccurrence(blockID: blockID, start: start)
        guard !record.runIDs.contains(runID) else { return }
        record.runIDs.append(runID)
        record.updatedAt = environment.now()
        try? store.saveOccurrence(record)
        events.publish(AtlasEvent(AtlasEvent.Name.scheduleChanged, payload: ["reason": "run"]))
    }

    private func linkRun(from event: AtlasEvent) {
        guard let trigger = event.payload["trigger"]?.stringValue, trigger.hasPrefix(RunTrigger.automatic("schedule.")),
              let runID = event.payload["runId"]?.stringValue.flatMap(UUID.init(uuidString:)),
              let run = try? store.run(id: runID),
              let blockID = run.triggerPayload["blockId"]?.stringValue.flatMap(UUID.init(uuidString:)),
              let start = run.triggerPayload["start"]?.numberValue
        else { return }
        link(runID: runID, blockID: blockID, start: Date(timeIntervalSince1970: start))
    }

    private func changed() {
        events.publish(AtlasEvent(AtlasEvent.Name.scheduleChanged))
        process()
    }

    /// Space, profile and workflow names for a block's generated workflow.
    func names(for block: ScheduleBlock) -> ScheduleAutomation.Names {
        func spaceName(_ id: UUID?) -> String? {
            guard let id else { return nil }
            return (try? store.database.query("SELECT name FROM space WHERE id = ?;", [.from(id)]))?.first?.string("name")
        }
        let profile = block.profileID.flatMap { id in
            (try? store.database.query("SELECT name FROM activation_profile WHERE id = ?;", [.from(id)]))?.first?.string("name")
        }
        return .init(space: spaceName(block.spaceID), profile: profile, endSpace: spaceName(block.endSpaceID))
    }

    // MARK: - Clock

    /// Publishes everything that's due and schedules the next wake-up.
    public func process() {
        let now = environment.now()
        let window = DateInterval(start: now.addingTimeInterval(-36 * 3_600), end: now.addingTimeInterval(36 * 3_600))
        let occurrences = RecurrenceExpander.occurrences(of: blocks(), in: window, calendar: calendar)
        let leads = leadMinutes()
        var next: Date?
        func consider(_ date: Date) { if date > now, date < (next ?? .distantFuture) { next = date } }

        for occurrence in occurrences {
            var record = (try? store.occurrence(blockID: occurrence.block.id, start: occurrence.start))
                ?? BlockOccurrence(blockID: occurrence.block.id, start: occurrence.start)
            let startedState = record.state
            switch record.state {
            case .upcoming:
                if occurrence.start <= now {
                    if now >= occurrence.end {
                        // Ended while the Mac slept or ATLAS was closed: never start it now.
                        record.state = .missed
                        publish(AtlasEvent.Name.blockMissed, occurrence, extra: ["reason": "ended"])
                    } else if now.timeIntervalSince(occurrence.start) <= Self.onTimeGrace || occurrence.block.missedPolicy == .runIfStillInBlock {
                        record.state = .active
                        let late = now.timeIntervalSince(occurrence.start) > Self.onTimeGrace
                        publish(AtlasEvent.Name.blockStarting, occurrence, extra: ["minutesBefore": 0, "late": .bool(late)])
                        publish(AtlasEvent.Name.blockStarted, occurrence, extra: ["late": .bool(late)])
                        consider(occurrence.end)
                    } else {
                        record.state = .missed
                        publish(AtlasEvent.Name.blockMissed, occurrence, extra: ["reason": "asleep"])
                    }
                } else {
                    // Reminders and lead events, only while they're current (not hours late after sleep).
                    for lead in leads where lead > 0 {
                        let at = occurrence.start.addingTimeInterval(-Double(lead) * 60)
                        let key = "\(occurrence.id)|\(lead)"
                        if at <= now, now.timeIntervalSince(at) < Self.onTimeGrace {
                            let first = lock.withLock { firedLeads.insert(key).inserted }
                            if first { publish(AtlasEvent.Name.blockStarting, occurrence, extra: ["minutesBefore": .number(Double(lead))]) }
                        } else {
                            consider(at)
                        }
                    }
                    consider(occurrence.start)
                }
            case .active:
                if occurrence.end <= now {
                    record.state = .completed
                    publish(AtlasEvent.Name.blockEnded, occurrence)
                } else {
                    consider(occurrence.end)
                }
            case .completed, .skipped, .missed:
                break
            }
            if record.state != startedState {
                record.updatedAt = now
                try? store.saveOccurrence(record)
            }
        }
        // Look again at least every few hours, for blocks further out.
        consider(now.addingTimeInterval(6 * 3_600))
        lock.withLock {
            if firedLeads.count > 5_000 { firedLeads.removeAll() }
        }
        timer?.cancel()
        if let next {
            timer = environment.schedule(at: next) { [weak self] in self?.process() }
        }
    }

    /// Lead times in use: the standard ones, block reminders, and any
    /// "Block Starting" trigger's minutes.
    func leadMinutes() -> Set<Int> {
        var leads = Set(Self.standardLeads)
        for block in blocks() { if let reminder = block.reminderMinutes, reminder > 0 { leads.insert(reminder) } }
        for workflow in (try? store.workflows()) ?? [] where workflow.isEnabled {
            for node in workflow.steps where node.kind == .trigger && node.config.triggerType == TriggerCatalog.blockStarting {
                if let minutes = node.parameters["minutesBefore"]?.numberValue, minutes > 0 { leads.insert(Int(minutes)) }
            }
        }
        return leads
    }

    private func publish(_ name: String, _ occurrence: Occurrence, extra: ActionParameters = [:]) {
        var payload: ActionParameters = [
            "blockId": .string(occurrence.block.id.uuidString),
            "title": .string(occurrence.block.title),
            "kind": .string(occurrence.block.kind.rawValue),
            "start": .number(occurrence.start.timeIntervalSince1970),
            "end": .number(occurrence.end.timeIntervalSince1970),
            "spaceId": .string(occurrence.block.spaceID?.uuidString ?? ""),
            "startBehavior": .string(occurrence.block.startBehavior.rawValue),
        ]
        if let space = names(for: occurrence.block).space { payload["spaceName"] = .string(space) }
        payload.merge(extra) { $1 }
        events.publish(AtlasEvent(name, payload: payload))
    }
}

public enum ScheduleError: Error, LocalizedError, Equatable {
    case notFound
    case endBeforeStart
    /// A calendar event on a calendar ATLAS may not write to.
    case readOnly

    public var errorDescription: String? {
        switch self {
        case .notFound: return "That block no longer exists."
        case .endBeforeStart: return "A block has to end after it starts."
        case .readOnly: return "This comes from your calendar, which ATLAS can only read. Turn on writing for that calendar in Time Architect settings to move it here."
        }
    }
}

/// Builds the Flow workflow that carries out a block's start and end
/// behaviour: schedule triggers, then ordinary registered actions.
public enum ScheduleAutomation {
    public struct Names: Sendable {
        public var space: String?
        public var profile: String?
        public var endSpace: String?
        public init(space: String? = nil, profile: String? = nil, endSpace: String? = nil) {
            self.space = space
            self.profile = profile
            self.endSpace = endSpace
        }
    }

    public static func snapshotName(for block: ScheduleBlock) -> String { "Before \(block.title)" }

    public static func compile(_ block: ScheduleBlock, names: Names) -> Workflow {
        var steps: [WorkflowStep] = []
        var connections: [WorkflowConnection] = []
        var row = 0.0
        let blockParameter: ActionParameters = ["block": .string(block.id.uuidString)]

        func chain(trigger: WorkflowStep, _ actions: [WorkflowStep]) {
            guard !actions.isEmpty else { return }
            var previous = trigger
            steps.append(trigger)
            for (index, var action) in actions.enumerated() {
                action.position = NodePosition(x: Double(index + 1) * 300, y: row)
                steps.append(action)
                connections.append(WorkflowConnection(fromNode: previous.id, fromPort: NodePort.controlOut, toNode: action.id))
                previous = action
            }
            row += 160
        }

        if let reminder = block.reminderMinutes, reminder > 0 {
            chain(trigger: .trigger(TriggerCatalog.blockStarting, parameters: blockParameter.merging(["minutesBefore": .number(Double(reminder))]) { $1 },
                                    at: NodePosition(x: 0, y: row)),
                  [WorkflowStep(actionID: ShowNotificationAction.id,
                                parameters: ["title": .string("\(block.title) starts in \(reminder) min"), "body": .string(names.space.map { "In \($0)." } ?? "")],
                                label: "Reminder")])
        }

        var startActions: [WorkflowStep] = []
        if block.endBehavior == .restoreSnapshot {
            startActions.append(WorkflowStep(actionID: "window.snapshot.save", parameters: ["name": .string(snapshotName(for: block))],
                                             label: "Remember windows"))
        }
        switch block.startBehavior {
        case .notify:
            startActions.append(WorkflowStep(actionID: ShowNotificationAction.id,
                                             parameters: ["title": .string("\(block.title) is starting"), "body": .string(names.space.map { "Open \($0) when you're ready." } ?? "")],
                                             label: "Notify"))
        case .activate:
            if let space = names.space {
                var parameters: ActionParameters = ["space": .string(space)]
                if let profile = names.profile { parameters["profile"] = .string(profile) }
                startActions.append(WorkflowStep(actionID: "space.activate", parameters: parameters, label: "Activate \(space)"))
            }
            if let workflowID = block.workflowID {
                startActions.append(.control(.subworkflow, config: NodeConfig(workflowID: workflowID), label: "Run linked workflow"))
            }
        case .nothing, .ask:
            break
        }
        chain(trigger: .trigger(TriggerCatalog.blockStarting, parameters: blockParameter.merging(["minutesBefore": 0]) { $1 },
                                at: NodePosition(x: 0, y: row)), startActions)

        var endActions: [WorkflowStep] = []
        switch block.endBehavior {
        case .notify:
            endActions.append(WorkflowStep(actionID: ShowNotificationAction.id, parameters: ["title": .string("\(block.title) has ended")], label: "Notify"))
        case .restoreSnapshot:
            endActions.append(WorkflowStep(actionID: "window.snapshot.restore", parameters: ["snapshot": .string(snapshotName(for: block))],
                                           label: "Restore windows"))
        case .activateSpace:
            if let space = names.endSpace {
                endActions.append(WorkflowStep(actionID: "space.activate", parameters: ["space": .string(space)], label: "Activate \(space)"))
            }
        case .nothing:
            break
        }
        chain(trigger: .trigger(TriggerCatalog.blockEnded, parameters: blockParameter, at: NodePosition(x: 0, y: row)), endActions)

        return Workflow(
            id: block.automationWorkflowID ?? UUID(),
            name: "Schedule: \(block.title)",
            summary: "Generated from a Time Architect block. Edit the block in Time Architect, which replaces changes made here.",
            isEnabled: true,
            failurePolicy: .continueOnFailure,
            steps: steps,
            connections: connections,
            settings: WorkflowSettings(reentrancy: .runInParallel, minimumInterval: 1, maxRunsPerMinute: 10, selfTriggerLimit: 3)
        )
    }
}
