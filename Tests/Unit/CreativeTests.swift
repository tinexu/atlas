import AppKit
import RealityKit
import XCTest
@testable import AtlasCore
@testable import AtlasCreative
import AtlasOrbit
@testable import AtlasSpaces
@testable import AtlasSpacesUI

/// Draws a flat coloured square instead of asking QuickLook.
struct SolidThumbnails: ThumbnailMaking {
    var fails = false

    func thumbnail(of path: String, size: CGFloat) async -> CGImage? {
        guard !fails else { return nil }
        let context = CGContext(data: nil, width: 64, height: 40, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0.9, green: 0.4, blue: 0.5, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 40))
        return context.makeImage()
    }
}

class CreativeTestCase: XCTestCase {
    var temp: URL!

    override func setUpWithError() throws {
        temp = FileManager.default.temporaryDirectory.appendingPathComponent("atlas-creative-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temp)
    }

    /// Creates a file `daysAgo` old.
    @discardableResult
    func file(_ relative: String, daysAgo: Double = 0) throws -> String {
        let url = temp.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: url.path, contents: Data("x".utf8))
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-daysAgo * 86_400)], ofItemAtPath: url.path)
        return url.path
    }
}

final class ProjectDiscoveryTests: CreativeTestCase {
    func testGroupsCreativeFilesByFolderNewestFirst() throws {
        try file("poster-series/poster.afdesign", daysAgo: 1)
        try file("poster-series/Versions/poster-old.afdesign", daysAgo: 9)
        try file("poster-series/Exports/poster.png", daysAgo: 1)
        try file("Robot/robot.blend", daysAgo: 3)
        try file("Robot/Renders/robot-0042.png", daysAgo: 3)
        try file("sketch.psd", daysAgo: 0.5)
        try file("Notes/readme.txt")
        let root = FileAccessPolicy.canonical(temp.path)

        let found = ProjectDiscovery.suggest(roots: [root], existing: [], isInstalled: { $0 == "org.blenderfoundation.blender" })
        XCTAssertEqual(found.map(\.name), ["Sketch", "Poster Series", "Robot"], "newest first")
        let poster = try XCTUnwrap(found.first { $0.name == "Poster Series" })
        XCTAssertEqual(poster.folder, root + "/poster-series")
        XCTAssertEqual(poster.fileCount, 2, "its Versions file belongs to it, not a project of its own")
        XCTAssertEqual(poster.kind, .design)
        XCTAssertEqual(poster.mainFiles, [root + "/poster-series/poster.afdesign"], "the newest of its kind")
        XCTAssertEqual(poster.apps, [], "Affinity isn't installed")
        let robot = try XCTUnwrap(found.first { $0.name == "Robot" })
        XCTAssertEqual(robot.kind, .threeD)
        XCTAssertEqual(robot.apps, ["org.blenderfoundation.blender"])
        let loose = try XCTUnwrap(found.first { $0.name == "Sketch" })
        XCTAssertNil(loose.folder, "a file directly in an Orbit folder is a project of its own")

        // Existing projects and ignored folders aren't suggested again.
        let existing = Project(name: "Robot", creative: CreativeInfo(folder: root + "/Robot"))
        let again = ProjectDiscovery.suggest(roots: [root], existing: [existing], ignored: [root + "/poster-series"])
        XCTAssertEqual(again.map(\.name), ["Sketch"])
    }

    func testDisplayNames() {
        XCTAssertEqual(ProjectDiscovery.displayName("robot_model"), "Robot Model")
        XCTAssertEqual(ProjectDiscovery.displayName("NotificationPets"), "NotificationPets")
    }
}

final class CreativeServiceTests: CreativeTestCase {
    private var h: TestHarness!
    private var module: CreativeModule!
    private var service: CreativeService { module.service }
    private var clock = Date()

    override func setUpWithError() throws {
        try super.setUpWithError()
        h = try TestHarness()
        h.system.installedApps["org.blenderfoundation.blender"] = "Blender"
        module = try CreativeModule(core: h.core, thumbnails: ProjectThumbnails(folder: temp.appendingPathComponent("thumbs"), maker: SolidThumbnails()))
        let now = LockedBox(clock)
        service.now = { now.value }
        service.isInstalled = { $0 == "org.blenderfoundation.blender" }
    }

    private func project(_ name: String, daysAgo: Double) throws -> Project {
        let main = try file("\(name)/\(name).blend", daysAgo: daysAgo)
        return try service.save(Project(name: name, color: "", creative: CreativeInfo(kind: .threeD, apps: ["org.blenderfoundation.blender"],
                                                                                    mainFiles: [main], folder: (main as NSString).deletingLastPathComponent)))
    }

    func testCreativeFieldsRoundTripAndPlainProjectsAreUntouched() throws {
        try h.store.saveProject(Project(name: "Plain"))
        var info = CreativeInfo(kind: .design, apps: ["com.figma.Desktop"], mainFiles: ["/a/b.fig"],
                                links: [.init(kind: .figma, url: "https://figma.com/file/x")], folder: "/a", status: .idea)
        info.coverImage = "/a/cover.png"
        let saved = try service.save(Project(name: "Poster", color: "", creative: info))
        XCTAssertTrue(CreativeService.palette.contains(saved.color), "gets a Creative Studio colour")
        let loaded = try XCTUnwrap(h.store.projects().first { $0.name == "Poster" })
        XCTAssertEqual(loaded.creative?.links.first?.url, "https://figma.com/file/x")
        XCTAssertEqual(loaded.creative?.resolvedExportsFolder, "/a/Exports")
        XCTAssertEqual(loaded.creative?.status, .idea)
        XCTAssertNil(try h.store.projects().first { $0.name == "Plain" }?.creative)
        XCTAssertEqual(service.projects().map(\.name), ["Poster"], "only creative projects")
        // Each new project a different colour.
        let second = try service.save(Project(name: "Second", color: "", creative: CreativeInfo()))
        XCTAssertNotEqual(second.color, saved.color)
        // Marking it done stamps when.
        var done = saved
        done.creative?.status = .done
        XCTAssertNotNil(try service.save(done).creative?.finishedAt)
    }

    func testCurrentProjectPinnedThenOpenedThenChanged() throws {
        let old = try project("Old", daysAgo: 5)
        let fresh = try project("Fresh", daysAgo: 1)
        XCTAssertEqual(service.currentProject()?.id, fresh.id, "files changed most recently")

        service.noteOpened(old.id)
        XCTAssertEqual(service.currentProject()?.id, old.id, "opened from the room beats changed")

        var settings = service.settings
        settings.pinnedProjectID = fresh.id
        service.settings = settings
        XCTAssertEqual(service.currentProject()?.id, fresh.id, "pinned beats everything")

        // An opening more than 12 hours ago no longer counts.
        settings.pinnedProjectID = nil
        service.settings = settings
        let later = LockedBox(clock.addingTimeInterval(13 * 3600))
        service.now = { later.value }
        XCTAssertEqual(service.currentProject()?.id, fresh.id)
    }

