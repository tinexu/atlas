import AtlasCore
import Darwin
import Foundation

/// What the indexer leaves out. Packages (.app, .photoslibrary…) are always
/// indexed as single files, never walked into.
public struct IndexExclusions: Sendable, Equatable {
    public var includeHidden = false
    public var excludedNames: Set<String> = [".git", "node_modules", ".build", ".Trash", "DerivedData", "Pods"]
    public var excludedPathFragments: [String] = ["/Library/Caches/", "/Library/Logs/"]

    public init() {}

    /// Whether `path` (inside `root`) should be skipped.
    public func isExcluded(_ path: String, root: String) -> Bool {
        guard path != root else { return false }
        let relative = path.hasPrefix(root + "/") ? String(path.dropFirst(root.count + 1)) : path
        for component in relative.split(separator: "/") {
            if !includeHidden && component.hasPrefix(".") { return true }
            if excludedNames.contains(String(component)) { return true }
        }
        return excludedPathFragments.contains { (path + "/").contains($0) }
    }
}

/// Builds and maintains the file index for the folders added to Orbit.
///
/// - The first walk of a folder streams through it at utility priority,
///   writing batches in transactions, so memory stays flat even for
///   hundreds of thousands of files. Folder sizes are added up on the way.
/// - After that, FSEvents changes update only what changed, and publish
///   `file.created`, `file.modified`, `file.moved` and `file.deleted`.
/// - At every launch each folder is walked again to catch what changed
///   while ATLAS wasn't running; an interrupted walk simply starts over.
/// - Pausing stops the walk at the next file. Nothing here changes files.
public final class FileIndexer: @unchecked Sendable {
    public struct Progress: Sendable, Equatable {
        public enum Phase: String, Sendable { case queued, walking, finishing, paused, idle }
        public var locationID: UUID
        public var name: String
        public var files: Int
        public var phase: Phase

        public var isActive: Bool { phase == .queued || phase == .walking || phase == .finishing }

        public var description: String {
            switch phase {
            case .queued: return "Waiting to index \(name)…"
            case .walking: return "Indexing \(name)… \(files.formatted()) files"
            case .finishing: return "Finishing \(name)… \(files.formatted()) files"
            case .paused: return "Indexing \(name) is paused"
            case .idle: return "\(name): \(files.formatted()) files"
            }
        }
    }

    private let store: AtlasStore
    private let events: EventBus
    private let watcher: FileTreeWatching?
    private let queue = DispatchQueue(label: "atlas.orbit.indexer", qos: .utility)
    private let lock = NSLock()
    private var tokens: [UUID: TriggerToken] = [:]
    private var progress: [UUID: Progress] = [:]
    private var paused = false
    private var walkWanted: Set<UUID> = []

    public var exclusions = IndexExclusions()
    /// Entries per transaction.
    public var batchSize = 500
    /// Pause between batches, to keep the walk gentle on the CPU.
    public var throttle: TimeInterval = 0.002
    /// Called (on the indexer's queue) whenever progress changes.
    public var onProgress: (@Sendable ([UUID: Progress]) -> Void)?
    /// Called after changes were applied, with the paths affected.
    public var onChange: (@Sendable ([String]) -> Void)?

    public init(store: AtlasStore, events: EventBus, watcher: FileTreeWatching?) {
        self.store = store
        self.events = events
        self.watcher = watcher
    }

    // MARK: - Control

    /// Watches every location and re-walks each to catch up on changes made
    /// while ATLAS wasn't running.
    public func start() {
        for location in (try? store.locations()) ?? [] {
            watch(location)
            index(locationID: location.id)
        }
    }

    public func stop() {
        let all = lock.withLock { () -> [TriggerToken] in
            defer { tokens = [:] }
            return Array(tokens.values)
        }
        all.forEach { $0.cancel() }
    }

    public var isPaused: Bool { lock.withLock { paused } }

    /// Stops walking at the next file; resuming walks the paused folders again.
    public func setPaused(_ value: Bool) {
        let resume = lock.withLock { () -> [UUID] in
            paused = value
            return value ? [] : progress.values.filter { $0.phase == .paused }.map(\.locationID)
        }
        resume.forEach { index(locationID: $0) }
        publishProgress()
    }

