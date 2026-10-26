import Foundation

/// The Stage 01 action library: launching apps plus the handful of
/// operations a basic workspace setup needs.
public enum BuiltInActions {
    public static var all: [any AtlasAction] {
        [
            LaunchApplicationAction(),
            QuitApplicationAction(),
            HideApplicationAction(),
            MinimizeApplicationAction(),
            OpenURLAction(),
            OpenFileAction(),
            RevealInFinderAction(),
            ShowNotificationAction(),
            DelayAction(),
            LogMessageAction(),
            MoveFileAction(),
            CopyFileAction(),
            RenameFileAction(),
            CreateFolderAction(),
            TrashFileAction(),
            TagFileAction(),
            UndoFileOperationAction(),
            StartTimerAction(),
            StopTimerAction(),
        ]
    }
}

// MARK: - Applications

public struct LaunchApplicationAction: AtlasAction {
    public static let id: ActionID = "application.launch"

    public let descriptor = ActionDescriptor(
        id: LaunchApplicationAction.id,
        title: "Launch App",
        summary: "Opens an app, or brings it forward if it's already running.",
        category: "Applications",
        symbolName: "app.badge",
        parameters: [
            ParameterSpec(key: "bundleId", label: "App", kind: .bundleIdentifier,
                          help: "Bundle identifier, e.g. com.apple.Terminal"),
            ParameterSpec(key: "activate", label: "Bring to front", kind: .boolean,
                          isRequired: false, defaultValue: true),
        ],
        sideEffects: [.launchesApplication],
        isIdempotent: true,
        defaultTimeout: 30,
        outputs: [OutputSpec(key: "appName", label: "App name", type: .string)]
    )

    public init() {}

    public func perform(_ parameters: ActionParameters, context: ActionContext) async throws -> ActionOutput {
        let bundleID = try parameters.requiredString("bundleId")
        let activate = parameters["activate"]?.boolValue ?? true
        let outcome = try await context.system.launchApplication(bundleID: bundleID, activate: activate)
        if !outcome.wasAlreadyRunning {
            context.reportEffect(.app, bundleID)
        }
        let message = outcome.wasAlreadyRunning
            ? "\(outcome.displayName) was already running"
            : "Launched \(outcome.displayName)"
        return ActionOutput(message, values: [
            "appName": .string(outcome.displayName),
            "processId": .number(Double(outcome.processID)),
            "wasAlreadyRunning": .bool(outcome.wasAlreadyRunning),
        ])
    }
}

public struct QuitApplicationAction: AtlasAction {
    public static let id: ActionID = "application.quit"

    public let descriptor = ActionDescriptor(
        id: QuitApplicationAction.id,
        title: "Quit App",
        summary: "Asks an app to quit. The app still asks about unsaved work, and you confirm each run.",
        category: "Applications",
        symbolName: "xmark.app",
        parameters: [
            ParameterSpec(key: "bundleId", label: "App", kind: .bundleIdentifier,
                          help: "Bundle identifier, e.g. com.apple.Music"),
        ],
        sideEffects: [.terminatesApplication],
        confirmationRequired: true,
        isIdempotent: true,
        defaultTimeout: 20
    )

    public init() {}

    public func perform(_ parameters: ActionParameters, context: ActionContext) async throws -> ActionOutput {
        let bundleID = try parameters.requiredString("bundleId")
        let name = context.system.applicationName(for: bundleID) ?? bundleID
        guard context.system.runningApplications().contains(where: { $0.bundleID == bundleID }) else {
            return ActionOutput("\(name) wasn't running", values: ["didQuit": false])
        }
        let quit = try await context.system.quitApplication(bundleID: bundleID)
        guard quit else {
            throw ActionError.failed("\(name) didn't quit. It may be waiting for you to save something.")
        }
        return ActionOutput("Quit \(name)", values: ["didQuit": true])
    }
}

public struct HideApplicationAction: AtlasAction {
    public static let id: ActionID = "application.hide"

    public let descriptor = ActionDescriptor(
        id: HideApplicationAction.id,
        title: "Hide App",
        summary: "Hides an app's windows without quitting it. Click its Dock icon to bring it back.",
        category: "Applications",
        symbolName: "eye.slash",
        parameters: [
            ParameterSpec(key: "bundleId", label: "App", kind: .bundleIdentifier,
                          help: "Bundle identifier, e.g. com.apple.Music"),
        ],
        sideEffects: [.hidesApplication],
        isIdempotent: true,
        defaultTimeout: 10
    )

