import AtlasSpaces
import Foundation

/// The growing bookshelf: one small book per hour studied, in the colour
/// of the course that hour went to (a palette colour when there wasn't
/// one), grouped by term. Pure, for tests.
public enum StudyShelf {
    /// One earned book.
    public struct Book: Equatable, Sendable {
        public var color: String
        public var courseCode: String?
        /// When its hour was completed.
        public var date: Date
    }

    public struct Term: Equatable, Sendable {
        public var name: String
        public var seconds: TimeInterval
        public var books: [Book]
        public var secondsByCourse: [String: TimeInterval]
    }

    /// Terms oldest first (by their first session), with `currentTerm` last
    /// even before anything's been studied in it.
    public static func terms(sessions: [StudySession], currentTerm: String, courses: [Course],
                             palette: [String] = CourseColors.palette) -> [Term] {
        let byID = Dictionary(courses.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var order: [String] = []
        var terms: [String: Term] = [:]
        for session in sessions.sorted(by: { $0.startedAt < $1.startedAt }) where session.focusedSeconds > 0 {
            let name = session.term.isEmpty ? AcademicTerm.name(for: session.startedAt) : session.term
            if terms[name] == nil {
                order.append(name)
                terms[name] = Term(name: name, seconds: 0, books: [], secondsByCourse: [:])
            }
            let course = session.courseID.flatMap { byID[$0] }
            var term = terms[name]!
            term.seconds += session.focusedSeconds
            term.secondsByCourse[course?.displayCode ?? "", default: 0] += session.focusedSeconds
            // Every hour completed during this session is a book for its course.
            while term.seconds >= Double(term.books.count + 1) * 3600 {
                let index = term.books.count
                term.books.append(Book(color: course?.color ?? palette[(index * 5 + name.count) % palette.count],
                                       courseCode: course?.displayCode, date: session.endedAt ?? session.startedAt))
            }
            terms[name] = term
        }
        // The current term goes last: it's the one that grows.
        order.removeAll { $0 == currentTerm }
        order.append(currentTerm)
        return order.map { terms[$0] ?? Term(name: $0, seconds: 0, books: [], secondsByCourse: [:]) }
    }

    /// What the room draws for each term.
    public static func sections(_ terms: [Term]) -> [StudyRoomState.ShelfSection] {
        terms.map { term in
            let hours = term.books.count
            var lines = ["\(term.name) · \(StudyMath.duration(term.seconds)) studied · \(hours) book\(hours == 1 ? "" : "s")"]
            let courses = term.secondsByCourse.filter { $0.value >= 60 }.sorted { $0.value > $1.value }
                .map { "\($0.key.isEmpty ? "No course" : $0.key) \(StudyMath.duration($0.value))" }
            if !courses.isEmpty { lines.append(courses.prefix(4).joined(separator: " · ")) }
            if let latest = term.books.last {
                lines.append("Latest: \(latest.courseCode ?? "No course") · 1 h · \(latest.date.formatted(.dateTime.month(.abbreviated).day()))")
            } else {
                lines.append("A book appears here for every hour you study.")
            }
            return StudyRoomState.ShelfSection(term: term.name, hours: hours, colors: term.books.map(\.color),
                                               detail: lines.joined(separator: "\n"))
        }
    }
}
