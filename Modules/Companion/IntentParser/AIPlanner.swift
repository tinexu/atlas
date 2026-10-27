import AtlasCore
import AtlasSpaces
import Foundation

/// The optional AI layer (off by default). A model only ever *chooses* from
/// what ATLAS already has: registered actions, your Spaces, workflows and
/// layouts, and files in folders you authorized. Its answer must decode into
/// a plan and pass `PlanValidator`; anything else is rejected and the
/// built-in parser is used instead. AI plans are never run automatically.

/// Context the person allowed the Companion to use, already reduced to plain
/// facts. Only what's switched on in Companion settings is filled in.
public struct CompanionContext: Equatable, Sendable {
    public var activeSpace: String?
    public var frontmostApp: String?
    public var runningWorkflows: [String] = []
    public var recentResults: [String] = []
    public var timers: [String] = []
    public var health: String?
    public var reviewCount: Int?

    public init() {}

    var lines: [String] {
        var lines: [String] = []
        if let activeSpace { lines.append("Active Space: \(activeSpace)") }
        if let frontmostApp { lines.append("Frontmost app: \(frontmostApp)") }
        if !runningWorkflows.isEmpty { lines.append("Running now: \(runningWorkflows.joined(separator: ", "))") }
        if !recentResults.isEmpty { lines.append("Recent results: \(recentResults.joined(separator: "; "))") }
        if !timers.isEmpty { lines.append("Timers: \(timers.joined(separator: ", "))") }
        if let health { lines.append("Mac health: \(health)") }
        if let reviewCount { lines.append("Files waiting for review: \(reviewCount)") }
        return lines
    }
}

/// Exactly what a model is given. `preview` is shown to the person before
/// anything is sent to a cloud provider.
public struct AIRequest: Equatable, Sendable {
    public let instructions: String
    public let input: String

    public var preview: String { "INSTRUCTIONS\n\(instructions)\n\nREQUEST\n\(input)" }

    /// What a model provider is sent.
    public var modelRequest: ModelRequest {
        ModelRequest(instructions: instructions, input: input, schema: Self.schema)
    }

    /// Actions a model may propose. Internal plumbing (rule organizer, undo,
    /// logging) is never offered.
    public static func offeredActions(_ registry: ActionRegistry) -> [ActionDescriptor] {
        let hidden: Set<ActionID> = ["orbit.organize", "file.undo", "atlas.log", "timer.delay", "window.captureLayout"]
        return registry.descriptors.filter { !hidden.contains($0.id) }.sorted { $0.id < $1.id }
    }

    public static func make(text: String, registry: ActionRegistry, vocabulary: CommandVocabulary, context: CompanionContext) -> AIRequest {
        let actions = offeredActions(registry).map { descriptor -> String in
            let parameters = descriptor.parameters.map { spec in
                var line = "\(spec.key) (\(spec.kind.rawValue)\(spec.isRequired ? ", required" : ""))"
                if let options = spec.options { line += " one of: \(options.joined(separator: "/"))" }
                return line
            }
            return "- \(descriptor.id.rawValue): \(descriptor.summary)" + (parameters.isEmpty ? "" : " Parameters: \(parameters.joined(separator: "; "))")
        }
        let spaces = vocabulary.spaces.map { space in
            space.profiles.isEmpty ? space.name : "\(space.name) (profiles: \(space.profiles.map(\.name).joined(separator: ", ")))"
        }
        let instructions = """
        You turn a Mac user's short command into a plan for ATLAS, a macOS automation app. \
        Choose ONLY from the actions, Spaces, workflows and layouts listed. Never invent action IDs, names or file paths. \
        Prefer one Space or workflow over several actions. If nothing fits, answer kind "none" with a short message. \
        Answer with JSON matching the schema: kind is one of actions, workflow, space, findFiles, open, none. \
        For actions, list steps with an action ID and its parameters as key/value strings. \
        For workflow or space, put the exact name in target (and an optional profile). For findFiles, put search words in query. \
        For open, choose a destination. Write summary as a short imperative line, e.g. "Activate Coding Lab — Deep Work".

        ACTIONS
        \(actions.joined(separator: "\n"))

        SPACES: \(spaces.isEmpty ? "none" : spaces.joined(separator: "; "))
        WORKFLOWS: \(vocabulary.workflows.isEmpty ? "none" : vocabulary.workflows.map(\.name).joined(separator: "; "))
        WINDOW LAYOUTS: \(vocabulary.layouts.isEmpty ? "none" : vocabulary.layouts.map(\.name).joined(separator: "; "))
        DESTINATIONS: largestFiles, cleanup, reviewQueue, runHistory, health, automations, permissions
        """
        var input = "Command: \(text)"
        let contextLines = context.lines
        if !contextLines.isEmpty { input += "\n\nContext the user allowed:\n" + contextLines.joined(separator: "\n") }
        return AIRequest(instructions: instructions, input: input)
    }

