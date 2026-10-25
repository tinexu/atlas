import Foundation

/// Typed access to everything ATLAS keeps on disk: workflows, run history
/// and preferences (spec 7.5). Large 3D assets will live beside the
/// database file, not inside it.
public final class AtlasStore: @unchecked Sendable {
    public let database: SQLiteDatabase

    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()
    private let decoder = JSONDecoder()

    public init(database: SQLiteDatabase) throws {
        self.database = database
        try Schema.migrate(database)
    }

    /// `~/Library/Application Support/ATLAS/atlas.sqlite`
    public static func defaultURL() throws -> URL {
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )
        let folder = support.appendingPathComponent("ATLAS", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("atlas.sqlite")
    }

    public static func live() throws -> AtlasStore {
        try AtlasStore(database: SQLiteDatabase(path: defaultURL().path))
    }

    public static func inMemory() throws -> AtlasStore {
        try AtlasStore(database: SQLiteDatabase(path: ":memory:"))
    }

    // MARK: - Workflows

    /// Inserts or replaces a workflow's graph atomically: nodes, connections,
    /// variable definitions and settings. Remembered values of saved
    /// variables are kept.
    public func saveWorkflow(_ workflow: Workflow) throws {
        try database.transaction {
            try database.run(
                """
                INSERT INTO workflow (id, name, summary, is_enabled, failure_policy, settings_json, created_at, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    name = excluded.name,
                    summary = excluded.summary,
                    is_enabled = excluded.is_enabled,
                    failure_policy = excluded.failure_policy,
                    settings_json = excluded.settings_json,
                    updated_at = excluded.updated_at;
                """,
                [
                    .from(workflow.id), .text(workflow.name), .text(workflow.summary),
                    .from(workflow.isEnabled), .text(workflow.failurePolicy.rawValue), .text(try json(workflow.settings)),
                    .from(workflow.createdAt), .from(workflow.updatedAt),
                ]
            )
            try database.run("DELETE FROM workflow_node WHERE workflow_id = ?;", [.from(workflow.id)])
            for (position, step) in workflow.steps.enumerated() {
                try database.run(
                    """
                    INSERT INTO workflow_node
                        (id, workflow_id, position, action_id, parameters_json, is_enabled, label, timeout_seconds, max_retries,
                         kind, pos_x, pos_y, pos_z, config_json, ports_json, failure_policy)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
                    """,
                    [
                        .from(step.id), .from(workflow.id), .from(position), .text(step.actionID.rawValue),
                        .text(try json(step.parameters)), .from(step.isEnabled), .from(step.label),
                        .from(step.timeout), .from(step.maxRetries),
                        .text(step.kind.rawValue), .from(step.position.x), .from(step.position.y), .from(step.position.z),
                        .text(try json(step.config)), .text(try json(step.ports)), .from(step.failurePolicy?.rawValue),
                    ]
                )
            }
            try database.run("DELETE FROM workflow_connection WHERE workflow_id = ?;", [.from(workflow.id)])
            for (position, connection) in workflow.connections.enumerated() {
                try database.run(
                    """
                    INSERT INTO workflow_connection (id, workflow_id, position, from_node, from_port, to_node, to_port)
                    VALUES (?, ?, ?, ?, ?, ?, ?);
                    """,
                    [
                        .from(connection.id), .from(workflow.id), .from(position), .from(connection.fromNode),
                        .text(connection.fromPort), .from(connection.toNode), .text(connection.toPort),
                    ]
                )
            }
            let names = workflow.variables.map(\.name)
            if names.isEmpty {
                try database.run("DELETE FROM workflow_variable WHERE workflow_id = ?;", [.from(workflow.id)])
            } else {
                let marks = Array(repeating: "?", count: names.count).joined(separator: ", ")
                try database.run("DELETE FROM workflow_variable WHERE workflow_id = ? AND name NOT IN (\(marks));",
                                 [.from(workflow.id)] + names.map(SQLValue.text))
            }
            for variable in workflow.variables {
                try database.run(
                    """
                    INSERT INTO workflow_variable (workflow_id, name, initial_json, is_saved) VALUES (?, ?, ?, ?)
                    ON CONFLICT(workflow_id, name) DO UPDATE SET
                        initial_json = excluded.initial_json,
                        is_saved = excluded.is_saved;
                    """,
                    [.from(workflow.id), .text(variable.name), .text(try json(variable.initialValue)), .from(variable.isSaved)]
                )
            }
        }
    }

