import Foundation

// File actions (Stage 04, tightened in Stage 05). All declare Files &
// Folders access and that they change files, refuse any path outside the
// folders added to Orbit, never overwrite anything, and record what they
// did so Run History can undo it. Nothing here deletes: removing a file
// means moving it to the Trash, and that asks for confirmation each time.

enum FilePaths {
    /// `folder/name`, or `folder/name (2).ext`, `… (3).ext` if taken, so
    /// nothing is ever overwritten.
    static func available(_ name: String, in folder: String, system: SystemAdapter) -> String {
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var candidate = (folder as NSString).appendingPathComponent(name)
        var n = 2
        while system.fileKind(atPath: candidate) != .missing {
            let numbered = ext.isEmpty ? "\(base) (\(n))" : "\(base) (\(n)).\(ext)"
            candidate = (folder as NSString).appendingPathComponent(numbered)
            n += 1
        }
        return candidate
    }

    /// Where an item called `name` would go in `folder`, or nil to skip
    /// because the name is taken and the mode says skip.
    static func destination(_ name: String, in folder: String, mode: ConflictMode, system: SystemAdapter) -> String? {
        let direct = (folder as NSString).appendingPathComponent(name)
        if system.fileKind(atPath: direct) == .missing { return direct }
        return mode == .skip ? nil : available(name, in: folder, system: system)
    }

    static func requireExisting(_ path: String, system: SystemAdapter) throws {
        guard system.fileKind(atPath: path) != .missing else {
            throw ActionError.failed("Nothing exists at \(path). It may have been moved or renamed.")
        }
    }

    static func outputs(_ path: String, skipped: Bool = false) -> ActionParameters {
        [
            "path": .string(path),
            "fileName": .string((path as NSString).lastPathComponent),
            "folder": .string((path as NSString).deletingLastPathComponent),
            "skipped": .bool(skipped),
        ]
    }

    static let outputSpecs = [
        OutputSpec(key: "path", label: "New path", type: .filePath),
        OutputSpec(key: "fileName", label: "File name", type: .string),
        OutputSpec(key: "folder", label: "Folder", type: .filePath),
        OutputSpec(key: "skipped", label: "Skipped (name taken)", type: .bool),
    ]

    static let ifExistsSpec = ParameterSpec(
        key: "ifExists", label: "If the name is taken", kind: .text, isRequired: false, defaultValue: "addNumber",
        options: ConflictMode.allCases.map(\.rawValue)
    )

    static func conflictMode(_ parameters: ActionParameters) -> ConflictMode {
        parameters["ifExists"]?.stringValue.flatMap(ConflictMode.init(rawValue:)) ?? .addNumber
    }
}

extension ActionContext {
    /// Records a file change for undo.
    func log(_ kind: FileOperation.Kind, _ source: String, to destination: String? = nil, extra: [String: String] = [:]) {
        files.log?.record(FileOperation(runID: runID, kind: kind, source: source, destination: destination, extra: extra))
    }

    /// Writes the change as pending, makes it, then marks it done; if it
    /// fails the record is dropped. A change cut short by a crash stays
    /// pending and is settled on the next launch (`FileOperationRecovery`).
    func journaled(_ kind: FileOperation.Kind, _ source: String, to destination: String?,
                   _ change: () async throws -> String?) async throws -> String? {
        var operation = FileOperation(runID: runID, kind: kind, source: source, destination: destination, state: .pending)
        files.log?.begin(operation)
        do {
            let result = try await change()
            operation.destination = result ?? destination
            operation.state = .done
            files.log?.record(operation)
            return result
        } catch {
            files.log?.discard(operation)
            throw error
        }
    }
}

public struct MoveFileAction: AtlasAction {
    public static let id: ActionID = "file.move"

    public let descriptor = ActionDescriptor(
        id: MoveFileAction.id,
        title: "Move File",
        summary: "Moves a file or folder into another folder. If the name is taken there, adds a number or skips it, never replacing anything.",
        category: "Links & Files",
        symbolName: "folder.badge.plus",
        parameters: [
            ParameterSpec(key: "path", label: "File", kind: .filePath),
            ParameterSpec(key: "destination", label: "To folder", kind: .folderPath),
            ParameterSpec(key: "createFolder", label: "Create the folder if needed", kind: .boolean,
                          isRequired: false, defaultValue: true),
            FilePaths.ifExistsSpec,
        ],
        permissions: [.fileAccess],
        sideEffects: [.modifiesFiles],
        // A retry after a partial move could move a different file with the same name.
        isIdempotent: false,
        defaultTimeout: 30,
        outputs: FilePaths.outputSpecs
    )

