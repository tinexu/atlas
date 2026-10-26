import XCTest
@testable import AtlasCore
@testable import AtlasOrbit

/// Delivers folder changes by hand.
final class MockTreeWatcher: FileTreeWatching, @unchecked Sendable {
    private let lock = NSLock()
    private var handlers: [String: @Sendable ([FileChange]) -> Void] = [:]

    func watchTree(_ path: String, _ handler: @escaping @Sendable ([FileChange]) -> Void) throws -> TriggerToken {
        lock.withLock { handlers[path] = handler }
        return TriggerToken { [weak self] in self?.lock.withLock { _ = self?.handlers.removeValue(forKey: path) } }
    }

    func send(_ changes: [FileChange], under root: String) {
        lock.withLock { handlers[root] }?(changes)
    }
}

/// Readings set by the test.
final class MockHealthSensor: HealthSensor, @unchecked Sendable {
    var next = HealthSample(cpu: 10, memoryUsed: 4_000_000_000, memoryTotal: 16_000_000_000, diskFree: 100_000_000_000,
                            diskTotal: 500_000_000_000, battery: 80, isCharging: false)
    func sample() -> HealthSample { next }
    func topProcesses(limit: Int) -> [ProcessUsage] { [] }
    func batteryCycleCount() -> Int? { 120 }
}

/// A real temporary folder, removed afterwards.
final class TempFolder {
    let path: String

    init() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("atlas-orbit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        path = FileLocation.normalize(base.path)
    }

    deinit { try? FileManager.default.removeItem(atPath: path) }

    @discardableResult
    func file(_ relative: String, bytes: Int = 10, fill: UInt8 = 0x61) throws -> String {
        try write(relative, Data(repeating: fill, count: bytes))
    }

    @discardableResult
    func write(_ relative: String, _ data: Data) throws -> String {
        let full = (path as NSString).appendingPathComponent(relative)
        try FileManager.default.createDirectory(atPath: (full as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try data.write(to: URL(fileURLWithPath: full))
        return FileLocation.normalize(full)
    }

    func folder(_ relative: String) throws -> String {
        let full = (path as NSString).appendingPathComponent(relative)
        try FileManager.default.createDirectory(atPath: full, withIntermediateDirectories: true)
        return FileLocation.normalize(full)
    }
}

/// Collects events by name.
final class EventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [AtlasEvent] = []

    init(_ bus: EventBus, _ pattern: String = "*") {
        bus.subscribe(pattern) { [weak self] event in self?.lock.withLock { self?.events.append(event) } }
    }

    func named(_ name: String) -> [AtlasEvent] { lock.withLock { events.filter { $0.name == name } } }
    var all: [AtlasEvent] { lock.withLock { events } }
}

extension TestHarness {
    /// An indexer over a real folder, with a mock watcher.
    func makeIndexer(_ folder: TempFolder) throws -> (FileIndexer, MockTreeWatcher, FileLocation) {
        let watcher = MockTreeWatcher()
        let indexer = FileIndexer(store: store, events: core.events, watcher: watcher)
        indexer.throttle = 0
        let location = FileLocation(path: folder.path)
        try store.saveLocation(location)
        core.refreshFileAccess()
        indexer.watch(location)
        return (indexer, watcher, location)
    }
}

// MARK: - Indexer

final class FileIndexerTests: XCTestCase {
    func testInitialWalkStoresMetadataAndFolderTotals() async throws {
        let h = try TestHarness()
        let folder = try TempFolder()
        try folder.file("a.pdf", bytes: 100)
        try folder.file("Photos/b.png", bytes: 200)
        try folder.file("Photos/Trip/c.jpg", bytes: 300)
        let (indexer, _, location) = try h.makeIndexer(folder)

        indexer.index(locationID: location.id)
        await indexer.waitUntilIdle()

        let root = try XCTUnwrap(try h.store.entry(at: folder.path))
        XCTAssertEqual(root.size, 600)
        XCTAssertEqual(root.itemCount, 3)
        let photos = try XCTUnwrap(try h.store.entry(at: folder.path + "/Photos"))
        XCTAssertTrue(photos.isFolder)
        XCTAssertEqual(photos.size, 500, "Folder size includes subfolders")
        XCTAssertEqual(photos.itemCount, 2)
        let pdf = try XCTUnwrap(try h.store.entry(at: folder.path + "/a.pdf"))
        XCTAssertEqual(pdf.ext, "pdf")
        XCTAssertEqual(pdf.category, .document)
        XCTAssertEqual(pdf.parent, folder.path)
        XCTAssertNotNil(pdf.modifiedAt)
        XCTAssertEqual(try h.store.entry(at: folder.path + "/Photos/Trip/c.jpg")?.category, .image)
        let saved = try XCTUnwrap(try h.store.location(id: location.id))
        XCTAssertEqual(saved.fileCount, 3)
        XCTAssertEqual(saved.totalSize, 600)
        XCTAssertEqual(saved.indexState, .complete)
        XCTAssertNotNil(saved.lastIndexedAt)
    }

