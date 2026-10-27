import XCTest
@testable import AtlasCompanion
@testable import AtlasCore
@testable import AtlasSpaces

/// Stage 08: data safety and nothing hanging.
final class FileRecoveryTests: XCTestCase {
    func testFileChangesAreWrittenPendingThenDone() async throws {
        let h = try TestHarness()
        h.system.existingPaths["/in/a.pdf"] = .file
        h.system.existingPaths["/out"] = .directory
        let run = await h.engine.invoke(MoveFileAction.id, parameters: ["path": "/in/a.pdf", "destination": "/out"], source: "test")
        XCTAssertEqual(run.state, .succeeded)
        let operation = try XCTUnwrap(h.store.operations(runID: run.id).first)
        XCTAssertEqual(operation.state, .done)
        XCTAssertTrue(try h.store.pendingOperations().isEmpty)

        // A failed change leaves no record behind.
        let failed = await h.engine.invoke(MoveFileAction.id, parameters: ["path": "/in/missing.pdf", "destination": "/out"], source: "test")
        XCTAssertEqual(failed.state, .failed)
        XCTAssertTrue(try h.store.operations(runID: failed.id).isEmpty)
    }

    func testHalfDoneChangesAreSettledAtLaunch() async throws {
        let h = try TestHarness()
        let system = h.system
        func pending(_ kind: FileOperation.Kind, _ source: String, _ destination: String?) throws -> UUID {
            let operation = FileOperation(runID: UUID(), kind: kind, source: source, destination: destination, state: .pending)
            try h.store.logOperation(operation)
            return operation.id
        }
        // Finished moving before the crash.
        let finished = try pending(.move, "/a/one.pdf", "/b/one.pdf")
        system.existingPaths["/b/one.pdf"] = .file
        // Never started.
        let notStarted = try pending(.rename, "/a/two.pdf", "/a/2.pdf")
        system.existingPaths["/a/two.pdf"] = .file
        // Half-moved across disks: both exist.
        let half = try pending(.move, "/a/three.mov", "/ext/three.mov")
        system.existingPaths["/a/three.mov"] = .file
        system.existingPaths["/ext/three.mov"] = .file
        // Incomplete copy.
        let copy = try pending(.copy, "/a/four.zip", "/b/four.zip")
        system.existingPaths["/a/four.zip"] = .file
        system.existingPaths["/b/four.zip"] = .file
        system.fileSizes["/a/four.zip"] = 100
        system.fileSizes["/b/four.zip"] = 40

        let results = await FileOperationRecovery.reconcile(store: h.store, system: system, events: h.core.events)
        let byID = Dictionary(uniqueKeysWithValues: results.map { ($0.operationID, $0) })
        XCTAssertEqual(byID[finished]?.state, .done)
        XCTAssertEqual(byID[notStarted]?.state, .rolledBack)
        XCTAssertEqual(byID[half]?.state, .rolledBack)
        XCTAssertEqual(byID[copy]?.state, .rolledBack)
        XCTAssertEqual(system.fileKind(atPath: "/a/three.mov"), .file, "The original is untouched")
        XCTAssertNotEqual(system.fileKind(atPath: "/ext/three.mov"), .file, "The partial copy went to the Trash")
        XCTAssertTrue(system.calls.contains { $0.hasPrefix("trash:/b/four.zip") })
        XCTAssertTrue(try h.store.pendingOperations().isEmpty)
        XCTAssertNotNil(try h.store.operation(id: half)?.extra["recovered"])
        // Rolled-back changes aren't offered for undo.
        let undo = await h.engine.invoke(UndoFileOperationAction.id, parameters: ["operationId": .string(notStarted.uuidString)], source: "test")
        XCTAssertEqual(undo.state, .failed)
        XCTAssertTrue(undo.error?.contains("never finished") == true, undo.error ?? "")
    }
}

final class DataSafetyTests: XCTestCase {
    private func tempFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("atlas-safety-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testDailyBackupsKeepTheNewestSeven() throws {
        let folder = try tempFolder()
        let store = try AtlasStore(database: SQLiteDatabase(path: folder.appendingPathComponent("atlas.sqlite").path))
        try store.saveWorkflow(Workflow(name: "Precious", steps: [.log("x")]))
        let backups = DatabaseBackups.folder(for: folder.appendingPathComponent("atlas.sqlite"))
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        for day in 0..<10 {
            XCTAssertNotNil(try DatabaseBackups.backUpIfDue(store.database, to: backups, now: start + Double(day) * 86_400))
            XCTAssertNil(try DatabaseBackups.backUpIfDue(store.database, to: backups, now: start + Double(day) * 86_400 + 3_600),
                         "Once a day")
        }
        let kept = DatabaseBackups.list(in: backups)
        XCTAssertEqual(kept.count, 7)
        XCTAssertEqual(kept.first?.date, start + 9 * 86_400, "Newest first")
        let copy = try AtlasStore(database: SQLiteDatabase(path: kept[0].url.path))
        XCTAssertEqual(try copy.workflows().map(\.name), ["Precious"], "A real, readable copy")
    }