    /// JSON Schema the answer must follow (structured output).
    public static var schema: [String: Any] {
        let parameter: [String: Any] = [
            "type": "object", "additionalProperties": false, "required": ["key", "value"],
            "properties": ["key": ["type": "string"], "value": ["type": "string"]],
        ]
        let step: [String: Any] = [
            "type": "object", "additionalProperties": false, "required": ["action", "parameters"],
            "properties": ["action": ["type": "string"], "parameters": ["type": "array", "items": parameter]],
        ]
        return [
            "type": "object", "additionalProperties": false,
            "required": ["kind", "summary", "steps", "target", "profile", "query", "destination", "message"],
            "properties": [
                "kind": ["type": "string", "enum": ["actions", "workflow", "space", "findFiles", "open", "none"]],
                "summary": ["type": "string"],
                "steps": ["type": "array", "items": step],
                "target": ["type": "string"],
                "profile": ["type": "string"],
                "query": ["type": "string"],
                "destination": ["type": "string", "enum": ["largestFiles", "cleanup", "reviewQueue", "runHistory", "health",
                                                           "automations", "permissions", "none"]],
                "message": ["type": "string"],
            ],
        ]
    }
}

/// What the model returns, before validation.
public struct AIPlanResponse: Decodable, Equatable, Sendable {
    public struct Step: Decodable, Equatable, Sendable {
        public struct Parameter: Decodable, Equatable, Sendable {
            public let key: String
            public let value: String
        }
        public let action: String
        public let parameters: [Parameter]
    }

    public let kind: String
    public let summary: String
    public let steps: [Step]
    public let target: String
    public let profile: String
    public let query: String
    public let destination: String
    public let message: String

    enum CodingKeys: String, CodingKey { case kind, summary, steps, target, profile, query, destination, message }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decode(String.self, forKey: .kind)
        summary = try c.decodeIfPresent(String.self, forKey: .summary) ?? ""
        steps = try c.decodeIfPresent([Step].self, forKey: .steps) ?? []
        target = try c.decodeIfPresent(String.self, forKey: .target) ?? ""
        profile = try c.decodeIfPresent(String.self, forKey: .profile) ?? ""
        query = try c.decodeIfPresent(String.self, forKey: .query) ?? ""
        destination = try c.decodeIfPresent(String.self, forKey: .destination) ?? "none"
        message = try c.decodeIfPresent(String.self, forKey: .message) ?? ""
    }

    /// Accepts a bare JSON object, or one wrapped in prose or a code fence.
    public static func decode(_ text: String) throws -> AIPlanResponse {
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end else {
            throw PlanRejection("The model didn't return a plan.")
        }
        do {
            return try JSONDecoder().decode(AIPlanResponse.self, from: Data(text[start...end].utf8))
        } catch {
            throw PlanRejection("The model's plan wasn't in the expected format.")
        }
    }
}

public struct PlanRejection: Error, LocalizedError, Equatable {
    public let reason: String
    public init(_ reason: String) { self.reason = reason }
    public var errorDescription: String? { reason }
}

