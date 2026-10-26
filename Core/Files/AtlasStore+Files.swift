import Foundation

/// Persistence for Orbit (schema v5): authorized locations, the file
/// index, projects, rules, the review queue, the undo log and health
/// history. Index writes are batched into transactions so a 500,000-file
/// walk never holds more than one batch in memory.
extension AtlasStore {

    // MARK: - Locations

    public func saveLocation(_ location: FileLocation) throws {
        try database.run(
            """
            INSERT INTO file_location
                (id, path, name, bookmark, added_at, last_indexed_at, file_count, total_size, index_state, scan_generation)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                path = excluded.path, name = excluded.name, bookmark = excluded.bookmark,
                last_indexed_at = excluded.last_indexed_at, file_count = excluded.file_count,
                total_size = excluded.total_size, index_state = excluded.index_state,
                scan_generation = excluded.scan_generation;
            """,
            [
                .from(location.id), .text(location.path), .text(location.name), location.bookmark.map(SQLValue.blob) ?? .null,
                .from(location.addedAt), .from(location.lastIndexedAt), .from(location.fileCount), .integer(location.totalSize),
                .text(location.indexState.rawValue), .from(location.scanGeneration),
            ]
        )
    }

    public func locations() throws -> [FileLocation] {
        try database.query("SELECT * FROM file_location ORDER BY added_at ASC;").compactMap(location(from:))
    }

    public func location(id: UUID) throws -> FileLocation? {
        try database.query("SELECT * FROM file_location WHERE id = ?;", [.from(id)]).first.flatMap(location(from:))
    }

    /// The location a path is in, if any.
    public func location(containing path: String) throws -> FileLocation? {
        try locations().filter { $0.contains(path) }.max { $0.path.count < $1.path.count }
    }

    /// Removes the location and its whole index (ON DELETE CASCADE).
    public func deleteLocation(id: UUID) throws {
        try database.run("DELETE FROM file_location WHERE id = ?;", [.from(id)])
    }

    private func location(from row: SQLRow) -> FileLocation? {
        guard let id = row.uuid("id"), let path = row.string("path") else { return nil }
        var bookmark: Data?
        if case .blob(let data)? = row.columns["bookmark"] { bookmark = data }
        return FileLocation(
            id: id, path: path, name: row.string("name"), bookmark: bookmark, addedAt: row.date("added_at") ?? Date(),
            lastIndexedAt: row.date("last_indexed_at"), fileCount: row.int("file_count") ?? 0,
            totalSize: Int64(row.double("total_size") ?? 0),
            indexState: row.string("index_state").flatMap(FileLocation.IndexState.init(rawValue:)) ?? .pending,
            scanGeneration: row.int("scan_generation") ?? 0
        )
    }

    // MARK: - Index writes

    /// Inserts or updates entries in one transaction, stamping them with the
    /// scan generation so a finished walk can drop what it didn't see.
    public func upsertEntries(_ entries: [FileEntry], generation: Int) throws {
        guard !entries.isEmpty else { return }
        try database.transaction {
            for entry in entries {
                try database.run(
                    """
                    INSERT INTO file_entry
                        (path, location_id, parent, name, extension, type_identifier, category, size, item_count,
                         created_at, modified_at, accessed_at, is_directory, is_package, inode, scan_generation)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(path) DO UPDATE SET
                        location_id = excluded.location_id, parent = excluded.parent, name = excluded.name,
                        extension = excluded.extension, type_identifier = excluded.type_identifier,
                        category = excluded.category,
                        size = CASE WHEN excluded.is_directory = 1 AND excluded.is_package = 0 THEN file_entry.size ELSE excluded.size END,
                        item_count = CASE WHEN excluded.is_directory = 1 AND excluded.is_package = 0 THEN file_entry.item_count ELSE excluded.item_count END,
                        created_at = excluded.created_at, modified_at = excluded.modified_at,
                        accessed_at = excluded.accessed_at, is_directory = excluded.is_directory,
                        is_package = excluded.is_package, inode = excluded.inode,
                        scan_generation = excluded.scan_generation;
                    """,
                    Self.bindings(entry, generation: generation)
                )
            }
        }
    }

