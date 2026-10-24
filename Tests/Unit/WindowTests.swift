import XCTest
@testable import AtlasCore
@testable import AtlasSpaces

// MARK: - Coordinates

final class ScreenCoordinateTests: XCTestCase {
    // A 1440×900 primary display.
    let primaryHeight: CGFloat = 900

    func testSingleDisplayFlipsY() {
        // A window 100 pt below the top of the screen, in AppKit terms.
        let appKit = CGRect(x: 100, y: 600, width: 400, height: 200)
        let ax = ScreenCoordinates.axRect(fromAppKit: appKit, primaryHeight: primaryHeight)
        XCTAssertEqual(ax, CGRect(x: 100, y: 100, width: 400, height: 200))
        XCTAssertEqual(ScreenCoordinates.axRect(fromAppKit: CGRect(x: 0, y: 0, width: 1440, height: 900), primaryHeight: primaryHeight),
                       CGRect(x: 0, y: 0, width: 1440, height: 900))
    }

    func testDisplayLeftOfMainKeepsNegativeX() {
        // 1920×1080 to the left, bottoms aligned.
        let appKit = CGRect(x: -1920, y: 0, width: 1920, height: 1080)
        let ax = ScreenCoordinates.axRect(fromAppKit: appKit, primaryHeight: primaryHeight)
        XCTAssertEqual(ax, CGRect(x: -1920, y: -180, width: 1920, height: 1080))
    }

    func testDisplayAboveMainHasNegativeAXY() {
        let appKit = CGRect(x: 0, y: 900, width: 2560, height: 1440)
        let ax = ScreenCoordinates.axRect(fromAppKit: appKit, primaryHeight: primaryHeight)
        XCTAssertEqual(ax, CGRect(x: 0, y: -1440, width: 2560, height: 1440))
    }

    func testDisplayBelowMain() {
        let appKit = CGRect(x: 200, y: -1080, width: 1920, height: 1080)
        let ax = ScreenCoordinates.axRect(fromAppKit: appKit, primaryHeight: primaryHeight)
        XCTAssertEqual(ax, CGRect(x: 200, y: 900, width: 1920, height: 1080))
    }

    func testRoundTripsAndPoints() {
        let rects = [
            CGRect(x: -1920, y: 0, width: 1920, height: 1080),
            CGRect(x: 0, y: 900, width: 2560, height: 1440),
            CGRect(x: 37, y: 412, width: 801, height: 333),
        ]
        for rect in rects {
            let ax = ScreenCoordinates.axRect(fromAppKit: rect, primaryHeight: primaryHeight)
            XCTAssertEqual(ScreenCoordinates.appKitRect(fromAX: ax, primaryHeight: primaryHeight), rect)
        }
        XCTAssertEqual(ScreenCoordinates.axPoint(fromAppKit: CGPoint(x: 5, y: 890), primaryHeight: primaryHeight), CGPoint(x: 5, y: 10))
        XCTAssertEqual(ScreenCoordinates.appKitPoint(fromAX: CGPoint(x: 5, y: 10), primaryHeight: primaryHeight), CGPoint(x: 5, y: 890))
    }
}

// MARK: - Resolver

final class LayoutResolverTests: XCTestCase {
    let builtIn = MockWindowAdapter.builtIn
    let external = MockWindowAdapter.external

    private func window(_ app: String, _ title: String = "", id: String? = nil, z: Int = 0, frame: CGRect = CGRect(x: 50, y: 60, width: 500, height: 400),
                        displayID: String? = "BUILTIN", minimized: Bool = false, fullScreen: Bool = false,
                        movable: Bool = true, resizable: Bool = true) -> WindowInfo {
        WindowInfo(id: WindowID(id ?? "\(app)-\(title)-\(z)"), bundleID: "com.test.\(app)", appName: app, title: title,
                   frame: frame, displayID: displayID, isMinimized: minimized, isFullScreen: fullScreen,
                   isMovable: movable, isResizable: resizable, zIndex: z)
    }

    private func rule(_ app: String, _ preset: WindowPreset, display: DisplayTarget = .main, title: TitleMatch? = nil, z: Int = 0) -> WindowRule {
        WindowRule(bundleID: "com.test.\(app)", appName: app, titleMatch: title, display: display, frame: preset.rect, zOrder: z)
    }

    private func plan(_ rules: [WindowRule], _ windows: [WindowInfo], displays: [DisplayInfo]? = nil,
                      running: Set<String>? = nil) -> PlacementPlan {
        LayoutResolver.plan(rules: rules, displays: displays ?? [builtIn], windows: windows,
                            runningBundleIDs: running ?? Set(windows.map(\.bundleID)))
    }

    func testFractionsBecomeFramesInsideTheVisibleFrame() {
        let result = plan([rule("Terminal", .leftHalf), rule("Safari", .rightHalf, display: .display(id: "EXTERNAL", name: "Studio"))],
                          [window("Terminal"), window("Safari")], displays: [builtIn, external])

        XCTAssertEqual(result.placements.count, 2)
        let terminal = result.placements.first { $0.appName == "Terminal" }
        let safari = result.placements.first { $0.appName == "Safari" }
        // Below the 25 pt menu bar, half of 1440 wide.
        XCTAssertEqual(terminal?.frame, CGRect(x: 0, y: 25, width: 720, height: 875))
        XCTAssertEqual(safari?.frame, CGRect(x: 2720, y: -200, width: 1280, height: 1440))
        XCTAssertEqual(safari?.displayID, "EXTERNAL")
        XCTAssertNil(safari?.note)
    }

