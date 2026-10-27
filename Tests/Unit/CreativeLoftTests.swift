import RealityKit
import XCTest
@testable import AtlasCore
@testable import AtlasSpaces
@testable import AtlasSpacesUI

final class CreativeLoftTests: XCTestCase {

    func testTemplateKeepsItsID() {
        XCTAssertEqual(SpaceTemplates.creativeStudio.id, "creative-studio")
        XCTAssertEqual(CreativeLoft.templateID, SpaceTemplates.creativeStudio.id)
    }

    func testAssignmentPrefersObjectsThatRunSomething() {
        let spaceID = UUID()
        let plainPoster = SpaceObject(spaceID: spaceID, kind: .poster, label: "Plain")
        var pictures = SpaceObject(spaceID: spaceID, kind: .poster, label: "Pictures")
        pictures.actionID = RevealInFinderAction.id
        var music = SpaceObject(spaceID: spaceID, kind: .cube, label: "Music")
        music.actionID = LaunchApplicationAction.id
        var extraMusic = SpaceObject(spaceID: spaceID, kind: .cube, label: "Podcasts")
        extraMusic.actionID = LaunchApplicationAction.id

        let assignment = CreativeLoft.assign([plainPoster, pictures, music, extraMusic])

        XCTAssertEqual(assignment.roles[.pegboard]?.id, pictures.id)
        XCTAssertEqual(assignment.roles[.pouf]?.id, music.id)
        XCTAssertEqual(assignment.loose.map(\.id), [extraMusic.id])
        XCTAssertEqual(assignment.hidden.map(\.id), [plainPoster.id])
    }

    func testUpgradeAddsMissingPropsOnceWithoutTouchingExistingOnes() throws {
        let h = try SpacesHarness()
        let workflow = try h.core.save(Workflow(name: "Create", steps: []))
        let space = Space(name: "Creative Studio", group: .personal, templateID: CreativeLoft.templateID, accentColor: "#E8A6B4", slot: 0)
        try h.store.saveSpace(space)
        try h.library.addProfile(to: space.id, name: "Create", workflowID: workflow.id)
        var notes = SpaceObject(spaceID: space.id, kind: .monitor, label: "Notes")
        notes.actionID = LaunchApplicationAction.id
        notes.parameters = ["bundleId": "com.apple.Notes"]
        try h.store.saveSpaceObject(notes)

        try h.library.upgradeCreativeStudios()
        let objects = try h.store.spaceObjects(spaceID: space.id)

        // The existing monitor keeps its action; no second monitor appears.
        XCTAssertEqual(objects.filter { $0.kind == .monitor }.map(\.id), [notes.id])
        XCTAssertEqual(objects.first { $0.id == notes.id }?.parameters["bundleId"], "com.apple.Notes")
        XCTAssertEqual(objects.first { $0.kind == .neon }?.workflowID, workflow.id)
        XCTAssertEqual(objects.first { $0.kind == .easel }?.parameters["path"], "~/Pictures")
        XCTAssertEqual(objects.first { $0.kind == .poster }?.actionID, OpenURLAction.id)
        XCTAssertNotNil(objects.first { $0.kind == .bookshelf })
        XCTAssertNotNil(objects.first { $0.kind == .mug })

        // Deleting a prop afterwards isn't undone by the next launch.
        let mug = try XCTUnwrap(objects.first { $0.kind == .mug })
        try h.store.deleteSpaceObject(id: mug.id)
        try h.library.upgradeCreativeStudios()
        XCTAssertEqual(try h.store.spaceObjects(spaceID: space.id).count, objects.count - 1)
    }

    func testNewCreativeStudioGetsANeonThatRunsItsActivation() throws {
        let h = try SpacesHarness()
        let space = try h.library.createSpace(from: SpaceTemplates.creativeStudio)
        let objects = try h.store.spaceObjects(spaceID: space.id)
        let activation = try XCTUnwrap(h.store.profiles(spaceID: space.id).first(where: \.isDefault)).workflowID
        XCTAssertEqual(objects.filter { $0.kind == .neon }.map(\.workflowID), [activation])
        XCTAssertEqual(objects.count, SpaceTemplates.creativeStudio.objects.count + 1)
    }

    @MainActor
    func testLoftStaysWithinEntityBudgets() throws {
        let space = Space(name: "Creative Studio", group: .personal, templateID: CreativeLoft.templateID, accentColor: "#E8A6B4", slot: 0)
        let template = SpaceTemplates.creativeStudio
        var objects = template.objects.map { blueprint -> SpaceObject in
            var object = SpaceObject(spaceID: space.id, kind: blueprint.kind, label: blueprint.label)
            object.actionID = blueprint.actionID
            return object
        }
        objects.append(SpaceObject(spaceID: space.id, kind: .neon, label: "Creative Studio"))

        let full = RoomBuilder.build(space: space, room: template.room, objects: objects, detail: true)
        let miniature = RoomBuilder.build(space: space, room: template.room, objects: objects, detail: false)

        XCTAssertLessThan(count(full), 150)
        XCTAssertLessThan(count(miniature), 40)
        // Every object with a prop is pickable by its ID.
        for object in objects where object.hasAssignment {
            XCTAssertNotNil(full.findEntity(named: RoomBuilder.objectName(object.id)), "\(object.kind)")
        }
    }

    @MainActor
    private func count(_ entity: Entity) -> Int {
        1 + entity.children.reduce(0) { $0 + count($1) }
    }
}
