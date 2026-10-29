import AtlasCore
import Foundation

/// One creative session, saved when it ends (v10 `creative_session`).
public struct CreativeSession: Identifiable, Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable {
        /// Making things: the mug timer.
        case create
        /// Watch mode (YouTube): counted separately.
        case watch
    }

    public var id: UUID
    public var projectID: UUID?
    public var kind: Kind
    public var startedAt: Date
    public var endedAt: Date?
    public var focusedSeconds: TimeInterval
    /// New exports and references saved in the project during the session.
    public var exports: [String]
    public var references: [String]
    /// Every file of the project changed during the session.
    public var files: [String]
    /// The session's palette (from its latest export), "#RRGGBB".
    public var palette: [String]
    public var tutorials: [String]

    public init(id: UUID = UUID(), projectID: UUID? = nil, kind: Kind = .create, startedAt: Date, endedAt: Date? = nil,
                focusedSeconds: TimeInterval = 0, exports: [String] = [], references: [String] = [], files: [String] = [],
                palette: [String] = [], tutorials: [String] = []) {
        self.id = id
        self.projectID = projectID
        self.kind = kind
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.focusedSeconds = focusedSeconds
        self.exports = exports
        self.references = references
        self.files = files
        self.palette = palette
        self.tutorials = tutorials
    }
}

/// What the end-of-session card shows.
public struct CreativeSummary: Codable, Equatable, Sendable {
    public var sessionID: UUID
    public var kind: CreativeSession.Kind
    public var focusedSeconds: TimeInterval
    public var projectName: String?
    public var exports: Int
    public var references: Int
    public var streak: Int
    /// The newest export, for its thumbnail.
    public var latestExport: String?
    public var palette: [String]
    public var endedEarly: Bool

    /// "1 h 55 m creating · Poster Series · 4 exports · 6 references saved · streak 3 days"
    public var headline: String {
        var parts = ["\(CreativeMath.duration(focusedSeconds)) \(kind == .watch ? "watching" : "creating")"]
        if let projectName { parts.append(projectName) }
        if exports > 0 { parts.append("\(exports) export\(exports == 1 ? "" : "s")") }
        if references > 0 { parts.append("\(references) reference\(references == 1 ? "" : "s") saved") }
        if streak > 0 { parts.append("streak \(streak) day\(streak == 1 ? "" : "s")") }
        return parts.joined(separator: " · ")
    }
}

public enum CreativeMath {
    /// "1 h 55 m", "25 m".
    public static func duration(_ seconds: TimeInterval) -> String {
        let minutes = Int((seconds / 60).rounded())
        let hours = minutes / 60, rest = minutes % 60
        if hours == 0 { return "\(minutes) m" }
        return rest == 0 ? "\(hours) h" : "\(hours) h \(rest) m"
    }

    /// How a new file in a project during a session counts: an export
    /// (a picture or video in its exports folder, or anywhere in it but
    /// References), a reference, or just a changed file.
    public enum FileRole: Equatable { case export, reference, other }

    public static func role(of path: String, in info: CreativeInfo, created: Bool) -> FileRole? {
        let path = FileAccessPolicy.canonical(path)
        guard let folder = info.folder.map(FileAccessPolicy.canonical), FileLocation.isPath(path, inside: folder)
            || info.resolvedExportsFolder.map({ FileLocation.isPath(path, inside: FileAccessPolicy.canonical($0)) }) == true else {
            return nil
        }
        guard created else { return .other }
        let ext = (path as NSString).pathExtension.lowercased()
        let visual = CreativeFiles.imageExtensions.union(CreativeFiles.videoExtensions).contains(ext)
        let references = info.folder.map { FileAccessPolicy.canonical(($0 as NSString).appendingPathComponent("References")) }
        if let references, FileLocation.isPath(path, inside: references) { return .reference }
        if let exports = info.resolvedExportsFolder.map(FileAccessPolicy.canonical), FileLocation.isPath(path, inside: exports) {
            return visual ? .export : .other
        }
        // Renders and other output folders count too.
        return visual ? .export : .other
    }
}

extension AtlasStore {
    public func saveCreativeSession(_ session: CreativeSession) throws {
        func json<T: Encodable>(_ value: T) throws -> String { String(decoding: try JSONEncoder().encode(value), as: UTF8.self) }
        try database.run(
            """
            INSERT INTO creative_session
                (id, project_id, kind, started_at, ended_at, focused_seconds, exports_json, references_json, files_json, palette_json, tutorials_json)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                project_id = excluded.project_id, kind = excluded.kind, ended_at = excluded.ended_at,
                focused_seconds = excluded.focused_seconds, exports_json = excluded.exports_json,
                references_json = excluded.references_json, files_json = excluded.files_json,
                palette_json = excluded.palette_json, tutorials_json = excluded.tutorials_json;
            """,
            [
                .from(session.id), .from(session.projectID?.uuidString), .text(session.kind.rawValue), .from(session.startedAt),
                .from(session.endedAt), .real(session.focusedSeconds), .text(try json(session.exports)), .text(try json(session.references)),
                .text(try json(session.files)), .text(try json(session.palette)), .text(try json(session.tutorials)),
            ]
        )
    }

    /// Finished sessions that started in `range`, oldest first.
    public func creativeSessions(in range: DateInterval) throws -> [CreativeSession] {
        try database.query(
            "SELECT * FROM creative_session WHERE ended_at IS NOT NULL AND started_at >= ? AND started_at < ? ORDER BY started_at;",
            [.from(range.start), .from(range.end)]
        ).compactMap(Self.creativeSession(from:))
    }

    public func creativeSession(id: UUID) throws -> CreativeSession? {
        try database.query("SELECT * FROM creative_session WHERE id = ?;", [.from(id)]).first.flatMap(Self.creativeSession(from:))
    }

    private static func creativeSession(from row: SQLRow) -> CreativeSession? {
        guard let id = row.uuid("id"), let started = row.date("started_at") else { return nil }
        func decode(_ column: String) -> [String] {
            row.string(column).flatMap { try? JSONDecoder().decode([String].self, from: Data($0.utf8)) } ?? []
        }
        return CreativeSession(
            id: id, projectID: row.uuid("project_id"), kind: row.string("kind").flatMap(CreativeSession.Kind.init) ?? .create,
            startedAt: started, endedAt: row.date("ended_at"), focusedSeconds: row.double("focused_seconds") ?? 0,
            exports: decode("exports_json"), references: decode("references_json"), files: decode("files_json"),
            palette: decode("palette_json"), tutorials: decode("tutorials_json")
        )
    }
}
