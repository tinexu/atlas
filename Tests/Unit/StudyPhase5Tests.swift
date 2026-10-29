import RealityKit
import XCTest
@testable import AtlasCompanion
@testable import AtlasCore
@testable import AtlasSpaces
@testable import AtlasSpacesUI
@testable import AtlasStudy

/// Serves canned Open-Meteo answers, or fails like being offline.
final class MockWeatherFetcher: WeatherFetching, @unchecked Sendable {
    private let lock = NSLock()
    var offline = false
    var code = 61
    private(set) var requests: [URL] = []

    func data(from url: URL) async throws -> Data {
        lock.withLock { requests.append(url) }
        if offline { throw URLError(.notConnectedToInternet) }
        if url.host?.hasPrefix("geocoding") == true {
            return Data("""
            {"results":[{"name":"Boston","latitude":42.36,"longitude":-71.06,"country":"United States","country_code":"US","admin1":"Massachusetts"},
                        {"name":"Boston","latitude":52.97,"longitude":-0.03,"country":"United Kingdom","country_code":"GB","admin1":"England"}]}
            """.utf8)
        }
        return Data("""
        {"current":{"time":1800000000,"weather_code":\(code),"temperature_2m":9.4},"daily":{"sunrise":[1799997000],"sunset":[1800035000]}}
        """.utf8)
    }

    var count: Int { lock.withLock { requests.count } }
}

final class WeatherTests: XCTestCase {
    typealias Weather = StudyRoomState.WindowView.Weather

    func testWMOCodesMapToTheWindowsWeather() {
        let cases: [(Int, Weather)] = [(0, .clear), (1, .clear), (2, .clouds), (3, .clouds), (45, .fog), (48, .fog), (51, .rain),
                                       (61, .rain), (65, .rain), (80, .rain), (95, .rain), (71, .snow), (75, .snow), (86, .snow)]
        for (code, weather) in cases { XCTAssertEqual(WeatherMapping.weather(code: code), weather, "code \(code)") }
        XCTAssertEqual(WeatherMapping.describe(code: 61), "Light rain")
    }

    func testSkyFollowsTheSun() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        func at(_ hour: Int, _ minute: Int = 0) -> Date {
            calendar.date(from: DateComponents(year: 2026, month: 10, day: 28, hour: hour, minute: minute))!
        }
        let sunrise = at(7, 10), sunset = at(17, 40)
        XCTAssertEqual(WeatherMapping.sky(at: at(5), sunrise: sunrise, sunset: sunset, calendar: calendar), .night)
        XCTAssertEqual(WeatherMapping.sky(at: at(7), sunrise: sunrise, sunset: sunset, calendar: calendar), .dawn)
        XCTAssertEqual(WeatherMapping.sky(at: at(12), sunrise: sunrise, sunset: sunset, calendar: calendar), .day)
        XCTAssertEqual(WeatherMapping.sky(at: at(16, 30), sunrise: sunrise, sunset: sunset, calendar: calendar), .golden)
        XCTAssertEqual(WeatherMapping.sky(at: at(18), sunrise: sunrise, sunset: sunset, calendar: calendar), .blueHour)
        XCTAssertEqual(WeatherMapping.sky(at: at(22), sunrise: sunrise, sunset: sunset, calendar: calendar), .night)
        // Never fetched: a typical day.
        XCTAssertEqual(WeatherMapping.sky(at: at(12), sunrise: nil, sunset: nil, calendar: calendar), .day)
        XCTAssertEqual(WeatherMapping.sky(at: at(23), sunrise: nil, sunset: nil, calendar: calendar), .night)
        // Sun times from an old cache keep their time of day.
        let lastWeek = calendar.date(byAdding: .day, value: -7, to: sunset)!
        XCTAssertEqual(WeatherMapping.sky(at: at(18), sunrise: nil, sunset: lastWeek, calendar: calendar), .blueHour)
    }

    func testFetchesCachesAndFallsBackWhenOffline() async throws {
        let store = try AtlasStore.inMemory()
        let fetcher = MockWeatherFetcher()
        var clock = Date(timeIntervalSince1970: 1_800_000_000)
        let now = LockedBox(clock)
        let service = WeatherService(store: store, fetcher: fetcher, now: { now.value })

        // No city: the time of day only.
        XCTAssertEqual(service.view(city: "").weather, .clear)
        XCTAssertTrue(service.view(city: "").detail.contains("set a weather city"))

        let changed = await service.refresh(city: "Boston, MA")
        XCTAssertTrue(changed)
        XCTAssertEqual(fetcher.count, 2, "geocode, then forecast")
        XCTAssertEqual(service.place(for: "boston, ma")?.region, "Massachusetts, United States", "the MA hint picks the US one")
        let view = service.view(city: "Boston, MA")
        XCTAssertEqual(view.weather, .rain)
        XCTAssertTrue(view.detail.hasPrefix("Light rain · 9°"), view.detail)
        XCTAssertTrue(view.detail.hasSuffix("Boston"))

        // Within 30 minutes: no new request.
        clock += 10 * 60
        now.value = clock
        let again = await service.refresh(city: "Boston, MA")
        XCTAssertFalse(again)
        XCTAssertEqual(fetcher.count, 2)

        // Offline: the last reading stays for a while, then the window shows only the time of day.
        fetcher.offline = true
        clock += 40 * 60
        now.value = clock
        let failed = await service.refresh(city: "Boston, MA")
        XCTAssertFalse(failed)
        XCTAssertEqual(service.view(city: "Boston, MA").weather, .rain)
        clock += 4 * 3600
        now.value = clock
        let stale = service.view(city: "Boston, MA")
        XCTAssertEqual(stale.weather, .clear)
        XCTAssertTrue(stale.detail.contains("offline"), stale.detail)

        // A new city looks itself up again.
        fetcher.offline = false
        fetcher.code = 73
        _ = await service.refresh(city: "Boston, England")
        XCTAssertEqual(service.place(for: "Boston, England")?.region, "England, United Kingdom")
        XCTAssertEqual(service.view(city: "Boston, England").weather, .snow)
    }
}

