import AtlasCore
import AtlasSpaces
import Foundation

/// The pegboard (real inspiration pictures), the paint jars (colours from
/// your latest work) and the gallery wall (finished projects).
extension CreativeService {
    public static let defaultInspirationFolder = "~/Pictures/Inspiration"
    public static let galleryLimit = 6
    static let pegboardLimit = 6
    static let pictureExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "heic", "tif", "tiff"]
    /// The jars' colours when there's no picture yet: rose, peach, sage, berry, mauve.
    static let defaultJars = ["#E8A6B4", "#FFC4A8", "#8FB59A", "#8E3B5B", "#C98A9B"]

    /// The inspiration folder, expanded.
    public var inspirationFolder: String {
        let folder = settings.inspirationFolder.trimmingCharacters(in: .whitespaces)
        return ((folder.isEmpty ? Self.defaultInspirationFolder : folder) as NSString).expandingTildeInPath
    }

    /// Makes the inspiration folder if it isn't there yet.
    public func ensureInspirationFolder() {
        try? fileManager.createDirectory(atPath: inspirationFolder, withIntermediateDirectories: true)
    }

    /// The newest pictures for the pegboard: the current project's
    /// References folder and the inspiration folder (and folders in it).
    public func pegboardSources() -> [String] {
        var folders = [inspirationFolder]
        if let folder = currentProject()?.creative?.folder { folders.insert((folder as NSString).appendingPathComponent("References"), at: 0) }
        var pictures: [(String, Date)] = []
        for folder in folders {
            for (path, modified, isFolder) in listing(folder) {
                if isFolder {
                    pictures += listing(path).filter { !$0.2 && Self.isPicture($0.0) }.map { ($0.0, $0.1) }
                } else if Self.isPicture(path) {
                    pictures.append((path, modified))
                }
            }
        }
        return pictures.sorted { $0.1 > $1.1 }.prefix(Self.pegboardLimit).map(\.0)
    }

    public static func isPicture(_ path: String) -> Bool {
        pictureExtensions.contains((path as NSString).pathExtension.lowercased())
    }

    private func listing(_ folder: String) -> [(String, Date, Bool)] {
        let url = URL(fileURLWithPath: folder)
        let items = (try? fileManager.contentsOfDirectory(at: url, includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey],
                                                          options: [.skipsHiddenFiles])) ?? []
        return items.map { item in
            let values = try? item.resourceValues(forKeys: [.contentModificationDateKey, .isDirectoryKey])
            return (item.path, values?.contentModificationDate ?? .distantPast, values?.isDirectory == true)
        }
    }

    /// Five colours from the current project's latest picture (worked out
    /// once per picture), or the studio's own when there's none.
    public func jarColors() -> [String] {
        guard let project = currentProject(), let source = latestVisual(project) else { return Self.defaultJars }
        let modified = (try? fileManager.attributesOfItem(atPath: source))?[.modificationDate] as? Date
        let key = "\(source)|\(modified?.timeIntervalSince1970 ?? 0)|\(thumbnails.cached(source) != nil)"
        if let cached = paletteCache.value(key) { return cached }
        let colors = palette(of: source)
        guard colors.count >= 3 else { return Self.defaultJars }
        let padded = Array((colors + Self.defaultJars).prefix(5))
        paletteCache.set(key, padded)
        return padded
    }

    /// The project's assets: its Assets folder, else the project folder.
    public func assetsFolder(_ project: Project) -> String? {
        guard let folder = project.creative?.folder else { return nil }
        let assets = (folder as NSString).appendingPathComponent("Assets")
        return fileManager.fileExists(atPath: assets) ? assets : folder
    }

    /// Finished projects, newest first.
    public func finishedProjects() -> [Project] {
        projects(includingArchived: true).filter { $0.creative?.status == .done }
            .sorted { ($0.creative?.finishedAt ?? $0.createdAt) > ($1.creative?.finishedAt ?? $1.createdAt) }
    }

    /// The gallery wall: the 6 most recently finished; older ones are "Past work".
    public func gallery() -> [CreativeRoomState.Frame] {
        finishedProjects().prefix(Self.galleryLimit).map { project in
            let source = latestVisual(project)
            if let source, thumbnails.cached(source) == nil {
                let thumbnails = self.thumbnails
                Task { [weak self] in if await thumbnails.make(source) { self?.changed() } }
            }
            let finished = (project.creative?.finishedAt ?? project.createdAt).formatted(.dateTime.month(.abbreviated).year())
            return CreativeRoomState.Frame(projectID: project.id, image: source.flatMap { thumbnails.cached($0) },
                                           detail: "\(project.name) · finished \(finished) · click for its exports")
        }
    }

    /// Finished projects that no longer fit on the wall.
    public func pastWork() -> [Project] {
        Array(finishedProjects().dropFirst(Self.galleryLimit))
    }

    /// Pegboard pictures (thumbnails, made in the background when missing).
    func pegboardPictures() -> [String] {
        pegboardSources().compactMap { source in
            if let cached = thumbnails.cached(source) { return cached }
            let thumbnails = self.thumbnails
            Task { [weak self] in if await thumbnails.make(source) { self?.changed() } }
            return nil
        }
    }
}

