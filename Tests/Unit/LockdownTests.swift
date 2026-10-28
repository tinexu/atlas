import XCTest
@testable import AtlasCore
@testable import AtlasSpaces

final class LockdownPolicyTests: XCTestCase {

    func testVerdicts() {
        let allowed = ["com.apple.Terminal"]
        XCTAssertEqual(LockdownPolicy.verdict(for: "com.apple.Terminal", allowed: allowed, ownBundleID: "atlas"), .allowed)
        XCTAssertEqual(LockdownPolicy.verdict(for: "atlas", allowed: allowed, ownBundleID: "atlas"), .allowed)
        XCTAssertEqual(LockdownPolicy.verdict(for: "com.apple.Safari", allowed: allowed, ownBundleID: "atlas"), .blocked)
        for essential in LockdownEssentials.apps {
            XCTAssertEqual(LockdownPolicy.verdict(for: essential.bundleID, allowed: [], ownBundleID: nil), .essential, essential.name)
        }
        XCTAssertEqual(LockdownPolicy.verdict(for: "com.apple.systempreferences.GeneralSettings", allowed: [], ownBundleID: nil), .essential)
    }

    func testExitGateCountsDownAndChecksThePhrase() {
        var settings = LockdownSettings()
        settings.exitCountdownSeconds = 10
        let opened = Date(timeIntervalSince1970: 1000)
        let gate = LockdownExitGate(openedAt: opened, settings: settings)
        XCTAssertEqual(gate.secondsLeft(at: opened), 10)
        XCTAssertFalse(gate.canConfirm(at: opened.addingTimeInterval(9.5), typed: ""))
        XCTAssertTrue(gate.canConfirm(at: opened.addingTimeInterval(10), typed: ""))

        settings.requiresPhrase = true
        let strict = LockdownExitGate(openedAt: opened, settings: settings)
        XCTAssertFalse(strict.canConfirm(at: opened.addingTimeInterval(20), typed: "done"))
        XCTAssertTrue(strict.canConfirm(at: opened.addingTimeInterval(20), typed: "  i'm DONE for now "))
    }

    func testOlderSettingsLoadWithTheirAppsAsOneMode() throws {
        let json = #"{"apps":[{"bundleID":"org.python.IDLE","name":"IDLE"}],"defaultMinutes":50,"exitCountdownSeconds":10,"isEnabled":true,"phrase":"x","pomodoro":{"focusMinutes":25,"longBreakEvery":4,"longBreakMinutes":15,"playsSounds":true,"shortBreakMinutes":5,"unlockDuringBreaks":false},"requiresPhrase":false}"#
        let settings = try JSONDecoder().decode(LockdownSettings.self, from: Data(json.utf8))
        XCTAssertTrue(settings.isEnabled)
        XCTAssertEqual(settings.defaultMinutes, 50)
        XCTAssertEqual(settings.modes.count, 1)
        XCTAssertEqual(settings.modes.first?.apps.map(\.bundleID), ["org.python.IDLE"])
        // And what's saved now reads back the same.
        let again = try JSONDecoder().decode(LockdownSettings.self, from: JSONEncoder().encode(LockdownSettings.codingLab))
        XCTAssertEqual(again, LockdownSettings.codingLab)
    }

    func testModeFallsBackToTheLastUsedThenTheFirst() {
        var settings = LockdownSettings.codingLab
        XCTAssertEqual(settings.mode(id: nil)?.name, "Vibe coding")
        settings.lastModeID = LockdownSettings.leetCode.id
        XCTAssertEqual(settings.mode(id: nil)?.name, "LeetCode")
        XCTAssertEqual(settings.mode(id: LockdownSettings.vibeCoding.id)?.name, "Vibe coding")
    }

    func testSummaryHeadline() {
        let summary = LockdownSummary(spaceName: "Coding Lab", focusedSeconds: 7200, blockedCounts: ["Safari": 5, "Messages": 2],
                                      skipped: [], hiddenAtStart: [], reason: .timer, endedAt: Date())
        XCTAssertEqual(summary.headline, "Lockdown complete — 2 h focused, blocked 7 attempts (Safari ×5, Messages ×2).")
    }
}

