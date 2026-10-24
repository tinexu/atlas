import Foundation

/// The assembled foundation every module and UI surface talks to (spec 7).
///
/// Spaces, Orbit, Flow and Companion never launch apps or touch files
/// themselves; they publish events and hand registered actions to `engine`.
public final class AtlasCore: @unchecked Sendable {
    public let store: AtlasStore
    public let events: EventBus
    public let registry: ActionRegistry
    public let permissions: PermissionManager
    public let system: SystemAdapter
    public let engine: AutomationEngine
    /// Window layouts and session snapshots (Stage 03).
    public let windows: WindowService

    public init(
        store: AtlasStore,
        system: SystemAdapter,
        permissionProvider: PermissionProvider,
        windowAdapter: WindowAdapter = UnavailableWindowAdapter(),
        registry: ActionRegistry = .standard(),
        events: EventBus = EventBus()
    ) {
        let permissions = PermissionManager(provider: permissionProvider, store: store)
        self.store = store
        self.events = events
        self.registry = registry
        self.system = system
        self.permissions = permissions
        self.engine = AutomationEngine(
            registry: registry,
            permissions: permissions,
            system: system,
            events: events,
            store: store
        )
        self.windows = WindowService(
            adapter: windowAdapter,
            store: store,
            system: system,
            events: events,
            registry: registry,
            permissions: permissions
        )
        for action in WindowActions.all(service: windows) {
            do {
                try registry.register(action)
            } catch {
                AtlasLog.engine.error("Couldn't register \(action.descriptor.id.rawValue, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    #if os(macOS)
    /// The production configuration: on-disk database, real macOS adapters.
    public static func live() throws -> AtlasCore {
        let store = try AtlasStore.live()
        try store.closeInterruptedRuns()
        try store.pruneRuns(keepingLatest: 1_000)
        let core = AtlasCore(
            store: store,
            system: MacSystemAdapter(),
            permissionProvider: MacPermissionProvider(),
            windowAdapter: MacWindowAdapter()
        )
        try core.seedSampleWorkflowsIfNeeded()
        core.windows.startObservingDisplays()
        return core
    }
    #endif

    // MARK: - Workflow management

    /// Saves a workflow, stamping `updatedAt`, and announces the change.
    @discardableResult
    public func save(_ workflow: Workflow) throws -> Workflow {
        var saved = workflow
        saved.updatedAt = Date()
        if saved.name.trimmingCharacters(in: .whitespaces).isEmpty { saved.name = "Untitled Automation" }
        try store.saveWorkflow(saved)
        events.publish(AtlasEvent(AtlasEvent.Name.workflowSaved, payload: ["workflowId": .string(saved.id.uuidString)]))
        return saved
    }

    public func delete(workflowID: UUID) throws {
        try store.deleteWorkflow(id: workflowID)
        events.publish(AtlasEvent(AtlasEvent.Name.workflowDeleted, payload: ["workflowId": .string(workflowID.uuidString)]))
    }

    /// Adds the starter workflows once, on first launch only, so deleting
    /// them is permanent.
    public func seedSampleWorkflowsIfNeeded() throws {
        let key = "onboarding.seededSamples.v1"
        guard try store.preference(key, as: Bool.self) != true else { return }
        if try store.workflows().isEmpty {
            for workflow in SampleWorkflows.all {
                try store.saveWorkflow(workflow)
            }
        }
        try store.setPreference(true, for: key)
    }
}
