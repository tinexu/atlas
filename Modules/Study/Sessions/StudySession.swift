import AtlasCore
import Foundation

/// Which course a session was about, and how ATLAS knows.
public struct CourseGuess: Codable, Hashable, Sendable {
    public enum Reason: String, Codable, Sendable {
        /// You clicked its book.
        case clicked
        /// Its class was on the calendar at the time.
        case classNow
        /// Most of the files you changed were in its folder or notes.
        case files
        /// You picked it ("Change").
        case chosen

        public var phrase: String {
            switch self {
            case .clicked: return "you opened its book"
            case .classNow: return "its class was on"
            case .files: return "you worked in its files"
            case .chosen: return "you picked it"
            }
        }
    }

    public var courseID: UUID
    public var reason: Reason

    public init(courseID: UUID, reason: Reason) {
        self.courseID = courseID
        self.reason = reason
    }

    /// The book you clicked (within 30 minutes before starting), else the
    /// class happening now, else the course whose files you changed most.
    public static func guess(clicked: (id: UUID, at: Date)?, sessionStart: Date, classNow: UUID?,
                             fileCounts: [UUID: Int]) -> CourseGuess? {
        if let clicked, clicked.at >= sessionStart.addingTimeInterval(-30 * 60) {
            return CourseGuess(courseID: clicked.id, reason: .clicked)
        }
        if let classNow { return CourseGuess(courseID: classNow, reason: .classNow) }
        if let busiest = fileCounts.filter({ $0.value > 0 }).max(by: { ($0.value, $1.key.uuidString) < ($1.value, $0.key.uuidString) }) {
            return CourseGuess(courseID: busiest.key, reason: .files)
        }
        return nil
    }
}

/// One study session, saved when it ends (v9 `study_session`).
public struct StudySession: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var guess: CourseGuess?
    public var term: String
    public var startedAt: Date
    public var endedAt: Date?
    public var focusedSeconds: TimeInterval
    public var pomodoros: Int
    /// Files changed in course folders and notes during the session.
    public var files: [String]
    /// Assignments checked off during the session.
    public var completedAssignments: [UUID]

    public init(id: UUID = UUID(), guess: CourseGuess? = nil, term: String = "", startedAt: Date, endedAt: Date? = nil,
                focusedSeconds: TimeInterval = 0, pomodoros: Int = 0, files: [String] = [], completedAssignments: [UUID] = []) {
        self.id = id
        self.guess = guess
        self.term = term
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.focusedSeconds = focusedSeconds
        self.pomodoros = pomodoros
        self.files = files
        self.completedAssignments = completedAssignments
    }

    public var courseID: UUID? { guess?.courseID }
}

/// What the end-of-session card shows.
public struct StudySummary: Codable, Equatable, Sendable {
    public var sessionID: UUID
    public var focusedSeconds: TimeInterval
    public var pomodoros: Int
    public var courseCode: String?
    public var guessReason: CourseGuess.Reason?
    /// Course codes whose notes or folder changed.
    public var notesUpdated: [String]
    public var assignmentsCompleted: Int
    public var streak: Int
    public var endedEarly: Bool

    /// "1 h 40 m studied · 3 pomodoros · CHEM101 notes updated · 2 assignments checked off · streak 5 days"
    public var headline: String {
        var parts = ["\(StudyMath.duration(focusedSeconds)) studied"]
        if pomodoros > 0 { parts.append("\(pomodoros) pomodoro\(pomodoros == 1 ? "" : "s")") }
        if !notesUpdated.isEmpty { parts.append("\(notesUpdated.joined(separator: ", ")) notes updated") }
        if assignmentsCompleted > 0 {
            parts.append("\(assignmentsCompleted) assignment\(assignmentsCompleted == 1 ? "" : "s") checked off")
        }
        if streak > 0 { parts.append("streak \(streak) day\(streak == 1 ? "" : "s")") }
        return parts.joined(separator: " · ")
    }
}

extension AtlasStore {
    public func saveStudySession(_ session: StudySession) throws {
        try database.run(
            """
            INSERT INTO study_session
                (id, course_id, course_guess, term, started_at, ended_at, focused_seconds, pomodoros, files_json, completed_json)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                course_id = excluded.course_id, course_guess = excluded.course_guess, term = excluded.term,
                ended_at = excluded.ended_at, focused_seconds = excluded.focused_seconds, pomodoros = excluded.pomodoros,
                files_json = excluded.files_json, completed_json = excluded.completed_json;
            """,
            [
                .from(session.id), .from(session.courseID?.uuidString), .from(session.guess?.reason.rawValue), .text(session.term),
                .from(session.startedAt), .from(session.endedAt), .real(session.focusedSeconds), .from(session.pomodoros),
                .text(try Self.studyJSON(session.files)), .text(try Self.studyJSON(session.completedAssignments)),
            ]
        )
    }

    /// Finished sessions that started in `range`, oldest first.
    public func studySessions(in range: DateInterval) throws -> [StudySession] {
        try database.query(
            "SELECT * FROM study_session WHERE ended_at IS NOT NULL AND started_at >= ? AND started_at < ? ORDER BY started_at;",
            [.from(range.start), .from(range.end)]
        ).compactMap(Self.studySession(from:))
    }

    public func studySession(id: UUID) throws -> StudySession? {
        try database.query("SELECT * FROM study_session WHERE id = ?;", [.from(id)]).first.flatMap(Self.studySession(from:))
    }

    private static func studySession(from row: SQLRow) -> StudySession? {
        guard let id = row.uuid("id"), let started = row.date("started_at") else { return nil }
        func decode<T: Decodable>(_ column: String, _ fallback: T) -> T {
            row.string(column).flatMap { try? JSONDecoder().decode(T.self, from: Data($0.utf8)) } ?? fallback
        }
        var guess: CourseGuess?
        if let course = row.uuid("course_id") {
            guess = CourseGuess(courseID: course, reason: row.string("course_guess").flatMap(CourseGuess.Reason.init) ?? .chosen)
        }
        return StudySession(
            id: id, guess: guess, term: row.string("term") ?? "", startedAt: started, endedAt: row.date("ended_at"),
            focusedSeconds: row.double("focused_seconds") ?? 0, pomodoros: row.int("pomodoros") ?? 0,
            files: decode("files_json", []), completedAssignments: decode("completed_json", [])
        )
    }
}