    func testTitleRulesBeatBundleOnlyRules() {
        // The bundle-only rule comes first, but the title rule still gets its window.
        let rules = [rule("Safari", .leftHalf), rule("Safari", .rightHalf, title: .contains("docs"))]
        let windows = [window("Safari", "Swift Docs", z: 0), window("Safari", "Inbox", z: 1)]

        let result = plan(rules, windows)

        let docs = result.placements.first { $0.title == "Swift Docs" }
        let inbox = result.placements.first { $0.title == "Inbox" }
        XCTAssertEqual(docs?.frame.minX, 720, "Title rule wins its window")
        XCTAssertEqual(inbox?.frame.minX, 0)
        XCTAssertEqual(Set(result.placements.map(\.windowID)).count, 2, "Each window placed once")
    }

    func testRegexTitleMatch() {
        let rules = [rule("Terminal", .rightThird, title: .regex("^ssh .*prod$"))]
        let result = plan(rules, [window("Terminal", "zsh", z: 0), window("Terminal", "ssh deploy@prod", z: 1)])
        XCTAssertEqual(result.placements.map(\.title), ["ssh deploy@prod"])
    }

    func testExtraWindowsOfTheSameAppCascade() {
        let windows = [window("Terminal", "a", z: 0), window("Terminal", "b", z: 1), window("Terminal", "c", z: 2)]

        let result = plan([rule("Terminal", .centered)], windows)

        let frames = result.placements.map(\.frame)
        XCTAssertEqual(frames.count, 3)
        XCTAssertEqual(frames[1].minX - frames[0].minX, LayoutResolver.cascadeStep)
        XCTAssertEqual(frames[1].minY - frames[0].minY, LayoutResolver.cascadeStep)
        XCTAssertEqual(frames[2].minX - frames[0].minX, LayoutResolver.cascadeStep * 2)
        XCTAssertEqual(Set(result.placements.map(\.windowID)).count, 3)
    }

    func testTitleRuleWithNoMatchIsSkippedWithReason() {
        let result = plan([rule("Safari", .leftHalf, title: .contains("Jira"))], [window("Safari", "Inbox")])

        XCTAssertTrue(result.placements.isEmpty)
        XCTAssertEqual(result.skipped.count, 1)
        XCTAssertTrue(result.skipped[0].reason.contains("Jira"))
    }

    func testMissingDisplayFallsBackToMainKeepingRelativePosition() {
        let gone = DisplayTarget.display(id: "EXTERNAL", name: "Studio Display")
        let result = plan([rule("Safari", .rightHalf, display: gone)], [window("Safari")])

        let placement = try? XCTUnwrap(result.placements.first)
        XCTAssertEqual(placement?.displayID, "BUILTIN")
        XCTAssertEqual(placement?.frame, CGRect(x: 720, y: 25, width: 720, height: 875), "Same fractions on the main display")
        XCTAssertTrue(placement?.note?.contains("Studio Display isn't connected") ?? false)
    }

    func testSecondaryWithoutSecondDisplayUsesMain() {
        let result = plan([rule("Notes", .leftThird, display: .secondary)], [window("Notes")])
        XCTAssertEqual(result.placements.first?.displayID, "BUILTIN")
        XCTAssertNotNil(result.placements.first?.note)

        let two = plan([rule("Notes", .leftThird, display: .secondary)], [window("Notes")], displays: [builtIn, external])
        XCTAssertEqual(two.placements.first?.displayID, "EXTERNAL")
    }

    func testSameAsBeforeKeepsTheCurrentDisplay() {
        let onExternal = window("Notes", frame: CGRect(x: 2000, y: 100, width: 400, height: 300), displayID: "EXTERNAL")
        let result = plan([rule("Notes", .leftHalf, display: .sameAsBefore)], [onExternal], displays: [builtIn, external])
        XCTAssertEqual(result.placements.first?.frame.minX, 1440)
    }

    func testFramesAreClampedToTheVisibleFrame() {
        var oversized = rule("Terminal", .full)
        oversized.frame = FractionalRect(x: 0.8, y: 0.9, width: 0.6, height: 1.4)

        let result = plan([oversized], [window("Terminal")])

        let frame = try? XCTUnwrap(result.placements.first?.frame)
        XCTAssertNotNil(frame)
        XCTAssertTrue(builtIn.visibleFrame.contains(frame!), "Never off-screen: \(frame!)")
        XCTAssertEqual(LayoutResolver.clamp(CGRect(x: -500, y: -500, width: 100, height: 100), to: builtIn.visibleFrame),
                       CGRect(x: 0, y: 25, width: 100, height: 100))
        XCTAssertEqual(LayoutResolver.clamp(CGRect(x: 5000, y: 5000, width: 3000, height: 3000), to: builtIn.visibleFrame),
                       builtIn.visibleFrame)
    }

    func testCascadeNeverPushesWindowsOffScreen() {
        let windows = (0..<20).map { window("Terminal", "w\($0)", z: $0) }
        let result = plan([rule("Terminal", .rightHalf)], windows)
        for placement in result.placements {
            XCTAssertTrue(builtIn.visibleFrame.contains(placement.frame), "\(placement.frame)")
        }
    }

    func testFullScreenAndImmovableWindowsAreSkipped() {
        let result = plan(
            [rule("Notes", .leftHalf), rule("Prefs", .rightHalf)],
            [window("Notes", fullScreen: true), window("Prefs", movable: false)]
        )

        XCTAssertTrue(result.placements.isEmpty)
        XCTAssertEqual(result.skipped.map(\.message).sorted(), [
            "Couldn't move Notes: the window is in full screen",
            "Couldn't move Prefs: the app doesn't let its window be moved",
        ])
    }

