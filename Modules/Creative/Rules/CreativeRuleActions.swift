import AtlasCore
import AtlasOrbit
import AtlasSpaces
import Foundation

/// The file rules' actions. Every change goes through the registered file
/// actions (Orbit-folder check, never overwriting, undoable from Run
/// History), and "ask first" goes to Orbit's review queue.
enum CreativeFileRules {
    static let exportReason = "Creative Studio export"
    static let referenceReason = "Screenshot during a creative session"

    /// "Screenshot 2026-10-29 at 10.02.11.png", "Screen Recording …", "CleanShot …".
    static func isScreenshot(_ path: String) -> Bool {
        let name = (path as NSString).lastPathComponent.lowercased()
        return ["screenshot", "screen shot", "screen recording", "cleanshot"].contains { name.hasPrefix($0) }
    }

    /// "Robot Model" → "robot-model".
    static func slug(_ name: String) -> String {
        let words = name.lowercased().split { !$0.isLetter && !$0.isNumber }
        return words.isEmpty ? "project" : words.joined(separator: "-")
    }

    /// `{project}-{date:yyyy-MM-dd}-{counter}.{ext}`, with the lowest counter
    /// free in `folder`.
    static func exportName(for path: String, project: String, date: Date, in folder: String, fileManager: FileManager = .default) -> String {
        RenamePattern.newName("\(slug(project))-{date:yyyy-MM-dd}-{counter}", path: path, date: date) { candidate in
            fileManager.fileExists(atPath: (folder as NSString).appendingPathComponent(candidate))
        }
    }

    /// Runs a registered file action inside this action's run (so it's
    /// journaled under it and undoable).
    static func run(_ id: ActionID, _ parameters: ActionParameters, registry: ActionRegistry, context: ActionContext) async throws -> ActionOutput {
        guard let action = registry.action(for: id) else { throw ActionError.unknownAction(id) }
        return try await action.perform(try registry.validate(parameters, for: action.descriptor), context: context)
    }

    /// Proposes a change in the review queue.
    static func propose(_ path: String, _ action: RuleAction, reason: String, core: AtlasCore) throws -> ActionOutput {
        let item = try core.store.addReviewItem(ReviewItem(path: path, ruleIDs: [], action: action, reason: reason))
        core.events.publish(AtlasEvent(AtlasEvent.Name.reviewAdded, payload: [
            "reviewId": .string(item.id.uuidString), "path": .string(path), "reason": .string(reason),
        ]))
        return ActionOutput("Waiting for your review: \(action.summary)", values: ["path": .string(path), "outcome": "review"])
    }

    static func skipped(_ why: String, _ path: String) -> ActionOutput {
        ActionOutput(why, values: ["path": .string(path), "outcome": "skipped"])
    }
}

/// `creative.fileExport`: a new picture, PDF or video in Downloads or on
/// the Desktop while the Creative Studio is active goes to the current
/// project's Exports folder as `robot-2026-10-29-1.png`. Asks first
/// (review queue) unless exports are set to automatic.
struct FileExportAction: AtlasAction {
    static let id: ActionID = "creative.fileExport"
    let ref = CreativeRef()

    let descriptor = ActionDescriptor(
        id: FileExportAction.id, title: "File Creative Export",
        summary: "While the Creative Studio is active: moves a new export into the current project's Exports folder, renamed {project}-{date}-{counter}. Asks first unless set to automatic.",
        category: "Creative", symbolName: "square.and.arrow.down.on.square",
        parameters: [ParameterSpec(key: "path", label: "File", kind: .filePath)],
        permissions: [.fileAccess], sideEffects: [.modifiesFiles], isIdempotent: false, defaultTimeout: 30
    )

    init(service: CreativeService) { ref.service = service }

    func perform(_ parameters: ActionParameters, context: ActionContext) async throws -> ActionOutput {
        let service = try ref.require()
        let path = try parameters.path("path")
        guard service.isStudioActive else { return CreativeFileRules.skipped("Not in the Creative Studio: left where it is", path) }
        guard !CreativeFileRules.isScreenshot(path) else { return CreativeFileRules.skipped("A screenshot: the screenshot rule handles it", path) }
        guard FileManager.default.fileExists(atPath: path) else { return CreativeFileRules.skipped("It's gone already", path) }
        guard let project = service.currentProject(), let exports = project.creative?.resolvedExportsFolder else {
            return CreativeFileRules.skipped("No current project with a folder: left where it is", path)
        }
        guard service.isAuthorized(exports) else {
            throw ActionError.failed("\(project.name)'s Exports folder (\(exports.abbreviatedPath)) isn't in an Orbit folder. Add the project's folder in Orbit → Folders.")
        }
        let name = CreativeFileRules.exportName(for: path, project: project.name, date: service.now(), in: exports)
        if service.settings.exportMode == .askFirst {
            let output = try CreativeFileRules.propose(path, .moveAndRename(folder: exports, name: name),
                                                       reason: "\(CreativeFileRules.exportReason) → \(project.name)", core: service.core)
            service.offerAutomaticExportsIfEarned()
            return output
        }
        let registry = service.core.registry
        var output = try await CreativeFileRules.run(MoveFileAction.id, ["path": .string(path), "destination": .string(exports),
                                                                         "name": .string(name), "createFolder": true],
                                                     registry: registry, context: context)
        output.values["outcome"] = "done"
        return output
    }
}