    func testRoomShowsTheCurrentProjectWithItsPicture() async throws {
        let robot = try project("Robot", daysAgo: 0.1)
        let export = try file("Robot/Exports/robot-final.png", daysAgo: 0.05)
        XCTAssertEqual(service.latestVisual(robot).map(FileAccessPolicy.canonical), FileAccessPolicy.canonical(export),
                       "the newest export beats the main file")
        var state = module.roomState()
        XCTAssertEqual(state.easel?.projectID, robot.id)
        XCTAssertTrue(state.easel?.detail.hasPrefix("Robot · In progress · last edited") ?? false, state.easel?.detail ?? "")
        XCTAssertEqual(state.monitorDetail, "Open Blender")
        _ = await service.thumbnails.make(export)
        state = module.roomState()
        let image = try XCTUnwrap(state.easel?.image)
        XCTAssertTrue(FileManager.default.fileExists(atPath: image))
        XCTAssertNotNil(state.monitorImage, "a blurred copy for the monitor")
        XCTAssertNotEqual(state.monitorImage, image)
        XCTAssertEqual(CreativeRoomState().detail(for: .easel), "No project yet · click to set one up")
    }

    func testEaselOpensMainFileFolderAndFigmaLink() async throws {
        var robot = try project("Robot", daysAgo: 1)
        robot.creative?.links = [.init(kind: .figma, url: "https://www.figma.com/file/abc"), .init(kind: .pinterest, url: "https://pinterest.com/x")]
        robot = try service.save(robot)
        let run = await h.engine.invoke(OpenCreativeProjectAction.id, source: "test")
        XCTAssertEqual(run.state, .succeeded, run.error ?? "")
        let main = try XCTUnwrap(robot.creative?.mainFiles.first)
        XCTAssertEqual(h.system.calls, ["open-file:\(main)", "open-file:\((main as NSString).deletingLastPathComponent)",
                                         "open-url:https://www.figma.com/file/abc"])
        XCTAssertNotNil(service.openedAt[robot.id], "counts as opened from the room")

        let monitor = await h.engine.invoke(OpenDesignAppAction.id, source: "test")
        XCTAssertEqual(monitor.state, .succeeded)
        XCTAssertEqual(h.system.calls.last, "launch:org.blenderfoundation.blender")
    }

    func testSuggestionsComeFromOrbitFolders() throws {
        try file("Poster/poster.psd")
        XCTAssertEqual(service.suggestions().count, 0, "the temp folder isn't in Orbit")
        h.core.fileAccess.setRoots([temp.path])
        XCTAssertEqual(service.suggestions().map(\.name), ["Poster"])
        let added = try service.add(service.suggestions())
        XCTAssertEqual(added.first?.creative?.kind, .photo)
        XCTAssertTrue(service.hasFinishedSetup)
        XCTAssertTrue(service.suggestions().isEmpty)
    }
}

final class CreativeRoomTests: CreativeTestCase {
    @MainActor
    func testEaselAndMonitorShowThePicture() throws {
        let space = Space(name: "Creative Studio", group: .personal, templateID: CreativeLoft.templateID, accentColor: "#E8A6B4", slot: 0)
        let template = SpaceTemplates.creativeStudio
        let objects = template.objects.map { SpaceObject(spaceID: space.id, kind: $0.kind, label: $0.label, actionID: $0.actionID) }
        let room = RoomBuilder.build(space: space, room: template.room, objects: objects, detail: true)
        let easel = try XCTUnwrap(room.findEntity(named: "easelPicture") as? ModelEntity)
        let monitor = try XCTUnwrap(room.findEntity(named: "monitorPicture") as? ModelEntity)
        XCTAssertFalse(easel.isEnabled, "the blobs show until there's a picture")

        let picture = temp.appendingPathComponent("p.png")
        let image = NSImage(size: NSSize(width: 80, height: 40), flipped: false) { rect in
            NSColor.systemPink.setFill(); rect.fill(); return true
        }
        try XCTUnwrap(NSBitmapImageRep(data: image.tiffRepresentation!)?.representation(using: .png, properties: [:])).write(to: picture)
        let motion = try XCTUnwrap(room.components[RoomMotionComponent.self]?.motion as? CreativeLoftMotion)
        motion.update(CreativeRoomState(easel: .init(projectID: UUID(), detail: "", image: picture.path), monitorImage: picture.path))
        XCTAssertTrue(easel.isEnabled)
        XCTAssertEqual(room.findEntity(named: "easelBlobs")?.isEnabled, false, "the blobs make way for the picture")
        XCTAssertEqual(easel.scale.x / easel.scale.y, 2, accuracy: 0.01, "keeps its shape")
        XCTAssertLessThanOrEqual(easel.scale.x, CreativeLoftBuilder.Easel.pictureArea.x + 0.0001)
        XCTAssertTrue(monitor.isEnabled)
        motion.update(CreativeRoomState())
        XCTAssertFalse(easel.isEnabled)
        XCTAssertEqual(room.findEntity(named: "easelBlobs")?.isEnabled, true)
    }
}

final class ColorPaletteTests: XCTestCase {
    func testFiveDistinctColoursMostCommonFirst() throws {
        let colors: [(CGFloat, CGFloat, CGFloat, Int)] = [(0.91, 0.65, 0.71, 40), (1, 0.77, 0.66, 25), (0.56, 0.71, 0.6, 15),
                                                          (0.83, 0.65, 0.35, 12), (0.56, 0.23, 0.36, 8)]
        let context = CGContext(data: nil, width: 100, height: 20, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        var x: CGFloat = 0
        for (r, g, b, width) in colors {
            context.setFillColor(CGColor(srgbRed: r, green: g, blue: b, alpha: 1))
            context.fill(CGRect(x: x, y: 0, width: CGFloat(width), height: 20))
            x += CGFloat(width)
        }
        let palette = ColorPalette.extract(from: try XCTUnwrap(context.makeImage()))
        XCTAssertEqual(palette.count, 5)
        XCTAssertEqual(Set(palette).count, 5, "distinct")
        XCTAssertEqual(palette.first, "#E8A6B5", "the biggest area first")
        // Deterministic.
        XCTAssertEqual(ColorPalette.extract(from: try XCTUnwrap(context.makeImage())), palette)
    }
}

final class CreativeSessionTests: CreativeTestCase {
    private var time: TimeHarness!
    private var module: CreativeModule!
    private var sessions: CreativeSessions { module.sessions }
    private var project: Project!

    override func setUpWithError() throws {
        try super.setUpWithError()
        time = try TimeHarness()
        module = try CreativeModule(core: time.core, thumbnails: ProjectThumbnails(folder: temp.appendingPathComponent("thumbs"), maker: SolidThumbnails()))
        module.service.now = { [environment = time.environment] in environment.now() }
        var settings = module.service.settings
        settings.dayBoundaryHour = 0
        module.service.settings = settings
        let folder = temp.appendingPathComponent("Robot").path
        try FileManager.default.createDirectory(atPath: folder + "/Exports", withIntermediateDirectories: true)
        project = try module.service.save(Project(name: "Robot", color: "", creative: CreativeInfo(kind: .threeD, folder: folder)))
    }

    private func png(_ path: String) throws {
        let context = CGContext(data: nil, width: 20, height: 20, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.9, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 20, height: 20))
        XCTAssertTrue(ProjectThumbnails.writePNG(context.makeImage()!, to: URL(fileURLWithPath: path)))
    }

    private func created(_ path: String) {
        time.core.events.publish(AtlasEvent(AtlasEvent.Name.fileCreatedEvent, payload: ["path": .string(path)]))
    }