    private static func bindings(_ entry: FileEntry, generation: Int) -> [SQLValue] {
        [
            .text(entry.path), .from(entry.locationID), .text(entry.parent), .text(entry.name), .text(entry.ext),
            .from(entry.typeIdentifier), .text(entry.category.rawValue), .integer(entry.size), .from(entry.itemCount),
            .from(entry.createdAt), .from(entry.modifiedAt), .from(entry.accessedAt), .from(entry.isDirectory),
            .from(entry.isPackage), entry.inode.map { .integer(Int64(bitPattern: $0)) } ?? .null, .from(generation),
        ]
    }

    /// Sets folders' totals (size and file count of everything inside).
    public func setFolderTotals(_ totals: [(path: String, size: Int64, count: Int)]) throws {
        guard !totals.isEmpty else { return }
        try database.transaction {
            for total in totals {
                try database.run("UPDATE file_entry SET size = ?, item_count = ? WHERE path = ?;",
                                 [.integer(total.size), .from(total.count), .text(total.path)])
            }
        }
    }

    /// Adds to the totals of every folder above `path`, up to the location root.
    public func adjustAncestors(of path: String, root: String, sizeDelta: Int64, countDelta: Int) throws {
        guard sizeDelta != 0 || countDelta != 0 else { return }
        var ancestors: [String] = []
        var current = (path as NSString).deletingLastPathComponent
        while FileLocation.isPath(current, inside: root) {
            ancestors.append(current)
            if current == root || current == "/" { break }
            current = (current as NSString).deletingLastPathComponent
        }
        guard !ancestors.isEmpty else { return }
        let marks = Array(repeating: "?", count: ancestors.count).joined(separator: ", ")
        try database.run(
            "UPDATE file_entry SET size = max(0, size + ?), item_count = max(0, item_count + ?) WHERE path IN (\(marks));",
            [.integer(sizeDelta), .from(countDelta)] + ancestors.map(SQLValue.text)
        )
    }

    /// Deletes an entry and everything under it; returns what was removed
    /// at the top level, so callers can fix folder totals.
    @discardableResult
    public func deleteEntries(at path: String) throws -> FileEntry? {
        let removed = try entry(at: path)
        try database.run("DELETE FROM file_entry WHERE path = ? OR (path >= ? AND path < ?);",
                         [.text(path), .text(path + "/"), .text(path + "0")])
        return removed
    }

    /// Drops entries a finished walk didn't see (deleted while ATLAS wasn't watching).
    @discardableResult
    public func removeUnseenEntries(locationID: UUID, generation: Int) throws -> Int {
        let count = try database.query(
            "SELECT COUNT(*) AS n FROM file_entry WHERE location_id = ? AND scan_generation < ?;",
            [.from(locationID), .from(generation)]
        ).first?.int("n") ?? 0
        if count > 0 {
            try database.run("DELETE FROM file_entry WHERE location_id = ? AND scan_generation < ?;",
                             [.from(locationID), .from(generation)])
        }
        return count
    }

    /// Moves an entry (and anything under it) to a new path, keeping its row.
    public func moveEntries(from oldPath: String, to newPath: String, locationID: UUID) throws {
        try database.transaction {
            try database.run("DELETE FROM file_entry WHERE path = ? OR (path >= ? AND path < ?);",
                             [.text(newPath), .text(newPath + "/"), .text(newPath + "0")])
            try database.run(
                """
                UPDATE file_entry SET
                    path = ? || substr(path, ?),
                    parent = CASE WHEN path = ? THEN ? ELSE ? || substr(parent, ?) END,
                    location_id = ?
                WHERE path = ? OR (path >= ? AND path < ?);
                """,
                [
                    .text(newPath), .from(oldPath.utf8.count + 1),
                    .text(oldPath), .text((newPath as NSString).deletingLastPathComponent), .text(newPath), .from(oldPath.utf8.count + 1),
                    .from(locationID),
                    .text(oldPath), .text(oldPath + "/"), .text(oldPath + "0"),
                ]
            )
            try database.run(
                "UPDATE file_entry SET name = ?, extension = ? WHERE path = ?;",
                [.text((newPath as NSString).lastPathComponent), .text((newPath as NSString).pathExtension.lowercased()), .text(newPath)]
            )
        }
    }

