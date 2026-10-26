import Foundation

/// Reports changes anywhere inside a folder, so the Orbit index stays up to
/// date. Behind a protocol so tests can deliver changes by hand.
public protocol FileTreeWatching: Sendable {
    /// Changes inside `path` at any depth, coalesced over about a second.
    /// A `.rescan` change means "look at everything under this path again".
    func watchTree(_ path: String, _ handler: @escaping @Sendable ([FileChange]) -> Void) throws -> TriggerToken
}

#if os(macOS)
/// FSEvents, at utility priority with a one-second latency to keep the
/// cost of busy folders low.
public struct MacFileTreeWatcher: FileTreeWatching {
    public init() {}

    public func watchTree(_ path: String, _ handler: @escaping @Sendable ([FileChange]) -> Void) throws -> TriggerToken {
        let watcher = FolderWatcher(path: path, recursive: true, latency: 1.0, qos: .utility, handler: handler)
        guard watcher.start() else { throw TriggerError("ATLAS couldn't watch “\(path)” for changes.") }
        return TriggerToken { watcher.stop() }
    }
}
#endif
