import XCTest
@testable import AtlasCore
@testable import AtlasOrbit

/// "Only when no other rule matches": a catch-all that steps aside.
final class RuleFallbackTests: XCTestCase {
    private func setUp(_ h: TestHarness) throws -> (FileOrganizer, resumes: FileRule, course: FileRule, other: FileRule) {
        try h.core.registry.register(OrganizeFileAction(store: h.store, registry: h.core.registry))
        let organizer = FileOrganizer(core: h.core)
        let resumes = try organizer.save(FileRule(name: "Resumes", isEnabled: true, folders: ["/dl"],
                                                  conditions: [.extensions("pdf, docx"), .nameMatches(pattern: "(?i)(?<![a-z])(resume|résumé|cv)(?![a-z])")],
                                                  action: .moveTo(folder: "/docs/Resumes")))
        let course = try organizer.save(FileRule(name: "Course PDFs: CS 475", isEnabled: true, folders: ["/dl"],
                                                 conditions: [.extensions("pdf"), .nameMatches(pattern: "CS ?475")],
                                                 action: .moveTo(folder: "/school/CS 475/Downloads")))
        let other = try organizer.save(FileRule(name: "Other PDFs", isEnabled: true, folders: ["/dl"], conditions: [.extensions("pdf")],
                                                action: .moveTo(folder: "/dl/PDFs"), isFallback: true))
        return (organizer, resumes, course, other)
    }

    private func organize(_ h: TestHarness, _ rule: FileRule, _ path: String) async -> WorkflowRun {
        await h.engine.invoke(OrganizeFileAction.id, parameters: ["ruleId": .string(rule.id.uuidString), "path": .string(path)], source: "test")
    }

    func testTheCatchAllStepsAsideAndNeverCompetes() async throws {
        let h = try TestHarness()
        let (_, resumes, course, other) = try setUp(h)
        for name in ["Jane Doe Resume.pdf", "CS475 hw3.pdf", "receipt.pdf"] { h.system.existingPaths["/dl/\(name)"] = .file }

        // A resume: the resume rule moves it straight away (no review, despite "Other PDFs" matching too)…
        let resume = await organize(h, resumes, "/dl/Jane Doe Resume.pdf")
        XCTAssertEqual(resume.steps.first?.output["outcome"], "done", resume.error ?? "")
        XCTAssertTrue(h.system.calls.contains("move:/dl/Jane Doe Resume.pdf->/docs/Resumes/Jane Doe Resume.pdf"))
        // …and the catch-all leaves school work alone.
        let skipped = await organize(h, other, "/dl/CS475 hw3.pdf")
        XCTAssertEqual(skipped.steps.first?.output["outcome"], "skipped")
        XCTAssertEqual(skipped.steps.first?.message, "Left to “Course PDFs: CS 475”")
        let school = await organize(h, course, "/dl/CS475 hw3.pdf")
        XCTAssertEqual(school.steps.first?.output["outcome"], "done")
        // Anything else: the catch-all.
        let receipt = await organize(h, other, "/dl/receipt.pdf")
        XCTAssertEqual(receipt.steps.first?.output["outcome"], "done")
        XCTAssertTrue(h.system.calls.contains("move:/dl/receipt.pdf->/dl/PDFs/receipt.pdf"))
        XCTAssertTrue(try h.store.reviewItems(state: .pending).isEmpty, "nothing asked twice")
    }

    func testTheFlagIsSavedAndShownInTheSummary() throws {
        let h = try TestHarness()
        let (organizer, _, _, other) = try setUp(h)
        let loaded = try XCTUnwrap(organizer.rules().first { $0.id == other.id })
        XCTAssertTrue(loaded.isFallback)
        XCTAssertEqual(loaded.summary, "When extension is pdf and no other rule matches, move to /dl/PDFs")
        XCTAssertFalse(try XCTUnwrap(organizer.rules().first { $0.name == "Resumes" }).isFallback)
    }
}