/// A value shared with a `@Sendable` closure.
final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

final class StudyShelfTests: XCTestCase {
    private let chem = Course(name: "Chemistry", code: "CHEM101", color: "#34466B")
    private let cs = Course(name: "CS", code: "CS180", color: "#7D3B45")

    private func session(_ term: String, hours: Double, course: Course?, day: Int) -> StudySession {
        StudySession(guess: course.map { CourseGuess(courseID: $0.id, reason: .chosen) }, term: term,
                     startedAt: Date(timeIntervalSince1970: 1_790_000_000 + Double(day) * 86_400), endedAt: nil,
                     focusedSeconds: hours * 3600)
    }

    func testABookForEveryHourInTheCourseThatCompletedIt() {
        let sessions = [
            session("Fall 2026", hours: 0.75, course: chem, day: 1),
            session("Fall 2026", hours: 0.5, course: cs, day: 2),      // completes hour 1 → CS
            session("Fall 2026", hours: 2.2, course: chem, day: 3),    // hours 2 and 3 → CHEM
            session("Fall 2026", hours: 1.0, course: nil, day: 4),     // hour 4 → a palette colour
        ]
        let terms = StudyShelf.terms(sessions: sessions, currentTerm: "Fall 2026", courses: [chem, cs])
        XCTAssertEqual(terms.count, 1)
        XCTAssertEqual(terms[0].books.map(\.color).prefix(3), ["#7D3B45", "#34466B", "#34466B"])
        XCTAssertEqual(terms[0].books.count, 4)
        XCTAssertTrue(CourseColors.palette.contains(terms[0].books[3].color))
        let section = StudyShelf.sections(terms)[0]
        XCTAssertEqual(section.hours, 4)
        XCTAssertTrue(section.detail.hasPrefix("Fall 2026 · 4 h 27 m studied · 4 books"), section.detail)
        XCTAssertTrue(section.detail.contains("CHEM 101 2 h 57 m"), section.detail)
    }