    func testExclusionsAndPackages() async throws {
        let h = try TestHarness()
        let folder = try TempFolder()
        try folder.file("keep.txt")
        try folder.file(".hidden")
        try folder.file(".git/config")
        try folder.file("project/node_modules/lib/index.js")
        try folder.file("project/.build/debug/app")
        try folder.file("project/main.swift")
        try folder.file("Tool.app/Contents/MacOS/Tool", bytes: 1_000)
        try folder.file("Tool.app/Contents/Info.plist", bytes: 500)
        try folder.file("Library/Caches/thing.cache")
        let (indexer, _, location) = try h.makeIndexer(folder)

        indexer.index(locationID: location.id)
        await indexer.waitUntilIdle()

        let all = try h.store.entries(matching: FileQuery(roots: [folder.path], limit: 1_000)).map(\.path)
        XCTAssertTrue(all.contains(folder.path + "/keep.txt"))
        XCTAssertTrue(all.contains(folder.path + "/project/main.swift"))
        XCTAssertFalse(all.contains { $0.contains("/.hidden") || $0.contains("/.git") }, "Hidden files are skipped")
        XCTAssertFalse(all.contains { $0.contains("node_modules") || $0.contains(".build") })
        XCTAssertFalse(all.contains { $0.contains("Library/Caches/") })
        let app = try XCTUnwrap(try h.store.entry(at: folder.path + "/Tool.app"))
        XCTAssertTrue(app.isPackage, "Apps are single files")
        XCTAssertEqual(app.category, .app)
        XCTAssertEqual(app.size, 1_500)
        XCTAssertFalse(all.contains { $0.contains("Tool.app/") }, "Package contents aren't indexed")
    }

    func testIncrementalUpdatesPublishEvents() async throws {
        let h = try TestHarness()
        let folder = try TempFolder()
        try folder.file("Docs/old.txt", bytes: 100)
        let (indexer, watcher, location) = try h.makeIndexer(folder)
        let recorder = EventRecorder(h.core.events, "file.*")
        indexer.index(locationID: location.id)
        await indexer.waitUntilIdle()

        // Created
        let created = try folder.file("Docs/new.pdf", bytes: 50)
        watcher.send([FileChange(path: created, kind: .created)], under: folder.path)
        await indexer.waitUntilIdle()
        XCTAssertNotNil(try h.store.entry(at: created))
        XCTAssertEqual(try h.store.entry(at: folder.path + "/Docs")?.size, 150, "Ancestor totals follow")
        XCTAssertEqual(try h.store.entry(at: folder.path)?.itemCount, 2)
        XCTAssertEqual(recorder.named(AtlasEvent.Name.fileCreatedEvent).last?.payload["path"], .string(created))

        // Modified
        try Data(repeating: 1, count: 80).write(to: URL(fileURLWithPath: created))
        watcher.send([FileChange(path: created, kind: .modified)], under: folder.path)
        await indexer.waitUntilIdle()
        XCTAssertEqual(try h.store.entry(at: created)?.size, 80)
        XCTAssertEqual(try h.store.entry(at: folder.path)?.size, 180)
        XCTAssertEqual(recorder.named(AtlasEvent.Name.fileModifiedEvent).count, 1)

        // Renamed (moved): same inode, new path
        let renamed = folder.path + "/renamed.pdf"
        try FileManager.default.moveItem(atPath: created, toPath: renamed)
        watcher.send([FileChange(path: created, kind: .renamed), FileChange(path: renamed, kind: .renamed)], under: folder.path)
        await indexer.waitUntilIdle()
        XCTAssertNil(try h.store.entry(at: created))
        XCTAssertNotNil(try h.store.entry(at: renamed))
        XCTAssertEqual(try h.store.entry(at: folder.path + "/Docs")?.size, 100)
        XCTAssertEqual(try h.store.entry(at: folder.path)?.size, 180)
        XCTAssertEqual(recorder.named(AtlasEvent.Name.fileMovedEvent).last?.payload["oldPath"], .string(created))

        // Deleted
        try FileManager.default.removeItem(atPath: renamed)
        watcher.send([FileChange(path: renamed, kind: .removed)], under: folder.path)
        await indexer.waitUntilIdle()
        XCTAssertNil(try h.store.entry(at: renamed))
        XCTAssertEqual(try h.store.entry(at: folder.path)?.size, 100)
        XCTAssertEqual(try h.store.location(id: location.id)?.fileCount, 1)
        XCTAssertEqual(recorder.named(AtlasEvent.Name.fileDeletedEvent).count, 1)
    }

    func testMovedFileKeepsProjectLinkAndDeletedFileBreaksIt() async throws {
        let h = try TestHarness()
        let folder = try TempFolder()
        let spec = try folder.file("spec.md")
        let notes = try folder.file("notes.md")
        let (indexer, watcher, location) = try h.makeIndexer(folder)
        indexer.index(locationID: location.id)
        await indexer.waitUntilIdle()
        try h.store.saveProject(Project(name: "P", links: [ProjectLink(path: spec), ProjectLink(path: notes)]))

        let moved = try folder.folder("Archive") + "/spec.md"
        try FileManager.default.moveItem(atPath: spec, toPath: moved)
        try FileManager.default.removeItem(atPath: notes)
        watcher.send([FileChange(path: spec, kind: .renamed), FileChange(path: moved, kind: .renamed),
                      FileChange(path: notes, kind: .removed)], under: folder.path)
        await indexer.waitUntilIdle()

        let links = try XCTUnwrap(try h.store.projects().first).links
        XCTAssertEqual(links.first { $0.name == "spec.md" }?.path, moved, "Link follows the move")
        XCTAssertEqual(links.first { $0.name == "notes.md" }?.isBroken, true, "Deleted file's link is broken")
    }

    func testRewalkRemovesFilesDeletedWhileNotWatching() async throws {
        let h = try TestHarness()
        let folder = try TempFolder()
        let gone = try folder.file("gone.txt")
        try folder.file("stays.txt")
        let (indexer, _, location) = try h.makeIndexer(folder)
        indexer.index(locationID: location.id)
        await indexer.waitUntilIdle()
        try FileManager.default.removeItem(atPath: gone)

        indexer.index(locationID: location.id)   // as at the next launch
        await indexer.waitUntilIdle()

        XCTAssertNil(try h.store.entry(at: gone))
        XCTAssertEqual(try h.store.location(id: location.id)?.fileCount, 1)
    }