    public func workflows() throws -> [Workflow] {
        let rows = try database.query("SELECT * FROM workflow ORDER BY created_at ASC;")
        let graph = try loadGraph(where: nil)
        return rows.compactMap { workflow(from: $0, graph: graph) }
    }

    public func workflow(id: UUID) throws -> Workflow? {
        guard let row = try database.query("SELECT * FROM workflow WHERE id = ?;", [.from(id)]).first else {
            return nil
        }
        return workflow(from: row, graph: try loadGraph(where: id))
    }

    public func deleteWorkflow(id: UUID) throws {
        // Nodes, connections and variables go with it (ON DELETE CASCADE); run history stays.
        try database.run("DELETE FROM workflow WHERE id = ?;", [.from(id)])
    }

    /// Remembered values of a workflow's saved variables.
    public func savedVariableValues(workflowID: UUID) throws -> [String: ActionValue] {
        let rows = try database.query(
            "SELECT name, value_json FROM workflow_variable WHERE workflow_id = ? AND is_saved = 1 AND value_json IS NOT NULL;",
            [.from(workflowID)]
        )
        var values: [String: ActionValue] = [:]
        for row in rows {
            guard let name = row.string("name"), let json = row.string("value_json"),
                  let value = try? decoder.decode(ActionValue.self, from: Data(json.utf8))
            else { continue }
            values[name] = value
        }
        return values
    }

    public func setSavedVariableValue(_ value: ActionValue, name: String, workflowID: UUID) throws {
        try database.run(
            "UPDATE workflow_variable SET value_json = ? WHERE workflow_id = ? AND name = ?;",
            [.text(try json(value)), .from(workflowID), .text(name)]
        )
    }

    private struct Graph {
        var steps: [UUID: [WorkflowStep]] = [:]
        var connections: [UUID: [WorkflowConnection]] = [:]
        var variables: [UUID: [WorkflowVariable]] = [:]
    }

    private func loadGraph(where workflowID: UUID?) throws -> Graph {
        func rows(_ table: String, order: String) throws -> [SQLRow] {
            if let workflowID {
                return try database.query("SELECT * FROM \(table) WHERE workflow_id = ? ORDER BY \(order);", [.from(workflowID)])
            }
            return try database.query("SELECT * FROM \(table) ORDER BY workflow_id, \(order);")
        }
        var graph = Graph()
        for row in try rows("workflow_node", order: "position ASC") {
            guard let workflowID = row.uuid("workflow_id"),
                  let id = row.uuid("id"),
                  let actionID = row.string("action_id")
            else { continue }
            graph.steps[workflowID, default: []].append(WorkflowStep(
                id: id,
                kind: row.string("kind").flatMap(NodeKind.init(rawValue:)) ?? .action,
                actionID: ActionID(actionID),
                parameters: decodeParameters(row.string("parameters_json")),
                config: decode(NodeConfig.self, row.string("config_json")) ?? NodeConfig(),
                position: NodePosition(x: row.double("pos_x") ?? 0, y: row.double("pos_y") ?? 0, z: row.double("pos_z") ?? 0),
                ports: decode([NodePort].self, row.string("ports_json")) ?? [],
                isEnabled: row.bool("is_enabled") ?? true,
                label: row.string("label"),
                timeout: row.double("timeout_seconds"),
                maxRetries: row.int("max_retries") ?? 0,
                failurePolicy: row.string("failure_policy").flatMap(FailurePolicy.init(rawValue:))
            ))
        }
        for row in try rows("workflow_connection", order: "position ASC") {
            guard let workflowID = row.uuid("workflow_id"), let id = row.uuid("id"),
                  let from = row.uuid("from_node"), let to = row.uuid("to_node"),
                  let fromPort = row.string("from_port"), let toPort = row.string("to_port")
            else { continue }
            graph.connections[workflowID, default: []].append(
                WorkflowConnection(id: id, fromNode: from, fromPort: fromPort, toNode: to, toPort: toPort)
            )
        }
        for row in try rows("workflow_variable", order: "name ASC") {
            guard let workflowID = row.uuid("workflow_id"), let name = row.string("name") else { continue }
            graph.variables[workflowID, default: []].append(WorkflowVariable(
                name: name,
                initialValue: decode(ActionValue.self, row.string("initial_json")) ?? .null,
                isSaved: row.bool("is_saved") ?? false
            ))
        }
        return graph
    }

