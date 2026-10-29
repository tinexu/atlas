import AppKit
import Foundation

/// Runs an AppleScript and returns its result as text items; a stand-in in tests.
public protocol AppleScriptRunning: Sendable {
    /// The script's result (a list becomes its items), or nil if it failed
    /// (for example, Automation permission was refused).
    func run(_ source: String) -> [String]?
}

public struct NSAppleScriptRunner: AppleScriptRunning {
    public init() {}

    public func run(_ source: String) -> [String]? {
        var result: [String]?
        let work = {
            var error: NSDictionary?
            guard let descriptor = NSAppleScript(source: source)?.executeAndReturnError(&error), error == nil else { return }
            if descriptor.numberOfItems > 0 {
                result = (1...descriptor.numberOfItems).map { descriptor.atIndex($0)?.stringValue ?? "" }
            } else {
                result = [descriptor.stringValue ?? ""]
            }
        }
        if Thread.isMainThread { work() } else { DispatchQueue.main.sync(execute: work) }
        return result
    }
}

/// The page in a browser's front window.
public struct BrowserTab: Equatable, Sendable {
    public var url: String
    public var title: String
    /// The browser's bundle ID.
    public var browser: String
}

/// Reads the URL and title of the front window's current tab, from Chrome
/// (and Chrome-like browsers) or Safari, through AppleScript. macOS asks for
/// Automation permission for each browser the first time.
public struct BrowserTabReader: Sendable {
    /// Browsers that answer `active tab of front window`.
    static let chromeLike: [String: String] = [
        "com.google.Chrome": "Google Chrome", "company.thebrowser.Browser": "Arc", "com.brave.Browser": "Brave Browser",
        "com.microsoft.edgemac": "Microsoft Edge",
    ]
    static let safari: [String: String] = ["com.apple.Safari": "Safari", "com.apple.SafariTechnologyPreview": "Safari Technology Preview"]

    let runner: AppleScriptRunning
    /// Bundle IDs of running apps, frontmost first.
    let running: @Sendable () -> [String]

    public init(runner: AppleScriptRunning = NSAppleScriptRunner(),
                running: @escaping @Sendable () -> [String] = BrowserTabReader.runningApps) {
        self.runner = runner
        self.running = running
    }

    public static func isSupported(_ bundleID: String) -> Bool {
        chromeLike[bundleID] != nil || safari[bundleID] != nil
    }

    /// The front tab of the frontmost supported browser (else `preferred`,
    /// else any running one); nil when none is open or it can't be read.
    public func frontTab(preferred: String? = nil) -> BrowserTab? {
        let apps = running()
        let candidates = apps.filter(Self.isSupported)
        // The frontmost browser wins; then the one Watch mode uses.
        var order = candidates
        if let preferred, let index = order.firstIndex(of: preferred), index > 0, apps.first.map(Self.isSupported) != true {
            order.insert(order.remove(at: index), at: 0)
        }
        for browser in order {
            if let tab = read(browser) { return tab }
        }
        return nil
    }

    func read(_ browser: String) -> BrowserTab? {
        let script: String
        if let name = Self.chromeLike[browser] {
            script = """
            tell application "\(name)"
                if (count of windows) = 0 then return {}
                set theTab to active tab of front window
                return {URL of theTab, title of theTab}
            end tell
            """
        } else if let name = Self.safari[browser] {
            script = """
            tell application "\(name)"
                if (count of documents) = 0 then return {}
                return {URL of front document, name of front document}
            end tell
            """
        } else {
            return nil
        }
        guard let items = runner.run(script), items.count >= 2 else { return nil }
        let url = items[0].trimmingCharacters(in: .whitespacesAndNewlines)
        guard url.hasPrefix("http") else { return nil }
        return BrowserTab(url: url, title: Self.cleanTitle(items[1], url: url), browser: browser)
    }

    /// "Donut tutorial - Part 1 - YouTube" → "Donut tutorial - Part 1"; the
    /// URL when there's no title.
    static func cleanTitle(_ raw: String, url: String) -> String {
        var title = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if title.hasSuffix(" - YouTube") { title = String(title.dropLast(" - YouTube".count)) }
        // YouTube puts the unread count in front: "(3) Donut tutorial".
        if let range = title.range(of: #"^\(\d+\) "#, options: .regularExpression) { title.removeSubrange(range) }
        return title.isEmpty ? url : title
    }

    public static let runningApps: @Sendable () -> [String] = {
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let all = NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier)
        return (front.map { [$0] } ?? []) + all.filter { $0 != front }
    }
}
