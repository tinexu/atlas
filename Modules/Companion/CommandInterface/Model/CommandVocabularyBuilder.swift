import AtlasCore
import AtlasSpaces
import Foundation

/// Reads current names from the store for the parser and the palette.
public enum CommandVocabularyBuilder {
    public static func build(store: AtlasStore, apps: [CommandVocabulary.Named], timers: TimerCenter = .shared) -> CommandVocabulary {
        let spaces = (try? store.spaces()) ?? []
        let profiles = (try? store.profiles()) ?? []
        let profileWorkflowIDs = Set(profiles.map(\.workflowID))
        let spaceEntries = spaces.map { space in
            CommandVocabulary.SpaceEntry(
                id: space.id, name: space.name,
                profiles: profiles.filter { $0.spaceID == space.id }.sorted { $0.position < $1.position }
                    .map { (id: $0.id, name: $0.name, isDefault: $0.isDefault) }
            )
        }
        // Workflows you'd run by name: not a Space's activation or a file rule's plumbing.
        let workflows = ((try? store.workflows()) ?? [])
            .filter { !profileWorkflowIDs.contains($0.id) && !$0.name.hasPrefix("Rule: ") && !$0.steps.isEmpty }
            .map { CommandVocabulary.Named(id: $0.id.uuidString, name: $0.name) }
        let layouts = ((try? store.windowLayouts()) ?? []).map { CommandVocabulary.Named(id: $0.id.uuidString, name: $0.name) }
        let snapshots = ((try? store.snapshots(limit: 30)) ?? [])
            .sorted { $0.createdAt > $1.createdAt }
            .map { CommandVocabulary.Named(id: $0.id.uuidString, name: $0.name) }
        let running = ((try? store.runs(matching: RunQuery(states: [.running]), limit: 20)) ?? [])
            .map { CommandVocabulary.Named(id: $0.id.uuidString, name: $0.workflowName) }
        return CommandVocabulary(spaces: spaceEntries, workflows: workflows, apps: apps, layouts: layouts, snapshots: snapshots,
                                 runningWorkflows: running, timers: timers.active.map(\.name))
    }
}

/// Apps in the usual Applications folders, by name and bundle ID. Read once
/// in the background; only names and IDs are kept.
public enum InstalledApps {
    public static func scan() -> [CommandVocabulary.Named] {
        let fm = FileManager.default
        let folders = ["/Applications", "/Applications/Utilities", "/System/Applications", "/System/Applications/Utilities",
                       (NSHomeDirectory() as NSString).appendingPathComponent("Applications")]
        var seen = Set<String>()
        var apps: [CommandVocabulary.Named] = []
        for folder in folders {
            for item in (try? fm.contentsOfDirectory(atPath: folder)) ?? [] where item.hasSuffix(".app") {
                let path = (folder as NSString).appendingPathComponent(item)
                guard let bundle = Bundle(path: path), let id = bundle.bundleIdentifier, seen.insert(id).inserted else { continue }
                let name = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                    ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
                    ?? (item as NSString).deletingPathExtension
                apps.append(.init(id: id, name: name))
            }
        }
        return apps.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}