    // MARK: - Index reads

    public func entry(at path: String) throws -> FileEntry? {
        try database.query("SELECT * FROM file_entry WHERE path = ?;", [.text(path)]).first.flatMap(entry(from:))
    }

    public func entries(withInode inode: UInt64) throws -> [FileEntry] {
        try database.query("SELECT * FROM file_entry WHERE inode = ?;", [.integer(Int64(bitPattern: inode))]).compactMap(entry(from:))
    }

    /// Matching entries, using the indexes on parent, extension, size and date.
    public func entries(matching query: FileQuery) throws -> [FileEntry] {
        var clauses: [String] = []
        var values: [SQLValue] = []
        if let parent = query.parent { clauses.append("parent = ?"); values.append(.text(parent)) }
        if !query.roots.isEmpty {
            let parts = query.roots.map { _ in "(path = ? OR (path >= ? AND path < ?))" }
            clauses.append("(" + parts.joined(separator: " OR ") + ")")
            for root in query.roots { values += [.text(root), .text(root + "/"), .text(root + "0")] }
        }
        if !query.extensions.isEmpty {
            clauses.append("extension IN (\(Array(repeating: "?", count: query.extensions.count).joined(separator: ", ")))")
            values += query.extensions.map { .text($0.lowercased()) }
        }
        if !query.categories.isEmpty {
            clauses.append("category IN (\(Array(repeating: "?", count: query.categories.count).joined(separator: ", ")))")
            values += query.categories.map { .text($0.rawValue) }
        }
        if let min = query.minSize { clauses.append("size >= ?"); values.append(.integer(min)) }
        if let max = query.maxSize { clauses.append("size <= ?"); values.append(.integer(max)) }
        if let date = query.modifiedAfter { clauses.append("modified_at >= ?"); values.append(.from(date)) }
        if let date = query.modifiedBefore { clauses.append("modified_at < ?"); values.append(.from(date)) }
        if let date = query.createdAfter { clauses.append("created_at >= ?"); values.append(.from(date)) }
        if let date = query.createdBefore { clauses.append("created_at < ?"); values.append(.from(date)) }
        if let date = query.openedBefore {
            clauses.append("coalesce(accessed_at, modified_at, created_at) < ?")
            values.append(.from(date))
        }
        for pattern in query.nameLike {
            clauses.append("name LIKE ? ESCAPE '\\'")
            values.append(.text(pattern))
        }
        switch query.kind {
        case .all: break
        case .filesOnly: clauses.append("(is_directory = 0 OR is_package = 1)")
        case .foldersOnly: clauses.append("is_directory = 1 AND is_package = 0")
        }
        let filter = clauses.isEmpty ? "" : "WHERE " + clauses.joined(separator: " AND ")
        let order: String
        switch query.sort {
        case .name: order = "name COLLATE NOCASE ASC"
        case .sizeDescending: order = "size DESC"
        case .modifiedDescending: order = "modified_at DESC"
        case .createdDescending: order = "created_at DESC"
        case .foldersFirst: order = "(is_directory = 1 AND is_package = 0) DESC, size DESC"
        }
        return try database.query("SELECT * FROM file_entry \(filter) ORDER BY \(order) LIMIT ?;", values + [.from(query.limit)])
            .compactMap(entry(from:))
    }