/// `creative.fileReference`: a screenshot taken during a creative session
/// goes to the current project's References folder (asks first by default).
struct FileReferenceAction: AtlasAction {
    static let id: ActionID = "creative.fileReference"
    let ref = CreativeRef()
    weak var sessions: CreativeSessions?

    let descriptor = ActionDescriptor(
        id: FileReferenceAction.id, title: "File Screenshot as Reference",
        summary: "During a creative session: moves a new screenshot into the current project's References folder. Asks first unless set to automatic.",
        category: "Creative", symbolName: "camera.viewfinder",
        parameters: [ParameterSpec(key: "path", label: "File", kind: .filePath)],
        permissions: [.fileAccess], sideEffects: [.modifiesFiles], isIdempotent: false, defaultTimeout: 30
    )

    init(service: CreativeService, sessions: CreativeSessions) {
        ref.service = service
        self.sessions = sessions
    }

    func perform(_ parameters: ActionParameters, context: ActionContext) async throws -> ActionOutput {
        let service = try ref.require()
        let path = try parameters.path("path")
        guard sessions?.current?.kind == .create else { return CreativeFileRules.skipped("No creative session running: left where it is", path) }
        guard CreativeFileRules.isScreenshot(path) else { return CreativeFileRules.skipped("Not a screenshot", path) }
        guard let project = service.currentProject(), let folder = project.creative?.folder else {
            return CreativeFileRules.skipped("No current project with a folder: left where it is", path)
        }
        let references = (folder as NSString).appendingPathComponent("References")
        guard service.isAuthorized(references) else {
            throw ActionError.failed("\(project.name)'s folder (\(folder.abbreviatedPath)) isn't in an Orbit folder. Add it in Orbit → Folders.")
        }
        if service.settings.screenshotMode == .askFirst {
            return try CreativeFileRules.propose(path, .moveTo(folder: references), reason: "\(CreativeFileRules.referenceReason) → \(project.name)",
                                                 core: service.core)
        }
        return try await CreativeFileRules.run(MoveFileAction.id, ["path": .string(path), "destination": .string(references), "createFolder": true],
                                               registry: service.core.registry, context: context)
    }
}

/// `creative.renderDone`: a new image or video in a project's render
/// folder. A notification with Open and Show, and it goes on the easel.
struct RenderDoneAction: AtlasAction {
    static let id: ActionID = "creative.renderDone"
    let ref = CreativeRef()

    let descriptor = ActionDescriptor(
        id: RenderDoneAction.id, title: "Render Done",
        summary: "A notification for a finished render (with Open and Show), and the render goes on the easel.",
        category: "Creative", symbolName: "cube.transparent",
        parameters: [ParameterSpec(key: "path", label: "File", kind: .filePath)],
        sideEffects: [.showsUI], isIdempotent: true, defaultTimeout: 15
    )

    init(service: CreativeService) { ref.service = service }

    func perform(_ parameters: ActionParameters, context: ActionContext) async throws -> ActionOutput {
        let service = try ref.require()
        let path = try parameters.path("path")
        let ext = (path as NSString).pathExtension.lowercased()
        guard CreativeFiles.imageExtensions.union(CreativeFiles.videoExtensions).contains(ext) else {
            return CreativeFileRules.skipped("Not a picture or video", path)
        }
        let name = (path as NSString).lastPathComponent
        let project = service.projects().first { project in
            service.renderFolder(of: project).map { FileLocation.isPath(FileAccessPolicy.canonical(path), inside: FileAccessPolicy.canonical($0)) } ?? false
        }
        try await context.system.postFileNotification(title: "Render done: \(name)", body: project.map { "\($0.name) · click to open" } ?? "Click to open",
                                                      path: path)
        // The easel picks the newest render up as the project's picture.
        let thumbnails = service.thumbnails
        if await thumbnails.make(path) { service.changed() }
        return ActionOutput("Render done: \(name)", values: ["path": .string(path)])
    }
}

