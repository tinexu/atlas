import Foundation

/// A global keyboard shortcut such as "cmd+shift+k".
public struct HotKey: Hashable, Sendable {
    public enum Modifier: String, CaseIterable, Sendable {
        case command, shift, option, control
        public var symbol: String {
            switch self {
            case .command: return "⌘"
            case .shift: return "⇧"
            case .option: return "⌥"
            case .control: return "⌃"
            }
        }
    }

    public struct ParseError: Error, Equatable, Sendable {
        public let message: String
    }

    /// Carbon virtual key code.
    public let keyCode: UInt32
    public let key: String
    public let modifiers: Set<Modifier>

    /// "⌃⌥⌘K"
    public var display: String {
        let order: [Modifier] = [.control, .option, .shift, .command]
        return order.filter(modifiers.contains).map(\.symbol).joined() + key.uppercased()
    }

    public static func parse(_ text: String) -> Result<HotKey, ParseError> {
        let parts = text.lowercased()
            .replacingOccurrences(of: " ", with: "")
            .split(separator: "+")
            .map(String.init)
        guard !parts.isEmpty else { return .failure(ParseError(message: "Type a shortcut such as cmd+shift+k.")) }
        var modifiers = Set<Modifier>()
        var key: String?
        for part in parts {
            switch part {
            case "cmd", "command", "⌘": modifiers.insert(.command)
            case "shift", "⇧": modifiers.insert(.shift)
            case "opt", "option", "alt", "⌥": modifiers.insert(.option)
            case "ctrl", "control", "⌃": modifiers.insert(.control)
            default:
                guard key == nil else { return .failure(ParseError(message: "“\(text)” has more than one key. Use one key plus modifiers.")) }
                key = part
            }
        }
        guard let key else { return .failure(ParseError(message: "“\(text)” needs a key as well as modifiers, e.g. cmd+shift+k.")) }
        guard let code = keyCodes[key] else { return .failure(ParseError(message: "“\(key)” isn't a key ATLAS can use in a shortcut.")) }
        guard !modifiers.isDisjoint(with: [.command, .control, .option]) else {
            return .failure(ParseError(message: "Shortcuts need ⌘, ⌃ or ⌥ so they don't get in the way of typing."))
        }
        return .success(HotKey(keyCode: code, key: key, modifiers: modifiers))
    }

    static let keyCodes: [String: UInt32] = {
        var codes: [String: UInt32] = [
            "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12,
            "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23,
            "=": 24, "9": 25, "7": 26, "minus": 27, "8": 28, "0": 29, "]": 30, "o": 31, "u": 32, "[": 33,
            "i": 34, "p": 35, "return": 36, "enter": 36, "l": 37, "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42,
            ",": 43, "/": 44, "n": 45, "m": 46, ".": 47, "tab": 48, "space": 49, "`": 50, "delete": 51,
            "escape": 53, "esc": 53, "left": 123, "right": 124, "down": 125, "up": 126,
        ]
        let functionKeys: [UInt32] = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111]
        for (index, code) in functionKeys.enumerated() { codes["f\(index + 1)"] = code }
        return codes
    }()
}

/// When a "Time reached" trigger fires.
public struct TimeSchedule: Hashable, Sendable {
    public enum Repeat: String, Sendable { case daily, weekly, once }

    public let repeats: Repeat
    public let time: TimeOfDay?
    /// 1 = Sunday … 7 = Saturday.
    public let weekdays: [Int]
    public let date: DateComponents?
    public let runIfMissed: Bool

    public init(parameters: ActionParameters) {
        repeats = Repeat(rawValue: parameters["repeat"]?.stringValue ?? "daily") ?? .daily
        time = TimeOfDay(parameters["time"]?.stringValue ?? "09:00")
        let names = ["sun", "mon", "tue", "wed", "thu", "fri", "sat"]
        weekdays = (parameters["days"]?.stringValue ?? "")
            .lowercased()
            .split(whereSeparator: { $0 == "," || $0 == " " })
            .compactMap { part in names.firstIndex { part.hasPrefix($0) }.map { $0 + 1 } }
        if let text = parameters["date"]?.stringValue, !text.isEmpty {
            let parts = text.split(separator: "-").compactMap { Int($0) }
            date = parts.count == 3 ? DateComponents(year: parts[0], month: parts[1], day: parts[2]) : nil
        } else {
            date = nil
        }
        runIfMissed = (parameters["ifMissed"]?.stringValue ?? "runOnWake") != "skip"
    }

    public var validationError: String? {
        if time == nil { return "The time must look like 09:30 (24-hour)." }
        if repeats == .weekly && weekdays.isEmpty { return "Weekly schedules need days, e.g. mon, wed, fri." }
        if repeats == .once && date == nil { return "One-time schedules need a date like 2026-12-24." }
        return nil
    }

    /// The first time strictly after `date`, or nil if there is none (a
    /// one-time schedule in the past).
    public func nextFireDate(after date: Date, calendar: Calendar = .current) -> Date? {
        guard let time else { return nil }
        switch repeats {
        case .once:
            guard var components = self.date else { return nil }
            components.hour = time.hour
            components.minute = time.minute
            guard let fire = calendar.date(from: components), fire > date else { return nil }
            return fire
        case .daily, .weekly:
            var components = DateComponents(hour: time.hour, minute: time.minute, second: 0)
            if repeats == .daily {
                return calendar.nextDate(after: date, matching: components, matchingPolicy: .nextTime)
            }
            return weekdays.compactMap { weekday -> Date? in
                components.weekday = weekday
                return calendar.nextDate(after: date, matching: components, matchingPolicy: .nextTime)
            }.min()
        }
    }
}
