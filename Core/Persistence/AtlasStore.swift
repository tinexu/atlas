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

    /// Inserts or replaces a workflow and all of its steps atomically.
    public func saveWorkflow(_ workflow: Workflow) throws {
        try database.transaction {
            try database.run(
                """
                INSERT INTO workflow (id, name, summary, is_enabled, failure_policy, created_at, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    name = excluded.name,
                    summary = excluded.summary,
                    is_enabled = excluded.is_enabled,
                    failure_policy = excluded.failure_policy,
                    updated_at = excluded.updated_at;
                """,
                [
                    .from(workflow.id), .text(workflow.name), .text(workflow.summary),
                    .from(workflow.isEnabled), .text(workflow.failurePolicy.rawValue),
                    .from(workflow.createdAt), .from(workflow.updatedAt),
                ]
            )
            try database.run("DELETE FROM workflow_node WHERE workflow_id = ?;", [.from(workflow.id)])
            for (position, step) in workflow.steps.enumerated() {
                try database.run(
                    """
                    INSERT INTO workflow_node
                        (id, workflow_id, position, action_id, parameters_json, is_enabled, label, timeout_seconds, max_retries)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?);
                    """,
                    [
                        .from(step.id), .from(workflow.id), .from(position), .text(step.actionID.rawValue),
                        .text(try json(step.parameters)), .from(step.isEnabled), .from(step.label),
                        .from(step.timeout), .from(step.maxRetries),
                    ]
                )
            }
        }
    }

    public func workflows() throws -> [Workflow] {
        let rows = try database.query("SELECT * FROM workflow ORDER BY created_at ASC;")
        let stepsByWorkflow = try loadSteps(where: nil)
        return rows.compactMap { workflow(from: $0, steps: stepsByWorkflow) }
    }

    public func workflow(id: UUID) throws -> Workflow? {
        guard let row = try database.query("SELECT * FROM workflow WHERE id = ?;", [.from(id)]).first else {
            return nil
        }
        return workflow(from: row, steps: try loadSteps(where: id))
    }

    public func deleteWorkflow(id: UUID) throws {
        // Steps go with it (ON DELETE CASCADE); run history stays.
        try database.run("DELETE FROM workflow WHERE id = ?;", [.from(id)])
    }

    private func loadSteps(where workflowID: UUID?) throws -> [UUID: [WorkflowStep]] {
        let rows: [SQLRow]
        if let workflowID {
            rows = try database.query(
                "SELECT * FROM workflow_node WHERE workflow_id = ? ORDER BY position ASC;", [.from(workflowID)]
            )
        } else {
            rows = try database.query("SELECT * FROM workflow_node ORDER BY workflow_id, position ASC;")
        }
        var result: [UUID: [WorkflowStep]] = [:]
        for row in rows {
            guard let workflowID = row.uuid("workflow_id"),
                  let id = row.uuid("id"),
                  let actionID = row.string("action_id")
            else { continue }
            let step = WorkflowStep(
                id: id,
                actionID: ActionID(actionID),
                parameters: decodeParameters(row.string("parameters_json")),
                isEnabled: row.bool("is_enabled") ?? true,
                label: row.string("label"),
                timeout: row.double("timeout_seconds"),
                maxRetries: row.int("max_retries") ?? 0
            )
            result[workflowID, default: []].append(step)
        }
        return result
    }

    private func workflow(from row: SQLRow, steps: [UUID: [WorkflowStep]]) -> Workflow? {
        guard let id = row.uuid("id"), let name = row.string("name") else { return nil }
        return Workflow(
            id: id,
            name: name,
            summary: row.string("summary") ?? "",
            isEnabled: row.bool("is_enabled") ?? true,
            failurePolicy: row.string("failure_policy").flatMap(FailurePolicy.init(rawValue:)) ?? .stopOnFailure,
            steps: steps[id] ?? [],
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
                INSERT INTO workflow_run (id, workflow_id, workflow_name, trigger, state, started_at, finished_at, error)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    state = excluded.state,
                    finished_at = excluded.finished_at,
                    error = excluded.error;
                """,
                [
                    .from(run.id), .from(run.workflowID), .text(run.workflowName), .text(run.trigger),
                    .text(run.state.rawValue), .from(run.startedAt), .from(run.finishedAt), .from(run.error),
                ]
            )
            try database.run("DELETE FROM workflow_run_step WHERE run_id = ?;", [.from(run.id)])
            for step in run.steps {
                try database.run(
                    """
                    INSERT INTO workflow_run_step
                        (run_id, position, node_id, action_id, label, state, attempts,
                         started_at, finished_at, message, error, output_json)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
                    """,
                    [
                        .from(run.id), .from(step.position), .from(step.nodeID), .text(step.actionID.rawValue),
                        .text(step.label), .text(step.state.rawValue), .from(step.attempts),
                        .from(step.startedAt), .from(step.finishedAt), .from(step.message), .from(step.error),
                        .text(try json(step.output)),
                    ]
                )
            }
        }
    }

    /// Most recent runs first, optionally for one workflow.
    public func runs(workflowID: UUID? = nil, limit: Int = 50) throws -> [WorkflowRun] {
        let runRows: [SQLRow]
        if let workflowID {
            runRows = try database.query(
                "SELECT * FROM workflow_run WHERE workflow_id = ? ORDER BY started_at DESC LIMIT ?;",
                [.from(workflowID), .from(limit)]
            )
        } else {
            runRows = try database.query(
                "SELECT * FROM workflow_run ORDER BY started_at DESC LIMIT ?;", [.from(limit)]
            )
        }
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
                steps: steps
            )
        }
    }

    public func run(id: UUID) throws -> WorkflowRun? {
        // Reuse the list query path for consistent decoding.
        guard let row = try database.query("SELECT workflow_id FROM workflow_run WHERE id = ?;", [.from(id)]).first,
              let workflowID = row.uuid("workflow_id")
        else { return nil }
        return try runs(workflowID: workflowID, limit: 500).first { $0.id == id }
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
            output: decodeParameters(row.string("output_json"))
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

    private func decodeParameters(_ json: String?) -> ActionParameters {
        guard let json, let data = json.data(using: .utf8) else { return [:] }
        return (try? decoder.decode(ActionParameters.self, from: data)) ?? [:]
    }
}
