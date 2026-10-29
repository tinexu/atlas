import Foundation

/// The folders ATLAS may change files in: exactly the ones the user added
/// to Orbit. Every file action, the folder triggers, Orbit rules and the
/// rule dry-run ask `contains(_:)`, so they can never disagree.
///
/// Paths are compared after expanding `~`, decoding `file://` URLs,
/// standardizing and resolving symlinks (on both sides), component by
/// component, so `~/Downloads2` isn't inside `~/Downloads`, a link inside
/// an added folder can't reach outside it, and `/users/…` matches
/// `/Users/…` on a case-insensitive volume.
public final class FileAccessPolicy: @unchecked Sendable {
    private struct Root {
        let path: String
        let components: [String]
        let caseSensitive: Bool
        let bookmark: Data?
    }

    private let lock = NSLock()
    private var roots: [Root]
    private var scoped: [String: URL] = [:]

    public init(roots: [String] = []) {
        self.roots = roots.map { Self.root($0, bookmark: nil) }
    }

    public convenience init(locations: [FileLocation]) {
        self.init()
        setLocations(locations)
    }

    public func setRoots(_ paths: [String]) {
        let new = paths.map { Self.root($0, bookmark: nil) }
        lock.synchronized { roots = new; scoped = [:] }
    }

    /// The Orbit folders, with their security-scoped bookmarks.
    public func setLocations(_ locations: [FileLocation]) {
        let new = locations.map { Self.root($0.path, bookmark: $0.bookmark) }
        lock.synchronized { roots = new; scoped = [:] }
    }

    public var authorizedRoots: [String] { lock.synchronized { roots.map(\.path) } }

    /// `url` (a file or folder, existing or not) is an added folder or inside one.
    public func contains(_ url: URL) -> Bool {
        root(containing: url) != nil
    }

    public func isAllowed(_ path: String) -> Bool {
        contains(Self.url(path))
    }

    /// Throws a message saying what to do if `path` is outside every added folder.
    public func require(_ path: String, label: String = "File") throws {
        guard isAllowed(path) else {
            throw ActionError.failed(
                "ATLAS only changes files in folders you've added to Orbit, and \(label.lowercased()) \(path.abbreviatedPath) isn't in one. Add its folder in Orbit → Folders, then try again."
            )
        }
    }

    /// Runs `body` with the security-scoped access of every added folder
    /// holding one of `paths` started, and stops it afterwards.
    public func withAccess<T>(to paths: [String], _ body: () async throws -> T) async rethrows -> T {
        var started: [URL] = []
        for path in paths {
            guard let root = root(containing: Self.url(path)), let url = scopedURL(for: root),
                  !started.contains(url), url.startAccessingSecurityScopedResource() else { continue }
            started.append(url)
        }
        defer { started.forEach { $0.stopAccessingSecurityScopedResource() } }
        return try await body()
    }

    private func root(containing url: URL) -> Root? {
        let target = Self.components(Self.canonical(url.path))
        return lock.synchronized { roots.first { Self.isInside(target, $0) } }
    }

