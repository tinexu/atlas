import XCTest
@testable import AtlasCore
@testable import AtlasSpaces

/// A harness with Spaces installed.
struct SpacesHarness {
    let base: TestHarness
    let module: SpacesModule

    var store: AtlasStore { base.store }
    var system: MockSystemAdapter { base.system }
    var core: AtlasCore { base.core }
    var library: SpaceLibrary { module.library }
    var activator: SpaceActivator { module.activator }

    init(system: MockSystemAdapter = MockSystemAdapter()) throws {
        system.installedApps["com.apple.Safari"] = "Safari"
        system.installedApps["com.apple.iCal"] = "Calendar"
        system.installedApps["com.apple.finder"] = "Finder"
        base = try TestHarness(system: system)
        module = try SpacesModule(core: base.core)
    }

    /// A Space whose single default profile runs `steps`.
    @discardableResult
    func makeSpace(
        _ name: String,
        steps: [WorkflowStep],
        transition: TransitionBehavior = .leaveRunning,
        failurePolicy: FailurePolicy = .continueOnFailure
    ) throws -> (space: Space, profile: ActivationProfile, workflow: Workflow) {
        let workflow = try core.save(Workflow(name: "\(name) setup", failurePolicy: failurePolicy, steps: steps))
        let space = Space(name: name, group: .work, templateID: "coding-lab", accentColor: "#000000",
                          slot: try store.spaces().count, transitionBehavior: transition)
        try store.saveSpace(space)
        let profile = try library.addProfile(to: space.id, name: "Default", workflowID: workflow.id)
        return (space, profile, workflow)
    }
}

// MARK: - Persistence

final class SpaceStoreTests: XCTestCase {

    func testSpaceRoundTrip() throws {
        let store = try AtlasStore.inMemory()
        let space = Space(
            name: "Lab", group: "Side Projects", templateID: "coding-lab", accentColor: "#123456", slot: 4,
            transitionBehavior: .minimizePrevious, isPinned: true,
            createdAt: Date(timeIntervalSince1970: 1_000), updatedAt: Date(timeIntervalSince1970: 2_000)
        )

        try store.saveSpace(space)

        XCTAssertEqual(try store.space(id: space.id), space)
        XCTAssertEqual(try store.spaces(), [space])
    }

    func testSavingSpaceUpdatesInPlace() throws {
        let store = try AtlasStore.inMemory()
        var space = Space(name: "A", templateID: "t", accentColor: "#000000")
        try store.saveSpace(space)
        space.name = "B"
        space.group = .school
        try store.saveSpace(space)

        XCTAssertEqual(try store.spaces().map(\.name), ["B"])
        XCTAssertEqual(try store.space(id: space.id)?.group, .school)
    }

    func testProfileRoundTrip() throws {
        let store = try AtlasStore.inMemory()
        let space = Space(name: "S", templateID: "t", accentColor: "#000000")
        try store.saveSpace(space)
        let second = ActivationProfile(spaceID: space.id, name: "Debugging", workflowID: UUID(), position: 1)
        let first = ActivationProfile(spaceID: space.id, name: "Deep Work", workflowID: UUID(), isDefault: true, position: 0)

        try store.saveProfile(second)
        try store.saveProfile(first)

        XCTAssertEqual(try store.profiles(spaceID: space.id), [first, second])
        XCTAssertEqual(try store.profile(id: second.id), second)
    }

    func testSpaceObjectRoundTrip() throws {
        let store = try AtlasStore.inMemory()
        let space = Space(name: "S", templateID: "t", accentColor: "#000000")
        try store.saveSpace(space)
        let withAction = SpaceObject(
            spaceID: space.id, kind: .monitor, label: "Docs",
            transform: SpaceTransform(position: [0.25, 0.5, -0.75], rotation: [0, 45, 0], scale: [1, 2, 0.5]),
            actionID: OpenURLAction.id, parameters: ["url": "https://example.com", "n": 2, "flag": true]
        )
        let withWorkflow = SpaceObject(spaceID: space.id, kind: .lamp, workflowID: UUID())

        try store.saveSpaceObject(withAction)
        try store.saveSpaceObject(withWorkflow)

        XCTAssertEqual(try store.spaceObjects(spaceID: space.id), [withAction, withWorkflow])
    }