    func testPauseStopsTheWalkAndResumeFinishesIt() async throws {
        let h = try TestHarness()
        let folder = try TempFolder()
        for i in 0..<50 { try folder.file("f\(i).txt") }
        let (indexer, _, location) = try h.makeIndexer(folder)

        indexer.setPaused(true)
        indexer.index(locationID: location.id)
        await indexer.waitUntilIdle()
        XCTAssertEqual(indexer.currentProgress[location.id]?.phase, .paused)
        XCTAssertNotEqual(try h.store.location(id: location.id)?.indexState, .complete)

        indexer.setPaused(false)
        await indexer.waitUntilIdle()
        XCTAssertEqual(try h.store.location(id: location.id)?.fileCount, 50)
        XCTAssertEqual(try h.store.location(id: location.id)?.indexState, .complete)
    }

    func testLargeTreeOf100kFiles() async throws {
        let h = try TestHarness()
        let folder = try TempFolder()
        // 100 folders × 1,000 empty files, created with raw syscalls for speed.
        for d in 0..<100 {
            let dir = try folder.folder("d\(d)")
            for f in 0..<1_000 {
                let fd = open(dir + "/f\(f).txt", O_CREAT | O_WRONLY, 0o644)
                if fd >= 0 { close(fd) }
            }
        }
        let (indexer, _, location) = try h.makeIndexer(folder)
        indexer.batchSize = 1_000

        let start = Date()
        indexer.index(locationID: location.id)
        await indexer.waitUntilIdle()
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertEqual(try h.store.location(id: location.id)?.fileCount, 100_000)
        XCTAssertEqual(try h.store.entryCount(locationID: location.id), 100_000)
        XCTAssertEqual(try h.store.entry(at: folder.path + "/d42")?.itemCount, 1_000)
        XCTAssertLessThan(elapsed, 120, "Indexed 100k files in \(Int(elapsed))s")
        print("Indexed 100,000 files in \(String(format: "%.1f", elapsed))s")
    }
}

// MARK: - File actions

final class OrbitFileActionTests: XCTestCase {
    func testRefusesPathsOutsideAuthorizedFolders() async throws {
        let h = try TestHarness(authorizedFolders: ["/allowed"])
        h.system.existingPaths["/allowed"] = .directory
        h.system.existingPaths["/allowed/a.txt"] = .file
        h.system.existingPaths["/elsewhere/b.txt"] = .file

        let outside = await h.engine.invoke(MoveFileAction.id, parameters: ["path": "/elsewhere/b.txt", "destination": "/allowed"], source: "test")
        XCTAssertEqual(outside.state, .failed)
        XCTAssertTrue(outside.steps[0].error?.contains("folders you've added to Orbit") ?? false)

        let intoOutside = await h.engine.invoke(MoveFileAction.id, parameters: ["path": "/allowed/a.txt", "destination": "/elsewhere"], source: "test")
        XCTAssertEqual(intoOutside.state, .failed, "Destinations must be authorized too")

        let trash = await h.engine.invoke(TrashFileAction.id, parameters: ["path": "/elsewhere/b.txt"], source: "test", approvedIn: "test")
        XCTAssertEqual(trash.state, .failed)
        XCTAssertFalse(h.system.calls.contains { $0.hasPrefix("move:") || $0.hasPrefix("trash:") }, "Nothing was touched")
    }

    func testSymlinkCannotEscapeAnAuthorizedFolder() throws {
        let folder = try TempFolder()
        let outside = try TempFolder()
        try FileManager.default.createSymbolicLink(atPath: folder.path + "/link", withDestinationPath: outside.path)
        let policy = FileAccessPolicy(roots: [folder.path])
        XCTAssertTrue(policy.isAllowed(folder.path + "/real.txt"))
        XCTAssertFalse(policy.isAllowed(folder.path + "/link/secret.txt"))
        XCTAssertFalse(policy.isAllowed(folder.path + "/../x"))
    }

    func testNeverOverwritesAndSkipModeSkips() async throws {
        let h = try TestHarness()
        h.system.existingPaths["/a/report.pdf"] = .file
        h.system.existingPaths["/b"] = .directory
        h.system.existingPaths["/b/report.pdf"] = .file

        let numbered = await h.engine.invoke(CopyFileAction.id, parameters: ["path": "/a/report.pdf", "destination": "/b"], source: "test")
        XCTAssertEqual(numbered.steps[0].output["path"], "/b/report (2).pdf")

        let skipped = await h.engine.invoke(MoveFileAction.id, parameters: ["path": "/a/report.pdf", "destination": "/b", "ifExists": "skip"],
                                            source: "test")
        XCTAssertEqual(skipped.state, .succeeded)
        XCTAssertEqual(skipped.steps[0].output["skipped"], .bool(true))
        XCTAssertEqual(h.system.fileKind(atPath: "/a/report.pdf"), .file, "Skipped, not moved")

        h.system.existingPaths["/b/taken.pdf"] = .file
        let rename = await h.engine.invoke(RenameFileAction.id, parameters: ["path": "/b/report.pdf", "name": "taken.pdf"], source: "test")
        XCTAssertEqual(rename.steps[0].output["path"], "/b/taken (2).pdf")
        XCTAssertEqual(h.system.fileKind(atPath: "/b/taken.pdf"), .file, "The existing file is untouched")
    }

