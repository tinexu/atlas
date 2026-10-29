import AtlasCore
import Foundation

/// Assignments from your school calendar feed, a Reminders list and ones
/// you add, merged and de-duplicated. Calendar events are never changed;
/// a reminder is only ever marked complete, when you check it off.
public final class AssignmentService: @unchecked Sendable {
    let core: AtlasCore
    let courses: StudyService
    public let reminders: ReminderStore
    var store: AtlasStore { core.store }
    /// A study session to credit when something is checked off.
    var onCompleted: (([UUID]) -> Void)?
    private var token: TriggerToken?

    init(core: AtlasCore, courses: StudyService, reminders: ReminderStore) {
        self.core = core
        self.courses = courses
        self.reminders = reminders
        token = reminders.observeChanges { [weak self] in
            guard let self else { return }
            Task { await self.sync() }
        }
    }

    deinit { token?.cancel() }

    private var now: Date { courses.now() }

    // MARK: - Reading

    /// Everything, merged, soonest first.
    public func all() -> [MergedAssignment] {
        AssignmentMerge.merge((try? store.assignments()) ?? [])
    }

    /// Not done and due from the start of today to `days` days ahead.
    public func upcoming(days: Int = 7) -> [MergedAssignment] {
        let start = Calendar.current.startOfDay(for: now)
        let end = start.addingTimeInterval(Double(days + 1) * 86_400)
        return all().filter { !$0.isDone && ($0.dueAt.map { $0 >= start && $0 < end } ?? false) }
    }

    /// The next thing due or exam that isn't done.
    public func nextDeadline() -> MergedAssignment? {
        let start = Calendar.current.startOfDay(for: now)
        return all().first { !$0.isDone && ($0.dueAt.map { $0 >= start } ?? false) }
    }

    /// The next exam within `days`.
    public func upcomingExam(within days: Int) -> MergedAssignment? {
        upcoming(days: days).first { $0.kind == .exam }
    }

    // MARK: - Sync

    /// Pulls from the calendar and Reminders. Rows keep their done state;
    /// items that vanished from their source are dropped.
    @discardableResult
    public func sync() async -> Bool {
        let settings = courses.settings
        let known = courses.courses()
        var changed = false

        // Calendar: a school feed counts whole (when it matches a course or
        // reads like something due); other calendars only for due and exam
        // events of a course (so lectures don't become assignments).
        let window = DateInterval(start: now.addingTimeInterval(-7 * 86_400), duration: 70 * 86_400)
        let events = core.time?.calendar.allEvents(in: window, alsoFrom: settings.assignmentCalendarIDs) ?? []
        var seen = Set<String>()
        for event in events {
            let course = known.first { $0.matches(event.title) }
            let isFeed = settings.assignmentCalendarIDs.contains(event.calendarID)
            let due = Assignment.isDue(event.title)
            guard isFeed ? (course != nil || due) : (due && course != nil) else { continue }
            seen.insert(event.id)
            let dueAt = event.isAllDay ? Calendar.current.date(bySettingHour: 23, minute: 59, second: 0, of: event.start) : event.start
            changed = upsert(source: .calendar, externalID: event.id, title: event.title, dueAt: dueAt,
                             kind: Assignment.isExam(event.title) ? .exam : .assignment, courseID: course?.id, isDone: nil) || changed
        }
        for row in (try? store.assignments()) ?? [] where row.source == .calendar {
            guard let id = row.externalID, !seen.contains(id), let due = row.dueAt, window.contains(due) else { continue }
            try? store.deleteAssignment(id: row.id)
            changed = true
        }

        // Reminders: everything in the chosen list, course by code in the title.
        if let listID = settings.remindersListID, reminders.access() == .granted {
            let items = await reminders.reminders(listID: listID)
            let ids = Set(items.map(\.id))
            for item in items {
                let course = known.first { $0.matches(item.title) }
                changed = upsert(source: .reminders, externalID: item.id, title: item.title, dueAt: item.dueAt,
                                 kind: Assignment.isExam(item.title) ? .exam : .assignment, courseID: course?.id,
                                 isDone: item.isCompleted) || changed
            }
            for row in (try? store.assignments()) ?? [] where row.source == .reminders {
                guard let id = row.externalID, !ids.contains(id) else { continue }
                try? store.deleteAssignment(id: row.id)
                changed = true
            }
        }
        if changed { core.events.publish(AtlasEvent(AtlasEvent.Name.studyChanged)) }
        return changed
    }

    /// Inserts or updates a source item; `isDone` nil keeps the stored state.
    private func upsert(source: Assignment.Source, externalID: String, title: String, dueAt: Date?, kind: Assignment.Kind,
                        courseID: UUID?, isDone: Bool?) -> Bool {
        let existing = try? store.assignment(source: source, externalID: externalID)
        var row = existing ?? Assignment(title: title, dueAt: dueAt, source: source, externalID: externalID)
        let before = row
        row.title = title
        row.dueAt = dueAt
        row.kind = kind
        row.courseID = courseID
        if let isDone, isDone != row.isDone {
            row.isDone = isDone
            row.doneAt = isDone ? (row.doneAt ?? now) : nil
        }
        guard existing == nil || row != before else { return false }
        row.updatedAt = now
        try? store.saveAssignment(row)
        return true
    }

    // MARK: - Changing

    /// Checks something off (or back on). Every source row of it changes;
    /// a reminder is marked complete in Reminders too (never un-completed).
    public func setDone(_ done: Bool, assignmentID: UUID) throws {
        guard let merged = all().first(where: { $0.all.contains { $0.id == assignmentID } }) else { return }
        for var row in merged.all where row.isDone != done {
            if done, row.source == .reminders, let id = row.externalID {
                try reminders.complete(id: id)
            }
            row.isDone = done
            row.doneAt = done ? now : nil
            row.updatedAt = now
            try store.saveAssignment(row)
        }
        if done { onCompleted?(merged.all.map(\.id)) }
        core.events.publish(AtlasEvent(AtlasEvent.Name.studyChanged))
    }

    @discardableResult
    public func add(title: String, courseID: UUID?, dueAt: Date?) throws -> Assignment {
        let row = Assignment(courseID: courseID, title: title, dueAt: dueAt, kind: Assignment.isExam(title) ? .exam : .assignment,
                             source: .manual, externalID: UUID().uuidString, updatedAt: now)
        try store.saveAssignment(row)
        core.events.publish(AtlasEvent(AtlasEvent.Name.studyChanged))
        return row
    }

    /// Only ones added here can be deleted; synced ones come back from their source.
    public func delete(assignmentID: UUID) throws {
        guard let row = try store.assignments().first(where: { $0.id == assignmentID }), row.source == .manual else { return }
        try store.deleteAssignment(id: row.id)
        core.events.publish(AtlasEvent(AtlasEvent.Name.studyChanged))
    }
}
