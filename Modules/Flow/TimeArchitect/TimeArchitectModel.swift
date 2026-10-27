import AppKit
import AtlasCore
import AtlasSpaces
import Combine
import SwiftUI

/// UI state for Time Architect. Everything it changes goes through
/// `ScheduleService`, `FocusService` and `CalendarService`.
@MainActor
public final class TimeArchitectModel: ObservableObject {
    public enum Mode: String, CaseIterable, Identifiable {
        case ribbon, day, week, agenda
        public var id: Self { self }
        public var title: String {
            switch self {
            case .ribbon: return "3D Timeline"
            case .day: return "Day"
            case .week: return "Week"
            case .agenda: return "Agenda"
            }
        }
        public var symbol: String {
            switch self {
            case .ribbon: return "cube.transparent"
            case .day: return "calendar.day.timeline.left"
            case .week: return "calendar"
            case .agenda: return "list.bullet.rectangle"
            }
        }
    }

    public enum Lanes: String, CaseIterable, Identifiable {
        case none, space, project
        public var id: Self { self }
        public var title: String {
            switch self {
            case .none: return "No lanes"
            case .space: return "Lanes by Space"
            case .project: return "Lanes by Project"
            }
        }
    }

    public struct SpaceItem: Identifiable, Hashable {
        public let id: UUID
        public let name: String
        public let color: String
        public let profiles: [(id: UUID, name: String)]
        public static func == (a: SpaceItem, b: SpaceItem) -> Bool { a.id == b.id && a.name == b.name && a.color == b.color }
        public func hash(into hasher: inout Hasher) { hasher.combine(id) }
    }

    @Published public var mode: Mode = .day
    @Published public var anchor = Calendar.current.startOfDay(for: Date())
    @Published public var lanes: Lanes = .none
    @Published public var selectedID: String?
    @Published public private(set) var occurrences: [Occurrence] = []
    @Published public private(set) var conflicts: [ScheduleConflict] = []
    @Published public private(set) var spaces: [SpaceItem] = []
    @Published public private(set) var projects: [(id: UUID, name: String)] = []
    @Published public private(set) var focus: FocusSession?
    @Published public var message: String?
    /// A calendar write waiting for "Allow" (first write to a calendar).
    @Published public var pendingWrite: (block: ScheduleBlock, calendarName: String)?
    @Published public var showCalendarSettings = false
    @Published public var showFocusSettings = false
    @Published public private(set) var revision = 0

    public let core: AtlasCore
    public let time: TimeServices
    public var calendar = Calendar.current
    private var eventTask: Task<Void, Never>?
    private var tick: Timer?

