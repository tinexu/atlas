import AtlasCore
import Foundation

/// Persistence for Spaces, their activation profiles and room objects.
/// Tables come from schema migration v2 in `Core/Persistence/Schema.swift`.
extension AtlasStore {
    static let activeSpaceKey = "spaces.activeSpaceID"
    static let activeProfileKey = "spaces.activeProfileID"

    // MARK: - Spaces

    public func saveSpace(_ space: Space) throws {
        try database.run(
            """
            INSERT INTO space (id, name, group_name, template_id, accent_color, slot,
                               transition_behavior, is_pinned, created_at, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                name = excluded.name,
                group_name = excluded.group_name,
                template_id = excluded.template_id,
                accent_color = excluded.accent_color,
                slot = excluded.slot,
                transition_behavior = excluded.transition_behavior,
                is_pinned = excluded.is_pinned,
                updated_at = excluded.updated_at;
            """,
            [
                .from(space.id), .text(space.name), .text(space.group.rawValue), .text(space.templateID),
                .text(space.accentColor), .from(space.slot), .text(space.transitionBehavior.rawValue),
                .from(space.isPinned), .from(space.createdAt), .from(space.updatedAt),
            ]
        )
    }

    /// Every Space in slot order.
    public func spaces() throws -> [Space] {
        try database.query("SELECT * FROM space ORDER BY slot ASC, created_at ASC;").compactMap(space(from:))
    }

    public func space(id: UUID) throws -> Space? {
        try database.query("SELECT * FROM space WHERE id = ?;", [.from(id)]).first.flatMap(space(from:))
    }

    /// Deletes the Space with its profiles and objects (ON DELETE CASCADE).
    /// The workflows the profiles point at are left alone.
    public func deleteSpace(id: UUID) throws {
        try database.transaction {
            try database.run("DELETE FROM space WHERE id = ?;", [.from(id)])
            try setLastActivationRunID(nil, spaceID: id)
            if try activeSpaceID() == id {
                try setActiveSpace(nil, profileID: nil)
            }
        }
    }

    private func space(from row: SQLRow) -> Space? {
        guard let id = row.uuid("id"), let name = row.string("name") else { return nil }
        return Space(
            id: id,
            name: name,
            group: SpaceGroup(row.string("group_name") ?? ""),
            templateID: row.string("template_id") ?? "",
            accentColor: row.string("accent_color") ?? "#3B82F6",
            slot: row.int("slot") ?? 0,
            transitionBehavior: row.string("transition_behavior").flatMap(TransitionBehavior.init(rawValue:)) ?? .leaveRunning,
            isPinned: row.bool("is_pinned") ?? false,
            createdAt: row.date("created_at") ?? Date(),
            updatedAt: row.date("updated_at") ?? Date()
        )
    }

    // MARK: - Activation profiles

    public func saveProfile(_ profile: ActivationProfile) throws {
        try database.run(
            """
            INSERT INTO activation_profile (id, space_id, position, name, workflow_id, is_default)
            VALUES (?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                space_id = excluded.space_id,
                position = excluded.position,
                name = excluded.name,
                workflow_id = excluded.workflow_id,
                is_default = excluded.is_default;
            """,
            [
                .from(profile.id), .from(profile.spaceID), .from(profile.position), .text(profile.name),
                .from(profile.workflowID), .from(profile.isDefault),
            ]
        )
    }

    /// Profiles for one Space, or for all Spaces, in their display order.
    public func profiles(spaceID: UUID? = nil) throws -> [ActivationProfile] {
        let rows: [SQLRow]
        if let spaceID {
            rows = try database.query(
                "SELECT * FROM activation_profile WHERE space_id = ? ORDER BY position ASC;", [.from(spaceID)]
            )
        } else {
            rows = try database.query("SELECT * FROM activation_profile ORDER BY space_id, position ASC;")
        }
        return rows.compactMap { row in
            guard let id = row.uuid("id"),
                  let spaceID = row.uuid("space_id"),
                  let workflowID = row.uuid("workflow_id")
            else { return nil }
            return ActivationProfile(
                id: id,
                spaceID: spaceID,
                name: row.string("name") ?? "Default",
                workflowID: workflowID,
                isDefault: row.bool("is_default") ?? false,
                position: row.int("position") ?? 0
            )
        }
    }

