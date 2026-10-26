import AtlasCore
import Foundation

public enum LocationError: Error, LocalizedError, Equatable {
    case alreadyAdded(String)
    case insideExisting(String)
    case notAFolder(String)
    case tooBroad(String)

    public var errorDescription: String? {
        switch self {
        case .alreadyAdded(let name): return "\(name) is already in Orbit."
        case .insideExisting(let name): return "That folder is already included, inside \(name)."
        case .notAFolder(let path): return "\(path.abbreviatedPath) isn't a folder."
        case .tooBroad(let path):
            return "Orbit doesn't index \(path.abbreviatedPath) as a whole. Add the folders inside it you want, like Documents or Downloads."
        }
    }
}

/// The folders the user authorized (spec 1). Each is stored with a
/// security-scoped bookmark so access survives relaunches, and adding or
/// removing one updates which paths file actions may touch.
public final class LocationManager: @unchecked Sendable {
    private let core: AtlasCore
    private let indexer: FileIndexer
    private let lock = NSLock()
    private var accessing: [UUID: URL] = [:]

    public init(core: AtlasCore, indexer: FileIndexer) {
        self.core = core
        self.indexer = indexer
    }

    public func locations() -> [FileLocation] {
        (try? core.store.locations()) ?? []
    }

    /// Downloads, Documents and Desktop, if not added yet. Each still needs
    /// the user to pick it once (and macOS asks once per folder).
    public var suggestions: [(name: String, path: String)] {
        let added = Set(locations().map(\.path))
        return [("Downloads", "~/Downloads"), ("Documents", "~/Documents"), ("Desktop", "~/Desktop")]
            .map { ($0.0, FileLocation.normalize($0.1)) }
            .filter { suggestion in !added.contains(suggestion.1) && !locations().contains { $0.contains(suggestion.1) } }
    }

    private static let tooBroad: Set<String> = ["/", "/System", "/Library", "/Applications", "/Users", "/Volumes", "/private",
                                                "/usr", "/bin", "/sbin", "/opt", "/cores", "/dev"]

    /// Adds a folder the user picked. A folder that contains already-added
    /// ones replaces them.
    @discardableResult
    public func add(_ url: URL) throws -> FileLocation {
        let path = FileLocation.normalize(url.path)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw LocationError.notAFolder(path)
        }
        if Self.tooBroad.contains(path) || path == FileLocation.normalize(NSHomeDirectory() + "/Library") {
            throw LocationError.tooBroad(path)
        }
        let existing = locations()
        if let same = existing.first(where: { $0.path == path }) { throw LocationError.alreadyAdded(same.name) }
        if let parent = existing.first(where: { $0.contains(path) }) { throw LocationError.insideExisting(parent.name) }
        for child in existing where FileLocation.isPath(child.path, inside: path) {
            remove(child.id)
        }
        let location = FileLocation(path: path, bookmark: Self.bookmark(for: url))
        try core.store.saveLocation(location)
        core.refreshFileAccess()
        startAccessing(location)
        indexer.watch(location)
        indexer.index(locationID: location.id)
        return location
    }

    /// Removes a folder and deletes its index. Files themselves are untouched.
    public func remove(_ id: UUID) {
        indexer.forget(locationID: id)
        try? core.store.deleteLocation(id: id)
        core.refreshFileAccess()
        let url = lock.withLock { accessing.removeValue(forKey: id) }
        url?.stopAccessingSecurityScopedResource()
    }

    /// At launch: resolve each bookmark, follow folders that moved, and
    /// refresh stale bookmarks. A folder that's gone is marked unavailable.
    public func resolveBookmarks() {
        for var location in locations() {
            guard let data = location.bookmark else { continue }
            var stale = false
            guard let url = (try? URL(resolvingBookmarkData: data, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &stale))
                ?? (try? URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &stale))
            else {
                location.indexState = .unavailable
                try? core.store.saveLocation(location)
                continue
            }
            let resolved = FileLocation.normalize(url.path)
            var changed = false
            if resolved != location.path, !locations().contains(where: { $0.id != location.id && $0.path == resolved }) {
                try? core.store.deleteLocation(id: location.id)   // old index paths are wrong now
                location.path = resolved
                location.name = FileLocation.displayName(for: resolved)
                location.scanGeneration = 0
                changed = true
            }
            if stale { location.bookmark = Self.bookmark(for: url) ?? location.bookmark; changed = true }
            if changed { try? core.store.saveLocation(location) }
            startAccessing(location, url: url)
        }
        core.refreshFileAccess()
    }

    private func startAccessing(_ location: FileLocation, url: URL? = nil) {
        let target = url ?? URL(fileURLWithPath: location.path, isDirectory: true)
        // Returns false outside the sandbox, where access needs no scope.
        if target.startAccessingSecurityScopedResource() {
            lock.withLock { accessing[location.id] = target }
        }
    }

    static func bookmark(for url: URL) -> Data? {
        (try? url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil))
            ?? (try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil))
    }
}