    public init() {}

    public func perform(_ parameters: ActionParameters, context: ActionContext) async throws -> ActionOutput {
        let path = try parameters.path("path")
        let folder = try parameters.path("destination")
        try context.files.access.require(path)
        try context.files.access.require(folder, label: "Folder")
        try FilePaths.requireExisting(path, system: context.system)
        switch context.system.fileKind(atPath: folder) {
        case .file:
            throw ActionError.failed("\(folder) is a file, not a folder.")
        case .missing:
            guard parameters["createFolder"]?.boolValue ?? true else {
                throw ActionError.failed("The folder \(folder) doesn't exist.")
            }
            try await context.system.createFolder(atPath: folder)
            context.log(.createFolder, folder)
        case .directory:
            break
        }
        let name = (path as NSString).lastPathComponent
        if (path as NSString).deletingLastPathComponent == FileLocation.normalize(folder) {
            return ActionOutput("\(name) is already in \((folder as NSString).lastPathComponent)", values: FilePaths.outputs(path))
        }
        guard let destination = FilePaths.destination(name, in: folder, mode: FilePaths.conflictMode(parameters), system: context.system) else {
            return ActionOutput("Skipped \(name): \((folder as NSString).lastPathComponent) already has a file with that name",
                                values: FilePaths.outputs(path, skipped: true))
        }
        _ = try await context.journaled(.move, path, to: destination) {
            try await context.system.moveItem(atPath: path, toPath: destination)
            return nil
        }
        context.reportEffect(.file, path)
        context.reportEffect(.file, destination)
        return ActionOutput("Moved \(name) to \((folder as NSString).lastPathComponent)", values: FilePaths.outputs(destination))
    }
}

public struct CopyFileAction: AtlasAction {
    public static let id: ActionID = "file.copy"

    public let descriptor = ActionDescriptor(
        id: CopyFileAction.id,
        title: "Copy File",
        summary: "Copies a file or folder into another folder, adding a number or skipping it if the name is taken.",
        category: "Links & Files",
        symbolName: "doc.on.doc",
        parameters: [
            ParameterSpec(key: "path", label: "File", kind: .filePath),
            ParameterSpec(key: "destination", label: "To folder", kind: .folderPath),
            ParameterSpec(key: "createFolder", label: "Create the folder if needed", kind: .boolean,
                          isRequired: false, defaultValue: true),
            FilePaths.ifExistsSpec,
        ],
        permissions: [.fileAccess],
        sideEffects: [.modifiesFiles],
        // Each retry would make another copy.
        isIdempotent: false,
        defaultTimeout: 120,
        outputs: FilePaths.outputSpecs
    )

    public init() {}

    public func perform(_ parameters: ActionParameters, context: ActionContext) async throws -> ActionOutput {
        let path = try parameters.path("path")
        let folder = try parameters.path("destination")
        try context.files.access.require(path)
        try context.files.access.require(folder, label: "Folder")
        try FilePaths.requireExisting(path, system: context.system)
        if context.system.fileKind(atPath: folder) == .missing {
            guard parameters["createFolder"]?.boolValue ?? true else {
                throw ActionError.failed("The folder \(folder) doesn't exist.")
            }
            try await context.system.createFolder(atPath: folder)
            context.log(.createFolder, folder)
        }
        let name = (path as NSString).lastPathComponent
        guard let destination = FilePaths.destination(name, in: folder, mode: FilePaths.conflictMode(parameters), system: context.system) else {
            return ActionOutput("Skipped \(name): \((folder as NSString).lastPathComponent) already has a file with that name",
                                values: FilePaths.outputs(path, skipped: true))
        }
        _ = try await context.journaled(.copy, path, to: destination) {
            try await context.system.copyItem(atPath: path, toPath: destination)
            return nil
        }
        context.reportEffect(.file, destination)
        return ActionOutput("Copied \(name) to \((folder as NSString).lastPathComponent)", values: FilePaths.outputs(destination))
    }
}

