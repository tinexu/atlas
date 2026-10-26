import AtlasCore
import AtlasSpaces
import Foundation

/// Where a command came from. Voice can plug in later as another source.
public enum CommandInputSource: String, Sendable {
    case palette, click, voice
}

/// Carries out a confirmed `CommandPlan`. It is a control surface, not an
/// engine: actions and workflows run through `AutomationEngine` with the
/// trigger "companion", so they get the same validation, permission checks,
/// confirmations and Run History as everything else.
public final class CommandRunner: Sendable {
    public enum Outcome: Sendable {
        case run(WorkflowRun)
        case open(CommandPlan.Destination)
        case findFiles(String)
        case paused(Bool)
        case stopped(Int)
        case failed(String)
    }

    let core: AtlasCore

    public init(core: AtlasCore) {
        self.core = core
    }

    /// Runs a plan. Call only after the person confirmed it when
    /// `plan.needsConfirmation` is true.
    public func run(_ plan: CommandPlan, text: String, source: CommandInputSource) async -> Outcome {
        record(plan, text: text, source: source)
        switch plan.kind {
        case .actions:
            guard let workflow = plan.workflow() else { return .failed("That command has nothing to run.") }
            return .run(await core.engine.run(workflow, trigger: RunTrigger.companion))
        case .workflow(let id, let name):
            guard let workflow = try? core.store.workflow(id: id) else { return .failed("“\(name)” was deleted.") }
            return .run(await core.engine.run(workflow, trigger: RunTrigger.companion))
        case .findFiles(let query):
            return .findFiles(query)
        case .open(let destination):
            return .open(destination)
        case .pauseAutomations(let paused):
            await core.engine.setPaused(paused)
            return .paused(paused)
        case .stopRun(let runID):
            if let runID {
                await core.engine.cancel(runID: runID)
                return .stopped(1)
            }
            let count = await core.engine.runningRunIDs.count
            await core.engine.cancelAll()
            return .stopped(count)
        }
    }

    /// Runs a plan without waiting, returning the run ID when it starts one.
    /// Used by quick controls so the menu closes at once.
    @discardableResult
    public func start(_ plan: CommandPlan, text: String, source: CommandInputSource) async -> UUID? {
        switch plan.kind {
        case .actions:
            guard let workflow = plan.workflow() else { return nil }
            record(plan, text: text, source: source)
            return await core.engine.start(workflow, trigger: RunTrigger.companion)
        case .workflow(let id, _):
            guard let workflow = try? core.store.workflow(id: id) else { return nil }
            record(plan, text: text, source: source)
            return await core.engine.start(workflow, trigger: RunTrigger.companion)
        default:
            _ = await run(plan, text: text, source: source)
            return nil
        }
    }

    private func record(_ plan: CommandPlan, text: String, source: CommandInputSource) {
        let typed = text.isEmpty ? plan.summary : text
        if source == .palette, !text.isEmpty {
            try? core.store.recordCompanionCommand(text: typed, summary: plan.summary, source: source.rawValue)
        }
        core.events.publish(AtlasEvent(AtlasEvent.Name.companionCommand, payload: [
            "text": .string(typed), "summary": .string(plan.summary), "source": .string(source.rawValue),
            "fromAI": .bool(plan.fromAI),
        ]))
    }
}

/// Short lines for the speech bubble.
public enum StatusMessages {
    /// "Coding Lab ready · 4 of 4 steps", "Moved 2 files to PDFs", "Morning Setup done".
    public static func message(for run: WorkflowRun, store: AtlasStore?) -> String {
        if let spaceStep = run.steps.first(where: { $0.actionID == SpaceActivateAction.id }) {
            let name = spaceStep.inputs["space"]?.stringValue ?? run.workflowName
            let inner = spaceStep.output["runId"]?.stringValue.flatMap(UUID.init(uuidString:)).flatMap { try? store?.run(id: $0) }
            let counts = inner.map { inner -> String in
                let actions = inner.steps.filter { $0.kind == .action }
                let done = actions.filter { $0.state == .succeeded }.count
                return " · \(done) of \(actions.count) steps"
            } ?? ""
            switch run.state {
            case .succeeded: return "\(name) ready\(counts)"
            case .partiallySucceeded, .failed:
                if let inner, inner.steps.contains(where: { $0.state == .succeeded }) { return "\(name) partly ready\(counts)" }
                return "\(name) didn't activate"
            default: break
            }
        }
        switch run.state {
        case .succeeded:
            let messages = run.steps.filter { $0.kind == .action && $0.state == .succeeded }.compactMap(\.message)
            if messages.count == 1, let only = messages.first { return only }
            return "\(run.workflowName) done"
        case .partiallySucceeded:
            let done = run.steps.filter { $0.state == .succeeded }.count
            return "\(run.workflowName): \(done) of \(run.steps.count) steps worked"
        case .failed:
            return "\(run.workflowName) failed"
        case .canceled:
            return "Stopped \(run.workflowName)"
        case .skipped:
            return "\(run.workflowName) didn't run: \(run.error ?? "automations are paused")"
        default:
            return run.workflowName
        }
    }
}