    func testDeletingSpaceCascadesButKeepsWorkflows() throws {
        let h = try SpacesHarness()
        let (space, _, workflow) = try h.makeSpace("Doomed", steps: [.launch("com.apple.Notes")])
        try h.store.saveSpaceObject(SpaceObject(spaceID: space.id, kind: .cube))
        try h.store.setActiveSpace(space.id, profileID: nil)

        try h.library.delete(spaceID: space.id, deleteWorkflows: false)

        XCTAssertNil(try h.store.space(id: space.id))
        XCTAssertTrue(try h.store.profiles(spaceID: space.id).isEmpty)
        XCTAssertTrue(try h.store.spaceObjects(spaceID: space.id).isEmpty)
        XCTAssertNil(try h.store.activeSpaceID())
        XCTAssertNotNil(try h.store.workflow(id: workflow.id), "Workflows are kept unless the user asks")
    }

    func testDeletingSpaceWithWorkflowsKeepsSharedOnes() throws {
        let h = try SpacesHarness()
        let (doomed, _, own) = try h.makeSpace("Doomed", steps: [.launch("com.apple.Notes")])
        let (keeper, _, _) = try h.makeSpace("Keeper", steps: [.launch("com.apple.Notes")])
        let shared = try h.core.save(Workflow(name: "Shared", steps: [.launch("com.apple.Terminal")]))
        try h.library.addProfile(to: doomed.id, name: "Shared", workflowID: shared.id)
        try h.library.addProfile(to: keeper.id, name: "Shared", workflowID: shared.id)

        try h.library.delete(spaceID: doomed.id, deleteWorkflows: true)

        XCTAssertNil(try h.store.workflow(id: own.id))
        XCTAssertNotNil(try h.store.workflow(id: shared.id), "Still used by another Space")
    }

    func testMigrationFromV1KeepsDataAndAddsSpaceTables() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("atlas-v1-\(UUID().uuidString).sqlite")
        defer {
            for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: url.path + suffix) }
        }
        let workflow = Workflow(name: "Old", steps: [.launch("com.apple.Notes")])

        // A Stage 01 database: only migration v1 applied.
        do {
            let db = try SQLiteDatabase(path: url.path)
            try db.transaction {
                try db.execute(Schema.migrations[0])
                try db.setUserVersion(1)
            }
            try db.run(
                "INSERT INTO workflow (id, name, created_at, updated_at) VALUES (?, ?, ?, ?);",
                [.from(workflow.id), .text(workflow.name), .from(Date()), .from(Date())]
            )
            try db.run(
                "INSERT INTO user_preference (key, value_json) VALUES ('keep.me', 'true');"
            )
        }

        let store = try AtlasStore(database: SQLiteDatabase(path: url.path))

        XCTAssertEqual(store.database.userVersion, Schema.currentVersion)
        XCTAssertGreaterThanOrEqual(Schema.currentVersion, 2)
        XCTAssertEqual(try store.workflows().map(\.name), ["Old"])
        XCTAssertEqual(try store.preference("keep.me", as: Bool.self), true)
        let space = Space(name: "New", templateID: "t", accentColor: "#000000")
        try store.saveSpace(space)
        try store.saveProfile(ActivationProfile(spaceID: space.id, name: "P", workflowID: workflow.id))
        try store.saveSpaceObject(SpaceObject(spaceID: space.id, kind: .clock))
        XCTAssertEqual(try store.spaces().count, 1)
    }

    func testNestedTransactionsRollBackTogether() throws {
        let store = try AtlasStore.inMemory()
        struct Boom: Error {}
        XCTAssertThrowsError(try store.database.transaction {
            try store.saveSpace(Space(name: "Outer", templateID: "t", accentColor: "#000000"))
            try store.database.transaction {
                try store.saveSpace(Space(name: "Inner", templateID: "t", accentColor: "#000000"))
            }
            throw Boom()
        })
        XCTAssertTrue(try store.spaces().isEmpty)
    }
}

