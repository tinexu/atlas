import Foundation

/// Keeps a copy of the database every day (the newest 7), checks it on
/// launch, and can put the latest good copy back.
public enum DatabaseBackups {
    public static let keep = 7

    /// `~/Library/Application Support/ATLAS/Backups`
    public static func folder(for databaseURL: URL) -> URL {
        databaseURL.deletingLastPathComponent().appendingPathComponent("Backups", isDirectory: true)
    }

    public struct Backup: Identifiable, Hashable, Sendable {
        public let url: URL
        public let date: Date
        public var id: URL { url }
    }

    /// Newest first.
    public static func list(in folder: URL) -> [Backup] {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return files.filter { $0.lastPathComponent.hasPrefix("atlas-") && $0.pathExtension == "sqlite" && !$0.lastPathComponent.contains("corrupt") }
            .map { Backup(url: $0, date: (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }
            .sorted { $0.date > $1.date }
    }

    /// Writes today's backup if there isn't one yet, then keeps the newest 7.
    @discardableResult
    public static func backUpIfDue(_ database: SQLiteDatabase, to folder: URL, now: Date = Date(), calendar: Calendar = .current) throws -> URL? {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if let newest = list(in: folder).first, calendar.isDate(newest.date, inSameDayAs: now) { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        let url = folder.appendingPathComponent("atlas-\(formatter.string(from: now)).sqlite")
        try backUp(database, to: url)
        try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: url.path)
        prune(folder)
        return url
    }

    /// A consistent copy of a live database (SQLite's VACUUM INTO).
    public static func backUp(_ database: SQLiteDatabase, to url: URL) throws {
        try? FileManager.default.removeItem(at: url)
        let escaped = url.path.replacingOccurrences(of: "'", with: "''")
        try database.execute("VACUUM INTO '\(escaped)';")
    }

    static func prune(_ folder: URL) {
        for old in list(in: folder).dropFirst(keep) { try? FileManager.default.removeItem(at: old.url) }
    }

    /// "ok", or what SQLite found wrong.
    public static func integrityProblem(_ database: SQLiteDatabase) -> String? {
        guard let result = try? database.query("PRAGMA quick_check;").first?.string("quick_check") else {
            return "The database couldn't be read."
        }
        return result == "ok" ? nil : result
    }

    /// Moves a damaged database (and its journal files) aside, keeping it.
    @discardableResult
    public static func setAside(_ databaseURL: URL, now: Date = Date()) throws -> URL {
        let folder = folder(for: databaseURL)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let stamp = Int(now.timeIntervalSince1970)
        let target = folder.appendingPathComponent("atlas-corrupt-\(stamp).sqlite")
        for suffix in ["", "-wal", "-shm"] {
            let from = URL(fileURLWithPath: databaseURL.path + suffix)
            if FileManager.default.fileExists(atPath: from.path) {
                try FileManager.default.moveItem(at: from, to: URL(fileURLWithPath: target.path + suffix))
            }
        }
        return target
    }

    /// Puts a backup in place of the (already set aside) database.
    public static func restore(_ backup: Backup, to databaseURL: URL) throws {
        for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: databaseURL.path + suffix) }
        try FileManager.default.copyItem(at: backup.url, to: databaseURL)
    }
}

/// Workflows, Spaces, rules and settings as one JSON file, for safekeeping
/// or moving to a fresh database. Run history, the file index and logs are
/// left out (they rebuild themselves).
public struct AtlasExport: Codable, Sendable {
    public static let tables = ["space", "activation_profile", "space_object", "window_layout", "window_rule", "file_location",
                                "file_rule", "project", "project_link", "schedule_block", "calendar_link", "companion_settings",
                                "user_preference"]

    public var format = 1
    public var schemaVersion: Int
    public var exportedAt: Date
    public var workflows: [Workflow]
    /// table → rows (column → value).
    public var tables: [String: [[String: ExportValue]]]

    public enum ExportValue: Codable, Hashable, Sendable {
        case null, integer(Int64), real(Double), text(String)

        public init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if c.decodeNil() { self = .null }
            else if let i = try? c.decode(Int64.self) { self = .integer(i) }
            else if let d = try? c.decode(Double.self) { self = .real(d) }
            else { self = .text(try c.decode(String.self)) }
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.singleValueContainer()
            switch self {
            case .null: try c.encodeNil()
            case .integer(let i): try c.encode(i)
            case .real(let d): try c.encode(d)
            case .text(let s): try c.encode(s)
            }
        }

