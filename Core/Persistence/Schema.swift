import Foundation

/// Ordered schema migrations. `PRAGMA user_version` records how many have
/// run, so each one executes exactly once. Never edit a shipped migration;
/// append a new one instead.
enum Schema {
    static let migrations: [String] = [
        // v1 — Stage 01: workflows, run history, preferences.
        """
        CREATE TABLE workflow (
            id              TEXT PRIMARY KEY,
            name            TEXT NOT NULL,
            summary         TEXT NOT NULL DEFAULT '',
            is_enabled      INTEGER NOT NULL DEFAULT 1,
            failure_policy  TEXT NOT NULL DEFAULT 'stopOnFailure',
            created_at      REAL NOT NULL,
            updated_at      REAL NOT NULL
        );

        -- Steps are stored as nodes so Stage 04's graph editor can add a
        -- workflow_connection table without migrating existing data.
        CREATE TABLE workflow_node (
            id               TEXT PRIMARY KEY,
            workflow_id      TEXT NOT NULL REFERENCES workflow(id) ON DELETE CASCADE,
            position         INTEGER NOT NULL,
            action_id        TEXT NOT NULL,
            parameters_json  TEXT NOT NULL DEFAULT '{}',
            is_enabled       INTEGER NOT NULL DEFAULT 1,
            label            TEXT,
            timeout_seconds  REAL,
            max_retries      INTEGER NOT NULL DEFAULT 0
        );
        CREATE INDEX idx_workflow_node_workflow ON workflow_node(workflow_id, position);

        -- No foreign key to workflow: history outlives deleted workflows.
        CREATE TABLE workflow_run (
            id             TEXT PRIMARY KEY,
            workflow_id    TEXT NOT NULL,
            workflow_name  TEXT NOT NULL,
            trigger        TEXT NOT NULL,
            state          TEXT NOT NULL,
            started_at     REAL NOT NULL,
            finished_at    REAL,
            error          TEXT
        );
        CREATE INDEX idx_workflow_run_started ON workflow_run(started_at DESC);
        CREATE INDEX idx_workflow_run_workflow ON workflow_run(workflow_id, started_at DESC);

        CREATE TABLE workflow_run_step (
            run_id       TEXT NOT NULL REFERENCES workflow_run(id) ON DELETE CASCADE,
            position     INTEGER NOT NULL,
            node_id      TEXT NOT NULL,
            action_id    TEXT NOT NULL,
            label        TEXT NOT NULL,
            state        TEXT NOT NULL,
            attempts     INTEGER NOT NULL DEFAULT 0,
            started_at   REAL,
            finished_at  REAL,
            message      TEXT,
            error        TEXT,
            output_json  TEXT NOT NULL DEFAULT '{}',
            PRIMARY KEY (run_id, position)
        );

        CREATE TABLE user_preference (
            key         TEXT PRIMARY KEY,
            value_json  TEXT NOT NULL
        );
        """,
    ]

    static var currentVersion: Int { migrations.count }

    static func migrate(_ database: SQLiteDatabase) throws {
        let current = database.userVersion
        guard current < migrations.count else { return }
        for (index, sql) in migrations.enumerated() where index >= current {
            try database.transaction {
                try database.execute(sql)
                try database.setUserVersion(index + 1)
            }
            AtlasLog.persistence.info("Applied schema migration v\(index + 1)")
        }
    }
}