public struct RenameFileAction: AtlasAction {
    public static let id: ActionID = "file.rename"

    public let descriptor = ActionDescriptor(
        id: RenameFileAction.id,
        title: "Rename File",
        summary: "Gives a file or folder a new name in the same folder. Never replaces an existing file.",
        category: "Links & Files",
        symbolName: "pencil",
        parameters: [
            ParameterSpec(key: "path", label: "File", kind: .filePath),
            ParameterSpec(key: "name", label: "New name", kind: .text, help: "e.g. Invoice {{trigger.fileName}}"),
            FilePaths.ifExistsSpec,
        ],
        permissions: [.fileAccess],
        sideEffects: [.modifiesFiles],
        isIdempotent: false,
        defaultTimeout: 15,
        outputs: FilePaths.outputSpecs
    )

    public init() {}

    public func perform(_ parameters: ActionParameters, context: ActionContext) async throws -> ActionOutput {
        let path = try parameters.path("path")
        let name = try parameters.requiredString("name").trimmingCharacters(in: .whitespaces)
        guard !name.contains("/"), name != ".", name != "..", !name.isEmpty else {
            throw ActionError.invalidParameter("New name", reason: "a name can't contain “/”")
        }
        try context.files.access.require(path)
        try FilePaths.requireExisting(path, system: context.system)
        if (path as NSString).lastPathComponent == name {
            return ActionOutput("Already called \(name)", values: FilePaths.outputs(path))
        }
        let folder = (path as NSString).deletingLastPathComponent
        // A change of case only ("report.pdf" → "Report.pdf") is the same item on macOS.
        let caseOnly = (path as NSString).lastPathComponent.lowercased() == name.lowercased()
        let destination: String
        if caseOnly {
            destination = (folder as NSString).appendingPathComponent(name)
        } else if let free = FilePaths.destination(name, in: folder, mode: FilePaths.conflictMode(parameters), system: context.system) {
            destination = free
        } else {
            return ActionOutput("Skipped: something called “\(name)” is already in that folder", values: FilePaths.outputs(path, skipped: true))
        }
        _ = try await context.journaled(.rename, path, to: destination) {
            try await context.system.moveItem(atPath: path, toPath: destination)
            return nil
        }
        context.reportEffect(.file, path)
        context.reportEffect(.file, destination)
        return ActionOutput("Renamed to \((destination as NSString).lastPathComponent)", values: FilePaths.outputs(destination))
    }
}

public struct CreateFolderAction: AtlasAction {
    public static let id: ActionID = "folder.create"

    public let descriptor = ActionDescriptor(
        id: CreateFolderAction.id,
        title: "Create Folder",
        summary: "Makes a folder, including any missing folders above it. Does nothing if it already exists.",
        category: "Links & Files",
        symbolName: "folder.badge.plus",
        parameters: [
            ParameterSpec(key: "path", label: "Folder", kind: .folderPath),
        ],
        permissions: [.fileAccess],
        sideEffects: [.modifiesFiles],
        isIdempotent: true,
        defaultTimeout: 10,
        outputs: [OutputSpec(key: "path", label: "Folder", type: .filePath)]
    )

    public init() {}

    public func perform(_ parameters: ActionParameters, context: ActionContext) async throws -> ActionOutput {
        let path = try parameters.path("path")
        try context.files.access.require(path, label: "Folder")
        switch context.system.fileKind(atPath: path) {
        case .directory:
            return ActionOutput("\((path as NSString).lastPathComponent) already exists", values: ["path": .string(path)])
        case .file:
            throw ActionError.failed("\(path) is a file, not a folder.")
        case .missing:
            try await context.system.createFolder(atPath: path)
            context.log(.createFolder, path)
            context.reportEffect(.file, path)
            return ActionOutput("Created \((path as NSString).lastPathComponent)", values: ["path": .string(path)])
        }
    }
}

public struct TrashFileAction: AtlasAction {
    public static let id: ActionID = "file.trash"

