import XCTest
@testable import AtlasCore
@testable import AtlasSpaces
@testable import AtlasStudy

final class WindowLockTests: XCTestCase {
    private var time: TimeHarness!
    private var system: MockSystemAdapter { time.base.system }
    private var windows: MockWindowAdapter { time.base.windows }
    private var windowLock: WindowLockService { time.time.windowLock }
    private let chrome = "com.google.Chrome", safari = "com.apple.Safari"
    private let owner = UUID()

    override func setUp() async throws {
        time = try TimeHarness()
        windowLock.pollInterval = .milliseconds(20)
        system.installedApps[chrome] = "Google Chrome"
        system.installedApps[safari] = "Safari"
        system.installedApps["com.apple.finder"] = "Finder"
        for app in [chrome, safari, "com.apple.Notes", "com.apple.finder"] { system.markRunning(app) }
    }

    override func tearDown() {
        windowLock.endBecauseATLASIsQuitting()
    }

    private func wait(_ condition: @escaping () -> Bool) async -> Bool {
        await time.base.waitUntil(condition)
    }

    func testStartHidesOtherAppsMinimizesOtherWindowsAndFocusesTheChosenOne() async throws {
        let leetcode = windows.addWindow(chrome, app: "Chrome", title: "LeetCode")
        _ = windows.addWindow(chrome, app: "Chrome-YouTube", title: "YouTube")
        _ = windows.addWindow(safari, app: "Safari", title: "News")
        let candidates = await windowLock.candidates()
        XCTAssertEqual(Set(candidates.map(\.title)), ["LeetCode", "YouTube", "News"])

        let session = await windowLock.start([LockedWindow(leetcode)], ownerID: owner)
        XCTAssertEqual(session?.allowedApps, [chrome])
        XCTAssertTrue(system.calls.contains("hide:\(safari)"))
        XCTAssertTrue(system.calls.contains("hide:com.apple.Notes"))
        XCTAssertTrue(system.calls.contains("hide:com.apple.finder"), "Finder's windows are tidied away")
        XCTAssertFalse(system.calls.contains("hide:\(chrome)"))
        XCTAssertFalse(system.calls.contains { $0.hasPrefix("quit:") }, "running apps are never quit")
        XCTAssertTrue(windows.calls.contains("minimize:Chrome-YouTube"))
        XCTAssertFalse(windows.calls.contains("minimize:Chrome"))
        XCTAssertTrue(windows.calls.contains("focus:Chrome"))
        XCTAssertEqual(session?.totalBlocked, 0, "tidying at the start isn't a blocked attempt")
    }

    func testANewWindowInTheChosenAppIsMinimized() async throws {
        let leetcode = windows.addWindow(chrome, app: "Chrome", title: "LeetCode")
        await windowLock.start([LockedWindow(leetcode)], ownerID: owner)
        time.environment.advance(by: 10)
        system.activeBundleID = chrome
        _ = windows.addWindow(chrome, app: "Chrome-New", title: "New Tab")
        let ok = await wait { self.windows.calls.contains("minimize:Chrome-New") }
        XCTAssertTrue(ok, "the poller catches a window opened in the chosen app")
        XCTAssertEqual(windowLock.session?.blocked["Another Chrome-New window"], 1)
    }

    func testABlockedAppComingForwardIsHiddenAgain() async throws {
        let leetcode = windows.addWindow(chrome, app: "Chrome", title: "LeetCode")
        await windowLock.start([LockedWindow(leetcode)], ownerID: owner)
        let before = system.calls.filter { $0 == "hide:\(safari)" }.count
        time.environment.activate(safari, name: "Safari")
        let ok = await wait { self.system.calls.filter { $0 == "hide:\(self.safari)" }.count == before + 1 }
        XCTAssertTrue(ok)
        XCTAssertEqual(windowLock.session?.blocked["Safari"], 1)
        time.environment.launch("com.apple.Music", name: "Music")
        let quit = await wait { self.system.calls.contains("quit:com.apple.Music") }
        XCTAssertTrue(quit, "an app opened during the lock is asked to quit")
    }

    func testAClosedWindowIsReplacedByTheAppsNextOne() async throws {
        let leetcode = windows.addWindow(chrome, app: "Chrome", title: "LeetCode")
        await windowLock.start([LockedWindow(leetcode)], ownerID: owner)
        windows.removeWindow(leetcode.id)
        let next = windows.addWindow(chrome, app: "Chrome-Again", title: "LeetCode")
        await windowLock.enforceWindows()
        XCTAssertEqual(windowLock.session?.windows.map(\.windowID), [next.id.rawValue])
        XCTAssertFalse(windows.calls.contains("minimize:Chrome-Again"))
    }