    func testTermRolloverStartsANewSectionAndKeepsTheOldOne() {
        let sessions = [session("Spring 2026", hours: 3, course: chem, day: 1), session("Fall 2026", hours: 1.5, course: cs, day: 200)]
        let terms = StudyShelf.terms(sessions: sessions, currentTerm: "Fall 2026", courses: [chem, cs])
        XCTAssertEqual(terms.map(\.name), ["Spring 2026", "Fall 2026"])
        XCTAssertEqual(terms.map(\.books.count), [3, 1])
        // A new term with nothing studied yet still gets its (empty) section, last.
        let next = StudyShelf.terms(sessions: sessions, currentTerm: "Spring 2027", courses: [chem, cs])
        XCTAssertEqual(next.map(\.name), ["Spring 2026", "Fall 2026", "Spring 2027"])
        XCTAssertEqual(next.last?.books.count, 0)
        XCTAssertTrue(StudyShelf.sections(next).last?.detail.contains("A book appears here for every hour") ?? false)
    }

    @MainActor
    func testShelfLayoutRunsOnAndDropsTheOldestWhenFull() {
        func section(_ term: String, _ count: Int) -> StudyRoomState.ShelfSection {
            .init(term: term, hours: count, colors: Array(repeating: "#34466B", count: count))
        }
        let layout = StudyLibraryBuilder.earnedLayout([section("Spring 2026", 10), section("Fall 2026", 70)])
        XCTAssertEqual(layout.map(\.section), [0, 1])
        XCTAssertEqual(layout[0].plaque.slot, 0)
        XCTAssertEqual(layout[1].plaque.slot, 1, "a new term starts a new section")
        XCTAssertEqual(layout[1].books.count, 70)
        XCTAssertGreaterThan(Set(layout[1].books.map(\.slot)).count, 1, "and runs on into the next")
        for placement in layout {
            for book in placement.books { XCTAssertTrue(StudyLibraryBuilder.earnedRange(book.slot).contains(book.z)) }
        }
        // Too much for six sections: the oldest term is left off, the current one stays.
        let full = StudyLibraryBuilder.earnedLayout([section("Fall 2025", 100), section("Spring 2026", 60), section("Fall 2026", 30)])
        XCTAssertEqual(full.map(\.section), [1, 2])
    }
}

final class StudyPhase5ModuleTests: XCTestCase {
    private var time: TimeHarness!
    private var study: StudyModule!

    override func setUp() async throws {
        time = try TimeHarness()
        study = try StudyModule(core: time.core, reminders: MockReminderStore(), weatherFetcher: MockWeatherFetcher())
        study.service.now = { [environment = time.environment] in environment.now() }
        var settings = study.service.settings
        settings.dayBoundaryHour = 0
        study.service.settings = settings
    }

    func testStreakUsesTheMinutesSetting() throws {
        let store = time.core.store
        let today = study.service.settings.studyDay.start(of: time.environment.now())
        for day in 1...3 {
            try store.saveStudySession(StudySession(startedAt: today.addingTimeInterval(-Double(day) * 86_400 + 3600),
                                                    endedAt: today.addingTimeInterval(-Double(day) * 86_400 + 5400), focusedSeconds: 20 * 60))
        }
        XCTAssertEqual(study.streak().days, 0, "20 minutes isn't a day at the default 30")
        var settings = study.service.settings
        settings.streakMinutes = 15
        study.service.settings = settings
        let streak = study.streak()
        XCTAssertEqual(streak.days, 3)
        XCTAssertTrue(streak.detail.contains("15 m more today makes it 4"), streak.detail)
    }

    func testShelfComesFromSavedSessions() throws {
        let chem = try study.service.save(Course(name: "Chemistry", code: "CHEM 101", color: ""))
        let now = time.environment.now()
        try time.core.store.saveStudySession(StudySession(guess: CourseGuess(courseID: chem.id, reason: .clicked),
                                                          term: AcademicTerm.name(for: now), startedAt: now.addingTimeInterval(-7200),
                                                          endedAt: now, focusedSeconds: 2 * 3600 + 60))
        let shelf = study.shelf()
        XCTAssertEqual(shelf.last?.term, AcademicTerm.name(for: now))
        XCTAssertEqual(shelf.last?.colors, [chem.color, chem.color])
    }

