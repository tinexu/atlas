import AppKit
import AtlasCore
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Run state presentation

extension RunState {
    var symbol: String {
        switch self {
        case .pending: return "circle.dotted"
        case .running: return "arrow.triangle.2.circlepath"
        case .succeeded: return "checkmark.circle.fill"
        case .partiallySucceeded: return "exclamationmark.circle.fill"
        case .failed: return "xmark.octagon.fill"
        case .skipped: return "arrow.uturn.forward.circle"
        case .canceled: return "stop.circle"
        }
    }

    var tint: Color {
        switch self {
        case .pending, .skipped, .canceled: return .secondary
        case .running: return .accentColor
        case .succeeded: return .green
        case .partiallySucceeded: return .orange
        case .failed: return .red
        }
    }
}

struct StateIcon: View {
    let state: RunState

    var body: some View {
        Image(systemName: state.symbol)
            .foregroundStyle(state.tint)
            .symbolEffect(.pulse, isActive: state == .running)
            .accessibilityLabel(state.title)
    }
}

struct StateBadge: View {
    let state: RunState

    var body: some View {
        Label(state.title, systemImage: state.symbol)
            .font(.caption.weight(.medium))
            .foregroundStyle(state.tint)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(state.tint.opacity(0.12), in: Capsule())
    }
}

extension PermissionStatus {
    var tint: Color {
        switch self {
        case .granted, .managedBySystem: return .green
        case .denied: return .red
        case .notDetermined: return .orange
        case .unavailable: return .secondary
        }
    }
}

struct Pill: View {
    let text: String
    var tint: Color = .secondary

    var body: some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .foregroundStyle(tint)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 4))
    }
}

// MARK: - Formatting

enum Formatting {
    static func duration(_ seconds: TimeInterval?) -> String {
        guard let seconds else { return "—" }
        if seconds < 1 { return "\(Int((seconds * 1000).rounded())) ms" }
        if seconds < 60 { return String(format: "%.1f s", seconds) }
        return "\(Int(seconds) / 60)m \(Int(seconds) % 60)s"
    }

    static func trigger(_ trigger: String) -> String {
        switch trigger {
        case "manual": return "Run manually"
        case "menu-bar": return "Menu bar"
        case "shortcut": return "Keyboard shortcut"
        case "space.activated": return "Space activated"
        case "space.transition": return "Space switch (tidying previous apps)"
        case "space.object": return "Room object"
        case "space.restore": return "Restore where you left off"
        case "window-manager": return "Window Manager"
        case RunTrigger.test: return "Run now (test)"
        case RunTrigger.retry: return "Retry of failed steps"
        case RunTrigger.subworkflow: return "Called by another automation"
        case "orbit": return "Orbit"
        case "cleanup": return "Cleanup Review"
        case "review": return "Approved in the review queue"
        case "undo": return "Undo from Run History"
        case "project": return "Project (Space activated)"
        case "trigger.orbit.sweep": return "Daily rule check"
        case RunTrigger.companion: return "Companion"
        case "recommendation": return "Accepted a recommendation"
        case "focus": return "Focus session ended"
        default:
            if trigger.hasPrefix(RunTrigger.automaticPrefix) {
                let type = String(trigger.dropFirst(RunTrigger.automaticPrefix.count))
                return "Trigger: \(TriggerCatalog.type(id: type)?.title ?? type)"
            }
            return trigger
        }
    }
}

// MARK: - Open panels

enum Pickers {
    /// Lets the user pick an app; returns its bundle identifier.
    @MainActor
    static func chooseApplication() -> String? {
        let panel = NSOpenPanel()
        panel.title = "Choose an App"
        panel.prompt = "Choose"
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return Bundle(url: url)?.bundleIdentifier
    }

    @MainActor
    static func choosePath(folders: Bool) -> String? {
        let panel = NSOpenPanel()
        panel.title = folders ? "Choose a Folder" : "Choose a File"
        panel.prompt = "Choose"
        panel.canChooseFiles = !folders
        panel.canChooseDirectories = folders
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        // Store paths under the home folder with ~ so workflows stay
        // portable between Macs with different user names.
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if url.path.hasPrefix(home) {
            return "~" + url.path.dropFirst(home.count)
        }
        return url.path
    }

    static func applicationName(for bundleID: String) -> String? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        return url.deletingPathExtension().lastPathComponent
    }

    static func applicationIcon(for bundleID: String) -> NSImage? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        return NSWorkspace.shared.icon(forFile: url.path)
    }
}
