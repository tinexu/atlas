import RealityKit
import XCTest
@testable import AtlasCompanion
@testable import AtlasCore
@testable import AtlasSpaces
@testable import AtlasSpacesUI

// MARK: - State → pose and expression

final class MochiPoseTests: XCTestCase {
    private func pose(_ state: CompanionState, _ intensity: CompanionSettings.Intensity = .full, reduceMotion: Bool = false,
                      reading: Bool = false, hover: SIMD2<Float>? = nil, petted: Bool = false) -> MochiPose {
        MochiPose.make(for: state, intensity: intensity, reduceMotion: reduceMotion, reading: reading, hover: hover, petted: petted)
    }

    func testIdleBreathesBlinksTwitchesAndWiggles() {
        let idle = pose(.idle)
        XCTAssertEqual(idle.posture, .idle)
        XCTAssertEqual(idle.motion, .idle)
        XCTAssertEqual(idle.breathPeriod, 3)
        XCTAssertTrue(idle.blinks && idle.earTwitch && idle.noseWiggle)
        XCTAssertEqual(idle.effect, .none)
    }

    func testListeningPerksBothEarsTiltsAndWidensTheEyes() {
        let p = pose(.listening).posture
        XCTAssertEqual(p.perk, 1)
        XCTAssertEqual(p.floppyLift, 0.5, "The floppy ear lifts halfway")
        XCTAssertEqual(p.headTilt, 10 * .pi / 180, accuracy: 0.0001)
        XCTAssertEqual(p.eyes, .wide)
    }

    func testThinkingTiltsTheOtherWayWithAPawToItsChinAndDots() {
        let thinking = pose(.thinking)
        XCTAssertLessThan(thinking.posture.headTilt, 0)
        XCTAssertEqual(thinking.posture.paws, .chin)
        XCTAssertEqual(thinking.effect, .thinkingDots)
        XCTAssertTrue(thinking.effectsMove)
    }

    func testExecutingHops() {
        let working = pose(.executing)
        XCTAssertEqual(working.motion, .hops)
        XCTAssertEqual(MochiPose.hopInterval, 0.6)
        XCTAssertEqual(MochiPose.squash, 0.08, "About 8% squash on landing")
    }

    func testSuccessIsABinkyWithSparklesAndHappyEyes() {
        let success = pose(.success)
        XCTAssertEqual(success.motion, .binky)
        XCTAssertEqual(success.effect, .sparkles)
        XCTAssertEqual(success.posture.eyes, .happy)
        XCTAssertGreaterThan(MochiPose.binkyHeight, MochiPose.hopHeight)
    }

    func testFailureDroopsLooksDownSweatsAndSighs() {
        let failure = pose(.failure)
        XCTAssertTrue(failure.posture.droop)
        XCTAssertEqual(failure.posture.eyes, .down)
        XCTAssertTrue(failure.posture.sweat)
        XCTAssertEqual(failure.posture.mouth, .frown)
        XCTAssertEqual(failure.motion, .sigh)
        XCTAssertEqual(CompanionStateMachine.outcomeDuration, 1.5, "Back to idle after 1.5 s")
    }

    func testFocusIsTheLoafBreathingOnly() {
        let focus = pose(.focus)
        XCTAssertEqual(focus.posture.body, .loaf)
        XCTAssertEqual(focus.posture.paws, .tucked)
        XCTAssertTrue(focus.posture.earsBack)
        XCTAssertEqual(focus.posture.eyes, .half)
        XCTAssertGreaterThan(focus.breathPeriod, 0)
        XCTAssertFalse(focus.blinks || focus.earTwitch || focus.noseWiggle)
        XCTAssertEqual(focus.effect, .none)
    }

    func testSleepingIsTheLoafWithClosedEyesAndSlowZs() {
        let sleeping = pose(.sleeping)
        XCTAssertEqual(sleeping.posture.body, .loaf)
        XCTAssertEqual(sleeping.posture.eyes, .closed)
        XCTAssertEqual(sleeping.effect, .zzz)
        XCTAssertGreaterThan(sleeping.breathPeriod, pose(.idle).breathPeriod, "Slower breathing")
    }

    func testStudyFocusReadsInTheLoaf() {
        let reading = pose(.focus, reading: true)
        XCTAssertEqual(reading.posture.body, .loaf)
        XCTAssertEqual(reading.posture.paws, .hold)
        XCTAssertEqual(pose(.executing, reading: true).motion, .hops, "Work still shows while studying")
    }

