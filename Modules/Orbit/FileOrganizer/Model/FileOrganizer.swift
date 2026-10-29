import AtlasCore
import Foundation

/// What a dry run says a rule would do to one existing file.
public struct DryRunItem: Identifiable, Hashable, Sendable {
    public var id: String { path }
    public let path: String
    public let outcome: String
    public let destination: String?
    public let needsReview: Bool
}

/// Organization rules (spec 5). Each rule is compiled into a Flow workflow
/// — File Created trigger(s) → condition → Organize File — so it appears
/// in the Automation Galaxy and Run History, and runs through the engine.
public final class FileOrganizer: @unchecked Sendable {
    private let core: AtlasCore
    private let lock = NSLock()
    private var sweepTimer: DispatchSourceTimer?
    private static let lastSweepKey = "orbit.rules.lastSweep"

    /// Trigger name for the daily check of rules about file age.
    public static let sweepTrigger = RunTrigger.automatic("orbit.sweep")
    public static let reviewTrigger = "review"

    public init(core: AtlasCore) {
        self.core = core
    }

    public func rules() -> [FileRule] {
        (try? core.store.rules()) ?? []
    }

    // MARK: - Editing

    /// Saves the rule and regenerates its workflow. A rule with problems is
    /// saved switched off.
    @discardableResult
    public func save(_ rule: FileRule) throws -> FileRule {
        var rule = rule
        rule.updatedAt = Date()
        if rule.action == .trash { rule.mode = .askFirst }
        if !rule.problems.isEmpty { rule.isEnabled = false }
        let workflow = try core.save(Self.compile(rule))
        rule.workflowID = workflow.id
        try core.store.saveRule(rule)
        return rule
    }

    public func setEnabled(_ enabled: Bool, for rule: FileRule) throws {
        var copy = rule
        copy.isEnabled = enabled
        try save(copy)
    }

    public func delete(_ rule: FileRule) throws {
        if let id = rule.workflowID, (try? core.store.workflow(id: id)) != nil {
            try core.delete(workflowID: id)
        }
        try core.store.deleteRule(id: rule.id)
    }

    /// The rule as a workflow. Its ID is kept across saves, so Run History
    /// stays attached to it.
    public static func compile(_ rule: FileRule) -> Workflow {
        let folders = rule.folders.isEmpty ? ["~/Downloads"] : rule.folders
        var steps: [WorkflowStep] = []
        var connections: [WorkflowConnection] = []
        let condition = WorkflowStep.condition(rule.conditionGroup, label: "Matches", at: NodePosition(x: 320, y: 0))
        let organize = WorkflowStep(
            actionID: OrganizeFileAction.id,
            parameters: ["ruleId": .string(rule.id.uuidString), "path": "{{trigger.path}}"],
            position: NodePosition(x: 620, y: 0),
            label: "Organize"
        )
        for (index, folder) in folders.enumerated() {
            let trigger = WorkflowStep.trigger(TriggerCatalog.fileCreated, parameters: ["folder": .string(folder)],
                                               at: NodePosition(x: 0, y: Double(index) * 160 - Double(folders.count - 1) * 80))
            steps.append(trigger)
            connections.append(WorkflowConnection(fromNode: trigger.id, fromPort: NodePort.controlOut, toNode: condition.id))
        }
        steps += [condition, organize]
        connections.append(WorkflowConnection(fromNode: condition.id, fromPort: "true", toNode: organize.id))
        return Workflow(
            id: rule.workflowID ?? UUID(),
            name: "Rule: \(rule.name)",
            summary: "\(rule.summary). Generated from an Orbit rule: edit it in Orbit → Rules, which replaces changes made here.",
            isEnabled: rule.isEnabled,
            failurePolicy: .stopOnFailure,
            steps: steps,
            connections: connections,
            settings: WorkflowSettings(reentrancy: .runInParallel, minimumInterval: 1, maxRunsPerMinute: 60, selfTriggerLimit: 3)
        )
    }