// MARK: - Library

final class SpaceLibraryTests: XCTestCase {

    func testCreateFromTemplateMakesWorkflowsProfilesAndObjects() throws {
        let h = try SpacesHarness()
        let template = SpaceTemplates.codingLab

        let space = try h.library.createSpace(from: template)

        let profiles = try h.store.profiles(spaceID: space.id)
        XCTAssertEqual(profiles.map(\.name), template.profiles.map(\.name))
        XCTAssertEqual(profiles.filter(\.isDefault).count, 1)
        for profile in profiles {
            XCTAssertNotNil(try h.store.workflow(id: profile.workflowID))
        }
        XCTAssertEqual(try h.store.spaceObjects(spaceID: space.id).count, template.objects.count)
        XCTAssertEqual(space.accentColor, template.room.accentColor)
    }

    func testStarterSpacesSeedOnlyOnce() throws {
        let h = try SpacesHarness()
        try h.library.seedStarterSpacesIfNeeded()
        XCTAssertEqual(try h.store.spaces().map(\.name), ["Coding Lab", "Study Library", "Creative Studio"])

        for space in try h.store.spaces() { try h.library.delete(spaceID: space.id, deleteWorkflows: true) }
        try h.library.seedStarterSpacesIfNeeded()
        XCTAssertTrue(try h.store.spaces().isEmpty, "Deleted starters must not come back")
    }

    func testDuplicateCopiesWorkflowsIndependently() throws {
        let h = try SpacesHarness()
        let original = try h.library.createSpace(from: SpaceTemplates.studyLibrary)

        let copy = try h.library.duplicate(spaceID: original.id)

        XCTAssertEqual(copy.name, "Study Library Copy")
        let originalWorkflows = Set(try h.store.profiles(spaceID: original.id).map(\.workflowID))
        let copiedWorkflows = Set(try h.store.profiles(spaceID: copy.id).map(\.workflowID))
        XCTAssertEqual(copiedWorkflows.count, originalWorkflows.count)
        XCTAssertTrue(originalWorkflows.isDisjoint(with: copiedWorkflows))
        XCTAssertEqual(try h.store.spaceObjects(spaceID: copy.id).count, try h.store.spaceObjects(spaceID: original.id).count)
    }

    func testMoveReordersWithinGroup() throws {
        let h = try SpacesHarness()
        let a = try h.library.createSpace(from: SpaceTemplates.codingLab, name: "A")
        let b = try h.library.createSpace(from: SpaceTemplates.meetingRoom, name: "B")
        let c = try h.library.createSpace(from: SpaceTemplates.codingLab, name: "C")

        try h.library.move(spaceID: c.id, by: -2)

        XCTAssertEqual(try h.store.spaces().worldOrdered.map(\.id), [c.id, a.id, b.id])
    }

    func testRenameTrimsAndRejectsEmpty() throws {
        let h = try SpacesHarness()
        let space = try h.library.createSpace(from: SpaceTemplates.codingLab)
        try h.library.rename(spaceID: space.id, to: "  Lab  ")
        XCTAssertEqual(try h.store.space(id: space.id)?.name, "Lab")
        try h.library.rename(spaceID: space.id, to: "   ")
        XCTAssertEqual(try h.store.space(id: space.id)?.name, "Untitled Space")
    }

    func testDefaultProfileIsExclusiveAndLastProfileIsKept() throws {
        let h = try SpacesHarness()
        let (space, first, _) = try h.makeSpace("S", steps: [.launch("com.apple.Notes")])
        var second = try h.library.addProfile(to: space.id, name: "Second", workflowID: UUID())

        second.isDefault = true
        try h.library.saveProfile(second)
        XCTAssertEqual(try h.store.profiles(spaceID: space.id).filter(\.isDefault).map(\.id), [second.id])

        try h.library.deleteProfile(id: second.id)
        XCTAssertEqual(try h.store.profiles(spaceID: space.id).filter(\.isDefault).map(\.id), [first.id])
        XCTAssertThrowsError(try h.library.deleteProfile(id: first.id))
    }

