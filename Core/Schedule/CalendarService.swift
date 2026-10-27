import CryptoKit
import Foundation

/// A calendar the Mac knows about (iCloud, Google, Outlook… whatever is
/// added to macOS Calendar).
public struct CalendarInfo: Identifiable, Hashable, Sendable {
    public let id: String
    public let title: String
    public let source: String
    /// "#RRGGBB"
    public let color: String
    public let allowsWriting: Bool

    public init(id: String, title: String, source: String, color: String = "#8E8E93", allowsWriting: Bool = true) {
        self.id = id
        self.title = title
        self.source = source
        self.color = color
        self.allowsWriting = allowsWriting
    }
}

public struct CalendarEvent: Identifiable, Hashable, Sendable {
    public let id: String
    public let calendarID: String
    public var title: String
    public var start: Date
    public var end: Date
    public var isAllDay: Bool
    public var notes: String

    public init(id: String, calendarID: String, title: String, start: Date, end: Date, isAllDay: Bool = false, notes: String = "") {
        self.id = id
        self.calendarID = calendarID
        self.title = title
        self.start = start
        self.end = end
        self.isAllDay = isAllDay
        self.notes = notes
    }
}

public enum CalendarAccess: String, Sendable {
    case notDetermined, granted, denied, restricted
}

/// EventKit, or a mock in tests.
public protocol CalendarStore: Sendable {
    func access() -> CalendarAccess
    func requestAccess() async -> CalendarAccess
    func calendars() -> [CalendarInfo]
    func events(from: Date, to: Date, calendarIDs: [String]) -> [CalendarEvent]
    func event(id: String) -> CalendarEvent?
    func createEvent(title: String, start: Date, end: Date, calendarID: String, notes: String) throws -> String
    func updateEvent(id: String, start: Date, end: Date) throws
    func deleteEvent(id: String) throws
    /// EKEventStoreChanged: something changed outside ATLAS.
    func observeChanges(_ handler: @escaping @Sendable () -> Void) -> TriggerToken
}

/// Which calendars ATLAS reads, and which it may write to.
public struct CalendarSettings: Codable, Equatable, Sendable {
    public var enabled = false
    public var visibleCalendarIDs: [String] = []
    /// Writing is off unless a calendar is listed here.
    public var writableCalendarIDs: [String] = []
    /// Calendars whose first write the person already confirmed.
    public var confirmedCalendarIDs: [String] = []
    public var defaultWriteCalendarID: String?

    public init() {}
}

/// Links between calendar events and ATLAS, and the log of what ATLAS wrote.
public struct CalendarLink: Identifiable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable {
        /// Events whose title contains some text → suggest a Space.
        case rule
        /// One event → a Space.
        case event
        /// An event ATLAS created (undo removes it).
        case write
    }

    public var id: UUID
    public var kind: Kind
    public var calendarID: String?
    public var eventID: String?
    public var titleContains: String?
    public var spaceID: UUID?
    public var profileID: UUID?
    public var minutesBefore: Int
    public var blockID: UUID?
    public var note: String
    public var createdAt: Date
    public var undoneAt: Date?

    public init(id: UUID = UUID(), kind: Kind, calendarID: String? = nil, eventID: String? = nil, titleContains: String? = nil,
                spaceID: UUID? = nil, profileID: UUID? = nil, minutesBefore: Int = 15, blockID: UUID? = nil, note: String = "",
                createdAt: Date = Date(), undoneAt: Date? = nil) {
        self.id = id
        self.kind = kind
        self.calendarID = calendarID
        self.eventID = eventID
        self.titleContains = titleContains
        self.spaceID = spaceID
        self.profileID = profileID
        self.minutesBefore = minutesBefore
        self.blockID = blockID
        self.note = note
        self.createdAt = createdAt
        self.undoneAt = undoneAt
    }

    /// Whether a rule or event link applies to an event.
    public func matches(_ event: CalendarEvent) -> Bool {
        switch kind {
        case .rule:
            guard let text = titleContains?.trimmingCharacters(in: .whitespaces), !text.isEmpty else { return false }
            return event.title.localizedCaseInsensitiveContains(text) && (calendarID == nil || calendarID == event.calendarID)
        case .event: return eventID == event.id
        case .write: return false
        }
    }
}

public enum CalendarError: Error, LocalizedError, Equatable {
    case off
    case noAccess
    case readOnly(String)
    /// The first write to a calendar needs a yes.
    case needsConfirmation(String)
    case noCalendar