    /// File sizes shared by more than one file: the only possible duplicates.
    public func duplicateSizeCandidates(minimumSize: Int64, roots: [String]) throws -> [(size: Int64, count: Int)] {
        var clauses = ["(is_directory = 0)", "size >= ?"]
        var values: [SQLValue] = [.integer(minimumSize)]
        if !roots.isEmpty {
            clauses.append("(" + roots.map { _ in "(path >= ? AND path < ?)" }.joined(separator: " OR ") + ")")
            for root in roots { values += [.text(root + "/"), .text(root + "0")] }
        }
        return try database.query(
            "SELECT size, COUNT(*) AS n FROM file_entry WHERE \(clauses.joined(separator: " AND ")) GROUP BY size HAVING n > 1 ORDER BY size DESC;",
            values
        ).compactMap { row in
            guard let size = row.double("size"), let count = row.int("n") else { return nil }
            return (Int64(size), count)
        }
    }

    public func files(ofSize size: Int64, roots: [String]) throws -> [FileEntry] {
        try entries(matching: FileQuery(roots: roots, minSize: size, maxSize: size, kind: .filesOnly, limit: 10_000))
            .filter { !$0.isDirectory }
    }

    /// Bytes and count per category under a folder, for legends and charts.
    public func categoryTotals(under root: String) throws -> [FileCategory: (count: Int, size: Int64)] {
        let rows = try database.query(
            """
            SELECT category, COUNT(*) AS n, SUM(size) AS bytes FROM file_entry
            WHERE path >= ? AND path < ? AND (is_directory = 0 OR is_package = 1)
            GROUP BY category;
            """,
            [.text(root + "/"), .text(root + "0")]
        )
        var result: [FileCategory: (Int, Int64)] = [:]
        for row in rows {
            guard let category = row.string("category").flatMap(FileCategory.init(rawValue:)) else { continue }
            result[category] = (row.int("n") ?? 0, Int64(row.double("bytes") ?? 0))
        }
        return result
    }

    public func entryCount(locationID: UUID) throws -> Int {
        try database.query("SELECT COUNT(*) AS n FROM file_entry WHERE location_id = ? AND (is_directory = 0 OR is_package = 1);",
                           [.from(locationID)]).first?.int("n") ?? 0
    }

    private func entry(from row: SQLRow) -> FileEntry? {
        guard let path = row.string("path"), let locationID = row.uuid("location_id") else { return nil }
        var inode: UInt64?
        if case .integer(let value)? = row.columns["inode"] { inode = UInt64(bitPattern: value) }
        return FileEntry(
            path: path, locationID: locationID, parent: row.string("parent"), name: row.string("name"),
            ext: row.string("extension") ?? "", typeIdentifier: row.string("type_identifier"),
            category: row.string("category").flatMap(FileCategory.init(rawValue:)) ?? .other,
            size: Int64(row.double("size") ?? 0), itemCount: row.int("item_count") ?? 0,
            createdAt: row.date("created_at"), modifiedAt: row.date("modified_at"), accessedAt: row.date("accessed_at"),
            isDirectory: row.bool("is_directory") ?? false, isPackage: row.bool("is_package") ?? false, inode: inode
        )
    }

    // MARK: - Projects

    public func saveProject(_ project: Project) throws {
        try database.transaction {
            try database.run(
                """
                INSERT INTO project (id, name, color, space_id, space_behavior, created_at) VALUES (?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET name = excluded.name, color = excluded.color,
                    space_id = excluded.space_id, space_behavior = excluded.space_behavior;
                """,
                [.from(project.id), .text(project.name), .text(project.color), .from(project.spaceID?.uuidString),
                 .text(project.spaceBehavior.rawValue), .from(project.createdAt)]
            )
            try database.run("DELETE FROM project_link WHERE project_id = ?;", [.from(project.id)])
            for (position, link) in project.links.enumerated() {
                try database.run(
                    "INSERT INTO project_link (id, project_id, position, path, is_key, is_broken, added_at) VALUES (?, ?, ?, ?, ?, ?, ?);",
                    [.from(link.id), .from(project.id), .from(position), .text(link.path), .from(link.isKey),
                     .from(link.isBroken), .from(link.addedAt)]
                )
            }
        }
    }

