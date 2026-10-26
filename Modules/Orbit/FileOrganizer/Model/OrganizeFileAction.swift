import AtlasCore
import Foundation

/// `orbit.organize`: the last node of every rule's workflow. It applies the
/// rule's action through the regular file actions (so folder checks,
/// "never overwrite" and the undo log all apply), or, when the rule asks
/// first or several rules want the same file, puts the file in the review
/// queue instead.
public struct OrganizeFileAction: AtlasAction {
    public static let id: ActionID = "orbit.organize"

    private let store: AtlasStore
    private let registry: ActionRegistry

    public let descriptor = ActionDescriptor(
        id: OrganizeFileAction.id,
        title: "Organize File",
        summary: "Applies an Orbit rule to a file, or puts it in the review queue when the rule asks first or more than one rule matches.",
        category: "Links & Files",
        symbolName: "tray.and.arrow.down",
        parameters: [
            ParameterSpec(key: "ruleId", label: "Rule", kind: .text),
            ParameterSpec(key: "path", label: "File", kind: .filePath),
        ],
        permissions: [.fileAccess],
        sideEffects: [.modifiesFiles],
        isIdempotent: false,
        defaultTimeout: 60,
        outputs: [
            OutputSpec(key: "path", label: "New path", type: .filePath),
            OutputSpec(key: "outcome", label: "Outcome", type: .string),
        ]
    )

    public init(store: AtlasStore, registry: ActionRegistry) {
        self.store = store
        self.registry = registry
    }

    public func perform(_ parameters: ActionParameters, context: ActionContext) async throws -> ActionOutput {
        guard let id = UUID(uuidString: try parameters.requiredString("ruleId")), let rule = try store.rule(id: id) else {
            throw ActionError.failed("This rule was deleted. Delete its automation too, or recreate the rule in Orbit → Rules.")
        }
        let path = try parameters.path("path")
        guard context.system.fileKind(atPath: path) != .missing else {
            return ActionOutput("\((path as NSString).lastPathComponent) is gone already", values: ["path": .string(path), "outcome": "skipped"])
        }
        context.events.publish(AtlasEvent(AtlasEvent.Name.ruleMatched, payload: [
            "ruleId": .string(rule.id.uuidString), "ruleName": .string(rule.name), "path": .string(path),
        ]))

        var others: [FileRule] = []
        for other in try store.rules() where other.isEnabled && other.id != rule.id && other.watches(path) {
            if await RuleMatcher.matches(other, path: path, system: context.system) { others.append(other) }
        }

        if rule.effectiveMode == .askFirst || !others.isEmpty {
            let reason: String
            if !others.isEmpty {
                reason = "Matches \(others.count + 1) rules: " + ([rule] + others).map { "“\($0.name)”" }.joined(separator: ", ")
            } else if rule.action == .trash {
                reason = "“\(rule.name)” wants to move it to the Trash"
            } else {
                reason = "“\(rule.name)” asks before acting"
            }
            let item = try store.addReviewItem(ReviewItem(path: path, ruleIDs: ([rule] + others).map(\.id), action: rule.action, reason: reason))
            context.events.publish(AtlasEvent(AtlasEvent.Name.reviewAdded, payload: [
                "reviewId": .string(item.id.uuidString), "path": .string(path), "reason": .string(reason),
            ]))
            return ActionOutput("Waiting for your review: \(reason)", values: ["path": .string(path), "outcome": "review"])
        }

        let step = RulePlanner.plan(rule.action, path: path, rule: rule, ifExists: rule.ifExists, system: context.system)
        guard let action = registry.action(for: step.actionID) else { throw ActionError.unknownAction(step.actionID) }
        let validated = try registry.validate(step.parameters, for: action.descriptor)
        var output = try await action.perform(validated, context: context)
        output.values["outcome"] = output.values["skipped"]?.boolValue == true ? "skipped" : "done"
        return output
    }
}
