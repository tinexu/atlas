import Foundation

/// A generated workflow waiting for review: what was asked, the plain
/// summary and the assumptions made. Kept so the editor can show them.
public struct GeneratedDraft: Identifiable, Hashable, Sendable {
    public enum Source: String, Codable, Sendable {
        case ai, rules, template
        public var title: String {
            switch self {
            case .ai: return "AI"
            case .rules: return "ATLAS (no AI)"
            case .template: return "Template"
            }
        }
    }
    public enum State: String, Codable, Sendable { case draft, kept, discarded }

    public var id: UUID
    public var workflowID: UUID
    public var prompt: String
    public var summary: String
    public var assumptions: [String]
    public var source: Source
    public var state: State
    public var createdAt: Date

    public init(id: UUID = UUID(), workflowID: UUID, prompt: String, summary: String, assumptions: [String], source: Source,
                state: State = .draft, createdAt: Date = Date()) {
        self.id = id
        self.workflowID = workflowID
        self.prompt = prompt
        self.summary = summary
        self.assumptions = assumptions
        self.source = source
        self.state = state
        self.createdAt = createdAt
    }
}

/// What generation may refer to. Names only; nothing else about your files.
public struct GenerationContext: Sendable {
    public var spaces: [String]
    public var workflows: [(id: UUID, name: String)]
    public var layouts: [String]
    /// Orbit folders (the only places file actions may touch).
    public var folders: [String]
    /// Installed apps: bundle ID and name.
    public var apps: [(id: String, name: String)]
    /// Permissions ATLAS already has.
    public var granted: Set<Permission>

    public init(spaces: [String] = [], workflows: [(id: UUID, name: String)] = [], layouts: [String] = [], folders: [String] = [],
                apps: [(id: String, name: String)] = [], granted: Set<Permission> = Set(Permission.allCases)) {
        self.spaces = spaces
        self.workflows = workflows
        self.layouts = layouts
        self.folders = folders
        self.apps = apps
        self.granted = granted
    }

    public func app(named text: String) -> (id: String, name: String)? {
        if text.contains("."), let exact = apps.first(where: { $0.id.caseInsensitiveCompare(text) == .orderedSame }) { return exact }
        return NameMatcher.rank(text, in: apps, name: \.name, ignoring: ["app", "application"]).first.flatMap { $0.score >= 0.7 ? $0.item : nil }
    }

    public func space(named text: String) -> String? {
        NameMatcher.rank(text, in: spaces, name: { $0 }, ignoring: ["space", "room"]).first.flatMap { $0.score >= 0.7 ? $0.item : nil }
    }
}

/// A workflow described as data: what a model returns, or what the
/// built-in phrase parser builds. Turned into a real graph by `build`.
public struct WorkflowBlueprint: Codable, Equatable, Sendable {
    public struct Parameter: Codable, Equatable, Sendable {
        public var key: String
        public var value: String
        public init(_ key: String, _ value: String) {
            self.key = key
            self.value = value
        }
    }

    public struct Trigger: Codable, Equatable, Sendable {
        public var type: String
        public var parameters: [Parameter]
        public init(type: String, parameters: [Parameter] = []) {
            self.type = type
            self.parameters = parameters
        }
    }

    /// Only these check types are generated: timeInRange ("09:00-17:00"),
    /// dayOfWeek ("weekdays" or "mon,wed"), appRunning (an app).
    public struct Condition: Codable, Equatable, Sendable {
        public var type: String
        public var value: String
        public init(type: String, value: String) {
            self.type = type
            self.value = value
        }
    }

    public struct Step: Codable, Equatable, Sendable {
        public var action: String
        public var parameters: [Parameter]
        public var label: String
        public init(action: String, parameters: [Parameter] = [], label: String = "") {
            self.action = action
            self.parameters = parameters
            self.label = label
        }
    }

    public var name: String
    public var summary: String
    public var assumptions: [String]
    public var trigger: Trigger?
    public var conditions: [Condition]
    public var steps: [Step]