    func testFixedSizeWindowsMoveButKeepTheirSize() {
        let fixed = window("Calculator", frame: CGRect(x: 600, y: 300, width: 230, height: 400), resizable: false)
        let result = plan([rule("Calculator", .rightHalf)], [fixed])

        XCTAssertEqual(result.placements.first?.frame, CGRect(x: 720, y: 25, width: 230, height: 400))
        XCTAssertNotNil(result.placements.first?.note)
    }

    func testAppsNotRunningOrWithoutWindowsAreReported() {
        let result = plan([rule("Notes", .leftHalf), rule("Safari", .rightHalf), rule("Notes", .full)], [],
                          running: ["com.test.Safari"])

        XCTAssertEqual(result.appsToLaunch, ["com.test.Notes"], "Listed once")
        XCTAssertEqual(result.appsWithoutWindows, ["com.test.Safari"])
    }

    func testMinimizedWindowsAreRestoredUnlessTheRuleMinimizes() {
        var keepMinimized = rule("Mail", .leftHalf)
        keepMinimized.state = .minimized
        let result = plan([rule("Notes", .leftHalf), keepMinimized],
                          [window("Notes", minimized: true), window("Mail", minimized: true)])

        XCTAssertEqual(result.placements.first { $0.appName == "Notes" }?.needsUnminimize, true)
        XCTAssertEqual(result.placements.first { $0.appName == "Mail" }?.needsUnminimize, false)
    }

    func testNoDisplaysSkipsEverything() {
        let result = plan([rule("Notes", .leftHalf)], [window("Notes")], displays: [])
        XCTAssertTrue(result.placements.isEmpty)
        XCTAssertEqual(result.skipped.count, 1)
    }

    func testPresetsAndFractionsRoundTrip() {
        for preset in WindowPreset.allCases {
            let absolute = preset.rect.absolute(in: builtIn.visibleFrame)
            let back = FractionalRect(absolute, in: builtIn.visibleFrame)
            XCTAssertEqual(WindowPreset.matching(back), preset == .full ? .full : WindowPreset.matching(preset.rect))
        }
        XCTAssertEqual(WindowPreset(loose: "Right half"), .rightHalf)
        XCTAssertEqual(WindowPreset(loose: "lefttwothirds"), .leftTwoThirds)
        XCTAssertNil(WindowPreset(loose: "diagonal"))
    }

    func testDisplayProfileIDIsStable() {
        let a = DisplayProfile(displays: [builtIn, external])
        let b = DisplayProfile(displays: [external, builtIn])
        XCTAssertEqual(a.id, b.id)
        XCTAssertNotEqual(a.id, DisplayProfile(displays: [builtIn]).id)
        XCTAssertTrue(a.matches([external, builtIn]))
        XCTAssertEqual(a.name, "Built-in Display + Studio Display")
    }
}

// MARK: - Engine & service

final class WindowEngineTests: XCTestCase {
    let terminal = "com.apple.Terminal"
    let notes = "com.apple.Notes"
    let music = "com.apple.Music"

    private func layout(_ h: TestHarness, _ rules: [WindowRule], name: String = "Programming") throws -> WindowLayout {
        let layout = WindowLayout(name: name, rules: rules)
        try h.store.saveWindowLayout(layout)
        return layout
    }

    func testApplyLayoutReportsPartialResultsHonestly() async throws {
        let h = try TestHarness()
        h.system.markRunning(terminal)
        h.system.markRunning(notes)
        h.system.markRunning(music)
        h.windows.addWindow(terminal, app: "Terminal", title: "zsh")
        h.windows.addWindow(notes, app: "Notes")
        h.windows.addWindow(music, app: "Music", fullScreen: true)
        try layout(h, [
            WindowRule(bundleID: terminal, appName: "Terminal", preset: .leftHalf),
            WindowRule(bundleID: notes, appName: "Notes", preset: .rightHalf),
            WindowRule(bundleID: music, appName: "Music", preset: .centered),
        ])

        let run = await h.engine.invoke(ApplyWindowLayoutAction.id, parameters: ["layout": "programming"], source: "shortcut")

        XCTAssertEqual(run.state, .partiallySucceeded, "Placed 2 of 3 is not a success")
        let step = try XCTUnwrap(run.steps.first)
        XCTAssertEqual(step.state, .partiallySucceeded)
        XCTAssertEqual(step.message, "Placed 2 of 3 windows")
        XCTAssertEqual(step.output["placed"], .number(2))
        XCTAssertEqual(step.output["skipped"], .number(1))
        XCTAssertTrue(step.error?.contains("Couldn't move Music: the window is in full screen") ?? false, step.error ?? "")
        let details = step.output["details"]?.stringValue ?? ""
        XCTAssertTrue(details.contains("Placed Terminal (“zsh”) on Built-in Display"), details)
        XCTAssertTrue(details.contains("Couldn't move Music"), details)
        XCTAssertTrue(h.windows.calls.contains("frame:Terminal:0,25,720,875"))
        XCTAssertTrue(h.windows.calls.contains("frame:Notes:720,25,720,875"))
        XCTAssertFalse(h.windows.calls.contains { $0.hasPrefix("frame:Music") })

        // History keeps the details.
        let stored = try XCTUnwrap(try h.store.run(id: run.id))
        XCTAssertEqual(stored.state, .partiallySucceeded)
        XCTAssertEqual(stored.steps.first?.output["details"], step.output["details"])
    }

    func testFullSuccessIsSucceeded() async throws {
        let h = try TestHarness()
        h.system.markRunning(terminal)
        h.windows.addWindow(terminal, app: "Terminal")
        try layout(h, [WindowRule(bundleID: terminal, appName: "Terminal", preset: .rightHalf)])

        let run = await h.engine.invoke(ApplyWindowLayoutAction.id, parameters: ["layout": "Programming"], source: "manual")

        XCTAssertEqual(run.state, .succeeded)
        XCTAssertEqual(run.steps.first?.message, "Placed 1 of 1 window")
    }

