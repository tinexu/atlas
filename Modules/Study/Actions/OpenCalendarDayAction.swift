import AtlasCore
import Foundation

/// `calendar.openDay`: opens Calendar to a day (the desk calendar's click).
public struct OpenCalendarDayAction: AtlasAction {
    public static let id: ActionID = "calendar.openDay"
    /// Replaced in tests.
    nonisolated(unsafe) static var runner: @Sendable (Date) async throws -> Void = { date in
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: date)
        let script = """
        set d to current date
        set day of d to 1
        set year of d to \(parts.year ?? 2000)
        set month of d to \(parts.month ?? 1)
        set day of d to \(parts.day ?? 1)
        tell application "Calendar"
            activate
            switch view to day view
            view calendar at d
        end tell
        """
        try await MainActor.run {
            var error: NSDictionary?
            NSAppleScript(source: script)?.executeAndReturnError(&error)
            if let error {
                throw ActionError.failed(error[NSAppleScript.errorMessage] as? String
                                         ?? "Calendar couldn't open that day. Allow ATLAS to control Calendar in System Settings → Privacy & Security → Automation.")
            }
        }
    }

    public let descriptor = ActionDescriptor(
        id: OpenCalendarDayAction.id,
        title: "Open Calendar to a Day",
        summary: "Opens Calendar on a given day.",
        category: "Study",
        symbolName: "calendar",
        parameters: [ParameterSpec(key: "date", label: "Day", kind: .text, help: "A date, e.g. 2026-11-03")],
        sideEffects: [.showsUI],
        isIdempotent: true,
        defaultTimeout: 15
    )

    public init() {}

    public func perform(_ parameters: ActionParameters, context: ActionContext) async throws -> ActionOutput {
        let raw = try parameters.requiredString("date")
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate]
        guard let date = formatter.date(from: String(raw.prefix(10))) ?? ISO8601DateFormatter().date(from: raw) else {
            throw ActionError.invalidParameter("Day", reason: "not a date like 2026-11-03.")
        }
        try await Self.runner(date)
        return ActionOutput("Opened Calendar on \(date.formatted(date: .abbreviated, time: .omitted))")
    }
}