    func testBreaksStayLockedUnlessAllowed() async throws {
        let leetcode = windows.addWindow(chrome, app: "Chrome", title: "LeetCode")
        await windowLock.start([LockedWindow(leetcode)], ownerID: owner, unlockDuringBreaks: true)
        windowLock.setOnBreak(true)
        let before = system.calls.filter { $0 == "hide:\(safari)" }.count
        await windowLock.handleActivation(safari, name: "Safari")
        XCTAssertEqual(system.calls.filter { $0 == "hide:\(safari)" }.count, before, "a break lets you out")
        windowLock.setOnBreak(false)
        await windowLock.handleActivation(safari, name: "Safari")
        XCTAssertGreaterThan(system.calls.filter { $0 == "hide:\(safari)" }.count, before, "and focus locks you back in")

        windowLock.endBecauseATLASIsQuitting()
        await windowLock.start([LockedWindow(leetcode)], ownerID: owner)
        windowLock.setOnBreak(true)
        let locked = system.calls.filter { $0 == "hide:\(safari)" }.count
        await windowLock.handleActivation(safari, name: "Safari")
        XCTAssertEqual(system.calls.filter { $0 == "hide:\(safari)" }.count, locked + 1, "by default breaks stay locked")
    }

    func testEndingBringsBackWhatItTidiedAway() async throws {
        let leetcode = windows.addWindow(chrome, app: "Chrome", title: "LeetCode")
        let youtube = windows.addWindow(chrome, app: "Chrome-YouTube", title: "YouTube")
        await windowLock.start([LockedWindow(leetcode)], ownerID: owner)
        XCTAssertEqual(windows.window(youtube.id)?.isMinimized, true)
        await windowLock.end()
        XCTAssertNil(windowLock.session)
        XCTAssertTrue(system.calls.contains("unhide:\(safari)"))
        XCTAssertTrue(windows.calls.contains("unminimize:Chrome-YouTube"))
        XCTAssertNil(try time.store.preference(WindowLockService.sessionKey, as: WindowLockSession.self))
    }

    func testWithoutAccessibilityItLocksWholeApps() async throws {
        let leetcode = windows.addWindow(chrome, app: "Chrome", title: "LeetCode")
        _ = windows.addWindow(chrome, app: "Chrome-YouTube", title: "YouTube")
        windows.trusted = false
        let session = await windowLock.start([LockedWindow(leetcode)], ownerID: owner)
        XCTAssertEqual(session?.windowLevel, false)
        XCTAssertTrue(system.calls.contains("hide:\(safari)"))
        XCTAssertTrue(system.calls.contains("activate:\(chrome)"))
        XCTAssertFalse(windows.calls.contains { $0.hasPrefix("minimize:") })
    }

    func testAStudySessionLocksInAndUnlocksWhenItEnds() async throws {
        let study = try StudyModule(core: time.core, reminders: MockReminderStore(), weatherFetcher: MockWeatherFetcher())
        let leetcode = windows.addWindow(chrome, app: "Chrome", title: "LeetCode")
        let none = await study.lockIn([LockedWindow(leetcode)])
        XCTAssertNil(none, "no session, no lock")

        let session = try study.sessions.start(minutes: 50, pomodoro: false)
        let locked = await study.lockIn([LockedWindow(leetcode)])
        XCTAssertEqual(locked?.ownerID, session.id)
        XCTAssertEqual(study.service.settings.windowLock.lastWindows.map(\.title), ["LeetCode"], "remembered for next time")

        study.sessions.end(early: true)
        let ended = await wait { !self.windowLock.isActive }
        XCTAssertTrue(ended, "ending the session unlocks")
    }

    func testALockFromBeforeACrashResumesOnlyWithItsSession() async throws {
        let leetcode = windows.addWindow(chrome, app: "Chrome", title: "LeetCode")
        await windowLock.start([LockedWindow(leetcode)], ownerID: owner)
        let saved = try XCTUnwrap(windowLock.session)
        // Simulate a crash: the lock is in memory-less limbo, still saved.
        windowLock.endBecauseATLASIsQuitting()
        try time.store.setPreference(saved, for: WindowLockService.sessionKey)

        await windowLock.resume(ownerID: UUID())
        XCTAssertNil(windowLock.session, "another session: dropped")
        try time.store.setPreference(saved, for: WindowLockService.sessionKey)
        await windowLock.resume(ownerID: owner)
        XCTAssertEqual(windowLock.session?.id, saved.id)
    }

    func testWindowsAccessibilityCantReadComeFromTheWindowList() async throws {
        _ = windows.addWindow(chrome, app: "Chrome", title: "LeetCode")
        let listed = WindowInfo(id: WindowID("cg-7"), bundleID: "com.hnc.Discord", appName: "Discord", title: "workshop",
                                frame: .zero, displayID: nil)
        let duplicate = WindowInfo(id: WindowID("cg-8"), bundleID: chrome, appName: "Chrome", title: "LeetCode", frame: .zero, displayID: nil)
        windowLock.listedWindows = { [listed, duplicate] }
        let both = await windowLock.candidates()
        XCTAssertEqual(both.map(\.id.rawValue).sorted(), ["Chrome-0", "cg-7"], "apps Accessibility read aren't listed twice")
        windows.trusted = false
        let fallback = await windowLock.candidates()
        XCTAssertEqual(Set(fallback.map(\.title)), ["workshop", "LeetCode"], "without the permission, the window list still shows what's open")
    }

    func testOlderStudySettingsLoad() throws {
        let settings = try JSONDecoder().decode(StudyWindowLockSettings.self, from: Data("{}".utf8))
        XCTAssertEqual(settings, StudyWindowLockSettings())
    }
}
