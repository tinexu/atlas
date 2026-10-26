import Foundation

/// A kind of event that can start a workflow on its own (spec 5.3). Like an
/// action descriptor: the editor builds its form from `parameters`, later
/// nodes can use `outputs`, and `reliability` is shown so people know what
/// to expect.
public struct TriggerType: Sendable, Identifiable, Hashable {
    public let id: String
    public let title: String
    public let summary: String
    public let symbolName: String
    public let parameters: [ParameterSpec]
    public let outputs: [OutputSpec]
    public let permissions: Set<Permission>
    /// When this trigger might not fire, in plain words.
    public let reliability: String

    public init(id: String, title: String, summary: String, symbolName: String, parameters: [ParameterSpec] = [],
                outputs: [OutputSpec] = [], permissions: Set<Permission> = [], reliability: String) {
        self.id = id
        self.title = title
        self.summary = summary
        self.symbolName = symbolName
        self.parameters = parameters
        self.outputs = outputs
        self.permissions = permissions
        self.reliability = reliability
    }
}

public enum TriggerCatalog {
    public static let appLaunched = "app.launched"
    public static let appQuit = "app.quit"
    public static let fileCreated = "file.created"
    public static let folderChanged = "folder.changed"
    public static let hotKey = "hotkey.pressed"
    public static let spaceActivated = "space.activated"
    public static let timeReached = "time.reached"
    public static let timerCompleted = "timer.completed"
    public static let displayChanged = "display.changed"
    public static let batteryLow = "battery.low"
    public static let powerConnected = "power.connected"
    public static let powerDisconnected = "power.disconnected"
    public static let woke = "system.woke"
    public static let healthWarning = "health.threshold"

    public static func type(id: String) -> TriggerType? {
        all.first { $0.id == id }
    }

    private static let appOutputs = [
        OutputSpec(key: "bundleId", label: "App", type: .bundleId),
        OutputSpec(key: "appName", label: "App name", type: .string),
    ]
    private static let fileOutputs = [
        OutputSpec(key: "path", label: "Path", type: .filePath),
        OutputSpec(key: "fileName", label: "File name", type: .string),
        OutputSpec(key: "extension", label: "Extension", type: .string),
        OutputSpec(key: "folder", label: "Folder", type: .filePath),
    ]
    private static let batteryOutput = [OutputSpec(key: "batteryPercent", label: "Battery %", type: .number)]

