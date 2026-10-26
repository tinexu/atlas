import AtlasCore
import AtlasOrbit
import AtlasSpaces
import Foundation

/// One row in the command palette.
public struct PaletteItem: Identifiable, Equatable, Sendable {
    public enum Section: String, CaseIterable, Sendable {
        case command = "Command"
        case spaces = "Spaces"
        case workflows = "Workflows"
        case layouts = "Layouts & Snapshots"
        case files = "Files"
        case actions = "Actions"
        case screens = "Screens"
        case history = "Recent"
    }

    public let id: String
    public let section: Section
    public let title: String
    public let subtitle: String
    public let symbol: String
    public let plan: CommandPlan
    public let score: Double

    public init(id: String, section: Section, title: String, subtitle: String, symbol: String, plan: CommandPlan, score: Double) {
        self.id = id
        self.section = section
        self.title = title
        self.subtitle = subtitle
        self.symbol = symbol
        self.plan = plan
        self.score = score
    }
}

/// Type-ahead over everything ATLAS can do. Typing narrows the list; text
/// that doesn't name an item becomes a command for the parser instead.
public struct PaletteCatalog: Sendable {
    public let vocabulary: CommandVocabulary
    public let registry: ActionRegistry
    /// Orbit search, or nil when Orbit isn't running.
    public let files: FileSearch?

    public init(vocabulary: CommandVocabulary, registry: ActionRegistry, files: FileSearch?) {
        self.vocabulary = vocabulary
        self.registry = registry
        self.files = files
    }

    /// Shown before anything is typed: Spaces, favourite workflows, screens.
    public func defaults(favorites: [UUID], recent: [String]) -> [PaletteItem] {
        var items: [PaletteItem] = []
        let parser = DeterministicParser(vocabulary: vocabulary)
        for space in vocabulary.spaces {
            items.append(item(.spaces, id: "space:\(space.id)", title: space.name, subtitle: space.defaultProfile.map { "Activate · \($0.name)" } ?? "Activate",
                              symbol: "cube.transparent", plan: parser.spacePlan(space, profile: nil), score: 1))
        }
        let favoriteSet = Set(favorites.map(\.uuidString))
        for workflow in vocabulary.workflows where favoriteSet.contains(workflow.id) {
            guard let id = UUID(uuidString: workflow.id) else { continue }
            items.append(item(.workflows, id: "workflow:\(id)", title: workflow.name, subtitle: "Favourite · Run", symbol: "star.fill",
                              plan: parser.workflowPlan(id: id, name: workflow.name), score: 1))
        }
        for text in recent.prefix(3) {
            if let plan = parser.parse(text).plan {
                items.append(item(.history, id: "recent:\(text)", title: text, subtitle: plan.summary, symbol: "clock.arrow.circlepath", plan: plan, score: 0.5))
            }
        }
        return items
    }

    /// Items matching typed text, best first, grouped in a stable order.
    public func search(_ text: String, limit: Int = 24) -> [PaletteItem] {
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }
        let parser = DeterministicParser(vocabulary: vocabulary)
        var items: [PaletteItem] = []

        func add(_ section: PaletteItem.Section, id: String, title: String, subtitle: String, symbol: String, plan: @autoclosure () -> CommandPlan) {
            let score = NameMatcher.score(query: query, name: title)
            let prefix = title.lowercased().hasPrefix(query.lowercased()) ? 0.15 : 0
            guard score + prefix >= NameMatcher.threshold else { return }
            items.append(item(section, id: id, title: title, subtitle: subtitle, symbol: symbol, plan: plan(), score: score + prefix))
        }