    public init(name: String, summary: String, assumptions: [String] = [], trigger: Trigger? = nil, conditions: [Condition] = [], steps: [Step]) {
        self.name = name
        self.summary = summary
        self.assumptions = assumptions
        self.trigger = trigger
        self.conditions = conditions
        self.steps = steps
    }

    enum CodingKeys: String, CodingKey { case name, summary, assumptions, trigger, conditions, steps }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Generated Automation"
        summary = try c.decodeIfPresent(String.self, forKey: .summary) ?? ""
        assumptions = try c.decodeIfPresent([String].self, forKey: .assumptions) ?? []
        trigger = try c.decodeIfPresent(Trigger.self, forKey: .trigger)
        if trigger?.type.isEmpty == true || trigger?.type == "none" { trigger = nil }
        conditions = try c.decodeIfPresent([Condition].self, forKey: .conditions) ?? []
        steps = try c.decodeIfPresent([Step].self, forKey: .steps) ?? []
    }
}

/// A reviewed-before-saving workflow: the graph (turned off), what it does
/// in plain words, the assumptions to check, and any problems.
public struct WorkflowProposal: Sendable {
    public var workflow: Workflow
    public var summary: String
    public var assumptions: [String]
    public var issues: [ValidationIssue]
    public var source: GeneratedDraft.Source
    public var prompt: String
    /// Set when AI was tried and the built-in parser was used instead.
    public var note: String?

    public var hasErrors: Bool { issues.contains { $0.severity == .error } }
}

public enum GenerationError: Error, LocalizedError, Equatable {
    case notUnderstood(String)
    case rejected(String)

    public var errorDescription: String? {
        switch self {
        case .notUnderstood(let message), .rejected(let message): return message
        }
    }
}

/// Turns blueprints into checked workflows. Unknown triggers and actions,
/// invalid parameters and folders outside Orbit are rejected; actions that
/// need a permission ATLAS doesn't have are flagged. Drafts start disabled.
public struct WorkflowGenerator: Sendable {
    let registry: ActionRegistry
    let fileAccess: FileAccessPolicy
    let validate: @Sendable (Workflow) -> [ValidationIssue]

    public init(registry: ActionRegistry, fileAccess: FileAccessPolicy, validate: @escaping @Sendable (Workflow) -> [ValidationIssue]) {
        self.registry = registry
        self.fileAccess = fileAccess
        self.validate = validate
    }

    /// Not a registered action: becomes a Subworkflow node.
    public static let runWorkflowAction = "workflow.run"

    public init(core: AtlasCore) {
        self.init(registry: core.registry, fileAccess: core.fileAccess) { [core] in core.validate($0) }
    }

    /// AI when a provider is given and available, otherwise (or on failure)
    /// the built-in phrase parser.
    public func generate(_ prompt: String, context: GenerationContext, provider: (any IntentModelProvider)?) async throws -> WorkflowProposal {
        var note: String?
        if let provider {
            if let reason = await provider.unavailableReason() {
                note = "\(reason) Used ATLAS's built-in understanding instead."
            } else {
                do {
                    let answer = try await provider.complete(Self.request(prompt, context: context, registry: registry), within: 60)
                    guard let data = extractJSONObject(answer) else { throw GenerationError.rejected("The model didn't return a workflow.") }
                    let blueprint = try JSONDecoder().decode(WorkflowBlueprint.self, from: data)
                    return try proposal(from: Self.resolveNames(blueprint, context: context), prompt: prompt, source: .ai, context: context)
                } catch {
                    note = "AI couldn't make a valid workflow (\(error.localizedDescription)). Used ATLAS's built-in understanding instead."
                }
            }
        }
        guard let blueprint = PhraseWorkflowParser.parse(prompt, context: context) else {
            throw GenerationError.notUnderstood(note.map { $0 + " " } ?? "" +
                "ATLAS couldn't turn that into steps. Try “When I open Blender, activate Creative Studio”, or start from a template.")
        }
        var result = try proposal(from: blueprint, prompt: prompt, source: .rules, context: context)
        result.note = note
        return result
    }