    func testHoverLooksAtTheCursorWithinFifteenDegrees() {
        let hover = pose(.idle, hover: [5, -5])
        XCTAssertEqual(hover.lookAt, [1, -1], "Clamped to the character's area")
        XCTAssertEqual(hover.posture.headTurn, 15 * .pi / 180, accuracy: 0.0001)
        XCTAssertEqual(hover.posture.headNod, 15 * .pi / 180, accuracy: 0.0001, "Looking down at a cursor below")
        XCTAssertTrue(hover.noseWiggle)
        XCTAssertNil(pose(.executing, hover: [1, 0]).lookAt, "Busy: it doesn't stop to look")
    }

    func testPettingHops() {
        XCTAssertEqual(pose(.idle, petted: true).motion, .happyHop)
        XCTAssertEqual(pose(.idle, petted: true).posture.eyes, .happy)
        XCTAssertEqual(pose(.success, petted: true).motion, .binky, "An outcome wins over a pet")
    }

    func testReduceMotionKeepsExpressionsOnly() {
        for reduced in [pose(.executing, reduceMotion: true), pose(.executing, .reduced)] {
            XCTAssertEqual(reduced.motion, .none, "No hops")
            XCTAssertEqual(reduced.breathPeriod, 0)
            XCTAssertFalse(reduced.earTwitch || reduced.noseWiggle)
        }
        let success = pose(.success, reduceMotion: true)
        XCTAssertEqual(success.motion, .none)
        XCTAssertEqual(success.effect, .none, "No sparkles")
        XCTAssertEqual(success.posture.eyes, .happy, "The happy face stays")
        let failure = pose(.failure, .reduced)
        XCTAssertTrue(failure.posture.droop, "Ear angle carries the state")
        XCTAssertEqual(failure.posture.mouth, .frown)
        let listening = pose(.listening, reduceMotion: true, hover: [1, 1])
        XCTAssertEqual(listening.posture.perk, 1)
        XCTAssertNil(listening.lookAt, "The head doesn't chase the cursor")
        XCTAssertEqual(listening.posture.headTurn, 0)
        XCTAssertFalse(pose(.thinking, .reduced).effectsMove, "Dots stay still")
        XCTAssertEqual(pose(.idle, reduceMotion: true, petted: true).motion, .none)
    }

    func testStillShowsAStaticIdlePose() {
        for state in CompanionState.allCases {
            let still = pose(state, .still)
            XCTAssertEqual(still.posture, .idle, "\(state)")
            XCTAssertTrue(still.isStill, "\(state)")
            XCTAssertEqual(CharacterPresentation.make(for: state, intensity: .still, reduceMotion: false).rendering, .staticImage)
        }
    }

    func testPresentationCarriesTheMochiPose() {
        let presentation = CharacterPresentation.make(for: .failure, intensity: .full, reduceMotion: false)
        XCTAssertEqual(presentation.mochi, pose(.failure))
    }

    func testRoomActivities() {
        XCTAssertEqual(MochiRoomPose.posture(.reading).body, .loaf)
        XCTAssertEqual(MochiRoomPose.posture(.reading).paws, .hold)
        XCTAssertEqual(MochiRoomPose.posture(.painting).paws, .brush)
        XCTAssertEqual(MochiRoomPose.posture(.watching).paws, .hold)
        XCTAssertEqual(MochiRoomPose.posture(.coding).body, .sit)
        XCTAssertEqual(MochiRoomPose.posture(.lockdown).body, .loaf)
        XCTAssertEqual(CodingRoomState.Sitter(isLockdown: true).activity, .lockdown)
        XCTAssertEqual(CodingRoomState.Sitter().activity, .coding)
    }
}

// MARK: - Accessories per room

final class MochiAccessoryTests: XCTestCase {
    func testRoomsResolveFromTheActiveSpaceAndWatchMode() {
        XCTAssertEqual(MochiRoom.resolve(templateID: CodingLab.templateID, isWatching: false), .codingLab)
        XCTAssertEqual(MochiRoom.resolve(templateID: StudyLibrary.templateID, isWatching: false), .studyLibrary)
        XCTAssertEqual(MochiRoom.resolve(templateID: CreativeLoft.templateID, isWatching: false), .creativeStudio)
        XCTAssertEqual(MochiRoom.resolve(templateID: CreativeLoft.templateID, isWatching: true), .watch, "Watch mode wins")
        XCTAssertEqual(MochiRoom.resolve(templateID: "blank", isWatching: false), .desktop)
        XCTAssertEqual(MochiRoom.resolve(templateID: nil, isWatching: false), .desktop)
    }