        for space in vocabulary.spaces {
            add(.spaces, id: "space:\(space.id)", title: space.name, subtitle: space.defaultProfile.map { "Activate · \($0.name)" } ?? "Activate",
                symbol: "cube.transparent", plan: parser.spacePlan(space, profile: nil))
            for profile in space.profiles where !profile.isDefault {
                add(.spaces, id: "profile:\(profile.id)", title: "\(space.name) — \(profile.name)", subtitle: "Activate this profile",
                    symbol: "cube.transparent", plan: parser.spacePlan(space, profile: profile))
            }
        }
        for workflow in vocabulary.workflows {
            guard let id = UUID(uuidString: workflow.id) else { continue }
            add(.workflows, id: "workflow:\(id)", title: workflow.name, subtitle: "Run workflow", symbol: "bolt.horizontal.circle",
                plan: parser.workflowPlan(id: id, name: workflow.name))
        }
        for layout in vocabulary.layouts {
            add(.layouts, id: "layout:\(layout.id)", title: layout.name, subtitle: "Apply window layout", symbol: "macwindow.on.rectangle",
                plan: parser.layoutApplyPlan(layout.name))
        }
        for snapshot in vocabulary.snapshots.prefix(10) {
            add(.layouts, id: "snapshot:\(snapshot.id)", title: snapshot.name, subtitle: "Restore snapshot", symbol: "clock.arrow.circlepath",
                plan: parser.snapshotRestorePlan(snapshot.name))
        }
        // Actions that need no settings run straight from the palette; others open their command.
        for descriptor in registry.descriptors where Self.paletteActions.contains(descriptor.id) {
            add(.actions, id: "action:\(descriptor.id)", title: descriptor.title, subtitle: descriptor.summary, symbol: descriptor.symbolName,
                plan: CommandPlan(kind: .actions([.init(descriptor.id)]), summary: descriptor.title, details: [descriptor.summary],
                                  hasSideEffects: true, subject: descriptor.title))
        }
        for (title, words, destination) in Self.screens {
            let best = ([title] + words).map { NameMatcher.score(query: query, name: $0) }.max() ?? 0
            if best >= NameMatcher.threshold {
                items.append(item(.screens, id: "screen:\(title)", title: title, subtitle: "Open in ATLAS", symbol: "rectangle.on.rectangle",
                                  plan: CommandPlan(kind: .open(destination), summary: "Open \(title)", hasSideEffects: false, subject: title),
                                  score: best))
            }
        }
        if let files, query.count >= 2 {
            let results = (try? files.search(SearchQuery.parse(query), limit: 6)) ?? []
            for result in results {
                let entry = result.entry
                items.append(item(.files, id: "file:\(entry.path)", title: entry.name, subtitle: entry.parent.abbreviatedPath,
                                  symbol: entry.isFolder ? "folder" : "doc",
                                  plan: Self.openFilePlan(entry), score: 0.55))
            }
        }
        let order = PaletteItem.Section.allCases
        return Array(items.sorted { a, b in
            if abs(a.score - b.score) > 0.2 { return a.score > b.score }
            return (order.firstIndex(of: a.section) ?? 0, -a.score) < (order.firstIndex(of: b.section) ?? 0, -b.score)
        }.prefix(limit))
    }

    /// Opening a document or folder you picked changes nothing, so it runs at once.
    public static func openFilePlan(_ entry: FileEntry) -> CommandPlan {
        let action: ActionID = entry.isFolder ? RevealInFinderAction.id : OpenFileAction.id
        return CommandPlan(kind: .actions([.init(action, ["path": .string(entry.path)])]),
                           summary: entry.isFolder ? "Show \(entry.name) in Finder" : "Open \(entry.name)",
                           hasSideEffects: false, subject: entry.name)
    }

    static let paletteActions: Set<ActionID> = ["window.snapshot.save"]

    static let screens: [(String, [String], CommandPlan.Destination)] = [
        ("Largest Files", ["storage", "disk space", "big files"], .largestFiles),
        ("Cleanup Review", ["clean up", "free space"], .cleanup),
        ("Review Queue", ["reviews", "waiting files"], .reviewQueue),
        ("Run History", ["history", "runs", "log"], .runHistory(nil)),
        ("Mac Health", ["health", "cpu", "memory", "battery"], .health),
        ("Automations", ["workflows", "flow"], .section("automations")),
        ("Permissions", ["privacy", "access"], .section("permissions")),
        ("Companion Settings", ["settings", "character", "companion"], .companionSettings),
        ("Orbit", ["files", "universe"], .section("orbit")),
        ("Spaces", ["rooms", "mission control"], .section("spaces")),
    ]

    private func item(_ section: PaletteItem.Section, id: String, title: String, subtitle: String, symbol: String, plan: CommandPlan,
                      score: Double) -> PaletteItem {
        PaletteItem(id: id, section: section, title: title, subtitle: subtitle, symbol: symbol, plan: plan, score: score)
    }
}