    func testASessionCountsExportsAndReferencesAndSavesItself() throws {
        try sessions.start(minutes: 90)
        XCTAssertEqual(time.time.focus.session?.title, "Create · Focus")
        XCTAssertEqual(time.time.focus.session?.plannedSeconds, 90 * 60, "one long block, no pomodoro")
        XCTAssertEqual(sessions.current?.projectID, project.id, "the current project")

        let folder = try XCTUnwrap(project.creative?.folder)
        let export = folder + "/Exports/robot-0001.png"
        try png(export)
        created(export)
        created(folder + "/References/ref.jpg")
        created(folder + "/References/ref2.jpg")
        created(folder + "/robot.blend")
        created("/elsewhere/not-mine.png")
        time.advance(minutes: 45)
        let summary = try XCTUnwrap(sessions.end(early: true))

        XCTAssertEqual(summary.exports, 1)
        XCTAssertEqual(summary.references, 2)
        XCTAssertEqual(summary.focusedSeconds, 45 * 60, accuracy: 1)
        XCTAssertEqual(summary.streak, 1)
        // From the export (blue; exact values shift a little through colour management).
        let first = try XCTUnwrap(summary.palette.first.flatMap { UInt32($0.dropFirst(), radix: 16) })
        XCTAssertGreaterThan(first & 0xFF, (first >> 16) & 0xFF)
        XCTAssertEqual(summary.headline, "45 m creating · Robot · 1 export · 2 references saved · streak 1 day")
        let saved = try XCTUnwrap(time.store.creativeSessions(in: DateInterval(start: .distantPast, end: .distantFuture)).first)
        XCTAssertEqual(saved.files.count, 4)
        XCTAssertEqual(saved.projectID, project.id)
        XCTAssertNil(sessions.current)
    }

    func testTheTimeRunningOutEndsItAndRefillsTheMug() throws {
        try sessions.start(minutes: 30)
        XCTAssertTrue(module.roomState().mug.isRunning)
        time.advance(minutes: 31)
        XCTAssertNil(sessions.current)
        XCTAssertEqual(sessions.lastSummary?.endedEarly, false)
        XCTAssertEqual(module.roomState().mug.refills, 1)
        XCTAssertFalse(module.roomState().mug.isRunning)
    }

    func testGentleBreakRemindersOncePerHourWithoutPausing() throws {
        var settings = module.service.settings
        settings.breakReminders = true
        module.service.settings = settings
        try sessions.start(minutes: 180)
        time.advance(minutes: 59)
        sessions.tick()
        time.advance(minutes: 2)
        sessions.tick()
        sessions.tick()
        let expectation = expectation(description: "notified")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { expectation.fulfill() }
        wait(for: [expectation], timeout: 1)
        XCTAssertEqual(time.base.system.calls.filter { $0.hasPrefix("notify:") }, ["notify:1 h of creating"])
        XCTAssertTrue(sessions.isRunning, "nothing pauses")
    }

    func testStreakNeedsThirtyMinutesADayAndWatchingDoesntCount() throws {
        let day = module.service.settings.day
        let today = day.start(of: time.now)
        func session(daysAgo: Int, minutes: Double, kind: CreativeSession.Kind = .create) throws {
            let start = today.addingTimeInterval(-Double(daysAgo) * 86_400 + 3600)
            try time.store.saveCreativeSession(CreativeSession(kind: kind, startedAt: start, endedAt: start.addingTimeInterval(minutes * 60),
                                                               focusedSeconds: minutes * 60))
        }
        try session(daysAgo: 1, minutes: 40)
        try session(daysAgo: 2, minutes: 35)
        try session(daysAgo: 3, minutes: 20)
        try session(daysAgo: 3, minutes: 120, kind: .watch)
        XCTAssertEqual(sessions.streak(), 2)
        try session(daysAgo: 0, minutes: 30)
        XCTAssertEqual(sessions.streak(), 3)
        XCTAssertEqual(sessions.createdToday(), 30 * 60)
        XCTAssertEqual(Set(sessions.weeklyHours().map(\.kind)), [.create, .watch], "watching is its own series")
    }

    func testLeavingTheStudioEndsTheSession() throws {
        let space = try SpaceLibrary(core: time.core).createSpace(from: SpaceTemplates.creativeStudio)
        try sessions.start()
        time.core.events.publish(AtlasEvent(AtlasEvent.Name.spaceDeactivated, payload: ["spaceId": .string(space.id.uuidString)]))
        XCTAssertNil(sessions.current)
        XCTAssertEqual(sessions.lastSummary?.endedEarly, true)
    }

    @MainActor
    func testMugSteamsOnlyWhileRunning() throws {
        let space = Space(name: "Creative Studio", group: .personal, templateID: CreativeLoft.templateID, accentColor: "#E8A6B4", slot: 0)
        let template = SpaceTemplates.creativeStudio
        let objects = template.objects.map { SpaceObject(spaceID: space.id, kind: $0.kind, label: $0.label, actionID: $0.actionID) }
        let room = RoomBuilder.build(space: space, room: template.room, objects: objects, detail: true, reduceMotion: true)
        let motion = try XCTUnwrap(room.components[RoomMotionComponent.self]?.motion as? CreativeLoftMotion)
        motion.update(CreativeRoomState(mug: .init(isRunning: true)))
        XCTAssertTrue(motion.isSteaming)
        motion.update(CreativeRoomState(mug: .init(isRunning: true, isPaused: true)))
        XCTAssertFalse(motion.isSteaming)
    }
}

final class CreativeRuleTests: CreativeTestCase {
    private var h: TestHarness!
    private var module: CreativeModule!
    private var service: CreativeService { module.service }
    private var studio: Space!
    private var project: Project!
    private var exports: String { project.creative!.resolvedExportsFolder! }

    override func setUpWithError() throws {
        try super.setUpWithError()
        h = try TestHarness()
        module = try CreativeModule(core: h.core, thumbnails: ProjectThumbnails(folder: temp.appendingPathComponent("thumbs"), maker: SolidThumbnails()))
        let folder = temp.appendingPathComponent("Robot Model").path
        try FileManager.default.createDirectory(atPath: folder + "/Exports", withIntermediateDirectories: true)
        project = try service.save(Project(name: "Robot Model", color: "", creative: CreativeInfo(kind: .threeD, folder: folder)))
        studio = try SpaceLibrary(core: h.core).createSpace(from: SpaceTemplates.creativeStudio)
    }

    private func enterStudio() throws {
        try h.store.setPreference(studio.id, for: ConditionCheck.activeSpacePreferenceKey)
    }

    /// A real file the mock file system also knows about.
    private func download(_ name: String) throws -> String {
        let path = try file("Downloads/\(name)")
        h.system.existingPaths[path] = .file
        return path
    }

    private func reviews() throws -> [ReviewItem] { try h.store.reviewItems(state: .pending) }