    public var errorDescription: String? {
        switch self {
        case .off: return "Calendar integration is off. Turn it on in Time Architect → Calendar."
        case .noAccess: return "ATLAS doesn't have access to your calendars. Allow it on the Permissions screen or in System Settings."
        case .readOnly(let name): return "ATLAS can only read “\(name)”. Allow writing to it in Time Architect → Calendar first."
        case .needsConfirmation(let name): return "Confirm that ATLAS may add events to “\(name)”."
        case .noCalendar: return "Choose a calendar to write to."
        }
    }
}

/// Reads your calendars into the timeline (read-only by default), applies
/// link rules, publishes `calendar.event.approaching`, and follows changes
/// made outside ATLAS. Writes only to calendars you allowed, confirms the
/// first write to each, logs every write and can undo it.
public final class CalendarService: @unchecked Sendable {
    public static let settingsKey = "calendar.settings"
    public static let standardLeads = [5, 10, 15]

    let calendarStore: CalendarStore
    let store: AtlasStore
    let events: EventBus
    let environment: TriggerEnvironment
    weak var schedule: ScheduleService?
    private let lock = NSLock()
    private var timer: TriggerToken?
    private var changeToken: TriggerToken?
    private var fired = Set<String>()

    init(calendarStore: CalendarStore, store: AtlasStore, events: EventBus, environment: TriggerEnvironment) {
        self.calendarStore = calendarStore
        self.store = store
        self.events = events
        self.environment = environment
    }

    func start() {
        changeToken = calendarStore.observeChanges { [weak self] in self?.externalChange() }
        process()
    }

    public var settings: CalendarSettings {
        get { (try? store.preference(Self.settingsKey, as: CalendarSettings.self)) ?? CalendarSettings() }
        set {
            try? store.setPreference(newValue, for: Self.settingsKey)
            events.publish(AtlasEvent(AtlasEvent.Name.calendarChanged, payload: ["reason": "settings"]))
            events.publish(AtlasEvent(AtlasEvent.Name.scheduleChanged))
            process()
        }
    }

    public var access: CalendarAccess { calendarStore.access() }

    /// Turns integration on, asking macOS for access only now.
    @discardableResult
    public func enable() async -> CalendarAccess {
        var access = calendarStore.access()
        if access == .notDetermined { access = await calendarStore.requestAccess() }
        var next = settings
        next.enabled = access == .granted
        if next.enabled, next.visibleCalendarIDs.isEmpty { next.visibleCalendarIDs = calendarStore.calendars().map(\.id) }
        settings = next
        return access
    }

    public func disable() {
        var next = settings
        next.enabled = false
        settings = next
    }

    public var isReadable: Bool { settings.enabled && calendarStore.access() == .granted }

    public func calendars() -> [CalendarInfo] {
        calendarStore.access() == .granted ? calendarStore.calendars() : []
    }

    /// Events from the visible calendars.
    public func events(in range: DateInterval) -> [CalendarEvent] {
        guard isReadable else { return [] }
        let visible = settings.visibleCalendarIDs
        guard !visible.isEmpty else { return [] }
        return calendarStore.events(from: range.start, to: range.end, calendarIDs: visible).filter { !$0.isAllDay }
    }

    /// Events as read-only timeline blocks. ATLAS's own written events are
    /// left out: their ATLAS block already shows.
    public func blocks(in range: DateInterval) -> [ScheduleBlock] {
        let written = Set(((try? store.calendarLinks(kind: .write)) ?? []).filter { $0.undoneAt == nil }.compactMap(\.eventID))
        let links = (try? store.calendarLinks()) ?? []
        return events(in: range).filter { !written.contains($0.id) }.map { event in
            let space = links.first { $0.matches(event) }?.spaceID
            return ScheduleBlock(id: Self.blockID(for: event), title: event.title, start: event.start, end: event.end,
                                 kind: .appointment, spaceID: space, source: .calendar, externalEventID: event.id, calendarID: event.calendarID)
        }
    }

