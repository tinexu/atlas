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

        // v4 — Stage 04: workflows become graphs. Nodes gain a kind, a
        // position, configuration and typed ports; connections and
        // variables get tables. Every existing step list becomes a straight
        // chain of trigger-less nodes. Node IDs are kept, so old run history
        // still lines up with its nodes.
        """
        ALTER TABLE workflow_node ADD COLUMN kind TEXT NOT NULL DEFAULT 'action';
        ALTER TABLE workflow_node ADD COLUMN pos_x REAL NOT NULL DEFAULT 0;
        ALTER TABLE workflow_node ADD COLUMN pos_y REAL NOT NULL DEFAULT 0;
        ALTER TABLE workflow_node ADD COLUMN pos_z REAL NOT NULL DEFAULT 0;
        ALTER TABLE workflow_node ADD COLUMN config_json TEXT NOT NULL DEFAULT '{}';
        ALTER TABLE workflow_node ADD COLUMN ports_json TEXT NOT NULL DEFAULT '[]';
        ALTER TABLE workflow_node ADD COLUMN failure_policy TEXT;
        ALTER TABLE workflow ADD COLUMN settings_json TEXT NOT NULL DEFAULT '{}';

        CREATE TABLE workflow_connection (
            id           TEXT PRIMARY KEY,
            workflow_id  TEXT NOT NULL REFERENCES workflow(id) ON DELETE CASCADE,
            position     INTEGER NOT NULL DEFAULT 0,
            from_node    TEXT NOT NULL,
            from_port    TEXT NOT NULL,
            to_node      TEXT NOT NULL,
            to_port      TEXT NOT NULL
        );
        CREATE INDEX idx_workflow_connection_workflow ON workflow_connection(workflow_id, position);

        -- value_json is the remembered value of a saved variable.
        CREATE TABLE workflow_variable (
            workflow_id   TEXT NOT NULL REFERENCES workflow(id) ON DELETE CASCADE,
            name          TEXT NOT NULL,
            initial_json  TEXT NOT NULL DEFAULT 'null',
            is_saved      INTEGER NOT NULL DEFAULT 0,
            value_json    TEXT,
            PRIMARY KEY (workflow_id, name)
        );

        ALTER TABLE workflow_run ADD COLUMN trigger_payload_json TEXT NOT NULL DEFAULT '{}';
        ALTER TABLE workflow_run ADD COLUMN path_json TEXT NOT NULL DEFAULT '[]';
        ALTER TABLE workflow_run_step ADD COLUMN inputs_json TEXT NOT NULL DEFAULT '{}';
        ALTER TABLE workflow_run_step ADD COLUMN kind TEXT NOT NULL DEFAULT 'action';

        -- Lay old steps out left to right and chain them in order.
        UPDATE workflow_node SET pos_x = position * 280, pos_y = 0;
        INSERT INTO workflow_connection (id, workflow_id, position, from_node, from_port, to_node, to_port)
        SELECT upper(substr(h, 1, 8) || '-' || substr(h, 9, 4) || '-' || substr(h, 13, 4) || '-' || substr(h, 17, 4) || '-' || substr(h, 21, 12)),
               workflow_id, position, from_node, 'out', to_node, 'in'
        FROM (
            SELECT hex(randomblob(16)) AS h, a.workflow_id AS workflow_id, a.position AS position,
                   a.id AS from_node, b.id AS to_node
            FROM workflow_node a
            JOIN workflow_node b ON b.workflow_id = a.workflow_id AND b.position = a.position + 1
        );
        """,

        // v5 — Stage 05: Orbit. The file index covers only folders the user
        // added (file_location); removing a location deletes its index.
        // file_operation is the undo log for every file change ATLAS makes.
        // health_sample keeps 7 days of readings at decreasing resolution.
        """
        CREATE TABLE file_location (
            id               TEXT PRIMARY KEY,
            path             TEXT NOT NULL UNIQUE,
            name             TEXT NOT NULL,
            bookmark         BLOB,
            added_at         REAL NOT NULL,
            last_indexed_at  REAL,
            file_count       INTEGER NOT NULL DEFAULT 0,
            total_size       INTEGER NOT NULL DEFAULT 0,
            index_state      TEXT NOT NULL DEFAULT 'pending',
            scan_generation  INTEGER NOT NULL DEFAULT 0
        );

        -- size and item_count of a folder include everything inside it.
        CREATE TABLE file_entry (
            path             TEXT PRIMARY KEY,
            location_id      TEXT NOT NULL REFERENCES file_location(id) ON DELETE CASCADE,
            parent           TEXT NOT NULL,
            name             TEXT NOT NULL,
            extension        TEXT NOT NULL DEFAULT '',
            type_identifier  TEXT,
            category         TEXT NOT NULL DEFAULT 'other',
            size             INTEGER NOT NULL DEFAULT 0,
            item_count       INTEGER NOT NULL DEFAULT 0,
            created_at       REAL,
            modified_at      REAL,
            accessed_at      REAL,
            is_directory     INTEGER NOT NULL DEFAULT 0,
            is_package       INTEGER NOT NULL DEFAULT 0,
            inode            INTEGER,
            scan_generation  INTEGER NOT NULL DEFAULT 0
        );
        CREATE INDEX idx_file_entry_parent ON file_entry(parent);
        CREATE INDEX idx_file_entry_extension ON file_entry(extension);
        CREATE INDEX idx_file_entry_size ON file_entry(size);
        CREATE INDEX idx_file_entry_modified ON file_entry(modified_at);
        CREATE INDEX idx_file_entry_location ON file_entry(location_id, scan_generation);
        CREATE INDEX idx_file_entry_inode ON file_entry(inode);

        CREATE TABLE project (
            id              TEXT PRIMARY KEY,
            name            TEXT NOT NULL,
            color           TEXT NOT NULL DEFAULT 'blue',
            space_id        TEXT,
            space_behavior  TEXT NOT NULL DEFAULT 'none',
            created_at      REAL NOT NULL
        );

        CREATE TABLE project_link (
            id          TEXT PRIMARY KEY,
            project_id  TEXT NOT NULL REFERENCES project(id) ON DELETE CASCADE,
            position    INTEGER NOT NULL DEFAULT 0,
            path        TEXT NOT NULL,
            is_key      INTEGER NOT NULL DEFAULT 0,
            is_broken   INTEGER NOT NULL DEFAULT 0,
            added_at    REAL NOT NULL
        );
        CREATE INDEX idx_project_link_project ON project_link(project_id, position);
        CREATE INDEX idx_project_link_path ON project_link(path);

        -- No foreign key to workflow: the rule regenerates it when saved.
        CREATE TABLE file_rule (
            id               TEXT PRIMARY KEY,
            position         INTEGER NOT NULL DEFAULT 0,
            name             TEXT NOT NULL,
            is_enabled       INTEGER NOT NULL DEFAULT 0,
            mode             TEXT NOT NULL DEFAULT 'automatic',
            folders_json     TEXT NOT NULL DEFAULT '[]',
            conditions_json  TEXT NOT NULL DEFAULT '{}',
            action_json      TEXT NOT NULL,
            workflow_id      TEXT,
            starter_id       TEXT,
            created_at       REAL NOT NULL,
            updated_at       REAL NOT NULL
        );

        CREATE TABLE review_item (
            id             TEXT PRIMARY KEY,
            path           TEXT NOT NULL,
            rule_ids_json  TEXT NOT NULL DEFAULT '[]',
            action_json    TEXT NOT NULL,
            reason         TEXT NOT NULL DEFAULT '',
            state          TEXT NOT NULL DEFAULT 'pending',
            created_at     REAL NOT NULL,
            resolved_at    REAL,
            run_id         TEXT
        );
        CREATE INDEX idx_review_item_state ON review_item(state, created_at DESC);

        CREATE TABLE file_operation (
            id            TEXT PRIMARY KEY,
            run_id        TEXT,
            kind          TEXT NOT NULL,
            source        TEXT NOT NULL,
            destination   TEXT,
            extra_json    TEXT NOT NULL DEFAULT '{}',
            performed_at  REAL NOT NULL,
            undone_at     REAL,
            undo_note     TEXT
        );
        CREATE INDEX idx_file_operation_run ON file_operation(run_id);
        CREATE INDEX idx_file_operation_time ON file_operation(performed_at DESC);

        -- resolution: seconds each row covers (5 = raw, 60, 900 after downsampling).
        CREATE TABLE health_sample (
            taken_at         REAL NOT NULL,
            resolution       INTEGER NOT NULL DEFAULT 5,
            cpu              REAL NOT NULL,
            memory_used      INTEGER NOT NULL,
            memory_total     INTEGER NOT NULL,
            memory_pressure  INTEGER NOT NULL DEFAULT 0,
            disk_free        INTEGER NOT NULL,
            disk_total       INTEGER NOT NULL,
            battery          REAL,
            charging         INTEGER
        );
        CREATE INDEX idx_health_sample_time ON health_sample(taken_at);
        """,
        // v6 — Stage 06: Companion. One settings row; command history (last
        // 50, local only); a log of every suggestion shown and why; and app
        // launches for repetition detection (bundle IDs and times only, 14 days).
        """
        CREATE TABLE companion_settings (
            id                INTEGER PRIMARY KEY CHECK (id = 1),
            character         TEXT NOT NULL DEFAULT 'robot',
            primary_color     TEXT NOT NULL DEFAULT '#5B8DEF',
            secondary_color   TEXT NOT NULL DEFAULT '#F5F7FA',
            accessory         TEXT NOT NULL DEFAULT 'none',
            size              TEXT NOT NULL DEFAULT 'medium',
            intensity         TEXT NOT NULL DEFAULT 'full',
            overlay_mode      TEXT NOT NULL DEFAULT 'onTop',
            click_through     INTEGER NOT NULL DEFAULT 1,
            positions_json    TEXT NOT NULL DEFAULT '{}',
            ai_provider       TEXT NOT NULL DEFAULT 'off',
            context_json      TEXT NOT NULL DEFAULT '{}',
            extra_json        TEXT NOT NULL DEFAULT '{}',
            updated_at        REAL NOT NULL
        );

        CREATE TABLE companion_command (
            id          TEXT PRIMARY KEY,
            text        TEXT NOT NULL,
            summary     TEXT NOT NULL DEFAULT '',
            source      TEXT NOT NULL,
            created_at  REAL NOT NULL
        );
        CREATE INDEX idx_companion_command_time ON companion_command(created_at DESC);

        CREATE TABLE companion_suggestion (
            id          TEXT PRIMARY KEY,
            kind        TEXT NOT NULL,
            title       TEXT NOT NULL,
            reason      TEXT NOT NULL,
            state       TEXT NOT NULL DEFAULT 'shown',
            created_at  REAL NOT NULL,
            resolved_at REAL
        );
        CREATE INDEX idx_companion_suggestion_time ON companion_suggestion(created_at DESC);

        CREATE TABLE app_launch (
            bundle_id    TEXT NOT NULL,
            launched_at  REAL NOT NULL
        );
        CREATE INDEX idx_app_launch_time ON app_launch(launched_at);
        """,
        // v7 — Stage 07: Time Architect. Blocks and what happened to each
        // occurrence; focus sessions; calendar links, rules and the write log;
        // recommendations shown (and how they were answered); and drafts of
        // generated workflows with the assumptions behind them.
        """
        CREATE TABLE schedule_block (
            id                      TEXT PRIMARY KEY,
            title                   TEXT NOT NULL,
            start_at                REAL NOT NULL,
            end_at                  REAL NOT NULL,
            kind                    TEXT NOT NULL DEFAULT 'focus',
            color                   TEXT,
            space_id                TEXT,
            profile_id              TEXT,
            workflow_id             TEXT,
            project_id              TEXT,
            recurrence              TEXT NOT NULL DEFAULT 'none',
            reminder_minutes        INTEGER,
            start_behavior          TEXT NOT NULL DEFAULT 'nothing',
            end_behavior            TEXT NOT NULL DEFAULT 'nothing',
            end_space_id            TEXT,
            missed_policy           TEXT NOT NULL DEFAULT 'runIfStillInBlock',
            source                  TEXT NOT NULL DEFAULT 'atlas',
            external_event_id       TEXT,
            calendar_id             TEXT,
            automation_workflow_id  TEXT,
            notes                   TEXT NOT NULL DEFAULT '',
            created_at              REAL NOT NULL,
            updated_at              REAL NOT NULL
        );
        CREATE INDEX idx_schedule_block_start ON schedule_block(start_at);
        CREATE INDEX idx_schedule_block_event ON schedule_block(external_event_id);

        CREATE TABLE block_occurrence (
            block_id      TEXT NOT NULL,
            starts_at     REAL NOT NULL,
            state         TEXT NOT NULL DEFAULT 'upcoming',
            run_ids_json  TEXT NOT NULL DEFAULT '[]',
            updated_at    REAL NOT NULL,
            PRIMARY KEY (block_id, starts_at)
        );

        CREATE TABLE focus_session (
            id                TEXT PRIMARY KEY,
            block_id          TEXT,
            title             TEXT NOT NULL DEFAULT 'Focus',
            planned_seconds   REAL NOT NULL,
            extended_seconds  REAL NOT NULL DEFAULT 0,
            started_at        REAL NOT NULL,
            ended_at          REAL,
            pauses_json       TEXT NOT NULL DEFAULT '[]',
            space_id          TEXT,
            state             TEXT NOT NULL DEFAULT 'running'
        );
        CREATE INDEX idx_focus_session_start ON focus_session(started_at DESC);

        -- kind: rule (title contains → Space), event (one event → Space), write (an event ATLAS created).
        CREATE TABLE calendar_link (
            id              TEXT PRIMARY KEY,
            kind            TEXT NOT NULL,
            calendar_id     TEXT,
            event_id        TEXT,
            title_contains  TEXT,
            space_id        TEXT,
            profile_id      TEXT,
            minutes_before  INTEGER NOT NULL DEFAULT 15,
            block_id        TEXT,
            note            TEXT NOT NULL DEFAULT '',
            created_at      REAL NOT NULL,
            undone_at       REAL
        );

        CREATE TABLE suggestion_log (
            id           TEXT PRIMARY KEY,
            kind         TEXT NOT NULL,
            title        TEXT NOT NULL,
            reason       TEXT NOT NULL,
            confidence   REAL NOT NULL DEFAULT 0.5,
            state        TEXT NOT NULL DEFAULT 'shown',
            action_json  TEXT NOT NULL DEFAULT '{}',
            created_at   REAL NOT NULL,
            resolved_at  REAL
        );
        CREATE INDEX idx_suggestion_log_time ON suggestion_log(created_at DESC);

        CREATE TABLE generated_workflow_draft (
            id                TEXT PRIMARY KEY,
            workflow_id       TEXT NOT NULL,
            prompt            TEXT NOT NULL,
            summary           TEXT NOT NULL DEFAULT '',
            assumptions_json  TEXT NOT NULL DEFAULT '[]',
            source            TEXT NOT NULL,
            state             TEXT NOT NULL DEFAULT 'draft',
            created_at        REAL NOT NULL
        );
        CREATE INDEX idx_generated_draft_workflow ON generated_workflow_draft(workflow_id);
        """,
        // v8 — Stage 08: file changes are written as pending first, so one
        // cut short by a crash or quit is settled on the next launch.
        """
        ALTER TABLE file_operation ADD COLUMN state TEXT NOT NULL DEFAULT 'done';
        CREATE INDEX idx_file_operation_state ON file_operation(state);
        """,
        // v9 — Study Library: courses (with the folder's security-scoped
        // bookmark), assignments merged from calendar, Reminders and manual
        // entry (one row per source item), and study sessions.
        """
        CREATE TABLE course (
            id               TEXT PRIMARY KEY,
            position         INTEGER NOT NULL DEFAULT 0,
            name             TEXT NOT NULL,
            code             TEXT NOT NULL,
            aliases_json     TEXT NOT NULL DEFAULT '[]',
            color            TEXT NOT NULL,
            folder_path      TEXT,
            folder_bookmark  BLOB,
            notes_json       TEXT NOT NULL DEFAULT '{}',
            links_json       TEXT NOT NULL DEFAULT '[]',
            match_json       TEXT NOT NULL DEFAULT '[]',
            opens_json       TEXT NOT NULL DEFAULT '{}',
            term             TEXT NOT NULL DEFAULT '',
            archived         INTEGER NOT NULL DEFAULT 0,
            created_at       REAL NOT NULL
        );
        CREATE INDEX idx_course_position ON course(archived, position);

        CREATE TABLE assignment (
            id           TEXT PRIMARY KEY,
            course_id    TEXT REFERENCES course(id) ON DELETE SET NULL,
            title        TEXT NOT NULL,
            due_at       REAL,
            kind         TEXT NOT NULL DEFAULT 'assignment',
            source       TEXT NOT NULL,
            external_id  TEXT,
            done         INTEGER NOT NULL DEFAULT 0,
            done_at      REAL,
            updated_at   REAL NOT NULL,
            UNIQUE (source, external_id)
        );
        CREATE INDEX idx_assignment_due ON assignment(done, due_at);

        CREATE TABLE study_session (
            id               TEXT PRIMARY KEY,
            course_id        TEXT REFERENCES course(id) ON DELETE SET NULL,
            course_guess     TEXT,
            term             TEXT NOT NULL DEFAULT '',
            started_at       REAL NOT NULL,
            ended_at         REAL,
            focused_seconds  REAL NOT NULL DEFAULT 0,
            pomodoros        INTEGER NOT NULL DEFAULT 0,
            files_json       TEXT NOT NULL DEFAULT '[]',
            completed_json   TEXT NOT NULL DEFAULT '[]'
        );
        CREATE INDEX idx_study_session_start ON study_session(started_at);
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