    public func projects() throws -> [Project] {
        var links: [UUID: [ProjectLink]] = [:]
        for row in try database.query("SELECT * FROM project_link ORDER BY project_id, position ASC;") {
            guard let projectID = row.uuid("project_id"), let id = row.uuid("id"), let path = row.string("path") else { continue }
            links[projectID, default: []].append(ProjectLink(
                id: id, path: path, isKey: row.bool("is_key") ?? false, isBroken: row.bool("is_broken") ?? false,
                addedAt: row.date("added_at") ?? Date()
            ))
        }
        return try database.query("SELECT * FROM project ORDER BY created_at ASC;").compactMap { row in
            guard let id = row.uuid("id"), let name = row.string("name") else { return nil }
            return Project(
                id: id, name: name, color: row.string("color") ?? "blue", spaceID: row.uuid("space_id"),
                spaceBehavior: row.string("space_behavior").flatMap(Project.SpaceBehavior.init(rawValue:)) ?? .none,
                createdAt: row.date("created_at") ?? Date(), links: links[id] ?? []
            )
        }
    }

    public func deleteProject(id: UUID) throws {
        try database.run("DELETE FROM project WHERE id = ?;", [.from(id)])
    }

    /// Follows a move: links to `oldPath` or anything under it now point at `newPath`.
    @discardableResult
    public func repointLinks(from oldPath: String, to newPath: String) throws -> Int {
        let affected = try database.query(
            "SELECT COUNT(*) AS n FROM project_link WHERE path = ? OR (path >= ? AND path < ?);",
            [.text(oldPath), .text(oldPath + "/"), .text(oldPath + "0")]
        ).first?.int("n") ?? 0
        guard affected > 0 else { return 0 }
        try database.run(
            "UPDATE project_link SET path = ? || substr(path, ?), is_broken = 0 WHERE path = ? OR (path >= ? AND path < ?);",
            [.text(newPath), .from(oldPath.utf8.count + 1), .text(oldPath), .text(oldPath + "/"), .text(oldPath + "0")]
        )
        return affected
    }

    /// Marks links to `path` (or under it) as broken; returns how many.
    @discardableResult
    public func markLinksBroken(at path: String) throws -> Int {
        let affected = try database.query(
            "SELECT COUNT(*) AS n FROM project_link WHERE is_broken = 0 AND (path = ? OR (path >= ? AND path < ?));",
            [.text(path), .text(path + "/"), .text(path + "0")]
        ).first?.int("n") ?? 0
        if affected > 0 {
            try database.run("UPDATE project_link SET is_broken = 1 WHERE path = ? OR (path >= ? AND path < ?);",
                             [.text(path), .text(path + "/"), .text(path + "0")])
        }
        return affected
    }

    // MARK: - Rules

    public func saveRule(_ rule: FileRule, position: Int? = nil) throws {
        let position = try position ?? database.query("SELECT position FROM file_rule WHERE id = ?;", [.from(rule.id)]).first?.int("position")
            ?? (database.query("SELECT COALESCE(MAX(position), -1) + 1 AS p FROM file_rule;").first?.int("p") ?? 0)
        try database.run(
            """
            INSERT INTO file_rule
                (id, position, name, is_enabled, mode, folders_json, conditions_json, action_json, workflow_id, starter_id, created_at, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                position = excluded.position, name = excluded.name, is_enabled = excluded.is_enabled, mode = excluded.mode,
                folders_json = excluded.folders_json, conditions_json = excluded.conditions_json,
                action_json = excluded.action_json, workflow_id = excluded.workflow_id, updated_at = excluded.updated_at;
            """,
            [
                .from(rule.id), .from(position), .text(rule.name), .from(rule.isEnabled), .text(rule.mode.rawValue),
                .text(try FileJSON.encode(rule.folders)),
                .text(try FileJSON.encode(StoredConditions(match: rule.match, items: rule.conditions, ifExists: rule.ifExists))),
                .text(try FileJSON.encode(rule.action)), .from(rule.workflowID?.uuidString), .from(rule.starterID),
                .from(rule.createdAt), .from(rule.updatedAt),
            ]
        )
    }

