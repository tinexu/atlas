import AtlasCore
import AtlasSpaces
import Foundation

extension CreativeService {
    /// Opens `url` in a new window of `browser` (Chrome-like browsers and
    /// Safari through AppleScript), else as a normal link.
    func openInNewWindow(_ url: String, browser: String, system: SystemAdapter) async throws {
        let name = BrowserTabReader.chromeLike[browser] ?? BrowserTabReader.safari[browser]
        if let name {
            let isSafari = BrowserTabReader.safari[browser] != nil
            let script = isSafari
                ? "tell application \"\(name)\"\nmake new document with properties {URL:\"\(url)\"}\nactivate\nend tell"
                : "tell application \"\(name)\"\nset newWindow to make new window\nset URL of active tab of newWindow to \"\(url)\"\nactivate\nend tell"
            if scriptRunner.run(script) != nil { return }
        }
        guard let link = URL(string: url) else { return }
        try await system.open(url: link, withApplication: browser)
    }
}

/// `creative.startWatch`: Watch mode. YouTube in its own window (large and
/// centred, or with notes on the right), and a watch session that counts
/// separately from creating. Never blocks or hides anything.
public struct StartWatchAction: AtlasAction {
    public static let id: ActionID = "creative.startWatch"
    let ref = CreativeRef()
    weak var sessions: CreativeSessions?

    public let descriptor = ActionDescriptor(
        id: StartWatchAction.id, title: "Start Watch Mode",
        summary: "Opens YouTube (Watch Later or the home page) in its own window, large and centred, and starts a watch session.",
        category: "Creative", symbolName: "play.tv",
        sideEffects: [.opensURL, .showsUI, .launchesApplication, .arrangesWindows], isIdempotent: false, defaultTimeout: 60
    )

    init(service: CreativeService, sessions: CreativeSessions) {
        ref.service = service
        self.sessions = sessions
    }

    public func perform(_ parameters: ActionParameters, context: ActionContext) async throws -> ActionOutput {
        let service = try ref.require()
        let settings = service.settings
        var notes: [String] = []
        if sessions?.isWatching != true {
            try sessions?.start(minutes: 240, kind: .watch)
        }
        try await service.openInNewWindow(settings.watchStartPage.url, browser: settings.watchBrowser, system: context.system)
        var opened = ["YouTube (\(settings.watchStartPage.title))"]
        let windows = service.core.windows
        do {
                _ = try await windows.arrange(bundleID: settings.watchBrowser, preset: settings.watchWithNotes ? .leftTwoThirds : .centered,
                                              display: .main)
                if settings.watchWithNotes {
                    _ = try await context.system.launchApplication(bundleID: settings.watchNotesApp, activate: false)
                    _ = try await windows.arrange(bundleID: settings.watchNotesApp, preset: .rightThird, display: .main)
                    opened.append(service.appName(settings.watchNotesApp))
                }
        } catch {
            notes.append("couldn't arrange the windows: \(error.localizedDescription)")
        }
        if settings.watchOpensProject, service.currentProject() != nil {
            _ = try? await OpenCreativeProjectAction(service: service).perform([:], context: context)
            opened.append("the current project")
        }
        if settings.watchMusic, let playlist = URL(string: settings.watchPlaylist), !settings.watchPlaylist.isEmpty {
            try? await context.system.open(url: playlist, withApplication: nil)
            opened.append("music")
        }
        var output = ActionOutput("Watching · opened " + opened.joined(separator: ", "))
        if !notes.isEmpty { output.partialFailure = notes.joined(separator: "; ") }
        return output
    }
}

public enum TutorialError: Error, LocalizedError, Equatable {
    case noProject
    case noTab

    public var errorDescription: String? {
        switch self {
        case .noProject: return "There's no current project to save it to. Pick one by right-clicking the easel."
        case .noTab: return "Couldn't read a video from your browser. Open the video in Chrome or Safari, and allow ATLAS to control it if macOS asks (System Settings → Privacy & Security → Automation)."
        }
    }
}

extension CreativeService {
    /// Saves the browser's current page into the current project's links
    /// under Tutorials (once per URL). Returns the project and the tab.
    @discardableResult
    public func saveTutorial(sessions: CreativeSessions?) throws -> (project: Project, tab: BrowserTab) {
        guard var project = currentProject() else { throw TutorialError.noProject }
        guard let tab = tabReader.frontTab(preferred: settings.watchBrowser) else { throw TutorialError.noTab }
        if !(project.creative?.links.contains { $0.url == tab.url } ?? false) {
            project.creative?.links.append(CreativeInfo.Link(kind: .tutorial, title: tab.title, url: tab.url))
            project = try save(project)
        }
        sessions?.noteTutorial(tab.url)
        return (project, tab)
    }

    /// The current project's saved tutorials.
    public func tutorials(of project: Project? = nil) -> [CreativeInfo.Link] {
        ((project ?? currentProject())?.creative?.links ?? []).filter { $0.kind == .tutorial }
    }
}

/// `creative.saveTutorial`: "Save to project".
public struct SaveTutorialAction: AtlasAction {
    public static let id: ActionID = "creative.saveTutorial"
    let ref = CreativeRef()
    weak var sessions: CreativeSessions?

    public let descriptor = ActionDescriptor(
        id: SaveTutorialAction.id, title: "Save Video to Project",
        summary: "Saves the video (or page) open in your browser into the current creative project's Tutorials.",
        category: "Creative", symbolName: "bookmark",
        isIdempotent: true, defaultTimeout: 15
    )

    init(service: CreativeService, sessions: CreativeSessions) {
        ref.service = service
        self.sessions = sessions
    }

    public func perform(_ parameters: ActionParameters, context: ActionContext) async throws -> ActionOutput {
        let service = try ref.require()
        let saved = try service.saveTutorial(sessions: sessions)
        return ActionOutput("Saved “\(saved.tab.title)” to \(saved.project.name)",
                            values: ["url": .string(saved.tab.url), "project": .string(saved.project.id.uuidString)])
    }
}