    func testCorruptDatabaseIsSetAsideAndTheBackupRestored() throws {
        let folder = try tempFolder()
        let url = folder.appendingPathComponent("atlas.sqlite")
        do {
            let store = try AtlasStore(database: SQLiteDatabase(path: url.path))
            try store.saveWorkflow(Workflow(name: "Precious", steps: [.log("x")]))
            try DatabaseBackups.backUpIfDue(store.database, to: DatabaseBackups.folder(for: url))
        }
        // Scribble over the file.
        for suffix in ["-wal", "-shm"] { try? FileManager.default.removeItem(atPath: url.path + suffix) }
        try Data(repeating: 0x42, count: 8_192).write(to: url)

        XCTAssertThrowsError(try AtlasStore.openChecked(at: url)) { error in
            guard case DataSafetyError.corrupted(_, let backupAvailable) = error else { return XCTFail("\(error)") }
            XCTAssertTrue(backupAvailable)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "Moved aside, not deleted")
        let folderContents = try FileManager.default.contentsOfDirectory(atPath: DatabaseBackups.folder(for: url).path)
        XCTAssertTrue(folderContents.contains { $0.hasPrefix("atlas-corrupt-") })

        let latest = try XCTUnwrap(DatabaseBackups.list(in: DatabaseBackups.folder(for: url)).first)
        try DatabaseBackups.restore(latest, to: url)
        let restored = try AtlasStore.openChecked(at: url)
        XCTAssertEqual(try restored.workflows().map(\.name), ["Precious"])
    }

    func testExportAndImportRoundTrip() throws {
        let h = try SpacesHarness()
        let (space, _, workflow) = try h.makeSpace("Coding Lab", steps: [.launch("com.apple.Terminal")])
        try h.store.saveWindowLayout(WindowLayout(name: "Programming", rules: [WindowRule(bundleID: "com.apple.Terminal", appName: "Terminal", preset: .leftHalf)]))
        try h.store.saveRule(FileRule(name: "PDFs", folders: ["/tmp/x"], conditions: [.extensions("pdf")], action: .tag("Paper")))
        try h.store.setPreference("deep", for: "some.setting")
        var settings = try h.store.companionSettings()
        settings.character = .orb
        try h.store.saveCompanionSettings(settings)

        let data = try AtlasExport.make(from: h.store).data()
        let fresh = try AtlasStore.inMemory()
        let summary = try AtlasExport.read(data).apply(to: fresh)
        XCTAssertGreaterThanOrEqual(summary.workflows, 1)
        XCTAssertEqual(try fresh.workflow(id: workflow.id)?.name, workflow.name)
        XCTAssertEqual(try fresh.space(id: space.id)?.name, "Coding Lab")
        XCTAssertEqual(try fresh.profiles(spaceID: space.id).count, 1)
        XCTAssertEqual(try fresh.windowLayouts().first?.rules.count, 1)
        XCTAssertEqual(try fresh.rules().first?.name, "PDFs")
        XCTAssertEqual(try fresh.preference("some.setting", as: String.self), "deep")
        XCTAssertEqual(try fresh.companionSettings().character, .orb)
        // Importing again changes nothing (replaces by ID).
        try AtlasExport.read(data).apply(to: fresh)
        XCTAssertEqual(try fresh.spaces().count, 1)

        var newer = try AtlasExport.read(data)
        newer.schemaVersion = 99
        XCTAssertThrowsError(try newer.apply(to: fresh))
    }
}

/// Never waits forever.
final class SlowCalendarStore: CalendarStore, @unchecked Sendable {
    func access() -> CalendarAccess { .granted }
    func requestAccess() async -> CalendarAccess { .granted }
    func calendars() -> [CalendarInfo] { Thread.sleep(forTimeInterval: 2); return [CalendarInfo(id: "w", title: "Work", source: "")] }
    func events(from: Date, to: Date, calendarIDs: [String]) -> [CalendarEvent] { Thread.sleep(forTimeInterval: 2); return [] }
    func event(id: String) -> CalendarEvent? { Thread.sleep(forTimeInterval: 2); return nil }
    func createEvent(title: String, start: Date, end: Date, calendarID: String, notes: String) throws -> String { Thread.sleep(forTimeInterval: 2); return "x" }
    func updateEvent(id: String, start: Date, end: Date) throws { Thread.sleep(forTimeInterval: 2) }
    func deleteEvent(id: String) throws { Thread.sleep(forTimeInterval: 2) }
    func observeChanges(_ handler: @escaping @Sendable () -> Void) -> TriggerToken { TriggerToken {} }
}

