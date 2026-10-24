import Foundation

/// Persistence for window layouts and session snapshots (schema v3).
extension AtlasStore {

    // MARK: - Layouts

    /// Inserts or replaces a layout and all of its rules atomically.
    public func saveWindowLayout(_ layout: WindowLayout) throws {
        try database.transaction {
            try database.run(
                """
                INSERT INTO window_layout (id, name, display_profile_json, created_at, updated_at)
                VALUES (?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    name = excluded.name,
                    display_profile_json = excluded.display_profile_json,
                    updated_at = excluded.updated_at;
                """,
                [
                    .from(layout.id), .text(layout.name), .from(try layout.displayProfile.map(WindowJSON.encode)),
                    .from(layout.createdAt), .from(layout.updatedAt),
                ]
            )
            try database.run("DELETE FROM window_rule WHERE layout_id = ?;", [.from(layout.id)])
            for (position, rule) in layout.rules.enumerated() {
                try database.run(
                    """
                    INSERT INTO window_rule
                        (id, layout_id, position, bundle_id, app_name, title_match_json, display_json, frame_json, state, z_order)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
                    """,
                    [
                        .from(rule.id), .from(layout.id), .from(position), .text(rule.bundleID), .text(rule.appName),
                        .from(try rule.titleMatch.map(WindowJSON.encode)), .text(try WindowJSON.encode(rule.display)),
                        .text(try WindowJSON.encode(rule.frame)), .text(rule.state.rawValue), .from(rule.zOrder),
                    ]
                )
            }
        }
    }

    /// Every layout, by name.
    public func windowLayouts() throws -> [WindowLayout] {
        let rules = try loadRules(layoutID: nil)
        return try database.query("SELECT * FROM window_layout ORDER BY name COLLATE NOCASE ASC;")
            .compactMap { layout(from: $0, rules: rules) }
    }

    public func windowLayout(id: UUID) throws -> WindowLayout? {
        guard let row = try database.query("SELECT * FROM window_layout WHERE id = ?;", [.from(id)]).first else {
            return nil
        }
        return layout(from: row, rules: try loadRules(layoutID: id))
    }

    /// Matches an ID exactly, otherwise a name case-insensitively.
    public func windowLayout(reference: String) throws -> WindowLayout? {
        let trimmed = reference.trimmingCharacters(in: .whitespacesAndNewlines)
        if let id = UUID(uuidString: trimmed), let layout = try windowLayout(id: id) { return layout }
        return try windowLayouts().first { $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }
    }

    public func deleteWindowLayout(id: UUID) throws {
        try database.run("DELETE FROM window_layout WHERE id = ?;", [.from(id)])
    }

    private func loadRules(layoutID: UUID?) throws -> [UUID: [WindowRule]] {
        let rows = if let layoutID {
            try database.query("SELECT * FROM window_rule WHERE layout_id = ? ORDER BY position ASC;", [.from(layoutID)])
        } else {
            try database.query("SELECT * FROM window_rule ORDER BY layout_id, position ASC;")
        }
        var result: [UUID: [WindowRule]] = [:]
        for row in rows {
            guard let id = row.uuid("id"), let layoutID = row.uuid("layout_id"), let bundleID = row.string("bundle_id") else {
                continue
            }
            result[layoutID, default: []].append(WindowRule(
                id: id,
                bundleID: bundleID,
                appName: row.string("app_name") ?? "",
                titleMatch: WindowJSON.decode(TitleMatch.self, row.string("title_match_json")),
                display: WindowJSON.decode(DisplayTarget.self, row.string("display_json")) ?? .main,
                frame: WindowJSON.decode(FractionalRect.self, row.string("frame_json")) ?? WindowPreset.centered.rect,
                state: row.string("state").flatMap(WindowState.init(rawValue:)) ?? .normal,
                zOrder: row.int("z_order") ?? 0
            ))
        }
        return result
    }