    func testWorldOrderPutsGroupsThenPinnedFirst() {
        let a = Space(name: "a", group: .creative, templateID: "", accentColor: "", slot: 0)
        let b = Space(name: "b", group: .work, templateID: "", accentColor: "", slot: 5)
        let c = Space(name: "c", group: .work, templateID: "", accentColor: "", slot: 9, isPinned: true)
        let d = Space(name: "d", group: "Zebra", templateID: "", accentColor: "", slot: 1)
        XCTAssertEqual([a, b, c, d].worldOrdered.map(\.name), ["c", "b", "a", "d"])
    }
}

// MARK: - Templates

final class SpaceTemplateTests: XCTestCase {

    func testFiveTemplatesWithUniqueIDs() {
        XCTAssertEqual(SpaceTemplates.all.count, 5)
        XCTAssertEqual(Set(SpaceTemplates.all.map(\.id)).count, 5)
    }

    func testEveryTemplateWorkflowPassesValidation() throws {
        let registry = ActionRegistry.standard()
        for template in SpaceTemplates.all {
            XCTAssertFalse(template.profiles.isEmpty, template.name)
            XCTAssertEqual(template.profiles.filter(\.isDefault).count, 1, "\(template.name) needs one default profile")
            for profile in template.profiles {
                let workflow = profile.makeWorkflow(spaceName: template.name)
                XCTAssertFalse(workflow.steps.isEmpty)
                for step in workflow.steps {
                    let descriptor = try XCTUnwrap(registry.descriptor(for: step.actionID), "\(template.name): \(step.actionID)")
                    XCTAssertNoThrow(try registry.validate(step.parameters, for: descriptor), "\(template.name): \(step.actionID)")
                }
            }
            for object in template.objects {
                guard let actionID = object.actionID else { continue }
                let descriptor = try XCTUnwrap(registry.descriptor(for: actionID), "\(template.name) object")
                XCTAssertNoThrow(try registry.validate(object.parameters, for: descriptor), "\(template.name) object")
            }
        }
    }

    func testTemplatesOnlyUseBuiltInApps() {
        let builtIn: Set<String> = [
            "com.apple.Terminal", "com.apple.Safari", "com.apple.Notes",
            "com.apple.iCal", "com.apple.Music", "com.apple.finder",
        ]
        for template in SpaceTemplates.all {
            for profile in template.profiles {
                let apps = Set(SpaceApps.bundleIDs(in: profile.makeWorkflow(spaceName: template.name)))
                XCTAssertTrue(apps.isSubset(of: builtIn), "\(template.name) uses \(apps.subtracting(builtIn))")
            }
        }
    }

    func testBundleIDsFollowStepOrderWithoutDuplicates() {
        var off = WorkflowStep.launch("com.apple.Music")
        off.isEnabled = false
        let workflow = Workflow(name: "W", steps: [
            .launch("com.apple.Terminal"),
            WorkflowStep(actionID: OpenURLAction.id, parameters: ["url": "https://a.example", "bundleId": "com.apple.Safari"]),
            WorkflowStep(actionID: RevealInFinderAction.id, parameters: ["path": "~"]),
            .launch("com.apple.Terminal"),
            off,
            WorkflowStep(actionID: HideApplicationAction.id, parameters: ["bundleId": "com.apple.Notes"]),
        ])
        XCTAssertEqual(SpaceApps.bundleIDs(in: workflow), ["com.apple.Terminal", "com.apple.Safari", "com.apple.finder"])
    }
}

// MARK: - Activation

final class SpaceActivatorTests: XCTestCase {