private struct HangingModel: IntentModelProvider {
    var displayName: String { "Slow model" }
    func unavailableReason() async -> String? { nil }
    func complete(_ request: ModelRequest) async throws -> String {
        try await Task.sleep(nanoseconds: 30_000_000_000)
        return "{}"
    }
}

final class TimeoutTests: XCTestCase {
    func testCalendarCallsGiveUpQuickly() {
        let store = TimeoutCalendarStore(SlowCalendarStore(), timeout: 0.2)
        let start = Date()
        XCTAssertTrue(store.events(from: Date(), to: Date() + 60, calendarIDs: ["w"]).isEmpty)
        XCTAssertTrue(store.calendars().isEmpty)
        XCTAssertThrowsError(try store.createEvent(title: "x", start: Date(), end: Date(), calendarID: "w", notes: "")) {
            XCTAssertEqual($0 as? CalendarError, .timedOut)
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 1.5)
    }

    func testAModelThatNeverAnswersTimesOutWithAClearMessage() async {
        let start = Date()
        do {
            _ = try await HangingModel().complete(ModelRequest(instructions: "", input: "", schemaJSON: "{}"), within: 0.2)
            XCTFail("Should time out")
        } catch {
            XCTAssertEqual((error as? ModelError)?.reason, "Slow model didn't answer within 0 seconds.")
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
    }
}

/// Daily-use fixes, each with the test that would have caught it.
final class DailyUseFixTests: XCTestCase {
    /// An idle Companion kept a live RealityKit view on screen: ~65% CPU.
    func testOnlyActiveStatesUseTheLive3DView() {
        XCTAssertFalse(CompanionState.idle.usesLiveRendering)
        XCTAssertFalse(CompanionState.sleeping.usesLiveRendering)
        XCTAssertFalse(CompanionState.focus.usesLiveRendering)
        for state in [CompanionState.listening, .thinking, .executing, .success, .failure] {
            XCTAssertTrue(state.usesLiveRendering, "\(state)")
        }
    }

    /// A busy file rule popped a bubble for every file.
    func testBusyAutomaticRunsDontChatter() {
        var policy = BubblePolicy()
        let rule = UUID(), t0 = Date(timeIntervalSince1970: 0)
        XCTAssertTrue(policy.shouldShow(workflowID: rule, trigger: "trigger.file.created", state: .succeeded, at: t0))
        XCTAssertFalse(policy.shouldShow(workflowID: rule, trigger: "trigger.file.created", state: .succeeded, at: t0 + 60))
        XCTAssertTrue(policy.shouldShow(workflowID: rule, trigger: "trigger.file.created", state: .failed, at: t0 + 90), "Failures always show")
        XCTAssertTrue(policy.shouldShow(workflowID: rule, trigger: "trigger.file.created", state: .succeeded, at: t0 + 90 + 601))
        XCTAssertTrue(policy.shouldShow(workflowID: UUID(), trigger: RunTrigger.companion, state: .succeeded, at: t0 + 61),
                      "Things you asked for always answer")
        XCTAssertTrue(policy.shouldShow(workflowID: rule, trigger: RunTrigger.manual, state: .succeeded, at: t0 + 62))
        XCTAssertFalse(policy.shouldShow(workflowID: UUID(), trigger: "space.activated", state: .succeeded, at: t0))
        XCTAssertFalse(policy.shouldShow(workflowID: UUID(), trigger: "trigger.time.reached", state: .skipped, at: t0))
    }
}

final class RenderPolicyTests: XCTestCase {
    /// A Spaces window left open behind other apps rendered 3D at ~40% CPU.
    func test3DDrawsOnlyWhenSeenAndInUse() {
        XCTAssertTrue(RenderPolicy.shouldDraw(windowVisible: true, appActive: true, lowPowerMode: false))
        XCTAssertFalse(RenderPolicy.shouldDraw(windowVisible: true, appActive: false, lowPowerMode: false), "ATLAS in the background")
        XCTAssertFalse(RenderPolicy.shouldDraw(windowVisible: false, appActive: true, lowPowerMode: false), "Covered or minimized")
        XCTAssertFalse(RenderPolicy.shouldDraw(windowVisible: true, appActive: true, lowPowerMode: true), "Low Power Mode")
    }
}