    func testExportNamesCountUpAndNeverOverwrite() throws {
        let date = Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 27, hour: 12))!
        let folder = temp.path
        XCTAssertEqual(CreativeFileRules.exportName(for: "/x/Untitled.png", project: "Robot Model", date: date, in: folder),
                       "robot-model-2026-10-27-1.png")
        try file("robot-model-2026-10-27-1.png")
        try file("robot-model-2026-10-27-2.png")
        XCTAssertEqual(CreativeFileRules.exportName(for: "/x/a.PNG", project: "Robot Model", date: date, in: folder),
                       "robot-model-2026-10-27-3.PNG")
        XCTAssertTrue(CreativeFileRules.isScreenshot("/d/Screenshot 2026-10-29 at 10.02.11.png"))
        XCTAssertFalse(CreativeFileRules.isScreenshot("/d/poster.png"))
    }

    func testExportsOnlyWhileInTheStudioAndAskFirstByDefault() async throws {
        let path = try download("render.png")
        var run = await h.engine.invoke(FileExportAction.id, parameters: ["path": .string(path)], source: "test")
        XCTAssertEqual(run.steps.first?.output["outcome"], "skipped", "not in the Creative Studio")
        XCTAssertTrue(try reviews().isEmpty)

        try enterStudio()
        run = await h.engine.invoke(FileExportAction.id, parameters: ["path": .string(path)], source: "test")
        XCTAssertEqual(run.state, .succeeded, run.error ?? "")
        let item = try XCTUnwrap(try reviews().first)
        XCTAssertTrue(item.reason.hasPrefix("Creative Studio export → Robot Model"))
        guard case .moveAndRename(let folder, let name) = item.action else { return XCTFail("\(item.action)") }
        XCTAssertEqual(folder, exports)
        XCTAssertTrue(name.hasPrefix("robot-model-") && name.hasSuffix("-1.png"), name)
        XCTAssertFalse(h.system.calls.contains { $0.hasPrefix("move:") }, "nothing moves before you approve")

        // Approving in the review queue moves and renames it.
        let approved = await FileOrganizer(core: h.core).approve(item)
        XCTAssertEqual(approved?.state, .succeeded, approved?.error ?? "")
        XCTAssertEqual(h.system.calls.last { $0.hasPrefix("move:") }, "move:\(path)->\(exports)/\(name)")
        XCTAssertNotNil(h.system.existingPaths["\(exports)/\(name)"])
    }

    func testAutomaticExportsAndScreenshotsAreLeftAlone() async throws {
        try enterStudio()
        service.settings.exportMode = .automatic
        let path = try download("poster.png")
        let run = await h.engine.invoke(FileExportAction.id, parameters: ["path": .string(path)], source: "test")
        XCTAssertEqual(run.state, .succeeded, run.error ?? "")
        XCTAssertTrue(h.system.calls.contains { $0.hasPrefix("move:\(path)->\(exports)/robot-model-") })
        let screenshot = try download("Screenshot 2026-10-29 at 10.00.00.png")
        let shot = await h.engine.invoke(FileExportAction.id, parameters: ["path": .string(screenshot)], source: "test")
        XCTAssertEqual(shot.steps.first?.output["outcome"], "skipped")
    }

    func testUnauthorizedExportsFolderIsBlockedWithAWarning() async throws {
        try enterStudio()
        h.core.fileAccess.setRoots([temp.appendingPathComponent("Downloads").path])
        let path = try download("poster.png")
        let run = await h.engine.invoke(FileExportAction.id, parameters: ["path": .string(path)], source: "test")
        XCTAssertEqual(run.state, .failed)
        XCTAssertTrue(run.steps.first?.error?.contains("isn't in an Orbit folder") ?? false, run.steps.first?.error ?? "")
        // The workflows say so in the editor too, for folders they watch.
        try module.rules.install()
        let workflow = try XCTUnwrap(module.rules.workflow(.exports))
        XCTAssertTrue(h.core.validate(workflow).contains { $0.folderToAdd != nil }, "Desktop isn't authorized here")
    }

    func testAfterAWeekAndFiveApprovalsInARowItOffersAutomatic() async throws {
        try enterStudio()
        let offers = CreativeEventCollector()
        _ = h.core.events.subscribe(AtlasEvent.Name.companionOffer) { offers.append($0) }
        service.settings.rulesInstalledAt = Date().addingTimeInterval(-8 * 86_400)
        for index in 0..<5 {
            var item = ReviewItem(path: "/old/\(index).png", ruleIDs: [], action: .moveTo(folder: "/x"), reason: "Creative Studio export → Robot Model")
            item.state = .approved
            item.resolvedAt = Date().addingTimeInterval(Double(-index) * 60)
            try h.store.saveReviewItem(item)
        }
        XCTAssertEqual(service.approvedExportsInARow(), 5)
        _ = await h.engine.invoke(FileExportAction.id, parameters: ["path": .string(try download("next.png"))], source: "test")
        XCTAssertEqual(offers.values.first?.payload["actionId"]?.stringValue, SetExportModeAction.id.rawValue)
        _ = await h.engine.invoke(FileExportAction.id, parameters: ["path": .string(try download("again.png"))], source: "test")
        XCTAssertEqual(offers.values.count, 1, "offered once")
        _ = await h.engine.invoke(SetExportModeAction.id, parameters: ["mode": "automatic"], source: "test")
        XCTAssertEqual(service.settings.exportMode, .automatic)
    }

    func testScreenshotsGoToReferencesOnlyDuringASession() async throws {
        let time = try TimeHarness()
        let module = try CreativeModule(core: time.core, thumbnails: ProjectThumbnails(folder: temp.appendingPathComponent("t2"), maker: SolidThumbnails()))
        let saved = try module.service.save(project)
        let shot = try file("Desktop/Screenshot 2026-10-29 at 10.00.00.png")
        time.base.system.existingPaths[shot] = .file
        var run = await time.core.engine.invoke(FileReferenceAction.id, parameters: ["path": .string(shot)], source: "test")
        XCTAssertEqual(run.steps.first?.output["outcome"], "skipped", "no session")
        try module.sessions.start(projectID: saved.id)
        run = await time.core.engine.invoke(FileReferenceAction.id, parameters: ["path": .string(shot)], source: "test")
        let item = try XCTUnwrap(try time.store.reviewItems(state: .pending).first)
        XCTAssertEqual(item.action, .moveTo(folder: saved.creative!.folder! + "/References"))
        module.sessions.end()
    }

    func testVersionSaveKeepsTheNewestTenAndTrashesOlderOnes() async throws {
        let main = try file("Robot Model/robot.blend")
        project.creative?.mainFiles = [main]
        project = try service.save(project)
        h.system.existingPaths[main] = .file
        let versions = project.creative!.folder! + "/Versions"
        for day in 10...20 {
            let path = try file("Robot Model/Versions/robot-2026-09-\(day)-1200.blend")
            h.system.existingPaths[path] = .file
        }
        try file("Robot Model/Versions/notes.txt")
        let run = await h.engine.invoke(SaveVersionAction.id, parameters: ["space": .string(studio.id.uuidString)], source: "test")
        XCTAssertEqual(run.state, .succeeded, run.error ?? "")
        let copy = try XCTUnwrap(h.system.calls.first { $0.hasPrefix("copy:") })
        XCTAssertTrue(copy.hasPrefix("copy:\(main)->\(versions)/robot-20"), copy)
        // 11 dated copies on disk: the oldest goes to the Trash, nothing is deleted.
        XCTAssertEqual(h.system.calls.filter { $0.hasPrefix("trash:") }, ["trash:\(versions)/robot-2026-09-10-1200.blend"])
        XCTAssertEqual(SaveVersionAction.versions(of: "robot", ext: "blend", in: versions).count, 11, "notes.txt isn't a version")
        // Leaving another Space does nothing.
        let other = await h.engine.invoke(SaveVersionAction.id, parameters: ["space": .string(UUID().uuidString)], source: "test")
        XCTAssertEqual(other.steps.first?.message, "Not the Creative Studio")
    }

    func testRulesInstallOnceAndRenderRulesFollowProjects() async throws {
        try module.rules.install()
        XCTAssertEqual(module.rules.workflow(.exports)?.isEnabled, true)
        XCTAssertEqual(module.rules.workflow(.screenshots)?.isEnabled, true)
        XCTAssertEqual(module.rules.workflow(.versions)?.isEnabled, false, "version save is off by default")
        XCTAssertEqual(module.rules.workflow(.exports)?.triggerNodes.compactMap { $0.parameters["folder"]?.stringValue }, ["~/Downloads", "~/Desktop"])
        XCTAssertEqual(module.rules.renderWorkflows.count, 0, "no Renders folder yet")

        let render = try file("Robot Model/Renders/robot-0042.png")
        try module.rules.syncRenders()
        let workflowID = try XCTUnwrap(module.rules.renderWorkflows[project.id])
        XCTAssertEqual(try h.store.workflow(id: workflowID)?.name, "Creative · Renders: Robot Model")

        let run = await h.engine.invoke(RenderDoneAction.id, parameters: ["path": .string(render)], source: "test")
        XCTAssertEqual(run.state, .succeeded, run.error ?? "")
        XCTAssertTrue(h.system.calls.contains("notify:Render done: robot-0042.png"))
        XCTAssertEqual(service.latestVisual(project).map(FileAccessPolicy.canonical), FileAccessPolicy.canonical(render), "it goes on the easel")

        try service.delete(projectID: project.id)
        try module.rules.syncRenders()
        XCTAssertNil(try h.store.workflow(id: workflowID), "the project's gone, so is its render rule")
        let ids = module.rules.installed
        try module.rules.install()
        XCTAssertEqual(module.rules.installed, ids, "installed once")
    }

    func testSpaceLeftTriggerFires() async throws {
        let env = h.startTriggers()
        var g = GraphBuilder()
        let trigger = g.add(.trigger(TriggerCatalog.spaceDeactivated, parameters: ["space": "Creative Studio"]))
        let log = g.add(.log("left {{trigger.spaceName}}"))
        g.flow(trigger, to: log)
        let workflow = try h.core.save(g.workflow("Left"))
        _ = env
        try await h.expect(h.waitUntil { h.core.triggers?.activeTriggerCount == 1 })
        h.core.events.publish(AtlasEvent(AtlasEvent.Name.spaceDeactivatedEvent, payload: ["spaceId": "1", "spaceName": "Coding Lab"]))
        h.core.events.publish(AtlasEvent(AtlasEvent.Name.spaceDeactivatedEvent, payload: ["spaceId": "2", "spaceName": "Creative Studio"]))
        try await h.expect(h.waitUntil { try h.runs(of: workflow).count == 1 })
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(try h.runs(of: workflow).map { $0.triggerPayload["spaceName"] }, ["Creative Studio"])
    }
}

