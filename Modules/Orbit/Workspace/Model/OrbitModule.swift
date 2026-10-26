import AtlasCore
import Foundation

/// Wires Orbit into an `AtlasCore`: registers `file.search` and
/// `orbit.organize`, and owns the indexer, rules, search, duplicates,
/// projects, cleanup and Mac Health. Everything keeps working with every
/// window closed.
public final class OrbitModule: @unchecked Sendable {
    public let core: AtlasCore
    public let indexer: FileIndexer
    public let locations: LocationManager
    public let search: FileSearch
    public let organizer: FileOrganizer
    public let duplicates: DuplicateFinder
    public let projects: ProjectManager
    public let cleanup: CleanupAdvisor
    public let health: HealthMonitor

    public init(core: AtlasCore, watcher: FileTreeWatching?, sensor: HealthSensor) throws {
        self.core = core
        indexer = FileIndexer(store: core.store, events: core.events, watcher: watcher)
        locations = LocationManager(core: core, indexer: indexer)
        search = FileSearch(store: core.store)
        organizer = FileOrganizer(core: core)
        duplicates = DuplicateFinder(store: core.store, events: core.events)
        projects = ProjectManager(core: core)
        cleanup = CleanupAdvisor(core: core)
        health = HealthMonitor(sensor: sensor, store: core.store, events: core.events)
        try core.registry.register(FileSearchAction(search: search))
        try core.registry.register(OrganizeFileAction(store: core.store, registry: core.registry))
    }

    #if os(macOS)
    /// The production configuration: FSEvents and real health readings.
    public static func live(core: AtlasCore) throws -> OrbitModule {
        try OrbitModule(core: core, watcher: MacFileTreeWatcher(), sensor: MacHealthSensor(system: core.system))
    }
    #endif

    /// Resolves folder bookmarks, catches the index up, and starts rules,
    /// project links and health sampling.
    public func start() {
        locations.resolveBookmarks()
        indexer.start()
        try? organizer.seedStarterRulesIfNeeded()
        organizer.startDailySweep()
        projects.verifyLinks()
        projects.startFollowingSpaces()
        health.start()
    }
}
