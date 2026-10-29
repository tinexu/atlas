import AtlasCompanion
@testable import AtlasCore
@testable import AtlasFlow
import XCTest

/// The one "is this inside an Orbit folder" check, and what uses it:
/// validation, folder triggers and "Retry failed steps".
final class FileAccessTests: XCTestCase {
    private var temp: URL!

    override func setUpWithError() throws {
        temp = FileManager.default.temporaryDirectory.appendingPathComponent("atlas-access-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temp.appendingPathComponent("Downloads"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: temp.appendingPathComponent("Downloads2"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: temp.appendingPathComponent("Elsewhere"), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: temp.appendingPathComponent("Downloads/quiz3 2.pdf").path, contents: Data("pdf".utf8))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temp)
    }

    private var downloads: String { temp.appendingPathComponent("Downloads").path }

    func testContainmentAcceptsEverySpellingOfAPathInside() throws {
        let policy = FileAccessPolicy(roots: [downloads])
        let file = downloads + "/quiz3 2.pdf"

        XCTAssertTrue(policy.isAllowed(file), "absolute")
        XCTAssertTrue(policy.isAllowed(URL(fileURLWithPath: file).absoluteString), "file:// URL with %20")
        XCTAssertTrue(URL(fileURLWithPath: file).absoluteString.contains("quiz3%202.pdf"))
        XCTAssertTrue(policy.contains(URL(fileURLWithPath: file)), "URL")
        XCTAssertTrue(policy.isAllowed(downloads + "/./sub/../quiz3 2.pdf"), "unstandardized")
        XCTAssertTrue(policy.isAllowed(downloads + "/"), "the folder itself, trailing slash")

        // Through a symlink to the folder, and an added folder named through a symlink.
        let link = temp.appendingPathComponent("dl-link").path
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: downloads)
        XCTAssertTrue(policy.isAllowed(link + "/quiz3 2.pdf"))
        XCTAssertTrue(FileAccessPolicy(roots: [link]).isAllowed(file))

        // A destination that doesn't exist yet counts when its parent is inside.
        XCTAssertTrue(policy.isAllowed(downloads + "/PDFs"))
        XCTAssertTrue(policy.isAllowed(downloads + "/PDFs/New/quiz3 2.pdf"))
    }

    func testTildePathsExpand() {
        let policy = FileAccessPolicy(roots: ["~/Downloads"])
        XCTAssertTrue(policy.isAllowed("~/Downloads/quiz3 2.pdf"))
        XCTAssertTrue(policy.isAllowed(NSHomeDirectory() + "/Downloads/quiz3 2.pdf"))
        XCTAssertTrue(policy.isAllowed("file://" + NSHomeDirectory() + "/Downloads/quiz3%202.pdf"))
        XCTAssertFalse(policy.isAllowed("~/Documents/quiz3 2.pdf"))
    }