/// Collects events from the bus (thread-safe).
final class CreativeEventCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [AtlasEvent] = []
    func append(_ event: AtlasEvent) { lock.withLock { events.append(event) } }
    var values: [AtlasEvent] { lock.withLock { events } }
}

final class CreativeWallsTests: CreativeTestCase {
    private var h: TestHarness!
    private var module: CreativeModule!
    private var service: CreativeService { module.service }

    override func setUpWithError() throws {
        try super.setUpWithError()
        h = try TestHarness()
        module = try CreativeModule(core: h.core, thumbnails: ProjectThumbnails(folder: temp.appendingPathComponent("thumbs"), maker: SolidThumbnails()))
        service.settings.inspirationFolder = temp.appendingPathComponent("Inspiration").path
    }

    private func png(_ relative: String, red: CGFloat, daysAgo: Double = 0) throws -> String {
        let url = temp.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let context = CGContext(data: nil, width: 40, height: 40, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        for (index, green) in [CGFloat(0.1), 0.4, 0.7, 0.9, 0.55].enumerated() {
            context.setFillColor(CGColor(srgbRed: red, green: green, blue: 0.5, alpha: 1))
            context.fill(CGRect(x: index * 8, y: 0, width: 8, height: 40))
        }
        XCTAssertTrue(ProjectThumbnails.writePNG(context.makeImage()!, to: url))
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-daysAgo * 86_400)], ofItemAtPath: url.path)
        return url.path
    }

    func testPegboardPinsTheSixNewestPictures() throws {
        let folder = temp.appendingPathComponent("Robot").path
        _ = try service.save(Project(name: "Robot", color: "", creative: CreativeInfo(folder: folder)))
        for day in 0..<5 { _ = try png("Inspiration/old-\(day).png", red: 0.2, daysAgo: Double(day + 3)) }
        let moodboard = try png("Inspiration/coffee/cup.jpg", red: 0.5, daysAgo: 1)
        let reference = try png("Robot/References/ref.png", red: 0.9, daysAgo: 0.5)
        try file("Inspiration/notes.txt")
        let pinned = service.pegboardSources()
        XCTAssertEqual(pinned.count, 6)
        XCTAssertEqual(pinned.prefix(2).map(FileAccessPolicy.canonical), [reference, moodboard].map(FileAccessPolicy.canonical),
                       "the project's references and moodboard folders count, newest first")
        XCTAssertFalse(pinned.contains { $0.hasSuffix("old-4.png") }, "the oldest drops off")
    }

    func testJarsTakeTheLatestPicturesColours() throws {
        XCTAssertEqual(service.jarColors(), CreativeService.defaultJars, "no project yet")
        let folder = temp.appendingPathComponent("Poster").path
        _ = try service.save(Project(name: "Poster", color: "", creative: CreativeInfo(kind: .design, folder: folder)))
        _ = try png("Poster/Exports/poster.png", red: 0.9)
        let jars = service.jarColors()
        XCTAssertEqual(jars.count, 5)
        XCTAssertEqual(Set(jars).count, 5)
        XCTAssertNotEqual(jars, CreativeService.defaultJars)
        XCTAssertEqual(service.jarColors(), jars, "worked out once per picture")
        XCTAssertTrue(module.roomState().shelvesDetail.contains(jars[0]))
    }

    func testGalleryHangsTheSixMostRecentlyFinished() throws {
        var ids: [UUID] = []
        for index in 0..<8 {
            var info = CreativeInfo(status: .done)
            info.finishedAt = Date().addingTimeInterval(Double(index) * 3600)
            ids.append(try service.save(Project(name: "Piece \(index)", color: "", creative: info)).id)
        }
        _ = try service.save(Project(name: "Still going", color: "", creative: CreativeInfo(status: .inProgress)))
        let gallery = service.gallery()
        XCTAssertEqual(gallery.map(\.projectID), Array(ids.reversed().prefix(6)), "newest first, at most 6")
        XCTAssertTrue(gallery[0].detail.hasPrefix("Piece 7 · finished"))
        XCTAssertEqual(service.pastWork().map(\.name), ["Piece 1", "Piece 0"], "older ones are past work")
        XCTAssertEqual(CreativeRoomState.Item(entityName: CreativeRoomState.Item.frame(ids[0]).entityName), .frame(ids[0]))
        XCTAssertEqual(CreativeRoomState.Item(entityName: "creativeitem:jar:3"), .jar(3))
    }

    func testPegboardAndShelvesOpenTheRightThings() async throws {
        let folder = temp.appendingPathComponent("Robot").path
        try FileManager.default.createDirectory(atPath: folder + "/Assets", withIntermediateDirectories: true)
        _ = try service.save(Project(name: "Robot", color: "", creative: CreativeInfo(
            links: [.init(kind: .pinterest, url: "https://pinterest.com/board"), .init(kind: .figma, url: "https://figma.com/f")], folder: folder)))
        let run = await h.engine.invoke(OpenInspirationAction.id, source: "test")
        XCTAssertEqual(run.state, .succeeded, run.error ?? "")
        XCTAssertTrue(FileManager.default.fileExists(atPath: service.inspirationFolder), "made when first used")
        XCTAssertEqual(h.system.calls, ["open-file:\(service.inspirationFolder)", "open-url:https://pinterest.com/board"])
        _ = await h.engine.invoke(OpenAssetsAction.id, source: "test")
        XCTAssertEqual(h.system.calls.last, "open-file:\(folder)/Assets")
    }

    @MainActor
    func testRoomHasClickableJarsAndFramesInFrontOfTheWall() throws {
        let space = Space(name: "Creative Studio", group: .personal, templateID: CreativeLoft.templateID, accentColor: "#E8A6B4", slot: 0)
        let template = SpaceTemplates.creativeStudio
        let objects = template.objects.map { SpaceObject(spaceID: space.id, kind: $0.kind, label: $0.label, actionID: $0.actionID) }
        let room = RoomBuilder.build(space: space, room: template.room, objects: objects, detail: true)
        for index in 0..<5 {
            XCTAssertNotNil(room.findEntity(named: "creativeitem:jar:\(index)")?.components[CollisionComponent.self])
        }
        let motion = try XCTUnwrap(room.components[RoomMotionComponent.self]?.motion as? CreativeLoftMotion)
        let picture = try png("pic.png", red: 0.8)
        let frames = (0..<3).map { CreativeRoomState.Frame(projectID: UUID(), image: $0 == 0 ? picture : nil, detail: "") }
        motion.update(CreativeRoomState(pegboard: [picture, picture], jars: ["#112233", "#445566", "#778899", "#AABBCC", "#DDEEFF"],
                                        gallery: frames))
        XCTAssertEqual(room.findEntity(named: "pegboardContent")?.children.count, 2)
        let gallery = try XCTUnwrap(room.findEntity(named: "galleryContent"))
        XCTAssertEqual(gallery.children.count, 3)
        // In front of the back wall's picking shape (world z = −1.0), so clicks reach them.
        for frame in gallery.children {
            let collision = try XCTUnwrap(frame.components[CollisionComponent.self])
            let matrix = frame.transformMatrix(relativeTo: room)
            let front = [collision.shapes[0].bounds.min, collision.shapes[0].bounds.max].map { (matrix * SIMD4($0, 1)).z }.max()!
            XCTAssertGreaterThan(front, -0.998)
        }
    }
}