    // MARK: - Starter rules

    public static func starterRules() -> [FileRule] {
        [
            FileRule(
                name: "Screenshots into a folder",
                folders: ["~/Desktop", "~/Downloads"],
                conditions: [.nameMatches(pattern: "^(Screenshot|Screen Shot|Screen Recording) "),
                             .extensions("png, jpg, jpeg, heic, mov")],
                action: .moveTo(folder: "{folder}/Screenshots"),
                starterID: "screenshots"
            ),
            FileRule(
                name: "Old installers to the Trash",
                mode: .askFirst,
                folders: ["~/Downloads"],
                conditions: [.extensions("dmg, pkg"), .olderThan(days: 30, field: .created)],
                action: .trash,
                starterID: "installers"
            ),
            FileRule(
                name: "Course PDFs into course folders",
                folders: ["~/Downloads"],
                conditions: [.extensions("pdf"), .nameMatches(pattern: "\\b[A-Z]{2,4} ?[0-9]{3}[A-Z]?\\b")],
                action: .moveTo(folder: "~/Documents/Courses/{match}"),
                starterID: "courses"
            ),
        ]
    }

    /// Adds the starter rules once, switched off.
    public func seedStarterRulesIfNeeded() throws {
        let key = "orbit.seededStarterRules.v1"
        guard try core.store.preference(key, as: Bool.self) != true else { return }
        let existing = Set(rules().compactMap(\.starterID))
        for rule in Self.starterRules() where !existing.contains(rule.starterID ?? "") {
            try save(rule)
        }
        try core.store.setPreference(true, for: key)
    }

    // MARK: - Dry run

    /// What the rule would do to files already in its folders. Changes nothing.
    public func dryRun(_ rule: FileRule, limit: Int = 500, now: Date = Date()) async -> [DryRunItem] {
        let system = core.system
        var candidates: [String] = []
        for folder in rule.folders.map(FileLocation.normalize) {
            let indexed = (try? core.store.entries(matching: FileQuery(parent: folder, kind: .filesOnly, sort: .name, limit: 5_000))) ?? []
            if !indexed.isEmpty {
                candidates += indexed.map(\.path)
            } else if let names = try? FileManager.default.contentsOfDirectory(atPath: folder) {
                // Not indexed (not an Orbit folder): look directly, read-only.
                candidates += names.filter { !$0.hasPrefix(".") }.map { (folder as NSString).appendingPathComponent($0) }.sorted()
            }
        }
        var items: [DryRunItem] = []
        let others = rules().filter { $0.isEnabled && $0.id != rule.id }
        for path in candidates {
            guard items.count < limit else { break }
            guard await RuleMatcher.matches(rule, path: path, system: system, now: now) else { continue }
            var competing: [FileRule] = []
            for other in others where other.watches(path) {
                if await RuleMatcher.matches(other, path: path, system: system, now: now) { competing.append(other) }
            }
            let step = RulePlanner.plan(rule.action, path: path, rule: rule, ifExists: rule.ifExists, system: system)
            let allowed = core.fileAccess.isAllowed(path)
            let destinationAllowed = step.destination.map(core.fileAccess.isAllowed) ?? true
            let outcome: String
            if !allowed {
                outcome = "Can't change: \(((path as NSString).deletingLastPathComponent).abbreviatedPath) isn't an Orbit folder"
            } else if !destinationAllowed, let destination = step.destination {
                outcome = "Can't change: \(((destination as NSString).deletingLastPathComponent).abbreviatedPath) isn't in an Orbit folder"
            } else if !competing.isEmpty {
                outcome = "Review: also matches " + competing.map { "“\($0.name)”" }.joined(separator: ", ")
            } else if rule.effectiveMode == .askFirst {
                outcome = "Review: \(step.description)"
            } else {
                outcome = step.description
            }
            items.append(DryRunItem(path: path, outcome: outcome, destination: step.destination,
                                    needsReview: !competing.isEmpty || rule.effectiveMode == .askFirst))
        }
        return items
    }