    public func rules() throws -> [FileRule] {
        try database.query("SELECT * FROM file_rule ORDER BY position ASC;").compactMap(rule(from:))
    }

    public func rule(id: UUID) throws -> FileRule? {
        try database.query("SELECT * FROM file_rule WHERE id = ?;", [.from(id)]).first.flatMap(rule(from:))
    }

    public func deleteRule(id: UUID) throws {
        try database.run("DELETE FROM file_rule WHERE id = ?;", [.from(id)])
    }

    private struct StoredConditions: Codable {
        var match: ConditionGroup.Match
        var items: [RuleCondition]
        var ifExists: ConflictMode?
    }

    private func rule(from row: SQLRow) -> FileRule? {
        guard let id = row.uuid("id"), let name = row.string("name"),
              let action = FileJSON.decode(RuleAction.self, row.string("action_json"))
        else { return nil }
        let conditions = FileJSON.decode(StoredConditions.self, row.string("conditions_json"))
        return FileRule(
            id: id, name: name, isEnabled: row.bool("is_enabled") ?? false,
            mode: row.string("mode").flatMap(FileRule.Mode.init(rawValue:)) ?? .automatic,
            folders: FileJSON.decode([String].self, row.string("folders_json")) ?? [],
            match: conditions?.match ?? .all, conditions: conditions?.items ?? [], action: action,
            ifExists: conditions?.ifExists ?? .addNumber, workflowID: row.uuid("workflow_id"),
            starterID: row.string("starter_id"), createdAt: row.date("created_at") ?? Date(),
            updatedAt: row.date("updated_at") ?? Date()
        )
    }

    // MARK: - Review queue

    /// Adds an item, or refreshes the pending one for the same file.
    @discardableResult
    public func addReviewItem(_ item: ReviewItem) throws -> ReviewItem {
        if var existing = try reviewItems(state: .pending).first(where: { $0.path == item.path }) {
            existing.ruleIDs = Array(Set(existing.ruleIDs + item.ruleIDs)).sorted { $0.uuidString < $1.uuidString }
            existing.action = item.action
            existing.reason = item.reason
            try saveReviewItem(existing)
            return existing
        }
        try saveReviewItem(item)
        return item
    }

    public func saveReviewItem(_ item: ReviewItem) throws {
        try database.run(
            """
            INSERT INTO review_item (id, path, rule_ids_json, action_json, reason, state, created_at, resolved_at, run_id)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                path = excluded.path, rule_ids_json = excluded.rule_ids_json, action_json = excluded.action_json,
                reason = excluded.reason, state = excluded.state, resolved_at = excluded.resolved_at, run_id = excluded.run_id;
            """,
            [
                .from(item.id), .text(item.path), .text(try FileJSON.encode(item.ruleIDs)), .text(try FileJSON.encode(item.action)),
                .text(item.reason), .text(item.state.rawValue), .from(item.createdAt), .from(item.resolvedAt),
                .from(item.runID?.uuidString),
            ]
        )
    }

    public func reviewItems(state: ReviewItem.State? = .pending, limit: Int = 500) throws -> [ReviewItem] {
        let rows = if let state {
            try database.query("SELECT * FROM review_item WHERE state = ? ORDER BY created_at DESC LIMIT ?;",
                               [.text(state.rawValue), .from(limit)])
        } else {
            try database.query("SELECT * FROM review_item ORDER BY created_at DESC LIMIT ?;", [.from(limit)])
        }
        return rows.compactMap { row in
            guard let id = row.uuid("id"), let path = row.string("path"),
                  let action = FileJSON.decode(RuleAction.self, row.string("action_json"))
            else { return nil }
            return ReviewItem(
                id: id, path: path, ruleIDs: FileJSON.decode([UUID].self, row.string("rule_ids_json")) ?? [], action: action,
                reason: row.string("reason") ?? "", state: row.string("state").flatMap(ReviewItem.State.init(rawValue:)) ?? .pending,
                createdAt: row.date("created_at") ?? Date(), resolvedAt: row.date("resolved_at"), runID: row.uuid("run_id")
            )
        }
    }