    func testActivationRunsProfileWorkflowWithSpaceTrigger() async throws {
        let h = try SpacesHarness()
        let (space, profile, workflow) = try h.makeSpace("Lab", steps: [.launch("com.apple.Terminal"), .launch("com.apple.Notes")])

        let activation = try await h.activator.activate(spaceID: space.id)

        XCTAssertEqual(activation.run.workflowID, workflow.id)
        XCTAssertEqual(activation.run.trigger, "space.activated")
        XCTAssertEqual(activation.profileID, profile.id)
        XCTAssertEqual(activation.status, .ready)
        XCTAssertEqual(h.system.calls, ["launch:com.apple.Terminal", "launch:com.apple.Notes"])
        XCTAssertEqual(try h.store.activeSpaceID(), space.id)
        XCTAssertEqual(try h.store.lastActivationRunID(spaceID: space.id), activation.run.id)
        let stored = try XCTUnwrap(try h.store.run(id: activation.run.id))
        XCTAssertEqual(stored.trigger, "space.activated")
    }

    func testChosenProfileRunsItsOwnWorkflow() async throws {
        let h = try SpacesHarness()
        let (space, _, _) = try h.makeSpace("Lab", steps: [.launch("com.apple.Terminal")])
        let review = try h.core.save(Workflow(name: "Review", steps: [.launch("com.apple.Notes")]))
        let reviewProfile = try h.library.addProfile(to: space.id, name: "Quick Review", workflowID: review.id)

        let activation = try await h.activator.activate(spaceID: space.id, profileID: reviewProfile.id)

        XCTAssertEqual(activation.run.workflowID, review.id)
        XCTAssertEqual(h.system.calls, ["launch:com.apple.Notes"])
    }

    func testEventsArePublishedInOrder() async throws {
        let h = try SpacesHarness()
        let (first, _, _) = try h.makeSpace("First", steps: [.launch("com.apple.Terminal")])
        let (second, profile, _) = try h.makeSpace("Second", steps: [.launch("com.apple.Notes")])
        _ = try await h.activator.activate(spaceID: first.id)

        let collected = EventPayloadCollector()
        h.core.events.subscribe("space.*") { collected.append($0) }
        let activation = try await h.activator.activate(spaceID: second.id)

        XCTAssertEqual(collected.events.map(\.name), ["space.activating", "space.deactivated", "space.activated"])
        XCTAssertEqual(collected.events[1].payload["spaceId"], .string(first.id.uuidString))
        let activated = collected.events[2].payload
        XCTAssertEqual(activated["spaceId"], .string(second.id.uuidString))
        XCTAssertEqual(activated["profileId"], .string(profile.id.uuidString))
        XCTAssertEqual(activated["runId"], .string(activation.run.id.uuidString))
    }

    func testPartialActivationIsReportedHonestly() async throws {
        let h = try SpacesHarness()
        let (space, _, _) = try h.makeSpace("Lab", steps: [
            .launch("com.apple.Terminal"), .launch("com.example.NotInstalled"), .launch("com.apple.Notes"),
        ])

        let activation = try await h.activator.activate(spaceID: space.id)

        XCTAssertEqual(activation.run.state, .partiallySucceeded)
        XCTAssertEqual(activation.status, .partiallyReady(succeeded: 2, total: 3))
        XCTAssertEqual(activation.status.title, "Partially ready (2 of 3 steps)")
        XCTAssertEqual(
            SpaceStatus.resolve(isActive: true, isActivating: false, lastRun: activation.run),
            .partiallyReady(succeeded: 2, total: 3)
        )
    }

    func testFailedActivationIsFailed() async throws {
        let h = try SpacesHarness()
        let (space, _, _) = try h.makeSpace("Lab", steps: [.launch("com.example.NotInstalled")])

        let activation = try await h.activator.activate(spaceID: space.id)

        guard case .failed = activation.status else { return XCTFail("Expected failed, got \(activation.status)") }
    }