    /// A stable block ID for an event.
    public static func blockID(for event: CalendarEvent) -> UUID {
        var bytes = Array(SHA256.hash(data: Data("calendar:\(event.id)".utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    // MARK: - Links

    public func links() -> [CalendarLink] { (try? store.calendarLinks()) ?? [] }

    public func saveLink(_ link: CalendarLink) throws {
        try store.saveCalendarLink(link)
        events.publish(AtlasEvent(AtlasEvent.Name.calendarChanged, payload: ["reason": "links"]))
        process()
    }

    public func deleteLink(_ id: UUID) throws {
        try store.deleteCalendarLink(id: id)
        events.publish(AtlasEvent(AtlasEvent.Name.calendarChanged, payload: ["reason": "links"]))
    }

    /// The Space linked to an event, by an event link or a title rule.
    public func linkedSpace(for event: CalendarEvent) -> CalendarLink? {
        let links = links()
        return links.first { $0.kind == .event && $0.matches(event) } ?? links.first { $0.kind == .rule && $0.matches(event) }
    }

    // MARK: - Writing

    /// Creates a calendar event for an ATLAS block. Throws `.needsConfirmation`
    /// the first time for a calendar unless `confirmed` is true.
    @discardableResult
    public func write(_ block: ScheduleBlock, to calendarID: String? = nil, confirmed: Bool) throws -> CalendarLink {
        guard settings.enabled else { throw CalendarError.off }
        guard calendarStore.access() == .granted else { throw CalendarError.noAccess }
        guard let calendarID = calendarID ?? settings.defaultWriteCalendarID ?? settings.writableCalendarIDs.first else { throw CalendarError.noCalendar }
        let name = calendarStore.calendars().first { $0.id == calendarID }?.title ?? "that calendar"
        guard settings.writableCalendarIDs.contains(calendarID) else { throw CalendarError.readOnly(name) }
        if !settings.confirmedCalendarIDs.contains(calendarID) {
            guard confirmed else { throw CalendarError.needsConfirmation(name) }
            var next = settings
            next.confirmedCalendarIDs.append(calendarID)
            try? store.setPreference(next, for: Self.settingsKey)
        }
        let eventID = try calendarStore.createEvent(title: block.title, start: block.start, end: block.end, calendarID: calendarID,
                                                    notes: "Added by ATLAS from Time Architect.")
        let link = CalendarLink(kind: .write, calendarID: calendarID, eventID: eventID, blockID: block.id,
                                note: "Added “\(block.title)” to \(name)", createdAt: environment.now())
        try store.saveCalendarLink(link)
        if var saved = try store.block(id: block.id) {
            saved.externalEventID = eventID
            saved.calendarID = calendarID
            try store.saveBlock(saved)
        }
        events.publish(AtlasEvent(AtlasEvent.Name.calendarChanged, payload: ["reason": "write", "eventId": .string(eventID)]))
        return link
    }

    /// Removes an event ATLAS created and marks the write undone.
    public func undo(_ link: CalendarLink) throws {
        guard link.kind == .write, link.undoneAt == nil, let eventID = link.eventID else { return }
        try calendarStore.deleteEvent(id: eventID)
        var undone = link
        undone.undoneAt = environment.now()
        try store.saveCalendarLink(undone)
        if let blockID = link.blockID, var block = try store.block(id: blockID), block.externalEventID == eventID {
            block.externalEventID = nil
            block.calendarID = nil
            try store.saveBlock(block)
        }
        events.publish(AtlasEvent(AtlasEvent.Name.calendarChanged, payload: ["reason": "undo"]))
    }

    /// Moves an event on the timeline, only on a writable calendar.
    public func move(eventID: String, start: Date, end: Date, confirmed: Bool) throws {
        guard let event = calendarStore.event(id: eventID) else { throw ScheduleError.notFound }
        let name = calendarStore.calendars().first { $0.id == event.calendarID }?.title ?? "that calendar"
        guard settings.writableCalendarIDs.contains(event.calendarID) else { throw CalendarError.readOnly(name) }
        if !settings.confirmedCalendarIDs.contains(event.calendarID) {
            guard confirmed else { throw CalendarError.needsConfirmation(name) }
            var next = settings
            next.confirmedCalendarIDs.append(event.calendarID)
            try? store.setPreference(next, for: Self.settingsKey)
        }
        try calendarStore.updateEvent(id: eventID, start: start, end: end)
        try store.saveCalendarLink(CalendarLink(kind: .write, calendarID: event.calendarID, eventID: eventID,
                                                note: "Moved “\(event.title)” to \(start.formatted(date: .abbreviated, time: .shortened))",
                                                createdAt: environment.now(), undoneAt: environment.now()))
        events.publish(AtlasEvent(AtlasEvent.Name.calendarChanged, payload: ["reason": "move"]))
        events.publish(AtlasEvent(AtlasEvent.Name.scheduleChanged))
    }

    /// Every write ATLAS made, newest first.
    public func writeLog() -> [CalendarLink] {
        ((try? store.calendarLinks(kind: .write)) ?? [])
    }

    // MARK: - Changes outside ATLAS

    /// A linked event moved: its block follows. Deleted: the link is removed
    /// and the block stays (it's yours), noted as unlinked.
    public func externalChange() {
        guard calendarStore.access() == .granted else { return }
        for block in (try? store.blocks()) ?? [] {
            guard let eventID = block.externalEventID else { continue }
            if let event = calendarStore.event(id: eventID) {
                if abs(event.start.timeIntervalSince(block.start)) > 1 || abs(event.end.timeIntervalSince(block.end)) > 1 || event.title != block.title {
                    var moved = block
                    moved.start = event.start
                    moved.end = event.end
                    moved.title = event.title
                    persist(moved)
                }
            } else {
                var unlinked = block
                unlinked.externalEventID = nil
                unlinked.calendarID = nil
                unlinked.notes = (block.notes.isEmpty ? "" : block.notes + "\n") + "Its calendar event was deleted outside ATLAS."
                persist(unlinked)
            }
        }
        for link in ((try? store.calendarLinks(kind: .event)) ?? []) {
            if let eventID = link.eventID, calendarStore.event(id: eventID) == nil { try? store.deleteCalendarLink(id: link.id) }
        }
        events.publish(AtlasEvent(AtlasEvent.Name.calendarChanged, payload: ["reason": "external"]))
        events.publish(AtlasEvent(AtlasEvent.Name.scheduleChanged))
        process()
    }

    private func persist(_ block: ScheduleBlock) {
        if let schedule { _ = try? schedule.save(block) } else { try? store.saveBlock(block) }
    }

    // MARK: - Approaching events

    /// Publishes `calendar.event.approaching` at each lead time.
    public func process() {
        timer?.cancel()
        guard isReadable else { return }
        let now = environment.now()
        let upcoming = events(in: DateInterval(start: now, end: now.addingTimeInterval(24 * 3_600)))
        let leads = leadMinutes()
        var next: Date?
        for event in upcoming where event.start > now {
            for lead in leads {
                let at = event.start.addingTimeInterval(-Double(lead) * 60)
                let key = "\(event.id)|\(Int(event.start.timeIntervalSince1970))|\(lead)"
                if at <= now {
                    if now.timeIntervalSince(at) < 120, lock.withLock({ fired.insert(key).inserted }) {
                        let calendarName = calendarStore.calendars().first { $0.id == event.calendarID }?.title ?? ""
                        var payload: ActionParameters = [
                            "eventId": .string(event.id), "title": .string(event.title), "calendar": .string(calendarName),
                            "calendarId": .string(event.calendarID), "start": .number(event.start.timeIntervalSince1970),
                            "end": .number(event.end.timeIntervalSince1970), "minutesBefore": .number(Double(lead)),
                        ]
                        if let link = linkedSpace(for: event), let space = link.spaceID {
                            payload["linkedSpaceId"] = .string(space.uuidString)
                            payload["linkMinutes"] = .number(Double(link.minutesBefore))
                        }
                        events.publish(AtlasEvent(AtlasEvent.Name.calendarEventApproaching, payload: payload))
                    }
                } else if at < (next ?? .distantFuture) {
                    next = at
                }
            }
        }
        let refresh = now.addingTimeInterval(3 * 3_600)
        timer = environment.schedule(at: min(next ?? refresh, refresh)) { [weak self] in self?.process() }
    }

    func leadMinutes() -> Set<Int> {
        var leads = Set(Self.standardLeads)
        for link in links() where link.kind != .write { leads.insert(link.minutesBefore) }
        for workflow in (try? store.workflows()) ?? [] where workflow.isEnabled {
            for node in workflow.steps where node.kind == .trigger && node.config.triggerType == TriggerCatalog.calendarEventApproaching {
                if let minutes = node.parameters["minutesBefore"]?.numberValue, minutes > 0 { leads.insert(Int(minutes)) }
            }
        }
        return leads
    }
}

/// When calendar integration is unavailable (tests, no EventKit).
public struct UnavailableCalendarStore: CalendarStore {
    public init() {}
    public func access() -> CalendarAccess { .denied }
    public func requestAccess() async -> CalendarAccess { .denied }
    public func calendars() -> [CalendarInfo] { [] }
    public func events(from: Date, to: Date, calendarIDs: [String]) -> [CalendarEvent] { [] }
    public func event(id: String) -> CalendarEvent? { nil }
    public func createEvent(title: String, start: Date, end: Date, calendarID: String, notes: String) throws -> String { throw CalendarError.noAccess }
    public func updateEvent(id: String, start: Date, end: Date) throws { throw CalendarError.noAccess }
    public func deleteEvent(id: String) throws { throw CalendarError.noAccess }
    public func observeChanges(_ handler: @escaping @Sendable () -> Void) -> TriggerToken { TriggerToken {} }
}
