import AtlasCore
import Foundation

/// A parsed Orbit search, e.g. `ext:pdf modified:<30d size:>10mb neural`.
///
/// - `ext:pdf,png` extensions
/// - `type:image` (document, code, image, video, audio, archive, app, folder)
/// - `size:>10mb`, `size:<1gb` (b, kb, mb, gb, tb; Finder's 1000-based units)
/// - `modified:<30d` (changed in the last 30 days), `modified:>1y` (longer
///   ago), `modified:>2026-01-01` (after a date); units h, d, w, mo, y.
///   `created:` works the same, and `opened:>6mo` finds files not opened in
///   six months.
/// - `in:Downloads` a folder's name or path
/// - `name:"exact phrase"`; any other words match names, fuzzily
public struct SearchQuery: Equatable, Sendable {
    public enum Comparison: String, Sendable { case less = "<", greater = ">", lessOrEqual = "<=", greaterOrEqual = ">=", equal = "=" }

    /// A date condition: relative age, or an absolute date.
    public enum DateFilter: Equatable, Sendable {
        /// `<30d` = within the last 30 days; `>30d` = more than 30 days ago.
        case age(Comparison, seconds: TimeInterval, text: String)
        /// `>2026-01-01` = after; `<…` = before; `=` that day.
        case date(Comparison, Date, text: String)
    }

    public var terms: [String] = []
    public var extensions: [String] = []
    public var categories: [FileCategory] = []
    public var minSize: Int64?
    public var maxSize: Int64?
    public var modified: DateFilter?
    public var created: DateFilter?
    public var opened: DateFilter?
    public var folders: [String] = []
    /// Words that looked like filters but weren't understood.
    public var problems: [String] = []

    public init() {}

    public var isEmpty: Bool {
        terms.isEmpty && extensions.isEmpty && categories.isEmpty && minSize == nil && maxSize == nil
            && modified == nil && created == nil && opened == nil && folders.isEmpty
    }

    // MARK: Parsing

