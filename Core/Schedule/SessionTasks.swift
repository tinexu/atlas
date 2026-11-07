import Foundation

// Session tasks: what you want to get done in a focus session, written
// before or during it and checked off as you go. Headless and shared, so
// any Space with a session timer can use it (the Study Library first).

/// One task (v11 `session_task`).
public struct SessionTask: Identifiable, Codable, Hashable, Sendable {
    /// A course or project the task belongs to (its colour shows as a dot).
    public struct Link: Codable, Hashable, Sendable {
        public enum Kind: String, Codable, Sendable { case course, project }
        public var kind: Kind
        public var id: UUID
        /// "CHEM 101", "Robot"
        public var label: String
        /// "#RRGGBB", if it has one.
        public var color: String?
        /// Other names it answers to for "#…" (a course's full name).
        public var aliases: [String]

        public init(kind: Kind, id: UUID, label: String, color: String? = nil, aliases: [String] = []) {
            self.kind = kind
            self.id = id
            self.label = label
            self.color = color
            self.aliases = aliases
        }
    }

    public var id: UUID
    public var title: String
    public var done: Bool
    public var completedAt: Date?
    /// 1…8, if you said ("x2", "🍅2").
    public var estimatedPomodoros: Int?
    public var actualPomodoros: Int
    public var order: Int
    public var link: Link?
    /// The assignment it came from (Study Library chalkboard).
    public var assignmentID: UUID?
    /// Which kind of Space it's for (its template ID), for carrying over.
    public var space: String
    public var createdAt: Date
    /// The session it's in; nil while waiting for the next one (planned
    /// before starting, added between sessions, or carried over).
    public var sessionID: UUID?
    /// Left unfinished last time and kept for the next session.
    public var carriedOver: Bool
    /// Pinned as the current task, whatever its place in the list.
    public var pinned: Bool

    public init(id: UUID = UUID(), title: String, done: Bool = false, completedAt: Date? = nil, estimatedPomodoros: Int? = nil,
                actualPomodoros: Int = 0, order: Int = 0, link: Link? = nil, assignmentID: UUID? = nil, space: String,
                createdAt: Date = Date(), sessionID: UUID? = nil, carriedOver: Bool = false, pinned: Bool = false) {
        self.id = id
        self.title = title
        self.done = done
        self.completedAt = completedAt
        self.estimatedPomodoros = estimatedPomodoros.map(SessionTask.clampEstimate)
        self.actualPomodoros = actualPomodoros
        self.order = order
        self.link = link
        self.assignmentID = assignmentID
        self.space = space
        self.createdAt = createdAt
        self.sessionID = sessionID
        self.carriedOver = carriedOver
        self.pinned = pinned
    }

    public static func clampEstimate(_ value: Int) -> Int { min(8, max(1, value)) }

    /// "from yesterday", "from Tuesday", for a carried-over task.
    public func carriedLabel(now: Date, calendar: Calendar = .current) -> String? {
        guard carriedOver else { return nil }
        if calendar.isDate(createdAt, inSameDayAs: now) { return "from earlier" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(createdAt, inSameDayAs: yesterday) {
            return "from yesterday"
        }
        return "from \(createdAt.formatted(.dateTime.weekday(.wide)))"
    }
}

// MARK: - Inline shortcuts

/// Reads the shortcuts typed into a task's title, then removes them:
/// "x2" or "🍅2" at the end is an estimate of 2 pomodoros; "#CHEM101" or
/// "#robot" links the course or project it best matches. Anything that
/// isn't a shortcut (or a "#…" that matches nothing) stays in the title.
public enum TaskTitleParser {
    public struct Parsed: Equatable, Sendable {
        public var title: String
        public var estimate: Int?
        public var link: SessionTask.Link?
    }

    public static func parse(_ raw: String, links: [SessionTask.Link] = []) -> Parsed {
        var words = raw.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        var estimate: Int?
        var link: SessionTask.Link?

        // "#tag" anywhere: the first that matches a course or project.
        var kept: [String] = []
        for word in words {
            if link == nil, word.count > 1, word.hasPrefix("#"), let match = bestLink(for: String(word.dropFirst()), in: links) {
                link = match
            } else {
                kept.append(word)
            }
        }
        words = kept

        // "x2" / "🍅2" / "🍅 2" at the end.
        if let last = words.last {
            if let n = estimateToken(last), words.count > 1 {
                estimate = n
                words.removeLast()
            } else if words.count > 2, Int(last) != nil, words[words.count - 2] == "🍅", let n = Int(last), (1...99).contains(n) {
                estimate = SessionTask.clampEstimate(n)
                words.removeLast(2)
            }
        }
        let title = estimate == nil && link == nil ? raw.trimmingCharacters(in: .whitespaces) : words.joined(separator: " ")
        return Parsed(title: title, estimate: estimate, link: link)
    }

