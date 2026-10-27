import Foundation

/// Plain-language answers to "Explain this workflow" and "Why did this run
/// fail?", built from the graph and the run record. No AI needed.
public enum WorkflowExplainer {
    public static func explain(_ workflow: Workflow, registry: ActionRegistry) -> String {
        var lines: [String] = []
        let triggers = workflow.steps.filter { $0.kind == .trigger }
        if triggers.isEmpty {
            lines.append("“\(workflow.name)” runs when you start it: from its Run button, the menu bar, the Companion or a room object.")
        } else {
            let whens = triggers.map { describeTrigger($0) }
            lines.append("“\(workflow.name)” starts on its own \(whens.joined(separator: ", or "))." + (workflow.isEnabled ? "" : " It's turned off, so right now it only runs when you start it."))
        }

        // Walk the control flow from each trigger (or the start for a plain list).
        let order = workflow.connections.isEmpty ? workflow.steps.filter { $0.kind != .trigger } : walk(workflow)
        var number = 1
        var steps: [String] = []
        for node in order where node.isEnabled {
            switch node.kind {
            case .trigger:
                continue
            case .condition:
                let group = node.config.condition ?? ConditionGroup()
                let checks = group.items.map { ($0.negated ? "not " : "") + $0.check.summary }
                steps.append("\(number). It checks that \(checks.joined(separator: group.match == .all ? " and " : " or ")); if not, it stops there.")
            case .action:
                let descriptor = registry.descriptor(for: node.actionID)
                steps.append("\(number). \(registry.displayLabel(for: node))" + (descriptor?.confirmationRequired == true ? " (asks you first)" : "") + ".")
            case .control:
                switch node.config.control {
                case .subworkflow: steps.append("\(number). It runs another workflow\(node.label.map { ": \($0)" } ?? "").")
                case .delay: steps.append("\(number). It waits\(node.parameters["seconds"].map { " \($0.displayString) seconds" } ?? "").")
                default: steps.append("\(number). \(node.config.control?.title ?? "Control step")\(node.label.map { ": \($0)" } ?? "").")
                }
            }
            number += 1
        }
        if steps.isEmpty {
            lines.append("It has no steps yet.")
        } else {
            lines.append("Then:\n" + steps.joined(separator: "\n"))
        }
        let disabled = workflow.steps.filter { !$0.isEnabled && $0.kind != .trigger }.count
        if disabled > 0 { lines.append("\(disabled) step\(disabled == 1 ? " is" : "s are") turned off and skipped.") }
        lines.append(workflow.failurePolicy == .stopOnFailure ? "If a step fails, it stops there." : "If a step fails, it carries on with the rest.")
        let permissions = Set(workflow.steps.compactMap { registry.descriptor(for: $0.actionID) }.flatMap(\.permissions))
        if !permissions.isEmpty { lines.append("It uses \(permissions.map(\.title).sorted().joined(separator: ", ")) permission.") }
        return lines.joined(separator: "\n\n")
    }

    static func describeTrigger(_ node: WorkflowStep) -> String {
        guard let type = node.config.triggerType.flatMap(TriggerCatalog.type(id:)) else { return "when its trigger fires" }
        let settings = type.parameters.compactMap { spec -> String? in
            guard let value = node.parameters[spec.key], !value.isEmpty else { return nil }
            return "\(spec.label.lowercased()) \(value.displayString)"
        }
        let base = type.summary.prefix(1).lowercased() + type.summary.dropFirst().dropLast(type.summary.hasSuffix(".") ? 1 : 0)
        return base + (settings.isEmpty ? "" : " (\(settings.joined(separator: ", ")))")
    }

