import AtlasCore
import Foundation

public struct SearchResult: Identifiable, Hashable, Sendable {
    public var id: String { entry.path }
    public let entry: FileEntry
    public let score: Double
}

/// Metadata search over the Orbit index. Only folders added to Orbit are
/// searched, and nothing is read from the files themselves.
public struct FileSearch: Sendable {
    let store: AtlasStore

    public init(store: AtlasStore) {
        self.store = store
    }

    /// Results, best first. `roots` limits the search (default: every Orbit folder).
    public func search(_ query: SearchQuery, roots: [String]? = nil, limit: Int = 200, now: Date = Date()) throws -> [SearchResult] {
        let locations = try store.locations()
        var scope = roots ?? locations.map(\.path)
        if !query.folders.isEmpty {
            scope = try query.folders.flatMap { try resolveFolder($0, locations: locations) }
                .filter { folder in roots.map { $0.contains { FileLocation.isPath(folder, inside: $0) } } ?? true }
            if scope.isEmpty { return [] }
        }
        guard !scope.isEmpty else { return [] }
        var base = FileQuery(roots: scope, sort: .modifiedDescending, limit: limit)
        query.apply(to: &base, now: now)
        if query.categories == [.folder] { base.kind = .foldersOnly }
        // Location roots themselves aren't results.
        let rootPaths = Set(locations.map(\.path))

        if query.terms.isEmpty {
            return try store.entries(matching: base).filter { !rootPaths.contains($0.path) }
                .map { SearchResult(entry: $0, score: 0) }
        }

        // Every word somewhere in the name first; then letters in order, for typos and abbreviations.
        var candidates: [String: FileEntry] = [:]
        var exact = base
        exact.nameLike = query.terms.map(FileQuery.containsPattern)
        exact.limit = 2_000
        for entry in try store.entries(matching: exact) { candidates[entry.path] = entry }
        if candidates.count < limit {
            var loose = base
            loose.nameLike = query.terms.map(FileQuery.subsequencePattern)
            loose.limit = 5_000
            for entry in try store.entries(matching: loose) where candidates[entry.path] == nil { candidates[entry.path] = entry }
        }
        return candidates.values
            .filter { !rootPaths.contains($0.path) }
            .compactMap { entry in FuzzyMatcher.score(entry.name, terms: query.terms).map { SearchResult(entry: entry, score: $0) } }
            .sorted { $0.score != $1.score ? $0.score > $1.score : ($0.entry.modifiedAt ?? .distantPast) > ($1.entry.modifiedAt ?? .distantPast) }
            .prefix(limit)
            .map { $0 }
    }

    /// `in:` values: a path, an Orbit folder's name, or any indexed folder's name.
    func resolveFolder(_ value: String, locations: [FileLocation]) throws -> [String] {
        if value.hasPrefix("/") || value.hasPrefix("~") { return [FileLocation.normalize(value)] }
        let named = locations.filter { $0.name.caseInsensitiveCompare(value) == .orderedSame }.map(\.path)
        if !named.isEmpty { return named }
        let folders = try store.entries(matching: FileQuery(roots: locations.map(\.path), nameLike: [FileQuery.containsPattern(value)],
                                                            kind: .foldersOnly, sort: .sizeDescending, limit: 20))
        let exact = folders.filter { $0.name.caseInsensitiveCompare(value) == .orderedSame }
        return (exact.isEmpty ? Array(folders.prefix(1)) : exact).map(\.path)
    }
}

/// `file.search`: lets Flow (and later Companion) find files by metadata.
public struct FileSearchAction: AtlasAction {
    public static let id: ActionID = "file.search"
    let search: FileSearch

    public let descriptor = ActionDescriptor(
        id: FileSearchAction.id,
        title: "Find Files",
        summary: "Searches the folders you've added to Orbit by name, type, size and date, e.g. “ext:pdf modified:<30d invoice”.",
        category: "Links & Files",
        symbolName: "magnifyingglass",
        parameters: [
            ParameterSpec(key: "query", label: "Search", kind: .text, help: "e.g. ext:pdf size:>10mb modified:<30d report"),
            ParameterSpec(key: "limit", label: "At most", kind: .number, isRequired: false, defaultValue: 20, minimum: 1, maximum: 500),
        ],
        isIdempotent: true,
        defaultTimeout: 20,
        outputs: [
            OutputSpec(key: "count", label: "Found", type: .number),
            OutputSpec(key: "first", label: "First match", type: .filePath),
            OutputSpec(key: "paths", label: "All matches (one per line)", type: .string),
        ],
        isConcurrencySafe: true
    )

    public init(search: FileSearch) {
        self.search = search
    }

    public func perform(_ parameters: ActionParameters, context: ActionContext) async throws -> ActionOutput {
        let query = SearchQuery.parse(try parameters.requiredString("query"))
        if let problem = query.problems.first { throw ActionError.invalidParameter("Search", reason: problem) }
        let limit = Int(parameters["limit"]?.numberValue ?? 20)
        let results = try search.search(query, limit: limit)
        let paths = results.map(\.entry.path)
        return ActionOutput(
            results.isEmpty ? "No files match “\(query.text)”" : "Found \(results.count) file\(results.count == 1 ? "" : "s")",
            values: ["count": .number(Double(results.count)), "first": .string(paths.first ?? ""),
                     "paths": .string(paths.joined(separator: "\n"))]
        )
    }
}