    public init() {}

    public func perform(_ parameters: ActionParameters, context: ActionContext) async throws -> ActionOutput {
        let bundleID = try parameters.requiredString("bundleId")
        let name = context.system.applicationName(for: bundleID) ?? bundleID
        let hidden = try await context.system.hideApplication(bundleID: bundleID)
        return ActionOutput(hidden ? "Hid \(name)" : "\(name) wasn't running", values: ["didHide": .bool(hidden)])
    }
}

public struct MinimizeApplicationAction: AtlasAction {
    public static let id: ActionID = "application.minimize"

    public let descriptor = ActionDescriptor(
        id: MinimizeApplicationAction.id,
        title: "Minimize App Windows",
        summary: "Minimizes every window of an app into the Dock. The app keeps running.",
        category: "Applications",
        symbolName: "dock.arrow.down.rectangle",
        parameters: [
            ParameterSpec(key: "bundleId", label: "App", kind: .bundleIdentifier,
                          help: "Bundle identifier, e.g. com.apple.Safari"),
        ],
        permissions: [.accessibility],
        sideEffects: [.hidesApplication],
        isIdempotent: true,
        defaultTimeout: 10
    )

    public init() {}

    public func perform(_ parameters: ActionParameters, context: ActionContext) async throws -> ActionOutput {
        let bundleID = try parameters.requiredString("bundleId")
        let name = context.system.applicationName(for: bundleID) ?? bundleID
        let count = try await context.system.minimizeApplicationWindows(bundleID: bundleID)
        let message = count == 0
            ? "\(name) had no windows to minimize"
            : "Minimized \(count) \(name) window\(count == 1 ? "" : "s")"
        return ActionOutput(message, values: ["windowsMinimized": .number(Double(count))])
    }
}

// MARK: - Links & files

public struct OpenURLAction: AtlasAction {
    public static let id: ActionID = "url.open"

    public let descriptor = ActionDescriptor(
        id: OpenURLAction.id,
        title: "Open Link",
        summary: "Opens a web page or app link in your default browser, or a browser you choose.",
        category: "Links & Files",
        symbolName: "link",
        parameters: [
            ParameterSpec(key: "url", label: "Link", kind: .url),
            ParameterSpec(key: "bundleId", label: "Open with", kind: .bundleIdentifier, isRequired: false,
                          help: "Leave empty for your default browser"),
        ],
        sideEffects: [.opensURL],
        // Retrying could open duplicate tabs.
        isIdempotent: false,
        defaultTimeout: 20,
        outputs: [OutputSpec(key: "url", label: "Link", type: .url)],
        isConcurrencySafe: true
    )

    public init() {}

    public func perform(_ parameters: ActionParameters, context: ActionContext) async throws -> ActionOutput {
        let raw = try parameters.requiredString("url")
        guard let url = URL(string: raw) else { throw ActionError.invalidParameter("Link", reason: "not a valid link") }
        try await context.system.open(url: url, withApplication: parameters.optionalString("bundleId"))
        return ActionOutput("Opened \(url.host ?? raw)", values: ["url": .string(raw)])
    }
}

public struct OpenFileAction: AtlasAction {
    public static let id: ActionID = "file.open"

    public let descriptor = ActionDescriptor(
        id: OpenFileAction.id,
        title: "Open File",
        summary: "Opens a document in its default app, or an app you choose.",
        category: "Links & Files",
        symbolName: "doc",
        parameters: [
            ParameterSpec(key: "path", label: "File", kind: .filePath),
            ParameterSpec(key: "bundleId", label: "Open with", kind: .bundleIdentifier, isRequired: false,
                          help: "Leave empty for the default app"),
        ],
        permissions: [.fileAccess],
        sideEffects: [.opensDocument],
        isIdempotent: true,
        defaultTimeout: 30
    )

    public init() {}

    public func perform(_ parameters: ActionParameters, context: ActionContext) async throws -> ActionOutput {
        let path = try parameters.path("path")
        guard context.system.fileKind(atPath: path) != .missing else {
            throw ActionError.failed("Nothing exists at \(path). It may have been moved or renamed.")
        }
        try await context.system.openFile(atPath: path, withApplication: parameters.optionalString("bundleId"))
        return ActionOutput("Opened \((path as NSString).lastPathComponent)", values: ["path": .string(path)])
    }
}

