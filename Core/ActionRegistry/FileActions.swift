import Foundation

// Stage 04 file actions. All declare Files & Folders access and that they
// change files. Nothing here deletes: removing a file means moving it to
// the Trash, and that asks for confirmation each time.

enum FilePaths {
    /// `folder/name`, or `folder/name 2.ext`, `… 3.ext` if taken, so
    /// nothing is ever overwritten.
    static func available(_ name: String, in folder: String, system: SystemAdapter) -> String {
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var candidate = (folder as NSString).appendingPathComponent(name)
        var n = 2
        while system.fileKind(atPath: candidate) != .missing {
            let numbered = ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)"
            candidate = (folder as NSString).appendingPathComponent(numbered)
            n += 1
        }
        return candidate
    }

    static func requireExisting(_ path: String, system: SystemAdapter) throws {
        guard system.fileKind(atPath: path) != .missing else {
            throw ActionError.failed("Nothing exists at \(path). It may have been moved or renamed.")
        }
    }

    static func outputs(_ path: String) -> ActionParameters {
        [
            "path": .string(path),
            "fileName": .string((path as NSString).lastPathComponent),
            "folder": .string((path as NSString).deletingLastPathComponent),
        ]
    }

    static let outputSpecs = [
        OutputSpec(key: "path", label: "New path", type: .filePath),
        OutputSpec(key: "fileName", label: "File name", type: .string),
        OutputSpec(key: "folder", label: "Folder", type: .filePath),
    ]
}

public struct MoveFileAction: AtlasAction {
    public static let id: ActionID = "file.move"

    public let descriptor = ActionDescriptor(
        id: MoveFileAction.id,
        title: "Move File",
        summary: "Moves a file or folder into another folder. If the name is taken there, adds a number instead of replacing anything.",
        category: "Links & Files",
        symbolName: "folder.badge.plus",
        parameters: [
            ParameterSpec(key: "path", label: "File", kind: .filePath),
            ParameterSpec(key: "destination", label: "To folder", kind: .folderPath),
            ParameterSpec(key: "createFolder", label: "Create the folder if needed", kind: .boolean,
                          isRequired: false, defaultValue: true),
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
        try FilePaths.requireExisting(path, system: context.system)
        switch context.system.fileKind(atPath: folder) {
        case .file:
            throw ActionError.failed("\(folder) is a file, not a folder.")
        case .missing:
            guard parameters["createFolder"]?.boolValue ?? true else {
                throw ActionError.failed("The folder \(folder) doesn't exist.")
            }
            try await context.system.createFolder(atPath: folder)
        case .directory:
            break
        }
        let destination = FilePaths.available((path as NSString).lastPathComponent, in: folder, system: context.system)
        try await context.system.moveItem(atPath: path, toPath: destination)
        context.reportEffect(.file, path)
        context.reportEffect(.file, destination)
        return ActionOutput("Moved \((path as NSString).lastPathComponent) to \((folder as NSString).lastPathComponent)",
                            values: FilePaths.outputs(destination))
    }
}

public struct CopyFileAction: AtlasAction {
    public static let id: ActionID = "file.copy"

    public let descriptor = ActionDescriptor(
        id: CopyFileAction.id,
        title: "Copy File",
        summary: "Copies a file or folder into another folder, adding a number if the name is taken.",
        category: "Links & Files",
        symbolName: "doc.on.doc",
        parameters: [
            ParameterSpec(key: "path", label: "File", kind: .filePath),
            ParameterSpec(key: "destination", label: "To folder", kind: .folderPath),
            ParameterSpec(key: "createFolder", label: "Create the folder if needed", kind: .boolean,
                          isRequired: false, defaultValue: true),
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
        try FilePaths.requireExisting(path, system: context.system)
        if context.system.fileKind(atPath: folder) == .missing {
            guard parameters["createFolder"]?.boolValue ?? true else {
                throw ActionError.failed("The folder \(folder) doesn't exist.")
            }
            try await context.system.createFolder(atPath: folder)
        }
        let destination = FilePaths.available((path as NSString).lastPathComponent, in: folder, system: context.system)
        try await context.system.copyItem(atPath: path, toPath: destination)
        context.reportEffect(.file, destination)
        return ActionOutput("Copied \((path as NSString).lastPathComponent) to \((folder as NSString).lastPathComponent)",
                            values: FilePaths.outputs(destination))
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
        guard !name.contains("/"), name != ".", name != ".." else {
            throw ActionError.invalidParameter("New name", reason: "a name can't contain “/”")
        }
        try FilePaths.requireExisting(path, system: context.system)
        let destination = ((path as NSString).deletingLastPathComponent as NSString).appendingPathComponent(name)
        guard context.system.fileKind(atPath: destination) == .missing else {
            throw ActionError.failed("Something called “\(name)” is already in that folder.")
        }
        try await context.system.moveItem(atPath: path, toPath: destination)
        context.reportEffect(.file, path)
        context.reportEffect(.file, destination)
        return ActionOutput("Renamed to \(name)", values: FilePaths.outputs(destination))
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
        switch context.system.fileKind(atPath: path) {
        case .directory:
            return ActionOutput("\((path as NSString).lastPathComponent) already exists", values: ["path": .string(path)])
        case .file:
            throw ActionError.failed("\(path) is a file, not a folder.")
        case .missing:
            try await context.system.createFolder(atPath: path)
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
        summary: "Moves a file or folder to the Trash. You confirm each time, and you can put it back from the Trash.",
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
        try FilePaths.requireExisting(path, system: context.system)
        let trashed = try await context.system.trashItem(atPath: path)
        context.reportEffect(.file, path)
        return ActionOutput("Moved \((path as NSString).lastPathComponent) to the Trash", values: ["trashPath": .string(trashed)])
    }
}

extension AtlasEvent.Name {
    /// Payload: name, seconds. Published by `timer.start` when time is up.
    public static let timerCompleted = "timer.completed"
}

public struct StartTimerAction: AtlasAction {
    public static let id: ActionID = "timer.start"

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

    public init() {}

    public func perform(_ parameters: ActionParameters, context: ActionContext) async throws -> ActionOutput {
        let name = try parameters.requiredString("name")
        let seconds = parameters["seconds"]?.numberValue ?? 300
        let events = context.events
        Task.detached {
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            events.publish(AtlasEvent(AtlasEvent.Name.timerCompleted, payload: ["name": .string(name), "seconds": .number(seconds)]))
        }
        let end = Date().addingTimeInterval(seconds)
        return ActionOutput("Started “\(name)” for \(ActionValue.number(seconds).displayString)s",
                            values: ["endsAt": .string(end.formatted(date: .omitted, time: .shortened))])
    }
}
