import AtlasCore
import Foundation

/// Storage for courses (v9). Assignments and sessions join later phases.
extension AtlasStore {
    public func saveCourse(_ course: Course) throws {
        try database.run(
            """
            INSERT INTO course
                (id, position, name, code, aliases_json, color, folder_path, folder_bookmark, notes_json, links_json,
                 match_json, opens_json, term, archived, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                position = excluded.position, name = excluded.name, code = excluded.code,
                aliases_json = excluded.aliases_json, color = excluded.color, folder_path = excluded.folder_path,
                folder_bookmark = excluded.folder_bookmark, notes_json = excluded.notes_json,
                links_json = excluded.links_json, match_json = excluded.match_json, opens_json = excluded.opens_json,
                term = excluded.term, archived = excluded.archived;
            """,
            [
                .from(course.id), .from(course.position), .text(course.name), .text(course.code),
                .text(try Self.studyJSON(course.aliases)), .text(course.color), .from(course.folderPath),
                course.folderBookmark.map(SQLValue.blob) ?? .null, .text(try Self.studyJSON(course.notes)),
                .text(try Self.studyJSON(course.links)), .text(try Self.studyJSON(course.matchTerms)),
                .text(try Self.studyJSON(course.opens)), .text(course.term), .from(course.isArchived), .from(course.createdAt),
            ]
        )
    }

    /// Courses in shelf order; archived ones only if asked.
    public func courses(includingArchived: Bool = false) throws -> [Course] {
        let sql = includingArchived
            ? "SELECT * FROM course ORDER BY archived, position, created_at;"
            : "SELECT * FROM course WHERE archived = 0 ORDER BY position, created_at;"
        return try database.query(sql).compactMap(Self.course(from:))
    }

    public func course(id: UUID) throws -> Course? {
        try database.query("SELECT * FROM course WHERE id = ?;", [.from(id)]).first.flatMap(Self.course(from:))
    }

    public func deleteCourse(id: UUID) throws {
        try database.run("DELETE FROM course WHERE id = ?;", [.from(id)])
    }

    private static func course(from row: SQLRow) -> Course? {
        guard let id = row.uuid("id"), let name = row.string("name"), let code = row.string("code"), let color = row.string("color")
        else { return nil }
        var bookmark: Data?
        if case .blob(let data)? = row.columns["folder_bookmark"] { bookmark = data }
        func decode<T: Decodable>(_ column: String, _ fallback: T) -> T {
            row.string(column).flatMap { try? JSONDecoder().decode(T.self, from: Data($0.utf8)) } ?? fallback
        }
        return Course(
            id: id, position: row.int("position") ?? 0, name: name, code: code, aliases: decode("aliases_json", []),
            color: color, folderPath: row.string("folder_path"), folderBookmark: bookmark,
            notes: decode("notes_json", Course.Notes.none(remark: nil)), links: decode("links_json", []),
            matchTerms: decode("match_json", []), opens: decode("opens_json", Course.Opens()), term: row.string("term") ?? "",
            isArchived: row.bool("archived") ?? false, createdAt: row.date("created_at") ?? Date()
        )
    }

    static func studyJSON<T: Encodable>(_ value: T) throws -> String {
        String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
    }
}
