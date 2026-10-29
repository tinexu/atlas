import AtlasCore
import Foundation

/// A project found on disk, waiting for confirmation.
public struct ProjectSuggestion: Identifiable, Hashable, Sendable {
    public var id: String { folder ?? mainFiles.first ?? name }
    public var name: String
    /// Nil for a single file sitting directly in an Orbit folder.
    public var folder: String?
    public var mainFiles: [String]
    public var kind: CreativeInfo.Kind
    public var apps: [String]
    public var fileCount: Int
    public var newest: Date

    /// "Blender · 3 files · ~/Creative/Robot".
    public func summary(appName: (String) -> String?) -> String {
        var parts: [String] = [apps.first.flatMap(appName) ?? kind.title]
        parts.append("\(fileCount) file\(fileCount == 1 ? "" : "s")")
        parts.append((folder ?? mainFiles.first ?? "").abbreviatedPath)
        return parts.joined(separator: " · ")
    }
}

/// Finds creative projects in your Orbit folders: creative files grouped
/// by the folder they're in (a project's own Exports, Versions, References…
/// folders count as part of it), newest first.
public enum ProjectDiscovery {
    public static let maxSuggestions = 12

    /// `roots` are authorized folders; `existing` projects and `ignored`
    /// folders are left out.
    public static func suggest(roots: [String], existing: [Project], ignored: Set<String> = [], fileManager: FileManager = .default,
                               isInstalled: (String) -> Bool = { _ in true }, limit: Int = 20_000) -> [ProjectSuggestion] {
        struct Group { var files: [(path: String, modified: Date)] = [] }
        var groups: [String: Group] = [:]   // key: project folder, or "file:<path>" for a loose file
        // One spelling for every path (e.g. /var vs /private/var), so folders match.
        let rootSet = Set(roots.map(FileAccessPolicy.canonical))
        var seen = 0
        for root in rootSet.sorted() {
            guard let walker = fileManager.enumerator(at: URL(fileURLWithPath: root), includingPropertiesForKeys: [.contentModificationDateKey],
                                                      options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
            for case let url as URL in walker {
                seen += 1
                if seen > limit { break }
                if walker.level > 5 { walker.skipDescendants(); continue }
                guard CreativeFiles.type(of: url.path) != nil else { continue }
                let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let path = FileAccessPolicy.canonical(url.path)
                let folder = projectFolder(for: path, roots: rootSet)
                let key = folder ?? "file:\(path)"
                groups[key, default: Group()].files.append((path, modified))
            }
        }

        let taken = existing.compactMap(\.creative)
        let takenFolders = Set(taken.compactMap(\.folder).map(FileAccessPolicy.canonical))
        let takenFiles = Set(taken.flatMap(\.mainFiles).map(FileAccessPolicy.canonical))
        let ignored = Set(ignored.map(FileAccessPolicy.canonical))
        var suggestions: [ProjectSuggestion] = []
        for (key, group) in groups {
            let folder = key.hasPrefix("file:") ? nil : key
            if let folder, takenFolders.contains(where: { FileLocation.isPath(folder, inside: $0) }) || ignored.contains(folder) { continue }
            let files = group.files.sorted { $0.modified > $1.modified }
            if folder == nil, let file = files.first?.path, takenFiles.contains(file) || ignored.contains(file) { continue }
            // The kind most of its files are; the newest file of that kind is the main one.
            var counts: [CreativeInfo.Kind: Int] = [:]
            for file in files { if let type = CreativeFiles.type(of: file.path) { counts[type.kind, default: 0] += 1 } }
            let kind = counts.max { ($0.value, $1.key.rawValue) < ($1.value, $0.key.rawValue) }?.key ?? .other
            let main = files.first { CreativeFiles.type(of: $0.path)?.kind == kind } ?? files[0]
            let apps = CreativeFiles.type(of: main.path)?.apps.filter(isInstalled) ?? []
            let name = displayName(folder.map { ($0 as NSString).lastPathComponent }
                                   ?? ((main.path as NSString).lastPathComponent as NSString).deletingPathExtension)
            suggestions.append(ProjectSuggestion(name: name, folder: folder, mainFiles: [main.path], kind: kind, apps: apps,
                                                 fileCount: files.count, newest: files[0].modified))
        }
        return Array(suggestions.sorted { ($0.newest, $1.name) > ($1.newest, $0.name) }.prefix(maxSuggestions))
    }

    /// The project folder a file belongs to: its folder, or the one above a
    /// project subfolder (Exports, Versions…). Nil when that would be an
    /// Orbit folder itself (a loose file there is a project on its own).
    static func projectFolder(for path: String, roots: Set<String>) -> String? {
        var folder = (path as NSString).deletingLastPathComponent
        while CreativeFiles.projectSubfolders.contains((folder as NSString).lastPathComponent.lowercased()), !roots.contains(folder) {
            folder = (folder as NSString).deletingLastPathComponent
        }
        return roots.contains(folder) ? nil : folder
    }

    /// "robot-model" → "Robot Model"; names with capitals are kept.
    static func displayName(_ raw: String) -> String {
        let spaced = raw.replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "-", with: " ")
            .split(separator: " ").joined(separator: " ")
        guard spaced == spaced.lowercased() else { return spaced }
        return spaced.split(separator: " ").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }
}