    public let descriptor = ActionDescriptor(
        id: TrashFileAction.id,
        title: "Move to Trash",
        summary: "Moves a file or folder to the Trash. You confirm each time, and you can put it back from the Trash or undo it in Run History.",
        category: "Links & Files",
        symbolName: "trash",
        parameters: [
            ParameterSpec(key: "path", label: "File", kind: .filePath),
        ],
        permissions: [.fileAccess],
        sideEffects: [.modifiesFiles, .destructive],
        confirmationRequired: true,
        isIdempotent: false,
        defaultTimeout: 15,
        outputs: [OutputSpec(key: "trashPath", label: "Location in Trash", type: .filePath)]
    )

    public init() {}

    public func perform(_ parameters: ActionParameters, context: ActionContext) async throws -> ActionOutput {
        let path = try parameters.path("path")
        try context.files.access.require(path)
        try FilePaths.requireExisting(path, system: context.system)
        let trashed = try await context.journaled(.trash, path, to: nil) {
            try await context.system.trashItem(atPath: path)
        } ?? ""
        context.reportEffect(.file, path)
        return ActionOutput("Moved \((path as NSString).lastPathComponent) to the Trash", values: ["trashPath": .string(trashed)])
    }
}

public struct TagFileAction: AtlasAction {
    public static let id: ActionID = "file.tag"

    public let descriptor = ActionDescriptor(
        id: TagFileAction.id,
        title: "Tag File",
        summary: "Adds Finder tags to a file or folder, keeping the tags it already has unless you choose to replace them.",
        category: "Links & Files",
        symbolName: "tag",
        parameters: [
            ParameterSpec(key: "path", label: "File", kind: .filePath),
            ParameterSpec(key: "tags", label: "Tags", kind: .text, help: "Comma-separated, e.g. Work, Red"),
            ParameterSpec(key: "replace", label: "Replace existing tags", kind: .boolean, isRequired: false, defaultValue: false),
        ],
        permissions: [.fileAccess],
        sideEffects: [.modifiesFiles],
        isIdempotent: true,
        defaultTimeout: 10,
        outputs: [
            OutputSpec(key: "path", label: "Path", type: .filePath),
            OutputSpec(key: "tags", label: "Tags", type: .string),
        ]
    )

    public init() {}

    static func split(_ text: String) -> [String] {
        text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    public func perform(_ parameters: ActionParameters, context: ActionContext) async throws -> ActionOutput {
        let path = try parameters.path("path")
        let wanted = Self.split(try parameters.requiredString("tags"))
        guard !wanted.isEmpty else { throw ActionError.invalidParameter("Tags", reason: "add at least one tag") }
        try context.files.access.require(path)
        try FilePaths.requireExisting(path, system: context.system)
        let previous = context.system.fileTags(atPath: path)
        var tags = parameters["replace"]?.boolValue == true ? [] : previous
        for tag in wanted where !tags.contains(where: { $0.caseInsensitiveCompare(tag) == .orderedSame }) { tags.append(tag) }
        guard tags != previous else {
            return ActionOutput("\((path as NSString).lastPathComponent) already has those tags",
                                values: ["path": .string(path), "tags": .string(tags.joined(separator: ", "))])
        }
        try await context.system.setFileTags(tags, atPath: path)
        context.log(.tag, path, extra: ["previous": previous.joined(separator: ","), "tags": tags.joined(separator: ", ")])
        return ActionOutput("Tagged \((path as NSString).lastPathComponent): \(tags.joined(separator: ", "))",
                            values: ["path": .string(path), "tags": .string(tags.joined(separator: ", "))])
    }
}

/// Reverses one recorded file change: moves and renames go back, trashed
/// items come back out of the Trash, tags are restored. Says plainly when
/// that's no longer possible instead of guessing.
public struct UndoFileOperationAction: AtlasAction {
    public static let id: ActionID = "file.undo"

    public let descriptor = ActionDescriptor(
        id: UndoFileOperationAction.id,
        title: "Undo File Change",
        summary: "Reverses a move, rename, Move to Trash or tag change ATLAS made, if nothing has changed since.",
        category: "Links & Files",
        symbolName: "arrow.uturn.backward",
        parameters: [
            ParameterSpec(key: "operationId", label: "Change", kind: .text, help: "From Run History"),
        ],
        permissions: [.fileAccess],
        sideEffects: [.modifiesFiles],
        isIdempotent: false,
        defaultTimeout: 30,
        outputs: [OutputSpec(key: "path", label: "Restored path", type: .filePath)]
    )

