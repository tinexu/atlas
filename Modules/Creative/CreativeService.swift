import AppKit
import AtlasCore
import AtlasSpaces
import Foundation
import ImageIO

/// Creative Studio settings, kept as a preference. Every field is optional
/// when reading, so later phases can add settings without breaking it.
public struct CreativeSettings: Codable, Equatable, Sendable {
    /// Always the current project, when set.
    public var pinnedProjectID: UUID?
    /// The monitor's app when the current project has none.
    public var designApp: String?
    /// Folders and files you said aren't projects.
    public var ignored: [String] = []
    /// What clicking the mug starts.
    public var sessionMinutes = 90
    /// A gentle notification every `breakEveryMinutes` (nothing pauses).
    public var breakReminders = false
    public var breakEveryMinutes = 60
    /// A day counts towards the streak with at least this much creating.
    public var streakMinutes = 30
    /// A creative day starts at this hour, so late nights count for the right day.
    public var dayBoundaryHour = 4
    /// Exports: ask first (the review queue) or move them automatically.
    public var exportMode: FileRule.Mode = .askFirst
    /// Screenshots during a session: ask first, or move them automatically.
    public var screenshotMode: FileRule.Mode = .askFirst
    /// How many dated copies "Version save" keeps per file.
    public var keepVersions = 10
    /// When the file rules were set up (exports ask first for a week).
    public var rulesInstalledAt: Date?
    /// Whether switching exports to automatic has been offered.
    public var offeredAutomaticExports = false
    /// The pegboard's pictures, and where dropped images are saved.
    public var inspirationFolder = CreativeService.defaultInspirationFolder
    /// The Companion paints at its tiny easel in the room.
    public var companionPaints = true
    /// Offers and suggestions wait until the creative session ends.
    public var quietDuringSessions = true
    /// The project picker's choice for today, when more than one project is active.
    public var pickedToday: PickedProject?

    public struct PickedProject: Codable, Equatable, Sendable {
        public var day: Date
        /// Nil: "Just watching".
        public var projectID: UUID?
        public init(day: Date, projectID: UUID?) {
            self.day = day
            self.projectID = projectID
        }
    }

    public init() {}

    public var day: DayBoundary { DayBoundary(boundaryHour: dayBoundaryHour) }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        pinnedProjectID = try c.decodeIfPresent(UUID.self, forKey: .pinnedProjectID)
        designApp = try c.decodeIfPresent(String.self, forKey: .designApp)
        ignored = try c.decodeIfPresent([String].self, forKey: .ignored) ?? []
        let defaults = CreativeSettings()
        sessionMinutes = try c.decodeIfPresent(Int.self, forKey: .sessionMinutes) ?? defaults.sessionMinutes
        breakReminders = try c.decodeIfPresent(Bool.self, forKey: .breakReminders) ?? defaults.breakReminders
        breakEveryMinutes = try c.decodeIfPresent(Int.self, forKey: .breakEveryMinutes) ?? defaults.breakEveryMinutes
        streakMinutes = try c.decodeIfPresent(Int.self, forKey: .streakMinutes) ?? defaults.streakMinutes
        dayBoundaryHour = try c.decodeIfPresent(Int.self, forKey: .dayBoundaryHour) ?? defaults.dayBoundaryHour
        exportMode = try c.decodeIfPresent(FileRule.Mode.self, forKey: .exportMode) ?? defaults.exportMode
        screenshotMode = try c.decodeIfPresent(FileRule.Mode.self, forKey: .screenshotMode) ?? defaults.screenshotMode
        keepVersions = try c.decodeIfPresent(Int.self, forKey: .keepVersions) ?? defaults.keepVersions
        rulesInstalledAt = try c.decodeIfPresent(Date.self, forKey: .rulesInstalledAt)
        offeredAutomaticExports = try c.decodeIfPresent(Bool.self, forKey: .offeredAutomaticExports) ?? false
        inspirationFolder = try c.decodeIfPresent(String.self, forKey: .inspirationFolder) ?? defaults.inspirationFolder
        companionPaints = try c.decodeIfPresent(Bool.self, forKey: .companionPaints) ?? defaults.companionPaints
        quietDuringSessions = try c.decodeIfPresent(Bool.self, forKey: .quietDuringSessions) ?? defaults.quietDuringSessions
        pickedToday = try c.decodeIfPresent(PickedProject.self, forKey: .pickedToday)
    }
}

