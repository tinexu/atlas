import AtlasCore
import Foundation

/// The Creative module's actions hold the service weakly.
final class CreativeRef: @unchecked Sendable {
    weak var service: CreativeService?

    func require() throws -> CreativeService {
        guard let service else { throw ActionError.failed("The Creative Studio isn't available right now.") }
        return service
    }

    /// The named project (ID or name), else the current one.
    func project(_ parameters: ActionParameters) throws -> Project? {
        let service = try require()
        guard let reference = parameters.optionalString("project"), !reference.isEmpty else { return service.currentProject() }
        let all = service.projects(includingArchived: true)
        if let id = UUID(uuidString: reference), let match = all.first(where: { $0.id == id }) { return match }
        guard let match = all.first(where: { $0.name.caseInsensitiveCompare(reference) == .orderedSame }) else {
            throw ActionError.invalidParameter("Project", reason: "no creative project is called “\(reference)”.")
        }
        return match
    }
}

/// `creative.openProject`: what clicking the easel does. Opens the
/// project's main file in its app, its folder in Finder, and its Figma link.
public struct OpenCreativeProjectAction: AtlasAction {
    public static let id: ActionID = "creative.openProject"
    let ref = CreativeRef()

    public let descriptor = ActionDescriptor(
        id: OpenCreativeProjectAction.id, title: "Open Creative Project",
        summary: "Opens a creative project's main file in its app, its folder in Finder and its Figma link. Without a project: the current one.",
        category: "Creative", symbolName: "paintbrush.pointed",
        parameters: [ParameterSpec(key: "project", label: "Project", kind: .text, isRequired: false, help: "Name or ID; empty for the current project")],
        sideEffects: [.opensURL, .showsUI, .launchesApplication], isIdempotent: false, defaultTimeout: 30
    )

    init(service: CreativeService) { ref.service = service }

    public func perform(_ parameters: ActionParameters, context: ActionContext) async throws -> ActionOutput {
        let service = try ref.require()
        guard let project = try ref.project(parameters), let info = project.creative else {
            return ActionOutput("No creative project yet: set one up in the Creative Studio")
        }
        service.noteOpened(project.id)
        var opened: [String] = []
        var problems: [String] = []
        let app = info.apps.first { context.system.applicationName(for: $0) != nil }
        for file in info.mainFiles where FileManager.default.fileExists(atPath: file) {
            do {
                try await context.system.openFile(atPath: file, withApplication: app)
                opened.append((file as NSString).lastPathComponent)
            } catch {
                problems.append("\((file as NSString).lastPathComponent) (\(error.localizedDescription))")
            }
        }
        if let folder = info.folder, FileManager.default.fileExists(atPath: folder) {
            do {
                try await context.system.openFile(atPath: folder, withApplication: "com.apple.finder")
                opened.append("folder")
            } catch {
                problems.append("its folder (\(error.localizedDescription))")
            }
        }
        for link in info.links where link.kind == .figma {
            guard let url = URL(string: link.url) else { continue }
            do {
                try await context.system.open(url: url, withApplication: nil)
                opened.append("Figma")
            } catch {
                problems.append("its Figma link (\(error.localizedDescription))")
            }
        }
        if opened.isEmpty, !problems.isEmpty {
            throw ActionError.failed("Couldn't open \(project.name): \(problems.joined(separator: "; ")).")
        }
        var output = ActionOutput("\(project.name): " + (opened.isEmpty ? "nothing to open yet; add a main file or folder" : opened.joined(separator: ", ")),
                                  values: ["project": .string(project.id.uuidString)])
        if !problems.isEmpty { output.partialFailure = "Couldn't open " + problems.joined(separator: "; ") }
        return output
    }
}

/// `creative.openDesignApp`: the monitor. The current project's main app,
/// or your default design app.
public struct OpenDesignAppAction: AtlasAction {
    public static let id: ActionID = "creative.openDesignApp"
    let ref = CreativeRef()

    public let descriptor = ActionDescriptor(
        id: OpenDesignAppAction.id, title: "Open Design App",
        summary: "Opens the current creative project's main app, or your default design app.",
        category: "Creative", symbolName: "display",
        sideEffects: [.launchesApplication], isIdempotent: true, defaultTimeout: 30
    )

    init(service: CreativeService) { ref.service = service }

    public func perform(_ parameters: ActionParameters, context: ActionContext) async throws -> ActionOutput {
        let service = try ref.require()
        let project = service.currentProject()
        let app = project?.creative?.apps.first { context.system.applicationName(for: $0) != nil }
            ?? service.settings.designApp ?? CreativeFiles.defaultDesignApp { context.system.applicationName(for: $0) != nil }
        _ = try await context.system.launchApplication(bundleID: app, activate: true)
        return ActionOutput("Opened \(service.appName(app))", values: ["bundleId": .string(app)])
    }
}
