import AtlasCore
import Foundation

/// Fills rename and destination patterns:
/// `{name}` the name without extension, `{ext}` the extension,
/// `{date:yyyy-MM-dd}` the file's creation date (any date format),
/// `{counter}` the lowest number that makes the name unique,
/// `{parentFolder}` the name of the folder it's in. Destinations may also
/// use `{folder}` (the full path of that folder) and `{match}` (what the
/// rule's name pattern matched, e.g. "CS101").
public enum RenamePattern {
    public static func resolve(_ pattern: String, path: String, date: Date?, match: String? = nil, counter: Int? = nil) -> String {
        let name = (path as NSString).lastPathComponent
        let folder = (path as NSString).deletingLastPathComponent
        var result = pattern
            .replacingOccurrences(of: "{name}", with: (name as NSString).deletingPathExtension)
            .replacingOccurrences(of: "{ext}", with: (name as NSString).pathExtension)
            .replacingOccurrences(of: "{parentFolder}", with: (folder as NSString).lastPathComponent)
            .replacingOccurrences(of: "{folder}", with: folder)
            .replacingOccurrences(of: "{match}", with: match ?? "Unsorted")
        if let counter { result = result.replacingOccurrences(of: "{counter}", with: String(counter)) }
        // {date} and {date:format}
        while let open = result.range(of: "{date") , let close = result.range(of: "}", range: open.upperBound..<result.endIndex) {
            var format = String(result[open.upperBound..<close.lowerBound])
            format = format.hasPrefix(":") ? String(format.dropFirst()) : "yyyy-MM-dd"
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = format.isEmpty ? "yyyy-MM-dd" : format
            result.replaceSubrange(open.lowerBound..<close.upperBound, with: formatter.string(from: date ?? Date()))
        }
        return result
    }

    /// A new file name from a pattern. Keeps the original extension when the
    /// pattern doesn't say one, so a rename never changes what opens the file.
    public static func newName(_ pattern: String, path: String, date: Date?, match: String? = nil,
                               isTaken: (String) -> Bool) -> String {
        let ext = (path as NSString).pathExtension
        func finish(_ name: String) -> String {
            let trimmed = name.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "/", with: "-")
            guard !ext.isEmpty, (trimmed as NSString).pathExtension.isEmpty else { return trimmed }
            return trimmed + "." + ext
        }
        guard pattern.contains("{counter}") else { return finish(resolve(pattern, path: path, date: date, match: match)) }
        for counter in 1...10_000 {
            let candidate = finish(resolve(pattern, path: path, date: date, match: match, counter: counter))
            if !isTaken(candidate) { return candidate }
        }
        return finish(resolve(pattern, path: path, date: date, match: match, counter: 10_001))
    }
}

/// One concrete step a rule will take for one file.
public struct PlannedStep: Sendable, Equatable {
    public let actionID: ActionID
    public let parameters: ActionParameters
    /// e.g. "Move to ~/Downloads/Screenshots"
    public let description: String
    /// Where the file ends up, when known in advance.
    public let destination: String?
}

/// Turns a rule action into a registered file action for a given file.
public enum RulePlanner {
    public static func plan(_ action: RuleAction, path: String, rule: FileRule?, ifExists: ConflictMode,
                            system: SystemAdapter) -> PlannedStep {
        let name = (path as NSString).lastPathComponent
        let date = system.fileInfo(atPath: path)?.createdAt
        let match = rule?.matchedText(in: name)
        let conflict = ActionValue.string(ifExists.rawValue)
        switch action {
        case .moveTo(let folder):
            let target = FileLocation.normalize(RenamePattern.resolve(folder, path: path, date: date, match: match))
            let direct = (target as NSString).appendingPathComponent(name)
            let taken = system.fileKind(atPath: direct) != .missing
            let destination: String? = taken ? (ifExists == .skip ? nil : FilePathsPreview.available(name, in: target, system: system)) : direct
            return PlannedStep(
                actionID: MoveFileAction.id,
                parameters: ["path": .string(path), "destination": .string(target), "createFolder": true, "ifExists": conflict],
                description: destination == nil ? "Skip: \(target.abbreviatedPath) already has \(name)" : "Move to \(target.abbreviatedPath)",
                destination: destination
            )
        case .moveAndRename(let folder, let newName):
            let target = FileLocation.normalize(folder)
            let direct = (target as NSString).appendingPathComponent(newName)
            let taken = system.fileKind(atPath: direct) != .missing
            let destination: String? = taken ? (ifExists == .skip ? nil : FilePathsPreview.available(newName, in: target, system: system)) : direct
            return PlannedStep(
                actionID: MoveFileAction.id,
                parameters: ["path": .string(path), "destination": .string(target), "name": .string(newName), "createFolder": true,
                             "ifExists": conflict],
                description: destination == nil ? "Skip: \(target.abbreviatedPath) already has \(newName)"
                    : "Move to \(target.abbreviatedPath) as “\(newName)”",
                destination: destination
            )
        case .rename(let pattern):
            let folder = (path as NSString).deletingLastPathComponent
            let newName = RenamePattern.newName(pattern, path: path, date: date, match: match) {
                system.fileKind(atPath: (folder as NSString).appendingPathComponent($0)) != .missing
            }
            return PlannedStep(
                actionID: RenameFileAction.id,
                parameters: ["path": .string(path), "name": .string(newName), "ifExists": conflict],
                description: "Rename to “\(newName)”",
                destination: (folder as NSString).appendingPathComponent(newName)
            )
        case .tag(let tags):
            return PlannedStep(actionID: TagFileAction.id, parameters: ["path": .string(path), "tags": .string(tags)],
                               description: "Tag \(tags)", destination: path)
        case .trash:
            return PlannedStep(actionID: TrashFileAction.id, parameters: ["path": .string(path)],
                               description: "Move to the Trash", destination: nil)
        }
    }
}

/// The same "name (2).ext" choice the file actions make, for previews.
enum FilePathsPreview {
    static func available(_ name: String, in folder: String, system: SystemAdapter) -> String {
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var candidate = (folder as NSString).appendingPathComponent(name)
        var n = 2
        while system.fileKind(atPath: candidate) != .missing {
            candidate = (folder as NSString).appendingPathComponent(ext.isEmpty ? "\(base) (\(n))" : "\(base) (\(n)).\(ext)")
            n += 1
        }
        return candidate
    }
}
