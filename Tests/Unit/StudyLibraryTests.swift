import RealityKit
import XCTest
@testable import AtlasCore
@testable import AtlasSpaces
@testable import AtlasSpacesUI

final class StudyLibraryTests: XCTestCase {

    func testTemplateKeepsItsID() {
        XCTAssertEqual(SpaceTemplates.studyLibrary.id, "study-library")
        XCTAssertEqual(StudyLibrary.templateID, SpaceTemplates.studyLibrary.id)
    }

    /// The objects a Study Library made before the redesign has.
    private func legacyObjects(spaceID: UUID) -> (documents: SpaceObject, notes: SpaceObject, calendar: SpaceObject,
                                                   lamp: SpaceObject, all: [SpaceObject]) {
        var documents = SpaceObject(spaceID: spaceID, kind: .bookshelf, label: "Documents")
        documents.actionID = RevealInFinderAction.id
        documents.parameters = ["path": "~/Documents"]
        var notes = SpaceObject(spaceID: spaceID, kind: .monitor, label: "Notes")
        notes.actionID = LaunchApplicationAction.id
        notes.parameters = ["bundleId": "com.apple.Notes"]
        var calendar = SpaceObject(spaceID: spaceID, kind: .clock, label: "Calendar")
        calendar.actionID = LaunchApplicationAction.id
        calendar.parameters = ["bundleId": "com.apple.iCal"]
        let lamp = SpaceObject(spaceID: spaceID, kind: .lamp)
        let all = [documents, SpaceObject(spaceID: spaceID, kind: .bookshelf), notes, calendar, lamp,
                   SpaceObject(spaceID: spaceID, kind: .poster)]
        return (documents, notes, calendar, lamp, all)
    }

    func testAssignmentKeepsExistingActionsOnProps() {
        let legacy = legacyObjects(spaceID: UUID())
        let assignment = StudyLibrary.assign(legacy.all)
        XCTAssertEqual(assignment.roles[.bookshelf]?.id, legacy.documents.id)
        XCTAssertEqual(assignment.roles[.calendar]?.id, legacy.calendar.id)
        XCTAssertEqual(assignment.roles[.laptop]?.id, legacy.notes.id)
        XCTAssertEqual(assignment.roles[.lamp]?.id, legacy.lamp.id)
        XCTAssertTrue(assignment.loose.isEmpty)
        XCTAssertEqual(assignment.hidden.map(\.kind), [.bookshelf, .poster])
    }

    func testUpgradeFillsOnlyEmptyAssignmentsAndRunsOnce() throws {
        let h = try SpacesHarness()
        let workflow = try h.core.save(Workflow(name: "Study Session", steps: []))
        let space = Space(name: "Study Library", group: .school, templateID: StudyLibrary.templateID, accentColor: "#6F8A6E", slot: 0)
        try h.store.saveSpace(space)
        try h.library.addProfile(to: space.id, name: "Study Session", workflowID: workflow.id)
        let legacy = legacyObjects(spaceID: space.id)
        for object in legacy.all { try h.store.saveSpaceObject(object) }

        try h.library.upgradeStudyLibraries()
        let objects = try h.store.spaceObjects(spaceID: space.id)
        func object(_ id: UUID) -> SpaceObject? { objects.first { $0.id == id } }

        // Existing assignments are untouched.
        XCTAssertEqual(object(legacy.documents.id), legacy.documents)
        XCTAssertEqual(object(legacy.notes.id), legacy.notes)
        XCTAssertEqual(object(legacy.calendar.id), legacy.calendar)
        // The plain lamp becomes the study timer (Notes without Time Architect).
        XCTAssertEqual(object(legacy.lamp.id)?.actionID, LaunchApplicationAction.id)
        XCTAssertEqual(object(legacy.lamp.id)?.label, "Study timer")
        // New props with their defaults.
        XCTAssertEqual(objects.first { $0.kind == .globe }?.parameters["url"], "https://scholar.google.com")
        XCTAssertEqual(objects.first { $0.kind == .chalkboard }?.parameters["path"], "~/Documents")
        XCTAssertEqual(objects.first { $0.kind == .book }?.workflowID, workflow.id)
        XCTAssertEqual(objects.count, legacy.all.count + 3)

        let globe = try XCTUnwrap(objects.first { $0.kind == .globe })
        try h.store.deleteSpaceObject(id: globe.id)
        try h.library.upgradeStudyLibraries()
        XCTAssertEqual(try h.store.spaceObjects(spaceID: space.id).count, objects.count - 1)
    }

    func testLampStartsAFiftyMinuteFocusWhenTimeArchitectRuns() throws {
        let objects = StudyLibrary.missingDefaults(for: UUID(), existing: [], activationWorkflowID: nil, hasFocusAction: true)
        let lamp = try XCTUnwrap(objects.first { $0.kind == .lamp })
        XCTAssertEqual(lamp.actionID, "timer.focus.start")
        XCTAssertEqual(lamp.parameters["minutes"], 50)
    }

    func testNewStudyLibraryGetsABookThatRunsItsActivation() throws {
        let h = try SpacesHarness()
        let space = try h.library.createSpace(from: SpaceTemplates.studyLibrary)
        let objects = try h.store.spaceObjects(spaceID: space.id)
        let activation = try XCTUnwrap(h.store.profiles(spaceID: space.id).first(where: \.isDefault)).workflowID
        XCTAssertEqual(objects.filter { $0.kind == .book }.map(\.workflowID), [activation])
        XCTAssertEqual(objects.count, SpaceTemplates.studyLibrary.objects.count + 1)
    }

    @MainActor
    func testRoomStaysWithinEntityBudgets() throws {
        let space = Space(name: "Study Library", group: .school, templateID: StudyLibrary.templateID, accentColor: "#6F8A6E", slot: 0)
        let template = SpaceTemplates.studyLibrary
        var objects = template.objects.map { blueprint -> SpaceObject in
            SpaceObject(spaceID: space.id, kind: blueprint.kind, label: blueprint.label, actionID: blueprint.actionID)
        }
        objects.append(SpaceObject(spaceID: space.id, kind: .book, label: "Study Library", workflowID: UUID()))
        objects += legacyObjects(spaceID: space.id).all

        let full = RoomBuilder.build(space: space, room: template.room, objects: objects, detail: true)
        let miniature = RoomBuilder.build(space: space, room: template.room, objects: objects, detail: false)

        XCTAssertLessThan(count(full), 150)
        XCTAssertLessThan(count(miniature), 40)
        for object in StudyLibrary.assign(objects).roles.values where object.hasAssignment {
            XCTAssertNotNil(full.findEntity(named: RoomBuilder.objectName(object.id)), "\(object.kind)")
        }
    }

    @MainActor
    private func count(_ entity: Entity) -> Int {
        1 + entity.children.reduce(0) { $0 + count($1) }
    }
}