    public static func parse(_ text: String) -> SearchQuery {
        var query = SearchQuery()
        for token in tokenize(text) {
            guard let colon = token.firstIndex(of: ":"), colon != token.startIndex else {
                query.terms.append(token)
                continue
            }
            let key = token[..<colon].lowercased()
            let value = String(token[token.index(after: colon)...]).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            guard !value.isEmpty else { query.problems.append("“\(token)” needs a value after the colon."); continue }
            switch key {
            case "ext", "extension":
                query.extensions += value.lowercased().split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ".", with: "") }.filter { !$0.isEmpty }
            case "type", "kind":
                for part in value.lowercased().split(separator: ",") {
                    if let category = category(named: String(part)) { query.categories.append(category) }
                    else { query.problems.append("“\(part)” isn't a type. Try image, document, code, video, audio, archive, app or folder.") }
                }
            case "size":
                guard let (comparison, bytes) = parseSize(value) else {
                    query.problems.append("“\(value)” isn't a size. Try size:>10mb.")
                    continue
                }
                switch comparison {
                case .greater, .greaterOrEqual: query.minSize = bytes
                case .less, .lessOrEqual: query.maxSize = bytes
                case .equal: query.minSize = bytes; query.maxSize = bytes
                }
            case "modified", "changed", "created", "opened", "used":
                guard let filter = parseDate(value) else {
                    query.problems.append("“\(value)” isn't a date or age. Try \(key):<30d or \(key):>2026-01-01.")
                    continue
                }
                switch key {
                case "created": query.created = filter
                case "opened", "used": query.opened = filter
                default: query.modified = filter
                }
            case "in", "folder", "where":
                query.folders.append(value)
            case "name":
                query.terms.append(value)
            default:
                // "c:\stuff" or "10:30" in a name: treat as a plain word.
                query.terms.append(token)
            }
        }
        return query
    }

    /// Splits on spaces, keeping "quoted phrases" (and key:"quoted values") together.
    static func tokenize(_ text: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var quoted = false
        for character in text {
            if character == "\"" {
                quoted.toggle()
                continue
            }
            if character.isWhitespace && !quoted {
                if !current.isEmpty { tokens.append(current) }
                current = ""
            } else {
                current.append(character)
            }
        }
        if !current.isEmpty { tokens.append(current) }
        return tokens
    }

    static func category(named name: String) -> FileCategory? {
        switch name.lowercased() {
        case "doc", "docs", "document", "documents", "text": return .document
        case "code", "source": return .code
        case "image", "images", "photo", "photos", "picture", "pictures": return .image
        case "video", "videos", "movie", "movies": return .video
        case "audio", "music", "sound": return .audio
        case "archive", "archives", "installer", "installers", "zip": return .archive
        case "app", "apps", "application", "applications": return .app
        case "folder", "folders", "directory": return .folder
        case "other": return .other
        default: return FileCategory(rawValue: name.lowercased())
        }
    }

    static func splitComparison(_ value: String) -> (Comparison, String) {
        for comparison in [Comparison.lessOrEqual, .greaterOrEqual, .less, .greater, .equal] where value.hasPrefix(comparison.rawValue) {
            return (comparison, String(value.dropFirst(comparison.rawValue.count)))
        }
        return (.equal, value)
    }

    /// ">10mb" → (greater, 10_000_000). Plain numbers are bytes.
    static func parseSize(_ value: String) -> (Comparison, Int64)? {
        var (comparison, rest) = splitComparison(value.lowercased().replacingOccurrences(of: " ", with: ""))
        if comparison == .equal && !value.hasPrefix("=") { comparison = .greater }
        let units: [(String, Double)] = [("tb", 1e12), ("gb", 1e9), ("mb", 1e6), ("kb", 1e3), ("t", 1e12), ("g", 1e9), ("m", 1e6), ("k", 1e3), ("b", 1)]
        var multiplier: Double = 1
        for (suffix, factor) in units where rest.hasSuffix(suffix) {
            multiplier = factor
            rest = String(rest.dropLast(suffix.count))
            break
        }
        guard let number = Double(rest), number >= 0 else { return nil }
        return (comparison, Int64(number * multiplier))
    }

    /// "<30d", ">6mo", ">2026-01-01", "2026-03-05".
    static func parseDate(_ value: String) -> DateFilter? {
        let (comparison, rest) = splitComparison(value.lowercased())
        let units: [(String, TimeInterval)] = [("mo", 30 * 86_400), ("y", 365 * 86_400), ("w", 7 * 86_400), ("d", 86_400),
                                               ("h", 3_600), ("m", 30 * 86_400)]
        for (suffix, seconds) in units where rest.hasSuffix(suffix) {
            if let number = Double(rest.dropLast(suffix.count)), number >= 0 {
                return .age(comparison == .equal ? .less : comparison, seconds: number * seconds, text: value.lowercased())
            }
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        if let date = formatter.date(from: rest) { return .date(comparison, date, text: value.lowercased()) }
        return nil
    }

    // MARK: Writing back

    /// The canonical text for this query, e.g. after a natural-language translation.
    public var text: String {
        var parts: [String] = []
        if !extensions.isEmpty { parts.append("ext:" + extensions.joined(separator: ",")) }
        if !categories.isEmpty { parts.append("type:" + categories.map(\.rawValue).joined(separator: ",")) }
        if let minSize { parts.append("size:>" + Self.sizeText(minSize)) }
        if let maxSize { parts.append("size:<" + Self.sizeText(maxSize)) }
        func dateText(_ key: String, _ filter: DateFilter?) {
            switch filter {
            case .age(_, _, let text)?, .date(_, _, let text)?: parts.append("\(key):\(text)")
            case nil: break
            }
        }
        dateText("modified", modified)
        dateText("created", created)
        dateText("opened", opened)
        parts += folders.map { $0.contains(" ") ? "in:\"\($0)\"" : "in:\($0)" }
        parts += terms.map { $0.contains(" ") ? "\"\($0)\"" : $0 }
        return parts.joined(separator: " ")
    }

    static func sizeText(_ bytes: Int64) -> String {
        if bytes >= 1_000_000_000, bytes % 1_000_000_000 == 0 { return "\(bytes / 1_000_000_000)gb" }
        if bytes >= 1_000_000, bytes % 1_000_000 == 0 { return "\(bytes / 1_000_000)mb" }
        if bytes >= 1_000, bytes % 1_000 == 0 { return "\(bytes / 1_000)kb" }
        return "\(bytes)b"
    }

    // MARK: To an index query

    /// Applies the date filters to a FileQuery, relative to `now`.
    func apply(to query: inout FileQuery, now: Date) {
        func range(_ filter: DateFilter?) -> (after: Date?, before: Date?) {
            switch filter {
            case .age(let comparison, let seconds, _)?:
                let cutoff = now.addingTimeInterval(-seconds)
                switch comparison {
                case .less, .lessOrEqual, .equal: return (cutoff, nil)        // newer than
                case .greater, .greaterOrEqual: return (nil, cutoff)          // older than
                }
            case .date(let comparison, let date, _)?:
                let nextDay = date.addingTimeInterval(86_400)
                switch comparison {
                case .greater: return (nextDay, nil)
                case .greaterOrEqual: return (date, nil)
                case .less: return (nil, date)
                case .lessOrEqual: return (nil, nextDay)
                case .equal: return (date, nextDay)
                }
            case nil:
                return (nil, nil)
            }
        }
        let m = range(modified), c = range(created), o = range(opened)
        query.modifiedAfter = m.after
        query.modifiedBefore = m.before
        query.createdAfter = c.after
        query.createdBefore = c.before
        query.openedBefore = o.before
        query.extensions = extensions
        query.categories = categories
        query.minSize = minSize
        query.maxSize = maxSize
    }
}

/// Ranks names against search words: exact, then prefix, then word starts,
/// then anywhere, then letters in order with gaps.
public enum FuzzyMatcher {
    /// Nil when some term doesn't match at all.
    public static func score(_ name: String, terms: [String]) -> Double? {
        guard !terms.isEmpty else { return 0 }
        let lower = name.lowercased()
        let stem = (lower as NSString).deletingPathExtension
        var total = 0.0
        for term in terms {
            let t = term.lowercased()
            if stem == t || lower == t { total += 100 }
            else if lower.hasPrefix(t) { total += 80 }
            else if lower.range(of: "(^|[^a-z0-9])" + NSRegularExpression.escapedPattern(for: t), options: .regularExpression) != nil { total += 65 }
            else if lower.contains(t) { total += 50 }
            else if let gaps = subsequenceGaps(t, in: lower) { total += max(5, 35 - Double(gaps) * 2) }
            else { return nil }
        }
        // Shorter names are a closer match for the same words.
        return total - Double(lower.count) * 0.05
    }

    /// How many skipped characters it takes to find `needle`'s letters in order.
    static func subsequenceGaps(_ needle: String, in haystack: String) -> Int? {
        var gaps = 0
        var started = false
        var iterator = haystack.makeIterator()
        for character in needle {
            var found = false
            while let next = iterator.next() {
                if next == character { found = true; break }
                if started { gaps += 1 }
            }
            guard found else { return nil }
            started = true
        }
        return gaps
    }
}