final class LockdownServiceTests: XCTestCase {
    private var time: TimeHarness!
    private var system: MockSystemAdapter { time.base.system }
    private var lockdown: LockdownService { time.time.lockdown }
    private let spaceID = UUID(), profileID = UUID()

    override func setUp() async throws {
        time = try TimeHarness()
        system.installedApps["com.apple.Safari"] = "Safari"
        system.installedApps["com.apple.MobileSMS"] = "Messages"
        system.installedApps["com.apple.finder"] = "Finder"
        system.installedApps["com.apple.systempreferences"] = "System Settings"
        lockdown.appFolders = []
    }

    private func settings(apps: [LockdownApp] = [LockdownApp(name: "Terminal", bundleID: "com.apple.Terminal")]) -> LockdownSettings {
        var settings = LockdownSettings()
        settings.isEnabled = true
        settings.modes = [LockdownMode(name: "Test", apps: apps)]
        return settings
    }

    @discardableResult
    private func start(minutes: Double = 120, settings: LockdownSettings? = nil) async -> LockdownSession? {
        let settings = settings ?? self.settings()
        return await lockdown.start(spaceID: spaceID, spaceName: "Coding Lab", profileID: profileID, minutes: minutes,
                                    settings: settings, plan: lockdown.plan(for: settings))
    }

    private func waitFor(_ call: String) async -> Bool {
        await time.base.waitUntil { self.system.calls.contains(call) }
    }

    func testStartHidesOthersButNeverQuitsAndLeavesAllowedAndEssentialsAlone() async throws {
        for app in ["com.apple.Safari", "com.apple.Terminal", "com.apple.finder", "com.apple.systempreferences"] { system.markRunning(app) }
        await start()
        let calls = system.calls
        XCTAssertTrue(calls.contains("hide:com.apple.Safari"))
        XCTAssertTrue(calls.contains("hide:com.apple.finder"), "Finder is tidied away at the start")
        XCTAssertFalse(calls.contains("hide:com.apple.Terminal"))
        XCTAssertFalse(calls.contains("hide:com.apple.systempreferences"))
        XCTAssertFalse(calls.contains { $0.hasPrefix("quit:") }, "apps already running are never quit")
        XCTAssertEqual(Set(lockdown.session?.hiddenAtStart ?? []), ["com.apple.Safari", "com.apple.finder"])
    }

    func testBlockedAppLaunchedDuringLockdownIsAskedToQuit() async throws {
        system.markRunning("com.apple.Terminal")
        await start()
        time.environment.activate("com.apple.Terminal", name: "Terminal")
        time.environment.launch("com.apple.Safari", name: "Safari")
        let ok1 = await waitFor("quit:com.apple.Safari")
        XCTAssertTrue(ok1)
        let ok2 = await waitFor("activate:com.apple.Terminal")
        XCTAssertTrue(ok2, "the last allowed app comes back to the front")
        XCTAssertFalse(system.calls.contains("hide:com.apple.Safari"))
    }

    func testAppThatRefusesToQuitIsHidden() async throws {
        system.refusesToQuit = true
        await start()
        time.environment.launch("com.apple.Safari", name: "Safari")
        let ok3 = await waitFor("hide:com.apple.Safari")
        XCTAssertTrue(ok3)
    }

    func testHiddenAppBroughtForwardIsHiddenAgain() async throws {
        system.markRunning("com.apple.MobileSMS")
        system.markRunning("com.apple.Terminal")
        await start()
        let before = system.calls.filter { $0 == "hide:com.apple.MobileSMS" }.count
        time.environment.activate("com.apple.MobileSMS", name: "Messages")
        let ok4 = await time.base.waitUntil { self.system.calls.filter { $0 == "hide:com.apple.MobileSMS" }.count == before + 1 }
        XCTAssertTrue(ok4)
        XCTAssertFalse(system.calls.contains("quit:com.apple.MobileSMS"), "a running app is never quit")
    }