/// A small thread-safe cache of palettes by picture.
final class PaletteCache: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: [String]] = [:]

    func value(_ key: String) -> [String]? { lock.withLock { values[key] } }
    func set(_ key: String, _ value: [String]) {
        lock.withLock {
            if values.count > 50 { values.removeAll() }
            values[key] = value
        }
    }
}

/// `creative.openInspiration`: the pegboard. The inspiration folder, and
/// the current project's Pinterest and Dribbble links.
public struct OpenInspirationAction: AtlasAction {
    public static let id: ActionID = "creative.openInspiration"
    let ref = CreativeRef()

    public let descriptor = ActionDescriptor(
        id: OpenInspirationAction.id, title: "Open Inspiration",
        summary: "Opens your inspiration folder, and the current creative project's Pinterest and Dribbble links.",
        category: "Creative", symbolName: "pin",
        sideEffects: [.opensURL, .showsUI], isIdempotent: false, defaultTimeout: 20
    )

    init(service: CreativeService) { ref.service = service }

    public func perform(_ parameters: ActionParameters, context: ActionContext) async throws -> ActionOutput {
        let service = try ref.require()
        service.ensureInspirationFolder()
        try await context.system.openFile(atPath: service.inspirationFolder, withApplication: "com.apple.finder")
        var opened = ["inspiration folder"]
        for link in service.currentProject()?.creative?.links ?? [] where link.kind == .pinterest || link.kind == .dribbble {
            guard let url = URL(string: link.url) else { continue }
            try await context.system.open(url: url, withApplication: nil)
            opened.append(link.kind.title)
        }
        return ActionOutput("Opened " + opened.joined(separator: ", "))
    }
}

/// `creative.openAssets`: the paint-jar shelf. The current project's assets.
public struct OpenAssetsAction: AtlasAction {
    public static let id: ActionID = "creative.openAssets"
    let ref = CreativeRef()

    public let descriptor = ActionDescriptor(
        id: OpenAssetsAction.id, title: "Open Project Assets",
        summary: "Opens the current creative project's Assets folder (or its folder).",
        category: "Creative", symbolName: "paintpalette",
        sideEffects: [.showsUI], isIdempotent: true, defaultTimeout: 20
    )

    init(service: CreativeService) { ref.service = service }

    public func perform(_ parameters: ActionParameters, context: ActionContext) async throws -> ActionOutput {
        let service = try ref.require()
        guard let project = service.currentProject(), let folder = service.assetsFolder(project) else {
            return ActionOutput("No current project with a folder")
        }
        try await context.system.openFile(atPath: folder, withApplication: "com.apple.finder")
        return ActionOutput("Opened \(project.name)'s \((folder as NSString).lastPathComponent)")
    }
}
