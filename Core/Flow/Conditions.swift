import Foundation
import UniformTypeIdentifiers

public enum ComparisonOperator: String, Codable, CaseIterable, Sendable {
    case equals, notEquals, lessThan, greaterThan, contains, isEmpty, isNotEmpty

    public var title: String {
        switch self {
        case .equals: return "="
        case .notEquals: return "≠"
        case .lessThan: return "<"
        case .greaterThan: return ">"
        case .contains: return "contains"
        case .isEmpty: return "is empty"
        case .isNotEmpty: return "is not empty"
        }
    }

    /// Numbers compare as numbers when both sides parse; otherwise as text.
    public func compare(_ left: String, _ right: String) -> Bool {
        let l = left.trimmingCharacters(in: .whitespaces), r = right.trimmingCharacters(in: .whitespaces)
        let ln = Double(l), rn = Double(r)
        switch self {
        case .equals:
            if let ln, let rn { return ln == rn }
            return l.caseInsensitiveCompare(r) == .orderedSame
        case .notEquals:
            return !ComparisonOperator.equals.compare(l, r)
        case .lessThan:
            if let ln, let rn { return ln < rn }
            return l.localizedStandardCompare(r) == .orderedAscending
        case .greaterThan:
            if let ln, let rn { return ln > rn }
            return l.localizedStandardCompare(r) == .orderedDescending
        case .contains:
            return l.localizedCaseInsensitiveContains(r)
        case .isEmpty:
            return l.isEmpty
        case .isNotEmpty:
            return !l.isEmpty
        }
    }

    public var needsRightSide: Bool { self != .isEmpty && self != .isNotEmpty }
}

/// One check a condition node can make. Text fields accept templates such
/// as `{{trigger.path}}`.
public enum ConditionCheck: Codable, Hashable, Sendable {
    case appRunning(bundleID: String)
    case appFrontmost(bundleID: String)
    case activeSpace(spaceID: UUID, name: String)
    case displayCount(op: ComparisonOperator, count: Int)
    case fileExists(path: String)
    /// Comma-separated, e.g. "pdf, png".
    case fileExtension(path: String, extensions: String)
    case fileSize(path: String, op: ComparisonOperator, megabytes: Double)
    case fileNameContains(path: String, text: String)
    case fileNameMatches(path: String, pattern: String)
    /// Whole days since the file was created or modified, compared with `days`.
    case fileAge(path: String, field: RuleCondition.DateField, op: ComparisonOperator, days: Int)
    /// The file's type conforms to a UTType, e.g. "public.image".
    case fileType(path: String, typeIdentifier: String)
    /// Where macOS says it came from (download site or creating app) contains the text.
    case fileSource(path: String, text: String)
    /// "HH:mm"; a range past midnight (22:00–06:00) wraps.
    case timeInRange(start: String, end: String)
    /// 1 = Sunday … 7 = Saturday.
    case dayOfWeek(days: [Int])
    case batteryLevel(op: ComparisonOperator, percent: Int)
    case powerSource(onAdapter: Bool)
    /// Compares two values, typically a variable and a constant.
    case compare(left: String, op: ComparisonOperator, right: String)

    public var title: String {
        switch self {
        case .appRunning: return "App is running"
        case .appFrontmost: return "App is frontmost"
        case .activeSpace: return "Active Space is"
        case .displayCount: return "Number of displays"
        case .fileExists: return "File exists"
        case .fileExtension: return "File extension is"
        case .fileSize: return "File size"
        case .fileNameContains: return "File name contains"
        case .fileNameMatches: return "File name matches"
        case .fileAge: return "File age"
        case .fileType: return "File kind is"
        case .fileSource: return "File came from"
        case .timeInRange: return "Time is between"
        case .dayOfWeek: return "Day of week is"
        case .batteryLevel: return "Battery level"
        case .powerSource: return "Power source"
        case .compare: return "Compare values"
        }
    }