    func testAppThatComesBackToTheFrontIsHiddenAgain() async throws {
        lockdown.recheckDelay = .milliseconds(20)
        system.markRunning("com.google.Chrome")
        system.markRunning("com.apple.Terminal")
        system.installedApps["com.google.Chrome"] = "Google Chrome"
        await start()
        let before = system.calls.filter { $0 == "hide:com.google.Chrome" }.count
        // Chrome reopens a window and stays in front after the first hide.
        system.activeBundleID = "com.google.Chrome"
        time.environment.activate("com.google.Chrome", name: "Google Chrome")
        let ok = await time.base.waitUntil { self.system.calls.filter { $0 == "hide:com.google.Chrome" }.count >= before + 3 }
        XCTAssertTrue(ok, "it keeps hiding it while it stays in front (a few tries)")
        XCTAssertEqual(lockdown.session?.blocked["com.google.Chrome"], 1, "still one attempt")
    }

    func testEssentialsAndAllowedAppsAreNeverTouched() async throws {
        await start()
        let before = system.calls.count
        time.environment.launch("com.apple.systempreferences", name: "System Settings")
        time.environment.activate("com.apple.Spotlight", name: "Spotlight")
        time.environment.launch("com.apple.Terminal", name: "Terminal")
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(system.calls.count, before)
        XCTAssertTrue(lockdown.session?.blocked.isEmpty ?? false)
    }

    func testAttemptsAreCountedOnceAndToastsThrottled() async throws {
        let toasts = Collector()
        _ = time.base.core.events.subscribe(AtlasEvent.Name.lockdownBlocked) { event in
            toasts.append(event.payload["toast"]?.stringValue ?? "")
        }
        await start()
        // A launch and the activation right after it are one attempt.
        time.environment.launch("com.apple.Safari", name: "Safari")
        time.environment.activate("com.apple.Safari", name: "Safari")
        let ok5 = await time.base.waitUntil { self.lockdown.session?.blocked["com.apple.Safari"] == 1 }
        XCTAssertTrue(ok5)
        time.environment.advance(by: 5)
        time.environment.activate("com.apple.Safari", name: "Safari")
        let ok6 = await time.base.waitUntil { self.lockdown.session?.blocked["com.apple.Safari"] == 2 }
        XCTAssertTrue(ok6)
        time.environment.advance(by: 5)
        time.environment.launch("com.apple.MobileSMS", name: "Messages")
        let ok7 = await time.base.waitUntil { self.lockdown.session?.blocked["com.apple.MobileSMS"] == 1 }
        XCTAssertTrue(ok7)

        let messages = toasts.values.filter { !$0.isEmpty }
        XCTAssertEqual(messages.count, 2, "Safari's second attempt was within the toast interval")
        XCTAssertTrue(messages[0].hasPrefix("Safari is locked until "))
        XCTAssertTrue(messages[0].hasSuffix("— 2 h left."))

        let summary = try XCTUnwrap(lockdown.end())
        XCTAssertEqual(summary.blockedCounts, ["Safari": 2, "Messages": 1])
        XCTAssertTrue(summary.headline.contains("blocked 3 attempts (Safari ×2, Messages ×1)"))
    }

    func testAddingAndRemovingTime() async throws {
        let started = await start(minutes: 60)
        let session = try XCTUnwrap(started)
        lockdown.addTime(minutes: 30)
        XCTAssertEqual(lockdown.session?.endsAt, session.endsAt.addingTimeInterval(1800))
        lockdown.removeTime(minutes: 45)
        XCTAssertEqual(lockdown.session?.endsAt, session.endsAt.addingTimeInterval(-900))
        // Removing more than is left keeps a minute; it never ends lockdown by itself.
        lockdown.removeTime(minutes: 600)
        XCTAssertEqual(lockdown.session?.endsAt, time.environment.now().addingTimeInterval(60))
        XCTAssertTrue(lockdown.isActive)
    }