    private func scopedURL(for root: Root) -> URL? {
        if let cached = lock.synchronized({ scoped[root.path] }) { return cached }
        guard let bookmark = root.bookmark else { return nil }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope, .withoutUI], relativeTo: nil,
                                 bookmarkDataIsStale: &stale) else { return nil }
        lock.synchronized { scoped[root.path] = url }
        return url
    }

    private static func isInside(_ target: [String], _ root: Root) -> Bool {
        guard target.count >= root.components.count else { return false }
        return zip(target, root.components).allSatisfy { a, b in
            root.caseSensitive ? a == b : a.caseInsensitiveCompare(b) == .orderedSame
        }
    }

    private static func root(_ path: String, bookmark: Data?) -> Root {
        let canonical = canonical(path)
        let sensitive = (try? URL(fileURLWithPath: canonical).resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey]))?
            .volumeSupportsCaseSensitiveNames ?? false
        return Root(path: canonical, components: components(canonical), caseSensitive: sensitive, bookmark: bookmark)
    }

    private static func components(_ path: String) -> [String] {
        URL(fileURLWithPath: path).pathComponents
    }

    /// A file URL for `string`: `~/x`, `/x` or `file:///x%20y` (decoded).
    public static func url(_ string: String) -> URL {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.lowercased().hasPrefix("file:"), let url = URL(string: trimmed), url.isFileURL {
            return url.standardizedFileURL
        }
        return URL(fileURLWithPath: (trimmed as NSString).expandingTildeInPath).standardizedFileURL
    }

    /// The folder to add to Orbit so `path` is allowed: the folder holding
    /// it (or, for a folder, itself), or the nearest one that exists.
    public static func folderToAuthorize(for path: String, isFolder: Bool) -> String {
        var folder = canonical(url(path).path)
        if !isFolder { folder = (folder as NSString).deletingLastPathComponent }
        var isDirectory: ObjCBool = false
        while folder != "/" && !(FileManager.default.fileExists(atPath: folder, isDirectory: &isDirectory) && isDirectory.boolValue) {
            folder = (folder as NSString).deletingLastPathComponent
        }
        return folder
    }

    /// Absolute and standardized, with symlinks resolved as far as the path
    /// exists (the rest may not exist yet, e.g. a destination).
    public static func canonical(_ path: String) -> String {
        let normalized = FileLocation.normalize(path.lowercased().hasPrefix("file:") ? url(path).path : path)
        var existing = normalized
        var rest: [String] = []
        while existing != "/" && !existing.isEmpty {
            if let resolved = realPath(existing) {
                // Normalize the existing part on its own: standardizing drops a
                // leading /private only for paths that exist.
                return ([FileLocation.normalize(resolved)] + rest.reversed()).joined(separator: "/")
                    .replacingOccurrences(of: "//", with: "/")
            }
            rest.append((existing as NSString).lastPathComponent)
            existing = (existing as NSString).deletingLastPathComponent
        }
        return normalized
    }

    private static func realPath(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}

/// Records every file change so it can be undone from Run History.
public final class FileOperationLog: @unchecked Sendable {
    private let store: AtlasStore
    private let events: EventBus

    public init(store: AtlasStore, events: EventBus) {
        self.store = store
        self.events = events
    }

    public func record(_ operation: FileOperation) {
        do {
            try store.logOperation(operation)
            var payload: ActionParameters = ["operationId": .string(operation.id.uuidString), "kind": .string(operation.kind.rawValue),
                                             "path": .string(operation.source)]
            if let runID = operation.runID { payload["runId"] = .string(runID.uuidString) }
            if let destination = operation.destination { payload["destination"] = .string(destination) }
            events.publish(AtlasEvent(AtlasEvent.Name.fileOperationLogged, payload: payload))
        } catch {
            AtlasLog.engine.error("Couldn't record a file change: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Records a change about to happen (no event yet).
    public func begin(_ operation: FileOperation) {
        do {
            try store.logOperation(operation)
        } catch {
            AtlasLog.engine.error("Couldn't record a pending file change: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Forgets a change that failed before anything moved.
    public func discard(_ operation: FileOperation) {
        try? store.deleteOperation(id: operation.id)
    }

    public func operation(id: UUID) -> FileOperation? {
        try? store.operation(id: id)
    }
}

/// What file actions need beyond the system adapter.
public struct FileServices: Sendable {
    public let access: FileAccessPolicy
    public let log: FileOperationLog?

    public init(access: FileAccessPolicy, log: FileOperationLog?) {
        self.access = access
        self.log = log
    }

    /// Allows nothing. Used where no file action should ever run.
    public static var none: FileServices { FileServices(access: FileAccessPolicy(), log: nil) }
}