final class CreativePhase5Tests: CreativeTestCase {
    private var time: TimeHarness!
    private var module: CreativeModule!
    private var service: CreativeService { module.service }
    private var offers: CreativeEventCollector!

    override func setUpWithError() throws {
        try super.setUpWithError()
        time = try TimeHarness()
        module = try CreativeModule(core: time.core, thumbnails: ProjectThumbnails(folder: temp.appendingPathComponent("thumbs"), maker: SolidThumbnails()))
        module.service.now = { [environment = time.environment] in environment.now() }
        service.settings.dayBoundaryHour = 0
        offers = CreativeEventCollector()
        let offers = self.offers!
        _ = time.core.events.subscribe { event in
            if event.name == AtlasEvent.Name.companionOffer || event.name == AtlasEvent.Name.creativePickProject { offers.append(event) }
        }
    }

    private func session(_ start: Date, minutes: Double, palette: [String] = [], project: UUID? = nil) throws {
        try time.store.saveCreativeSession(CreativeSession(projectID: project, startedAt: start, endedAt: start.addingTimeInterval(minutes * 60),
                                                           focusedSeconds: minutes * 60, exports: ["/e/1.png", "/e/2.png"], palette: palette))
    }

    @MainActor
    func testTheRugGetsASplashPerCreativeDayAndStartsFreshEachMonth() throws {
        let calendar = Calendar.current
        let month = calendar.dateInterval(of: .month, for: time.now)!.start
        let day = { (n: Int) in calendar.date(byAdding: .day, value: n - 1, to: month)!.addingTimeInterval(12 * 3600) }
        try session(day(1), minutes: 45, palette: ["#112233"])
        try session(day(3), minutes: 20)                                  // not enough
        try session(day(3), minutes: 15, palette: ["#445566"])           // together: 35 min
        try session(calendar.date(byAdding: .day, value: -3, to: month)!, minutes: 60, palette: ["#778899"])   // last month
        let rug = module.sessions.rug()
        XCTAssertEqual(rug.map(\.day), [1, 3], "30 minutes makes a day; two sessions can add up")
        XCTAssertEqual(rug.map(\.color), ["#112233", "#445566"], "in that day's palette")
        XCTAssertEqual(module.sessions.rugHistory().first?.splashes.map(\.color), ["#778899"], "last month is kept for the stats")
        // Splashes always land in the same place, on the rug.
        for dayNumber in 1...31 {
            let place = CreativeLoftBuilderProbe.splash(dayNumber)
            XCTAssertEqual(place, CreativeLoftBuilderProbe.splash(dayNumber))
            XCTAssertLessThanOrEqual(simd_length(SIMD2(place.x - 0.1, place.z - 0.35)), 0.7)
        }
    }

    func testAutomationsInstallOnceWithTheNudgeOff() throws {
        try module.automations.install()
        for kind in CreativeAutomations.Kind.allCases {
            XCTAssertEqual(module.automations.workflow(kind)?.isEnabled, kind != .staleNudge, kind.rawValue)
        }
        let ids = module.automations.installed
        try module.automations.install()
        XCTAssertEqual(module.automations.installed, ids)
    }

    func testOfferingTheStudioOutsideItAtMostHourly() async throws {
        let space = try SpaceLibrary(core: time.core).createSpace(from: SpaceTemplates.creativeStudio)
        _ = try service.save(Project(name: "Robot", color: "", creative: CreativeInfo()))
        time.base.system.installedApps["org.blenderfoundation.blender"] = "Blender"
        _ = await time.core.engine.invoke(OfferStudioAction.id, parameters: ["app": "org.blenderfoundation.blender"], source: "test")
        let offer = try XCTUnwrap(offers.values.first)
        XCTAssertEqual(offer.payload["message"]?.stringValue, "Blender is open. Open the Creative Studio for Robot?")
        XCTAssertEqual(offer.payload["param.space"]?.stringValue, space.id.uuidString)
        _ = await time.core.engine.invoke(OfferStudioAction.id, parameters: ["app": "org.blenderfoundation.blender"], source: "test")
        XCTAssertEqual(offers.values.count, 1, "once an hour")
        time.advance(minutes: 61)
        try time.store.setPreference(space.id, for: ConditionCheck.activeSpacePreferenceKey)
        _ = await time.core.engine.invoke(OfferStudioAction.id, parameters: ["app": "org.blenderfoundation.blender"], source: "test")
        XCTAssertEqual(offers.values.count, 1, "not when you're already there")
    }