    func testAutoSwitchPicksEachRoomsAccessories() {
        let settings = MochiAccessorySettings()
        XCTAssertTrue(settings.auto, "On by default")
        XCTAssertEqual(settings.accessories(for: .codingLab), [.headphones])
        XCTAssertEqual(settings.accessories(for: .studyLibrary), [.glasses, .scarf])
        XCTAssertEqual(settings.accessories(for: .creativeStudio), [.beret, .paintSmudge])
        XCTAssertEqual(settings.accessories(for: .watch), [.popcorn])
        XCTAssertEqual(settings.accessories(for: .desktop), [.sprout])
    }

    func testAutoOffWearsTheOutsideChoiceEverywhere() {
        var settings = MochiAccessorySettings(auto: false)
        settings.perRoom[.desktop] = [.bow]
        for room in MochiRoom.allCases { XCTAssertEqual(settings.accessories(for: room), [.bow], "\(room)") }
        settings.perRoom[.desktop] = []
        XCTAssertEqual(settings.accessories(for: .codingLab), [], "Or nothing")
    }

    func testAtMostTwoAtATime() {
        var settings = MochiAccessorySettings()
        settings.toggle(.bow, in: .studyLibrary)
        XCTAssertEqual(settings.chosen(for: .studyLibrary), [.scarf, .bow], "The oldest goes")
        settings.toggle(.scarf, in: .studyLibrary)
        XCTAssertEqual(settings.chosen(for: .studyLibrary), [.bow])
        settings.perRoom[.watch] = [.popcorn, .bow, .sprout]
        XCTAssertEqual(settings.accessories(for: .watch).count, 2)
    }
}

// MARK: - Colours, geometry and rig

final class MochiLookTests: XCTestCase {
    private func part(_ model: MochiModel, _ joint: MochiJoint, _ name: String) -> MochiPart? {
        model.nodes.first { $0.joint == joint }?.parts.first { $0.name == name }
    }

    func testDefaultColoursAndFinishes() {
        let model = MochiRecipe.build(look: MochiLook())
        XCTAssertEqual(part(model, .head, "fur")?.surface, MochiSurface("#FFF6F2", .fur))
        XCTAssertEqual(part(model, .head, "shade")?.surface.hex, "#F7E4E8")
        XCTAssertEqual(part(model, .earLeft, "inner")?.surface.hex, "#F7A8BE")
        XCTAssertEqual(part(model, .nose, "nose")?.surface.hex, "#F7A8BE")
        XCTAssertEqual(part(model, .feet, "pads")?.surface.hex, "#F7A8BE")
        XCTAssertEqual(part(model, .body, "tummy")?.surface.hex, "#FFFFFF")
        XCTAssertEqual(part(model, .body, "tail")?.surface.finish, .fluff)
        let blush = part(model, .cheeks, "blush")?.surface
        XCTAssertEqual(blush?.hex, "#FF9FB7")
        XCTAssertEqual(blush?.finish, .blush)
        XCTAssertEqual(blush?.opacity ?? 0, 0.45, accuracy: 0.001)
        XCTAssertEqual(part(model, .eyes, "eye")?.surface, MochiSurface("#3B2A3F", .glossy))
        XCTAssertEqual(part(model, .eyes, "highlight")?.surface.finish, .sparkle)
        XCTAssertEqual(part(model, .mouth, "mouth")?.surface.finish, .glossy)
    }

    func testPresetsColourTheRightParts() {
        for preset in MochiPreset.allCases {
            let palette = preset.palette
            let model = MochiRecipe.build(look: MochiLook(preset: preset))
            XCTAssertEqual(part(model, .body, "fur")?.surface.hex, palette.fur, "\(preset)")
            XCTAssertEqual(part(model, .earRightTip, "inner")?.surface.hex, palette.accent, "\(preset)")
            XCTAssertEqual(part(model, .feet, "pads")?.surface.hex, palette.accent, "\(preset)")
            XCTAssertEqual(part(model, .eyes, "eye")?.surface.hex, palette.eye, "\(preset)")
        }
        XCTAssertEqual(MochiPreset.matcha.palette.fur, "#EEF5E6")
        XCTAssertEqual(MochiPreset.matcha.palette.accent, "#A8CFA0")
        XCTAssertEqual(MochiPreset.taro.palette.fur, "#F1EAFB")
        XCTAssertEqual(MochiPreset.mocha.palette.accent, "#C99A7A")
        XCTAssertEqual(MochiPreset.midnight.palette.fur, "#3B3550")
        let midnight = MochiRecipe.build(look: MochiLook(preset: .midnight))
        let normal = MochiRecipe.build(look: MochiLook())
        XCTAssertGreaterThan(part(midnight, .eyes, "highlight")!.surface.glow, part(normal, .eyes, "highlight")!.surface.glow,
                             "Midnight's sparkles are brighter")
    }

