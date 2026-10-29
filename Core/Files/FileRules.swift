import Foundation

/// What to do when the destination name is taken. ATLAS never overwrites.
public enum ConflictMode: String, Codable, CaseIterable, Sendable {
    /// "Report (2).pdf"
    case addNumber
    case skip

    public var title: String {
        self == .addNumber ? "Add a number, e.g. “Report (2).pdf”" : "Skip the file"
    }
}

/// One check an organization rule makes about a file.
public enum RuleCondition: Codable, Hashable, Sendable {
    public enum DateField: String, Codable, CaseIterable, Sendable {
        case created, modified
    }

    /// Comma-separated, e.g. "dmg, pkg".
    case extensions(String)
    case nameContains(String)
    case nameMatches(pattern: String)
    case sizeAbove(megabytes: Double)
    case sizeBelow(megabytes: Double)
    case olderThan(days: Int, field: DateField)
    case newerThan(days: Int, field: DateField)
    /// A UTType it conforms to, e.g. "public.image".
    case conformsTo(typeIdentifier: String)
    /// Where it came from, as recorded by macOS (download site or creating app).
    case sourceContains(String)

    public var title: String {
        switch self {
        case .extensions: return "Extension is"
        case .nameContains: return "Name contains"
        case .nameMatches: return "Name matches"
        case .sizeAbove: return "Larger than"
        case .sizeBelow: return "Smaller than"
        case .olderThan: return "Older than"
        case .newerThan: return "Newer than"
        case .conformsTo: return "Kind is"
        case .sourceContains: return "Came from"
        }
    }

    public var summary: String {
        switch self {
        case .extensions(let list): return "extension is \(list)"
        case .nameContains(let text): return "name contains “\(text)”"
        case .nameMatches(let pattern): return "name matches /\(pattern)/"
        case .sizeAbove(let mb): return "larger than \(ActionValue.number(mb).displayString) MB"
        case .sizeBelow(let mb): return "smaller than \(ActionValue.number(mb).displayString) MB"
        case .olderThan(let days, let field): return "\(field.rawValue) more than \(days) days ago"
        case .newerThan(let days, let field): return "\(field.rawValue) in the last \(days) days"
        case .conformsTo(let type): return "kind is \(type)"
        case .sourceContains(let text): return "came from “\(text)”"
        }
    }

    /// Conditions about age can only become true later, so rules using them
    /// also check existing files once a day.
    public var dependsOnTime: Bool {
        switch self {
        case .olderThan, .newerThan: return true
        default: return false
        }
    }

    public static var templates: [RuleCondition] {
        [
            .extensions("pdf"), .nameContains(""), .nameMatches(pattern: ".*"), .sizeAbove(megabytes: 100),
            .sizeBelow(megabytes: 1), .olderThan(days: 30, field: .modified), .newerThan(days: 7, field: .created),
            .conformsTo(typeIdentifier: "public.image"), .sourceContains(""),
        ]
    }
}

/// What a rule does to a matching file.
public enum RuleAction: Codable, Hashable, Sendable {
    /// The folder may use {parentFolder}, {match} and {date:yyyy-MM}.
    case moveTo(folder: String)
    /// Moves it into `folder` under a new name (already worked out, e.g.
    /// "robot-2026-10-29-3.png"). The Creative Studio's exports use this.
    case moveAndRename(folder: String, name: String)
    /// e.g. "{date:yyyy-MM-dd} {name}.{ext}"
    case rename(pattern: String)
    /// Comma-separated Finder tags, added to any it has.
    case tag(String)
    case trash

    public var title: String {
        switch self {
        case .moveTo: return "Move to folder"
        case .moveAndRename: return "Move and rename"
        case .rename: return "Rename"
        case .tag: return "Add Finder tags"
        case .trash: return "Move to Trash"
        }
    }

    public var summary: String {
        switch self {
        case .moveTo(let folder): return "move to \(folder.abbreviatedPath)"
        case .moveAndRename(let folder, let name): return "move to \(folder.abbreviatedPath) as “\(name)”"
        case .rename(let pattern): return "rename to “\(pattern)”"
        case .tag(let tags): return "tag \(tags)"
        case .trash: return "move to the Trash"
        }
    }
}

/// A rule that keeps folders tidy. It runs as a Flow workflow, so it shows
/// up in the Automation Galaxy and in Run History like any other.
public struct FileRule: Identifiable, Hashable, Sendable {
    public enum Mode: String, Codable, CaseIterable, Sendable {
        case automatic, askFirst
        public var title: String { self == .automatic ? "Automatically" : "Ask me first" }
    }

    public var id: UUID
    public var name: String
    public var isEnabled: Bool
    public var mode: Mode
    /// Folders it watches, e.g. ~/Downloads.
    public var folders: [String]
    public var match: ConditionGroup.Match
    public var conditions: [RuleCondition]
    public var action: RuleAction
    public var ifExists: ConflictMode
    /// Only acts when no other rule matches the file (a catch-all, e.g.
    /// "other PDFs"), and never competes with the rules that do.
    public var isFallback: Bool
    /// The generated workflow.
    public var workflowID: UUID?
    /// Set on the built-in starter rules.
    public var starterID: String?
    public var createdAt: Date
    public var updatedAt: Date

    public init(id: UUID = UUID(), name: String, isEnabled: Bool = false, mode: Mode = .automatic, folders: [String],
                match: ConditionGroup.Match = .all, conditions: [RuleCondition], action: RuleAction,
                ifExists: ConflictMode = .addNumber, isFallback: Bool = false, workflowID: UUID? = nil, starterID: String? = nil,
                createdAt: Date = Date(), updatedAt: Date = Date()) {
        self.id = id
        self.name = name
        self.isEnabled = isEnabled
        self.mode = mode
        self.folders = folders
        self.match = match
        self.conditions = conditions
        self.action = action
        self.ifExists = ifExists
        self.isFallback = isFallback
        self.workflowID = workflowID
        self.starterID = starterID
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public var summary: String {
        let joiner = match == .all ? " and " : " or "
        let when = conditions.isEmpty ? "any file" : conditions.map(\.summary).joined(separator: joiner)
        return "When \(when)\(isFallback ? " and no other rule matches" : ""), \(action.summary)\(mode == .askFirst ? " (after you approve)" : "")"
    }

    public var dependsOnTime: Bool { conditions.contains { $0.dependsOnTime } }
}

/// A file waiting for the user to approve what a rule wants to do.
public struct ReviewItem: Identifiable, Hashable, Sendable {
    public enum State: String, Codable, Sendable {
        case pending, approved, ignored, failed
    }

    public var id: UUID
    public var path: String
    public var ruleIDs: [UUID]
    /// The proposal; its folder can be changed before approving.
    public var action: RuleAction
    public var reason: String
    public var state: State
    public var createdAt: Date
    public var resolvedAt: Date?
    public var runID: UUID?

    public init(id: UUID = UUID(), path: String, ruleIDs: [UUID], action: RuleAction, reason: String, state: State = .pending,
                createdAt: Date = Date(), resolvedAt: Date? = nil, runID: UUID? = nil) {
        self.id = id
        self.path = path
        self.ruleIDs = ruleIDs
        self.action = action
        self.reason = reason
        self.state = state
        self.createdAt = createdAt
        self.resolvedAt = resolvedAt
        self.runID = runID
    }

    public var name: String { (path as NSString).lastPathComponent }
}