    func testUndoMoveRenameAndTrash() async throws {
        let h = try TestHarness()
        h.system.existingPaths["/dl/a.pdf"] = .file
        h.system.existingPaths["/dl/b.txt"] = .file
        h.system.existingPaths["/dl/c.zip"] = .file
        h.system.existingPaths["/docs"] = .directory

        let move = await h.engine.invoke(MoveFileAction.id, parameters: ["path": "/dl/a.pdf", "destination": "/docs"], source: "test")
        let rename = await h.engine.invoke(RenameFileAction.id, parameters: ["path": "/dl/b.txt", "name": "notes.txt"], source: "test")
        let trash = await h.engine.invoke(TrashFileAction.id, parameters: ["path": "/dl/c.zip"], source: "test", approvedIn: "test")
        XCTAssertEqual([move.state, rename.state, trash.state], [.succeeded, .succeeded, .succeeded])

        for run in [move, rename, trash] {
            let operation = try XCTUnwrap(try h.store.operations(runID: run.id).last { $0.kind != .createFolder })
            let undo = await h.engine.invoke(UndoFileOperationAction.id, parameters: ["operationId": .string(operation.id.uuidString)], source: "undo")
            XCTAssertEqual(undo.state, .succeeded, undo.error ?? "")
            XCTAssertNotNil(try h.store.operation(id: operation.id)?.undoneAt)
        }
        XCTAssertEqual(h.system.fileKind(atPath: "/dl/a.pdf"), .file)
        XCTAssertEqual(h.system.fileKind(atPath: "/docs/a.pdf"), .missing)
        XCTAssertEqual(h.system.fileKind(atPath: "/dl/b.txt"), .file)
        XCTAssertEqual(h.system.fileKind(atPath: "/dl/c.zip"), .file, "Put back from the Trash")
    }

    func testUndoSaysWhenItIsNoLongerPossible() async throws {
        let h = try TestHarness()
        h.system.existingPaths["/dl/a.pdf"] = .file
        h.system.existingPaths["/docs"] = .directory
        let move = await h.engine.invoke(MoveFileAction.id, parameters: ["path": "/dl/a.pdf", "destination": "/docs"], source: "test")
        let operation = try XCTUnwrap(try h.store.operations(runID: move.id).first { $0.kind == .move })
        h.system.existingPaths["/dl/a.pdf"] = .file   // something new arrived at the old place

        let undo = await h.engine.invoke(UndoFileOperationAction.id, parameters: ["operationId": .string(operation.id.uuidString)], source: "undo")
        XCTAssertEqual(undo.state, .failed)
        XCTAssertTrue(undo.steps[0].error?.contains("never replaces") ?? false)

        let copy = await h.engine.invoke(CopyFileAction.id, parameters: ["path": "/docs/a.pdf", "destination": "/dl"], source: "test")
        let copyOp = try XCTUnwrap(try h.store.operations(runID: copy.id).first)
        let undoCopy = await h.engine.invoke(UndoFileOperationAction.id, parameters: ["operationId": .string(copyOp.id.uuidString)], source: "undo")
        XCTAssertEqual(undoCopy.state, .failed)
        XCTAssertTrue(undoCopy.steps[0].error?.contains("can't be undone") ?? false)
    }

    func testTagAndUndoTag() async throws {
        let h = try TestHarness()
        h.system.existingPaths["/dl/a.pdf"] = .file
        try await h.system.setFileTags(["Red"], atPath: "/dl/a.pdf")
        let tag = await h.engine.invoke(TagFileAction.id, parameters: ["path": "/dl/a.pdf", "tags": "Work, School"], source: "test")
        XCTAssertEqual(tag.state, .succeeded)
        XCTAssertEqual(h.system.fileTags(atPath: "/dl/a.pdf"), ["Red", "Work", "School"])
        let op = try XCTUnwrap(try h.store.operations(runID: tag.id).first)
        _ = await h.engine.invoke(UndoFileOperationAction.id, parameters: ["operationId": .string(op.id.uuidString)], source: "undo")
        XCTAssertEqual(h.system.fileTags(atPath: "/dl/a.pdf"), ["Red"])
    }
}

// MARK: - Rules

final class FileRuleTests: XCTestCase {
    private func organizer(_ h: TestHarness) throws -> FileOrganizer {
        try h.core.registry.register(OrganizeFileAction(store: h.store, registry: h.core.registry))
        return FileOrganizer(core: h.core)
    }

    func testConditionMatching() async throws {
        let h = try TestHarness()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        h.system.existingPaths["/dl/Screenshot 2026-10-25 at 10.00.00.png"] = .file
        h.system.existingPaths["/dl/setup.dmg"] = .file
        h.system.existingPaths["/dl/CS101 Lecture 3.pdf"] = .file
        h.system.fileInfos["/dl/setup.dmg"] = FileInfo(createdAt: now.addingTimeInterval(-40 * 86_400), sources: ["https://example.com/setup.dmg"])
        h.system.fileSizes["/dl/setup.dmg"] = 200_000_000
        let rules = FileOrganizer.starterRules()

        let screenshot = rules[0], installers = rules[1], courses = rules[2]
        try await h.expect(await RuleMatcher.matches(screenshot, path: "/dl/Screenshot 2026-10-25 at 10.00.00.png", system: h.system))
        try await h.expect(!(await RuleMatcher.matches(screenshot, path: "/dl/setup.dmg", system: h.system)))
        try await h.expect(await RuleMatcher.matches(installers, path: "/dl/setup.dmg", system: h.system, now: now))
        try await h.expect(!(await RuleMatcher.matches(installers, path: "/dl/setup.dmg", system: h.system, now: now.addingTimeInterval(-20 * 86_400))),
                       "Not old enough yet")
        try await h.expect(await RuleMatcher.matches(courses, path: "/dl/CS101 Lecture 3.pdf", system: h.system))
        XCTAssertEqual(courses.matchedText(in: "CS101 Lecture 3.pdf"), "CS101")

        var any = FileRule(name: "Big or from example", folders: ["/dl"], match: .any,
                           conditions: [.sizeAbove(megabytes: 1_000), .sourceContains("example.com")], action: .tag("Web"))
        try await h.expect(await RuleMatcher.matches(any, path: "/dl/setup.dmg", system: h.system))
        any.match = .all
        try await h.expect(!(await RuleMatcher.matches(any, path: "/dl/setup.dmg", system: h.system)))
    }

