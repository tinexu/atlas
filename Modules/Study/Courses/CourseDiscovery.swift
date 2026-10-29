import AtlasCore
import Foundation

/// A class ATLAS found and proposes to add.
public struct CourseSuggestion: Identifiable, Hashable, Sendable {
    public enum Source: Hashable, Sendable {
        case calendar(title: String, count: Int)
        case folder(path: String)
        case vault(path: String)
    }

    public var code: CourseCode
    public var name: String
    public var sources: [Source]
    public var folderPath: String?
    public var vaultPath: String?
    public var id: String { code.canonical }

    /// "calendar + ~/Documents/Chem 101"
    public var summary: String {
        sources.map { source -> String in
            switch source {
            case .calendar(_, let count): return count > 1 ? "calendar (\(count)×)" : "calendar"
            case .folder(let path): return (path as NSString).abbreviatingWithTildeInPath
            case .vault(let path): return "vault/\((path as NSString).lastPathComponent)"
            }
        }.joined(separator: " + ")
    }
}

/// Finds classes from what's already on the Mac, so setup is mostly
/// confirming: recurring calendar events, folder names in folders you
/// gave ATLAS, and folder names in an Obsidian vault.
public enum CourseDiscovery {
    /// Words dropped when guessing a course name from an event title.
    static let eventWords: Set<String> = ["lecture", "lec", "lab", "discussion", "disc", "section", "sec", "recitation", "rec",
                                          "seminar", "tutorial", "class", "office", "hours", "oh", "-", "–", "—", ":", "·", "|"]

    /// Suggestions from calendar events, folder paths and vault folders,
    /// skipping codes already in `existing` (or their aliases) and `ignored`.
    /// Calendar classes count only if they recur (seen at least twice).
    public static func suggest(events: [CalendarEvent], folders: [String], vaultFolders: [String] = [],
                               existing: [Course], ignored: Set<String> = []) -> [CourseSuggestion] {
        let known = Set(existing.flatMap { [$0.code] + $0.aliases }).union(ignored)
        var found: [String: CourseSuggestion] = [:]
        func add(_ code: CourseCode, _ source: CourseSuggestion.Source, name: String?, folder: String? = nil, vault: String? = nil) {
            guard !known.contains(code.canonical) else { return }
            var suggestion = found[code.canonical] ?? CourseSuggestion(code: code, name: code.display, sources: [])
            suggestion.sources.append(source)
            if let name, suggestion.name == code.display || name.count > suggestion.name.count { suggestion.name = name }
            if let folder, suggestion.folderPath == nil { suggestion.folderPath = folder }
            if let vault, suggestion.vaultPath == nil { suggestion.vaultPath = vault }
            found[code.canonical] = suggestion
        }

        var byCode: [CourseCode: [CalendarEvent]] = [:]
        for event in events {
            for code in CourseCode.find(in: event.title) { byCode[code, default: []].append(event) }
        }
        for (code, matches) in byCode where matches.count >= 2 {
            add(code, .calendar(title: matches[0].title, count: matches.count), name: nameGuess(matches[0].title, code: code))
        }
        for path in folders {
            let name = (path as NSString).lastPathComponent
            for code in CourseCode.find(in: name) { add(code, .folder(path: path), name: nameGuess(name, code: code), folder: path) }
        }
        for path in vaultFolders {
            let name = (path as NSString).lastPathComponent
            for code in CourseCode.find(in: name) { add(code, .vault(path: path), name: nameGuess(name, code: code), vault: path) }
        }
        return found.values.sorted { ($0.sources.count, $1.code) > ($1.sources.count, $0.code) }
    }

    /// "CHEM 101 – General Chemistry Lecture" → "General Chemistry";
    /// nil when nothing but the code and filler words is left.
    static func nameGuess(_ text: String, code: CourseCode) -> String? {
        var remainder = text
        for spelling in [code.canonical, code.display, "\(code.subject)-\(code.number)", "\(code.subject)_\(code.number)"] {
            remainder = remainder.replacingOccurrences(of: spelling, with: " ", options: .caseInsensitive)
        }
        let words = remainder.split(whereSeparator: { $0 == " " || $0 == "_" }).map(String.init)
            .filter { !eventWords.contains($0.lowercased()) && !$0.allSatisfy(\.isNumber) }
        let name = words.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        return name.count >= 3 ? name : nil
    }

    /// Folders up to `depth` levels inside `roots` (course folders are
    /// often a level or two down, e.g. ~/Documents/School/CHEM 101).
    public static func subfolders(of roots: [String], depth: Int = 2, fileManager: FileManager = .default) -> [String] {
        var result: [String] = []
        func walk(_ path: String, _ level: Int) {
            guard level <= depth, let items = try? fileManager.contentsOfDirectory(atPath: path) else { return }
            for item in items where !item.hasPrefix(".") {
                let child = (path as NSString).appendingPathComponent(item)
                var isDirectory: ObjCBool = false
                guard fileManager.fileExists(atPath: child, isDirectory: &isDirectory), isDirectory.boolValue,
                      !child.hasSuffix(".app"), !child.hasSuffix(".bundle") else { continue }
                result.append(child)
                walk(child, level + 1)
            }
        }
        roots.forEach { walk($0, 1) }
        return result
    }
}