/// `creative.saveVersion`: leaving the Creative Studio saves a dated copy
/// of the current project's main file in `<project>/Versions`, keeping the
/// newest ones (older copies go to the Trash, never deleted).
struct SaveVersionAction: AtlasAction {
    static let id: ActionID = "creative.saveVersion"
    let ref = CreativeRef()

    let descriptor = ActionDescriptor(
        id: SaveVersionAction.id, title: "Save Project Version",
        summary: "Saves a dated copy of the current creative project's main file in its Versions folder, keeping the newest 10 (older ones go to the Trash).",
        category: "Creative", symbolName: "clock.arrow.circlepath",
        parameters: [ParameterSpec(key: "space", label: "Space ID", kind: .text, isRequired: false, help: "From the trigger: {{trigger.spaceId}}")],
        permissions: [.fileAccess], sideEffects: [.modifiesFiles], isIdempotent: false, defaultTimeout: 120
    )

    init(service: CreativeService) { ref.service = service }

    func perform(_ parameters: ActionParameters, context: ActionContext) async throws -> ActionOutput {
        let service = try ref.require()
        if let id = parameters.optionalString("space").flatMap(UUID.init(uuidString:)),
           ((try? service.store.space(id: id)) ?? nil)?.templateID != CreativeLoft.templateID {
            return ActionOutput("Not the Creative Studio")
        }
        guard let project = service.currentProject(), let info = project.creative, let folder = info.folder,
              let main = info.mainFiles.first(where: { FileManager.default.fileExists(atPath: $0) }) else {
            return ActionOutput("No current project with a main file")
        }
        let versions = (folder as NSString).appendingPathComponent("Versions")
        let base = ((main as NSString).lastPathComponent as NSString).deletingPathExtension
        let ext = (main as NSString).pathExtension
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmm"
        let name = "\(base)-\(formatter.string(from: service.now()))" + (ext.isEmpty ? "" : ".\(ext)")
        let registry = service.core.registry
        _ = try await CreativeFileRules.run(CopyFileAction.id, ["path": .string(main), "destination": .string(versions),
                                                                "name": .string(name), "createFolder": true, "ifExists": "skip"],
                                            registry: registry, context: context)
        // Keep the newest `keepVersions` copies of this file.
        let keep = max(1, service.settings.keepVersions)
        let copies = Self.versions(of: base, ext: ext, in: versions)
        var trashed = 0
        for old in copies.dropFirst(keep) {
            _ = try await CreativeFileRules.run(TrashFileAction.id, ["path": .string(old)], registry: registry, context: context)
            trashed += 1
        }
        return ActionOutput("Saved \(name) in \(project.name)/Versions" + (trashed > 0 ? " · \(trashed) older moved to the Trash" : ""),
                            values: ["path": .string((versions as NSString).appendingPathComponent(name))])
    }

    /// Dated copies of `base` in `folder`, newest first (by the date in the name).
    static func versions(of base: String, ext: String, in folder: String) -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []
        return names.filter { name in
            name.hasPrefix(base + "-") && (name as NSString).pathExtension == ext
                && (name as NSString).deletingPathExtension.dropFirst(base.count + 1).range(of: #"^\d{4}-\d{2}-\d{2}-\d{4}$"#, options: .regularExpression) != nil
        }
        .sorted(by: >)
        .map { (folder as NSString).appendingPathComponent($0) }
    }
}

/// `creative.setExportMode`: the offer to move exports automatically from now on.
struct SetExportModeAction: AtlasAction {
    static let id: ActionID = "creative.setExportMode"
    let ref = CreativeRef()

    let descriptor = ActionDescriptor(
        id: SetExportModeAction.id, title: "Set Export Mode",
        summary: "Exports: move them automatically, or ask first.",
        category: "Creative", symbolName: "arrow.triangle.branch",
        parameters: [ParameterSpec(key: "mode", label: "Mode", kind: .text, defaultValue: "automatic", options: FileRule.Mode.allCases.map(\.rawValue))],
        isIdempotent: true, defaultTimeout: 5
    )

    init(service: CreativeService) { ref.service = service }

    func perform(_ parameters: ActionParameters, context: ActionContext) async throws -> ActionOutput {
        let service = try ref.require()
        let mode = parameters.optionalString("mode").flatMap(FileRule.Mode.init(rawValue:)) ?? .automatic
        service.settings.exportMode = mode
        return ActionOutput(mode == .automatic ? "Exports now move automatically" : "Exports now ask first")
    }
}