extension AtlasEvent.Name {
    /// Creative projects (or anything the Creative Studio shows) changed.
    public static let creativeChanged = "creative.changed"
}

/// The Creative Studio's brain: creative projects (Orbit projects with
/// creative fields), finding them, and which one is current. Headless;
/// everything it opens goes through the engine.
public final class CreativeService: @unchecked Sendable {
    static let settingsKey = "creative.settings"
    static let setupKey = "creative.setup.done"
    static let openedKey = "creative.opened"

    /// The Creative Studio palette: rose, peach, mauve, sage, brass, berry.
    public static let palette = ["#E8A6B4", "#FFC4A8", "#C98A9B", "#8FB59A", "#D4A55A", "#8E3B5B"]
    public static let paletteNames = ["Rose", "Peach", "Mauve", "Sage", "Brass", "Berry"]

    let core: AtlasCore
    public let thumbnails: ProjectThumbnails
    let paletteCache = PaletteCache()
    var store: AtlasStore { core.store }
    /// Replaced in tests.
    var now: @Sendable () -> Date = { Date() }
    var fileManager: FileManager = .default
    var isInstalled: (String) -> Bool = { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil }

    init(core: AtlasCore, thumbnails: ProjectThumbnails = ProjectThumbnails()) {
        self.core = core
        self.thumbnails = thumbnails
        // A new export in the current project: the painter does a happy bounce.
        exportWatch = core.events.subscribe(AtlasEvent.Name.fileCreatedEvent) { [weak self] event in
            guard let self, let path = event.payload["path"]?.stringValue, let info = self.currentProject()?.creative,
                  CreativeMath.role(of: path, in: info, created: true) == .export else { return }
            self.exportsLock.withLock { self._exportsSaved += 1 }
            self.changed()
        }
    }

    deinit {
        if let exportWatch { core.events.unsubscribe(exportWatch) }
    }

    private var exportWatch: EventBus.Subscription?
    private let exportsLock = NSLock()
    private var _exportsSaved = 0
    /// Exports saved in the current project since launch.
    public var exportsSaved: Int { exportsLock.withLock { _exportsSaved } }

    public var settings: CreativeSettings {
        get { (try? store.preference(Self.settingsKey, as: CreativeSettings.self)) ?? CreativeSettings() }
        set {
            try? store.setPreference(newValue, for: Self.settingsKey)
            changed()
        }
    }

    // MARK: - Projects

    /// Creative projects, newest first; archived ones only when asked.
    public func projects(includingArchived: Bool = false) -> [Project] {
        ((try? store.projects()) ?? [])
            .filter { $0.creative != nil && (includingArchived || $0.creative?.isArchived == false) }
            .sorted { $0.createdAt > $1.createdAt }
    }

    public func project(id: UUID) -> Project? { projects(includingArchived: true).first { $0.id == id } }

    /// Saves a creative project. A new one gets the next free palette colour.
    @discardableResult
    public func save(_ project: Project) throws -> Project {
        var project = project
        if project.creative == nil { project.creative = CreativeInfo() }
        if !Self.palette.contains(project.color) {
            let used = Set(projects().filter { $0.id != project.id }.map(\.color))
            project.color = Self.palette.first { !used.contains($0) } ?? Self.palette[projects().count % Self.palette.count]
        }
        if let folder = project.creative?.folder, project.creative?.folderBookmark == nil {
            project.creative?.folderBookmark = Self.bookmark(for: folder)
        }
        if project.creative?.status == .done, project.creative?.finishedAt == nil { project.creative?.finishedAt = now() }
        if project.creative?.status != .done { project.creative?.finishedAt = nil }
        try store.saveProject(project)
        changed()
        return project
    }

    public func delete(projectID: UUID) throws {
        try store.deleteProject(id: projectID)
        if settings.pinnedProjectID == projectID { settings.pinnedProjectID = nil }
        changed()
    }

    /// Whether ATLAS may change files in `folder` (it's in an Orbit folder).
    public func isAuthorized(_ folder: String) -> Bool {
        core.fileAccess.isAllowed(folder)
    }

    // MARK: - Finding projects

