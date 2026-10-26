import AtlasCore
import Foundation

/// Optional search inside files, through Spotlight's existing index and
/// scoped to Orbit folders. ATLAS keeps no content index of its own.
@MainActor
public final class SpotlightSearch {
    private var query: NSMetadataQuery?
    private var observer: NSObjectProtocol?

    public init() {}

    /// Paths of files in `roots` whose text contains `text`.
    public func search(_ text: String, in roots: [String], limit: Int = 200, timeout: TimeInterval = 10) async -> [String] {
        cancel()
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !roots.isEmpty else { return [] }
        let query = NSMetadataQuery()
        query.searchScopes = roots.map { URL(fileURLWithPath: $0, isDirectory: true) }
        query.predicate = NSPredicate(format: "kMDItemTextContent CONTAINS[cd] %@", trimmed)
        self.query = query
        return await withCheckedContinuation { continuation in
            var finished = false
            let finish: @MainActor () -> Void = { [weak self] in
                guard !finished else { return }
                finished = true
                query.disableUpdates()
                var paths: [String] = []
                for index in 0..<min(query.resultCount, limit) {
                    if let item = query.result(at: index) as? NSMetadataItem,
                       let path = item.value(forAttribute: NSMetadataItemPathKey) as? String {
                        paths.append(path)
                    }
                }
                query.stop()
                self?.cleanUp()
                continuation.resume(returning: paths)
            }
            observer = NotificationCenter.default.addObserver(forName: .NSMetadataQueryDidFinishGathering, object: query, queue: .main) { _ in
                MainActor.assumeIsolated { finish() }
            }
            if !query.start() { finish(); return }
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { MainActor.assumeIsolated { finish() } }
        }
    }

    public func cancel() {
        query?.stop()
        cleanUp()
    }

    private func cleanUp() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        query = nil
    }
}

/// Optional, off by default: turns a plain sentence into the query syntax,
/// on the device, with fixed rules (no AI service). The translation is
/// always shown before it runs, so it can be corrected.
public enum NaturalLanguageQuery {
    public static func translate(_ sentence: String, folderNames: [String] = [], now: Date = Date()) -> SearchQuery {
        var query = SearchQuery()
        let words = sentence.lowercased()
            .replacingOccurrences(of: "[^a-z0-9.\\- ]", with: " ", options: .regularExpression)
            .split(separator: " ").map(String.init)
        var index = 0
        var nameWords: [String] = []

        func next(_ offset: Int = 1) -> String? { words.indices.contains(index + offset) ? words[index + offset] : nil }
        /// "than 10 mb" / "10mb" after position `i`: the size and how many words it used.
        func sizeAfter(_ i: Int) -> (bytes: Int64, used: Int)? {
            var j = i + 1
            if words.indices.contains(j), words[j] == "than" { j += 1 }
            guard words.indices.contains(j) else { return nil }
            var text = words[j]
            if words.indices.contains(j + 1), ["mb", "gb", "kb", "tb"].contains(words[j + 1]) { text += words[j + 1]; j += 1 }
            guard text.contains(where: \.isLetter), let (_, bytes) = SearchQuery.parseSize(">" + text) else { return nil }
            return (bytes, j - i)
        }
        func unitSeconds(_ word: String?) -> (String, TimeInterval)? {
            switch word?.trimmingCharacters(in: CharacterSet(charactersIn: "s")) {
            case "day": return ("d", 86_400)
            case "week": return ("w", 7 * 86_400)
            case "month": return ("mo", 30 * 86_400)
            case "year": return ("y", 365 * 86_400)
            default: return nil
            }
        }

        let stopWords: Set<String> = ["the", "a", "an", "about", "my", "with", "called", "named", "file", "files", "find", "show", "me",
                                      "that", "which", "is", "are", "of", "for", "on", "all", "any", "some", "i", "got", "get",
                                      "downloaded", "saved", "where", "what", "to", "and", "or", "it", "was", "were", "had", "have"]
        let typeWords: [String: FileCategory] = [
            "image": .image, "images": .image, "photo": .image, "photos": .image, "picture": .image, "pictures": .image,
            "video": .video, "videos": .video, "movie": .video, "movies": .video, "song": .audio, "songs": .audio,
            "audio": .audio, "music": .audio, "document": .document, "documents": .document, "doc": .document, "docs": .document,
            "app": .app, "apps": .app, "code": .code, "archive": .archive, "archives": .archive, "folder": .folder, "folders": .folder,
        ]
        let extensionWords: [String: [String]] = [
            "pdf": ["pdf"], "pdfs": ["pdf"], "installer": ["dmg", "pkg"], "installers": ["dmg", "pkg"], "dmg": ["dmg"],
            "zip": ["zip"], "zips": ["zip"], "spreadsheet": ["xlsx", "numbers", "csv"], "spreadsheets": ["xlsx", "numbers", "csv"],
            "presentation": ["key", "pptx"], "slides": ["key", "pptx"], "word": ["docx", "doc"], "screenshot": [], "screenshots": [],
        ]

        while index < words.count {
            let word = words[index]
            if word == "screenshot" || word == "screenshots" {
                nameWords.append("screenshot")
            } else if let exts = extensionWords[word] {
                query.extensions += exts
            } else if let category = typeWords[word] {
                query.categories.append(category)
            } else if word == "today" {
                query.modified = .age(.less, seconds: 86_400, text: "<1d")
            } else if word == "yesterday" {
                query.modified = .age(.less, seconds: 2 * 86_400, text: "<2d")
            } else if (word == "last" || word == "this" || word == "past"), let (unit, seconds) = unitSeconds(next()) {
                query.modified = .age(.less, seconds: seconds, text: "<1\(unit)")
                index += 1
            } else if (word == "last" || word == "past"), let count = next().flatMap(Double.init), let (unit, seconds) = unitSeconds(next(2)) {
                query.modified = .age(.less, seconds: count * seconds, text: "<\(Int(count))\(unit)")
                index += 2
            } else if word == "older", next() == "than", let count = next(2).flatMap(Double.init), let (unit, seconds) = unitSeconds(next(3)) {
                query.modified = .age(.greater, seconds: count * seconds, text: ">\(Int(count))\(unit)")
                index += 3
            } else if word == "not", next() == "opened", next(2) == "in" || next(2) == "for",
                      let count = next(3).flatMap(Double.init), let (unit, seconds) = unitSeconds(next(4)) {
                query.opened = .age(.greater, seconds: count * seconds, text: ">\(Int(count))\(unit)")
                index += 4
            } else if word == "big" || word == "large" || word == "larger" || word == "bigger" {
                if let size = sizeAfter(index) { query.minSize = size.bytes; index += size.used } else { query.minSize = 100_000_000 }
            } else if word == "huge" {
                query.minSize = 1_000_000_000
            } else if word == "small" || word == "smaller" {
                if let size = sizeAfter(index) { query.maxSize = size.bytes; index += size.used } else { query.maxSize = 1_000_000 }
            } else if word == "over" || word == "above", let size = sizeAfter(index) {
                query.minSize = size.bytes
                index += size.used
            } else if (word == "in" || word == "from"),
                      let folder = next().flatMap({ name in folderNames.first { $0.lowercased() == name } }) {
                query.folders.append(folder)
                index += 1
            } else if !stopWords.contains(word), !["than", "over", "in", "from", "last", "this", "past", "not", "opened"].contains(word) {
                nameWords.append(word)
            }
            index += 1
        }
        query.terms = nameWords
        return query
    }
}
