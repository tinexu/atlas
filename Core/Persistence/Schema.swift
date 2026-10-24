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

        // v2 — Stage 02: Spaces. The active Space is a user_preference row
        // (`spaces.activeSpaceID`), so it needs no table of its own.
        """
        CREATE TABLE space (
            id                   TEXT PRIMARY KEY,
            name                 TEXT NOT NULL,
            group_name           TEXT NOT NULL,
            template_id          TEXT NOT NULL,
            accent_color         TEXT NOT NULL,
            slot                 INTEGER NOT NULL DEFAULT 0,
            transition_behavior  TEXT NOT NULL DEFAULT 'leaveRunning',
            is_pinned            INTEGER NOT NULL DEFAULT 0,
            created_at           REAL NOT NULL,
            updated_at           REAL NOT NULL
        );
        CREATE INDEX idx_space_slot ON space(slot);

        -- No foreign key to workflow: a profile whose automation was deleted
        -- stays visible and reports the problem instead of vanishing.
        CREATE TABLE activation_profile (
            id           TEXT PRIMARY KEY,
            space_id     TEXT NOT NULL REFERENCES space(id) ON DELETE CASCADE,
            position     INTEGER NOT NULL DEFAULT 0,
            name         TEXT NOT NULL,
            workflow_id  TEXT NOT NULL,
            is_default   INTEGER NOT NULL DEFAULT 0
        );
        CREATE INDEX idx_activation_profile_space ON activation_profile(space_id, position);

        CREATE TABLE space_object (
            id               TEXT PRIMARY KEY,
            space_id         TEXT NOT NULL REFERENCES space(id) ON DELETE CASCADE,
            kind             TEXT NOT NULL,
            label            TEXT,
            transform_json   TEXT NOT NULL,
            action_id        TEXT,
            parameters_json  TEXT NOT NULL DEFAULT '{}',
            workflow_id      TEXT
        );
        CREATE INDEX idx_space_object_space ON space_object(space_id);
        """,

        // v3 — Stage 03: window layouts and session snapshots. Layout rules
        // get their own rows so they can be edited one at a time; a
        // snapshot's rules are a frozen record, kept as JSON.
        """
        CREATE TABLE window_layout (
            id                    TEXT PRIMARY KEY,
            name                  TEXT NOT NULL,
            display_profile_json  TEXT,
            created_at            REAL NOT NULL,
            updated_at            REAL NOT NULL
        );

        CREATE TABLE window_rule (
            id                TEXT PRIMARY KEY,
            layout_id         TEXT NOT NULL REFERENCES window_layout(id) ON DELETE CASCADE,
            position          INTEGER NOT NULL,
            bundle_id         TEXT NOT NULL,
            app_name          TEXT NOT NULL DEFAULT '',
            title_match_json  TEXT,
            display_json      TEXT NOT NULL,
            frame_json        TEXT NOT NULL,
            state             TEXT NOT NULL DEFAULT 'normal',
            z_order           INTEGER NOT NULL DEFAULT 0
        );
        CREATE INDEX idx_window_rule_layout ON window_rule(layout_id, position);

        CREATE TABLE session_snapshot (
            id                    TEXT PRIMARY KEY,
            name                  TEXT NOT NULL,
            created_at            REAL NOT NULL,
            space_id              TEXT,
            is_automatic          INTEGER NOT NULL DEFAULT 0,
            running_apps_json     TEXT NOT NULL DEFAULT '[]',
            rules_json            TEXT NOT NULL DEFAULT '[]',
            display_profile_json  TEXT
        );
        CREATE INDEX idx_session_snapshot_space ON session_snapshot(space_id, created_at DESC);

        -- No foreign key: a profile whose layout was deleted just stops
        -- arranging windows.
        ALTER TABLE activation_profile ADD COLUMN window_layout_id TEXT;
        ALTER TABLE space ADD COLUMN snapshot_on_leave INTEGER NOT NULL DEFAULT 1;
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