    private func workflow(from row: SQLRow, graph: Graph) -> Workflow? {
        guard let id = row.uuid("id"), let name = row.string("name") else { return nil }
        return Workflow(
            id: id,
            name: name,
            summary: row.string("summary") ?? "",
            isEnabled: row.bool("is_enabled") ?? true,
            failurePolicy: row.string("failure_policy").flatMap(FailurePolicy.init(rawValue:)) ?? .stopOnFailure,
            steps: graph.steps[id] ?? [],
            connections: graph.connections[id] ?? [],
            variables: graph.variables[id] ?? [],
            settings: decode(WorkflowSettings.self, row.string("settings_json")) ?? .default,
            createdAt: row.date("created_at") ?? Date(),
            updatedAt: row.date("updated_at") ?? Date()
        )
    }

    // MARK: - Run history

    /// Inserts or updates a run and replaces its step records.
    public func saveRun(_ run: WorkflowRun) throws {
        try database.transaction {
            try database.run(
                """
                INSERT INTO workflow_run
                    (id, workflow_id, workflow_name, trigger, state, started_at, finished_at, error, trigger_payload_json, path_json)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    state = excluded.state,
                    finished_at = excluded.finished_at,
                    error = excluded.error,
                    path_json = excluded.path_json;
                """,
                [
                    .from(run.id), .from(run.workflowID), .text(run.workflowName), .text(run.trigger),
                    .text(run.state.rawValue), .from(run.startedAt), .from(run.finishedAt), .from(run.error),
                    .text(try json(run.triggerPayload)), .text(try json(run.path)),
                ]
            )
            try database.run("DELETE FROM workflow_run_step WHERE run_id = ?;", [.from(run.id)])
            for step in run.steps {
                try database.run(
                    """
                    INSERT INTO workflow_run_step
                        (run_id, position, node_id, action_id, label, state, attempts,
                         started_at, finished_at, message, error, output_json, inputs_json, kind)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
                    """,
                    [
                        .from(run.id), .from(step.position), .from(step.nodeID), .text(step.actionID.rawValue),
                        .text(step.label), .text(step.state.rawValue), .from(step.attempts),
                        .from(step.startedAt), .from(step.finishedAt), .from(step.message), .from(step.error),
                        .text(try json(step.output)), .text(try json(step.inputs)), .text(step.kind.rawValue),
                    ]
                )
            }
        }
    }

    /// Most recent runs first, optionally for one workflow.
    public func runs(workflowID: UUID? = nil, limit: Int = 50) throws -> [WorkflowRun] {
        try runs(matching: RunQuery(workflowID: workflowID), limit: limit)
    }

    /// Most recent runs first, filtered.
    public func runs(matching query: RunQuery, limit: Int = 200) throws -> [WorkflowRun] {
        var clauses: [String] = []
        var values: [SQLValue] = []
        if let id = query.runID { clauses.append("id = ?"); values.append(.from(id)) }
        if let id = query.workflowID { clauses.append("workflow_id = ?"); values.append(.from(id)) }
        if let trigger = query.trigger {
            if trigger.hasSuffix("*") {
                clauses.append("trigger LIKE ?")
                values.append(.text(String(trigger.dropLast()) + "%"))
            } else {
                clauses.append("trigger = ?")
                values.append(.text(trigger))
            }
        }
        if let states = query.states, !states.isEmpty {
            clauses.append("state IN (\(Array(repeating: "?", count: states.count).joined(separator: ", ")))")
            values.append(contentsOf: states.map { .text($0.rawValue) })
        }
        if let from = query.from { clauses.append("started_at >= ?"); values.append(.from(from)) }
        if let to = query.to { clauses.append("started_at < ?"); values.append(.from(to)) }
        let filter = clauses.isEmpty ? "" : "WHERE " + clauses.joined(separator: " AND ")
        let runRows = try database.query(
            "SELECT * FROM workflow_run \(filter) ORDER BY started_at DESC LIMIT ?;", values + [.from(limit)]
        )
        return try runRows.compactMap { row in
            guard let id = row.uuid("id"), let workflowID = row.uuid("workflow_id") else { return nil }
            let steps = try database.query(
                "SELECT * FROM workflow_run_step WHERE run_id = ? ORDER BY position ASC;", [.from(id)]
            ).compactMap(stepRecord(from:))
            return WorkflowRun(
                id: id,
                workflowID: workflowID,
                workflowName: row.string("workflow_name") ?? "Untitled",
                trigger: row.string("trigger") ?? "manual",
                state: row.string("state").flatMap(RunState.init(rawValue:)) ?? .failed,
                startedAt: row.date("started_at") ?? Date(),
                finishedAt: row.date("finished_at"),
                error: row.string("error"),
                steps: steps,
                triggerPayload: decodeParameters(row.string("trigger_payload_json")),
                path: decode([UUID].self, row.string("path_json")) ?? []
            )
        }
    }