/// Checks an AI answer against what actually exists before it can become a
/// plan: known, offered action IDs; every required parameter present and
/// valid; file paths inside authorized folders; real Space and workflow names.
public struct PlanValidator: Sendable {
    public let registry: ActionRegistry
    public let vocabulary: CommandVocabulary
    public let fileAccess: FileAccessPolicy

    public init(registry: ActionRegistry, vocabulary: CommandVocabulary, fileAccess: FileAccessPolicy) {
        self.registry = registry
        self.vocabulary = vocabulary
        self.fileAccess = fileAccess
    }

    public func validate(_ response: AIPlanResponse) throws -> CommandPlan {
        let summary = response.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        switch response.kind {
        case "actions":
            guard !response.steps.isEmpty else { throw PlanRejection("The plan had no steps.") }
            guard response.steps.count <= 8 else { throw PlanRejection("The plan had too many steps.") }
            let offered = Set(AIRequest.offeredActions(registry).map(\.id))
            var steps: [CommandPlan.Step] = []
            var details: [String] = []
            for raw in response.steps {
                let id = ActionID(raw.action)
                guard let descriptor = registry.descriptor(for: id), offered.contains(id) else {
                    throw PlanRejection("“\(raw.action)” isn't an action ATLAS can run.")
                }
                var parameters: ActionParameters = [:]
                for parameter in raw.parameters {
                    guard let spec = descriptor.parameters.first(where: { $0.key == parameter.key }) else {
                        throw PlanRejection("\(descriptor.title) has no setting called “\(parameter.key)”.")
                    }
                    parameters[spec.key] = Self.value(parameter.value, for: spec)
                }
                let validated: ActionParameters
                do {
                    validated = try registry.validate(parameters, for: descriptor)
                } catch {
                    throw PlanRejection("\(descriptor.title): \(error.localizedDescription)")
                }
                for spec in descriptor.parameters where spec.kind == .filePath || spec.kind == .folderPath {
                    guard let path = validated[spec.key]?.stringValue, !path.isEmpty else { continue }
                    let expanded = (path as NSString).expandingTildeInPath
                    guard fileAccess.isAllowed(expanded) else {
                        throw PlanRejection("\(path) isn't in a folder you added to Orbit, so ATLAS won't touch it.")
                    }
                }
                if id == SpaceActivateAction.id, let name = validated["space"]?.stringValue, space(named: name) == nil {
                    throw PlanRejection("There's no Space called “\(name)”.")
                }
                steps.append(.init(id, validated))
                details.append(registry.displayLabel(for: WorkflowStep(actionID: id, parameters: validated)))
            }
            return CommandPlan(kind: .actions(steps), summary: summary.isEmpty ? details.joined(separator: ", ") : summary,
                               details: steps.count > 1 ? details : [], hasSideEffects: true, fromAI: true,
                               subject: details.first ?? "")
        case "workflow":
            guard let workflow = vocabulary.workflows.first(where: { $0.name.caseInsensitiveCompare(response.target) == .orderedSame }),
                  let id = UUID(uuidString: workflow.id)
            else { throw PlanRejection("There's no workflow called “\(response.target)”.") }
            return CommandPlan(kind: .workflow(id, name: workflow.name), summary: summary.isEmpty ? "Run \(workflow.name)" : summary,
                               hasSideEffects: true, fromAI: true, subject: workflow.name)
        case "space":
            guard let space = space(named: response.target) else { throw PlanRejection("There's no Space called “\(response.target)”.") }
            var parameters: ActionParameters = ["space": .string(space.name)]
            var profileName = space.defaultProfile?.name
            if !response.profile.isEmpty {
                guard let profile = space.profiles.first(where: { $0.name.caseInsensitiveCompare(response.profile) == .orderedSame }) else {
                    throw PlanRejection("\(space.name) has no profile called “\(response.profile)”.")
                }
                parameters["profile"] = .string(profile.name)
                profileName = profile.name
            }
            return CommandPlan(kind: .actions([.init(SpaceActivateAction.id, parameters)]),
                               summary: profileName.map { "Activate \(space.name) — \($0)" } ?? "Activate \(space.name)",
                               hasSideEffects: true, fromAI: true, subject: space.name)
        case "findFiles":
            let query = response.query.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !query.isEmpty else { throw PlanRejection("The plan didn't say what to search for.") }
            return CommandPlan(kind: .findFiles(query), summary: "Find files matching “\(query)”", hasSideEffects: false, fromAI: true, subject: query)
        case "open":
            let destinations: [String: (CommandPlan.Destination, String)] = [
                "largestFiles": (.largestFiles, "Show the largest files in Orbit"), "cleanup": (.cleanup, "Open Cleanup Review"),
                "reviewQueue": (.reviewQueue, "Open the review queue"), "runHistory": (.runHistory(nil), "Open Run History"),
                "health": (.health, "Open Mac Health"), "automations": (.section("automations"), "Open Automations"),
                "permissions": (.section("permissions"), "Open Permissions"),
            ]
            guard let (destination, title) = destinations[response.destination] else { throw PlanRejection("The plan named a screen ATLAS doesn't have.") }
            return CommandPlan(kind: .open(destination), summary: title, hasSideEffects: false, fromAI: true, subject: title)
        case "none":
            throw PlanRejection(response.message.isEmpty ? "The model couldn't match that to anything ATLAS can do." : response.message)
        default:
            throw PlanRejection("The model returned an unknown kind of plan.")
        }
    }