    func testCustomColoursOverrideTheirRolesOnly() {
        var look = MochiLook(preset: .taro)
        look.accent = "#123456"
        XCTAssertTrue(look.isCustom)
        XCTAssertEqual(look.palette.accent, "#123456")
        XCTAssertEqual(look.palette.fur, MochiPreset.taro.palette.fur)
        look.fur = "#808080"
        XCTAssertEqual(look.palette.fur, "#808080")
        XCTAssertNotEqual(look.palette.shade, MochiPreset.taro.palette.shade, "Shading follows a custom fur")
        look.choose(.mocha)
        XCTAssertFalse(look.isCustom)
        XCTAssertEqual(look.palette, MochiPreset.mocha.palette)
    }

    func testAccessoriesAttachWhereTheyBelong() {
        let model = MochiRecipe.build(look: MochiLook(), accessories: [.glasses, .scarf])
        XCTAssertNotNil(part(model, .head, "accessory.glasses"))
        XCTAssertNotNil(part(model, .body, "accessory.scarf"))
        let sprout = MochiRecipe.build(look: MochiLook(floppyEar: .right), accessories: [.sprout])
        XCTAssertNotNil(part(sprout, .earRightTip, "accessory.sprout"), "On the floppy ear")
        let bothUp = MochiRecipe.build(look: MochiLook(floppyEar: .none), accessories: [.bow])
        XCTAssertNotNil(part(bothUp, .head, "accessory.bow"), "No floppy ear: on the head")
        XCTAssertEqual(MochiRecipe.build(look: MochiLook(), accessories: [.glasses, .scarf, .beret]).accessories.count, 2)
    }

    func testHeadIsAboutSixtyPercentOfTheHeight() {
        // The head sphere's height over soles-to-top of head (a baby's big head).
        let model = MochiRecipe.build(look: MochiLook())
        let head = model.nodes.first { $0.joint == .head }!.parts.first { $0.name == "fur" }!.mesh
        let headSphere = head.positions.prefix(29 * 19)   // the first sphere: the head itself
        let headHeight = headSphere.map(\.y).max()! - headSphere.map(\.y).min()!
        let total = MochiRecipe.headPivot.y + headSphere.map(\.y).max()!
        XCTAssertEqual(headHeight / total, 0.62, accuracy: 0.05)
    }

    func testTheFloppyEarFlopsAndTheUprightOneStandsUp() {
        let t = MochiRig.transforms(.idle, floppyEar: .right)
        let up = SIMD3<Float>(0, 1, 0)
        func tipDirection(_ base: MochiJoint, _ tip: MochiJoint) -> SIMD3<Float> {
            (t[base]!.rotation * t[tip]!.rotation).act(up)
        }
        XCTAssertGreaterThan(tipDirection(.earLeft, .earLeftTip).y, 0.8, "Left ear stands up")
        XCTAssertLessThan(tipDirection(.earRight, .earRightTip).y, 0, "Right ear's tip hangs down")
        XCTAssertGreaterThan(tipDirection(.earRight, .earRightTip).x, 0, "…over the outside of the head")
        let both = MochiRig.transforms(.idle, floppyEar: .none)
        XCTAssertGreaterThan((both[.earRight]!.rotation * both[.earRightTip]!.rotation).act(up).y, 0.8)
        var listening = MochiPosture()
        listening.floppyLift = 0.5
        let half = MochiRig.transforms(listening, floppyEar: .right)
        XCTAssertGreaterThan((half[.earRight]!.rotation * half[.earRightTip]!.rotation).act(up).y, tipDirection(.earRight, .earRightTip).y)
    }