    public func run(id: UUID) throws -> WorkflowRun? {
        // Reuse the list query path for consistent decoding.
        try runs(matching: RunQuery(runID: id), limit: 1).first
    }

    /// Keeps the newest `count` runs and deletes the rest.
    public func pruneRuns(keepingLatest count: Int) throws {
        try database.run(
            """
            DELETE FROM workflow_run WHERE id NOT IN (
                SELECT id FROM workflow_run ORDER BY started_at DESC LIMIT ?
            );
            """,
            [.from(count)]
        )
    }

    /// Runs left in `running`/`pending` by a crash or force-quit are marked
    /// canceled at launch, so history never shows a phantom active run.
    public func closeInterruptedRuns(at date: Date = Date()) throws {
        try database.transaction {
            try database.run(
                """
                UPDATE workflow_run_step SET state = 'canceled', finished_at = ?
                WHERE state IN ('running', 'pending')
                  AND run_id IN (SELECT id FROM workflow_run WHERE state IN ('running', 'pending'));
                """,
                [.from(date)]
            )
            try database.run(
                """
                UPDATE workflow_run SET state = 'canceled', finished_at = ?, error = 'ATLAS quit before this run finished.'
                WHERE state IN ('running', 'pending');
                """,
                [.from(date)]
            )
        }
    }

    private func stepRecord(from row: SQLRow) -> StepRecord? {
        guard let position = row.int("position"),
              let nodeID = row.uuid("node_id"),
              let actionID = row.string("action_id")
        else { return nil }
        return StepRecord(
            position: position,
            nodeID: nodeID,
            actionID: ActionID(actionID),
            label: row.string("label") ?? actionID,
            state: row.string("state").flatMap(RunState.init(rawValue:)) ?? .failed,
            attempts: row.int("attempts") ?? 0,
            startedAt: row.date("started_at"),
            finishedAt: row.date("finished_at"),
            message: row.string("message"),
            error: row.string("error"),
            output: decodeParameters(row.string("output_json")),
            inputs: decodeParameters(row.string("inputs_json")),
            kind: row.string("kind").flatMap(NodeKind.init(rawValue:)) ?? .action
        )
    }

    // MARK: - Preferences

    public func preference<T: Decodable>(_ key: String, as type: T.Type) throws -> T? {
        guard let json = try database.query(
            "SELECT value_json FROM user_preference WHERE key = ?;", [.text(key)]
        ).first?.string("value_json") else { return nil }
        return try decoder.decode(T.self, from: Data(json.utf8))
    }

    public func setPreference<T: Encodable>(_ value: T?, for key: String) throws {
        guard let value else {
            try database.run("DELETE FROM user_preference WHERE key = ?;", [.text(key)])
            return
        }
        try database.run(
            """
            INSERT INTO user_preference (key, value_json) VALUES (?, ?)
            ON CONFLICT(key) DO UPDATE SET value_json = excluded.value_json;
            """,
            [.text(key), .text(try json(value))]
        )
    }

    // MARK: - JSON helpers

    private func json<T: Encodable>(_ value: T) throws -> String {
        String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    private func decode<T: Decodable>(_ type: T.Type, _ json: String?) -> T? {
        guard let json, let data = json.data(using: .utf8) else { return nil }
        return try? decoder.decode(T.self, from: data)
    }

    private func decodeParameters(_ json: String?) -> ActionParameters {
        guard let json, let data = json.data(using: .utf8) else { return [:] }
        return (try? decoder.decode(ActionParameters.self, from: data)) ?? [:]
    }
}

/// Filters for run history.
public struct RunQuery: Sendable, Equatable {
    public var runID: UUID?
    public var workflowID: UUID?
    /// An exact trigger, or a prefix ending in "*", e.g. "trigger.*".
    public var trigger: String?
    public var states: [RunState]?
    public var from: Date?
    public var to: Date?

    public init(runID: UUID? = nil, workflowID: UUID? = nil, trigger: String? = nil, states: [RunState]? = nil,
                from: Date? = nil, to: Date? = nil) {
        self.runID = runID
        self.workflowID = workflowID
        self.trigger = trigger
        self.states = states
        self.from = from
        self.to = to
    }
}