    func testTimerEndsLockdownAndStopsEnforcing() async throws {
        await start(minutes: 30)
        time.environment.advance(by: 30 * 60)
        time.environment.fireDueSchedules()
        XCTAssertFalse(lockdown.isActive)
        XCTAssertEqual(lockdown.lastSummary?.reason, .timer)
        let ok8 = await waitFor("notify:Lockdown complete")
        XCTAssertTrue(ok8)
        time.environment.launch("com.apple.Safari", name: "Safari")
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertFalse(system.calls.contains("quit:com.apple.Safari"))
    }

    func testEndingEarlyRecordsOneRunWithTheBlockedAttempts() async throws {
        await start()
        time.environment.launch("com.apple.Safari", name: "Safari")
        let ok9 = await waitFor("quit:com.apple.Safari")
        XCTAssertTrue(ok9)
        let summary = try XCTUnwrap(lockdown.end(early: true))
        XCTAssertEqual(summary.reason, .early)
        let runs = try time.store.runs(limit: 20).filter { $0.trigger == LockdownService.trigger }
        XCTAssertEqual(runs.count, 1)
        XCTAssertEqual(runs.first?.state, .succeeded)
        XCTAssertTrue(runs.first?.steps.contains { $0.label == "Blocked Safari ×1" } ?? false)
    }

    func testQuittingATLASEndsLockdownImmediately() async throws {
        await start()
        lockdown.endBecauseATLASIsQuitting()
        XCTAssertFalse(lockdown.isActive)
        XCTAssertNil(try time.store.preference(LockdownService.sessionKey, as: LockdownSession.self))
        XCTAssertEqual(lockdown.lastSummary?.reason, .quit)
    }

    /// A fresh service on the same store, as after a crash and relaunch.
    private func relaunch() -> LockdownService {
        let focus = FocusService(store: time.store, events: time.base.core.events, environment: time.environment, engine: time.base.core.engine)
        let service = LockdownService(store: time.store, events: time.base.core.events, environment: time.environment,
                                      engine: time.base.core.engine, system: system, focus: focus)
        service.load()
        focus.restore()
        return service
    }

    func testResumesAfterRelaunchWithTimeLeft() async throws {
        await start(minutes: 60)
        time.environment.advance(by: 10 * 60)
        system.markRunning("com.apple.MobileSMS")
        let relaunched = relaunch()
        await relaunched.resume()
        XCTAssertTrue(relaunched.isActive)
        XCTAssertTrue(system.calls.contains("hide:com.apple.MobileSMS"), "enforcement resumes")
        time.environment.launch("com.apple.Safari", name: "Safari")
        let ok10 = await waitFor("quit:com.apple.Safari")
        XCTAssertTrue(ok10)
    }

    func testEndsCleanlyAfterRelaunchWithNoTimeLeft() async throws {
        await start(minutes: 30)
        time.environment.advance(by: 45 * 60)
        let relaunched = relaunch()
        await relaunched.resume()
        XCTAssertFalse(relaunched.isActive)
        XCTAssertEqual(relaunched.lastSummary?.reason, .expiredWhileClosed)
        XCTAssertNil(try time.store.preference(LockdownService.sessionKey, as: LockdownSession.self))
    }

    func testMissingAllowedAppIsSkippedAndReported() async throws {
        let settings = settings(apps: [LockdownApp(name: "Terminal", bundleID: "com.apple.Terminal"),
                                       LockdownApp(name: "Obsidian", bundleID: "md.obsidian"), .claude])
        let plan = lockdown.plan(for: settings)
        XCTAssertEqual(plan.apps.map(\.bundleID), ["com.apple.Terminal"])
        XCTAssertEqual(plan.missing, ["Obsidian", "Claude"])
        await start(settings: settings)
        XCTAssertEqual(lockdown.end()?.skipped, ["Obsidian", "Claude"])
        XCTAssertTrue(lockdown.lastSummary?.headline.contains("Not installed: Obsidian, Claude") ?? false)
    }

