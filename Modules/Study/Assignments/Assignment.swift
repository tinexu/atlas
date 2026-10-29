import AtlasCore
import Foundation

/// Something due: homework, a paper, an exam. One row per source item
/// (v9 `assignment`); the same thing from two sources is merged on read.
public struct Assignment: Identifiable, Hashable, Codable, Sendable {
    public enum Kind: String, Codable, Sendable { case assignment, exam }
    public enum Source: String, Codable, Sendable, CaseIterable {
        case calendar, reminders, manual
        public var title: String {
            switch self {
            case .calendar: return "Calendar"
            case .reminders: return "Reminders"
            case .manual: return "Added here"
            }
        }
    }

    public var id: UUID
    public var courseID: UUID?
    public var title: String
    public var dueAt: Date?
    public var kind: Kind
    public var source: Source
    /// The calendar event or reminder it came from.
    public var externalID: String?
    public var isDone: Bool
    public var doneAt: Date?
    public var updatedAt: Date

    public init(id: UUID = UUID(), courseID: UUID? = nil, title: String, dueAt: Date?, kind: Kind = .assignment,
                source: Source, externalID: String? = nil, isDone: Bool = false, doneAt: Date? = nil, updatedAt: Date = Date()) {
        self.id = id
        self.courseID = courseID
        self.title = title
        self.dueAt = dueAt
        self.kind = kind
        self.source = source
        self.externalID = externalID
        self.isDone = isDone
        self.doneAt = doneAt
        self.updatedAt = updatedAt
    }

    /// Words that make a calendar event or reminder something due.
    static let examWords = ["exam", "midterm", "final", "quiz", "test"]
    static let dueWords = ["due", "deadline", "submit", "submission", "assignment", "homework", "hw", "problem set", "pset", "essay", "paper", "project"]

    /// Whether a title reads like an exam ("CHEM101 Midterm").
    static func isExam(_ title: String) -> Bool {
        words(in: title).contains { examWords.contains($0) }
    }

    /// Whether a title reads like something due or an exam.
    static func isDue(_ title: String) -> Bool {
        let lowered = title.lowercased()
        return isExam(title) || dueWords.contains { word in
            word.contains(" ") ? lowered.contains(word) : words(in: title).contains(word)
        }
    }

    private static func words(in text: String) -> [String] {
        text.lowercased().split { !$0.isLetter }.map(String.init)
    }
}

/// One thing due, possibly reported by several sources (a Canvas feed
/// event and a reminder for the same essay). Marking it done marks them all.
public struct MergedAssignment: Identifiable, Hashable, Sendable {
    public var primary: Assignment
    public var duplicates: [Assignment]

    public var id: UUID { primary.id }
    public var all: [Assignment] { [primary] + duplicates }
    public var title: String { primary.title }
    public var courseID: UUID? { primary.courseID ?? duplicates.lazy.compactMap(\.courseID).first }
    public var dueAt: Date? { primary.dueAt ?? duplicates.lazy.compactMap(\.dueAt).first }
    public var isDone: Bool { all.contains(where: \.isDone) }
    public var kind: Assignment.Kind { all.contains { $0.kind == .exam } ? .exam : .assignment }
    public var sources: [Assignment.Source] { all.map(\.source) }
}

public enum AssignmentMerge {
    /// Groups rows that are the same thing: same course (or none), the same
    /// title once course codes, punctuation and filler words are dropped,
    /// and due the same day. Reminders lead a group (they can be checked
    /// off from here), then manual entries, then calendar events.
    public static func merge(_ items: [Assignment], calendar: Calendar = .current) -> [MergedAssignment] {
        let order: [Assignment.Source: Int] = [.reminders: 0, .manual: 1, .calendar: 2]
        let sorted = items.sorted { (order[$0.source]!, $0.updatedAt) < (order[$1.source]!, $1.updatedAt) }
        var groups: [MergedAssignment] = []
        for item in sorted {
            if let index = groups.firstIndex(where: { same($0.primary, item, calendar: calendar) }) {
                groups[index].duplicates.append(item)
            } else {
                groups.append(MergedAssignment(primary: item, duplicates: []))
            }
        }
        return groups.sorted { ($0.dueAt ?? .distantFuture, $0.title) < ($1.dueAt ?? .distantFuture, $1.title) }
    }

    static func same(_ a: Assignment, _ b: Assignment, calendar: Calendar) -> Bool {
        guard a.source != b.source || a.externalID != b.externalID else { return false }
        if let ca = a.courseID, let cb = b.courseID, ca != cb { return false }
        switch (a.dueAt, b.dueAt) {
        case let (x?, y?): guard calendar.isDate(x, inSameDayAs: y) else { return false }
        case (nil, nil): break
        default: return false
        }
        let ka = key(a.title), kb = key(b.title)
        return !ka.isEmpty && (ka == kb || ka.contains(kb) || kb.contains(ka))
    }

    /// "CHEM 101: Problem Set 3 due!" → "problem set 3"
    static func key(_ title: String) -> String {
        var text = title
        for code in CourseCode.find(in: title) {
            for spelling in [code.canonical, code.display, "\(code.subject)-\(code.number)", "\(code.subject)_\(code.number)"] {
                text = text.replacingOccurrences(of: spelling, with: " ", options: .caseInsensitive)
            }
        }
        let filler: Set<String> = ["due", "deadline", "submit", "the", "a", "an", "for", "is", "today", "tomorrow"]
        return text.lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
            .filter { !filler.contains($0) }
            .joined(separator: " ")
    }
}

extension AtlasStore {
    public func saveAssignment(_ assignment: Assignment) throws {
        try database.run(
            """
            INSERT INTO assignment (id, course_id, title, due_at, kind, source, external_id, done, done_at, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                course_id = excluded.course_id, title = excluded.title, due_at = excluded.due_at, kind = excluded.kind,
                done = excluded.done, done_at = excluded.done_at, updated_at = excluded.updated_at;
            """,
            [
                .from(assignment.id), .from(assignment.courseID?.uuidString), .text(assignment.title), .from(assignment.dueAt),
                .text(assignment.kind.rawValue), .text(assignment.source.rawValue), .from(assignment.externalID),
                .from(assignment.isDone), .from(assignment.doneAt), .from(assignment.updatedAt),
            ]
        )
    }

    public func assignments() throws -> [Assignment] {
        try database.query("SELECT * FROM assignment ORDER BY due_at;").compactMap(Self.assignment(from:))
    }

    public func assignment(source: Assignment.Source, externalID: String) throws -> Assignment? {
        try database.query("SELECT * FROM assignment WHERE source = ? AND external_id = ?;",
                           [.text(source.rawValue), .text(externalID)]).first.flatMap(Self.assignment(from:))
    }

    public func deleteAssignment(id: UUID) throws {
        try database.run("DELETE FROM assignment WHERE id = ?;", [.from(id)])
    }

    private static func assignment(from row: SQLRow) -> Assignment? {
        guard let id = row.uuid("id"), let title = row.string("title"),
              let source = row.string("source").flatMap(Assignment.Source.init) else { return nil }
        return Assignment(
            id: id, courseID: row.uuid("course_id"), title: title, dueAt: row.date("due_at"),
            kind: row.string("kind").flatMap(Assignment.Kind.init) ?? .assignment, source: source,
            externalID: row.string("external_id"), isDone: row.bool("done") ?? false, doneAt: row.date("done_at"),
            updatedAt: row.date("updated_at") ?? Date()
        )
    }
}