    private func layout(from row: SQLRow, rules: [UUID: [WindowRule]]) -> WindowLayout? {
        guard let id = row.uuid("id"), let name = row.string("name") else { return nil }
        return WindowLayout(
            id: id,
            name: name,
            rules: rules[id] ?? [],
            displayProfile: WindowJSON.decode(DisplayProfile.self, row.string("display_profile_json")),
            createdAt: row.date("created_at") ?? Date(),
            updatedAt: row.date("updated_at") ?? Date()
        )
    }

    // MARK: - Snapshots

    public func saveSnapshot(_ snapshot: SessionSnapshot) throws {
        try database.run(
            """
            INSERT INTO session_snapshot
                (id, name, created_at, space_id, is_automatic, running_apps_json, rules_json, display_profile_json)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                name = excluded.name,
                space_id = excluded.space_id,
                is_automatic = excluded.is_automatic,
                running_apps_json = excluded.running_apps_json,
                rules_json = excluded.rules_json,
                display_profile_json = excluded.display_profile_json;
            """,
            [
                .from(snapshot.id), .text(snapshot.name), .from(snapshot.createdAt),
                snapshot.spaceID.map(SQLValue.from) ?? .null, .from(snapshot.isAutomatic),
                .text(try WindowJSON.encode(snapshot.runningApps)), .text(try WindowJSON.encode(snapshot.rules)),
                .from(try snapshot.displayProfile.map(WindowJSON.encode)),
            ]
        )
    }

    /// Newest first, optionally only one Space's.
    public func snapshots(spaceID: UUID? = nil, limit: Int = 100) throws -> [SessionSnapshot] {
        let rows = if let spaceID {
            try database.query(
                "SELECT * FROM session_snapshot WHERE space_id = ? ORDER BY created_at DESC LIMIT ?;",
                [.from(spaceID), .from(limit)]
            )
        } else {
            try database.query("SELECT * FROM session_snapshot ORDER BY created_at DESC LIMIT ?;", [.from(limit)])
        }
        return rows.compactMap(snapshot(from:))
    }

    public func snapshot(id: UUID) throws -> SessionSnapshot? {
        try database.query("SELECT * FROM session_snapshot WHERE id = ?;", [.from(id)]).first.flatMap(snapshot(from:))
    }

    /// An ID, a name (newest wins), or "latest".
    public func snapshot(reference: String) throws -> SessionSnapshot? {
        let trimmed = reference.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.caseInsensitiveCompare("latest") == .orderedSame { return try snapshots(limit: 1).first }
        if let id = UUID(uuidString: trimmed), let snapshot = try snapshot(id: id) { return snapshot }
        return try snapshots(limit: 500).first { $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }
    }

    public func deleteSnapshot(id: UUID) throws {
        try database.run("DELETE FROM session_snapshot WHERE id = ?;", [.from(id)])
    }

    /// Keeps the newest `count` automatic snapshots of a Space.
    public func pruneAutomaticSnapshots(spaceID: UUID, keepingLatest count: Int) throws {
        try database.run(
            """
            DELETE FROM session_snapshot WHERE is_automatic = 1 AND space_id = ? AND id NOT IN (
                SELECT id FROM session_snapshot WHERE is_automatic = 1 AND space_id = ?
                ORDER BY created_at DESC LIMIT ?
            );
            """,
            [.from(spaceID), .from(spaceID), .from(count)]
        )
    }

    private func snapshot(from row: SQLRow) -> SessionSnapshot? {
        guard let id = row.uuid("id"), let name = row.string("name") else { return nil }
        return SessionSnapshot(
            id: id,
            name: name,
            createdAt: row.date("created_at") ?? Date(),
            spaceID: row.uuid("space_id"),
            isAutomatic: row.bool("is_automatic") ?? false,
            runningApps: WindowJSON.decode([String].self, row.string("running_apps_json")) ?? [],
            rules: WindowJSON.decode([WindowRule].self, row.string("rules_json")) ?? [],
            displayProfile: WindowJSON.decode(DisplayProfile.self, row.string("display_profile_json"))
        )
    }
}

enum WindowJSON {
    static func encode<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    static func decode<T: Decodable>(_ type: T.Type, _ json: String?) -> T? {
        guard let json else { return nil }
        return try? JSONDecoder().decode(T.self, from: Data(json.utf8))
    }
}