    func testDifferentLetterCaseOnACaseInsensitiveVolume() throws {
        let sensitive = try URL(fileURLWithPath: downloads).resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey])
            .volumeSupportsCaseSensitiveNames ?? false
        try XCTSkipIf(sensitive, "The temporary folder is on a case-sensitive volume")
        let policy = FileAccessPolicy(roots: [downloads])
        XCTAssertTrue(policy.isAllowed(temp.appendingPathComponent("DOWNLOADS/quiz3 2.pdf").path))
        XCTAssertTrue(policy.isAllowed(temp.appendingPathComponent("downloads/pdfs/missing.pdf").path), "case differs and doesn't exist yet")
        XCTAssertTrue(FileAccessPolicy(roots: [temp.appendingPathComponent("DownLoads").path]).isAllowed(downloads + "/quiz3 2.pdf"))
    }

    func testOutsidePathsAreRefused() throws {
        let policy = FileAccessPolicy(roots: [downloads])
        XCTAssertFalse(policy.isAllowed(temp.appendingPathComponent("Downloads2/x.pdf").path), "a sibling with the same prefix")
        XCTAssertFalse(policy.isAllowed(temp.path), "the parent")
        XCTAssertFalse(policy.isAllowed(downloads + "/../Elsewhere/x.pdf"), "dot-dot out")
        // A link inside the folder can't reach outside it.
        let escape = downloads + "/escape"
        try FileManager.default.createSymbolicLink(atPath: escape, withDestinationPath: temp.appendingPathComponent("Elsewhere").path)
        XCTAssertFalse(policy.isAllowed(escape + "/x.pdf"))
        XCTAssertThrowsError(try policy.require(escape + "/x.pdf")) { error in
            XCTAssertTrue(error.localizedDescription.contains("ATLAS only changes files in folders you've added to Orbit"))
        }
    }

    func testFolderToAuthorize() {
        XCTAssertEqual(FileAccessPolicy.folderToAuthorize(for: downloads + "/quiz3 2.pdf", isFolder: false),
                       FileAccessPolicy.canonical(downloads))
        XCTAssertEqual(FileAccessPolicy.folderToAuthorize(for: downloads + "/PDFs", isFolder: true),
                       FileAccessPolicy.canonical(downloads), "a missing destination: its nearest existing folder")
        XCTAssertEqual(FileAccessPolicy.folderToAuthorize(for: downloads, isFolder: true), FileAccessPolicy.canonical(downloads))
    }

    // MARK: - Validation and triggers

    private func moveWorkflow(folder: String) -> Workflow {
        var g = GraphBuilder()
        let trigger = g.add(.trigger(TriggerCatalog.fileCreated, parameters: ["folder": .string(folder)]))
        let move = g.add(.move(to: folder + "/PDFs"))
        g.flow(trigger, to: move)
        g.data(trigger, "path", to: move, "path")
        var workflow = g.workflow("Move file")
        workflow.isEnabled = true
        return workflow
    }

    func testUnauthorizedTriggerFolderIsAnErrorWithTheFolderToAdd() throws {
        let h = try TestHarness(authorizedFolders: ["/Users/test/Desktop"])
        h.system.existingPaths["/Users/test/Downloads"] = .directory
        let issues = h.core.validate(moveWorkflow(folder: "/Users/test/Downloads")).filter { $0.folderToAdd != nil }
        XCTAssertEqual(issues.count, 2, "the trigger, and the move's destination")
        XCTAssertTrue(issues.allSatisfy { $0.severity == .error })
        XCTAssertTrue(issues.contains { $0.message.hasPrefix("Watches /Users/test/Downloads, which isn't in Orbit") }, "\(issues.map(\.message))")

        h.core.fileAccess.setRoots(["/Users/test/Downloads"])
        XCTAssertEqual(h.core.validate(moveWorkflow(folder: "/Users/test/Downloads")).filter { $0.folderToAdd != nil }, [])
    }

    func testOneFolderToAddWhenADestinationIsInsideTheWatchedFolder() throws {
        // Real folders, so the destination (which exists) would otherwise suggest itself.
        try FileManager.default.createDirectory(atPath: downloads + "/PDFs", withIntermediateDirectories: true)
        let h = try TestHarness(authorizedFolders: [temp.appendingPathComponent("Elsewhere").path])
        let issues = h.core.validate(moveWorkflow(folder: downloads)).filter { $0.folderToAdd != nil }
        XCTAssertEqual(issues.count, 2)
        XCTAssertEqual(Set(issues.compactMap(\.folderToAdd)), [FileAccessPolicy.canonical(downloads)])
    }

    @MainActor
    func testEditorWontTurnOnAWorkflowWatchingAnUnauthorizedFolder() throws {
        let h = try TestHarness(authorizedFolders: ["/Users/test/Desktop"])
        var workflow = moveWorkflow(folder: "/Users/test/Downloads")
        workflow.isEnabled = false
        let editor = FlowEditorModel(workflow: workflow, core: h.core)
        XCTAssertTrue(editor.issues.contains { $0.folderToAdd != nil && $0.severity == .error })

        editor.setEnabled(true)
        XCTAssertFalse(editor.draft.isEnabled)
        XCTAssertNotNil(editor.message)

        h.core.fileAccess.setRoots(["/Users/test"])
        editor.revalidate()
        editor.setEnabled(true)
        XCTAssertTrue(editor.draft.isEnabled)
    }

    func testTriggerRefusesToWatchUntilTheFolderIsAdded() async throws {
        let h = try TestHarness(authorizedFolders: ["/Users/test/Desktop"])
        h.system.existingPaths["/dl"] = .directory
        let env = h.startTriggers()
        let workflow = try h.core.save(moveWorkflow(folder: "/dl"))
        let triggerID = try XCTUnwrap(workflow.triggerNodes.first?.id)

        try await h.expect(h.waitUntil { h.core.triggers?.problem(for: triggerID) != nil })
        XCTAssertEqual(env.listenerCount, 0, "not watching")
        XCTAssertTrue(h.core.triggers?.problem(for: triggerID)?.contains("isn't in Orbit") ?? false)
        XCTAssertTrue(try XCTUnwrap(h.store.workflow(id: workflow.id)).isEnabled, "stays on, waiting for the folder")

        // Adding the folder starts it, without turning anything back on.
        try h.store.saveLocation(FileLocation(path: "/dl"))
        h.core.refreshFileAccess()
        try await h.expect(h.waitUntil { env.listenerCount == 1 })
        XCTAssertNil(h.core.triggers?.problem(for: triggerID))

        // And removing it stops it again.
        try h.store.deleteLocation(id: try XCTUnwrap(h.store.locations().first).id)
        h.core.refreshFileAccess()
        try await h.expect(h.waitUntil { env.listenerCount == 0 })
    }

    // MARK: - Retry

    func testRetryFailedStepsRunsOnlyWhatFailed() async throws {
        let h = try TestHarness(authorizedFolders: ["/Users/test/Desktop"])
        h.system.existingPaths["/dl"] = .directory
        h.system.existingPaths["/dl/quiz3 2.pdf"] = .file
        h.system.installedApps["com.apple.Preview"] = "Preview"
        var g = GraphBuilder()
        let trigger = g.add(.trigger(TriggerCatalog.fileCreated, parameters: ["folder": "/dl"]))
        let launch = g.add(.launch("com.apple.Preview"))
        let move = g.add(.move(to: "/dl/PDFs", path: "{{trigger.path}}"))
        let log = g.add(.log("Moved {{node.\(move.uuidString).fileName}}"))
        g.flow(trigger, to: launch)
        g.flow(launch, to: move)
        g.flow(move, to: log)
        let workflow = try h.core.save(g.workflow("Move file"))

        let first = await h.engine.run(workflow, payload: ["path": "/dl/quiz3 2.pdf", "fileName": "quiz3 2.pdf"], entryNodeID: trigger)
        XCTAssertEqual(first.state, .partiallySucceeded)
        XCTAssertEqual(first.steps.map(\.state), [.succeeded, .succeeded, .failed, .skipped])
        XCTAssertTrue(first.steps[2].error?.contains("folders you've added to Orbit") ?? false)

        h.core.fileAccess.setRoots(["/dl"])
        let maybeRetried = await h.engine.retryFailedSteps(of: first.id)
        let retried = try XCTUnwrap(maybeRetried)
        XCTAssertEqual(retried.trigger, RunTrigger.retry)
        XCTAssertEqual(retried.state, .succeeded)
        XCTAssertEqual(retried.steps.map(\.state), [.succeeded, .succeeded, .succeeded, .succeeded])
        XCTAssertEqual(retried.steps[1].message, "Done in the earlier run")
        XCTAssertEqual(h.system.calls.filter { $0.hasPrefix("launch:") }.count, 1, "the step that worked isn't repeated")
        XCTAssertEqual(h.system.existingPaths["/dl/PDFs/quiz3 2.pdf"], .file)
        XCTAssertEqual(retried.steps[3].message, "Moved quiz3 2.pdf")

        // Nothing failed this time, so there's nothing to retry.
        let none = await h.engine.retryFailedSteps(of: retried.id)
        XCTAssertNil(none)
    }

    func testFailureExplainerOffersAddFolderAndRetry() async throws {
        let h = try TestHarness(authorizedFolders: ["/Users/test/Desktop"])
        let file = downloads + "/quiz3 2.pdf"
        h.system.existingPaths[file] = .file
        let run = await h.engine.invoke(MoveFileAction.id, parameters: ["path": .string(file), "destination": .string(downloads + "/PDFs")],
                                        source: "test")
        let explanation = FailureExplainer.explain(run, fileAccess: h.core.fileAccess)
        XCTAssertTrue(explanation.message.hasPrefix("ATLAS only changes files in folders you've added to Orbit"), "keeps the wording")
        XCTAssertEqual(explanation.fixTitle, "Add Downloads to Orbit")
        XCTAssertEqual(explanation.fix, .addFolderToOrbit(FileAccessPolicy.canonical(downloads)))
        XCTAssertEqual(explanation.secondaryTitle, "Retry failed steps")
        XCTAssertEqual(explanation.secondary, .retryFailedSteps(run.id))
    }
}