    func testLoafLowersTheBodyAndDroopLaysTheEarsFlat() {
        var loaf = MochiPosture()
        loaf.body = .loaf
        XCTAssertLessThan(MochiRig.transforms(loaf, floppyEar: .right)[.body]!.translation.y, 0)
        var droop = MochiPosture()
        droop.droop = true
        let t = MochiRig.transforms(droop, floppyEar: .right)
        XCTAssertLessThan(t[.earLeft]!.rotation.act([0, 1, 0]).y, 0.5)
        XCTAssertTrue(t[.sweat]!.visible == false, "Sweat only when asked")
        droop.sweat = true
        XCTAssertTrue(MochiRig.transforms(droop, floppyEar: .right)[.sweat]!.visible)
    }

    @MainActor
    func testUnderThirtyEntitiesWithAnAccessory() {
        for accessory in MochiAccessory.allCases {
            let figure = MochiFigure(look: MochiLook(), accessories: [accessory])
            XCTAssertLessThan(figure.modelEntityCount, 30, "\(accessory)")
        }
        let two = MochiFigure(look: MochiLook(), accessories: [.glasses, .scarf])
        XCTAssertLessThan(two.modelEntityCount, 30)
        XCTAssertLessThan(two.model.triangleCount, 60_000, "Within the custom-character polygon budget")
        let room = MochiRecipe.build(look: MochiLook(), accessories: [.headphones], detail: .room)
        XCTAssertLessThan(room.triangleCount, two.model.triangleCount / 2, "Rooms use a lighter mesh")
    }

    @MainActor
    func testPosingSwapsExpressions() {
        let figure = MochiFigure(look: MochiLook())
        let openEyes = (figure[.eyes] as? ModelEntity)?.model?.mesh
        var happy = MochiPosture()
        happy.eyes = .happy
        happy.mouth = .open
        figure.apply(happy)
        XCTAssertFalse((figure[.eyes] as? ModelEntity)?.model?.mesh === openEyes, "^ ^ arcs")
        XCTAssertEqual(figure[.eyes]?.findEntity(named: "highlight")?.isEnabled, false, "No sparkles on closed eyes")
        var failure = MochiPosture()
        failure.sweat = true
        figure.apply(failure)
        XCTAssertEqual(figure[.sweat]?.isEnabled, true)
        XCTAssertEqual(figure[.eyes]?.findEntity(named: "highlight")?.isEnabled, true)
    }
}

// MARK: - Settings persist

final class MochiSettingsTests: XCTestCase {
    func testMochiIsTheDefault() {
        XCTAssertEqual(CompanionSettings().character, .mochi)
        XCTAssertEqual(CompanionSettings.Character.allCases.first, .mochi)
        XCTAssertEqual(CharacterSource.from(CompanionSettings()), .procedural(.mochi))
        var custom = CompanionSettings()
        custom.character = .custom
        XCTAssertEqual(CharacterSource.from(custom), .procedural(.mochi), "No file yet: Mochi")
    }

    func testCustomisationsSurviveARelaunch() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mochi-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        var settings = CompanionSettings()
        settings.mochi.look = MochiLook(preset: .midnight, accent: "#ABCDEF", floppyEar: .left)
        settings.mochi.accessories.auto = false
        settings.mochi.accessories.perRoom[.desktop] = [.bow]
        settings.mochi.accessories.perRoom[.studyLibrary] = [.scarf]
        settings.size = .small
        settings.intensity = .reduced
        do {
            let store = try AtlasStore(database: SQLiteDatabase(path: url.path))
            try store.saveCompanionSettings(settings)
        }
        let relaunched = try AtlasStore(database: SQLiteDatabase(path: url.path))
        XCTAssertEqual(try relaunched.companionSettings(), settings)
    }

    func testExistingCompanionsSwitchToMochiOnce() throws {
        let store = try AtlasStore.inMemory()
        // A robot saved before Mochi existed: no flag in extra_json.
        var old = CompanionSettings()
        old.character = .robot
        old.primaryColor = "#FF8800"
        try store.saveCompanionSettings(old)
        try store.database.run("UPDATE companion_settings SET extra_json = '{}' WHERE id = 1;")

        let switched = try store.companionSettings()
        XCTAssertEqual(switched.character, .mochi)
        XCTAssertEqual(switched.primaryColor, "#FF8800", "The robot's colours are kept")

        var back = switched
        back.character = .robot
        try store.saveCompanionSettings(back)
        XCTAssertEqual(try store.companionSettings().character, .robot, "Choosing the robot again sticks")
    }
}