    /// Short readable form, e.g. "File extension is pdf".
    public var summary: String {
        switch self {
        case .appRunning(let id): return "\(id) is running"
        case .appFrontmost(let id): return "\(id) is frontmost"
        case .activeSpace(_, let name): return "Active Space is \(name)"
        case .displayCount(let op, let n): return "Displays \(op.title) \(n)"
        case .fileExists(let path): return "\(path) exists"
        case .fileExtension(_, let ext): return "Extension is \(ext)"
        case .fileSize(_, let op, let mb): return "Size \(op.title) \(ActionValue.number(mb).displayString) MB"
        case .fileNameContains(_, let text): return "Name contains “\(text)”"
        case .fileNameMatches(_, let pattern): return "Name matches /\(pattern)/"
        case .fileAge(_, let field, let op, let days): return "Days since \(field.rawValue) \(op.title) \(days)"
        case .fileType(_, let type): return "Kind is \(type)"
        case .fileSource(_, let text): return "Came from “\(text)”"
        case .timeInRange(let a, let b): return "Between \(a) and \(b)"
        case .dayOfWeek(let days):
            let names = Calendar(identifier: .gregorian).shortWeekdaySymbols
            return days.sorted().compactMap { names.indices.contains($0 - 1) ? names[$0 - 1] : nil }.joined(separator: ", ")
        case .batteryLevel(let op, let p): return "Battery \(op.title) \(p)%"
        case .powerSource(let ac): return ac ? "On power adapter" : "On battery"
        case .compare(let l, let op, let r): return op.needsRightSide ? "\(l) \(op.title) \(r)" : "\(l) \(op.title)"
        }
    }

    /// A blank check of each type, for the editor's "Add check" menu.
    public static var templates: [ConditionCheck] {
        [
            .fileExtension(path: "{{trigger.path}}", extensions: "pdf"),
            .fileNameContains(path: "{{trigger.path}}", text: ""),
            .fileNameMatches(path: "{{trigger.path}}", pattern: ".*"),
            .fileExists(path: "{{trigger.path}}"),
            .fileSize(path: "{{trigger.path}}", op: .greaterThan, megabytes: 10),
            .fileAge(path: "{{trigger.path}}", field: .modified, op: .greaterThan, days: 30),
            .fileType(path: "{{trigger.path}}", typeIdentifier: "public.image"),
            .fileSource(path: "{{trigger.path}}", text: ""),
            .appRunning(bundleID: "com.apple.Safari"),
            .appFrontmost(bundleID: "com.apple.Safari"),
            .activeSpace(spaceID: UUID(), name: "Space"),
            .displayCount(op: .greaterThan, count: 1),
            .timeInRange(start: "09:00", end: "17:00"),
            .dayOfWeek(days: [2, 3, 4, 5, 6]),
            .batteryLevel(op: .lessThan, percent: 20),
            .powerSource(onAdapter: true),
            .compare(left: "{{var.count}}", op: .greaterThan, right: "0"),
        ]
    }

    public var validationError: String? {
        switch self {
        case .fileNameMatches(_, let pattern):
            return (try? NSRegularExpression(pattern: pattern)) == nil ? "“\(pattern)” isn't a valid regular expression." : nil
        case .timeInRange(let a, let b):
            return TimeOfDay(a) == nil || TimeOfDay(b) == nil ? "Times must look like 09:30." : nil
        case .dayOfWeek(let days):
            return days.isEmpty ? "Pick at least one day." : nil
        case .fileType(_, let identifier):
            return identifier.contains("{{") || UTType(identifier) != nil ? nil : "“\(identifier)” isn't a type macOS knows, e.g. public.image."
        default:
            return nil
        }
    }
}

/// A check in a group; `negated` turns it into NOT.
public struct ConditionItem: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var check: ConditionCheck
    public var negated: Bool

    public init(id: UUID = UUID(), _ check: ConditionCheck, negated: Bool = false) {
        self.id = id
        self.check = check
        self.negated = negated
    }
}

/// Checks combined with AND (all) or OR (any).
public struct ConditionGroup: Codable, Hashable, Sendable {
    public enum Match: String, Codable, CaseIterable, Sendable {
        case all, any
        public var title: String { self == .all ? "All of these (AND)" : "Any of these (OR)" }
    }

