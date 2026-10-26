import Foundation

/// The folders ATLAS may change files in: exactly the ones the user added
/// to Orbit. File actions check every path against this before touching
/// anything, after resolving symlinks, so a link inside an added folder
/// can't reach outside it.
public final class FileAccessPolicy: @unchecked Sendable {
    private let lock = NSLock()
    private var roots: [String]

    public init(roots: [String] = []) {
        self.roots = roots.map(Self.canonical)
    }

    public func setRoots(_ paths: [String]) {
        let canonical = paths.map(Self.canonical)
        lock.synchronized { roots = canonical }
    }

    public var authorizedRoots: [String] { lock.synchronized { roots } }

    public func isAllowed(_ path: String) -> Bool {
        let target = Self.canonical(path)
        return lock.synchronized { roots.contains { FileLocation.isPath(target, inside: $0) } }
    }

    /// Throws a message saying what to do if `path` is outside every added folder.
    public func require(_ path: String, label: String = "File") throws {
        guard isAllowed(path) else {
            throw ActionError.failed(
                "ATLAS only changes files in folders you've added to Orbit, and \(label.lowercased()) \(path.abbreviatedPath) isn't in one. Add its folder in Orbit → Folders, then try again."
            )
        }
    }

    /// Absolute and standardized, with symlinks resolved as far as the path
    /// exists (the rest may not exist yet, e.g. a destination).
    public static func canonical(_ path: String) -> String {
        let normalized = FileLocation.normalize(path)
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
