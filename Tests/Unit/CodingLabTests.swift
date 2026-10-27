import RealityKit
import XCTest
@testable import AtlasCore
@testable import AtlasSpaces
@testable import AtlasSpacesUI

final class CodingLabTests: XCTestCase {

    func testTemplateKeepsItsID() {
        XCTAssertEqual(SpaceTemplates.codingLab.id, "coding-lab")
        XCTAssertEqual(CodingLab.templateID, SpaceTemplates.codingLab.id)
    }

    /// The objects a Coding Lab made before the redesign has.
    private struct Legacy {
        var docs, terminal, home, calendar: SpaceObject
        var all: [SpaceObject]

        init(spaceID: UUID) {
            docs = SpaceObject(spaceID: spaceID, kind: .monitor, label: "Swift docs", actionID: OpenURLAction.id,
                               parameters: ["url": "https://developer.apple.com/documentation/swift", "bundleId": "com.apple.Safari"])
            terminal = SpaceObject(spaceID: spaceID, kind: .terminal, label: "Terminal", actionID: LaunchApplicationAction.id,
                                   parameters: ["bundleId": "com.apple.Terminal"])
            home = SpaceObject(spaceID: spaceID, kind: .bookshelf, label: "Home folder", actionID: RevealInFinderAction.id,
                               parameters: ["path": "~"])
            calendar = SpaceObject(spaceID: spaceID, kind: .clock, label: "Calendar", actionID: LaunchApplicationAction.id,
                                   parameters: ["bundleId": "com.apple.iCal"])
            all = [docs, terminal, home, calendar, SpaceObject(spaceID: spaceID, kind: .lamp),
                   SpaceObject(spaceID: spaceID, kind: .cube), SpaceObject(spaceID: spaceID, kind: .poster)]
        }
    }

    func testOlderObjectsKeepTheirActionsOnTheNewProps() {
        let legacy = Legacy(spaceID: UUID())
        let assignment = CodingLab.assign(legacy.all)
        XCTAssertEqual(assignment.roles[.ultrawide]?.id, legacy.docs.id)
        XCTAssertEqual(assignment.roles[.portrait]?.id, legacy.terminal.id)
        // A bookshelf that opens a folder becomes the project hologram.
        XCTAssertEqual(assignment.roles[.hologram]?.id, legacy.home.id)
        XCTAssertEqual(assignment.roles[.clock]?.id, legacy.calendar.id)
        XCTAssertTrue(assignment.loose.isEmpty)
        XCTAssertEqual(Set(assignment.hidden.map(\.kind)), [.lamp, .cube, .poster])
    }

    func testAPlainBookshelfDoesNotBecomeTheHologram() {
        let spaceID = UUID()
        let assignment = CodingLab.assign([SpaceObject(spaceID: spaceID, kind: .bookshelf)])
        XCTAssertNil(assignment.roles[.hologram])
    }

    func testUpgradeAddsOnlyMissingPropsAndRunsOnce() throws {
        let h = try SpacesHarness()
        let workflow = try h.core.save(Workflow(name: "Deep Work", steps: []))
        let space = Space(name: "Coding Lab", group: .work, templateID: CodingLab.templateID, accentColor: "#3B82F6", slot: 0)
        try h.store.saveSpace(space)
        try h.library.addProfile(to: space.id, name: "Deep Work", workflowID: workflow.id)
        let legacy = Legacy(spaceID: space.id)
        for object in legacy.all { try h.store.saveSpaceObject(object) }

        try h.library.upgradeCodingLabs()
        let objects = try h.store.spaceObjects(spaceID: space.id)

        for old in [legacy.docs, legacy.terminal, legacy.home, legacy.calendar] {
            XCTAssertEqual(objects.first { $0.id == old.id }, old)
        }
        XCTAssertNil(objects.first { $0.kind == .hologram }, "the Home folder bookshelf already plays the hologram")
        XCTAssertEqual(objects.first { $0.kind == .keyboard }?.workflowID, workflow.id)
        XCTAssertEqual(objects.first { $0.kind == .serverRack }?.parameters["url"], "https://github.com")
        XCTAssertEqual(objects.first { $0.kind == .kanban }?.actionID, OpenURLAction.id)
        XCTAssertNotNil(objects.first { $0.kind == .mug })
        XCTAssertEqual(objects.count, legacy.all.count + 4)

        let rack = try XCTUnwrap(objects.first { $0.kind == .serverRack })
        try h.store.deleteSpaceObject(id: rack.id)
        try h.library.upgradeCodingLabs()
        XCTAssertEqual(try h.store.spaceObjects(spaceID: space.id).count, objects.count - 1)
    }