    func testRenamePatterns() {
        let date = DateComponents(calendar: Calendar(identifier: .gregorian), timeZone: .current, year: 2026, month: 3, day: 5).date
        XCTAssertEqual(RenamePattern.resolve("{date:yyyy-MM-dd} {name}.{ext}", path: "/x/Invoices/bill.pdf", date: date), "2026-03-05 bill.pdf")
        XCTAssertEqual(RenamePattern.resolve("{parentFolder} - {name}", path: "/x/Invoices/bill.pdf", date: date), "Invoices - bill")
        XCTAssertEqual(RenamePattern.newName("{parentFolder} - {name}", path: "/x/Invoices/bill.pdf", date: date) { _ in false },
                       "Invoices - bill.pdf", "Keeps the extension when the pattern has none")
        let taken: Set<String> = ["Scan 1.pdf", "Scan 2.pdf"]
        XCTAssertEqual(RenamePattern.newName("Scan {counter}", path: "/x/img.pdf", date: date) { taken.contains($0) }, "Scan 3.pdf")
        XCTAssertEqual(RenamePattern.resolve("{folder}/Screenshots", path: "/Users/me/Desktop/s.png", date: date), "/Users/me/Desktop/Screenshots")
        XCTAssertEqual(RenamePattern.resolve("~/Courses/{match}", path: "/d/a.pdf", date: date, match: "CS101"), "~/Courses/CS101")
    }

    func testRuleCompilesToAWorkflowAndMovesNewFiles() async throws {
        let h = try TestHarness()
        let environment = h.startTriggers()
        let organizer = try organizer(h)
        h.system.existingPaths["/desk"] = .directory
        var rule = FileOrganizer.starterRules()[0]
        rule.folders = ["/desk"]
        rule.isEnabled = true
        let saved = try organizer.save(rule)

        let workflow = try XCTUnwrap(try h.store.workflow(id: XCTUnwrap(saved.workflowID)))
        XCTAssertTrue(workflow.isEnabled)
        XCTAssertEqual(workflow.triggerNodes.count, 1)
        XCTAssertTrue(workflow.steps.contains { $0.kind == .condition })
        XCTAssertTrue(workflow.steps.contains { $0.actionID == OrganizeFileAction.id })
        XCTAssertTrue(h.core.validate(workflow).filter { $0.severity == .error }.isEmpty)

        let shot = "/desk/Screenshot 2026-10-25 at 10.00.00.png"
        h.system.existingPaths[shot] = .file
        await h.waitUntil { environment.listenerCount > 0 }
        environment.fileCreated(shot)
        let moved = await h.waitUntil { h.system.fileKind(atPath: "/desk/Screenshots/Screenshot 2026-10-25 at 10.00.00.png") == .file }
        XCTAssertTrue(moved)
        let run = try XCTUnwrap(try h.runs(of: workflow).last)
        XCTAssertFalse(try h.store.operations(runID: run.id).isEmpty, "Logged for undo")
    }

    func testAskFirstAndCompetingRulesGoToTheReviewQueue() async throws {
        let h = try TestHarness()
        let organizer = try organizer(h)
        h.system.existingPaths["/dl/old.dmg"] = .file
        h.system.fileInfos["/dl/old.dmg"] = FileInfo(createdAt: Date().addingTimeInterval(-60 * 86_400))
        var installers = FileOrganizer.starterRules()[1]
        installers.folders = ["/dl"]
        installers.isEnabled = true
        installers = try organizer.save(installers)
        XCTAssertEqual(installers.mode, .askFirst)

        let workflow = try XCTUnwrap(try h.store.workflow(id: XCTUnwrap(installers.workflowID)))
        let run = await h.engine.run(workflow, trigger: FileOrganizer.sweepTrigger, payload: FileOrganizer.payload(for: "/dl/old.dmg"),
                                     entryNodeID: workflow.triggerNodes.first?.id)
        XCTAssertEqual(run.state, .succeeded, run.error ?? "")
        XCTAssertEqual(h.system.fileKind(atPath: "/dl/old.dmg"), .file, "Not trashed without approval")
        let item = try XCTUnwrap(organizer.pendingReviews().first)
        XCTAssertEqual(item.path, "/dl/old.dmg")
        XCTAssertEqual(item.action, .trash)

        // Approving runs it through the engine, without a second prompt.
        let approved = await organizer.approve(item)
        XCTAssertEqual(approved?.state, .succeeded)
        XCTAssertEqual(h.system.fileKind(atPath: "/dl/old.dmg"), .missing)
        XCTAssertTrue(organizer.pendingReviews().isEmpty)

        // Two automatic rules matching one file: neither acts.
        h.system.existingPaths["/dl/CS101 notes.pdf"] = .file
        var courses = FileOrganizer.starterRules()[2]
        courses.folders = ["/dl"]
        courses.isEnabled = true
        courses = try organizer.save(courses)
        let tagAll = try organizer.save(FileRule(name: "Tag PDFs", isEnabled: true, folders: ["/dl"], conditions: [.extensions("pdf")],
                                                 action: .tag("PDF")))
        let coursesFlow = try XCTUnwrap(try h.store.workflow(id: XCTUnwrap(courses.workflowID)))
        _ = await h.engine.run(coursesFlow, trigger: "test", payload: FileOrganizer.payload(for: "/dl/CS101 notes.pdf"),
                               entryNodeID: coursesFlow.triggerNodes.first?.id)
        XCTAssertEqual(h.system.fileKind(atPath: "/dl/CS101 notes.pdf"), .file)
        let conflict = try XCTUnwrap(organizer.pendingReviews().first { $0.path == "/dl/CS101 notes.pdf" })
        XCTAssertTrue(conflict.reason.contains("Matches 2 rules"))
        XCTAssertEqual(Set(conflict.ruleIDs), [courses.id, tagAll.id])
    }

