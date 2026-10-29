import AppKit
import AtlasCore
import AtlasOrbit
import SwiftUI

/// Filters shared by the 3D Universe and the 2D browser.
public struct FileFilters: Equatable, Sendable {
    public enum SizeRange: String, CaseIterable, Identifiable, Sendable {
        case any, over1MB, over100MB, over1GB, under1MB
        public var id: Self { self }
        public var title: String {
            switch self {
            case .any: return "Any size"
            case .over1MB: return "Over 1 MB"
            case .over100MB: return "Over 100 MB"
            case .over1GB: return "Over 1 GB"
            case .under1MB: return "Under 1 MB"
            }
        }
        var bounds: (Int64?, Int64?) {
            switch self {
            case .any: return (nil, nil)
            case .over1MB: return (1_000_000, nil)
            case .over100MB: return (100_000_000, nil)
            case .over1GB: return (1_000_000_000, nil)
            case .under1MB: return (nil, 1_000_000)
            }
        }
    }

    public enum DateRange: String, CaseIterable, Identifiable, Sendable {
        case any, week, month, year, olderThanYear
        public var id: Self { self }
        public var title: String {
            switch self {
            case .any: return "Any date"
            case .week: return "Changed this week"
            case .month: return "Changed this month"
            case .year: return "Changed this year"
            case .olderThanYear: return "Older than a year"
            }
        }
    }

    public var categories: Set<FileCategory> = []
    public var size: SizeRange = .any
    public var date: DateRange = .any

    public init() {}

    public var isActive: Bool { !categories.isEmpty || size != .any || date != .any }

    public func matches(_ entry: FileEntry, now: Date = Date()) -> Bool {
        if !categories.isEmpty && !categories.contains(entry.category) { return false }
        let (low, high) = size.bounds
        if let low, entry.size < low { return false }
        if let high, entry.size > high { return false }
        let modified = entry.modifiedAt ?? .distantPast
        switch date {
        case .any: break
        case .week: if modified < now.addingTimeInterval(-7 * 86_400) { return false }
        case .month: if modified < now.addingTimeInterval(-30 * 86_400) { return false }
        case .year: if modified < now.addingTimeInterval(-365 * 86_400) { return false }
        case .olderThanYear: if modified >= now.addingTimeInterval(-365 * 86_400) { return false }
        }
        return true
    }
}

/// Things to make stand out, with everything else dimmed.
public enum FileHighlight: String, CaseIterable, Identifiable, Sendable {
    case none, overOneGB, notOpenedSixMonths
    public var id: Self { self }
    public var title: String {
        switch self {
        case .none: return "No highlight"
        case .overOneGB: return "Files over 1 GB"
        case .notOpenedSixMonths: return "Not opened in 6 months"
        }
    }

    public func matches(_ entry: FileEntry, now: Date = Date()) -> Bool {
        switch self {
        case .none: return true
        case .overOneGB: return entry.size >= 1_000_000_000
        case .notOpenedSixMonths:
            guard !entry.isFolder else { return false }
            return (entry.accessedAt ?? entry.modifiedAt ?? .distantPast) < now.addingTimeInterval(-182 * 86_400)
        }
    }
}

/// UI state for Orbit. Owns no logic: reads come from the index, and every
/// change to a file is a registered action run by the engine.
@MainActor
public final class OrbitViewModel: ObservableObject {
    public enum Tab: String, CaseIterable, Identifiable {
        case universe, browser, search, rules, duplicates, projects, folders
        public var id: Self { self }
        public var title: String {
            switch self {
            case .universe: return "Universe"
            case .browser: return "Browser"
            case .search: return "Search"
            case .rules: return "Rules"
            case .duplicates: return "Duplicates"
            case .projects: return "Projects"
            case .folders: return "Folders"
            }
        }
        public var symbol: String {
            switch self {
            case .universe: return "globe.americas"
            case .browser: return "list.bullet.indent"
            case .search: return "magnifyingglass"
            case .rules: return "wand.and.stars"
            case .duplicates: return "doc.on.doc"
            case .projects: return "folder.badge.person.crop"
            case .folders: return "externaldrive"
            }
        }
    }

    public let module: OrbitModule
    var core: AtlasCore { module.core }

    @Published public var tab: Tab = .universe
    @Published public private(set) var locations: [FileLocation] = []
    @Published public private(set) var progress: [UUID: FileIndexer.Progress] = [:]
    @Published public private(set) var isIndexingPaused = false
    /// Bumped whenever the index changes, so views can reload.
    @Published public private(set) var revision = 0