public struct RevealInFinderAction: AtlasAction {
    public static let id: ActionID = "folder.reveal"

    public let descriptor = ActionDescriptor(
        id: RevealInFinderAction.id,
        title: "Show in Finder",
        summary: "Opens a folder in Finder, or selects a file inside its folder.",
        category: "Links & Files",
        symbolName: "folder",
        parameters: [
            ParameterSpec(key: "path", label: "Folder or file", kind: .folderPath),
        ],
        permissions: [.fileAccess],
        sideEffects: [.showsUI],
        isIdempotent: true,
        defaultTimeout: 15
    )

    public init() {}

    public func perform(_ parameters: ActionParameters, context: ActionContext) async throws -> ActionOutput {
        let path = try parameters.path("path")
        guard context.system.fileKind(atPath: path) != .missing else {
            throw ActionError.failed("Nothing exists at \(path). It may have been moved or renamed.")
        }
        try await context.system.reveal(path: path)
        return ActionOutput("Showed \((path as NSString).lastPathComponent) in Finder", values: ["path": .string(path)])
    }
}

// MARK: - Feedback & timing

public struct ShowNotificationAction: AtlasAction {
    public static let id: ActionID = "notification.show"

    public let descriptor = ActionDescriptor(
        id: ShowNotificationAction.id,
        title: "Show Notification",
        summary: "Posts a macOS notification.",
        category: "Feedback",
        symbolName: "bell",
        parameters: [
            ParameterSpec(key: "title", label: "Title", kind: .text),
            ParameterSpec(key: "body", label: "Message", kind: .text, isRequired: false),
        ],
        permissions: [.notifications],
        sideEffects: [.showsNotification],
        // A retry could post the same notification twice.
        isIdempotent: false,
        defaultTimeout: 10,
        isConcurrencySafe: true
    )

    public init() {}

    public func perform(_ parameters: ActionParameters, context: ActionContext) async throws -> ActionOutput {
        let title = try parameters.requiredString("title")
        let body = parameters.optionalString("body") ?? ""
        try await context.system.postNotification(title: title, body: body)
        return ActionOutput("Notified: \(title)")
    }
}

public struct DelayAction: AtlasAction {
    public static let id: ActionID = "timer.delay"

    public let descriptor = ActionDescriptor(
        id: DelayAction.id,
        title: "Wait",
        summary: "Pauses the workflow, e.g. to give an app time to finish opening.",
        category: "Timing",
        symbolName: "hourglass",
        parameters: [
            ParameterSpec(key: "seconds", label: "Seconds", kind: .number, defaultValue: 1,
                          minimum: 0, maximum: 3600),
        ],
        isIdempotent: true,
        // Longer than the maximum wait so the timeout never cuts it short.
        defaultTimeout: 3_660,
        isConcurrencySafe: true
    )

    public init() {}

    public func perform(_ parameters: ActionParameters, context: ActionContext) async throws -> ActionOutput {
        let seconds = parameters["seconds"]?.numberValue ?? 1
        // Task.sleep throws CancellationError, so canceling a run stops a wait immediately.
        try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
        return ActionOutput("Waited \(ActionValue.number(seconds).displayString)s")
    }
}

public struct LogMessageAction: AtlasAction {
    public static let id: ActionID = "atlas.log"

    public let descriptor = ActionDescriptor(
        id: LogMessageAction.id,
        title: "Log Message",
        summary: "Writes a note into the run history. Handy for marking progress while building a workflow.",
        category: "Feedback",
        symbolName: "text.bubble",
        parameters: [
            ParameterSpec(key: "message", label: "Message", kind: .text),
        ],
        isIdempotent: true,
        defaultTimeout: 5,
        isConcurrencySafe: true
    )

    public init() {}

    public func perform(_ parameters: ActionParameters, context: ActionContext) async throws -> ActionOutput {
        let message = try parameters.requiredString("message")
        var payload: ActionParameters = ["message": .string(message)]
        if let runID = context.runID { payload["runId"] = .string(runID.uuidString) }
        context.events.publish(AtlasEvent(AtlasEvent.Name.log, payload: payload))
        AtlasLog.actions.info("\(message, privacy: .public)")
        return ActionOutput(message)
    }
}