    func testDryRunChangesNothing() async throws {
        let folder = try TempFolder()
        try folder.file("Screenshot 2026-01-01 at 09.00.00.png")
        try folder.file("Screenshot 2026-01-02 at 09.00.00.png")
        try folder.file("notes.txt")
        // Dry runs look at real files, so use the real file system.
        let store = try AtlasStore.inMemory()
        try store.saveLocation(FileLocation(path: folder.path))
        let core = AtlasCore(store: store, system: MacSystemAdapter(), permissionProvider: MockPermissionProvider())
        var rule = FileOrganizer.starterRules()[0]
        rule.folders = [folder.path]

        let items = await FileOrganizer(core: core).dryRun(rule)

        XCTAssertEqual(items.count, 2)
        XCTAssertTrue(items.allSatisfy { $0.outcome.hasPrefix("Move to") }, items.map(\.outcome).joined(separator: "; "))
        XCTAssertEqual(items.first?.destination, folder.path + "/Screenshots/Screenshot 2026-01-01 at 09.00.00.png")
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
        XCTAssertEqual(names, ["Screenshot 2026-01-01 at 09.00.00.png", "Screenshot 2026-01-02 at 09.00.00.png", "notes.txt"], "Nothing moved")
        XCTAssertTrue(try store.recentOperations().isEmpty)
    }

    func testSweepRunsAgeRulesForExistingFiles() async throws {
        let h = try TestHarness()
        let organizer = try organizer(h)
        h.system.existingPaths["/dl/a.dmg"] = .file
        h.system.fileInfos["/dl/a.dmg"] = FileInfo(createdAt: Date().addingTimeInterval(-45 * 86_400))
        let location = FileLocation(path: "/dl")
        try h.store.saveLocation(location)
        try h.store.upsertEntries([FileEntry(path: "/dl", locationID: location.id, isDirectory: true),
                                   FileEntry(path: "/dl/a.dmg", locationID: location.id, size: 10)], generation: 1)
        var rule = FileOrganizer.starterRules()[1]
        rule.folders = ["/dl"]
        rule.isEnabled = true
        _ = try organizer.save(rule)

        let started = await organizer.sweep()
        XCTAssertEqual(started, 1)
        let queued = await h.waitUntil { !organizer.pendingReviews().isEmpty }
        XCTAssertTrue(queued)
    }
}

// MARK: - Duplicates

final class DuplicateFinderTests: XCTestCase {
    private func index(_ h: TestHarness, _ folder: TempFolder) async throws {
        let (indexer, _, location) = try h.makeIndexer(folder)
        indexer.index(locationID: location.id)
        await indexer.waitUntilIdle()
    }

    func testExactDuplicatesOnly() async throws {
        let h = try TestHarness()
        let folder = try TempFolder()
        try folder.file("a/one.bin", bytes: 1_000, fill: 1)
        try folder.file("b/copy.bin", bytes: 1_000, fill: 1)
        try folder.file("c/same-size-different.bin", bytes: 1_000, fill: 2)
        try folder.file("unique.bin", bytes: 999, fill: 1)
        try await index(h, folder)

        let sets = try await DuplicateFinder(store: h.store, events: h.core.events).find()
        XCTAssertEqual(sets.count, 1)
        XCTAssertEqual(Set(sets[0].files.map(\.name)), ["one.bin", "copy.bin"], "Same size but different bytes isn't a duplicate")
        XCTAssertEqual(sets[0].recoverable, 1_000)
    }

    func testPartialHashCollisionIsResolvedByFullHash() async throws {
        let h = try TestHarness()
        let folder = try TempFolder()
        let chunk = DuplicateFinder.partialChunk
        var first = Data(repeating: 7, count: chunk * 3)
        var second = first
        first[chunk + 10] = 1      // differ only in the middle
        second[chunk + 10] = 2
        let a = try folder.write("a.bin", first)
        let b = try folder.write("b.bin", second)
        try await index(h, folder)

        XCTAssertEqual(DuplicateFinder.partialHash(of: a, size: Int64(first.count)), DuplicateFinder.partialHash(of: b, size: Int64(second.count)))
        let sets = try await DuplicateFinder(store: h.store, events: h.core.events).find()
        XCTAssertTrue(sets.isEmpty)
    }

    func testHardLinksAreNotDuplicates() async throws {
        let h = try TestHarness()
        let folder = try TempFolder()
        let original = try folder.file("original.bin", bytes: 5_000, fill: 3)
        try FileManager.default.linkItem(atPath: original, toPath: folder.path + "/hardlink.bin")
        try await index(h, folder)

        let sets = try await DuplicateFinder(store: h.store, events: h.core.events).find()
        XCTAssertTrue(sets.isEmpty, "Removing a hard link frees no space")
    }
}

// MARK: - Search

final class SearchQueryTests: XCTestCase {
    func testParser() throws {
        let q = SearchQuery.parse("ext:pdf modified:<30d size:>10mb neural \"deep nets\" type:image in:Downloads")
        XCTAssertEqual(q.extensions, ["pdf"])
        XCTAssertEqual(q.minSize, 10_000_000)
        XCTAssertEqual(q.terms, ["neural", "deep nets"])
        XCTAssertEqual(q.categories, [.image])
        XCTAssertEqual(q.folders, ["Downloads"])
        guard case .age(.less, let seconds, _)? = q.modified else { return XCTFail("modified") }
        XCTAssertEqual(seconds, 30 * 86_400)
        XCTAssertTrue(q.problems.isEmpty)

        let sizes = SearchQuery.parse("size:<1.5gb ext:.PNG,jpg opened:>6mo created:>=2026-01-01")
        XCTAssertEqual(sizes.maxSize, 1_500_000_000)
        XCTAssertEqual(sizes.extensions, ["png", "jpg"])
        guard case .age(.greater, let opened, _)? = sizes.opened else { return XCTFail("opened") }
        XCTAssertEqual(opened, 180 * 86_400)
        guard case .date(.greaterOrEqual, _, _)? = sizes.created else { return XCTFail("created") }

        let bad = SearchQuery.parse("size:huge type:spaceship")
        XCTAssertEqual(bad.problems.count, 2)
        XCTAssertEqual(SearchQuery.parse("10:30 notes").terms, ["10:30", "notes"])
        XCTAssertEqual(SearchQuery.parse(q.text), q, "Round-trips through its text")
    }