    func testNothingPlacedIsAFailure() async throws {
        let h = try TestHarness()
        h.system.markRunning(notes)
        h.windows.addWindow(notes, app: "Notes", fullScreen: true)
        try layout(h, [WindowRule(bundleID: notes, appName: "Notes", preset: .rightHalf)])

        let run = await h.engine.invoke(ApplyWindowLayoutAction.id, parameters: ["layout": "Programming"], source: "manual")

        XCTAssertEqual(run.state, .failed)
        XCTAssertTrue(run.steps.first?.error?.contains("Placed 0 of 1 window") ?? false)
    }

    func testMissingAccessibilityFailsWithoutTouchingWindowsOrPrompting() async throws {
        let provider = MockPermissionProvider(statuses: [.accessibility: .notDetermined])
        let h = try TestHarness(permissions: provider)
        h.system.markRunning(terminal)
        h.windows.addWindow(terminal, app: "Terminal")
        try layout(h, [WindowRule(bundleID: terminal, appName: "Terminal", preset: .rightHalf)])

        let run = await h.engine.invoke(ApplyWindowLayoutAction.id, parameters: ["layout": "Programming"], source: "manual")

        XCTAssertEqual(run.state, .failed)
        XCTAssertTrue(run.steps.first?.error?.contains("Accessibility") ?? false, run.steps.first?.error ?? "")
        XCTAssertTrue(h.windows.calls.isEmpty, "Windows untouched: \(h.windows.calls)")
        XCTAssertEqual(provider.requestCount, 0, "The engine doesn't pop the system prompt mid-run")
    }

    func testAdapterLosingTrustFailsCleanly() async throws {
        let h = try TestHarness()
        h.system.markRunning(terminal)
        h.windows.addWindow(terminal, app: "Terminal")
        h.windows.trusted = false
        try layout(h, [WindowRule(bundleID: terminal, appName: "Terminal", preset: .rightHalf)])

        let run = await h.engine.invoke(ApplyWindowLayoutAction.id, parameters: ["layout": "Programming"], source: "manual")

        XCTAssertEqual(run.state, .failed)
        XCTAssertTrue(run.steps.first?.error?.contains("Accessibility permission") ?? false)
        XCTAssertTrue(h.windows.mutatingCalls.isEmpty)
    }

    func testPermissionRevokedMidRunStopsAndReports() async throws {
        let h = try TestHarness()
        for (bundleID, app) in [(terminal, "Terminal"), (notes, "Notes"), (music, "Music")] {
            h.system.markRunning(bundleID)
            h.windows.addWindow(bundleID, app: app)
        }
        h.windows.revokeAfter(moves: 1)
        try layout(h, [
            WindowRule(bundleID: terminal, appName: "Terminal", preset: .leftThird),
            WindowRule(bundleID: notes, appName: "Notes", preset: .centerThird),
            WindowRule(bundleID: music, appName: "Music", preset: .rightThird),
        ])

        let run = await h.engine.invoke(ApplyWindowLayoutAction.id, parameters: ["layout": "Programming"], source: "manual")

        XCTAssertEqual(run.state, .partiallySucceeded)
        XCTAssertEqual(run.steps.first?.output["placed"], .number(1))
        XCTAssertEqual(run.steps.first?.output["skipped"], .number(2))
        XCTAssertTrue(run.steps.first?.error?.contains("turned off") ?? false)
    }

    func testAppsNotRunningAreLaunchedFirstThenPlaced() async throws {
        let h = try TestHarness()
        h.windows.addWindow(notes, app: "Notes", untilLaunched: true)
        try layout(h, [WindowRule(bundleID: notes, appName: "Notes", preset: .leftHalf)])

        let run = await h.engine.invoke(ApplyWindowLayoutAction.id, parameters: ["layout": "Programming"], source: "manual")

        XCTAssertEqual(run.state, .succeeded, run.steps.first?.error ?? "")
        XCTAssertEqual(h.system.calls, ["launch:com.apple.Notes"])
        XCTAssertTrue(h.windows.calls.contains("frame:Notes:0,25,720,875"))
        XCTAssertEqual(run.steps.first?.output["launched"], .number(1))
        XCTAssertTrue(run.steps.first?.output["details"]?.stringValue?.hasPrefix("Opened Notes") ?? false)
    }

    func testAppThatCantOpenIsSkippedAndOthersStillPlaced() async throws {
        let h = try TestHarness()
        h.system.markRunning(terminal)
        h.windows.addWindow(terminal, app: "Terminal")
        try layout(h, [
            WindowRule(bundleID: "com.example.Missing", appName: "Missing", preset: .leftHalf),
            WindowRule(bundleID: terminal, appName: "Terminal", preset: .rightHalf),
        ])

        let run = await h.engine.invoke(ApplyWindowLayoutAction.id, parameters: ["layout": "Programming"], source: "manual")

        XCTAssertEqual(run.state, .partiallySucceeded)
        XCTAssertTrue(run.steps.first?.error?.contains("Couldn't move Missing: ATLAS couldn't open it") ?? false,
                      run.steps.first?.error ?? "")
    }