    func testEntryAsksWhichProjectWhenSeveralAreActiveAndRemembers() async throws {
        let space = try SpaceLibrary(core: time.core).createSpace(from: SpaceTemplates.creativeStudio)
        func project(_ name: String) throws -> Project {
            let main = try file("\(name)/\(name).blend")
            try FileManager.default.setAttributes([.modificationDate: time.now.addingTimeInterval(-3600)], ofItemAtPath: main)
            return try service.save(Project(name: name, color: "", creative: CreativeInfo(mainFiles: [main])))
        }
        let robot = try project("Robot")
        _ = try project("Poster")
        _ = await time.core.engine.invoke(ProjectOnEntryAction.id, parameters: ["space": .string(space.id.uuidString)], source: "test")
        let ask = try XCTUnwrap(offers.values.first { $0.name == AtlasEvent.Name.creativePickProject })
        XCTAssertEqual(ask.payload["projectIds"]?.stringValue?.split(separator: ",").count, 2)
        XCTAssertFalse(time.base.system.calls.contains { $0.hasPrefix("open-file:") }, "nothing opens until you pick")

        service.pick(robot.id)
        XCTAssertEqual(service.currentProject()?.id, robot.id)
        _ = await time.core.engine.invoke(ProjectOnEntryAction.id, parameters: ["space": .string(space.id.uuidString)], source: "test")
        XCTAssertEqual(offers.values.filter { $0.name == AtlasEvent.Name.creativePickProject }.count, 1, "remembered for the day")
        XCTAssertTrue(time.base.system.calls.contains("open-file:\(robot.creative!.mainFiles[0])"))
    }

    func testStaleNudgeOncePerProject() async throws {
        let main = try file("Old/old.blend", daysAgo: 20)
        _ = main
        let old = try service.save(Project(name: "Old", color: "", createdAt: time.now.addingTimeInterval(-30 * 86_400),
                                           creative: CreativeInfo(mainFiles: [main], status: .inProgress)))
        let realNow = LockedBox(Date())
        service.now = { realNow.value }
        _ = await time.core.engine.invoke(StaleNudgeAction.id, source: "test")
        let offer = try XCTUnwrap(offers.values.first)
        XCTAssertTrue(offer.payload["message"]?.stringValue?.hasPrefix("Old has been waiting 2 weeks") ?? false)
        XCTAssertEqual(offer.payload["param.project"]?.stringValue, old.id.uuidString)
        _ = await time.core.engine.invoke(StaleNudgeAction.id, source: "test")
        XCTAssertEqual(offers.values.count, 1, "once")
    }

    func testWeeklyRecap() async throws {
        let robot = try service.save(Project(name: "Robot", color: "", creative: CreativeInfo()))
        try session(time.now.addingTimeInterval(-2 * 86_400), minutes: 130, palette: ["#E8A6B4", "#FFC4A8"], project: robot.id)
        try session(time.now.addingTimeInterval(-86_400), minutes: 60, palette: ["#E8A6B4", "#8FB59A"])
        let text = WeeklyRecapAction.recap(service: service)
        XCTAssertEqual(text, "Robot 2 h 10 m · No project 1 h · 4 exports · palette #E8A6B4 #FFC4A8 #8FB59A")
        let run = await time.core.engine.invoke(WeeklyRecapAction.id, source: "test")
        XCTAssertEqual(run.state, .succeeded)
        XCTAssertTrue(time.base.system.calls.contains("notify:Your creative week"))
    }

    @MainActor
    func testWindowRugAndPainterInTheRoom() throws {
        let space = Space(name: "Creative Studio", group: .personal, templateID: CreativeLoft.templateID, accentColor: "#E8A6B4", slot: 0)
        let template = SpaceTemplates.creativeStudio
        let objects = template.objects.map { SpaceObject(spaceID: space.id, kind: $0.kind, label: $0.label, actionID: $0.actionID) }
        let room = RoomBuilder.build(space: space, room: template.room, objects: objects, detail: true)
        let motion = try XCTUnwrap(room.components[RoomMotionComponent.self]?.motion as? CreativeLoftMotion)
        XCTAssertNil(room.findEntity(named: "creativeitem:painter"))
        var state = CreativeRoomState(window: .init(sky: .night, weather: .rain), rug: [.init(day: 1, color: "#112233"), .init(day: 2, color: "#112233")],
                                      streak: 8, painter: .init(style: .creature))
        motion.update(state)
        XCTAssertNotNil(room.findEntity(named: "creativeitem:painter"), "the painter moves in")
        XCTAssertNotNil(room.findEntity(named: "rain-0"), "rain made when it first rains")
        XCTAssertEqual(room.findEntity(named: "rugSplashes")?.children.count, 1, "same colour, one mesh")
        for item in [CreativeRoomState.Item.window, .rug, .painter] {
            XCTAssertNotNil(room.findEntity(named: item.entityName)?.components[CollisionComponent.self], item.entityName)
            XCTAssertEqual(CreativeRoomState.Item(entityName: item.entityName), item)
        }
        state.painter = nil
        motion.update(state)
        XCTAssertNil(room.findEntity(named: "creativeitem:painter"), "gone when the Companion doesn't paint")
    }
}

/// Exposes the rug placement to tests.
enum CreativeLoftBuilderProbe {
    @MainActor
    static func splash(_ day: Int) -> SIMD3<Float> { CreativeLoftBuilder.splashPlacement(day: day).position }
}

/// Answers AppleScript with canned results, recording each script.
final class MockAppleScript: AppleScriptRunning, @unchecked Sendable {
    private let lock = NSLock()
    var results: [String: [String]?] = [:]   // by application name in the script
    private(set) var scripts: [String] = []

    func run(_ source: String) -> [String]? {
        lock.withLock { scripts.append(source) }
        for (app, result) in results where source.contains("tell application \"\(app)\"") { return result }
        return nil
    }
}

final class WatchModeTests: CreativeTestCase {
    private var time: TimeHarness!
    private var module: CreativeModule!
    private var service: CreativeService { module.service }
    private var script: MockAppleScript!

    override func setUpWithError() throws {
        try super.setUpWithError()
        time = try TimeHarness()
        module = try CreativeModule(core: time.core, thumbnails: ProjectThumbnails(folder: temp.appendingPathComponent("thumbs"), maker: SolidThumbnails()))
        module.service.now = { [environment = time.environment] in environment.now() }
        service.settings.dayBoundaryHour = 0
        script = MockAppleScript()
        service.scriptRunner = script
        service.tabReader = BrowserTabReader(runner: script, running: { ["com.google.Chrome", "com.apple.finder"] })
    }

    func testReadsTheFrontTabFromChromeOrSafari() {
        script.results["Google Chrome"] = ["https://www.youtube.com/watch?v=abc", "(3) Blender Donut Tutorial - Part 1 - YouTube"]
        let chrome = BrowserTabReader(runner: script, running: { ["com.google.Chrome"] }).frontTab()
        XCTAssertEqual(chrome, BrowserTab(url: "https://www.youtube.com/watch?v=abc", title: "Blender Donut Tutorial - Part 1", browser: "com.google.Chrome"))
        XCTAssertTrue(script.scripts.last?.contains("active tab of front window") ?? false)

        script.results["Safari"] = ["https://www.youtube.com/watch?v=xyz", "Sculpting basics - YouTube"]
        let safari = BrowserTabReader(runner: script, running: { ["com.apple.Safari", "com.google.Chrome"] }).frontTab()
        XCTAssertEqual(safari?.title, "Sculpting basics", "the frontmost browser wins")
        XCTAssertEqual(safari?.browser, "com.apple.Safari")

        XCTAssertNil(BrowserTabReader(runner: script, running: { ["com.apple.finder"] }).frontTab(), "no browser open")
        script.results["Google Chrome"] = .some(nil)
        XCTAssertNil(BrowserTabReader(runner: script, running: { ["com.google.Chrome"] }).frontTab(), "permission refused")
        script.results["Google Chrome"] = ["chrome://newtab/", "New Tab"]
        XCTAssertNil(BrowserTabReader(runner: script, running: { ["com.google.Chrome"] }).frontTab(), "not a web page")
        script.results["Google Chrome"] = ["https://example.com/x", ""]
        XCTAssertEqual(BrowserTabReader(runner: script, running: { ["com.google.Chrome"] }).frontTab()?.title, "https://example.com/x")
    }

