import AtlasCore
import Foundation

/// Projects (spec 8): files and folders from anywhere, grouped without
/// moving them. The indexer keeps links pointing at moved files and marks
/// links to deleted files broken; this offers repairs.
public final class ProjectManager: @unchecked Sendable {
    private let core: AtlasCore
    private var subscription: EventBus.Subscription?

    public init(core: AtlasCore) {
        self.core = core
    }

    public func projects() -> [Project] {
        (try? core.store.projects()) ?? []
    }

    @discardableResult
    public func create(named name: String) throws -> Project {
        let project = Project(name: name.trimmingCharacters(in: .whitespaces).isEmpty ? "New Project" : name)
        try core.store.saveProject(project)
        return project
    }

    public func save(_ project: Project) throws {
        try core.store.saveProject(project)
    }

    public func delete(_ project: Project) throws {
        try core.store.deleteProject(id: project.id)
    }

    /// Adds links (ignoring ones already there).
    public func add(paths: [String], to project: Project) throws -> Project {
        var project = project
        let existing = Set(project.links.map(\.path))
        for path in paths.map(FileLocation.normalize) where !existing.contains(path) {
            project.links.append(ProjectLink(path: path, isBroken: !FileManager.default.fileExists(atPath: path)))
        }
        try core.store.saveProject(project)
        return project
    }

    /// Re-checks every link against the disk; returns how many are broken.
    @discardableResult
    public func verifyLinks() -> Int {
        var broken = 0
        for var project in projects() {
            var changed = false
            for index in project.links.indices {
                let exists = FileManager.default.fileExists(atPath: project.links[index].path)
                if project.links[index].isBroken == exists {
                    project.links[index].isBroken = !exists
                    changed = true
                }
                if !exists { broken += 1 }
            }
            if changed { try? core.store.saveProject(project) }
        }
        return broken
    }

    /// Indexed files with the same name as a broken link: likely where it went.
    public func repairCandidates(for link: ProjectLink, limit: Int = 10) -> [FileEntry] {
        let roots = (try? core.store.locations().map(\.path)) ?? []
        let matches = (try? core.store.entries(matching: FileQuery(roots: roots, nameLike: [FileQuery.containsPattern(link.name)],
                                                                   sort: .modifiedDescending, limit: 100))) ?? []
        return Array(matches.filter { $0.name == link.name && $0.path != link.path }.prefix(limit))
    }

    public func repair(_ link: ProjectLink, in project: Project, to path: String) throws {
        var project = project
        guard let index = project.links.firstIndex(where: { $0.id == link.id }) else { return }
        project.links[index].path = FileLocation.normalize(path)
        project.links[index].isBroken = !FileManager.default.fileExists(atPath: path)
        try core.store.saveProject(project)
    }

    /// When a Space linked to a project activates, opens or reveals the
    /// project's key items through the engine.
    public func startFollowingSpaces() {
        guard subscription == nil else { return }
        subscription = core.events.subscribe(AtlasEvent.Name.spaceActivatedEvent) { [weak self] event in
            guard let self, let id = event.payload["spaceId"]?.stringValue.flatMap(UUID.init(uuidString:)) else { return }
            for project in self.projects() where project.spaceID == id && project.spaceBehavior != .none {
                let items = project.links.filter { $0.isKey && !$0.isBroken }
                for item in items {
                    let action: ActionID = project.spaceBehavior == .reveal ? RevealInFinderAction.id : OpenFileAction.id
                    Task { await self.core.engine.invoke(action, parameters: ["path": .string(item.path)], source: "project") }
                }
            }
        }
    }
}