    func testDisabledLaunchActionIsRespected() async throws {
        let h = try TestHarness()
        try h.core.permissions.setEnabled(false, for: LaunchApplicationAction.id)
        h.windows.addWindow(notes, app: "Notes", untilLaunched: true)
        try layout(h, [WindowRule(bundleID: notes, appName: "Notes", preset: .leftHalf)])

        let run = await h.engine.invoke(ApplyWindowLayoutAction.id, parameters: ["layout": "Programming"], source: "manual")

        XCTAssertEqual(run.state, .failed)
        XCTAssertTrue(h.system.calls.isEmpty)
    }

    func testWindowThatSnapsBackIsNotCountedAsPlaced() async throws {
        let h = try TestHarness()
        h.system.markRunning(terminal)
        h.windows.addWindow(terminal, app: "Terminal")
        h.windows.refusesToMove = ["Terminal"]
        try layout(h, [WindowRule(bundleID: terminal, appName: "Terminal", preset: .rightHalf)])

        let run = await h.engine.invoke(ApplyWindowLayoutAction.id, parameters: ["layout": "Programming"], source: "manual")

        XCTAssertEqual(run.state, .failed)
        XCTAssertTrue(run.steps.first?.error?.contains("didn't accept the new position") ?? false)
    }

    func testMinimizeAndHideStates() async throws {
        let h = try TestHarness()
        h.system.markRunning(terminal)
        h.system.markRunning(music)
        h.windows.addWindow(terminal, app: "Terminal")
        h.windows.addWindow(music, app: "Music")
        var minimized = WindowRule(bundleID: terminal, appName: "Terminal", preset: .leftHalf)
        minimized.state = .minimized
        var hidden = WindowRule(bundleID: music, appName: "Music", preset: .rightHalf)
        hidden.state = .hidden
        try layout(h, [minimized, hidden])

        let run = await h.engine.invoke(ApplyWindowLayoutAction.id, parameters: ["layout": "Programming"], source: "manual")

        XCTAssertEqual(run.state, .succeeded)
        XCTAssertTrue(h.windows.calls.contains("minimize:Terminal"))
        XCTAssertTrue(h.system.calls.contains("hide:com.apple.Music"))
        XCTAssertFalse(h.system.calls.contains { $0.hasPrefix("quit:") }, "Never quits")
    }

    func testLayoutAppliedEventCarriesCounts() async throws {
        let h = try TestHarness()
        h.system.markRunning(terminal)
        h.windows.addWindow(terminal, app: "Terminal")
        let saved = try layout(h, [WindowRule(bundleID: terminal, appName: "Terminal", preset: .rightHalf)])
        let collected = EventPayloadCollector()
        h.core.events.subscribe(AtlasEvent.Name.windowLayoutApplied) { collected.append($0) }

        _ = await h.engine.invoke(ApplyWindowLayoutAction.id, parameters: ["layout": "Programming"], source: "manual")

        let payload = try XCTUnwrap(collected.events.first?.payload)
        XCTAssertEqual(payload["layoutId"], .string(saved.id.uuidString))
        XCTAssertEqual(payload["placed"], .number(1))
        XCTAssertEqual(payload["skipped"], .number(0))
    }

    func testUnknownLayoutFails() async throws {
        let h = try TestHarness()
        let run = await h.engine.invoke(ApplyWindowLayoutAction.id, parameters: ["layout": "Nope"], source: "manual")
        XCTAssertEqual(run.state, .failed)
        XCTAssertTrue(run.steps.first?.error?.contains("No window layout called “Nope”") ?? false)
    }

    func testArrangePutsAnAppOnAPreset() async throws {
        let h = try TestHarness()
        h.windows.displayList = [MockWindowAdapter.builtIn, MockWindowAdapter.external]
        h.system.markRunning(terminal)
        h.windows.addWindow(terminal, app: "Terminal")

        let run = await h.engine.invoke(ArrangeWindowAction.id, parameters: [
            "app": .string(terminal), "preset": "rightHalf", "display": "Studio Display",
        ], source: "shortcut")

        XCTAssertEqual(run.state, .succeeded, run.steps.first?.error ?? "")
        XCTAssertTrue(h.windows.calls.contains("frame:Terminal:2720,-200,1280,1440"), "\(h.windows.calls)")
    }

    func testArrangeRejectsUnknownPresetAndDisplay() async throws {
        let h = try TestHarness()
        h.system.markRunning(terminal)
        h.windows.addWindow(terminal, app: "Terminal")

        let badPreset = await h.engine.invoke(ArrangeWindowAction.id, parameters: ["app": .string(terminal), "preset": "diagonal"], source: "manual")
        XCTAssertEqual(badPreset.state, .failed)
        let badDisplay = await h.engine.invoke(ArrangeWindowAction.id, parameters: [
            "app": .string(terminal), "preset": "LEFTHALF", "display": "Projector",
        ], source: "manual")
        XCTAssertEqual(badDisplay.state, .failed)
        XCTAssertTrue(badDisplay.steps.first?.error?.contains("Projector") ?? false)
        XCTAssertTrue(h.windows.mutatingCalls.isEmpty)
    }

