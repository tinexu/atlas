import Foundation

/// A day (for creating) runs from the boundary hour (default
/// 4 AM) to the next, so working past midnight still counts for the
/// evening it started.
public struct DayBoundary: Equatable, Sendable {
    public var boundaryHour: Int
    public var calendar: Calendar

    public init(boundaryHour: Int = 4, calendar: Calendar = .current) {
        self.boundaryHour = max(0, min(23, boundaryHour))
        self.calendar = calendar
    }

    /// When the day containing `date` began.
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

/// Streaks of days with enough time in them (the Creative Studio).
public enum Streaks {
    /// Consecutive days with at least `minimum`, ending today, or yesterday
    /// when today hasn't got there yet (the streak isn't lost until the day
    /// is over). `totals` is seconds by day start.
    public static func count(totals: [Date: TimeInterval], now: Date, day: DayBoundary, minimum: TimeInterval) -> Int {
        var start = day.start(of: now)
        if (totals[start] ?? 0) < minimum { start = day.previous(before: start) }
        var count = 0
        while (totals[start] ?? 0) >= minimum {
            count += 1
            start = day.previous(before: start)
        }
        return count
    }
}
