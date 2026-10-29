import AtlasCore
import EventKit
import Foundation

public struct ReminderList: Identifiable, Hashable, Sendable {
    public let id: String
    public let title: String

    public init(id: String, title: String) {
        self.id = id
        self.title = title
    }
}

public struct ReminderItem: Identifiable, Hashable, Sendable {
    public let id: String
    public var title: String
    public var dueAt: Date?
    public var isCompleted: Bool

    public init(id: String, title: String, dueAt: Date?, isCompleted: Bool) {
        self.id = id
        self.title = title
        self.dueAt = dueAt
        self.isCompleted = isCompleted
    }
}

/// Apple Reminders, or a mock in tests. ATLAS only reads, and marks a
/// reminder complete when you check it off in the room.
public protocol ReminderStore: Sendable {
    func access() -> CalendarAccess
    func requestAccess() async -> CalendarAccess
    func lists() -> [ReminderList]
    /// Open reminders, and ones completed in the last two weeks.
    func reminders(listID: String) async -> [ReminderItem]
    func complete(id: String) throws
    func observeChanges(_ handler: @escaping @Sendable () -> Void) -> TriggerToken
}

/// Reminders through EventKit. Access is asked for only when you choose a
/// Reminders list as an assignment source.
public final class EventKitReminderStore: ReminderStore, @unchecked Sendable {
    private let store = EKEventStore()

    public init() {}

    public func access() -> CalendarAccess {
        switch EKEventStore.authorizationStatus(for: .reminder) {
        case .fullAccess: return .granted
        case .notDetermined: return .notDetermined
        case .restricted: return .restricted
        default: return .denied
        }
    }

    public func requestAccess() async -> CalendarAccess {
        let granted = (try? await store.requestFullAccessToReminders()) ?? false
        return granted ? .granted : access()
    }

    public func lists() -> [ReminderList] {
        guard access() == .granted else { return [] }
        return store.calendars(for: .reminder).map { ReminderList(id: $0.calendarIdentifier, title: $0.title) }
    }

    public func reminders(listID: String) async -> [ReminderItem] {
        guard access() == .granted, let list = store.calendar(withIdentifier: listID) else { return [] }
        let open = store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: [list])
        let done = store.predicateForCompletedReminders(withCompletionDateStarting: Date().addingTimeInterval(-14 * 86_400),
                                                        ending: nil, calendars: [list])
        var items: [ReminderItem] = []
        for predicate in [open, done] {
            let found: [EKReminder] = await withCheckedContinuation { continuation in
                store.fetchReminders(matching: predicate) { continuation.resume(returning: $0 ?? []) }
            }
            items += found.map { reminder in
                ReminderItem(id: reminder.calendarItemIdentifier, title: reminder.title ?? "Untitled",
                             dueAt: reminder.dueDateComponents.flatMap { Calendar.current.date(from: $0) },
                             isCompleted: reminder.isCompleted)
            }
        }
        return items
    }

    public func complete(id: String) throws {
        guard let reminder = store.calendarItem(withIdentifier: id) as? EKReminder else { return }
        reminder.isCompleted = true
        try store.save(reminder, commit: true)
    }

    public func observeChanges(_ handler: @escaping @Sendable () -> Void) -> TriggerToken {
        let observer = NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store, queue: nil) { _ in handler() }
        return TriggerToken { NotificationCenter.default.removeObserver(observer) }
    }
}
