import AtlasCore
import Foundation

/// A class you're taking. Everything in the Study Library hangs off it:
/// its book on the shelf, assignments, sessions and automations.
public struct Course: Identifiable, Hashable, Codable, Sendable {
    /// Where the course's notes live.
    public enum Notes: Codable, Hashable, Sendable {
        /// Not on this Mac (e.g. Notability on an iPad); `remark` says where.
        case none(remark: String?)
        case folder(path: String)
        /// A note or folder inside an Obsidian vault.
        case obsidian(vaultPath: String, relativePath: String)
        case app(bundleID: String, name: String)
        case url(String)

        public var title: String {
            switch self {
            case .none(let remark): return remark.map { "Not on this Mac (\($0))" } ?? "None"
            case .folder(let path): return (path as NSString).lastPathComponent
            case .obsidian(let vault, let relative): return "Obsidian · \((vault as NSString).lastPathComponent)/\(relative)"
            case .app(_, let name): return name
            case .url(let url): return URL(string: url)?.host ?? url
            }
        }

        /// A local path ATLAS can watch for "notes updated", if any.
        public var watchedPath: String? {
            switch self {
            case .folder(let path): return path
            case .obsidian(let vault, let relative): return (vault as NSString).appendingPathComponent(relative)
            case .none, .app, .url: return nil
            }
        }
    }

    public struct Link: Codable, Hashable, Sendable, Identifiable {
        public enum Kind: String, Codable, CaseIterable, Sendable {
            case site, syllabus, research, other
            public var title: String {
                switch self {
                case .site: return "Course site"
                case .syllabus: return "Syllabus"
                case .research: return "Research"
                case .other: return "Link"
                }
            }
        }
        public var id: UUID
        public var kind: Kind
        public var title: String
        public var url: String

        public init(id: UUID = UUID(), kind: Kind = .site, title: String = "", url: String) {
            self.id = id
            self.kind = kind
            self.title = title
            self.url = url
        }
    }

    /// What clicking the course's book opens.
    public struct Opens: Codable, Hashable, Sendable {
        public var folder = true
        public var notes = true
        public var site = true
        public init() {}
    }

    public var id: UUID
    public var position: Int
    public var name: String
    /// Canonical, e.g. "CHEM101".
    public var code: String
    /// Other codes for the same class (cross-listings), canonical.
    public var aliases: [String]
    /// Spine colour, sRGB hex.
    public var color: String
    public var folderPath: String?
    public var folderBookmark: Data?
    public var notes: Notes
    public var links: [Link]
    /// Extra words that mark a calendar event as this class.
    public var matchTerms: [String]
    public var opens: Opens
    public var term: String
    public var isArchived: Bool
    public var createdAt: Date

    public init(id: UUID = UUID(), position: Int = 0, name: String, code: String, aliases: [String] = [], color: String,
                folderPath: String? = nil, folderBookmark: Data? = nil, notes: Notes = .none(remark: nil), links: [Link] = [],
                matchTerms: [String] = [], opens: Opens = Opens(), term: String = "", isArchived: Bool = false,
                createdAt: Date = Date()) {
        self.id = id
        self.position = position
        self.name = name
        self.code = CourseCode.parse(code)?.canonical ?? code.uppercased().replacingOccurrences(of: " ", with: "")
        self.aliases = aliases
        self.color = color
        self.folderPath = folderPath
        self.folderBookmark = folderBookmark
        self.notes = notes
        self.links = links
        self.matchTerms = matchTerms
        self.opens = opens
        self.term = term
        self.isArchived = isArchived
        self.createdAt = createdAt
    }

    public var courseCode: CourseCode? { CourseCode.parse(code) }
    public var displayCode: String { courseCode?.display ?? code }
    public var site: Link? { links.first { $0.kind == .site } }

    /// Whether `text` (an event title, a file name) is about this course:
    /// its code or an alias in any spelling, its name, or a match term.
    public func matches(_ text: String) -> Bool {
        let codes = Set(CourseCode.find(in: text).map(\.canonical))
        if codes.contains(code) || aliases.contains(where: codes.contains) { return true }
        let lowered = text.lowercased()
        if name.count >= 4, lowered.contains(name.lowercased()) { return true }
        return matchTerms.contains { !$0.isEmpty && lowered.contains($0.lowercased()) }
    }
}

/// Course colours: the Study Library's book-spine palette, each course a
/// different one while there are enough.
public enum CourseColors {
    public static let palette = ["#34466B", "#7D3B45", "#6F8A6E", "#C99A9A", "#E8D9BF", "#3F5A4A"]
    public static let names = ["Navy", "Burgundy", "Deep sage", "Dusty rose", "Parchment", "Forest"]

    /// The first palette colour no active course uses (cycling when all are taken).
    public static func next(after courses: [Course]) -> String {
        let used = courses.filter { !$0.isArchived }.map(\.color)
        return palette.first { !used.contains($0) } ?? palette[used.count % palette.count]
    }
}

/// "Fall 2026" for a date: Spring Jan–May, Summer Jun–Jul, Fall Aug–Dec.
public enum AcademicTerm {
    public static func name(for date: Date, calendar: Calendar = .current) -> String {
        let month = calendar.component(.month, from: date), year = calendar.component(.year, from: date)
        switch month {
        case 1...5: return "Spring \(year)"
        case 6...7: return "Summer \(year)"
        default: return "Fall \(year)"
        }
    }
}