    /// Nodes in the order a run would usually visit them.
    static func walk(_ workflow: Workflow) -> [WorkflowStep] {
        let byID = Dictionary(workflow.steps.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var seen = Set<UUID>()
        var order: [WorkflowStep] = []
        var queue = workflow.steps.filter { $0.kind == .trigger }.map(\.id)
        if queue.isEmpty, let first = workflow.steps.first { queue = [first.id] }
        while !queue.isEmpty {
            let id = queue.removeFirst()
            guard seen.insert(id).inserted, let node = byID[id] else { continue }
            order.append(node)
            let next = workflow.connections.filter { $0.fromNode == id && $0.toPort == NodePort.controlIn }
                .sorted { $0.fromPort == "false" && $1.fromPort != "false" ? false : true }
            queue.append(contentsOf: next.map(\.toNode))
        }
        return order
    }

    public static func explainFailure(_ run: WorkflowRun, workflow: Workflow?) -> String {
        let when = run.startedAt.formatted(date: .abbreviated, time: .shortened)
        let trigger = run.trigger.hasPrefix(RunTrigger.automaticPrefix)
            ? "on its own (\(TriggerCatalog.type(id: String(run.trigger.dropFirst(RunTrigger.automaticPrefix.count)))?.title ?? run.trigger))"
            : "when you started it"
        guard run.state == .failed || run.state == .partiallySucceeded || run.state == .skipped || run.state == .canceled else {
            return "This run of “\(run.workflowName)” didn't fail: it \(run.state == .succeeded ? "finished successfully" : "is \(run.state.rawValue)")."
        }
        if run.state == .skipped {
            return "“\(run.workflowName)” didn't run \(when): \(run.error ?? "automations were paused or it was turned off")."
        }
        if run.state == .canceled { return "“\(run.workflowName)” was stopped \(when) before it finished." }
        let worked = run.steps.filter { $0.state == .succeeded && $0.kind == .action }
        guard let failed = run.steps.first(where: { $0.state == .failed }) ?? run.steps.first(where: { $0.state == .partiallySucceeded }) else {
            return "“\(run.workflowName)” failed \(when): \(run.error ?? "no step reported why")."
        }
        var text = "“\(run.workflowName)” ran \(trigger) on \(when). "
        if !worked.isEmpty { text += "\(worked.count) step\(worked.count == 1 ? "" : "s") worked (\(worked.map { "“\($0.label)”" }.joined(separator: ", "))). " }
        text += "It \(failed.state == .partiallySucceeded ? "only partly finished" : "stopped") at “\(failed.label)”: \(failed.error ?? "no reason given")"
        text += "\n\n" + hint(for: failed.error ?? "")
        if let workflow, workflow.failurePolicy == .continueOnFailure { text += "\n\nIt's set to carry on after failures, so later steps still ran." }
        return text
    }

    static func hint(for error: String) -> String {
        let lower = error.lowercased()
        if lower.contains("no installed app") || lower.contains("isn't installed") { return "What to do: install the app, or open the workflow and pick an app that's installed." }
        if lower.contains("accessibility") { return "What to do: grant Accessibility on the Permissions screen, then run it again." }
        if lower.contains("orbit") { return "What to do: add that folder in Orbit → Folders so ATLAS may change files there." }
        if lower.contains("declined") { return "You declined that step when ATLAS asked, so nothing after it ran." }
        if lower.contains("didn't finish within") { return "What to do: the step took too long. Give it a longer timeout in the inspector, or check the app isn't stuck." }
        if lower.contains("no window layout") || lower.contains("no space") || lower.contains("doesn't exist") || lower.contains("no snapshot") {
            return "What to do: something it refers to was renamed or deleted. Open the workflow and choose it again."
        }
        if lower.contains("paused") { return "Automations were paused at the time." }
        return "What to do: open the run in Run History to see each step's inputs, then fix that step in the editor."
    }
}

/// The "Today" summary (spec 8), from the schedule, runs, Orbit and health.
public struct DailyOverview: Sendable {
    public var date: Date
    public var upcoming: [Occurrence]
    public var past: [Occurrence]
    public var plannedFocus: TimeInterval
    public var completedFocus: TimeInterval
    public var runsToday: Int
    public var failures: [WorkflowRun]
    public var reviewCount: Int
    public var healthWarnings: [String]

