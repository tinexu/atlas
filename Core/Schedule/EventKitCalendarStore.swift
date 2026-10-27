#if os(macOS)
import AppKit
import EventKit
import Foundation

/// macOS Calendar through EventKit. Google and Outlook calendars work
/// through the accounts already added to Calendar. Access is requested only
/// when calendar integration is turned on.
public final class EventKitCalendarStore: CalendarStore, @unchecked Sendable {
    private let store = EKEventStore()

    public init() {}

    public func access() -> CalendarAccess {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess: return .granted
        case .notDetermined: return .notDetermined
        case .restricted: return .restricted
        default: return .denied
        }
    }

    public func requestAccess() async -> CalendarAccess {
        let granted = (try? await store.requestFullAccessToEvents()) ?? false
        return granted ? .granted : access()
    }

    public func calendars() -> [CalendarInfo] {
        store.calendars(for: .event).map { calendar in
            CalendarInfo(id: calendar.calendarIdentifier, title: calendar.title, source: calendar.source?.title ?? "",
                         color: Self.hex(calendar.color), allowsWriting: calendar.allowsContentModifications)
        }
    }

    public func events(from: Date, to: Date, calendarIDs: [String]) -> [CalendarEvent] {
        let calendars = store.calendars(for: .event).filter { calendarIDs.contains($0.calendarIdentifier) }
        guard !calendars.isEmpty else { return [] }
        let predicate = store.predicateForEvents(withStart: from, end: to, calendars: calendars)
        return store.events(matching: predicate).map(Self.event(from:))
    }

    public func event(id: String) -> CalendarEvent? {
        store.event(withIdentifier: id).map(Self.event(from:))
    }

    public func createEvent(title: String, start: Date, end: Date, calendarID: String, notes: String) throws -> String {
        guard let calendar = store.calendar(withIdentifier: calendarID) else { throw CalendarError.noCalendar }
        let event = EKEvent(eventStore: store)
        event.title = title
        event.startDate = start
        event.endDate = end
        event.notes = notes
        event.calendar = calendar
        try store.save(event, span: .thisEvent, commit: true)
        return event.eventIdentifier ?? ""
    }

    public func updateEvent(id: String, start: Date, end: Date) throws {
        guard let event = store.event(withIdentifier: id) else { throw ScheduleError.notFound }
        event.startDate = start
        event.endDate = end
        try store.save(event, span: .thisEvent, commit: true)
    }

    public func deleteEvent(id: String) throws {
        guard let event = store.event(withIdentifier: id) else { return }
        try store.remove(event, span: .thisEvent, commit: true)
    }

    public func observeChanges(_ handler: @escaping @Sendable () -> Void) -> TriggerToken {
        let observer = NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store, queue: nil) { _ in handler() }
        return TriggerToken { NotificationCenter.default.removeObserver(observer) }
    }

    private static func event(from event: EKEvent) -> CalendarEvent {
        CalendarEvent(id: event.eventIdentifier ?? UUID().uuidString, calendarID: event.calendar?.calendarIdentifier ?? "",
                      title: event.title ?? "Untitled", start: event.startDate, end: event.endDate, isAllDay: event.isAllDay,
                      notes: event.notes ?? "")
    }

    private static func hex(_ color: NSColor?) -> String {
        guard let rgb = color?.usingColorSpace(.sRGB) else { return "#8E8E93" }
        return String(format: "#%02X%02X%02X", Int(rgb.redComponent * 255), Int(rgb.greenComponent * 255), Int(rgb.blueComponent * 255))
    }
}
#endif