    func testHidePreviousHidesOnlyThePreviousSpacesOtherApps() async throws {
        let h = try SpacesHarness()
        let (coding, _, _) = try h.makeSpace("Coding", steps: [
            .launch("com.apple.Terminal"),
            .launch("com.apple.Safari"),
            WorkflowStep(actionID: RevealInFinderAction.id, parameters: ["path": "/tmp"]),
        ])
        h.system.existingPaths["/tmp"] = .directory
        let (study, _, _) = try h.makeSpace("Study", steps: [.launch("com.apple.Notes"), .launch("com.apple.Safari")],
                                            transition: .hidePrevious)
        _ = try await h.activator.activate(spaceID: coding.id)
        // Finder is running but wasn't launched through the mock.
        h.system.markRunning("com.apple.finder")

        let activation = try await h.activator.activate(spaceID: study.id)

        let hidden = h.system.calls.filter { $0.hasPrefix("hide:") }
        XCTAssertEqual(Set(hidden), ["hide:com.apple.Terminal", "hide:com.apple.finder"],
                       "Safari is shared with the new Space and must stay visible")
        XCTAssertEqual(activation.transitionRun?.trigger, "space.transition")
        XCTAssertEqual(activation.transitionRun?.state, .succeeded)
        XCTAssertFalse(h.system.calls.contains { $0.hasPrefix("quit:") }, "A Space switch never quits apps")
    }

    func testLeaveRunningTouchesNothing() async throws {
        let h = try SpacesHarness()
        let (a, _, _) = try h.makeSpace("A", steps: [.launch("com.apple.Terminal")])
        let (b, _, _) = try h.makeSpace("B", steps: [.launch("com.apple.Notes")])

        _ = try await h.activator.activate(spaceID: a.id)
        let activation = try await h.activator.activate(spaceID: b.id)

        XCTAssertNil(activation.transitionRun)
        XCTAssertEqual(h.system.calls, ["launch:com.apple.Terminal", "launch:com.apple.Notes"])
    }

    func testMinimizePreviousNeverQuits() async throws {
        let h = try SpacesHarness()
        let (a, _, _) = try h.makeSpace("A", steps: [.launch("com.apple.Terminal")])
        let (b, _, _) = try h.makeSpace("B", steps: [.launch("com.apple.Notes")], transition: .minimizePrevious)

        _ = try await h.activator.activate(spaceID: a.id)
        _ = try await h.activator.activate(spaceID: b.id)

        XCTAssertTrue(h.system.calls.contains("minimize:com.apple.Terminal"))
        XCTAssertFalse(h.system.calls.contains { $0.hasPrefix("quit:") || $0.hasPrefix("hide:") })
    }

    func testReactivatingSameSpaceHasNoTransition() async throws {
        let h = try SpacesHarness()
        let (a, _, _) = try h.makeSpace("A", steps: [.launch("com.apple.Terminal")], transition: .hidePrevious)
        let collected = EventPayloadCollector()
        h.core.events.subscribe("space.*") { collected.append($0) }

        _ = try await h.activator.activate(spaceID: a.id)
        let second = try await h.activator.activate(spaceID: a.id)

        XCTAssertNil(second.transitionRun)
        XCTAssertFalse(collected.events.map(\.name).contains("space.deactivated"))
        XCTAssertEqual(second.status, .ready)
    }

    func testMissingWorkflowIsAClearError() async throws {
        let h = try SpacesHarness()
        let (space, _, workflow) = try h.makeSpace("A", steps: [.launch("com.apple.Terminal")])
        try h.core.delete(workflowID: workflow.id)

        do {
            _ = try await h.activator.activate(spaceID: space.id)
            XCTFail("Expected an error")
        } catch {
            XCTAssertEqual(error as? SpaceActivationError, .workflowMissing("Default"))
        }
        XCTAssertTrue(h.system.calls.isEmpty)
    }

    func testActivationWorksWithTemplateSpaces() async throws {
        let h = try SpacesHarness()
        h.system.existingPaths[("~" as NSString).expandingTildeInPath] = .directory
        let lab = try h.library.createSpace(from: SpaceTemplates.codingLab)

        let activation = try await h.activator.activate(spaceID: lab.id)

        XCTAssertEqual(activation.status, .ready, activation.run.error ?? "")
        XCTAssertTrue(h.system.calls.contains("launch:com.apple.Terminal"))
        XCTAssertTrue(h.system.calls.contains("open-url:https://developer.apple.com/documentation/swift"))
    }
}

// MARK: - Actions

