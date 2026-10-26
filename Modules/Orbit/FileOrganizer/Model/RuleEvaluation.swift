import AtlasCore
import Foundation

extension RuleCondition {
    /// The Flow condition check for this rule condition, about `path`
    /// (usually `{{trigger.path}}`).
    public func check(path: String = "{{trigger.path}}") -> ConditionCheck {
        switch self {
        case .extensions(let list): return .fileExtension(path: path, extensions: list)
        case .nameContains(let text): return .fileNameContains(path: path, text: text)
        case .nameMatches(let pattern): return .fileNameMatches(path: path, pattern: pattern)
        case .sizeAbove(let mb): return .fileSize(path: path, op: .greaterThan, megabytes: mb)
        case .sizeBelow(let mb): return .fileSize(path: path, op: .lessThan, megabytes: mb)
        case .olderThan(let days, let field): return .fileAge(path: path, field: field, op: .greaterThan, days: days)
        case .newerThan(let days, let field): return .fileAge(path: path, field: field, op: .lessThan, days: days)
        case .conformsTo(let type): return .fileType(path: path, typeIdentifier: type)
        case .sourceContains(let text): return .fileSource(path: path, text: text)
        }
    }

    public var validationError: String? {
        switch self {
        case .extensions(let list):
            return list.trimmingCharacters(in: .whitespaces).isEmpty ? "List at least one extension." : nil
        case .nameContains(let text), .sourceContains(let text):
            return text.isEmpty ? "Enter some text." : nil
        case .nameMatches(let pattern):
            return (try? NSRegularExpression(pattern: pattern)) == nil ? "“\(pattern)” isn't a valid regular expression." : nil
        case .sizeAbove(let mb), .sizeBelow(let mb):
            return mb < 0 ? "Sizes can't be negative." : nil
        case .olderThan(let days, _), .newerThan(let days, _):
            return days < 0 ? "Days can't be negative." : nil
        case .conformsTo(let type):
            return check().validationError ?? (type.isEmpty ? "Enter a type, e.g. public.image." : nil)
        }
    }
}

extension FileRule {
    public var conditionGroup: ConditionGroup {
        ConditionGroup(match: match, items: conditions.map { ConditionItem($0.check()) })
    }

    /// Problems that stop the rule from being turned on.
    public var problems: [String] {
        var problems: [String] = []
        if name.trimmingCharacters(in: .whitespaces).isEmpty { problems.append("Give the rule a name.") }
        if folders.isEmpty { problems.append("Choose at least one folder to watch.") }
        problems += conditions.compactMap(\.validationError)
        switch action {
        case .moveTo(let folder) where folder.trimmingCharacters(in: .whitespaces).isEmpty:
            problems.append("Choose a folder to move files to.")
        case .rename(let pattern) where pattern.trimmingCharacters(in: .whitespaces).isEmpty:
            problems.append("Enter a rename pattern, e.g. {date:yyyy-MM-dd} {name}.")
        case .tag(let tags) where tags.trimmingCharacters(in: .whitespaces).isEmpty:
            problems.append("Enter at least one tag.")
        default: break
        }
        return problems
    }

    /// Moving to the Trash always waits for approval: ATLAS never removes
    /// files without a preview and a yes.
    public var effectiveMode: Mode { action == .trash ? .askFirst : mode }

    /// The text the rule's name pattern matched, for `{match}`, e.g. "CS101".
    public func matchedText(in name: String) -> String? {
        for case .nameMatches(let pattern) in conditions {
            if let range = name.range(of: pattern, options: [.regularExpression, .caseInsensitive]) {
                return String(name[range]).uppercased().replacingOccurrences(of: " ", with: "")
            }
        }
        return nil
    }

    /// Whether this rule watches the folder `path` is directly in.
    public func watches(_ path: String) -> Bool {
        let parent = (path as NSString).deletingLastPathComponent
        return folders.contains { FileLocation.normalize($0) == parent }
    }
}

/// Checks rules against a real file, with the same evaluator Flow uses.
public enum RuleMatcher {
    public static func matches(_ rule: FileRule, path: String, system: SystemAdapter, now: Date = Date()) async -> Bool {
        guard system.fileKind(atPath: path) == .file || isPackage(path, system: system) else { return false }
        let context = ConditionContext(system: system, displayCount: { 1 }, activeSpaceID: nil, now: now,
                                       resolve: { $0.replacingOccurrences(of: "{{trigger.path}}", with: path) })
        return await ConditionEvaluator.evaluate(rule.conditionGroup, in: context).0
    }

    private static func isPackage(_ path: String, system: SystemAdapter) -> Bool {
        system.fileKind(atPath: path) == .directory
            && ["app", "pages", "numbers", "key", "rtfd"].contains((path as NSString).pathExtension.lowercased())
    }
}