    public var currentProgress: [UUID: Progress] { lock.withLock { progress } }

    /// Queues a full walk of a location.
    public func index(locationID: UUID) {
        guard let location = try? store.location(id: locationID) else { return }
        let alreadyQueued = lock.withLock { () -> Bool in
            defer { walkWanted.insert(locationID) }
            if walkWanted.contains(locationID) { return true }
            progress[locationID] = Progress(locationID: locationID, name: location.name, files: progress[locationID]?.files ?? 0,
                                            phase: paused ? .paused : .queued)
            return false
        }
        publishProgress()
        guard !alreadyQueued else { return }
        queue.async { [weak self] in self?.walk(locationID) }
    }

    /// Starts watching a location for changes.
    public func watch(_ location: FileLocation) {
        guard let watcher, lock.withLock({ tokens[location.id] == nil }) else { return }
        do {
            let token = try watcher.watchTree(location.path) { [weak self] changes in
                self?.queue.async { self?.apply(changes, locationID: location.id) }
            }
            lock.withLock { tokens[location.id] = token }
        } catch {
            AtlasLog.engine.error("Orbit couldn't watch \(location.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Stops watching and forgets progress; the caller deletes the index.
    public func forget(locationID: UUID) {
        let token = lock.withLock { () -> TriggerToken? in
            progress[locationID] = nil
            walkWanted.remove(locationID)
            return tokens.removeValue(forKey: locationID)
        }
        token?.cancel()
        publishProgress()
    }

    /// Waits until queued work has finished (tests, and before reading counts).
    public func waitUntilIdle() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async { continuation.resume() }
        }
    }

    // MARK: - Full walk

    private func setPhase(_ id: UUID, _ phase: Progress.Phase, files: Int? = nil) {
        lock.withLock {
            guard var p = progress[id] else { return }
            p.phase = phase
            if let files { p.files = files }
            progress[id] = p
        }
        publishProgress()
    }

    private func publishProgress() {
        onProgress?(currentProgress)
    }

    private struct FolderTotal {
        let path: String
        var size: Int64 = 0
        var count = 0
    }

    private func walk(_ locationID: UUID) {
        guard lock.withLock({ walkWanted.remove(locationID) != nil }) else { return }
        guard var location = try? store.location(id: locationID) else { return }
        if lock.withLock({ paused }) {
            setPhase(locationID, .paused)
            return
        }
        let root = location.path
        guard FileManager.default.fileExists(atPath: root) else {
            location.indexState = .unavailable
            try? store.saveLocation(location)
            setPhase(locationID, .idle)
            return
        }
        let generation = location.scanGeneration + 1
        location.indexState = .indexing
        try? store.saveLocation(location)
        setPhase(locationID, .walking, files: 0)

        var batch: [FileEntry] = []
        var totals: [(path: String, size: Int64, count: Int)] = []
        var stack: [FolderTotal] = []
        var files = 0
        var interrupted = false

        func flush() {
            do {
                try store.upsertEntries(batch, generation: generation)
                try store.setFolderTotals(totals)
            } catch {
                AtlasLog.persistence.error("Orbit index write failed: \(error.localizedDescription, privacy: .public)")
            }
            batch.removeAll(keepingCapacity: true)
            totals.removeAll(keepingCapacity: true)
            if throttle > 0 { Thread.sleep(forTimeInterval: throttle) }
        }

        func close(until parent: String) {
            while let top = stack.last, top.path != parent, !FileLocation.isPath(parent, inside: top.path) {
                stack.removeLast()
                totals.append((top.path, top.size, top.count))
                if !stack.isEmpty {
                    stack[stack.count - 1].size += top.size
                    stack[stack.count - 1].count += top.count
                }
            }
        }

        if let rootEntry = Self.makeEntry(path: root, locationID: locationID) {
            batch.append(rootEntry)
        }
        stack.append(FolderTotal(path: root))

        let keys: [URLResourceKey] = Self.resourceKeys
        var options: FileManager.DirectoryEnumerationOptions = [.skipsPackageDescendants]
        if !exclusions.includeHidden { options.insert(.skipsHiddenFiles) }
        let enumerator = FileManager.default.enumerator(at: URL(fileURLWithPath: root, isDirectory: true),
                                                        includingPropertiesForKeys: keys, options: options) { _, _ in true }
        while let url = enumerator?.nextObject() as? URL {
            if lock.withLock({ paused || walkWanted.contains(locationID) }) {
                interrupted = true
                break
            }
            let path = FileLocation.normalize(url.path)
            if exclusions.isExcluded(path, root: root) {
                enumerator?.skipDescendants()
                continue
            }
            guard let entry = Self.makeEntry(url: url, path: path, locationID: locationID) else { continue }
            close(until: entry.parent)
            batch.append(entry)
            if entry.isFolder {
                stack.append(FolderTotal(path: path))
            } else if !stack.isEmpty {
                stack[stack.count - 1].size += entry.size
                stack[stack.count - 1].count += 1
                files += 1
            }
            if batch.count >= batchSize {
                flush()
                lock.withLock { progress[locationID]?.files = files }
                if files % 2_000 < batchSize {
                    publishProgress()
                    events.publish(AtlasEvent(AtlasEvent.Name.indexProgress, payload: [
                        "locationId": .string(locationID.uuidString), "name": .string(location.name),
                        "files": .number(Double(files)), "phase": .string("walking"),
                    ]))
                }
            }
        }

        if interrupted {
            flush()
            location.indexState = .paused
            try? store.saveLocation(location)
            let isPaused = lock.withLock { paused }
            setPhase(locationID, isPaused ? .paused : .queued, files: files)
            if !isPaused { queue.async { [weak self] in self?.walk(locationID) } }
            return
        }

        setPhase(locationID, .finishing, files: files)
        close(until: "")
        flush()
        let removed = (try? store.removeUnseenEntries(locationID: locationID, generation: generation)) ?? 0
        let rootEntry = try? store.entry(at: root)
        location.scanGeneration = generation
        location.indexState = .complete
        location.lastIndexedAt = Date()
        location.fileCount = rootEntry?.itemCount ?? files
        location.totalSize = rootEntry?.size ?? 0
        try? store.saveLocation(location)
        setPhase(locationID, .idle, files: location.fileCount)
        events.publish(AtlasEvent(AtlasEvent.Name.indexCompleted, payload: [
            "locationId": .string(locationID.uuidString), "name": .string(location.name),
            "files": .number(Double(location.fileCount)), "bytes": .number(Double(location.totalSize)),
            "removed": .number(Double(removed)),
        ]))
        onChange?([root])
    }

    // MARK: - Incremental updates

    /// Applies FSEvents changes for one location. Internal so tests can call it.
    func apply(_ changes: [FileChange], locationID: UUID) {
        guard let location = try? store.location(id: locationID) else { return }
        if lock.withLock({ walkWanted.contains(locationID) }) { return }  // A full walk is coming anyway.
        let root = location.path
        if changes.contains(where: { $0.kind == .rescan }) {
            index(locationID: locationID)
            return
        }

        // Last word per path wins; skip excluded paths and package insides.
        var latest: [String: FileChange] = [:]
        var order: [String] = []
        for change in changes {
            var path = FileLocation.normalize(change.path)
            guard FileLocation.isPath(path, inside: root), path != root, !exclusions.isExcluded(path, root: root) else { continue }
            if let package = Self.enclosingPackage(of: path, root: root) { path = package }
            if latest[path] == nil { order.append(path) }
            latest[path] = change
        }

        var gone: [String: FileEntry] = [:]         // path → old entry
        var present: [(String, FileEntry)] = []      // path → fresh entry
        for path in order {
            let indexed = try? store.entry(at: path)
            if let fresh = Self.makeEntry(path: path, locationID: locationID) {
                present.append((path, fresh))
            } else if let indexed {
                gone[path] = indexed
            }
        }

        var affected: [String] = []
        for (path, fresh) in present {
            let indexed = try? store.entry(at: path)
            if let indexed {
                // Changed in place.
                guard !fresh.isFolder else { continue }
                guard indexed.size != fresh.size || indexed.modifiedAt != fresh.modifiedAt else { continue }
                try? store.upsertEntries([fresh], generation: location.scanGeneration)
                try? store.adjustAncestors(of: path, root: root, sizeDelta: fresh.size - indexed.size, countDelta: 0)
                publish(AtlasEvent.Name.fileModifiedEvent, path: path, locationID: locationID)
                affected.append(path)
            } else if let inode = fresh.inode, let moved = Self.match(inode: inode, in: gone) ?? lookupMoved(inode: inode, excluding: path) {
                // Moved or renamed (maybe from another Orbit folder).
                let (oldPath, old) = moved
                gone[oldPath] = nil
                if let oldLocation = try? store.location(id: old.locationID) {
                    try? store.adjustAncestors(of: oldPath, root: oldLocation.path, sizeDelta: -old.size,
                                               countDelta: -(old.isFolder ? old.itemCount : 1))
                }
                try? store.moveEntries(from: oldPath, to: path, locationID: locationID)
                try? store.upsertEntries([fresh.isFolder ? Self.keepingTotals(fresh, from: old) : fresh], generation: location.scanGeneration)
                try? store.adjustAncestors(of: path, root: root, sizeDelta: old.isFolder ? old.size : fresh.size,
                                           countDelta: old.isFolder ? old.itemCount : 1)
                try? store.repointLinks(from: oldPath, to: path)
                publish(AtlasEvent.Name.fileMovedEvent, path: path, locationID: locationID, extra: ["oldPath": .string(oldPath)])
                affected += [oldPath, path]
            } else {
                // New here.
                let (size, count) = fresh.isFolder ? indexSubtree(path, location: location) : (fresh.size, 1)
                if !fresh.isFolder { try? store.upsertEntries([fresh], generation: location.scanGeneration) }
                try? store.adjustAncestors(of: path, root: root, sizeDelta: size, countDelta: count)
                publish(AtlasEvent.Name.fileCreatedEvent, path: path, locationID: locationID)
                affected.append(path)
            }
        }

        for (path, old) in gone {
            try? store.deleteEntries(at: path)
            try? store.adjustAncestors(of: path, root: root, sizeDelta: -old.size, countDelta: -(old.isFolder ? old.itemCount : 1))
            try? store.markLinksBroken(at: path)
            publish(AtlasEvent.Name.fileDeletedEvent, path: path, locationID: locationID)
            affected.append(path)
        }

        guard !affected.isEmpty else { return }
        refreshStats(locationID)
        onChange?(affected)
    }

    /// A just-removed entry elsewhere in the index with this inode, for moves
    /// whose old path was reported in an earlier batch or another folder.
    private func lookupMoved(inode: UInt64, excluding path: String) -> (String, FileEntry)? {
        for candidate in (try? store.entries(withInode: inode)) ?? [] where candidate.path != path {
            if !FileManager.default.fileExists(atPath: candidate.path) { return (candidate.path, candidate) }
        }
        return nil
    }

    private static func match(inode: UInt64, in gone: [String: FileEntry]) -> (String, FileEntry)? {
        gone.first { $0.value.inode == inode }.map { ($0.key, $0.value) }
    }

    private static func keepingTotals(_ entry: FileEntry, from old: FileEntry) -> FileEntry {
        var copy = entry
        copy.size = old.size
        copy.itemCount = old.itemCount
        return copy
    }

    /// Indexes a folder that appeared, returning its size and file count.
    private func indexSubtree(_ path: String, location: FileLocation) -> (Int64, Int) {
        var size: Int64 = 0
        var count = 0
        var batch: [FileEntry] = []
        var folders: [String] = [path]
        if let entry = Self.makeEntry(path: path, locationID: location.id) { batch.append(entry) }
        var options: FileManager.DirectoryEnumerationOptions = [.skipsPackageDescendants]
        if !exclusions.includeHidden { options.insert(.skipsHiddenFiles) }
        let enumerator = FileManager.default.enumerator(at: URL(fileURLWithPath: path, isDirectory: true),
                                                        includingPropertiesForKeys: Self.resourceKeys, options: options)
        while let url = enumerator?.nextObject() as? URL {
            let child = FileLocation.normalize(url.path)
            if exclusions.isExcluded(child, root: location.path) { enumerator?.skipDescendants(); continue }
            guard let entry = Self.makeEntry(url: url, path: child, locationID: location.id) else { continue }
            batch.append(entry)
            if entry.isFolder { folders.append(child) } else { size += entry.size; count += 1 }
            if batch.count >= batchSize {
                try? store.upsertEntries(batch, generation: location.scanGeneration)
                batch.removeAll(keepingCapacity: true)
            }
        }
        try? store.upsertEntries(batch, generation: location.scanGeneration)
        // Totals for the new folders, deepest first.
        for folder in folders.reversed() {
            let children = (try? store.entries(matching: FileQuery(parent: folder, limit: 1_000_000))) ?? []
            let s = children.reduce(Int64(0)) { $0 + $1.size }
            let c = children.reduce(0) { $0 + ($1.isFolder ? $1.itemCount : 1) }
            try? store.setFolderTotals([(folder, s, c)])
        }
        return (size, count)
    }

    private func refreshStats(_ locationID: UUID) {
        guard var location = try? store.location(id: locationID), let root = try? store.entry(at: location.path) else { return }
        location.fileCount = root.itemCount
        location.totalSize = root.size
        try? store.saveLocation(location)
    }

    private func publish(_ name: String, path: String, locationID: UUID, extra: ActionParameters = [:]) {
        var payload: ActionParameters = ["path": .string(path), "locationId": .string(locationID.uuidString)]
        payload.merge(extra) { $1 }
        events.publish(AtlasEvent(name, payload: payload))
    }

    // MARK: - Reading one item

    static let resourceKeys: [URLResourceKey] = [
        .isDirectoryKey, .isPackageKey, .isSymbolicLinkKey, .fileSizeKey, .totalFileSizeKey, .creationDateKey,
        .contentModificationDateKey, .contentAccessDateKey, .typeIdentifierKey,
    ]

    static let packageExtensions: Set<String> = ["app", "photoslibrary", "bundle", "framework", "xcodeproj", "xcworkspace",
                                                 "playground", "rtfd", "pages", "numbers", "key", "musiclibrary", "fcpbundle"]

    /// The outermost package containing `path`, below `root`.
    static func enclosingPackage(of path: String, root: String) -> String? {
        var current = (path as NSString).deletingLastPathComponent
        var found: String?
        while current.count > root.count, FileLocation.isPath(current, inside: root) {
            if packageExtensions.contains((current as NSString).pathExtension.lowercased()) { found = current }
            current = (current as NSString).deletingLastPathComponent
        }
        return found
    }

    static func makeEntry(path: String, locationID: UUID) -> FileEntry? {
        makeEntry(url: URL(fileURLWithPath: path), path: path, locationID: locationID)
    }

    static func makeEntry(url: URL, path: String, locationID: UUID) -> FileEntry? {
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        if (info.st_mode & S_IFMT) == S_IFLNK { return nil }  // Never follow links out of the folder.
        let values = try? url.resourceValues(forKeys: Set(resourceKeys))
        let isDirectory = (info.st_mode & S_IFMT) == S_IFDIR
        let isPackage = isDirectory && (values?.isPackage ?? packageExtensions.contains(url.pathExtension.lowercased()))
        let size: Int64
        if isPackage {
            size = packageSize(url)
        } else if isDirectory {
            size = 0
        } else {
            size = Int64(values?.totalFileSize ?? values?.fileSize ?? Int(info.st_size))
        }
        return FileEntry(
            path: path, locationID: locationID, typeIdentifier: values?.typeIdentifier, size: size,
            itemCount: isDirectory && !isPackage ? 0 : 1,
            createdAt: values?.creationDate, modifiedAt: values?.contentModificationDate, accessedAt: values?.contentAccessDate,
            isDirectory: isDirectory, isPackage: isPackage, inode: UInt64(info.st_ino)
        )
    }

    /// Everything inside a package, which is shown as one file.
    static func packageSize(_ url: URL) -> Int64 {
        var total: Int64 = 0
        let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.totalFileSizeKey, .fileSizeKey])
        while let item = enumerator?.nextObject() as? URL {
            let values = try? item.resourceValues(forKeys: [.totalFileSizeKey, .fileSizeKey])
            total += Int64(values?.totalFileSize ?? values?.fileSize ?? 0)
        }
        return total
    }
}