    /// Checks a blueprint and builds the (disabled) workflow.
    public func proposal(from blueprint: WorkflowBlueprint, prompt: String, source: GeneratedDraft.Source, context: GenerationContext) throws -> WorkflowProposal {
        guard !blueprint.steps.isEmpty else { throw GenerationError.rejected("The workflow had no steps.") }
        var assumptions = blueprint.assumptions
        var steps: [WorkflowStep] = []
        var connections: [WorkflowConnection] = []
        var x = 0.0

        var previous: WorkflowStep?
        func append(_ step: WorkflowStep) {
            var step = step
            step.position = NodePosition(x: x, y: 0)
            x += 300
            if let previous {
                connections.append(WorkflowConnection(fromNode: previous.id, fromPort: previous.kind == .condition ? "true" : NodePort.controlOut, toNode: step.id))
            }
            steps.append(step)
            previous = step
        }

        if let trigger = blueprint.trigger {
            guard let type = TriggerCatalog.type(id: trigger.type) else {
                throw GenerationError.rejected("“\(trigger.type)” isn't a trigger ATLAS has.")
            }
            var parameters: ActionParameters = [:]
            for parameter in trigger.parameters {
                guard let spec = type.parameters.first(where: { $0.key == parameter.key }) else {
                    throw GenerationError.rejected("The “\(type.title)” trigger has no setting called “\(parameter.key)”.")
                }
                parameters[spec.key] = Self.value(parameter.value, for: spec)
                if spec.kind == .folderPath || spec.kind == .filePath { try checkPath(parameter.value) }
            }
            for missing in type.permissions where !context.granted.contains(missing) {
                assumptions.append("The “\(type.title)” trigger needs \(missing.title) access, which ATLAS doesn't have yet.")
            }
            append(.trigger(type.id, parameters: parameters))
        }

        if !blueprint.conditions.isEmpty {
            let checks = try blueprint.conditions.map { try Self.check(for: $0, context: context) }
            append(.condition(ConditionGroup(match: .all, items: checks.map { ConditionItem($0) }), label: "Only if"))
        }

        for raw in blueprint.steps {
            if raw.action == Self.runWorkflowAction {
                let name = raw.parameters.first { $0.key == "workflow" }?.value ?? ""
                guard let target = context.workflows.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) else {
                    throw GenerationError.rejected("There's no workflow called “\(name)”.")
                }
                append(.control(.subworkflow, config: NodeConfig(workflowID: target.id), label: "Run \(target.name)"))
                continue
            }
            let id = ActionID(raw.action)
            guard let descriptor = registry.descriptor(for: id), !AIRequestCatalog.hiddenActions.contains(id) else {
                throw GenerationError.rejected("“\(raw.action)” isn't an action ATLAS can run.")
            }
            var parameters: ActionParameters = [:]
            for parameter in raw.parameters {
                guard let spec = descriptor.parameters.first(where: { $0.key == parameter.key }) else {
                    throw GenerationError.rejected("\(descriptor.title) has no setting called “\(parameter.key)”.")
                }
                parameters[spec.key] = Self.value(parameter.value, for: spec)
            }
            // Templates ({{trigger.path}}) are filled at run time, so check the rest.
            let concrete = parameters.filter { !($0.value.stringValue ?? "").contains("{{") }
            let missingRequired = descriptor.parameters.filter { $0.isRequired && parameters[$0.key] == nil && $0.defaultValue == nil }
            if let missing = missingRequired.first { throw GenerationError.rejected("\(descriptor.title) needs “\(missing.label)”.") }
            do {
                var check = concrete
                for spec in descriptor.parameters where parameters[spec.key] != nil && concrete[spec.key] == nil {
                    check[spec.key] = Self.placeholder(for: spec)
                }
                _ = try registry.validate(check, for: descriptor)
            } catch {
                throw GenerationError.rejected("\(descriptor.title): \(error.localizedDescription)")
            }
            for spec in descriptor.parameters where spec.kind == .filePath || spec.kind == .folderPath {
                if let value = concrete[spec.key]?.stringValue { try checkPath(value) }
            }
            for missing in descriptor.permissions where !context.granted.contains(missing) {
                assumptions.append("“\(descriptor.title)” needs \(missing.title) permission, which ATLAS doesn't have yet. Grant it before turning this on.")
            }
            append(WorkflowStep(actionID: id, parameters: parameters, label: raw.label.isEmpty ? nil : raw.label))
        }