    public init() {}

    public func perform(_ parameters: ActionParameters, context: ActionContext) async throws -> ActionOutput {
        guard let id = UUID(uuidString: try parameters.requiredString("operationId")),
              let log = context.files.log, var operation = log.operation(id: id)
        else { throw ActionError.failed("That change isn't in the undo log any more.") }
        guard operation.undoneAt == nil else { throw ActionError.failed("“\(operation.summary)” was already undone.") }
        guard operation.state == .done else {
            throw ActionError.failed("“\(operation.summary)” never finished, so there's nothing to undo. \(operation.extra["recovered"] ?? "")")
        }
        guard operation.kind.isUndoable else {
            throw ActionError.failed("“\(operation.summary)” can't be undone automatically: undoing it would mean removing something. Move it to the Trash yourself if you don't want it.")
        }
        let system = context.system
        let message: String
        let restored: String
        switch operation.kind {
        case .move, .rename, .trash:
            guard let current = operation.destination else { throw ActionError.failed("No record of where it went.") }
            let original = operation.source
            guard system.fileKind(atPath: current) != .missing else {
                let place = operation.kind == .trash ? "in the Trash (it may have been emptied)" : "at \(current.abbreviatedPath)"
                throw ActionError.failed("Can't undo: \((original as NSString).lastPathComponent) is no longer \(place).")
            }
            guard system.fileKind(atPath: original) == .missing else {
                throw ActionError.failed("Can't undo: something new is already at \(original.abbreviatedPath), and ATLAS never replaces files.")
            }
            try context.files.access.require(original, label: "Original location")
            if operation.kind != .trash { try context.files.access.require(current) }
            let folder = (original as NSString).deletingLastPathComponent
            if system.fileKind(atPath: folder) == .missing { try await system.createFolder(atPath: folder) }
            try await system.moveItem(atPath: current, toPath: original)
            context.log(operation.kind == .rename ? .rename : .move, current, to: original, extra: ["undoOf": operation.id.uuidString])
            context.reportEffect(.file, current)
            context.reportEffect(.file, original)
            restored = original
            message = operation.kind == .trash
                ? "Put \((original as NSString).lastPathComponent) back from the Trash"
                : "Put \((original as NSString).lastPathComponent) back in \(folder.abbreviatedPath)"
        case .tag:
            try context.files.access.require(operation.source)
            try FilePaths.requireExisting(operation.source, system: system)
            let previous = TagFileAction.split(operation.extra["previous"] ?? "")
            try await system.setFileTags(previous, atPath: operation.source)
            restored = operation.source
            message = previous.isEmpty ? "Removed the tags ATLAS added" : "Restored tags: \(previous.joined(separator: ", "))"
        case .copy, .createFolder:
            throw ActionError.failed("This kind of change can't be undone.")
        }
        operation.undoneAt = Date()
        operation.undoNote = message
        log.record(operation)
        return ActionOutput(message, values: ["path": .string(restored)])
    }
}

extension AtlasEvent.Name {
    /// Payload: name, seconds. Published by `timer.start` when time is up.
    public static let timerCompleted = "timer.completed"
    /// Payload: name, seconds, endsAt (seconds since 1970).
    public static let timerStarted = "timer.started"
    /// Payload: name. A timer stopped before it finished.
    public static let timerStopped = "timer.stopped"
}

/// Timers started by `timer.start` that haven't finished, so they can be
/// listed (Companion, menu bar) and stopped early.
public final class TimerCenter: @unchecked Sendable {
    public struct ActiveTimer: Hashable, Sendable, Identifiable {
        public let id: UUID
        public let name: String
        public let endsAt: Date
    }

    /// The registry's timers. Tests that need isolation create their own.
    public static let shared = TimerCenter()

    private let lock = NSLock()
    private var timers: [UUID: (timer: ActiveTimer, task: Task<Void, Never>)] = [:]

    public init() {}

    public var active: [ActiveTimer] {
        lock.withLock { timers.values.map(\.timer) }.sorted { $0.endsAt < $1.endsAt }
    }