    public var match: Match
    public var items: [ConditionItem]

    public init(match: Match = .all, items: [ConditionItem] = []) {
        self.match = match
        self.items = items
    }

    public init(_ checks: ConditionCheck..., match: Match = .all) {
        self.init(match: match, items: checks.map { ConditionItem($0) })
    }
}

/// "HH:mm" as minutes since midnight.
public struct TimeOfDay: Hashable, Sendable {
    public let minutes: Int

    public init?(_ text: String) {
        let parts = text.trimmingCharacters(in: .whitespaces).split(separator: ":")
        guard parts.count == 2, let h = Int(parts[0]), let m = Int(parts[1]), (0..<24).contains(h), (0..<60).contains(m) else {
            return nil
        }
        minutes = h * 60 + m
    }

    public var hour: Int { minutes / 60 }
    public var minute: Int { minutes % 60 }
}

/// What conditions can look at while a run is in progress.
public struct ConditionContext: Sendable {
    public let system: SystemAdapter
    public let displayCount: @Sendable () async -> Int
    public let activeSpaceID: UUID?
    public let now: Date
    public let calendar: Calendar
    /// Fills in `{{…}}` templates.
    public let resolve: @Sendable (String) -> String

    public init(
        system: SystemAdapter,
        displayCount: @escaping @Sendable () async -> Int,
        activeSpaceID: UUID?,
        now: Date = Date(),
        calendar: Calendar = .current,
        resolve: @escaping @Sendable (String) -> String = { $0 }
    ) {
        self.system = system
        self.displayCount = displayCount
        self.activeSpaceID = activeSpaceID
        self.now = now
        self.calendar = calendar
        self.resolve = resolve
    }
}

public enum ConditionEvaluator {
    /// The group's result and, per check, a line explaining it.
    public static func evaluate(_ group: ConditionGroup, in context: ConditionContext) async -> (Bool, [String]) {
        var results: [Bool] = []
        var lines: [String] = []
        for item in group.items {
            let raw = await evaluate(item.check, in: context)
            let value = item.negated ? !raw : raw
            results.append(value)
            lines.append("\(item.negated ? "NOT " : "")\(item.check.summary): \(value ? "yes" : "no")")
        }
        if results.isEmpty { return (true, ["No checks: always true"]) }
        let passed = group.match == .all ? results.allSatisfy { $0 } : results.contains(true)
        return (passed, lines)
    }

    public static func evaluate(_ check: ConditionCheck, in context: ConditionContext) async -> Bool {
        let r = context.resolve
        switch check {
        case .appRunning(let id):
            let id = r(id)
            return context.system.runningApplications().contains { $0.bundleID == id }
        case .appFrontmost(let id):
            let id = r(id)
            return context.system.runningApplications().contains { $0.bundleID == id && $0.isActive }
        case .activeSpace(let spaceID, _):
            return context.activeSpaceID == spaceID
        case .displayCount(let op, let count):
            return op.compare(String(await context.displayCount()), String(count))
        case .fileExists(let path):
            return context.system.fileKind(atPath: expand(r(path))) != .missing
        case .fileExtension(let path, let extensions):
            let ext = (r(path) as NSString).pathExtension.lowercased()
            let wanted = r(extensions).split(separator: ",").map {
                $0.trimmingCharacters(in: .whitespaces).lowercased().replacingOccurrences(of: ".", with: "")
            }
            return !ext.isEmpty && wanted.contains(ext)
        case .fileSize(let path, let op, let megabytes):
            guard let size = context.system.fileSize(atPath: expand(r(path))) else { return false }
            return op.compare(String(Double(size) / 1_000_000), String(megabytes))
        case .fileNameContains(let path, let text):
            return (r(path) as NSString).lastPathComponent.localizedCaseInsensitiveContains(r(text))
        case .fileNameMatches(let path, let pattern):
            let name = (r(path) as NSString).lastPathComponent
            return name.range(of: r(pattern), options: [.regularExpression, .caseInsensitive]) != nil
        case .fileAge(let path, let field, let op, let days):
            guard let info = context.system.fileInfo(atPath: expand(r(path))),
                  let date = field == .created ? info.createdAt : info.modifiedAt
            else { return false }
            let age = Int(context.now.timeIntervalSince(date) / 86_400)
            return op.compare(String(age), String(days))
        case .fileType(let path, let identifier):
            let path = expand(r(path))
            guard let info = context.system.fileInfo(atPath: path), let wanted = UTType(r(identifier)) else { return false }
            let type = info.typeIdentifier.flatMap(UTType.init) ?? UTType(filenameExtension: (path as NSString).pathExtension)
            return type?.conforms(to: wanted) ?? false
        case .fileSource(let path, let text):
            let text = r(text)
            guard !text.isEmpty, let info = context.system.fileInfo(atPath: expand(r(path))) else { return false }
            return info.sources.contains { $0.localizedCaseInsensitiveContains(text) }
        case .timeInRange(let start, let end):
            guard let a = TimeOfDay(start), let b = TimeOfDay(end) else { return false }
            let parts = context.calendar.dateComponents([.hour, .minute], from: context.now)
            let now = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
            return a.minutes <= b.minutes ? (now >= a.minutes && now < b.minutes) : (now >= a.minutes || now < b.minutes)
        case .dayOfWeek(let days):
            return days.contains(context.calendar.component(.weekday, from: context.now))
        case .batteryLevel(let op, let percent):
            guard let level = context.system.powerStatus()?.batteryPercent else { return false }
            return op.compare(String(level), String(percent))
        case .powerSource(let onAdapter):
            guard let status = context.system.powerStatus() else { return onAdapter }
            return status.isOnAdapter == onAdapter
        case .compare(let left, let op, let right):
            return op.compare(r(left), r(right))
        }
    }