    public static func make(store: AtlasStore, schedule: ScheduleService?, events: EventBus, now: Date = Date(), calendar: Calendar = .current) -> DailyOverview {
        let start = calendar.startOfDay(for: now)
        let end = calendar.date(byAdding: .day, value: 1, to: start) ?? now.addingTimeInterval(86_400)
        let occurrences = schedule?.occurrences(in: DateInterval(start: start, end: end)) ?? []
        let planned = occurrences.filter { $0.block.kind == .focus }.reduce(0) { $0 + $1.end.timeIntervalSince($1.start) }
        let sessions = (try? store.focusSessions(since: start)) ?? []
        let done = sessions.reduce(0) { $0 + $1.elapsed(at: now) }
        let runs = ((try? store.runs(matching: RunQuery(from: start), limit: 500)) ?? []).filter { !$0.trigger.hasPrefix("space.") }
        let failures = runs.filter { $0.state == .failed || $0.state == .partiallySucceeded }
        let warnings = events.recentEvents.filter { $0.name == "health.threshold" && $0.timestamp >= start }
            .compactMap { $0.payload["message"]?.stringValue }
        return DailyOverview(date: now, upcoming: occurrences.filter { $0.end > now }, past: occurrences.filter { $0.end <= now },
                             plannedFocus: planned, completedFocus: done, runsToday: runs.count, failures: failures,
                             reviewCount: (try? store.reviewItems(state: .pending).count) ?? 0,
                             healthWarnings: Array(Set(warnings)).sorted())
    }

    /// For the morning notification.
    public var text: String {
        var parts: [String] = []
        if let next = upcoming.first {
            parts.append("\(upcoming.count) block\(upcoming.count == 1 ? "" : "s") today, first “\(next.block.title)” at \(next.start.formatted(date: .omitted, time: .shortened)).")
        } else {
            parts.append("Nothing planned on your timeline today.")
        }
        if plannedFocus > 0 { parts.append("\(Int(plannedFocus / 60)) min of focus planned.") }
        if !failures.isEmpty { parts.append("\(failures.count) automation\(failures.count == 1 ? "" : "s") need attention.") }
        if reviewCount > 0 { parts.append("\(reviewCount) file\(reviewCount == 1 ? "" : "s") waiting for review.") }
        if !healthWarnings.isEmpty { parts.append(healthWarnings.first!) }
        return parts.joined(separator: " ")
    }
}

/// `atlas.dailySummary`: posts the Today summary as a notification. Used by
/// the built-in "Morning Summary" workflow, which you can edit.
public struct DailySummaryAction: AtlasAction {
    public static let id: ActionID = "atlas.dailySummary"
    final class Ref: @unchecked Sendable { weak var core: AtlasCore? }
    let ref = Ref()

    public let descriptor = ActionDescriptor(
        id: DailySummaryAction.id,
        title: "Show Today's Summary",
        summary: "Posts a notification with today's blocks, focus time, automations needing attention and files waiting for review.",
        category: "Feedback",
        symbolName: "sun.max",
        permissions: [.notifications],
        sideEffects: [.showsNotification],
        isIdempotent: false,
        defaultTimeout: 10,
        outputs: [OutputSpec(key: "summary", label: "Summary", type: .string)]
    )

    init(core: AtlasCore) { ref.core = core }

    public func perform(_ parameters: ActionParameters, context: ActionContext) async throws -> ActionOutput {
        guard let core = ref.core else { throw ActionError.failed("ATLAS isn't ready yet.") }
        let overview = DailyOverview.make(store: core.store, schedule: core.time?.schedule, events: core.events)
        try await context.system.postNotification(title: "Today", body: overview.text)
        return ActionOutput("Posted today's summary", values: ["summary": .string(overview.text)])
    }
}
