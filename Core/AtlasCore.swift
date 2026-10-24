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

    public init(
        store: AtlasStore,
        system: SystemAdapter,
        permissionProvider: PermissionProvider,
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
    }

    #if os(macOS)
    /// The production configuration: on-disk database, real macOS adapters.
    public static func live() throws -> AtlasCore {
        let store = try AtlasStore.live()
        try store.closeInterruptedRuns()
        try store.pruneRuns(keepingLatest: 1_000)
        let core = AtlasCore(store: store, system: MacSystemAdapter(), permissionProvider: MacPermissionProvider())
        try core.seedSampleWorkflowsIfNeeded()
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