    private static func expand(_ path: String) -> String {
        (path as NSString).expandingTildeInPath
    }
}

// MARK: - Templates

/// Fills `{{name}}` placeholders, e.g. "Moved {{trigger.fileName}}".
///
/// Names: `trigger.<key>` (what the trigger reported), `var.<name>`
/// (variables), `loop.item` / `loop.index`, `error.message`, and
/// `node.<label>.<key>` (an upstream node's output).
public enum Templates {
    /// The value for a parameter: a lone `{{x}}` keeps its type (a number
    /// stays a number); text with placeholders becomes text.
    public static func resolve(_ value: ActionValue, scope: [String: ActionValue]) -> (ActionValue, missing: [String]) {
        guard case .string(let text) = value, text.contains("{{") else { return (value, []) }
        let names = placeholders(in: text)
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if names.count == 1, trimmed == "{{\(names[0].raw)}}" {
            if let found = lookup(names[0].name, scope) { return (found, []) }
            return (.string(""), [names[0].name])
        }
        let (result, missing) = resolve(text, scope: scope)
        return (.string(result), missing)
    }

    public static func resolve(_ text: String, scope: [String: ActionValue]) -> (String, missing: [String]) {
        var result = text
        var missing: [String] = []
        for placeholder in placeholders(in: text) {
            let value = lookup(placeholder.name, scope)
            if value == nil { missing.append(placeholder.name) }
            result = result.replacingOccurrences(of: "{{\(placeholder.raw)}}", with: value?.displayString ?? "")
        }
        return (result, missing)
    }

    public static func placeholders(in text: String) -> [(raw: String, name: String)] {
        var found: [(String, String)] = []
        var rest = Substring(text)
        while let open = rest.range(of: "{{"), let close = rest.range(of: "}}", range: open.upperBound..<rest.endIndex) {
            let raw = String(rest[open.upperBound..<close.lowerBound])
            found.append((raw, raw.trimmingCharacters(in: .whitespaces)))
            rest = rest[close.upperBound...]
        }
        return found
    }

    private static func lookup(_ name: String, _ scope: [String: ActionValue]) -> ActionValue? {
        if let value = scope[name] { return value }
        // Bare names are variables: {{count}} means {{var.count}}.
        if !name.contains("."), let value = scope["var.\(name)"] { return value }
        // Case-insensitive fallback, e.g. {{Trigger.FileName}}.
        return scope.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }
}
