import AtlasCore
import Foundation

/// A file the Cleanup Review suggests moving to the Trash, and why.
public struct CleanupItem: Identifiable, Hashable, Sendable {
    public enum Reason: String, CaseIterable, Sendable {
        case largest, oldInstaller, staleDownload, duplicate

        public var title: String {
            switch self {
            case .largest: return "Largest files"
            case .oldInstaller: return "Old installers"
            case .staleDownload: return "Large downloads you haven't opened"
            case .duplicate: return "Extra copies of duplicates"
            }
        }
    }

    public var id: String { "\(reason.rawValue):\(entry.path)" }
    public let entry: FileEntry
    public let reason: Reason
    public let detail: String
}

/// Suggestions for freeing space (spec 10), all from Orbit folders. Nothing
/// is changed here; trashing goes through the engine after the person
/// reviews and confirms the list.
public struct CleanupAdvisor: Sendable {
    let core: AtlasCore

    public init(core: AtlasCore) {
        self.core = core
    }

    public func suggestions(duplicates: [DuplicateSet] = [], now: Date = Date()) -> [CleanupItem] {
        let roots = (try? core.store.locations().map(\.path)) ?? []
        guard !roots.isEmpty else { return [] }
        var items: [CleanupItem] = []
        var seen = Set<String>()
        func add(_ entry: FileEntry, _ reason: CleanupItem.Reason, _ detail: String) {
            guard seen.insert(entry.path).inserted else { return }
            items.append(CleanupItem(entry: entry, reason: reason, detail: detail))
        }
        let month: TimeInterval = 30 * 86_400

        let installers = (try? core.store.entries(matching: FileQuery(
            roots: roots, extensions: ["dmg", "pkg", "mpkg", "xip"], createdBefore: now.addingTimeInterval(-month),
            kind: .filesOnly, sort: .sizeDescending, limit: 100
        ))) ?? []
        for entry in installers {
            add(entry, .oldInstaller, "Downloaded \(Self.ago(entry.createdAt, now: now)). Installers aren't needed once the app is installed.")
        }

        let downloads = roots.filter { ($0 as NSString).lastPathComponent == "Downloads" }
        if !downloads.isEmpty {
            let stale = (try? core.store.entries(matching: FileQuery(
                roots: downloads, minSize: 50_000_000, openedBefore: now.addingTimeInterval(-3 * month),
                kind: .filesOnly, sort: .sizeDescending, limit: 100
            ))) ?? []
            for entry in stale {
                add(entry, .staleDownload, "Not opened since \(Self.ago(entry.accessedAt ?? entry.modifiedAt, now: now)).")
            }
        }

        for set in duplicates {
            for copy in set.files.dropFirst() {
                add(copy, .duplicate, "Same bytes as \(set.files[0].path.abbreviatedPath), which would be kept.")
            }
        }

        let largest = (try? core.store.entries(matching: FileQuery(roots: roots, minSize: 100_000_000, kind: .filesOnly,
                                                                   sort: .sizeDescending, limit: 30))) ?? []
        for entry in largest {
            add(entry, .largest, "Modified \(Self.ago(entry.modifiedAt, now: now)).")
        }
        return items
    }

    /// Moves the chosen files to the Trash in one run (so Run History can
    /// undo all of them). The caller has shown the list and asked for a yes.
    public func trash(_ paths: [String], source: String = "Cleanup Review") async -> WorkflowRun {
        let workflow = Workflow(
            name: "\(source): Move \(paths.count) item\(paths.count == 1 ? "" : "s") to Trash",
            summary: "Confirmed in \(source).",
            failurePolicy: .continueOnFailure,
            steps: paths.map { WorkflowStep(actionID: TrashFileAction.id, parameters: ["path": .string($0)],
                                            label: "Trash \(($0 as NSString).lastPathComponent)") }
        )
        return await core.engine.run(workflow, trigger: "cleanup", approvedIn: source)
    }

    static func ago(_ date: Date?, now: Date) -> String {
        guard let date else { return "a while ago" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: now)
    }
}