        let workflow = Workflow(
            name: blueprint.name.isEmpty ? "Generated Automation" : blueprint.name,
            summary: blueprint.summary,
            isEnabled: false,
            failurePolicy: .stopOnFailure,
            steps: steps,
            connections: connections
        )
        return WorkflowProposal(workflow: workflow, summary: blueprint.summary, assumptions: assumptions,
                                issues: validate(workflow), source: source, prompt: prompt)
    }

    private func checkPath(_ value: String) throws {
        guard !value.contains("{{") else { return }
        let path = (value as NSString).expandingTildeInPath
        guard fileAccess.isAllowed(path) else {
            throw GenerationError.rejected("\(value) isn't in a folder you added to Orbit, so ATLAS won't touch it. Add it in Orbit → Folders first.")
        }
    }

    /// A valid stand-in for a value filled in at run time, so the rest can be checked.
    static func placeholder(for spec: ParameterSpec) -> ActionValue {
        switch spec.kind {
        case .number: return .number(spec.minimum ?? 1)
        case .boolean: return .bool(true)
        case .filePath, .folderPath: return "/placeholder"
        case .url: return "https://example.com"
        case .bundleIdentifier: return "com.example.placeholder"
        case .text: return .string(spec.options?.first ?? "placeholder")
        }
    }

    static func value(_ text: String, for spec: ParameterSpec) -> ActionValue {
        switch spec.kind {
        case .number: return Double(text.trimmingCharacters(in: .whitespaces)).map(ActionValue.number) ?? .string(text)
        case .boolean: return ActionValue.string(text).boolValue.map(ActionValue.bool) ?? .string(text)
        default: return .string(text)
        }
    }

    static func check(for condition: WorkflowBlueprint.Condition, context: GenerationContext) throws -> ConditionCheck {
        switch condition.type {
        case "timeInRange":
            let parts = condition.value.split(separator: "-").map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2, TimeOfDay(parts[0]) != nil, TimeOfDay(parts[1]) != nil else {
                throw GenerationError.rejected("“\(condition.value)” isn't a time range like 09:00-17:00.")
            }
            return .timeInRange(start: parts[0], end: parts[1])
        case "dayOfWeek":
            let text = condition.value.lowercased()
            if text.contains("weekday") { return .dayOfWeek(days: [2, 3, 4, 5, 6]) }
            if text.contains("weekend") { return .dayOfWeek(days: [1, 7]) }
            let names = ["sun", "mon", "tue", "wed", "thu", "fri", "sat"]
            let days = text.split(whereSeparator: { $0 == "," || $0 == " " }).compactMap { part in names.firstIndex { part.hasPrefix($0) }.map { $0 + 1 } }
            guard !days.isEmpty else { throw GenerationError.rejected("“\(condition.value)” isn't a list of days.") }
            return .dayOfWeek(days: days)
        case "appRunning":
            guard let app = context.app(named: condition.value) else { throw GenerationError.rejected("No installed app matches “\(condition.value)”.") }
            return .appRunning(bundleID: app.id)
        default:
            throw GenerationError.rejected("“\(condition.type)” isn't a check ATLAS can generate.")
        }
    }

    /// Models sometimes name apps instead of giving bundle IDs; map them.
    static func resolveNames(_ blueprint: WorkflowBlueprint, context: GenerationContext) -> WorkflowBlueprint {
        var result = blueprint
        func fix(_ parameters: inout [WorkflowBlueprint.Parameter], keys: Set<String>) {
            for index in parameters.indices where keys.contains(parameters[index].key) {
                let value = parameters[index].value
                if !value.contains("."), let app = context.app(named: value) { parameters[index].value = app.id }
            }
        }
        if result.trigger != nil { fix(&result.trigger!.parameters, keys: ["app"]) }
        for index in result.steps.indices { fix(&result.steps[index].parameters, keys: ["bundleId"]) }
        return result
    }

    // MARK: - Model request

    public static func request(_ prompt: String, context: GenerationContext, registry: ActionRegistry) -> ModelRequest {
        let triggers = TriggerCatalog.all.map { type in
            "- \(type.id): \(type.summary)" + (type.parameters.isEmpty ? "" : " Settings: " + type.parameters.map { "\($0.key) (\($0.kind.rawValue))" }.joined(separator: "; "))
        }
        let actions = registry.descriptors.filter { !AIRequestCatalog.hiddenActions.contains($0.id) }.sorted { $0.id < $1.id }.map { d in
            "- \(d.id.rawValue): \(d.summary)" + (d.parameters.isEmpty ? "" : " Settings: " + d.parameters.map { "\($0.key) (\($0.kind.rawValue)\($0.isRequired ? ", required" : ""))" }.joined(separator: "; "))
        }
        let instructions = """
        You design automations for ATLAS, a macOS app. Turn the user's description into a workflow: at most one trigger, optional \
        conditions, then actions in order. Use ONLY the trigger types, condition types and action IDs listed; never invent IDs, \
        names or paths. Apps are bundle IDs from the APPS list. File paths must be inside the FOLDERS list. Use {{trigger.path}} \
        for the file a file trigger reported. To run another workflow, use action "workflow.run" with parameter workflow (its exact name). When you have to guess what the user meant (e.g. which apps are "distracting"), \
        make a reasonable choice and say so in assumptions. Leave trigger null for a workflow run by hand.

        TRIGGERS
        \(triggers.joined(separator: "\n"))

        CONDITIONS: timeInRange (value "09:00-17:00"), dayOfWeek (value "weekdays" or "mon,wed"), appRunning (value an app's bundle ID)

        ACTIONS
        \(actions.joined(separator: "\n"))

        SPACES: \(context.spaces.joined(separator: "; ").nilIfEmpty ?? "none")
        WORKFLOWS: \(context.workflows.map(\.name).joined(separator: "; ").nilIfEmpty ?? "none")
        WINDOW LAYOUTS: \(context.layouts.joined(separator: "; ").nilIfEmpty ?? "none")
        FOLDERS: \(context.folders.joined(separator: "; ").nilIfEmpty ?? "none")
        APPS: \(context.apps.prefix(200).map { "\($0.name)=\($0.id)" }.joined(separator: "; "))
        """
        return ModelRequest(instructions: instructions, input: "Describe as a workflow: \(prompt)", schema: schema)
    }

    static var schema: [String: Any] {
        let parameter: [String: Any] = ["type": "object", "additionalProperties": false, "required": ["key", "value"],
                                        "properties": ["key": ["type": "string"], "value": ["type": "string"]]]
        let trigger: [String: Any] = ["type": "object", "additionalProperties": false, "required": ["type", "parameters"],
                                      "properties": ["type": ["type": "string"], "parameters": ["type": "array", "items": parameter]]]
        return [
            "type": "object", "additionalProperties": false,
            "required": ["name", "summary", "assumptions", "trigger", "conditions", "steps"],
            "properties": [
                "name": ["type": "string"],
                "summary": ["type": "string"],
                "assumptions": ["type": "array", "items": ["type": "string"]],
                "trigger": ["anyOf": [trigger, ["type": "null"]]],
                "conditions": ["type": "array", "items": [
                    "type": "object", "additionalProperties": false, "required": ["type", "value"],
                    "properties": ["type": ["type": "string", "enum": ["timeInRange", "dayOfWeek", "appRunning"]], "value": ["type": "string"]],
                ]],
                "steps": ["type": "array", "items": [
                    "type": "object", "additionalProperties": false, "required": ["action", "parameters", "label"],
                    "properties": ["action": ["type": "string"], "parameters": ["type": "array", "items": parameter], "label": ["type": "string"]],
                ]],
            ],
        ]
    }

    // MARK: - Templates (no AI)

    public static func templates(context: GenerationContext) -> [(title: String, blueprint: WorkflowBlueprint)] {
        let space = context.spaces.first ?? "Coding Lab"
        let folder = context.folders.first ?? "~/Downloads"
        let workflow = context.workflows.first?.name
        return [
            ("When an app launches → activate a Space", WorkflowBlueprint(
                name: "Open \(space) with an app", summary: "When the app you choose opens, activate \(space).",
                assumptions: ["Pick the app in the trigger, and the Space in the step."],
                trigger: .init(type: TriggerCatalog.appLaunched, parameters: [.init("app", context.apps.first?.id ?? "com.apple.Safari")]),
                steps: [.init(action: "space.activate", parameters: [.init("space", space)])])),
            ("When a file arrives → move it", WorkflowBlueprint(
                name: "Sort new files in \((folder as NSString).lastPathComponent)", summary: "When a PDF appears in \(folder), move it into a PDFs folder there.",
                assumptions: ["Change the extension and the destination to suit you."],
                trigger: .init(type: TriggerCatalog.fileCreated, parameters: [.init("folder", folder), .init("extensions", "pdf")]),
                steps: [.init(action: "file.move", parameters: [.init("path", "{{trigger.path}}"), .init("destination", (folder as NSString).appendingPathComponent("PDFs"))])])),
            ("Every weekday at 9 → run", WorkflowBlueprint(
                name: "Weekday mornings", summary: "Every weekday at 09:00, \(workflow.map { "run \($0)" } ?? "show a notification").",
                trigger: .init(type: TriggerCatalog.timeReached, parameters: [.init("repeat", "weekly"), .init("time", "09:00"), .init("days", "mon, tue, wed, thu, fri")]),
                steps: workflow == nil
                    ? [.init(action: "notification.show", parameters: [.init("title", "Good morning")])]
                    : [.init(action: "notification.show", parameters: [.init("title", "Starting \(workflow!)")])])),
        ]
    }
}