    /// "x2", "X3", "🍅2", "×2" → the number (1…8).
    static func estimateToken(_ token: String) -> Int? {
        for prefix in ["🍅", "x", "X", "×"] where token.hasPrefix(prefix) {
            let digits = token.dropFirst(prefix.count)
            if !digits.isEmpty, digits.allSatisfy(\.isNumber), let n = Int(digits), n >= 1 { return SessionTask.clampEstimate(n) }
        }
        return nil
    }

    /// Letters and digits only, lowercased ("CHEM 101" → "chem101").
    static func key(_ text: String) -> String {
        String(text.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(Character.init))
    }

    /// Exact (ignoring spaces and case), then a prefix, then one typo.
    static func bestLink(for tag: String, in links: [SessionTask.Link]) -> SessionTask.Link? {
        let needle = key(tag)
        guard !needle.isEmpty else { return nil }
        var best: (link: SessionTask.Link, score: Int)?
        for link in links {
            for name in [link.label] + link.aliases {
                let hay = key(name)
                guard !hay.isEmpty else { continue }
                let score: Int
                if hay == needle { score = 3 }
                else if hay.hasPrefix(needle) && needle.count >= 3 { score = 2 }
                else if needle.count >= 4 && distance(hay, needle) <= 1 { score = 1 }
                else { continue }
                if score > (best?.score ?? 0) { best = (link, score) }
            }
        }
        return best?.link
    }

    static func distance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        guard !a.isEmpty else { return b.count }
        guard !b.isEmpty else { return a.count }
        var row = Array(0...b.count)
        for i in 1...a.count {
            var previous = row[0]
            row[0] = i
            for j in 1...b.count {
                let saved = row[j]
                row[j] = min(row[j] + 1, row[j - 1] + 1, previous + (a[i - 1] == b[j - 1] ? 0 : 1))
                previous = saved
            }
        }
        return row[b.count]
    }
}

// MARK: - The list

/// The rules of a session's task list: which task is current, where new
/// ones go, and what checking one off does. Pure, so it's easy to test.
public struct SessionTaskList: Equatable, Sendable {
    public var tasks: [SessionTask]

    public init(_ tasks: [SessionTask]) {
        self.tasks = tasks
    }

    /// Unchecked, in order: a pinned task first, carried-over ones next.
    public var open: [SessionTask] {
        tasks.filter { !$0.done }.sorted { ($0.pinned ? 0 : 1, $0.order, $0.createdAt) < ($1.pinned ? 0 : 1, $1.order, $1.createdAt) }
    }

    /// Checked off, oldest first.
    public var finished: [SessionTask] {
        tasks.filter(\.done).sorted { ($0.completedAt ?? .distantPast) < ($1.completedAt ?? .distantPast) }
    }

    /// The one you're on: the pinned task, else the first unchecked.
    public var current: SessionTask? { open.first }

    public var allDone: Bool { !tasks.isEmpty && open.isEmpty }

    /// Adds a task at the end of the open ones.
    @discardableResult
    public mutating func append(_ task: SessionTask) -> SessionTask {
        var task = task
        task.order = (tasks.map(\.order).max() ?? -1) + 1
        tasks.append(task)
        return task
    }

    public mutating func check(_ id: UUID, at date: Date) {
        guard let index = tasks.firstIndex(where: { $0.id == id }), !tasks[index].done else { return }
        tasks[index].done = true
        tasks[index].completedAt = date
        tasks[index].pinned = false
    }

    public mutating func uncheck(_ id: UUID) {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }
        tasks[index].done = false
        tasks[index].completedAt = nil
    }

    /// Pins one task as current (unpinning any other); pinning it again unpins.
    public mutating func pin(_ id: UUID) {
        let wasPinned = tasks.first { $0.id == id }?.pinned ?? false
        for index in tasks.indices { tasks[index].pinned = !wasPinned && tasks[index].id == id && !tasks[index].done }
    }

    /// Puts the open tasks in this order (the done ones keep theirs).
    public mutating func reorder(_ ids: [UUID]) {
        for (position, id) in ids.enumerated() {
            if let index = tasks.firstIndex(where: { $0.id == id }) { tasks[index].order = position }
        }
    }

    public mutating func remove(_ id: UUID) {
        tasks.removeAll { $0.id == id }
    }
}

