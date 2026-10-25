import AtlasCore
import Foundation

/// Follows a workflow's runs as they happen, so the editor can light nodes
/// up: running, succeeded, failed, skipped, and connections as data flows.
@MainActor
public final class LiveRunMonitor: ObservableObject {
    @Published public private(set) var runID: UUID?
    @Published public private(set) var nodeStates: [UUID: RunState] = [:]
    /// Connections a value or the flow just passed along.
    @Published public private(set) var flowing: Set<UUID> = []
    @Published public private(set) var isRunning = false
    /// The latest finished run, from history.
    @Published public private(set) var lastRun: WorkflowRun?

    private let workflowID: UUID
    private let store: AtlasStore
    private let connections: () -> [WorkflowConnection]
    private var task: Task<Void, Never>?
    private var fadeTasks: [UUID: Task<Void, Never>] = [:]

    public init(workflowID: UUID, events: EventBus, store: AtlasStore, connections: @escaping () -> [WorkflowConnection]) {
        self.workflowID = workflowID
        self.store = store
        self.connections = connections
        lastRun = try? store.runs(workflowID: workflowID, limit: 1).first
        let stream = events.stream()
        task = Task { [weak self] in
            for await event in stream {
                guard let self else { return }
                self.handle(event)
            }
        }
    }

    deinit { task?.cancel() }

    /// Shows a past run's states (e.g. the last one) until a new run starts.
    public func show(_ run: WorkflowRun?) {
        guard !isRunning else { return }
        nodeStates = Dictionary(run?.steps.map { ($0.nodeID, $0.state) } ?? [], uniquingKeysWith: { a, _ in a })
        flowing = []
    }

    public func clear() {
        guard !isRunning else { return }
        nodeStates = [:]
        flowing = []
    }

    private func handle(_ event: AtlasEvent) {
        let p = event.payload
        guard p["workflowId"]?.stringValue == workflowID.uuidString else { return }
        let run = p["runId"]?.stringValue.flatMap(UUID.init(uuidString:))
        switch event.name {
        case AtlasEvent.Name.workflowStarted:
            runID = run
            isRunning = true
            nodeStates = [:]
            flowing = []
        case AtlasEvent.Name.nodeStarted:
            guard run == runID, let node = p["nodeId"]?.stringValue.flatMap(UUID.init(uuidString:)) else { return }
            nodeStates[node] = .running
            // Light up connections arriving from nodes that already ran.
            let arriving = connections().filter { $0.toNode == node && nodeStates[$0.fromNode] == .succeeded }
            for connection in arriving { pulse(connection.id) }
        case AtlasEvent.Name.nodeFinished:
            guard run == runID, let node = p["nodeId"]?.stringValue.flatMap(UUID.init(uuidString:)),
                  let state = p["stepState"]?.stringValue.flatMap(RunState.init(rawValue:))
            else { return }
            nodeStates[node] = state
        case AtlasEvent.Name.workflowFinished:
            guard p["recordOnly"] == nil, run == runID || runID == nil else { return }
            isRunning = false
            if let run, let record = try? store.run(id: run) {
                lastRun = record
                for step in record.steps { nodeStates[step.nodeID] = step.state }
            }
        default:
            break
        }
    }

    private func pulse(_ connection: UUID) {
        flowing.insert(connection)
        fadeTasks[connection]?.cancel()
        fadeTasks[connection] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            guard !Task.isCancelled else { return }
            self?.flowing.remove(connection)
        }
    }
}