    func testProfilesAreAddedOnceAndStayDeleted() throws {
        let library = SpaceLibrary(core: time.core)
        let space = try library.createSpace(from: SpaceTemplates.studyLibrary)
        try study.automations.install()
        let names = try time.core.store.profiles(spaceID: space.id).map(\.name)
        for name in ["Exam cram", "Default", "Reading", "Problem set"] { XCTAssertTrue(names.contains(name), name) }
        let reading = try XCTUnwrap(time.core.store.profiles(spaceID: space.id).first { $0.name == "Reading" })
        XCTAssertEqual(try time.core.store.workflow(id: reading.workflowID)?.steps.first?.actionID, OpenReadingAction.id)
        try library.deleteProfile(id: reading.id)
        try study.automations.install()
        XCTAssertFalse(try time.core.store.profiles(spaceID: space.id).contains { $0.name == "Reading" })
    }

    func testProblemSetPDFIsTheBestNameMatchElseTheNewest() {
        let now = Date()
        let pdfs = [(path: "/c/Lecture 9.pdf", modified: now), (path: "/c/Problem Set 4.pdf", modified: now.addingTimeInterval(-86_400)),
                    (path: "/c/ps3.pdf", modified: now.addingTimeInterval(-9 * 86_400))]
        XCTAssertEqual(CoursePDFs.best(pdfs, for: "CHEM101 Problem Set 4"), "/c/Problem Set 4.pdf")
        XCTAssertEqual(CoursePDFs.best(pdfs, for: "Essay draft"), "/c/Lecture 9.pdf")
        XCTAssertEqual(CoursePDFs.best(pdfs, for: nil), "/c/Lecture 9.pdf")
    }
}

final class StudyHoldTests: XCTestCase {
    private func offer(_ title: String) -> Suggestion {
        Suggestion(kind: .offer, title: title, reason: "test", actionTitle: "Open", action: .openPermissions)
    }

    func testOffersWaitForTheBreakExceptUrgentOnes() {
        var hold = StudyHold()
        XCTAssertEqual(hold.offer(offer("Due today: PS 3"))?.title, "Due today: PS 3", "not studying: shown at once")
        XCTAssertNil(hold.setFocus(true))
        XCTAssertNil(hold.offer(offer("Your week: 3 assignments")))
        XCTAssertNil(hold.offer(offer("Your week: 3 assignments")), "no duplicates")
        XCTAssertNil(hold.offer(offer("Morning check")))
        XCTAssertEqual(hold.offer(offer("CHEM 101 starts at 10:00"), urgent: true)?.title, "CHEM 101 starts at 10:00")
        XCTAssertEqual(hold.offer(Suggestion(kind: .workflowFailed, title: "Failed", reason: "", actionTitle: "", action: .openPermissions))?.title,
                       "Failed")
        XCTAssertEqual(hold.offer(offer("Off"), holding: false)?.title, "Off", "the setting can turn holding off")
        XCTAssertEqual(hold.held.map(\.title), ["Your week: 3 assignments", "Morning check"])

        // A break: the first comes out, the next follows when asked.
        XCTAssertEqual(hold.setFocus(false)?.title, "Your week: 3 assignments")
        XCTAssertEqual(hold.next()?.title, "Morning check")
        XCTAssertNil(hold.next())
    }

    func testReadingPoseDuringStudyFocus() {
        let reading = CharacterPresentation.make(for: .focus, intensity: .full, reduceMotion: false, reading: true)
        XCTAssertTrue(reading.isReading)
        XCTAssertEqual(reading.opacity, 1)
        XCTAssertFalse(CharacterPresentation.make(for: .focus, intensity: .full, reduceMotion: false).isReading)
        XCTAssertFalse(CharacterPresentation.make(for: .executing, intensity: .full, reduceMotion: false, reading: true).isReading)
    }
}