    /// nil = the overview with every Orbit folder as a planet.
    @Published public var currentFolder: String?
    @Published public var selection: String?
    @Published public var filters = FileFilters()
    @Published public var highlight: FileHighlight = .none

    @Published public private(set) var rules: [FileRule] = []
    @Published public private(set) var reviews: [ReviewItem] = []
    @Published public private(set) var projects: [Project] = []
    @Published public var selectedProjectID: UUID?

    @Published public private(set) var duplicateSets: [DuplicateSet] = []
    @Published public private(set) var duplicateProgress: DuplicateFinder.Progress?
    @Published public private(set) var lastDuplicateScan: Date?
    private var duplicateTask: Task<Void, Never>?

    @Published public private(set) var health: HealthSample?
    @Published public var pendingTrash: TrashRequest?
    @Published public var showCleanup = false

    /// Spaces a project can be linked to; the app fills this in.
    public var spaces: () -> [(id: UUID, name: String)] = { [] }
    /// Opens a generated workflow in the Automations editor.
    public var openWorkflow: (UUID) -> Void = { _ in }
    public var onError: (String) -> Void = { _ in }

    private var eventTask: Task<Void, Never>?
    private var refreshScheduled = false

    /// Files about to go to the Trash, waiting for the person's yes.
    public struct TrashRequest: Identifiable {
        public let id = UUID()
        public let paths: [String]
        public let source: String
        public var totalSize: Int64
    }

    public init(module: OrbitModule) {
        self.module = module
        module.indexer.onProgress = { [weak self] progress in
            Task { @MainActor in self?.progress = progress }
        }
        reload()
        listen()
    }

    // MARK: - Loading

    public func reload() {
        locations = module.locations.locations()
        rules = module.organizer.rules()
        reviews = module.organizer.pendingReviews()
        projects = module.projects.projects()
        isIndexingPaused = module.indexer.isPaused
        progress = module.indexer.currentProgress
        health = module.health.latest
        if let folder = currentFolder, !locations.contains(where: { $0.contains(folder) }) { currentFolder = nil }
        revision += 1
    }

    private func listen() {
        let stream = core.events.stream()
        eventTask = Task { [weak self] in
            for await event in stream {
                guard let self else { return }
                switch event.name {
                case AtlasEvent.Name.healthSample:
                    self.health = self.module.health.latest
                case _ where event.name.hasPrefix("file.") || event.name.hasPrefix("index.") || event.name.hasPrefix("review.")
                    || event.name == AtlasEvent.Name.workflowSaved || event.name == AtlasEvent.Name.workflowFinished:
                    self.scheduleRefresh()
                default:
                    break
                }
            }
        }
    }