// MARK: - Pomodoro credit

/// Which task a finished pomodoro counts for: the one that was current for
/// most of it, so switching tasks halfway credits the one you spent longer on.
public struct PomodoroCredit: Equatable, Sendable {
    private var started: Date?
    private var segments: [(task: UUID?, since: Date)] = []

    public init() {}

    public static func == (a: PomodoroCredit, b: PomodoroCredit) -> Bool {
        a.started == b.started && a.segments.map(\.task) == b.segments.map(\.task) && a.segments.map(\.since) == b.segments.map(\.since)
    }

    public var isRunning: Bool { started != nil }

    /// A focus phase began, with this task current.
    public mutating func begin(at date: Date, current: UUID?) {
        started = date
        segments = [(current, date)]
    }

    /// The current task changed (checked off, pinned, reordered, added).
    public mutating func current(_ task: UUID?, at date: Date) {
        guard started != nil, segments.last?.task != task else { return }
        segments.append((task, date))
    }

    /// The focus phase ended: the task to credit (nil if none was current most of the time).
    public mutating func finish(at date: Date) -> UUID? {
        defer {
            started = nil
            segments = []
        }
        guard started != nil else { return nil }
        var totals: [UUID: TimeInterval] = [:]
        var empty: TimeInterval = 0
        for (index, segment) in segments.enumerated() {
            let end = index + 1 < segments.count ? segments[index + 1].since : date
            let length = max(0, end.timeIntervalSince(segment.since))
            if let task = segment.task { totals[task, default: 0] += length } else { empty += length }
        }
        // Ties go to the task that was current first.
        let order = segments.compactMap(\.task)
        guard let best = totals.max(by: { ($0.value, -(order.firstIndex(of: $0.key) ?? 0)) < ($1.value, -(order.firstIndex(of: $1.key) ?? 0)) }),
              best.value >= empty
        else { return nil }
        return best.key
    }
}

// MARK: - Settings and events

/// How tasks behave in sessions (kept with the Space's own settings).
public struct SessionTaskSettings: Codable, Equatable, Sendable {
    public enum CarryOver: String, Codable, CaseIterable, Sendable, Identifiable {
        case ask, always, never
        public var id: Self { self }
        public var title: String {
            switch self {
            case .ask: return "Ask"
            case .always: return "Always carry over"
            case .never: return "Clear them"
            }
        }
    }

    /// "What do you want to get done?" before the timer starts.
    public var promptAtStart = true
    public var quickAddHotKey = "opt+shift+t"
    /// "Did you finish …?" at each break.
    public var breakCheckIn = true
    public var carryOver: CarryOver = .ask
    /// Mochi hops when you check one off.
    public var celebrations = true
    /// Checking off a task from an assignment completes its reminder too.
    public var syncAssignments = true

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = SessionTaskSettings()
        promptAtStart = try c.decodeIfPresent(Bool.self, forKey: .promptAtStart) ?? d.promptAtStart
        quickAddHotKey = try c.decodeIfPresent(String.self, forKey: .quickAddHotKey) ?? d.quickAddHotKey
        breakCheckIn = try c.decodeIfPresent(Bool.self, forKey: .breakCheckIn) ?? d.breakCheckIn
        carryOver = try c.decodeIfPresent(CarryOver.self, forKey: .carryOver) ?? d.carryOver
        celebrations = try c.decodeIfPresent(Bool.self, forKey: .celebrations) ?? d.celebrations
        syncAssignments = try c.decodeIfPresent(Bool.self, forKey: .syncAssignments) ?? d.syncAssignments
    }
}

extension AtlasEvent.Name {
    /// The task list changed. Payload: space.
    public static let sessionTasksChanged = "session.tasks.changed"
    /// A task was checked off. Payload: taskId, title, space, assignmentId,
    /// last (it was the last open one), celebrate (Mochi may hop).
    public static let sessionTaskCompleted = "session.task.completed"
    /// A break began with a task in progress. Payload: taskId, title.
    public static let sessionTaskCheckIn = "session.task.checkIn"
}

/// What the end-of-session card says about tasks.
public struct SessionTaskTally: Codable, Equatable, Sendable {
    public struct Line: Codable, Equatable, Sendable {
        public var title: String
        public var planned: Int?
        public var actual: Int