    public var hasFinishedSetup: Bool {
        get { (try? store.preference(Self.setupKey, as: Bool.self)) == true }
        set { try? store.setPreference(newValue, for: Self.setupKey) }
    }

    /// Creative files in your Orbit folders that aren't projects yet.
    public func suggestions() -> [ProjectSuggestion] {
        ProjectDiscovery.suggest(roots: core.fileAccess.authorizedRoots, existing: projects(includingArchived: true),
                                 ignored: Set(settings.ignored), fileManager: fileManager, isInstalled: isInstalled)
    }

    @discardableResult
    public func add(_ suggestions: [ProjectSuggestion]) throws -> [Project] {
        var added: [Project] = []
        for suggestion in suggestions {
            let info = CreativeInfo(kind: suggestion.kind, apps: suggestion.apps, mainFiles: suggestion.mainFiles, folder: suggestion.folder)
            added.append(try save(Project(name: suggestion.name, color: "", createdAt: now(), creative: info)))
        }
        hasFinishedSetup = true
        return added
    }

    /// "Not a project": never suggested again.
    public func ignore(_ suggestion: ProjectSuggestion) {
        var settings = self.settings
        settings.ignored.append(suggestion.folder ?? suggestion.mainFiles.first ?? suggestion.name)
        self.settings = settings
    }

    // MARK: - The current project

    /// When each project was last opened from the room.
    var openedAt: [UUID: Date] {
        get { (try? store.preference(Self.openedKey, as: [UUID: Date].self)) ?? [:] }
        set { try? store.setPreference(newValue, for: Self.openedKey) }
    }

    /// A project was opened from the room (the easel, the switcher).
    public func noteOpened(_ projectID: UUID) {
        var opened = openedAt
        opened[projectID] = now()
        openedAt = opened
        changed()
    }

    /// Pinned, else the one opened from the room in the last 12 hours,
    /// else the one whose files changed most recently, else the newest.
    public func currentProject() -> Project? {
        let active = projects().filter { $0.creative?.status != .done }
        let candidates = active.isEmpty ? projects() : active
        if let pinned = settings.pinnedProjectID, let project = candidates.first(where: { $0.id == pinned }) { return project }
        let recent = now().addingTimeInterval(-12 * 3600)
        let opened = openedAt
        if let project = candidates.compactMap({ project in opened[project.id].map { (project, $0) } })
            .filter({ $0.1 >= recent }).max(by: { $0.1 < $1.1 })?.0 {
            return project
        }
        return candidates.max { (lastChanged($0) ?? $0.createdAt) < (lastChanged($1) ?? $1.createdAt) }
    }

    /// When the project's files last changed: its main files, and what's
    /// directly in its folder and exports folder.
    public func lastChanged(_ project: Project) -> Date? {
        newestFile(project, matching: { _ in true })?.modified
    }

    /// The picture for a project: its cover, else its newest export or
    /// picture, else its newest main file.
    public func latestVisual(_ project: Project) -> String? {
        guard let info = project.creative else { return nil }
        if let cover = info.coverImage, fileManager.fileExists(atPath: cover) { return cover }
        let pictures = CreativeFiles.imageExtensions.union(CreativeFiles.videoExtensions)
        let exports = (info.resolvedExportsFolder.map { shallow($0) } ?? []) + (renderFolder(of: project).map { shallow($0) } ?? [])
        if let export = exports.filter({ pictures.contains(($0.path as NSString).pathExtension.lowercased()) }).max(by: { $0.modified < $1.modified }) {
            return export.path
        }
        return newestFile(project) { CreativeFiles.type(of: $0) != nil || pictures.contains(($0 as NSString).pathExtension.lowercased()) }?.path
    }

    /// The project's render output folder (Renders, Render or Output), if it has one.
    public func renderFolder(of project: Project) -> String? {
        guard let folder = project.creative?.folder else { return nil }
        return ["Renders", "Render", "Output"].map { (folder as NSString).appendingPathComponent($0) }.first { path in
            var isDirectory: ObjCBool = false
            return fileManager.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
        }
    }

    /// Whether the active Space is a Creative Studio.
    public var isStudioActive: Bool {
        guard let id = try? store.preference(ConditionCheck.activeSpacePreferenceKey, as: UUID.self),
              let space = (try? store.space(id: id)) ?? nil else { return false }
        return space.templateID == CreativeLoft.templateID
    }