    /// Coalesces bursts of changes into one reload.
    private func scheduleRefresh() {
        guard !refreshScheduled else { return }
        refreshScheduled = true
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 400_000_000)
            refreshScheduled = false
            reload()
        }
    }

    // MARK: - Index reads

    public func entry(_ path: String?) -> FileEntry? {
        guard let path else { return nil }
        return try? core.store.entry(at: path)
    }

    /// Children of a folder, biggest first, honouring the filters (folders always show).
    public func children(of folder: String, limit: Int = 2_000, applyFilters: Bool = true) -> [FileEntry] {
        let all = (try? core.store.entries(matching: FileQuery(parent: folder, sort: .foldersFirst, limit: limit))) ?? []
        guard applyFilters, filters.isActive else { return all }
        return all.filter { $0.isFolder || filters.matches($0) }
    }

    public func location(for path: String) -> FileLocation? {
        locations.filter { $0.contains(path) }.max { $0.path.count < $1.path.count }
    }

    /// Orbit › Downloads › Photos
    public var breadcrumb: [(name: String, path: String?)] {
        var crumbs: [(String, String?)] = [("Orbit", nil)]
        guard let folder = currentFolder, let location = location(for: folder) else { return crumbs }
        crumbs.append((location.name, location.path))
        let relative = folder.dropFirst(location.path.count).split(separator: "/")
        var path = location.path
        for part in relative {
            path += "/" + part
            crumbs.append((String(part), path))
        }
        return crumbs
    }

    public func categoryTotals(under path: String) -> [FileCategory: (count: Int, size: Int64)] {
        (try? core.store.categoryTotals(under: path)) ?? [:]
    }

    // MARK: - Navigation

    public func enter(_ folder: String?) {
        currentFolder = folder
        selection = nil
    }

    public func goUp() {
        guard let folder = currentFolder, let location = location(for: folder) else { return enter(nil) }
        enter(folder == location.path ? nil : (folder as NSString).deletingLastPathComponent)
    }

    /// The biggest files across every Orbit folder.
    public func largestFiles(limit: Int = 25) -> [FileEntry] {
        _ = revision
        let roots = locations.map(\.path)
        guard !roots.isEmpty else { return [] }
        return (try? module.core.store.entries(matching: FileQuery(roots: roots, kind: .filesOnly, sort: .sizeDescending, limit: limit))) ?? []
    }

    /// The Browser's overview, which lists the largest files first.
    public func showLargestFiles() {
        tab = .browser
        enter(nil)
    }

    /// Shows a file in the Universe: enters its folder and selects it.
    public func reveal(inUniverse path: String) {
        currentFolder = (path as NSString).deletingLastPathComponent
        selection = path
        tab = .universe
    }

    // MARK: - File actions (all through the engine)

    private func run(_ action: ActionID, _ parameters: ActionParameters, source: String = "orbit") {
        Task {
            let run = await core.engine.invoke(action, parameters: parameters, source: source)
            if run.state == .failed { onError(run.error ?? "That didn't work.") }
        }
    }

    public func open(_ path: String) { run(OpenFileAction.id, ["path": .string(path)]) }
    public func showInFinder(_ path: String) { run(RevealInFinderAction.id, ["path": .string(path)]) }

    public func rename(_ path: String, to name: String) {
        run(RenameFileAction.id, ["path": .string(path), "name": .string(name)])
    }

    public func move(_ paths: [String], to folder: String) {
        Task {
            for path in paths {
                let run = await core.engine.invoke(MoveFileAction.id, parameters: ["path": .string(path), "destination": .string(folder)],
                                                   source: "orbit")
                if run.state == .failed { onError(run.error ?? "Couldn't move \((path as NSString).lastPathComponent)."); break }
            }
        }
    }

    /// Asks first; `confirmTrash()` does it.
    public func requestTrash(_ paths: [String], source: String = "Orbit") {
        guard !paths.isEmpty else { return }
        let size = paths.compactMap { entry($0)?.size }.reduce(0, +)
        pendingTrash = TrashRequest(paths: paths, source: source, totalSize: size)
    }

    public func confirmTrash() {
        guard let request = pendingTrash else { return }
        pendingTrash = nil
        Task {
            let run = await module.cleanup.trash(request.paths, source: request.source)
            if run.state != .succeeded { onError(run.error ?? "Some items couldn't be moved to the Trash.") }
            if selection.map({ request.paths.contains($0) }) == true { selection = nil }
            duplicateSets = duplicateSets.compactMap { set in
                let remaining = set.files.filter { !request.paths.contains($0.path) }
                return remaining.count > 1 ? DuplicateSet(hash: set.hash, size: set.size, files: remaining) : nil
            }
        }
    }

    // MARK: - Folders

    public func addFolder(_ url: URL) {
        do {
            let location = try module.locations.add(url)
            reload()
            if currentFolder == nil && locations.count == 1 { selection = location.path }
        } catch {
            onError(error.localizedDescription)
        }
    }

    /// "Add Downloads to Orbit": the folder picker, opened at the folder
    /// (choosing it is the permission). True if it was added.
    @discardableResult
    public func addFolderToOrbit(_ path: String) -> Bool {
        let folder = FileAccessPolicy.folderToAuthorize(for: path, isFolder: true)
        guard let url = Self.chooseFolder(prompt: "Add to Orbit", startingAt: folder) else { return false }
        let before = locations.count
        addFolder(url)
        return locations.count != before || module.core.fileAccess.isAllowed(path)
    }

    public func removeLocation(_ location: FileLocation) {
        module.locations.remove(location.id)
        reload()
    }

    public func reindex(_ location: FileLocation) {
        module.indexer.index(locationID: location.id)
    }

    public func setIndexingPaused(_ paused: Bool) {
        module.indexer.setPaused(paused)
        isIndexingPaused = paused
    }

    public var indexingSummary: String? {
        let active = progress.values.filter(\.isActive).sorted { $0.name < $1.name }
        if isIndexingPaused, !progress.isEmpty { return "Indexing paused" }
        return active.first?.description
    }

    // MARK: - Rules

    public func save(_ rule: FileRule) {
        do {
            try module.organizer.save(rule)
            reload()
        } catch {
            onError(error.localizedDescription)
        }
    }

    public func setEnabled(_ enabled: Bool, rule: FileRule) {
        do {
            try module.organizer.setEnabled(enabled, for: rule)
            reload()
        } catch {
            onError(error.localizedDescription)
        }
    }

    public func delete(_ rule: FileRule) {
        do {
            try module.organizer.delete(rule)
            reload()
        } catch {
            onError(error.localizedDescription)
        }
    }

    public func dryRun(_ rule: FileRule) async -> [DryRunItem] {
        await module.organizer.dryRun(rule)
    }

    public func approve(_ item: ReviewItem, action: RuleAction? = nil) {
        Task {
            let run = await module.organizer.approve(item, action: action)
            if run?.state == .failed { onError(run?.error ?? "Couldn't apply that.") }
            reload()
        }
    }

    public func ignore(_ item: ReviewItem) {
        module.organizer.ignore(item)
        reload()
    }

    public func approveAll() {
        let items = reviews
        Task {
            for item in items { _ = await module.organizer.approve(item) }
            reload()
        }
    }

    // MARK: - Duplicates

    public var isScanningDuplicates: Bool { duplicateTask != nil }

    public func findDuplicates(minimumSize: Int64 = 1) {
        duplicateTask?.cancel()
        duplicateProgress = DuplicateFinder.Progress(checked: 0, total: 0, phase: "Looking for files of the same size")
        let finder = module.duplicates
        duplicateTask = Task { [weak self] in
            let result = await Task.detached(priority: .utility) {
                try? await finder.find(minimumSize: minimumSize) { progress in
                    Task { @MainActor in self?.duplicateProgress = progress }
                }
            }.value
            guard let self else { return }
            if !Task.isCancelled, let result {
                self.duplicateSets = result
                self.lastDuplicateScan = Date()
            }
            self.duplicateProgress = nil
            self.duplicateTask = nil
        }
    }

    public func cancelDuplicateScan() {
        duplicateTask?.cancel()
        duplicateTask = nil
        duplicateProgress = nil
    }

    // MARK: - Projects

    public func createProject(named name: String) {
        do {
            let project = try module.projects.create(named: name)
            selectedProjectID = project.id
            reload()
        } catch {
            onError(error.localizedDescription)
        }
    }

    public func save(_ project: Project) {
        do {
            try module.projects.save(project)
            reload()
        } catch {
            onError(error.localizedDescription)
        }
    }

    public func delete(_ project: Project) {
        do {
            try module.projects.delete(project)
            if selectedProjectID == project.id { selectedProjectID = nil }
            reload()
        } catch {
            onError(error.localizedDescription)
        }
    }

    public func add(_ paths: [String], to project: Project) {
        do {
            _ = try module.projects.add(paths: paths, to: project)
            reload()
        } catch {
            onError(error.localizedDescription)
        }
    }

    public func repairCandidates(for link: ProjectLink) -> [FileEntry] {
        module.projects.repairCandidates(for: link)
    }

    public func repair(_ link: ProjectLink, in project: Project, to path: String) {
        do {
            try module.projects.repair(link, in: project, to: path)
            reload()
        } catch {
            onError(error.localizedDescription)
        }
    }

    // MARK: - Cleanup

    public func cleanupSuggestions() -> [CleanupItem] {
        module.cleanup.suggestions(duplicates: duplicateSets)
    }

    /// Low disk, by the user's own warning (or under 10% free).
    public var isDiskLow: Bool {
        guard let health else { return false }
        let limit = module.health.thresholds.first { $0.metric == .diskFree && $0.isEnabled }?.value ?? 20
        return Double(health.diskFree) / 1e9 < limit || (health.diskTotal > 0 && Double(health.diskFree) / Double(health.diskTotal) < 0.1)
    }

    // MARK: - Panels

    public static func chooseFolder(prompt: String = "Choose", startingAt path: String? = nil) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = prompt
        if let path { panel.directoryURL = URL(fileURLWithPath: FileLocation.normalize(path)) }
        return panel.runModal() == .OK ? panel.url : nil
    }

    public static func chooseItems() -> [URL] {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Add"
        return panel.runModal() == .OK ? panel.urls : []
    }
}

enum OrbitFormat {
    static func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }

    static func date(_ value: Date?) -> String {
        value.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "—"
    }

    static func color(_ category: FileCategory) -> Color {
        switch category {
        case .folder: return .blue
        case .document: return .orange
        case .code: return .green
        case .image: return .pink
        case .video: return .purple
        case .audio: return .teal
        case .archive: return .brown
        case .app: return .indigo
        case .other: return .gray
        }
    }

    static func nsColor(_ category: FileCategory) -> NSColor {
        switch category {
        case .folder: return .systemBlue
        case .document: return .systemOrange
        case .code: return .systemGreen
        case .image: return .systemPink
        case .video: return .systemPurple
        case .audio: return .systemTeal
        case .archive: return .systemBrown
        case .app: return .systemIndigo
        case .other: return .systemGray
        }
    }
}