    func testAModesPageKeepsItsBrowserAllowed() {
        system.installedApps["com.google.Chrome"] = "Google Chrome"
        system.installedApps["org.python.IDLE"] = "IDLE"
        let plan = lockdown.plan(for: .codingLab, modeID: LockdownSettings.leetCode.id)
        XCTAssertEqual(plan.modeName, "LeetCode")
        XCTAssertEqual(plan.apps.map(\.bundleID), ["org.python.IDLE", "com.google.Chrome"])
        XCTAssertEqual(plan.links.map(\.host), ["leetcode.com"])
        XCTAssertEqual(plan.missing, ["Spotify"])

        system.installedApps["com.google.Chrome"] = nil
        XCTAssertEqual(lockdown.plan(for: .codingLab, modeID: LockdownSettings.leetCode.id).missing,
                       ["Spotify", "Google Chrome (for leetcode.com)"])
    }

    func testClaudeResolvesToTheDesktopAppWhenInstalled() {
        system.installedApps[LockdownApp.claudeDesktopBundleID] = "Claude"
        XCTAssertEqual(lockdown.resolveClaude()?.bundleID, LockdownApp.claudeDesktopBundleID)
    }

    func testPomodoroMovesToABreakOnTheFocusTimerWithoutItsOwnWrapUp() async throws {
        await start(minutes: 120)
        XCTAssertEqual(time.time.focus.session?.title, "Lockdown · Focus")
        time.environment.advance(by: 25 * 60)
        time.environment.fireDueSchedules()
        XCTAssertEqual(lockdown.session?.phase.kind, .shortBreak)
        XCTAssertEqual(lockdown.session?.phase.completedFocus, 1)
        XCTAssertEqual(time.time.focus.session?.title, "Lockdown · Short break")
        let ok11 = await waitFor("notify:Break time")
        XCTAssertTrue(ok11)
        XCTAssertFalse(system.calls.contains { $0.hasPrefix("notify:Lockdown · Focus") }, "no separate focus-timer notification")
        // Breaks stay locked by default.
        time.environment.launch("com.apple.Safari", name: "Safari")
        let ok12 = await waitFor("quit:com.apple.Safari")
        XCTAssertTrue(ok12)
    }

    func testUnlockDuringBreaksLetsAppsOpen() async throws {
        var settings = settings()
        settings.pomodoro.unlockDuringBreaks = true
        await start(minutes: 120, settings: settings)
        lockdown.skipPhase()
        XCTAssertEqual(lockdown.session?.phase.kind, .shortBreak)
        time.environment.launch("com.apple.Safari", name: "Safari")
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertFalse(system.calls.contains("quit:com.apple.Safari"))
        lockdown.skipPhase()
        XCTAssertEqual(lockdown.session?.phase.kind, .focus)
    }

    func testLongBreakEveryFourth() async throws {
        await start(minutes: 600)
        var kinds: [LockdownSession.Phase.Kind] = []
        for _ in 0..<8 {
            lockdown.skipPhase()
            kinds.append(lockdown.session?.phase.kind ?? .focus)
        }
        XCTAssertEqual(kinds, [.shortBreak, .focus, .shortBreak, .focus, .shortBreak, .focus, .longBreak, .focus])
    }

    func testWakeEndsAnExpiredLockdown() async throws {
        await start(minutes: 30)
        time.environment.advance(by: 31 * 60)
        time.environment.wake()
        let ok13 = await time.base.waitUntil { !self.lockdown.isActive }
        XCTAssertTrue(ok13)
    }

    func testBringBackHiddenApps() async throws {
        system.markRunning("com.apple.Safari")
        await start()
        lockdown.end()
        await lockdown.bringBackHiddenApps()
        XCTAssertTrue(system.calls.contains("unhide:com.apple.Safari"))
        XCTAssertEqual(lockdown.lastSummary?.hiddenAtStart, [])
    }
}

final class LockdownActivationTests: XCTestCase {