    private func space(named name: String) -> CommandVocabulary.SpaceEntry? {
        vocabulary.spaces.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    static func value(_ text: String, for spec: ParameterSpec) -> ActionValue {
        switch spec.kind {
        case .number: return Double(text.trimmingCharacters(in: .whitespaces)).map(ActionValue.number) ?? .string(text)
        case .boolean: return ActionValue.string(text).boolValue.map(ActionValue.bool) ?? .string(text)
        default: return .string(text)
        }
    }
}

/// Runs the AI layer with the built-in parser as the fallback.
public struct IntentResolver: Sendable {
    public struct Result: Equatable, Sendable {
        public var outcome: ParseOutcome
        /// "AI couldn't …, so built-in commands were used." Shown under the plan.
        public var note: String?
        public var usedAI: Bool
    }

    public let parser: DeterministicParser
    public let validator: PlanValidator
    public let provider: (any IntentModelProvider)?

    public init(parser: DeterministicParser, validator: PlanValidator, provider: (any IntentModelProvider)?) {
        self.parser = parser
        self.validator = validator
        self.provider = provider
    }

    public func resolve(_ text: String, context: CompanionContext) async -> Result {
        let builtIn = parser.parse(text)
        guard let provider else { return Result(outcome: builtIn, note: nil, usedAI: false) }
        // A confident built-in match doesn't need a model.
        if case .plan(let plan) = builtIn, !isFallbackSearch(plan) { return Result(outcome: builtIn, note: nil, usedAI: false) }
        if let reason = await provider.unavailableReason() {
            return Result(outcome: builtIn, note: "\(reason) Used built-in commands.", usedAI: false)
        }
        let request = AIRequest.make(text: text, registry: validator.registry, vocabulary: validator.vocabulary, context: context)
        do {
            let answer = try await provider.complete(request.modelRequest)
            let plan = try validator.validate(try AIPlanResponse.decode(answer))
            return Result(outcome: .plan(plan), note: "Planned by \(provider.displayName). Check it before running.", usedAI: true)
        } catch {
            let reason = (error as? PlanRejection)?.reason ?? error.localizedDescription
            return Result(outcome: builtIn, note: "AI plan rejected: \(reason) Used built-in commands.", usedAI: false)
        }
    }

    /// The parser's "no exact match, so search files" guess: worth asking a model.
    private func isFallbackSearch(_ plan: CommandPlan) -> Bool {
        if case .findFiles = plan.kind, plan.details.first?.hasPrefix("No Space") == true { return true }
        return false
    }
}