    // MARK: - Undo log

    public func logOperation(_ operation: FileOperation) throws {
        try database.run(
            """
            INSERT INTO file_operation (id, run_id, kind, source, destination, extra_json, performed_at, undone_at, undo_note)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET undone_at = excluded.undone_at, undo_note = excluded.undo_note;
            """,
            [
                .from(operation.id), .from(operation.runID?.uuidString), .text(operation.kind.rawValue), .text(operation.source),
                .from(operation.destination), .text(try FileJSON.encode(operation.extra)), .from(operation.performedAt),
                .from(operation.undoneAt), .from(operation.undoNote),
            ]
        )
    }

    public func operations(runID: UUID) throws -> [FileOperation] {
        try database.query("SELECT * FROM file_operation WHERE run_id = ? ORDER BY performed_at ASC;", [.from(runID)])
            .compactMap(operation(from:))
    }

    public func operation(id: UUID) throws -> FileOperation? {
        try database.query("SELECT * FROM file_operation WHERE id = ?;", [.from(id)]).first.flatMap(operation(from:))
    }

    public func recentOperations(limit: Int = 100) throws -> [FileOperation] {
        try database.query("SELECT * FROM file_operation ORDER BY performed_at DESC LIMIT ?;", [.from(limit)])
            .compactMap(operation(from:))
    }

    private func operation(from row: SQLRow) -> FileOperation? {
        guard let id = row.uuid("id"), let kind = row.string("kind").flatMap(FileOperation.Kind.init(rawValue:)),
              let source = row.string("source")
        else { return nil }
        return FileOperation(
            id: id, runID: row.uuid("run_id"), kind: kind, source: source, destination: row.string("destination"),
            extra: FileJSON.decode([String: String].self, row.string("extra_json")) ?? [:],
            performedAt: row.date("performed_at") ?? Date(), undoneAt: row.date("undone_at"), undoNote: row.string("undo_note")
        )
    }

    // MARK: - Health history

    public func insertHealthSample(_ sample: HealthSample) throws {
        try database.run(
            """
            INSERT INTO health_sample
                (taken_at, resolution, cpu, memory_used, memory_total, memory_pressure, disk_free, disk_total, battery, charging)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
            """,
            [
                .from(sample.takenAt), .from(sample.resolution), .real(sample.cpu), .integer(sample.memoryUsed),
                .integer(sample.memoryTotal), .from(sample.memoryPressure), .integer(sample.diskFree), .integer(sample.diskTotal),
                .from(sample.battery), sample.isCharging.map { .from($0) } ?? .null,
            ]
        )
    }

    public func healthSamples(from: Date, to: Date = .distantFuture) throws -> [HealthSample] {
        try database.query("SELECT * FROM health_sample WHERE taken_at >= ? AND taken_at < ? ORDER BY taken_at ASC;",
                           [.from(from), .from(to)])
            .map { row in
                HealthSample(
                    takenAt: row.date("taken_at") ?? Date(), resolution: row.int("resolution") ?? 5, cpu: row.double("cpu") ?? 0,
                    memoryUsed: Int64(row.double("memory_used") ?? 0), memoryTotal: Int64(row.double("memory_total") ?? 0),
                    memoryPressure: row.int("memory_pressure") ?? 0, diskFree: Int64(row.double("disk_free") ?? 0),
                    diskTotal: Int64(row.double("disk_total") ?? 0), battery: row.double("battery"), isCharging: row.bool("charging")
                )
            }
    }