    func testCaptureLayoutRecordsDisplaysFractionsAndTitles() async throws {
        let h = try TestHarness()
        h.windows.displayList = [MockWindowAdapter.builtIn, MockWindowAdapter.external]
        for bundleID in [terminal, notes, music] { h.system.markRunning(bundleID) }
        h.windows.addWindow(terminal, app: "Terminal", title: "zsh", frame: CGRect(x: 0, y: 25, width: 720, height: 875))
        h.windows.addWindow(terminal, app: "Terminal", title: "logs", frame: CGRect(x: 720, y: 25, width: 720, height: 875))
        h.windows.addWindow(notes, app: "Notes", title: "Ideas", frame: CGRect(x: 1440, y: -200, width: 1280, height: 1440))
        h.windows.addWindow(music, app: "Music", minimized: true)

        let run = await h.engine.invoke(CaptureWindowLayoutAction.id, parameters: ["name": "Programming"], source: "manual")

        XCTAssertEqual(run.state, .succeeded, run.steps.first?.error ?? "")
        let saved = try XCTUnwrap(try h.store.windowLayout(reference: "Programming"))
        XCTAssertEqual(saved.rules.count, 3, "Minimized windows aren't part of a layout")
        let zsh = try XCTUnwrap(saved.rules.first { $0.titleMatch == .contains("zsh") })
        XCTAssertEqual(zsh.display, .main)
        XCTAssertEqual(zsh.frame.x, 0, accuracy: 0.001)
        XCTAssertEqual(zsh.frame.width, 0.5, accuracy: 0.001)
        let ideas = try XCTUnwrap(saved.rules.first { $0.bundleID == notes })
        XCTAssertNil(ideas.titleMatch, "A lone window matches by app")
        XCTAssertEqual(ideas.display, .display(id: "EXTERNAL", name: "Studio Display"))
        XCTAssertEqual(ideas.frame.width, 0.5, accuracy: 0.001)
        XCTAssertEqual(saved.displayProfile?.displays.count, 2)
        XCTAssertTrue(h.windows.mutatingCalls.isEmpty, "Capturing never moves anything")

        // Capturing again under the same name updates the same layout.
        _ = await h.engine.invoke(CaptureWindowLayoutAction.id, parameters: ["name": "programming"], source: "manual")
        XCTAssertEqual(try h.store.windowLayouts().map(\.id), [saved.id])
    }

    func testCapturedLayoutRestoresAfterScrambleAndOnFewerDisplays() async throws {
        // The Stage 03 demo, in miniature.
        let h = try TestHarness()
        h.windows.displayList = [MockWindowAdapter.builtIn, MockWindowAdapter.external]
        for bundleID in [terminal, notes] { h.system.markRunning(bundleID) }
        let t = h.windows.addWindow(terminal, app: "Terminal", frame: CGRect(x: 0, y: 25, width: 720, height: 875))
        let n = h.windows.addWindow(notes, app: "Notes", frame: CGRect(x: 2720, y: -200, width: 1280, height: 1440))
        _ = try await h.core.windows.captureLayout(named: "Programming")

        // Scramble.
        _ = try await h.windows.setFrame(CGRect(x: 300, y: 300, width: 200, height: 200), of: t.id)
        _ = try await h.windows.setFrame(CGRect(x: 1500, y: 0, width: 300, height: 300), of: n.id)

        _ = await h.engine.invoke(ApplyWindowLayoutAction.id, parameters: ["layout": "Programming"], source: "manual")
        XCTAssertEqual(h.windows.frame(of: t.id), CGRect(x: 0, y: 25, width: 720, height: 875))
        XCTAssertEqual(h.windows.frame(of: n.id), CGRect(x: 2720, y: -200, width: 1280, height: 1440))

        // Unplug the external display.
        h.windows.displayList = [MockWindowAdapter.builtIn]
        let run = await h.engine.invoke(ApplyWindowLayoutAction.id, parameters: ["layout": "Programming"], source: "manual")
        XCTAssertEqual(run.state, .succeeded)
        let notesFrame = try XCTUnwrap(h.windows.frame(of: n.id))
        XCTAssertTrue(MockWindowAdapter.builtIn.visibleFrame.contains(notesFrame), "Nothing off-screen: \(notesFrame)")
        XCTAssertEqual(notesFrame, CGRect(x: 720, y: 25, width: 720, height: 875), "Right half of the laptop, as on the external")
        XCTAssertTrue(run.steps.first?.output["details"]?.stringValue?.contains("isn't connected") ?? false)
    }

    func testSnapshotSaveAndRestoreRelaunchesMissingApps() async throws {
        let h = try TestHarness()
        for bundleID in [terminal, notes, music] { h.system.markRunning(bundleID) }
        let t = h.windows.addWindow(terminal, app: "Terminal", frame: CGRect(x: 10, y: 40, width: 500, height: 300))

        let saveRun = await h.engine.invoke(SaveSnapshotAction.id, parameters: ["name": "Before lunch"], source: "manual")
        XCTAssertEqual(saveRun.state, .succeeded, saveRun.steps.first?.error ?? "")
        let snapshot = try XCTUnwrap(try h.store.snapshot(reference: "before lunch"))
        XCTAssertEqual(snapshot.runningApps, [music, notes, terminal])
        XCTAssertEqual(snapshot.rules.count, 1)

        // Music and Notes were quit by the user; Terminal moved.
        _ = try await h.system.quitApplication(bundleID: music)
        _ = try await h.system.quitApplication(bundleID: notes)
        _ = try await h.windows.setFrame(CGRect(x: 600, y: 400, width: 200, height: 200), of: t.id)

        let restoreRun = await h.engine.invoke(RestoreSnapshotAction.id, parameters: ["snapshot": "latest"], source: "manual")

        XCTAssertEqual(restoreRun.state, .succeeded, restoreRun.steps.first?.error ?? "")
        XCTAssertEqual(h.windows.frame(of: t.id), CGRect(x: 10, y: 40, width: 500, height: 300))
        XCTAssertTrue(h.system.calls.contains("launch:com.apple.Music"))
        XCTAssertTrue(h.system.calls.contains("launch:com.apple.Notes"))
        XCTAssertEqual(restoreRun.steps.first?.output["launched"], .number(2))
    }