/// Actions never offered to a model or generated.
public enum AIRequestCatalog {
    public static let hiddenActions: Set<ActionID> = ["orbit.organize", "file.undo", "atlas.log", "window.captureLayout"]
}

extension AtlasCore {
    /// Saves an approved proposal as a turned-off workflow, remembering the
    /// prompt and assumptions for the editor's draft banner.
    @discardableResult
    public func saveDraft(_ proposal: WorkflowProposal) throws -> Workflow {
        var workflow = proposal.workflow
        workflow.isEnabled = false
        let saved = try save(workflow)
        try store.saveDraft(GeneratedDraft(workflowID: saved.id, prompt: proposal.prompt, summary: proposal.summary,
                                           assumptions: proposal.assumptions, source: proposal.source))
        events.publish(AtlasEvent(AtlasEvent.Name.workflowGenerated, payload: [
            "workflowId": .string(saved.id.uuidString), "source": .string(proposal.source.rawValue), "prompt": .string(proposal.prompt),
        ]))
        return saved
    }

    /// Names generation may refer to, from the store.
    public func generationContext(apps: [(id: String, name: String)], granted: Set<Permission>) -> GenerationContext {
        let spaces = ((try? store.database.query("SELECT name FROM space ORDER BY slot;")) ?? []).compactMap { $0.string("name") }
        let workflows = ((try? store.workflows()) ?? []).filter { !$0.name.hasPrefix("Rule: ") && !$0.name.hasPrefix("Schedule: ") }
            .map { (id: $0.id, name: $0.name) }
        return GenerationContext(spaces: spaces, workflows: workflows, layouts: ((try? store.windowLayouts()) ?? []).map(\.name),
                                 folders: fileAccess.authorizedRoots, apps: apps, granted: granted)
    }
}
