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
    /// You switched away from a Space (to another one).
    public static let spaceDeactivated = "space.deactivated"
    public static let timeReached = "time.reached"
    public static let timerCompleted = "timer.completed"
    public static let displayChanged = "display.changed"
    public static let batteryLow = "battery.low"
    public static let powerConnected = "power.connected"
    public static let powerDisconnected = "power.disconnected"
    public static let woke = "system.woke"
    public static let healthWarning = "health.threshold"
    public static let blockStarting = "schedule.blockStarting"
    public static let blockEnded = "schedule.blockEnded"
    public static let focusEnded = "focus.ended"
    public static let calendarEventApproaching = "calendar.eventApproaching"

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
    private static let blockOutputs = [
        OutputSpec(key: "blockId", label: "Block ID", type: .string),
        OutputSpec(key: "title", label: "Block title", type: .string),
        OutputSpec(key: "spaceName", label: "Linked Space", type: .string),
        OutputSpec(key: "start", label: "Starts (seconds)", type: .number),
    ]

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
            id: spaceDeactivated, title: "Space Left", summary: "When you switch from a Space to another one.",
            symbolName: "cube.transparent.fill",
            parameters: [ParameterSpec(key: "space", label: "Space", kind: .text, isRequired: false,
                                       help: "A Space's name. Leave empty for any Space")],
            outputs: [
                OutputSpec(key: "spaceId", label: "Space ID", type: .string),
                OutputSpec(key: "spaceName", label: "Space name", type: .string),
                OutputSpec(key: "nextSpaceId", label: "Next Space ID", type: .string),
            ],
            reliability: "Fires when another Space is activated."
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
        TriggerType(
            id: blockStarting, title: "Block Starting", summary: "When a Time Architect block starts, or a set number of minutes before.",
            symbolName: "calendar.badge.clock",
            parameters: [
                ParameterSpec(key: "block", label: "Block", kind: .text, isRequired: false, help: "A block's title or ID. Leave empty for any block"),
                ParameterSpec(key: "minutesBefore", label: "Minutes before", kind: .number, isRequired: false,
                              help: "0 fires at the start", defaultValue: 0, minimum: 0, maximum: 240),
                ParameterSpec(key: "kind", label: "Only this kind", kind: .text, isRequired: false, defaultValue: "any",
                              options: ["any", "focus", "task", "appointment", "break"]),
            ],
            outputs: blockOutputs,
            reliability: "If the Mac is asleep or ATLAS isn't running at the start, the block's own setting decides: start on wake if it hasn't ended, or mark it missed. It never fires after a block has ended."
        ),
        TriggerType(
            id: blockEnded, title: "Block Ended", summary: "When a Time Architect block ends.", symbolName: "calendar.badge.checkmark",
            parameters: [ParameterSpec(key: "block", label: "Block", kind: .text, isRequired: false, help: "A block's title or ID. Leave empty for any block")],
            outputs: blockOutputs,
            reliability: "Fires only for blocks that started. Missed and skipped blocks don't end."
        ),
        TriggerType(
            id: focusEnded, title: "Focus Session Ended", summary: "When a focus session finishes or is stopped.", symbolName: "scope",
            parameters: [ParameterSpec(key: "completedOnly", label: "Only when it ran to the end", kind: .boolean, isRequired: false, defaultValue: false)],
            outputs: [
                OutputSpec(key: "title", label: "Session", type: .string),
                OutputSpec(key: "elapsedMinutes", label: "Minutes focused", type: .number),
                OutputSpec(key: "completed", label: "Ran to the end", type: .bool),
            ],
            reliability: "Sessions live in ATLAS. A session still running when ATLAS quits continues when it reopens."
        ),
        TriggerType(
            id: calendarEventApproaching, title: "Calendar Event Approaching", summary: "A set number of minutes before an event in your calendars.",
            symbolName: "calendar",
            parameters: [
                ParameterSpec(key: "minutesBefore", label: "Minutes before", kind: .number, defaultValue: 10, minimum: 1, maximum: 240),
                ParameterSpec(key: "calendar", label: "Calendar", kind: .text, isRequired: false, help: "A calendar's name. Leave empty for any"),
                ParameterSpec(key: "titleContains", label: "Title contains", kind: .text, isRequired: false, help: "e.g. Interview"),
            ],
            outputs: [
                OutputSpec(key: "title", label: "Event title", type: .string),
                OutputSpec(key: "calendar", label: "Calendar", type: .string),
                OutputSpec(key: "eventId", label: "Event ID", type: .string),
            ],
            permissions: [.calendar],
            reliability: "Needs calendar integration on (Time Architect → Calendar) and ATLAS running. Only calendars you chose to show are watched; all-day events are ignored."
        ),
    ]
}