    // MARK: - Review queue

    public func pendingReviews() -> [ReviewItem] {
        (try? core.store.reviewItems(state: .pending)) ?? []
    }

    /// Runs the proposed action through the engine. Approving is the
    /// confirmation, so a Move to Trash doesn't ask a second time.
    @discardableResult
    public func approve(_ item: ReviewItem, action override: RuleAction? = nil) async -> WorkflowRun? {
        var item = item
        if let override { item.action = override }
        let rule = item.ruleIDs.first.flatMap { try? core.store.rule(id: $0) }
        let step = RulePlanner.plan(item.action, path: item.path, rule: rule, ifExists: rule?.ifExists ?? .addNumber, system: core.system)
        let workflow = Workflow(
            name: "Review: \(item.name)",
            summary: item.reason,
            steps: [WorkflowStep(actionID: step.actionID, parameters: step.parameters)]
        )
        let run = await core.engine.run(workflow, trigger: Self.reviewTrigger, approvedIn: "the review queue")
        item.state = run.state == .succeeded ? .approved : .failed
        item.resolvedAt = Date()
        item.runID = run.id
        try? core.store.saveReviewItem(item)
        return run
    }

    public func ignore(_ item: ReviewItem) {
        var item = item
        item.state = .ignored
        item.resolvedAt = Date()
        try? core.store.saveReviewItem(item)
    }

    /// Changes where a pending item will go.
    public func update(_ item: ReviewItem, action: RuleAction) {
        var item = item
        item.action = action
        try? core.store.saveReviewItem(item)
    }

    // MARK: - Daily check

    /// Rules about age ("older than 30 days") can only become true later, so
    /// once a day their workflows run for existing files that now match.
    @discardableResult
    public func sweep(now: Date = Date(), perRuleLimit: Int = 50) async -> Int {
        var started = 0
        for rule in rules() where rule.isEnabled && rule.dependsOnTime {
            guard let workflowID = rule.workflowID, let workflow = try? core.store.workflow(id: workflowID), workflow.isEnabled else { continue }
            let pending = Set(pendingReviews().map(\.path))
            var count = 0
            for folder in rule.folders.map(FileLocation.normalize) {
                let files = (try? core.store.entries(matching: FileQuery(parent: folder, kind: .filesOnly, limit: 5_000))) ?? []
                for file in files where count < perRuleLimit && !pending.contains(file.path) {
                    guard await RuleMatcher.matches(rule, path: file.path, system: core.system, now: now) else { continue }
                    let entry = workflow.triggerNodes.first { FileLocation.normalize($0.parameters["folder"]?.stringValue ?? "") == folder }
                    await core.engine.start(workflow, trigger: Self.sweepTrigger, payload: Self.payload(for: file.path),
                                            entryNodeID: entry?.id ?? workflow.triggerNodes.first?.id)
                    count += 1
                }
            }
            started += count
        }
        try? core.store.setPreference(now, for: Self.lastSweepKey)
        return started
    }

    /// Checks every few hours whether a day has passed since the last sweep.
    public func startDailySweep() {
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + 60, repeating: 3 * 3_600, leeway: .seconds(300))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let last = (try? self.core.store.preference(Self.lastSweepKey, as: Date.self)) ?? nil
            guard last.map({ Date().timeIntervalSince($0) > 86_400 }) ?? true else { return }
            Task { await self.sweep() }
        }
        timer.resume()
        lock.withLock { sweepTimer = timer }
    }

    static func payload(for path: String) -> ActionParameters {
        [
            "path": .string(path),
            "fileName": .string((path as NSString).lastPathComponent),
            "extension": .string((path as NSString).pathExtension.lowercased()),
            "folder": .string((path as NSString).deletingLastPathComponent),
        ]
    }
}