    public init(core: AtlasCore, time: TimeServices) {
        self.core = core
        self.time = time
        reload()
        listen()
        // The "now" line and countdowns move once a minute.
        tick = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.revision += 1 }
        }
        tick?.tolerance = 5
    }

    private func listen() {
        let stream = core.events.stream()
        eventTask = Task { [weak self] in
            for await event in stream {
                guard let self else { return }
                if event.name.hasPrefix("schedule.") || event.name.hasPrefix("focus.") || event.name.hasPrefix("calendar.")
                    || event.name == AtlasEvent.Name.workflowFinished || event.name == AtlasEvent.Name.spaceActivatedEvent {
                    self.reload()
                }
            }
        }
    }

    // MARK: - Range

    /// What the current mode shows: the day, the week, or (3D/agenda) a week from the day.
    public var range: DateInterval {
        switch mode {
        case .day:
            return DateInterval(start: anchor, end: calendar.date(byAdding: .day, value: 1, to: anchor)!)
        case .week:
            let start = calendar.dateInterval(of: .weekOfYear, for: anchor)?.start ?? anchor
            return DateInterval(start: start, end: calendar.date(byAdding: .day, value: 7, to: start)!)
        case .ribbon, .agenda:
            return DateInterval(start: anchor, end: calendar.date(byAdding: .day, value: 7, to: anchor)!)
        }
    }

    public var days: [Date] {
        var days: [Date] = []
        var day = calendar.startOfDay(for: range.start)
        while day < range.end {
            days.append(day)
            day = calendar.date(byAdding: .day, value: 1, to: day)!
        }
        return days
    }

    public func step(_ direction: Int) {
        let unit: Calendar.Component = mode == .day ? .day : .weekOfYear
        anchor = calendar.date(byAdding: unit, value: direction, to: anchor) ?? anchor
        reload()
    }

    public func goToToday() {
        anchor = calendar.startOfDay(for: Date())
        reload()
    }

    public func reload() {
        let range = self.range
        occurrences = time.schedule.occurrences(in: range)
        conflicts = ScheduleConflict.find(in: occurrences.filter { $0.block.kind != .breakTime })
        spaces = ((try? core.store.spaces()) ?? []).map { space in
            SpaceItem(id: space.id, name: space.name, color: space.accentColor,
                      profiles: ((try? core.store.profiles(spaceID: space.id)) ?? []).map { ($0.id, $0.name) })
        }
        projects = ((try? core.store.projects()) ?? []).map { ($0.id, $0.name) }
        focus = time.focus.session
        revision += 1
    }

    // MARK: - Lookup

    public var selected: Occurrence? { occurrences.first { $0.id == selectedID } }

    public func occurrences(on day: Date) -> [Occurrence] {
        let end = calendar.date(byAdding: .day, value: 1, to: day)!
        return occurrences.filter { $0.start < end && $0.end > day }
    }

    public func isConflicted(_ occurrence: Occurrence) -> Bool {
        conflicts.contains { $0.first.id == occurrence.id || $0.second.id == occurrence.id }
    }

    public func space(_ id: UUID?) -> SpaceItem? { spaces.first { $0.id == id } }

    public func color(for block: ScheduleBlock) -> Color {
        if let hex = block.color ?? space(block.spaceID)?.color, let color = Color(timeHex: hex) { return color }
        if block.isExternal { return .gray }
        switch block.kind {
        case .focus: return .indigo
        case .task: return .teal
        case .appointment: return .orange
        case .breakTime: return .green
        }
    }

    /// Lane name for grouping.
    public func lane(for block: ScheduleBlock) -> String {
        switch lanes {
        case .none: return ""
        case .space: return space(block.spaceID)?.name ?? (block.isExternal ? "Calendar" : "No Space")
        case .project: return projects.first { $0.id == block.projectID }?.name ?? "No Project"
        }
    }

    public var laneNames: [String] {
        guard lanes != .none else { return [""] }
        return Array(Set(occurrences.map { lane(for: $0.block) })).sorted()
    }

    /// "Scheduled 2:00 · Activated Coding Lab 2:00 · 4 of 4 steps"
    public func status(of occurrence: Occurrence) -> (scheduled: String, state: BlockOccurrence.State, runs: [String]) {
        let state = time.schedule.state(of: occurrence)
        let runs = time.schedule.runs(for: occurrence).map { run -> String in
            let actions = run.steps.filter { $0.kind == .action }
            let done = actions.filter { $0.state == .succeeded }.count
            let what = run.steps.first { $0.actionID == "space.activate" }.flatMap { $0.inputs["space"]?.stringValue }.map { "Activated \($0)" }
                ?? run.workflowName.replacingOccurrences(of: "Schedule: ", with: "")
            return "\(what) \(run.startedAt.formatted(date: .omitted, time: .shortened)) · \(run.state == .succeeded ? "\(done) of \(actions.count) steps" : run.state.rawValue)"
        }
        return ("Scheduled \(occurrence.start.formatted(date: .omitted, time: .shortened))", state.state, runs)
    }

    // MARK: - Editing

    @discardableResult
    public func create(title: String = "Focus", at start: Date, minutes: Double = 60, spaceID: UUID? = nil, kind: ScheduleBlock.Kind = .focus) -> ScheduleBlock? {
        let rounded = Self.snap(start)
        var block = ScheduleBlock(title: spaceID.flatMap { space($0)?.name } ?? title, start: rounded,
                                  end: rounded.addingTimeInterval(minutes * 60), kind: kind, spaceID: spaceID,
                                  startBehavior: spaceID == nil ? .nothing : .ask)
        if let spaceID, let profile = space(spaceID)?.profiles.first { block.profileID = profile.id }
        return perform { try time.schedule.save(block) }.map { saved in
            selectedID = Occurrence(block: saved, start: saved.start, end: saved.end).id
            return saved
        }
    }

    public func save(_ block: ScheduleBlock) {
        _ = perform { try time.schedule.save(block) }
    }

    /// Moves or resizes the block behind an occurrence (all its repeats keep
    /// the same time of day). Calendar events move only on writable calendars.
    public func move(_ occurrence: Occurrence, minutes: Double, resize: Bool = false) {
        let seconds = minutes * 60
        if occurrence.block.isExternal {
            guard let eventID = occurrence.block.externalEventID else { return }
            let start = resize ? occurrence.start : occurrence.start.addingTimeInterval(seconds)
            let end = occurrence.end.addingTimeInterval(seconds)
            do {
                try time.calendar.move(eventID: eventID, start: start, end: max(end, start.addingTimeInterval(300)), confirmed: false)
            } catch CalendarError.needsConfirmation(let name) {
                message = "Moving events in “\(name)” changes your calendar. Write the first change from the inspector to confirm."
            } catch {
                message = error.localizedDescription
            }
            reload()
            return
        }
        guard let updated = perform({ try time.schedule.move(occurrence.block.id, by: seconds, resizeOnly: resize) }) else { return }
        let offset = occurrence.start.timeIntervalSince(occurrence.block.start)
        let newStart = resize ? occurrence.start : updated.start.addingTimeInterval(offset)
        selectedID = Occurrence(block: updated, start: newStart, end: newStart.addingTimeInterval(updated.duration)).id
        reload()
    }

    public func delete(_ occurrence: Occurrence) {
        guard !occurrence.block.isExternal else { return }
        _ = perform { try time.schedule.delete(occurrence.block.id) }
        selectedID = nil
    }

    public func skip(_ occurrence: Occurrence) {
        _ = perform { try time.schedule.skip(occurrence) }
    }

    public func fix(_ conflict: ScheduleConflict) {
        let (occurrence, newStart) = conflict.movable
        move(occurrence, minutes: newStart.timeIntervalSince(occurrence.start) / 60)
    }

    /// Adds a block to the calendar, asking first the first time per calendar.
    public func writeToCalendar(_ block: ScheduleBlock, confirmed: Bool = false) {
        do {
            try time.calendar.write(block, confirmed: confirmed)
            message = "Added “\(block.title)” to your calendar. Undo it in Calendar settings."
        } catch CalendarError.needsConfirmation(let name) {
            pendingWrite = (block, name)
        } catch {
            message = error.localizedDescription
        }
        reload()
    }

    // MARK: - Focus

    public func startFocus(minutes: Double? = nil, spaceID: UUID? = nil, title: String? = nil, blockID: UUID? = nil) {
        time.focus.start(minutes: minutes, title: title, spaceID: spaceID, blockID: blockID)
        reload()
    }

    public func pauseFocus() { time.focus.pause(); reload() }
    public func resumeFocus() { time.focus.resume(); reload() }
    public func extendFocus(_ minutes: Double) { time.focus.extend(minutes: minutes); reload() }
    public func stopFocus() { time.focus.stop(); reload() }

    // MARK: - Helpers

    /// 15-minute grid.
    public static func snap(_ date: Date) -> Date {
        let seconds = date.timeIntervalSinceReferenceDate
        return Date(timeIntervalSinceReferenceDate: (seconds / 900).rounded() * 900)
    }

    private func perform<T>(_ body: () throws -> T) -> T? {
        do {
            let value = try body()
            reload()
            return value
        } catch {
            message = error.localizedDescription
            return nil
        }
    }
}

extension Color {
    /// "#RRGGBB"
    public init?(timeHex hex: String) {
        var text = hex.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("#") { text.removeFirst() }
        guard text.count == 6, let value = UInt32(text, radix: 16) else { return nil }
        self.init(.sRGB, red: Double((value >> 16) & 0xFF) / 255, green: Double((value >> 8) & 0xFF) / 255, blue: Double(value & 0xFF) / 255)
    }
}

extension TimeInterval {
    /// "1:05:09" or "24:13"
    public var countdown: String {
        let total = Int(self.rounded())
        let h = total / 3_600, m = (total % 3_600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}