    /// Starting a timer with a name that's already running restarts it.
    @discardableResult
    func start(name: String, seconds: Double, events: EventBus) -> ActiveTimer {
        stop(named: name, events: nil)
        let timer = ActiveTimer(id: UUID(), name: name, endsAt: Date().addingTimeInterval(seconds))
        let task = Task.detached { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.lock.withLock { _ = self?.timers.removeValue(forKey: timer.id) }
            events.publish(AtlasEvent(AtlasEvent.Name.timerCompleted, payload: ["name": .string(name), "seconds": .number(seconds)]))
        }
        lock.withLock { timers[timer.id] = (timer, task) }
        events.publish(AtlasEvent(AtlasEvent.Name.timerStarted, payload: [
            "name": .string(name), "seconds": .number(seconds), "endsAt": .number(timer.endsAt.timeIntervalSince1970),
        ]))
        return timer
    }

    /// Stops every timer with this name (case-insensitive). Returns how many.
    @discardableResult
    func stop(named name: String, events: EventBus?) -> Int {
        let stopped = lock.withLock {
            let matches = timers.filter { $0.value.timer.name.caseInsensitiveCompare(name) == .orderedSame }
            matches.keys.forEach { timers.removeValue(forKey: $0) }
            return matches.values.map(\.task)
        }
        stopped.forEach { $0.cancel() }
        if !stopped.isEmpty { events?.publish(AtlasEvent(AtlasEvent.Name.timerStopped, payload: ["name": .string(name)])) }
        return stopped.count
    }
}

public struct StartTimerAction: AtlasAction {
    public static let id: ActionID = "timer.start"
    private let center: TimerCenter

    public let descriptor = ActionDescriptor(
        id: StartTimerAction.id,
        title: "Start Timer",
        summary: "Starts a named timer and carries on at once. When it ends, workflows with a “Timer completed” trigger run.",
        category: "Timing",
        symbolName: "timer",
        parameters: [
            ParameterSpec(key: "name", label: "Timer name", kind: .text, help: "e.g. Break"),
            ParameterSpec(key: "seconds", label: "Seconds", kind: .number, defaultValue: 300, minimum: 1, maximum: 86_400),
        ],
        isIdempotent: false,
        defaultTimeout: 5,
        outputs: [OutputSpec(key: "endsAt", label: "Ends at", type: .string)],
        isConcurrencySafe: true
    )

    public init(center: TimerCenter = .shared) {
        self.center = center
    }

    public func perform(_ parameters: ActionParameters, context: ActionContext) async throws -> ActionOutput {
        let name = try parameters.requiredString("name")
        let seconds = parameters["seconds"]?.numberValue ?? 300
        let timer = center.start(name: name, seconds: seconds, events: context.events)
        return ActionOutput("Started “\(name)” for \(Self.duration(seconds))",
                            values: ["endsAt": .string(timer.endsAt.formatted(date: .omitted, time: .shortened))])
    }

    /// "25 min", "90 s", "1 h 30 min".
    public static func duration(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        if total < 120 { return "\(total) s" }
        let hours = total / 3_600, minutes = (total % 3_600) / 60
        if hours == 0 { return "\(minutes) min" }
        return minutes == 0 ? "\(hours) h" : "\(hours) h \(minutes) min"
    }
}

public struct StopTimerAction: AtlasAction {
    public static let id: ActionID = "timer.stop"
    private let center: TimerCenter

    public let descriptor = ActionDescriptor(
        id: StopTimerAction.id,
        title: "Stop Timer",
        summary: "Stops a running timer early. Its “Timer completed” automations don't run.",
        category: "Timing",
        symbolName: "timer.circle",
        parameters: [
            ParameterSpec(key: "name", label: "Timer name", kind: .text, help: "The name it was started with"),
        ],
        isIdempotent: true,
        defaultTimeout: 5,
        isConcurrencySafe: true
    )

    public init(center: TimerCenter = .shared) {
        self.center = center
    }

    public func perform(_ parameters: ActionParameters, context: ActionContext) async throws -> ActionOutput {
        let name = try parameters.requiredString("name")
        guard center.stop(named: name, events: context.events) > 0 else {
            throw ActionError.failed("No timer called “\(name)” is running.")
        }
        return ActionOutput("Stopped “\(name)”")
    }
}
