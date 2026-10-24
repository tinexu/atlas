import AtlasCore
import Foundation

/// Works out which apps a workflow brings up, so a Space can show which of
/// its apps are running and hide them when another Space takes over.
public enum SpaceApps {
    public static let finder = "com.apple.finder"

    /// Bundle identifiers of apps the workflow's enabled steps open, in
    /// step order, without duplicates.
    public static func bundleIDs(in workflow: Workflow) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for step in workflow.steps where step.isEnabled {
            let bundleID: String?
            if let explicit = step.parameters["bundleId"]?.stringValue, !explicit.isEmpty {
                bundleID = explicit
            } else if step.actionID == RevealInFinderAction.id {
                bundleID = finder
            } else {
                bundleID = nil
            }
            // Hiding or quitting an app doesn't make it part of the Space.
            let opensApp = step.actionID != HideApplicationAction.id
                && step.actionID != MinimizeApplicationAction.id
                && step.actionID != QuitApplicationAction.id
            if let bundleID, opensApp, seen.insert(bundleID).inserted {
                result.append(bundleID)
            }
        }
        return result
    }

    /// Apps the workflow opens plus apps its window layout places.
    public static func bundleIDs(in workflow: Workflow, layout: WindowLayout?) -> [String] {
        var result = bundleIDs(in: workflow)
        for bundleID in layout?.bundleIDs ?? [] where !result.contains(bundleID) {
            result.append(bundleID)
        }
        return result
    }
}