    func testAutomaticSnapshotsArePrunedPerSpace() async throws {
        let h = try TestHarness()
        let space = UUID()
        for _ in 0..<7 { _ = try await h.core.windows.saveSnapshot(name: nil, spaceID: space, automatic: true) }
        _ = try await h.core.windows.saveSnapshot(name: "Manual", spaceID: space, automatic: false)

        let kept = try h.store.snapshots(spaceID: space)
        XCTAssertEqual(kept.filter(\.isAutomatic).count, 5)
        XCTAssertEqual(kept.filter { !$0.isAutomatic }.count, 1)
    }

    func testWindowActionsDeclareAccessibility() throws {
        let h = try TestHarness()
        for id in [ApplyWindowLayoutAction.id, CaptureWindowLayoutAction.id, SaveSnapshotAction.id,
                   RestoreSnapshotAction.id, ArrangeWindowAction.id] {
            let descriptor = try XCTUnwrap(h.core.registry.descriptor(for: id), id.rawValue)
            XCTAssertTrue(descriptor.permissions.contains(.accessibility), id.rawValue)
            XCTAssertFalse(descriptor.sideEffects.contains(.terminatesApplication))
        }
        XCTAssertTrue(h.core.registry.descriptor(for: ApplyWindowLayoutAction.id)!.isIdempotent)
    }

    func testChoiceParametersAreValidated() throws {
        let h = try TestHarness()
        let descriptor = try XCTUnwrap(h.core.registry.descriptor(for: ArrangeWindowAction.id))
        let resolved = try h.core.registry.validate(["app": "com.apple.Terminal", "preset": "RIGHTHALF"], for: descriptor)
        XCTAssertEqual(resolved["preset"], "rightHalf", "Normalized to the option's spelling")
        XCTAssertThrowsError(try h.core.registry.validate(["app": "com.apple.Terminal", "preset": "middle"], for: descriptor))
    }
}

// MARK: - Persistence

final class WindowStoreTests: XCTestCase {

    func testLayoutRoundTripWithEveryRuleShape() throws {
        let store = try AtlasStore.inMemory()
        let layout = WindowLayout(
            name: "Research",
            rules: [
                WindowRule(bundleID: "com.apple.Safari", appName: "Safari", titleMatch: .regex("^Docs"),
                           display: .display(id: "EXT", name: "LG"), frame: WindowPreset.leftTwoThirds.rect, zOrder: 0),
                WindowRule(bundleID: "com.apple.Notes", appName: "Notes", titleMatch: .contains("Ideas"),
                           display: .secondary, frame: FractionalRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4),
                           state: .minimized, zOrder: 1),
                WindowRule(bundleID: "com.apple.Music", appName: "Music", display: .sameAsBefore,
                           frame: .full, state: .hidden, zOrder: 2),
                WindowRule(bundleID: "com.apple.Terminal", preset: .rightThird),
            ],
            displayProfile: DisplayProfile(displays: [MockWindowAdapter.builtIn]),
            createdAt: Date(timeIntervalSince1970: 1_000),
            updatedAt: Date(timeIntervalSince1970: 2_000)
        )

        try store.saveWindowLayout(layout)

        XCTAssertEqual(try store.windowLayout(id: layout.id), layout)
        XCTAssertEqual(try store.windowLayouts(), [layout])
        XCTAssertEqual(try store.windowLayout(reference: "research")?.id, layout.id)
        XCTAssertEqual(try store.windowLayout(reference: layout.id.uuidString)?.id, layout.id)
    }

    func testSavingLayoutReplacesRulesAndDeleteCascades() throws {
        let store = try AtlasStore.inMemory()
        var layout = WindowLayout(name: "L", rules: [WindowRule(bundleID: "a.b", preset: .full), WindowRule(bundleID: "c.d", preset: .full)])
        try store.saveWindowLayout(layout)
        layout.rules = [WindowRule(bundleID: "e.f", preset: .leftHalf)]
        try store.saveWindowLayout(layout)
        XCTAssertEqual(try store.windowLayout(id: layout.id)?.rules.map(\.bundleID), ["e.f"])

        try store.deleteWindowLayout(id: layout.id)

        XCTAssertNil(try store.windowLayout(id: layout.id))
        XCTAssertEqual(try store.database.query("SELECT COUNT(*) AS n FROM window_rule;").first?.int("n"), 0)
    }

    func testSnapshotRoundTrip() throws {
        let store = try AtlasStore.inMemory()
        let snapshot = SessionSnapshot(
            name: "Left Coding Lab",
            createdAt: Date(timeIntervalSince1970: 5_000),
            spaceID: UUID(),
            isAutomatic: true,
            runningApps: ["com.apple.Terminal", "com.apple.Safari"],
            rules: [WindowRule(bundleID: "com.apple.Terminal", appName: "Terminal", titleMatch: .contains("zsh"),
                               display: .main, frame: WindowPreset.leftHalf.rect, zOrder: 0)],
            displayProfile: DisplayProfile(displays: [MockWindowAdapter.builtIn, MockWindowAdapter.external])
        )

        try store.saveSnapshot(snapshot)

        XCTAssertEqual(try store.snapshot(id: snapshot.id), snapshot)
        XCTAssertEqual(try store.snapshots(spaceID: snapshot.spaceID), [snapshot])
        XCTAssertEqual(try store.snapshot(reference: "latest"), snapshot)
        XCTAssertEqual(try store.snapshot(reference: "left coding lab"), snapshot)
        try store.deleteSnapshot(id: snapshot.id)
        XCTAssertTrue(try store.snapshots().isEmpty)
    }

    func testMigrationFromV2AddsWindowTablesAndKeepsData() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("atlas-v2-\(UUID().uuidString).sqlite")
        defer {
            for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: url.path + suffix) }
        }
        let spaceID = UUID(), profileID = UUID(), workflowID = UUID()

        // A Stage 02 database: migrations v1 and v2 applied, with a Space.
        do {
            let db = try SQLiteDatabase(path: url.path)
            for (index, sql) in Schema.migrations.prefix(2).enumerated() {
                try db.transaction {
                    try db.execute(sql)
                    try db.setUserVersion(index + 1)
                }
            }
            try db.run(
                """
                INSERT INTO space (id, name, group_name, template_id, accent_color, created_at, updated_at)
                VALUES (?, 'Lab', 'Work', 'coding-lab', '#000000', 0, 0);
                """,
                [.from(spaceID)]
            )
            try db.run(
                "INSERT INTO activation_profile (id, space_id, name, workflow_id, is_default) VALUES (?, ?, 'Deep Work', ?, 1);",
                [.from(profileID), .from(spaceID), .from(workflowID)]
            )
        }

        let store = try AtlasStore(database: SQLiteDatabase(path: url.path))

        XCTAssertEqual(store.database.userVersion, Schema.currentVersion)
        XCTAssertGreaterThanOrEqual(Schema.currentVersion, 3)
        let profile = try XCTUnwrap(try store.database.query("SELECT * FROM activation_profile;").first)
        XCTAssertEqual(profile.uuid("id"), profileID, "Existing profiles survive")
        XCTAssertNil(profile.string("window_layout_id"), "…with no layout yet")
        XCTAssertEqual(try store.database.query("SELECT snapshot_on_leave FROM space;").first?.bool("snapshot_on_leave"), true)
        try store.saveWindowLayout(WindowLayout(name: "New", rules: [WindowRule(bundleID: "a.b", preset: .full)]))
        try store.saveSnapshot(SessionSnapshot(name: "S", spaceID: spaceID))
        XCTAssertEqual(try store.windowLayouts().count, 1)
        XCTAssertEqual(try store.snapshots(spaceID: spaceID).count, 1)
    }
}