final class StudyLivingRoomTests: XCTestCase {
    @MainActor
    func testFullRoomWithWeatherShelfStarsAndReaderStaysWithinBudget() throws {
        let space = Space(name: "Study Library", group: .school, templateID: StudyLibrary.templateID, accentColor: "#6F8A6E", slot: 0)
        let template = SpaceTemplates.studyLibrary
        let objects = template.objects.map { SpaceObject(spaceID: space.id, kind: $0.kind, label: $0.label, actionID: $0.actionID) }
        let books = (0..<6).map { StudyRoomState.Book(id: UUID(), code: "CHEM \(101 + $0)", name: "C\($0)", color: CourseColors.palette[$0], detail: "") }
        let shelf = [
            StudyRoomState.ShelfSection(term: "Spring 2026", hours: 40, colors: (0..<40).map { CourseColors.palette[$0 % 6] }),
            StudyRoomState.ShelfSection(term: "Fall 2026", hours: 63, colors: (0..<63).map { CourseColors.palette[$0 % 6] }),
        ]
        let study = StudyRoomState(books: books, window: .init(sky: .night, weather: .snow, detail: "Snow"), shelf: shelf,
                                   streak: .init(days: 12, detail: "12 days"), reader: .init(style: .creature, waiting: 2))
        func count(_ entity: Entity) -> Int { 1 + entity.children.reduce(0) { $0 + count($1) } }

        let full = RoomBuilder.build(space: space, room: template.room, objects: objects, detail: true, study: study)
        // Everything at once (six courses, two terms of books, snow, a streak, the reader):
        // a little over the plain room's 150, every part merged by material.
        XCTAssertLessThan(count(full), 165)
        for item in [StudyRoomState.Item.window, .stars, .reader, .shelf("Spring 2026"), .shelf("Fall 2026")] {
            let entity = try XCTUnwrap(full.findEntity(named: item.entityName), item.entityName)
            XCTAssertNotNil(entity.components[CollisionComponent.self], "\(item.entityName) is hoverable")
            XCTAssertEqual(StudyRoomState.Item(entityName: item.entityName), item)
        }
        let miniature = RoomBuilder.build(space: space, room: template.room, objects: objects, detail: false, study: study)
        XCTAssertLessThan(count(miniature), 40)

        // The shelf and reader rebuild the room; weather and stars don't.
        var later = study
        later.window = .init(sky: .day, weather: .clear)
        later.streak = .init(days: 13)
        later.reader?.waiting = 0
        XCTAssertEqual(later.geometry, study.geometry)
        later.shelf[1].colors.append("#34466B")
        XCTAssertNotEqual(later.geometry, study.geometry)
    }

    /// Clicks reach the first shape along the ray, and the room's back-wall
    /// shape (inner face at world z = −1.0) selects the room. Every clickable
    /// item must stick out in front of it, or clicking it just selects the room.
    @MainActor
    func testEveryClickableItemIsInFrontOfTheBackWall() throws {
        let space = Space(name: "Study Library", group: .school, templateID: StudyLibrary.templateID, accentColor: "#6F8A6E", slot: 0)
        let template = SpaceTemplates.studyLibrary
        let objects = template.objects.map { SpaceObject(spaceID: space.id, kind: $0.kind, label: $0.label, actionID: $0.actionID) }
        let study = StudyRoomState(shelf: [.init(term: "Fall 2026", hours: 3, colors: ["#34466B", "#34466B", "#34466B"])],
                                   streak: .init(days: 2), reader: .init())
        let room = RoomBuilder.build(space: space, room: template.room, objects: objects, detail: true, study: study)
        let wallFront: Float = -1.0
        var checked = 0
        func visit(_ entity: Entity) {
            if entity.name.hasPrefix("studyitem:"), let collision = entity.components[CollisionComponent.self] {
                let matrix = entity.transformMatrix(relativeTo: room)
                let front = collision.shapes.map { shape -> Float in
                    let b = shape.bounds
                    return [b.min, b.max].map { (matrix * SIMD4($0, 1)).z }.max()!
                }.max()!
                XCTAssertGreaterThan(front, wallFront + 0.002, "\(entity.name) is behind the back wall")
                checked += 1
            }
            entity.children.forEach(visit)
        }
        visit(room)
        XCTAssertGreaterThanOrEqual(checked, 5)
    }

    func testHoverTextForEachItem() {
        let state = StudyRoomState(window: .init(detail: "Light rain · 9° · Boston"), shelf: [.init(term: "Fall 2026", hours: 1, colors: ["#000000"], detail: "Fall")],
                                   streak: .init(days: 3, detail: "Streak: 3 days"), reader: .init(detail: "Reading"))
        XCTAssertEqual(state.detail(for: .window), "Light rain · 9° · Boston")
        XCTAssertEqual(state.detail(for: .shelf("Fall 2026")), "Fall")
        XCTAssertEqual(state.detail(for: .stars), "Streak: 3 days")
        XCTAssertEqual(state.detail(for: .reader), "Reading")
    }
}