    func testSearchRanksAndFilters() throws {
        let h = try TestHarness()
        let location = FileLocation(path: "/u/Downloads")
        try h.store.saveLocation(location)
        let now = Date()
        let entries = [
            FileEntry(path: "/u/Downloads", locationID: location.id, isDirectory: true),
            FileEntry(path: "/u/Downloads/neural-networks.pdf", locationID: location.id, size: 20_000_000, modifiedAt: now.addingTimeInterval(-86_400)),
            FileEntry(path: "/u/Downloads/notes on neural nets.pdf", locationID: location.id, size: 20_000_000, modifiedAt: now.addingTimeInterval(-86_400)),
            FileEntry(path: "/u/Downloads/neural.pdf", locationID: location.id, size: 1_000, modifiedAt: now),
            FileEntry(path: "/u/Downloads/old-neural.pdf", locationID: location.id, size: 20_000_000, modifiedAt: now.addingTimeInterval(-90 * 86_400)),
            FileEntry(path: "/u/Downloads/nrl.png", locationID: location.id, size: 20_000_000, modifiedAt: now),
        ]
        try h.store.upsertEntries(entries, generation: 1)
        let search = FileSearch(store: h.store)

        let results = try search.search(SearchQuery.parse("ext:pdf modified:<30d size:>10mb neural"), now: now).map(\.entry.name)
        XCTAssertEqual(results, ["neural-networks.pdf", "notes on neural nets.pdf"])

        let fuzzy = try search.search(SearchQuery.parse("nrlnet")).map(\.entry.name)
        XCTAssertEqual(fuzzy.first, "neural-networks.pdf", "Letters in order still match")
        XCTAssertEqual(try search.search(SearchQuery.parse("neural")).first?.entry.name, "neural.pdf", "Exact name ranks first")
        XCTAssertTrue(try search.search(SearchQuery.parse("in:Nowhere neural")).isEmpty)
    }

    func testNaturalLanguageTranslation() {
        let q = NaturalLanguageQuery.translate("the PDF about neural networks from last month", folderNames: ["Downloads"])
        XCTAssertEqual(q.extensions, ["pdf"])
        XCTAssertEqual(q.terms, ["neural", "networks"])
        guard case .age(.less, let seconds, _)? = q.modified else { return XCTFail("modified") }
        XCTAssertEqual(seconds, 30 * 86_400)
        let big = NaturalLanguageQuery.translate("videos larger than 2 gb in downloads", folderNames: ["Downloads"])
        XCTAssertEqual(big.categories, [.video])
        XCTAssertEqual(big.minSize, 2_000_000_000)
        XCTAssertEqual(big.folders, ["Downloads"])
    }

    func testFileSearchActionInFlow() async throws {
        let h = try TestHarness()
        let location = FileLocation(path: "/u/Docs")
        try h.store.saveLocation(location)
        try h.store.upsertEntries([FileEntry(path: "/u/Docs/plan.pdf", locationID: location.id, size: 10)], generation: 1)
        try h.core.registry.register(FileSearchAction(search: FileSearch(store: h.store)))
        let run = await h.engine.invoke(FileSearchAction.id, parameters: ["query": "plan ext:pdf"], source: "test")
        XCTAssertEqual(run.steps[0].output["count"], .number(1))
        XCTAssertEqual(run.steps[0].output["first"], "/u/Docs/plan.pdf")
    }
}

// MARK: - Health

final class HealthTests: XCTestCase {
    func testCPUAndMemoryMath() {
        let a = CPUTicks(user: 100, system: 50, idle: 850, nice: 0)
        let b = CPUTicks(user: 400, system: 150, idle: 1_350, nice: 100)
        XCTAssertEqual(CPUTicks.usage(from: a, to: b), 50, accuracy: 0.001)   // 500 busy of 1000
        XCTAssertEqual(CPUTicks.usage(from: a, to: a), 0)
        let pages = MemoryPages(pageSize: 16_384, internalPages: 1_000, purgeable: 200, wired: 300, compressed: 100)
        XCTAssertEqual(pages.usedBytes, 1_200 * 16_384)
    }