    func testEnteringWithLockdownOpensAllowedAppsAndBlocksSwitchingSpaces() async throws {
        let h = try SpacesHarness()
        let environment = h.base.startTriggers()
        let time = h.core.startScheduling(environment: environment, calendarStore: MockCalendarStore(), calendar: TimeHarness.utc)
        h.system.installedApps["md.obsidian"] = "Obsidian"
        let lab = try h.makeSpace("Coding Lab", steps: [.launch("com.apple.Terminal")])
        let other = try h.makeSpace("Study", steps: [.launch("com.apple.Notes")])
        var settings = LockdownSettings.codingLab
        settings.isEnabled = true
        time.lockdown.setSettings(settings, forProfile: lab.profile.id)
        time.lockdown.appFolders = []

        let activation = try await h.activator.activate(spaceID: lab.space.id, profileID: lab.profile.id, lockdownMinutes: 120)
        XCTAssertEqual(activation.run.state, .succeeded)
        XCTAssertTrue(h.system.calls.contains("launch:md.obsidian"))
        XCTAssertEqual(h.system.calls.filter { $0 == "launch:com.apple.Terminal" }.count, 1, "not opened twice")
        let session = try XCTUnwrap(time.lockdown.session)
        XCTAssertEqual(Set(session.skipped), ["Cursor", "Spotify", "Claude"])

        do {
            _ = try await h.activator.activate(spaceID: other.space.id)
            XCTFail("switching Spaces should be blocked")
        } catch SpaceActivationError.lockedDown(let name, _) {
            XCTAssertEqual(name, "Coding Lab")
        }
        time.lockdown.end()
        _ = try await h.activator.activate(spaceID: other.space.id)
    }

    func testLeetCodeModeOpensIDLEAndTheProblemSetInChrome() async throws {
        let h = try SpacesHarness()
        let environment = h.base.startTriggers()
        let time = h.core.startScheduling(environment: environment, calendarStore: MockCalendarStore(), calendar: TimeHarness.utc)
        h.system.installedApps["org.python.IDLE"] = "IDLE"
        h.system.installedApps["com.google.Chrome"] = "Google Chrome"
        h.system.installedApps["com.todesktop.230313mzl4w4u92"] = "Cursor"
        let lab = try h.makeSpace("Coding Lab", steps: [.launch("com.apple.Terminal")])
        time.lockdown.setSettings(.codingLab, forProfile: lab.profile.id)

        _ = try await h.activator.activate(spaceID: lab.space.id, profileID: lab.profile.id, lockdownMinutes: 60,
                                           lockdownModeID: LockdownSettings.leetCode.id)
        let calls = h.system.calls
        XCTAssertTrue(calls.contains("launch:org.python.IDLE"))
        XCTAssertTrue(calls.contains("open-url:https://leetcode.com/problemset/"))
        XCTAssertFalse(calls.contains("launch:com.todesktop.230313mzl4w4u92"), "vibe-coding apps stay closed")
        let session = try XCTUnwrap(time.lockdown.session)
        XCTAssertEqual(session.modeName, "LeetCode")
        XCTAssertTrue(session.allowed.contains("com.google.Chrome"))
        XCTAssertFalse(session.allowed.contains("com.todesktop.230313mzl4w4u92"))
        time.lockdown.end()
    }

    func testCodingLabsGetLockdownTurnedOnOnce() throws {
        let h = try SpacesHarness()
        let space = try h.library.createSpace(from: SpaceTemplates.codingLab)
        let profile = try XCTUnwrap(h.store.profiles(spaceID: space.id).first(where: \.isDefault))
        let key = LockdownService.settingsKey(profileID: profile.id)
        let settings = try XCTUnwrap(h.store.preference(key, as: LockdownSettings.self))
        XCTAssertTrue(settings.isEnabled)
        XCTAssertEqual(settings.modes.map(\.name), ["Vibe coding", "LeetCode"])
        XCTAssertEqual(settings.modes[0].apps.map(\.name), ["Cursor", "Obsidian", "Spotify", "Terminal", "Claude"])
        XCTAssertFalse(settings.modes[0].apps.contains { $0.name == "IDLE" })

        var changed = settings
        changed.isEnabled = false
        try h.store.setPreference(changed, for: key)
        try h.library.upgradeDioramaRooms()
        XCTAssertEqual(try h.store.preference(key, as: LockdownSettings.self)?.isEnabled, false, "your changes stay")
    }
}

private final class Collector: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []
    func append(_ value: String) { lock.withLock { items.append(value) } }
    var values: [String] { lock.withLock { items } }
}
