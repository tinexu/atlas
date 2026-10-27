import Foundation

/// A parsed iCalendar RRULE (the subset ATLAS supports).
public struct RRule: Hashable, Sendable {
    public enum Frequency: String, Sendable { case daily = "DAILY", weekly = "WEEKLY", monthly = "MONTHLY" }

    public var frequency: Frequency
    public var interval: Int
    /// 1 = Sunday … 7 = Saturday.
    public var byDay: [Int]
    public var count: Int?
    public var until: Date?

    static let dayCodes = ["SU": 1, "MO": 2, "TU": 3, "WE": 4, "TH": 5, "FR": 6, "SA": 7]

    /// "FREQ=WEEKLY;INTERVAL=2;BYDAY=MO,WE" (an "RRULE:" prefix is fine).
    public init?(_ text: String) {
        var body = text.trimmingCharacters(in: .whitespaces)
        if body.uppercased().hasPrefix("RRULE:") { body = String(body.dropFirst(6)) }
        var parts: [String: String] = [:]
        for pair in body.split(separator: ";") {
            let kv = pair.split(separator: "=", maxSplits: 1).map { String($0).uppercased().trimmingCharacters(in: .whitespaces) }
            guard kv.count == 2 else { return nil }
            parts[kv[0]] = kv[1]
        }
        guard let freq = parts["FREQ"].flatMap(Frequency.init(rawValue:)) else { return nil }
        frequency = freq
        interval = max(1, Int(parts["INTERVAL"] ?? "1") ?? 1)
        byDay = (parts["BYDAY"] ?? "").split(separator: ",").compactMap { Self.dayCodes[String($0.suffix(2))] }
        count = parts["COUNT"].flatMap(Int.init)
        if let raw = parts["UNTIL"] {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(identifier: "UTC")
            formatter.dateFormat = raw.count > 8 ? "yyyyMMdd'T'HHmmss'Z'" : "yyyyMMdd"
            guard let date = formatter.date(from: raw) else { return nil }
            // A date-only UNTIL includes that whole day.
            until = raw.count > 8 ? date : date.addingTimeInterval(86_399)
        }
    }

    public var summary: String {
        let unit: String
        switch frequency {
        case .daily: unit = interval == 1 ? "Every day" : "Every \(interval) days"
        case .weekly: unit = interval == 1 ? "Every week" : "Every \(interval) weeks"
        case .monthly: unit = interval == 1 ? "Every month" : "Every \(interval) months"
        }
        let names = Calendar(identifier: .gregorian).shortWeekdaySymbols
        let days = byDay.isEmpty ? "" : " on " + byDay.map { names[$0 - 1] }.joined(separator: ", ")
        let limit = count.map { ", \($0) times" } ?? until.map { ", until \($0.formatted(date: .abbreviated, time: .omitted))" } ?? ""
        return unit + days + limit
    }
}

public enum RecurrenceError: Error, LocalizedError, Equatable {
    case invalidRule(String)
    public var errorDescription: String? {
        switch self {
        case .invalidRule(let rule): return "“\(rule)” isn't a repeat rule ATLAS understands. Try FREQ=WEEKLY;BYDAY=MO,WE,FR."
        }
    }
}

/// Expands repeating blocks into occurrences.
///
/// Repeats keep the local wall-clock start ("9:00 every weekday") in the
/// calendar's time zone, so a daylight-saving change doesn't shift them an
/// hour; the length in seconds stays the same.
public enum RecurrenceExpander {
    public static func validate(_ recurrence: Recurrence) throws {
        if case .custom(let rule) = recurrence, RRule(rule) == nil { throw RecurrenceError.invalidRule(rule) }
    }

    public static func occurrences(of block: ScheduleBlock, in range: DateInterval, calendar: Calendar = .current,
                                   limit: Int = 2_000) -> [Occurrence] {
        let duration = block.duration
        guard block.recurrence.isRepeating else {
            let single = Occurrence(block: block, start: block.start, end: block.end)
            return single.start < range.end && single.end > range.start ? [single] : []
        }
        let rule: RRule?
        switch block.recurrence {
        case .custom(let text):
            guard let parsed = RRule(text) else { return [] }
            rule = parsed
        default:
            rule = nil
        }
        let time = calendar.dateComponents([.hour, .minute, .second], from: block.start)
        let firstDay = calendar.startOfDay(for: block.start)
        // With COUNT every occurrence from the first one counts, so walk from the start.
        var day = rule?.count != nil ? firstDay : max(firstDay, calendar.startOfDay(for: range.start.addingTimeInterval(-duration)))
        let lastDay = calendar.startOfDay(for: range.end)
        var results: [Occurrence] = []
        var counted = 0
        var steps = 0
        while day <= lastDay, results.count < limit, steps < 20_000 {
            steps += 1
            defer { day = calendar.date(byAdding: .day, value: 1, to: day) ?? day.addingTimeInterval(86_400) }
            guard matches(day: day, block: block, rule: rule, firstDay: firstDay, calendar: calendar) else { continue }
            guard let start = calendar.date(bySettingHour: time.hour ?? 0, minute: time.minute ?? 0, second: time.second ?? 0, of: day),
                  start >= block.start
            else { continue }
            if let until = rule?.until, start > until { break }
            counted += 1
            if let count = rule?.count, counted > count { break }
            let occurrence = Occurrence(block: block, start: start, end: start.addingTimeInterval(duration))
            if occurrence.end > range.start, occurrence.start < range.end { results.append(occurrence) }
        }
        return results
    }

    static func matches(day: Date, block: ScheduleBlock, rule: RRule?, firstDay: Date, calendar: Calendar) -> Bool {
        let weekday = calendar.component(.weekday, from: day)
        switch block.recurrence {
        case .none: return day == firstDay
        case .daily: return true
        case .weekdays: return (2...6).contains(weekday)
        case .weekly: return weekday == calendar.component(.weekday, from: block.start)
        case .custom:
            guard let rule else { return false }
            switch rule.frequency {
            case .daily:
                let days = calendar.dateComponents([.day], from: firstDay, to: day).day ?? 0
                return days % rule.interval == 0 && (rule.byDay.isEmpty || rule.byDay.contains(weekday))
            case .weekly:
                let days = rule.byDay.isEmpty ? [calendar.component(.weekday, from: block.start)] : rule.byDay
                guard days.contains(weekday) else { return false }
                let startWeek = calendar.dateInterval(of: .weekOfYear, for: firstDay)?.start ?? firstDay
                let thisWeek = calendar.dateInterval(of: .weekOfYear, for: day)?.start ?? day
                let weeks = (calendar.dateComponents([.day], from: startWeek, to: thisWeek).day ?? 0) / 7
                return weeks % rule.interval == 0
            case .monthly:
                guard calendar.component(.day, from: day) == calendar.component(.day, from: firstDay) else { return false }
                let months = calendar.dateComponents([.month], from: firstDay, to: day).month ?? 0
                return months % rule.interval == 0
            }
        }
    }

    /// Every occurrence of every block in the range, sorted.
    public static func occurrences(of blocks: [ScheduleBlock], in range: DateInterval, calendar: Calendar = .current) -> [Occurrence] {
        blocks.flatMap { occurrences(of: $0, in: range, calendar: calendar) }.sorted { $0.start < $1.start }
    }
}