    public static let all: [TriggerType] = [
        TriggerType(
            id: appLaunched, title: "App Launched", summary: "When an app opens.", symbolName: "app.badge",
            parameters: [ParameterSpec(key: "app", label: "App", kind: .bundleIdentifier, isRequired: false,
                                       help: "Leave empty for any app")],
            outputs: appOutputs,
            reliability: "Fires for apps with a Dock icon. Background helpers and command-line tools aren't reported by macOS."
        ),
        TriggerType(
            id: appQuit, title: "App Quit", summary: "When an app quits.", symbolName: "xmark.app",
            parameters: [ParameterSpec(key: "app", label: "App", kind: .bundleIdentifier, isRequired: false,
                                       help: "Leave empty for any app")],
            outputs: appOutputs,
            reliability: "Also fires when an app crashes. Apps quit while ATLAS wasn't running aren't noticed."
        ),
        TriggerType(
            id: fileCreated, title: "File Created", summary: "When a new file appears in a folder.", symbolName: "doc.badge.plus",
            parameters: [
                ParameterSpec(key: "folder", label: "Folder", kind: .folderPath, help: "e.g. ~/Downloads"),
                ParameterSpec(key: "extensions", label: "Only these extensions", kind: .text, isRequired: false,
                              help: "e.g. pdf, png. Leave empty for all files"),
            ],
            outputs: fileOutputs,
            permissions: [.fileAccess],
            reliability: "Waits until a download or copy finishes before firing. Hidden files and partial downloads are ignored. Files added while ATLAS wasn't running aren't noticed."
        ),
        TriggerType(
            id: folderChanged, title: "Folder Changed", summary: "When anything in a folder is added, changed, renamed or removed.",
            symbolName: "folder.badge.gearshape",
            parameters: [ParameterSpec(key: "folder", label: "Folder", kind: .folderPath, help: "e.g. ~/Desktop")],
            outputs: fileOutputs + [OutputSpec(key: "change", label: "Change", type: .string)],
            permissions: [.fileAccess],
            reliability: "Bursts of changes within half a second are combined into one run."
        ),
        TriggerType(
            id: hotKey, title: "Keyboard Shortcut", summary: "When you press a shortcut anywhere on the Mac.", symbolName: "command",
            parameters: [ParameterSpec(key: "shortcut", label: "Shortcut", kind: .text, help: "e.g. cmd+shift+k or ctrl+option+1")],
            reliability: "Needs at least one of ⌘, ⌃ or ⌥. If another app already uses the shortcut, macOS won't let ATLAS have it and the workflow shows why."
        ),
        TriggerType(
            id: spaceActivated, title: "Space Activated", summary: "When a Space is activated.", symbolName: "cube.transparent",
            parameters: [ParameterSpec(key: "space", label: "Space", kind: .text, isRequired: false,
                                       help: "A Space's name. Leave empty for any Space")],
            outputs: [
                OutputSpec(key: "spaceId", label: "Space ID", type: .string),
                OutputSpec(key: "spaceName", label: "Space name", type: .string),
                OutputSpec(key: "profileId", label: "Profile ID", type: .string),
            ],
            reliability: "Fires after the Space's own activation has finished."
        ),
        TriggerType(
            id: timeReached, title: "Time Reached", summary: "Every day, on some weekdays, or once, at a time.", symbolName: "clock",
            parameters: [
                ParameterSpec(key: "repeat", label: "Repeat", kind: .text, defaultValue: "daily", options: ["daily", "weekly", "once"]),
                ParameterSpec(key: "time", label: "Time", kind: .text, help: "24-hour, e.g. 09:00", defaultValue: "09:00"),
                ParameterSpec(key: "days", label: "Days (weekly)", kind: .text, isRequired: false, help: "e.g. mon, wed, fri"),
                ParameterSpec(key: "date", label: "Date (once)", kind: .text, isRequired: false, help: "e.g. 2026-12-24"),
                ParameterSpec(key: "ifMissed", label: "If the Mac was asleep", kind: .text, defaultValue: "runOnWake",
                              options: ["runOnWake", "skip"]),
            ],
            outputs: [OutputSpec(key: "scheduledFor", label: "Scheduled time", type: .string)],
            reliability: "Needs ATLAS running. If the Mac is asleep at that time, the run happens on wake or is skipped, as you choose."
        ),
        TriggerType(
            id: timerCompleted, title: "Timer Completed", summary: "When a timer started by “Start Timer” ends.", symbolName: "timer",
            parameters: [ParameterSpec(key: "name", label: "Timer name", kind: .text, isRequired: false,
                                       help: "Leave empty for any timer")],
            outputs: [OutputSpec(key: "name", label: "Timer name", type: .string)],
            reliability: "Timers live in ATLAS: quitting ATLAS cancels them."
        ),
        TriggerType(
            id: displayChanged, title: "Displays Changed", summary: "When a display is connected, disconnected or rearranged.",
            symbolName: "display.2",
            outputs: [
                OutputSpec(key: "displayCount", label: "Displays", type: .number),
                OutputSpec(key: "profileId", label: "Display profile", type: .string),
            ],
            reliability: "Several quick changes (like a dock connecting) are combined into one."
        ),
        TriggerType(
            id: batteryLow, title: "Battery Low", summary: "When the battery drops below a level.", symbolName: "battery.25",
            parameters: [ParameterSpec(key: "percent", label: "Below %", kind: .number, defaultValue: 20, minimum: 1, maximum: 99)],
            outputs: batteryOutput,
            reliability: "Fires once each time the level crosses below the threshold. Macs without a battery never fire it."
        ),
        TriggerType(
            id: powerConnected, title: "Power Adapter Connected", summary: "When the Mac is plugged in.", symbolName: "powerplug",
            outputs: batteryOutput, reliability: "Macs without a battery never fire it."
        ),
        TriggerType(
            id: powerDisconnected, title: "Power Adapter Disconnected", summary: "When the Mac is unplugged.",
            symbolName: "powerplug.portrait",
            outputs: batteryOutput, reliability: "Macs without a battery never fire it."
        ),
        TriggerType(
            id: woke, title: "Mac Woke Up", summary: "When the Mac wakes from sleep.", symbolName: "sunrise",
            reliability: "Fires a moment after wake, once the network and displays are back."
        ),
        TriggerType(
            id: healthWarning, title: "Mac Health Warning", summary: "When a Mac Health warning you set is crossed, like low disk space.",
            symbolName: "stethoscope",
            parameters: [ParameterSpec(key: "metric", label: "Warning", kind: .text, isRequired: false, defaultValue: "any",
                                       options: ["any", "diskFree", "cpu", "memory", "battery"])],
            outputs: [
                OutputSpec(key: "metric", label: "Warning", type: .string),
                OutputSpec(key: "value", label: "Value", type: .number),
                OutputSpec(key: "threshold", label: "Threshold", type: .number),
                OutputSpec(key: "message", label: "Description", type: .string),
            ],
            reliability: "Set warnings in Mac Health. Each fires once when crossed, and again only after things recover. Needs ATLAS running."
        ),
    ]
}
