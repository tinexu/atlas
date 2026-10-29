import Foundation

/// A course code such as CHEM101: 2–5 letters and 3–4 digits, written
/// any of the usual ways ("CHEM 101", "Chem-101", "chem_101", "CS180A").
public struct CourseCode: Hashable, Comparable, Sendable, CustomStringConvertible {
    public let subject: String
    public let number: String

    public init(subject: String, number: String) {
        self.subject = subject.uppercased()
        self.number = number.uppercased()
    }

    /// "CHEM101": how codes are stored and compared.
    public var canonical: String { subject + number }
    /// "CHEM 101": how codes are shown.
    public var display: String { "\(subject) \(number)" }
    public var description: String { canonical }

    public static func < (a: CourseCode, b: CourseCode) -> Bool { a.canonical < b.canonical }

    /// Words that look like a subject but aren't: rooms, buildings, pages,
    /// terms, times. "ROOM 101" or "FALL 2026" never become courses.
    static let notSubjects: Set<String> = [
        "ROOM", "RM", "BLDG", "HALL", "SUITE", "STE", "FLOOR", "FL", "UNIT", "APT", "LEVEL", "WING", "GATE", "DOOR",
        "PAGE", "PAGES", "PG", "PP", "CH", "CHAP", "VOL", "NO", "NUM", "NR", "ISSUE", "ITEM", "LINE", "ROW", "SEAT",
        "FALL", "SPRING", "SUMMER", "WINTER", "TERM", "YEAR", "WEEK", "DAY", "SEM",
        "SEC", "SECT", "LEC", "SECTION", "GROUP", "TEAM", "ZOOM", "TEL", "PHONE", "EXT", "FAX", "BOX", "PO", "ZIP",
        "ID", "PIN", "CODE", "REF", "ORDER", "INV", "BUS", "ROUTE", "HWY", "EXIT", "AM", "PM", "UTC", "GMT", "PST", "EST",
        "MAC", "IOS", "WIN", "COVID", "MP", "MK", "GEN", "VER", "RTX", "GTX", "IPHONE", "IPAD",
    ]

    private static let pattern = try! NSRegularExpression(
        pattern: #"(?<![A-Za-z0-9])([A-Za-z]{2,5})[ \t\-_.]?(\d{3,4})([A-Za-z]?)(?![A-Za-z0-9])"#
    )

    /// Every course code in `text`, in order, without repeats.
    public static func find(in text: String) -> [CourseCode] {
        let range = NSRange(text.startIndex..., in: text)
        var seen = Set<CourseCode>()
        var codes: [CourseCode] = []
        for match in pattern.matches(in: text, range: range) {
            guard let subject = Range(match.range(at: 1), in: text).map({ String(text[$0]) }),
                  let digits = Range(match.range(at: 2), in: text).map({ String(text[$0]) }),
                  let suffix = Range(match.range(at: 3), in: text).map({ String(text[$0]) })
            else { continue }
            guard !notSubjects.contains(subject.uppercased()) else { continue }
            // A bare four-digit year after a word ("Spring 2026", "Report 2024") isn't a course.
            if digits.count == 4, let year = Int(digits), (1900...2099).contains(year), suffix.isEmpty, subject.count > 4 { continue }
            let code = CourseCode(subject: subject, number: digits + suffix)
            if seen.insert(code).inserted { codes.append(code) }
        }
        return codes
    }

    /// Parses a single code typed on its own, e.g. in the course editor.
    public static func parse(_ text: String) -> CourseCode? {
        let codes = find(in: text.trimmingCharacters(in: .whitespacesAndNewlines))
        return codes.count == 1 ? codes[0] : nil
    }
}
