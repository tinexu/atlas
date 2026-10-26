import AtlasCore
import CryptoKit
import Foundation

/// Files whose bytes are identical. Never anything merely similar.
public struct DuplicateSet: Identifiable, Hashable, Sendable {
    public var id: String { hash }
    /// Full SHA-256 of the contents.
    public let hash: String
    public let size: Int64
    /// Oldest first (by creation, then modification).
    public let files: [FileEntry]

    public init(hash: String, size: Int64, files: [FileEntry]) {
        self.hash = hash
        self.size = size
        self.files = files
    }

    /// Space freed by keeping one copy.
    public var recoverable: Int64 { size * Int64(max(0, files.count - 1)) }
    public var oldest: FileEntry? { files.first }
    public var newest: FileEntry? { files.last }
}

/// Exact duplicate detection (spec 6): group by size, then compare the
/// first and last 64 KB, then a full SHA-256 of what's still a candidate.
/// Hard links to the same file count once, since removing one frees nothing.
public final class DuplicateFinder: @unchecked Sendable {
    public struct Progress: Sendable, Equatable {
        public var checked: Int
        public var total: Int
        public var phase: String

        public init(checked: Int, total: Int, phase: String) {
            self.checked = checked
            self.total = total
            self.phase = phase
        }
    }

    private let store: AtlasStore
    private let events: EventBus
    public static let partialChunk = 64 * 1024

    public init(store: AtlasStore, events: EventBus) {
        self.store = store
        self.events = events
    }

    /// Scans files of at least `minimumSize` bytes under `roots` (default:
    /// every Orbit folder). Cancel the task to stop; partial results are discarded.
    public func find(minimumSize: Int64 = 1, roots: [String]? = nil,
                     progress: (@Sendable (Progress) -> Void)? = nil) async throws -> [DuplicateSet] {
        let scope = try roots ?? store.locations().map(\.path)
        guard !scope.isEmpty else { return [] }
        let sizes = try store.duplicateSizeCandidates(minimumSize: max(1, minimumSize), roots: scope)
        let total = sizes.reduce(0) { $0 + $1.count }
        var checked = 0
        var results: [DuplicateSet] = []

        for (size, _) in sizes {
            try Task.checkCancellation()
            let files = try store.files(ofSize: size, roots: scope)
            checked += files.count
            progress?(Progress(checked: checked, total: total, phase: "Comparing files"))

            // Same file reached by two names (hard links): keep one.
            var byInode: [String: FileEntry] = [:]
            var unique: [FileEntry] = []
            for file in files {
                if let key = Self.identity(of: file.path) {
                    if byInode[key] != nil { continue }
                    byInode[key] = file
                }
                unique.append(file)
            }
            guard unique.count > 1 else { continue }

            let partial = Dictionary(grouping: unique) { Self.partialHash(of: $0.path, size: size) }
            for (key, group) in partial where key != nil && group.count > 1 {
                try Task.checkCancellation()
                let full = Dictionary(grouping: group) { Self.fullHash(of: $0.path) }
                for (hash, same) in full {
                    guard let hash, same.count > 1 else { continue }
                    let ordered = same.sorted {
                        ($0.createdAt ?? $0.modifiedAt ?? .distantFuture) < ($1.createdAt ?? $1.modifiedAt ?? .distantFuture)
                    }
                    results.append(DuplicateSet(hash: hash, size: size, files: ordered))
                }
            }
        }
        results.sort { $0.recoverable > $1.recoverable }
        events.publish(AtlasEvent(AtlasEvent.Name.duplicatesFound, payload: [
            "sets": .number(Double(results.count)),
            "recoverableBytes": .number(Double(results.reduce(0) { $0 + $1.recoverable })),
        ]))
        return results
    }

    /// Device and inode, so two paths to one file are recognised.
    static func identity(of path: String) -> String? {
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        return "\(info.st_dev):\(info.st_ino)"
    }

    /// SHA-256 of the first and last 64 KB (all of it for small files).
    static func partialHash(of path: String, size: Int64) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        do {
            if let head = try handle.read(upToCount: partialChunk) { hasher.update(data: head) }
            if size > Int64(partialChunk * 2) {
                try handle.seek(toOffset: UInt64(size - Int64(partialChunk)))
                if let tail = try handle.read(upToCount: partialChunk) { hasher.update(data: tail) }
            } else if size > Int64(partialChunk) {
                if let rest = try handle.readToEnd() { hasher.update(data: rest) }
            }
        } catch {
            return nil
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// SHA-256 of the whole file, read in 1 MB pieces.
    static func fullHash(of path: String) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        do {
            while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
                if Task.isCancelled { return nil }
                hasher.update(data: chunk)
            }
        } catch {
            return nil
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