    public func profile(id: UUID) throws -> ActivationProfile? {
        guard let row = try database.query("SELECT space_id FROM activation_profile WHERE id = ?;", [.from(id)]).first,
              let spaceID = row.uuid("space_id")
        else { return nil }
        return try profiles(spaceID: spaceID).first { $0.id == id }
    }

    public func deleteProfile(id: UUID) throws {
        try database.run("DELETE FROM activation_profile WHERE id = ?;", [.from(id)])
    }

    // MARK: - Room objects

    public func saveSpaceObject(_ object: SpaceObject) throws {
        try database.run(
            """
            INSERT INTO space_object (id, space_id, kind, label, transform_json, action_id, parameters_json, workflow_id)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                space_id = excluded.space_id,
                kind = excluded.kind,
                label = excluded.label,
                transform_json = excluded.transform_json,
                action_id = excluded.action_id,
                parameters_json = excluded.parameters_json,
                workflow_id = excluded.workflow_id;
            """,
            [
                .from(object.id), .from(object.spaceID), .text(object.kind.rawValue), .from(object.label),
                .text(try Self.json(object.transform)), .from(object.actionID?.rawValue),
                .text(try Self.json(object.parameters)), object.workflowID.map(SQLValue.from) ?? .null,
            ]
        )
    }

    /// Objects for one Space, or for all Spaces.
    public func spaceObjects(spaceID: UUID? = nil) throws -> [SpaceObject] {
        let rows: [SQLRow]
        if let spaceID {
            rows = try database.query("SELECT * FROM space_object WHERE space_id = ? ORDER BY rowid ASC;", [.from(spaceID)])
        } else {
            rows = try database.query("SELECT * FROM space_object ORDER BY space_id, rowid ASC;")
        }
        return rows.compactMap { row in
            guard let id = row.uuid("id"),
                  let spaceID = row.uuid("space_id"),
                  let kind = row.string("kind").flatMap(SpaceObjectKind.init(rawValue:))
            else { return nil }
            return SpaceObject(
                id: id,
                spaceID: spaceID,
                kind: kind,
                label: row.string("label"),
                transform: Self.decode(SpaceTransform.self, row.string("transform_json")) ?? .identity,
                actionID: row.string("action_id").map { ActionID($0) },
                parameters: Self.decode(ActionParameters.self, row.string("parameters_json")) ?? [:],
                workflowID: row.uuid("workflow_id")
            )
        }
    }

    public func deleteSpaceObject(id: UUID) throws {
        try database.run("DELETE FROM space_object WHERE id = ?;", [.from(id)])
    }

    // MARK: - Active Space

    public func activeSpaceID() throws -> UUID? {
        try preference(Self.activeSpaceKey, as: UUID.self)
    }

    public func activeProfileID() throws -> UUID? {
        try preference(Self.activeProfileKey, as: UUID.self)
    }

    public func setActiveSpace(_ spaceID: UUID?, profileID: UUID?) throws {
        try database.transaction {
            try setPreference(spaceID, for: Self.activeSpaceKey)
            try setPreference(profileID, for: Self.activeProfileKey)
        }
    }

    /// The most recent activation run of a Space, so its status survives a relaunch.
    public func lastActivationRunID(spaceID: UUID) throws -> UUID? {
        try preference("spaces.lastRun.\(spaceID.uuidString)", as: UUID.self)
    }

    public func setLastActivationRunID(_ runID: UUID?, spaceID: UUID) throws {
        try setPreference(runID, for: "spaces.lastRun.\(spaceID.uuidString)")
    }

    // MARK: - JSON helpers

    private static func json<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    private static func decode<T: Decodable>(_ type: T.Type, _ json: String?) -> T? {
        guard let json else { return nil }
        return try? JSONDecoder().decode(T.self, from: Data(json.utf8))
    }
}
