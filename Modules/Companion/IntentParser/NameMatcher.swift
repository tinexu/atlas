import Foundation

/// Scores how well typed words name something ("coding room" → "Coding Lab",
/// "morning setp" → "Morning Setup"). Tolerates typos, word order, filler
/// words and plurals. Scores run 0…1; below `threshold` isn't a match.
public enum NameMatcher {
    public static let threshold = 0.5
    /// Two candidates closer than this are ambiguous.
    public static let ambiguityMargin = 0.08

    /// Words that carry no meaning in a name.
    static let filler: Set<String> = [
        "my", "the", "a", "an", "please", "for", "to", "me", "our", "your", "this", "that", "of", "on", "in", "up",
        "now", "can", "you", "could", "would", "i", "want", "some", "all",
    ]

    public static func words(_ text: String) -> [String] {
        text.lowercased()
            .replacingOccurrences(of: "’", with: "'")
            .components(separatedBy: CharacterSet.alphanumerics.inverted.subtracting(CharacterSet(charactersIn: "'")))
            .map { $0.replacingOccurrences(of: "'s", with: "").replacingOccurrences(of: "'", with: "") }
            .filter { !$0.isEmpty }
    }

    /// Meaningful words: filler removed.
    public static func keywords(_ text: String, ignoring extra: Set<String> = []) -> [String] {
        words(text).filter { !filler.contains($0) && !extra.contains($0) }
    }

    public static func score(query: String, name: String, ignoring extra: Set<String> = []) -> Double {
        let q = keywords(query, ignoring: extra)
        let n = keywords(name)
        guard !q.isEmpty, !n.isEmpty else { return 0 }
        let joinedQ = q.joined(separator: " "), joinedN = n.joined(separator: " ")
        if joinedQ == joinedN { return 1 }

        // Each query word against its best name word.
        var queryHits = 0.0
        var usedName = Set<Int>()
        for word in q {
            var best = 0.0, bestIndex = -1
            for (index, candidate) in n.enumerated() {
                let s = wordScore(word, candidate)
                if s > best { best = s; bestIndex = index }
            }
            queryHits += best
            if best >= 0.6, bestIndex >= 0 { usedName.insert(bestIndex) }
        }
        let queryCoverage = queryHits / Double(q.count)
        let nameCoverage = Double(usedName.count) / Double(n.count)
        var score = queryCoverage * 0.72 + nameCoverage * 0.28
        // Typed as one squashed word or a prefix of the whole name ("morningset").
        let squashedQ = q.joined(), squashedN = n.joined()
        if squashedQ.count >= 4, squashedN.hasPrefix(squashedQ) { score = max(score, 0.75 + 0.2 * Double(squashedQ.count) / Double(squashedN.count)) }
        return min(score, 0.99)
    }

    /// 1 for the same word, less for plurals, prefixes and typos.
    static func wordScore(_ a: String, _ b: String) -> Double {
        if a == b { return 1 }
        let sa = stem(a), sb = stem(b)
        if sa == sb { return 0.95 }
        if a.count >= 3, b.hasPrefix(a) { return 0.85 }
        if b.count >= 4, a.hasPrefix(b) { return 0.8 }
        let distance = min(levenshtein(a, b), levenshtein(sa, sb))
        let longest = max(a.count, b.count)
        if longest >= 4, distance == 1 { return 0.8 }
        if longest >= 7, distance == 2 { return 0.65 }
        return 0
    }

    /// Crude English stemming: enough for plurals and -ing/-ed/-ation forms.
    static func stem(_ word: String) -> String {
        for suffix in ["ications", "ication", "ations", "ation", "ings", "ing", "ies", "es", "ed", "s"] {
            if word.count > suffix.count + 2, word.hasSuffix(suffix) {
                let base = String(word.dropLast(suffix.count))
                return suffix == "ies" ? base + "y" : base
            }
        }
        return word
    }

    static func levenshtein(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var beforePrevious = [Int](repeating: 0, count: b.count + 1)
        var previous = Array(0...b.count)
        for i in 1...a.count {
            var current = [i] + Array(repeating: 0, count: b.count)
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
                // Adjacent swap ("teh") counts as one edit.
                if i > 1, j > 1, a[i - 1] == b[j - 2], a[i - 2] == b[j - 1] {
                    current[j] = min(current[j], beforePrevious[j - 2] + 1)
                }
            }
            beforePrevious = previous
            previous = current
        }
        return previous[b.count]
    }

    public struct Match<T> {
        public let item: T
        public let score: Double
    }

    /// Best matches above the threshold, best first.
    public static func rank<T>(_ query: String, in items: [T], name: (T) -> String, ignoring extra: Set<String> = []) -> [Match<T>] {
        items.map { Match(item: $0, score: score(query: query, name: name($0), ignoring: extra)) }
            .filter { $0.score >= threshold }
            .sorted { $0.score > $1.score }
    }
}