        var sql: SQLValue {
            switch self {
            case .null: return .null
            case .integer(let i): return .integer(i)
            case .real(let d): return .real(d)
            case .text(let s): return .text(s)
            }
        }
    }

    public static func make(from store: AtlasStore, now: Date = Date()) throws -> AtlasExport {
        var tables: [String: [[String: ExportValue]]] = [:]
        for table in Self.tables {
            let rows = try store.database.query("SELECT * FROM \(table);")
            tables[table] = rows.map { row in
                row.columns.compactMapValues { value -> ExportValue? in
                    switch value {
                    case .null: return .null
                    case .integer(let i): return .integer(i)
                    case .real(let d): return .real(d)
                    case .text(let s): return .text(s)
                    case .blob(let data): return .text("base64:" + data.base64EncodedString())
                    }
                }
            }
        }
        return AtlasExport(schemaVersion: store.database.userVersion, exportedAt: now, workflows: try store.workflows(), tables: tables)
    }

    public func data() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }

    public static func read(_ data: Data) throws -> AtlasExport {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(AtlasExport.self, from: data)
    }

    public struct ImportSummary: Equatable, Sendable {
        public var workflows = 0
        public var rows = 0
    }

    /// Adds everything, replacing items with the same ID. Nothing else is
    /// removed. All or nothing.
    @discardableResult
    public func apply(to store: AtlasStore) throws -> ImportSummary {
        guard schemaVersion <= store.database.userVersion else {
            throw DataSafetyError.newerExport(schemaVersion)
        }
        var summary = ImportSummary()
        try store.database.transaction {
            for workflow in workflows {
                try store.saveWorkflow(workflow)
                summary.workflows += 1
            }
            // Parents before children.
            for table in Self.tables {
                let known = Set(try store.database.query("PRAGMA table_info(\(table));").compactMap { $0.string("name") })
                for row in tables[table] ?? [] {
                    let columns = row.keys.filter(known.contains).sorted()
                    guard !columns.isEmpty else { continue }
                    let placeholders = Array(repeating: "?", count: columns.count).joined(separator: ", ")
                    try store.database.run("INSERT OR REPLACE INTO \(table) (\(columns.joined(separator: ", "))) VALUES (\(placeholders));",
                                           columns.map { row[$0]!.sql })
                    summary.rows += 1
                }
            }
        }
        return summary
    }
}

public enum DataSafetyError: Error, LocalizedError, Equatable {
    case corrupted(String, backupAvailable: Bool)
    case newerExport(Int)

    public var errorDescription: String? {
        switch self {
        case .corrupted(let detail, let backup):
            return "ATLAS's database is damaged (\(detail)). It was moved to the Backups folder untouched." + (backup ? " You can restore the latest daily backup." : " There's no backup to restore, so ATLAS will start fresh.")
        case .newerExport(let version):
            return "This export comes from a newer ATLAS (database v\(version)). Update ATLAS first."
        }
    }
}

extension AtlasStore {
    /// Opens the on-disk database after checking it. A damaged one is moved
    /// to the Backups folder (kept, never deleted) and reported, so the app
    /// can offer to restore the latest backup.
    public static func openChecked(at url: URL) throws -> AtlasStore {
        func corrupted(_ detail: String) throws -> Never {
            try DatabaseBackups.setAside(url)
            throw DataSafetyError.corrupted(detail, backupAvailable: !DatabaseBackups.list(in: DatabaseBackups.folder(for: url)).isEmpty)
        }
        guard FileManager.default.fileExists(atPath: url.path) else { return try AtlasStore(database: SQLiteDatabase(path: url.path)) }
        let problem: String?
        do {
            let database = try SQLiteDatabase(path: url.path)
            problem = DatabaseBackups.integrityProblem(database)
            if problem == nil { return try AtlasStore(database: database) }
        } catch let error as DatabaseError {
            try corrupted(error.localizedDescription)
        }
        try corrupted(problem ?? "unknown problem")
    }
}

extension AtlasCore {
    /// Today's backup now, then a check every few hours.
    public func startDailyBackups(environment: TriggerEnvironment) {
        guard store.database.path != ":memory:" else { return }
        let folder = DatabaseBackups.folder(for: URL(fileURLWithPath: store.database.path))
        let database = store.database
        func check() {
            do {
                if let url = try DatabaseBackups.backUpIfDue(database, to: folder, now: environment.now()) {
                    AtlasLog.persistence.info("Backed up the database to \(url.lastPathComponent, privacy: .public)")
                }
            } catch {
                AtlasLog.persistence.error("Daily backup failed: \(error.localizedDescription, privacy: .public)")
            }
            backupToken = environment.schedule(at: environment.now().addingTimeInterval(4 * 3_600)) { check() }
        }
        check()
    }
}

/// When a 3D view may draw. A RealityKit view redraws every frame (about
/// half a CPU core even when nothing moves), so it draws only when it can
/// be seen and is in use.
public enum RenderPolicy {
    public static func shouldDraw(windowVisible: Bool, appActive: Bool, lowPowerMode: Bool) -> Bool {
        windowVisible && appActive && !lowPowerMode
    }
}