    /// Keeps raw readings for an hour, minute averages for a day, 15-minute
    /// averages for a week, and nothing older.
    public func downsampleHealth(now: Date = Date()) throws {
        try database.transaction {
            try database.run("DELETE FROM health_sample WHERE taken_at < ?;", [.from(now.addingTimeInterval(-7 * 86_400))])
            try averageHealth(olderThan: now.addingTimeInterval(-3_600), finerThan: 60, into: 60)
            try averageHealth(olderThan: now.addingTimeInterval(-86_400), finerThan: 900, into: 900)
        }
    }

    private func averageHealth(olderThan cutoff: Date, finerThan resolution: Int, into bucket: Int) throws {
        let bound = Double(Int(cutoff.timeIntervalSince1970) / bucket * bucket)
        try database.run(
            """
            INSERT INTO health_sample
                (taken_at, resolution, cpu, memory_used, memory_total, memory_pressure, disk_free, disk_total, battery, charging)
            SELECT CAST(taken_at / ? AS INTEGER) * ?, ?, AVG(cpu), AVG(memory_used), MAX(memory_total), MAX(memory_pressure),
                   AVG(disk_free), MAX(disk_total), AVG(battery), MAX(charging)
            FROM health_sample WHERE taken_at < ? AND resolution < ?
            GROUP BY CAST(taken_at / ? AS INTEGER);
            """,
            [.from(bucket), .from(bucket), .from(bucket), .real(bound), .from(resolution), .from(bucket)]
        )
        try database.run("DELETE FROM health_sample WHERE taken_at < ? AND resolution < ?;", [.real(bound), .from(resolution)])
    }
}

/// Filters for index reads. Every field is optional; empty means "any".
public struct FileQuery: Sendable, Equatable {
    public enum Kind: Sendable { case all, filesOnly, foldersOnly }
    public enum Sort: Sendable { case name, sizeDescending, modifiedDescending, createdDescending, foldersFirst }

    public var parent: String?
    /// Only under these folders.
    public var roots: [String]
    public var extensions: [String]
    public var categories: [FileCategory]
    public var minSize: Int64?
    public var maxSize: Int64?
    public var modifiedAfter: Date?
    public var modifiedBefore: Date?
    public var createdAfter: Date?
    public var createdBefore: Date?
    /// Not opened (or, failing that, changed) since.
    public var openedBefore: Date?
    /// SQL LIKE patterns on the name, all of which must match.
    public var nameLike: [String]
    public var kind: Kind
    public var sort: Sort
    public var limit: Int

    public init(parent: String? = nil, roots: [String] = [], extensions: [String] = [], categories: [FileCategory] = [],
                minSize: Int64? = nil, maxSize: Int64? = nil, modifiedAfter: Date? = nil, modifiedBefore: Date? = nil,
                createdAfter: Date? = nil, createdBefore: Date? = nil, openedBefore: Date? = nil, nameLike: [String] = [],
                kind: Kind = .all, sort: Sort = .foldersFirst, limit: Int = 500) {
        self.parent = parent
        self.roots = roots
        self.extensions = extensions
        self.categories = categories
        self.minSize = minSize
        self.maxSize = maxSize
        self.modifiedAfter = modifiedAfter
        self.modifiedBefore = modifiedBefore
        self.createdAfter = createdAfter
        self.createdBefore = createdBefore
        self.openedBefore = openedBefore
        self.nameLike = nameLike
        self.kind = kind
        self.sort = sort
        self.limit = limit
    }

    /// "%n%e%u%r%a%l%": the letters in order, anything between. Escapes % and _.
    public static func subsequencePattern(_ text: String) -> String {
        "%" + text.lowercased().map { Self.escapeLike(String($0)) }.joined(separator: "%") + "%"
    }

    public static func containsPattern(_ text: String) -> String { "%" + escapeLike(text) + "%" }

    static func escapeLike(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
    }
}

enum FileJSON {
    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    static func encode<T: Encodable>(_ value: T) throws -> String {
        String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    static func decode<T: Decodable>(_ type: T.Type, _ json: String?) -> T? {
        guard let json, let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }
}