final class SpaceActionTests: XCTestCase {

    func testSpaceActivateViaEngineInvokeFromShortcut() async throws {
        let h = try SpacesHarness()
        let (space, _, workflow) = try h.makeSpace("Coding Lab", steps: [.launch("com.apple.Terminal")])

        let run = await h.core.engine.invoke(SpaceActivateAction.id, parameters: ["space": "coding lab"], source: "shortcut")

        XCTAssertEqual(run.state, .succeeded, run.error ?? "")
        XCTAssertEqual(run.trigger, "shortcut")
        XCTAssertEqual(try h.store.activeSpaceID(), space.id)
        XCTAssertEqual(h.system.calls, ["launch:com.apple.Terminal"])
        let activationRuns = try h.store.runs(workflowID: workflow.id)
        XCTAssertEqual(activationRuns.map(\.trigger), ["space.activated"])
    }

    func testSpaceActivateByIDAndProfileName() async throws {
        let h = try SpacesHarness()
        let (space, _, _) = try h.makeSpace("Lab", steps: [.launch("com.apple.Terminal")])
        let review = try h.core.save(Workflow(name: "Review", steps: [.launch("com.apple.Notes")]))
        try h.library.addProfile(to: space.id, name: "Quick Review", workflowID: review.id)

        let run = await h.core.engine.invoke(
            SpaceActivateAction.id, parameters: ["space": .string(space.id.uuidString), "profile": "quick review"], source: "shortcut"
        )

        XCTAssertEqual(run.state, .succeeded, run.error ?? "")
        XCTAssertEqual(h.system.calls, ["launch:com.apple.Notes"])
    }

    func testSpaceActivateUnknownSpaceFails() async throws {
        let h = try SpacesHarness()
        let run = await h.core.engine.invoke(SpaceActivateAction.id, parameters: ["space": "Nowhere"], source: "shortcut")
        XCTAssertEqual(run.state, .failed)
        XCTAssertEqual(run.steps.first?.error, SpaceActivationError.spaceNotFound("Nowhere").errorDescription)
    }

    func testSpaceActivateReportsPartialActivationAsFailure() async throws {
        let h = try SpacesHarness()
        try h.makeSpace("Lab", steps: [.launch("com.apple.Terminal"), .launch("com.example.Missing")])

        let run = await h.core.engine.invoke(SpaceActivateAction.id, parameters: ["space": "Lab"], source: "shortcut")

        XCTAssertEqual(run.state, .failed)
        XCTAssertTrue(run.steps.first?.error?.contains("1 of 2") == true, run.steps.first?.error ?? "")
    }

    func testHideApplicationAction() async throws {
        let h = try SpacesHarness()
        h.system.markRunning("com.apple.Music")

        let running = await h.core.engine.invoke(HideApplicationAction.id, parameters: ["bundleId": "com.apple.Music"], source: "test")
        let notRunning = await h.core.engine.invoke(HideApplicationAction.id, parameters: ["bundleId": "com.apple.Notes"], source: "test")

        XCTAssertEqual(running.state, .succeeded)
        XCTAssertEqual(running.steps.first?.message, "Hid Music")
        XCTAssertEqual(notRunning.steps.first?.message, "Notes wasn't running")
        XCTAssertEqual(h.system.calls, ["hide:com.apple.Music", "hide:com.apple.Notes"])
        XCTAssertTrue(try XCTUnwrap(h.core.registry.descriptor(for: HideApplicationAction.id)).isIdempotent)
    }

    func testSpaceActivateIsRegisteredAndIdempotent() throws {
        let h = try SpacesHarness()
        let descriptor = try XCTUnwrap(h.core.registry.descriptor(for: SpaceActivateAction.id))
        XCTAssertTrue(descriptor.isIdempotent)
        XCTAssertFalse(descriptor.confirmationRequired)
    }
}

final class EventPayloadCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var _events: [AtlasEvent] = []
    var events: [AtlasEvent] { lock.synchronized { _events } }
    func append(_ event: AtlasEvent) { lock.synchronized { _events.append(event) } }
}