        public init(title: String, planned: Int?, actual: Int) {
            self.title = title
            self.planned = planned
            self.actual = actual
        }

        /// "Outline essay: planned 2 🍅, took 3"
        public var text: String {
            guard let planned else { return actual > 0 ? "\(title): took \(actual) 🍅" : title }
            return "\(title): planned \(planned) 🍅, took \(actual)"
        }
    }

    public var done: Int
    public var total: Int
    public var finished: [Line]
    /// Unfinished tasks waiting for "Carry over" or "Clear" (0 once decided).
    public var unfinished: Int

    public init(done: Int, total: Int, finished: [Line], unfinished: Int) {
        self.done = done
        self.total = total
        self.finished = finished
        self.unfinished = unfinished
    }

    /// "4 of 5 tasks done"
    public var headline: String { "\(done) of \(total) task\(total == 1 ? "" : "s") done" }
}

// MARK: - Storage

extension AtlasStore {
    public func saveSessionTask(_ task: SessionTask) throws {
        try database.run(
            """
            INSERT INTO session_task
                (id, title, done, completed_at, estimated, actual, sort_order, link_json, assignment_id, space, created_at,
                 session_id, carried_over, pinned)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                title = excluded.title, done = excluded.done, completed_at = excluded.completed_at, estimated = excluded.estimated,
                actual = excluded.actual, sort_order = excluded.sort_order, link_json = excluded.link_json,
                assignment_id = excluded.assignment_id, space = excluded.space, session_id = excluded.session_id,
                carried_over = excluded.carried_over, pinned = excluded.pinned;
            """,
            [
                .from(task.id), .text(task.title), .from(task.done), .from(task.completedAt), .from(task.estimatedPomodoros),
                .from(task.actualPomodoros), .from(task.order),
                .from(task.link.flatMap { (try? JSONEncoder().encode($0)).flatMap { String(data: $0, encoding: .utf8) } }),
                .from(task.assignmentID?.uuidString), .text(task.space), .from(task.createdAt), .from(task.sessionID?.uuidString),
                .from(task.carriedOver), .from(task.pinned),
            ]
        )
    }

    public func deleteSessionTask(id: UUID) throws {
        try database.run("DELETE FROM session_task WHERE id = ?;", [.from(id)])
    }

    /// A session's tasks.
    public func sessionTasks(sessionID: UUID) throws -> [SessionTask] {
        try database.query("SELECT * FROM session_task WHERE session_id = ? ORDER BY sort_order, created_at;", [.from(sessionID)])
            .compactMap(Self.sessionTask(from:))
    }

    /// Tasks waiting for the next session in a kind of Space (planned or carried over).
    public func waitingSessionTasks(space: String) throws -> [SessionTask] {
        try database.query("SELECT * FROM session_task WHERE session_id IS NULL AND done = 0 AND space = ? ORDER BY sort_order, created_at;",
                           [.text(space)]).compactMap(Self.sessionTask(from:))
    }

    /// Tasks checked off in `range` (for stats).
    public func completedSessionTasks(in range: DateInterval, space: String? = nil) throws -> [SessionTask] {
        var sql = "SELECT * FROM session_task WHERE done = 1 AND completed_at >= ? AND completed_at < ?"
        var values: [SQLValue] = [.from(range.start), .from(range.end)]
        if let space {
            sql += " AND space = ?"
            values.append(.text(space))
        }
        return try database.query(sql + " ORDER BY completed_at;", values).compactMap(Self.sessionTask(from:))
    }

    private static func sessionTask(from row: SQLRow) -> SessionTask? {
        guard let id = row.uuid("id"), let title = row.string("title"), let space = row.string("space") else { return nil }
        let link = row.string("link_json").flatMap { try? JSONDecoder().decode(SessionTask.Link.self, from: Data($0.utf8)) }
        return SessionTask(
            id: id, title: title, done: row.bool("done") ?? false, completedAt: row.date("completed_at"),
            estimatedPomodoros: row.int("estimated"), actualPomodoros: row.int("actual") ?? 0, order: row.int("sort_order") ?? 0,
            link: link, assignmentID: row.uuid("assignment_id"), space: space, createdAt: row.date("created_at") ?? Date(),
            sessionID: row.uuid("session_id"), carriedOver: row.bool("carried_over") ?? false, pinned: row.bool("pinned") ?? false
        )
    }
}