// MARK: - Editing canvas

final class LayoutCanvasTests: XCTestCase {
    let canvas = LayoutCanvas(displays: [MockWindowAdapter.builtIn, MockWindowAdapter.external])

    func testBoundsSpanEveryDisplay() {
        XCTAssertEqual(canvas.bounds, CGRect(x: 0, y: -200, width: 4000, height: 1440))
    }

    func testDraggingNearAPresetSnapsToIt() {
        let rule = WindowRule(bundleID: "a.b", preset: .centered)
        // Roughly the left half of the laptop, a little off.
        let dropped = CGRect(x: 12, y: 40, width: 700, height: 850)

        let snap = canvas.snap(for: dropped)
        XCTAssertEqual(snap?.preset, .leftHalf)
        XCTAssertEqual(snap?.frame, CGRect(x: 0, y: 25, width: 720, height: 875))
        let committed = canvas.commit(rule, rect: dropped)
        XCTAssertEqual(committed.frame, WindowPreset.leftHalf.rect)
        XCTAssertEqual(committed.display, .main)
    }

    func testDroppingFarFromPresetsKeepsTheExactSpot() {
        let rule = WindowRule(bundleID: "a.b", preset: .centered)
        let dropped = CGRect(x: 300, y: 300, width: 400, height: 300)

        XCTAssertNil(canvas.snap(for: dropped))
        let committed = canvas.commit(rule, rect: dropped)
        XCTAssertEqual(committed.frame.absolute(in: MockWindowAdapter.builtIn.visibleFrame), dropped)
    }

    func testDraggingAcrossMonitorsChangesTheDisplay() {
        let rule = WindowRule(bundleID: "a.b", preset: .leftHalf)
        let start = try! XCTUnwrap(canvas.frame(of: rule))

        let moved = canvas.moved(start, by: CGSize(width: 2000, height: 0))
        let committed = canvas.commit(rule, rect: moved, snapping: false)

        XCTAssertEqual(committed.display, .display(id: "EXTERNAL", name: "Studio Display"))
        let frame = try! XCTUnwrap(canvas.frame(of: committed))
        XCTAssertTrue(MockWindowAdapter.external.visibleFrame.contains(frame))
    }

    func testDroppingPartlyOffScreenIsClamped() {
        let rule = WindowRule(bundleID: "a.b", preset: .centered)
        let committed = canvas.commit(rule, rect: CGRect(x: -300, y: 500, width: 600, height: 600), snapping: false)
        let frame = try! XCTUnwrap(canvas.frame(of: committed))
        XCTAssertTrue(MockWindowAdapter.builtIn.visibleFrame.contains(frame), "\(frame)")
    }

    func testStayingOnTheSameDisplayKeepsItsRole() {
        let rule = WindowRule(bundleID: "a.b", preset: .leftHalf, display: .secondary)
        let start = try! XCTUnwrap(canvas.frame(of: rule))
        let committed = canvas.commit(rule, rect: start.offsetBy(dx: 40, dy: 40), snapping: false)
        XCTAssertEqual(committed.display, .secondary)
    }

    func testResizingRespectsTheMinimumSize() {
        let start = CGRect(x: 100, y: 100, width: 400, height: 300)
        XCTAssertEqual(canvas.resized(start, edge: .right, by: CGSize(width: 100, height: 0)), CGRect(x: 100, y: 100, width: 500, height: 300))
        XCTAssertEqual(canvas.resized(start, edge: .topLeft, by: CGSize(width: -50, height: -20)), CGRect(x: 50, y: 80, width: 450, height: 320))
        let tiny = canvas.resized(start, edge: .bottomRight, by: CGSize(width: -1000, height: -1000))
        XCTAssertEqual(tiny.size, LayoutCanvas.minimumSize)
    }
}