    private func newestFile(_ project: Project, matching wanted: (String) -> Bool) -> (path: String, modified: Date)? {
        guard let info = project.creative else { return nil }
        var files = info.mainFiles.compactMap { path -> (String, Date)? in
            (try? fileManager.attributesOfItem(atPath: path))?[.modificationDate].flatMap { $0 as? Date }.map { (path, $0) }
        }
        if let folder = info.folder { files += shallow(folder).map { ($0.path, $0.modified) } }
        if let exports = info.resolvedExportsFolder { files += shallow(exports).map { ($0.path, $0.modified) } }
        return files.filter { wanted($0.0) }.max { $0.1 < $1.1 }.map { (path: $0.0, modified: $0.1) }
    }

    private func shallow(_ folder: String) -> [(path: String, modified: Date)] {
        let url = URL(fileURLWithPath: (folder as NSString).expandingTildeInPath)
        let items = (try? fileManager.contentsOfDirectory(at: url, includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey],
                                                          options: [.skipsHiddenFiles])) ?? []
        return items.compactMap { item in
            let values = try? item.resourceValues(forKeys: [.contentModificationDateKey, .isDirectoryKey])
            guard values?.isDirectory != true || CreativeFiles.type(of: item.path) != nil else { return nil }
            return (item.path, values?.contentModificationDate ?? .distantPast)
        }
    }

    /// A file's five main colours, from a small copy of it (its cached
    /// thumbnail, or the picture itself read at 128 px).
    public func palette(of path: String) -> [String] {
        // Pictures are read directly; other files (.blend…) through their thumbnail.
        let source = Self.isPicture(path) ? path : (thumbnails.cached(path) ?? path)
        guard let imageSource = CGImageSourceCreateWithURL(URL(fileURLWithPath: source) as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 128,
              ] as CFDictionary) else { return [] }
        return ColorPalette.extract(from: image)
    }

    // MARK: - Room

    /// The easel and monitor for the current project. Pictures not made
    /// yet are made in the background (and the room told when they're ready).
    public func roomState() -> CreativeRoomState {
        guard let project = currentProject(), let info = project.creative else {
            let app = settings.designApp ?? CreativeFiles.defaultDesignApp(isInstalled: isInstalled)
            return CreativeRoomState(monitorDetail: "Open \(appName(app))")
        }
        var detail = "\(project.name) · \(info.status.title)"
        if let changed = lastChanged(project) {
            detail += " · last edited \(Self.ago(changed, now: now()))"
        }
        if settings.pinnedProjectID == project.id { detail += " · pinned" }
        detail += "\nClick to open · right-click to switch"
        let source = latestVisual(project)
        if let source, thumbnails.cached(source) == nil {
            let thumbnails = self.thumbnails
            Task { [weak self] in
                if await thumbnails.make(source) { self?.changed() }
            }
        }
        let app = info.apps.first ?? settings.designApp ?? CreativeFiles.defaultDesignApp(isInstalled: isInstalled)
        return CreativeRoomState(
            easel: .init(projectID: project.id, detail: detail, image: source.flatMap { thumbnails.cached($0) }),
            monitorImage: source.flatMap { thumbnails.cached($0, blurred: true) },
            monitorDetail: "Open \(appName(app))"
        )
    }

    public func appName(_ bundleID: String) -> String {
        core.system.applicationName(for: bundleID) ?? bundleID
    }

    /// "2 h ago", "3 days ago", "just now".
    static func ago(_ date: Date, now: Date) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        switch seconds {
        case ..<120: return "just now"
        case ..<3600: return "\(Int(seconds / 60)) min ago"
        case ..<86_400: return "\(Int(seconds / 3600)) h ago"
        case ..<(86_400 * 30): let days = Int(seconds / 86_400); return "\(days) day\(days == 1 ? "" : "s") ago"
        default: return date.formatted(date: .abbreviated, time: .omitted)
        }
    }

    // MARK: - Helpers

    func changed() {
        core.events.publish(AtlasEvent(AtlasEvent.Name.creativeChanged))
    }

    static func bookmark(for path: String) -> Data? {
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        return (try? url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil))
            ?? (try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil))
    }
}