    func testSavingATutorialGoesToTheCurrentProjectOnce() throws {
        XCTAssertThrowsError(try service.saveTutorial(sessions: module.sessions)) { XCTAssertEqual($0 as? TutorialError, .noProject) }
        _ = try service.save(Project(name: "Poster", color: "", createdAt: time.now.addingTimeInterval(-100), creative: CreativeInfo()))
        let robot = try service.save(Project(name: "Robot Model", color: "", creative: CreativeInfo()))
        service.noteOpened(robot.id)
        XCTAssertThrowsError(try service.saveTutorial(sessions: module.sessions)) { XCTAssertEqual($0 as? TutorialError, .noTab) }

        script.results["Google Chrome"] = ["https://www.youtube.com/watch?v=abc", "Blender Donut Tutorial - YouTube"]
        try module.sessions.start(kind: .watch)
        let saved = try service.saveTutorial(sessions: module.sessions)
        XCTAssertEqual(saved.project.id, robot.id)
        _ = try service.saveTutorial(sessions: module.sessions)
        let links = service.tutorials(of: service.project(id: robot.id))
        XCTAssertEqual(links.map(\.title), ["Blender Donut Tutorial"], "once per video")
        XCTAssertEqual(links.first?.kind, .tutorial)
        XCTAssertTrue(module.roomState().easel?.detail.contains("1 saved tutorial") ?? false)

        time.advance(minutes: 70)
        let summary = try XCTUnwrap(module.sessions.end())
        XCTAssertEqual(summary.headline, "1 h 10 m watching · 1 tutorial saved to Robot Model")
    }

    func testWatchTimeCountsOnlyAsTheSettingSays() throws {
        let day = service.settings.day
        let today = day.start(of: time.now)
        func session(_ kind: CreativeSession.Kind, minutes: Double, daysAgo: Int, tutorials: [String] = []) throws {
            let start = today.addingTimeInterval(-Double(daysAgo) * 86_400 + 3600)
            try time.store.saveCreativeSession(CreativeSession(kind: kind, startedAt: start, endedAt: start.addingTimeInterval(minutes * 60),
                                                               focusedSeconds: minutes * 60, tutorials: tutorials))
        }
        try session(.watch, minutes: 60, daysAgo: 0)
        try session(.watch, minutes: 45, daysAgo: 1, tutorials: ["https://youtu.be/a"])
        try session(.create, minutes: 40, daysAgo: 2)
        XCTAssertEqual(module.sessions.createdToday(), 0, "watching isn't creating, by default")
        XCTAssertEqual(module.sessions.streak(), 0)
        service.settings.countWatchTime = .tutorials
        XCTAssertEqual(module.sessions.createdToday(), 0, "no tutorial saved today")
        XCTAssertEqual(module.sessions.streak(), 2, "yesterday's watching saved a tutorial")
        service.settings.countWatchTime = .always
        XCTAssertEqual(module.sessions.createdToday(), 60 * 60)
        XCTAssertEqual(module.sessions.streak(), 3)
        XCTAssertTrue(module.sessions.weeklyHours().contains { $0.kind == .watch }, "the Stats panel shows it separately")
    }

    func testStartWatchOpensYouTubeInItsOwnWindowAndStartsASession() async throws {
        script.results["Google Chrome"] = ["ok"]
        let run = await time.core.engine.invoke(StartWatchAction.id, source: "test")
        XCTAssertNotEqual(run.state, .failed, run.error ?? "")
        XCTAssertTrue(module.sessions.isWatching)
        XCTAssertEqual(time.time.focus.session?.title, "Watch · Focus")
        let opened = try XCTUnwrap(script.scripts.first { $0.contains("make new window") })
        XCTAssertTrue(opened.contains("https://www.youtube.com/playlist?list=WL"), "Watch Later by default")
        XCTAssertTrue(module.roomState().isWatching)
        XCTAssertTrue(module.roomState().dimmed)
    }

    func testEnteringOffersJustWatchingAndRemembersIt() async throws {
        let space = try SpaceLibrary(core: time.core).createSpace(from: SpaceTemplates.creativeStudio)
        try module.automations.install()
        XCTAssertTrue(try time.store.profiles(spaceID: space.id).contains { $0.name == "Watch" }, "the Watch profile")
        _ = try service.save(Project(name: "Robot", color: "", creative: CreativeInfo()))
        let picks = CreativeEventCollector()
        _ = time.core.events.subscribe(AtlasEvent.Name.creativePickProject) { picks.append($0) }
        _ = await time.core.engine.invoke(ProjectOnEntryAction.id, parameters: ["space": .string(space.id.uuidString)], source: "test")
        XCTAssertEqual(picks.values.first?.payload["watch"], true, "one project, but “Just watching” is on offer")

        service.pick(nil)
        script.results["Google Chrome"] = ["ok"]
        _ = await time.core.engine.invoke(ProjectOnEntryAction.id, parameters: ["space": .string(space.id.uuidString)], source: "test")
        XCTAssertEqual(picks.values.count, 1, "remembered for the day")
        XCTAssertTrue(module.sessions.isWatching, "straight back into Watch mode")
    }

    @MainActor
    func testTheTVGlowsAndTheCompanionGrabsPopcorn() throws {
        let space = Space(name: "Creative Studio", group: .personal, templateID: CreativeLoft.templateID, accentColor: "#E8A6B4", slot: 0)
        let template = SpaceTemplates.creativeStudio
        let objects = template.objects.map { SpaceObject(spaceID: space.id, kind: $0.kind, label: $0.label, actionID: $0.actionID) }
        let room = RoomBuilder.build(space: space, room: template.room, objects: objects, detail: true)
        let tv = try XCTUnwrap(room.findEntity(named: "creativeitem:tv"))
        XCTAssertNotNil(tv.components[CollisionComponent.self])
        func count(_ entity: Entity) -> Int { 1 + entity.children.reduce(0) { $0 + count($1) } }
        XCTAssertLessThan(count(tv), 10, "under 10 entities")
        let motion = try XCTUnwrap(room.components[RoomMotionComponent.self]?.motion as? CreativeLoftMotion)
        var painter = CreativeRoomState.Painter(style: .robot)
        motion.update(CreativeRoomState(painter: painter))
        let figure = try XCTUnwrap(motion.parts.painter)
        XCTAssertFalse(figure.popcorn.isEnabled)
        painter.isWatching = true
        var watching = CreativeRoomState(painter: painter)
        watching.isWatching = true
        watching.dimmed = true
        motion.update(watching)
        XCTAssertTrue(figure.popcorn.isEnabled)
        XCTAssertFalse(figure.easel.isEnabled)
        XCTAssertEqual(figure.body.position, CreativeLoftBuilder.Painter.seat, "on the window seat")
        XCTAssertGreaterThan(motion.parts.tvLight?.light.intensity ?? 0, 0, "the screen glows")
        XCTAssertEqual(CreativeRoomState.Item(entityName: "creativeitem:tv"), .tv)
    }
}