    func testThresholdFiresOnceAfterSustainedTimeAndRearmsAfterRecovery() {
        var tracker = ThresholdTracker()
        let cpu = HealthThreshold(metric: .cpu, value: 90, sustainedSeconds: 300)
        let start = Date(timeIntervalSince1970: 1_000_000)
        func sample(_ value: Double, at seconds: TimeInterval) -> HealthSample {
            HealthSample(takenAt: start.addingTimeInterval(seconds), cpu: value, memoryUsed: 1, memoryTotal: 2, diskFree: 1, diskTotal: 2)
        }
        XCTAssertTrue(tracker.update(sample(95, at: 0), thresholds: [cpu]).isEmpty)
        XCTAssertTrue(tracker.update(sample(95, at: 200), thresholds: [cpu]).isEmpty, "Not sustained yet")
        XCTAssertEqual(tracker.update(sample(96, at: 300), thresholds: [cpu]).count, 1)
        XCTAssertTrue(tracker.update(sample(97, at: 600), thresholds: [cpu]).isEmpty, "Fires once")
        XCTAssertTrue(tracker.update(sample(85, at: 610), thresholds: [cpu]).isEmpty)
        XCTAssertTrue(tracker.update(sample(95, at: 620), thresholds: [cpu]).isEmpty)
        XCTAssertTrue(tracker.update(sample(95, at: 1_000), thresholds: [cpu]).isEmpty, "Hovering near the line doesn't re-arm")
        XCTAssertTrue(tracker.update(sample(50, at: 1_010), thresholds: [cpu]).isEmpty)
        XCTAssertTrue(tracker.update(sample(95, at: 1_020), thresholds: [cpu]).isEmpty)
        XCTAssertEqual(tracker.update(sample(95, at: 1_330), thresholds: [cpu]).count, 1, "Re-armed after real recovery")

        var disk = ThresholdTracker()
        let low = HealthThreshold(metric: .diskFree, value: 20)
        let lowSample = HealthSample(cpu: 0, memoryUsed: 1, memoryTotal: 2, diskFree: 15_000_000_000, diskTotal: 500_000_000_000)
        XCTAssertEqual(disk.update(lowSample, thresholds: [low]).first?.message.contains("15.0 GB"), true)
    }

    func testThresholdEventStartsAFlowWorkflow() async throws {
        let h = try TestHarness()
        h.startTriggers()
        var builder = GraphBuilder()
        let trigger = builder.add(.trigger(TriggerCatalog.healthWarning, parameters: ["metric": "diskFree"]))
        let notify = builder.add(.notify("{{trigger.message}}"))
        builder.flow(trigger, to: notify)
        var workflow = builder.workflow("Low disk")
        workflow.settings.minimumInterval = 0
        workflow = try h.core.save(workflow)

        let sensor = MockHealthSensor()
        let monitor = HealthMonitor(sensor: sensor, store: h.store, events: h.core.events)
        monitor.thresholds = [HealthThreshold(metric: .diskFree, value: 20)]
        await h.waitUntil { h.core.triggers?.activeTriggerCount == 1 }
        sensor.next.diskFree = 12_000_000_000
        monitor.tick()

        let ran = await h.waitUntil { (try? h.runs(of: workflow).count) == 1 }
        XCTAssertTrue(ran)
        XCTAssertTrue(h.system.calls.contains { $0.hasPrefix("notify:Only 12.0 GB") })
        XCTAssertEqual(try h.store.healthSamples(from: .distantPast).count, 1)
    }

    func testHealthHistoryIsDownsampled() throws {
        let store = try AtlasStore.inMemory()
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        for minute in 0..<180 {   // three hours of 5-second readings, every 30 s here
            for second in stride(from: 0, to: 60, by: 30) {
                try store.insertHealthSample(HealthSample(takenAt: now.addingTimeInterval(-Double(minute * 60 + second)), cpu: 50,
                                                          memoryUsed: 1, memoryTotal: 2, diskFree: 1, diskTotal: 2))
            }
        }
        try store.insertHealthSample(HealthSample(takenAt: now.addingTimeInterval(-8 * 86_400), cpu: 1, memoryUsed: 1, memoryTotal: 2,
                                                  diskFree: 1, diskTotal: 2))
        try store.downsampleHealth(now: now)
        let rows = try store.healthSamples(from: .distantPast)
        XCTAssertFalse(rows.contains { $0.takenAt < now.addingTimeInterval(-7 * 86_400) }, "Older than a week is dropped")
        XCTAssertTrue(rows.filter { $0.takenAt < now.addingTimeInterval(-3_660) }.allSatisfy { $0.resolution == 60 }, "Minute averages after an hour")
        XCTAssertTrue(rows.contains { $0.resolution == 5 })
        XCTAssertLessThan(rows.count, 360)
    }
}

// MARK: - Migration

final class OrbitMigrationTests: XCTestCase {
    func testV4DatabaseMigratesToV5() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("atlas-v4-\(UUID().uuidString).sqlite")
        defer {
            for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: url.path + suffix) }
        }
        let workflowID = UUID()
        do {
            let db = try SQLiteDatabase(path: url.path)
            for (index, sql) in Schema.migrations.prefix(4).enumerated() {
                try db.transaction {
                    try db.execute(sql)
                    try db.setUserVersion(index + 1)
                }
            }
            try db.run("INSERT INTO workflow (id, name, created_at, updated_at) VALUES (?, 'Old', 0, 0);", [.from(workflowID)])
        }

        let store = try AtlasStore(database: SQLiteDatabase(path: url.path))
        XCTAssertEqual(store.database.userVersion, Schema.currentVersion)
        XCTAssertEqual(try store.workflow(id: workflowID)?.name, "Old", "Existing data survives")
        let location = FileLocation(path: "/tmp/x")
        try store.saveLocation(location)
        try store.upsertEntries([FileEntry(path: "/tmp/x/a.txt", locationID: location.id, size: 5)], generation: 1)
        try store.saveRule(FileRule(name: "R", folders: ["/tmp/x"], conditions: [.extensions("txt")], action: .tag("T")))
        try store.logOperation(FileOperation(runID: nil, kind: .move, source: "/a", destination: "/b"))
        try store.insertHealthSample(HealthSample(cpu: 1, memoryUsed: 1, memoryTotal: 2, diskFree: 1, diskTotal: 2))
        try store.saveProject(Project(name: "P", links: [ProjectLink(path: "/tmp/x/a.txt")]))
        XCTAssertEqual(try store.rules().count, 1)
        XCTAssertEqual(try store.projects().first?.links.count, 1)
        try store.deleteLocation(id: location.id)
        XCTAssertNil(try store.entry(at: "/tmp/x/a.txt"), "Removing a location deletes its index")
    }
}
