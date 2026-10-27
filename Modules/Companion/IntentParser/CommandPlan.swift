import AtlasCore
import Foundation

/// What a command will do, before it runs. Both the built-in parser and the
/// optional AI layer produce one, and nothing runs until the person confirms
/// a plan with side effects. Running always goes through `AutomationEngine`
/// (registered actions or a saved workflow), except opening a screen inside
/// ATLAS, which changes nothing on the Mac.
public struct CommandPlan: Equatable, Sendable, Identifiable {
    public struct Step: Equatable, Sendable {
        public var actionID: ActionID
        public var parameters: ActionParameters

        public init(_ actionID: ActionID, _ parameters: ActionParameters = [:]) {
            self.actionID = actionID
            self.parameters = parameters
        }
    }

    /// A screen inside ATLAS. Read-only.
    public enum Destination: Equatable, Sendable {
        case largestFiles
        case cleanup
        case search(String)
        case reviewQueue
        case runHistory(UUID?)
        case section(String)
        case companionSettings
        case health
        /// "When I open Blender, …": draft it as an automation.
        case describeAutomation(String)
        case today
        case timeline
    }

    public enum Kind: Equatable, Sendable {
        /// Registered actions, run in order as one workflow.
        case actions([Step])
        /// A saved workflow, by ID.
        case workflow(UUID, name: String)
        /// Show matching files in the palette (reads the Orbit index).
        case findFiles(String)
        case open(Destination)
        case pauseAutomations(Bool)
        /// Stop a running workflow's run (nil: stop everything).
        case stopRun(UUID?)
    }

    public enum Origin: String, Equatable, Sendable {
        case palette, click, deterministic, ai
    }

    public let id: UUID
    public var kind: Kind
    /// "Activate Coding Lab — Deep Work"
    public var summary: String
    /// Extra lines shown under the summary: the steps, a warning.
    public var details: [String]
    /// Changes something on the Mac, so it's shown before it runs.
    public var hasSideEffects: Bool
    /// True when an AI model proposed it. Always shown and confirmed.
    public var fromAI: Bool
    /// Short label for Run History, e.g. "Coding Lab".
    public var subject: String

    public init(id: UUID = UUID(), kind: Kind, summary: String, details: [String] = [], hasSideEffects: Bool,
                fromAI: Bool = false, subject: String = "") {
        self.id = id
        self.kind = kind
        self.summary = summary
        self.details = details
        self.hasSideEffects = hasSideEffects
        self.fromAI = fromAI
        self.subject = subject
    }

    /// Plans are previewed first when they change something, or came from AI.
    public var needsConfirmation: Bool { hasSideEffects || fromAI }

    /// A one-step workflow for an action plan, named for Run History.
    public func workflow(named name: String? = nil) -> Workflow? {
        guard case .actions(let steps) = kind, !steps.isEmpty else { return nil }
        return Workflow(
            name: name ?? summary,
            summary: "From the Companion",
            steps: steps.map { WorkflowStep(actionID: $0.actionID, parameters: $0.parameters) }
        )
    }
}

/// The result of understanding typed text.
public enum ParseOutcome: Equatable, Sendable {
    case plan(CommandPlan)
    /// Several things match about equally well: ask, don't guess.
    case choices(prompt: String, [CommandPlan])
    /// Nothing matched. The message says what was understood and what to try.
    case unknown(String)

    public var plan: CommandPlan? {
        if case .plan(let plan) = self { return plan }
        return nil
    }
}

/// Names the parser can match against. Built from the store each time the
/// palette opens, so it's always current.
public struct CommandVocabulary: Sendable {
    public struct SpaceEntry: Sendable, Equatable {
        public let id: UUID
        public let name: String
        public let profiles: [(id: UUID, name: String, isDefault: Bool)]
        /// e.g. "coding-lab", for matching "my app" to the coding Space.
        public let templateID: String

        public init(id: UUID, name: String, profiles: [(id: UUID, name: String, isDefault: Bool)], templateID: String = "") {
            self.id = id
            self.name = name
            self.profiles = profiles
            self.templateID = templateID
        }

        public static func == (a: SpaceEntry, b: SpaceEntry) -> Bool { a.id == b.id && a.name == b.name }

        public var defaultProfile: (id: UUID, name: String, isDefault: Bool)? {
            profiles.first(where: \.isDefault) ?? profiles.first
        }
    }

    public struct Named: Sendable, Equatable {
        public let id: String
        public let name: String
        public init(id: String, name: String) {
            self.id = id
            self.name = name
        }
    }

    public var spaces: [SpaceEntry]
    /// Workflows a person would run by name (not rule or activation internals).
    public var workflows: [Named]
    /// Installed apps: id = bundle ID.
    public var apps: [Named]
    public var layouts: [Named]
    public var snapshots: [Named]
    /// Workflows running now: id = run ID, name = workflow name.
    public var runningWorkflows: [Named]
    public var timers: [String]

    public init(spaces: [SpaceEntry] = [], workflows: [Named] = [], apps: [Named] = [], layouts: [Named] = [],
                snapshots: [Named] = [], runningWorkflows: [Named] = [], timers: [String] = []) {
        self.spaces = spaces
        self.workflows = workflows
        self.apps = apps
        self.layouts = layouts
        self.snapshots = snapshots
        self.runningWorkflows = runningWorkflows
        self.timers = timers
    }
}
