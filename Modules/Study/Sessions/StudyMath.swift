import Foundation

/// A study day runs from the boundary hour (default 4 AM) to the next, so
/// studying past midnight still counts for the evening it started.
public struct StudyDay: Equatable, Sendable {
    public var boundaryHour: Int
    public var calendar: Calendar

    public init(boundaryHour: Int = 4, calendar: Calendar = .current) {
        self.boundaryHour = max(0, min(23, boundaryHour))
        self.calendar = calendar
    }

    /// When the study day containing `date` began.
    public func start(of date: Date) -> Date {
        let shifted = date.addingTimeInterval(-Double(boundaryHour) * 3600)
        let midnight = calendar.startOfDay(for: shifted)
        return calendar.date(byAdding: .hour, value: boundaryHour, to: midnight) ?? midnight
    }

    public func next(after start: Date) -> Date {
        calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)
    }

    public func previous(before start: Date) -> Date {
        calendar.date(byAdding: .day, value: -1, to: start) ?? start.addingTimeInterval(-86_400)
    }
}

/// The candle, streak and summary arithmetic, kept pure for tests.
public enum StudyMath {
    /// A day counts towards the streak with at least this much study (by default).
    public static let streakMinimum: TimeInterval = 30 * 60

    /// How far today's candle has burned (0…1) and whether the goal is met.
    public static func candle(studied: TimeInterval, goal: TimeInterval) -> (burned: Double, goalReached: Bool) {
        guard goal > 0 else { return (studied > 0 ? 1 : 0, studied > 0) }
        return (min(1, max(0, studied / goal)), studied >= goal)
    }

    /// Consecutive study days with at least `streakMinimum`, ending today,
    /// or yesterday when today hasn't got there yet (the streak isn't lost
    /// until the day is over). `totals` is seconds by study-day start.
    public static func streak(totals: [Date: TimeInterval], now: Date, day: StudyDay, minimum: TimeInterval = streakMinimum) -> Int {
        var start = day.start(of: now)
        if (totals[start] ?? 0) < minimum { start = day.previous(before: start) }
        var count = 0
        while (totals[start] ?? 0) >= minimum {
            count += 1
            start = day.previous(before: start)
        }
        return count
    }

    /// "1 h 40 m", "25 m".
    public static func duration(_ seconds: TimeInterval) -> String {
        let minutes = Int((seconds / 60).rounded())
        let hours = minutes / 60, rest = minutes % 60
        if hours == 0 { return "\(minutes) m" }
        return rest == 0 ? "\(hours) h" : "\(hours) h \(rest) m"
    }
}