    func testDefaultsForANewLab() throws {
        let objects = CodingLab.missingDefaults(for: UUID(), existing: [], activationWorkflowID: nil,
                                                editor: CodingLab.cursorBundleID, projectFolder: "~", hasFocusAction: true)
        XCTAssertEqual(objects.first { $0.kind == .monitor }?.parameters["bundleId"], .string(CodingLab.cursorBundleID))
        let terminal = try XCTUnwrap(objects.first { $0.kind == .terminal })
        XCTAssertEqual(terminal.actionID, OpenFileAction.id)
        XCTAssertEqual(terminal.parameters["bundleId"], "com.apple.Terminal")
        XCTAssertEqual(objects.first { $0.kind == .mug }?.actionID, "timer.focus.start")
        XCTAssertNil(CodingLab.missingDefaults(for: UUID(), existing: [], activationWorkflowID: nil, editor: "x",
                                               projectFolder: "~", hasFocusAction: false).first { $0.kind == .mug }?.actionID)
    }

    func testNewCodingLabGetsAKeyboardThatRunsItsActivation() throws {
        let h = try SpacesHarness()
        let space = try h.library.createSpace(from: SpaceTemplates.codingLab)
        let objects = try h.store.spaceObjects(spaceID: space.id)
        let activation = try XCTUnwrap(h.store.profiles(spaceID: space.id).first(where: \.isDefault)).workflowID
        XCTAssertEqual(objects.filter { $0.kind == .keyboard }.map(\.workflowID), [activation])
        XCTAssertEqual(objects.count, SpaceTemplates.codingLab.objects.count + 1)
    }

    @MainActor
    func testRoomStaysWithinEntityBudgets() throws {
        let space = Space(name: "Coding Lab", group: .work, templateID: CodingLab.templateID, accentColor: "#B9A8F0", slot: 0)
        let template = SpaceTemplates.codingLab
        var objects = template.objects.map { blueprint in
            SpaceObject(spaceID: space.id, kind: blueprint.kind, label: blueprint.label, actionID: blueprint.actionID)
        }
        objects.append(SpaceObject(spaceID: space.id, kind: .keyboard, label: "Coding Lab", workflowID: UUID()))
        // Plus an older Space's extras: its Calendar clock and plain props.
        let legacy = Legacy(spaceID: space.id)
        objects += [legacy.calendar] + legacy.all.filter { !$0.hasAssignment }

        let full = RoomBuilder.build(space: space, room: template.room, objects: objects, detail: true)
        let miniature = RoomBuilder.build(space: space, room: template.room, objects: objects, detail: false)

        XCTAssertLessThan(count(full), 150)
        XCTAssertLessThan(count(miniature), 40)
        for object in CodingLab.assign(objects).roles.values where object.hasAssignment {
            XCTAssertNotNil(full.findEntity(named: RoomBuilder.objectName(object.id)), "\(object.kind)")
        }
    }

    @MainActor
    func testCodeScreenScrollsWithoutRebuildingItsTexture() throws {
        let screen = try XCTUnwrap(CodeScreen(style: .editor, width: 256, height: 128, seed: 1, palette: .current))
        let texture = screen.texture
        screen.advance()
        XCTAssertTrue(screen.texture === texture)
    }

    @MainActor
    private func count(_ entity: Entity) -> Int {
        1 + entity.children.reduce(0) { $0 + count($1) }
    }
}
