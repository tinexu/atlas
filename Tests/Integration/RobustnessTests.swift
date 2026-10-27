import XCTest
@testable import AtlasCompanion
@testable import AtlasCore
@testable import AtlasOrbit
@testable import AtlasSpaces

/// Stage 08: every schema version upgrades without losing data, and the
/// parsers never crash on odd input.
final class MigrationLadderTests: XCTestCase {
    /// Rows written at each version, using only the columns that version had.
    static let canaries: [Int: [String]] = [
        1: ["INSERT INTO workflow (id, name, created_at, updated_at) VALUES ('11111111-1111-1111-1111-111111111111', 'Canary', 0, 0);",
            "INSERT INTO workflow_node (id, workflow_id, position, action_id, parameters_json) VALUES ('11111111-1111-1111-1111-111111111112', '11111111-1111-1111-1111-111111111111', 0, 'atlas.log', '{\"message\":\"hi\"}');",
            "INSERT INTO user_preference (key, value_json) VALUES ('canary', '\"kept\"');"],
        2: ["INSERT INTO space (id, name, group_name, template_id, accent_color, created_at, updated_at) VALUES ('22222222-2222-2222-2222-222222222222', 'Canary Space', 'Work', 'coding-lab', '#000000', 0, 0);",
            "INSERT INTO activation_profile (id, space_id, name, workflow_id, is_default) VALUES ('22222222-2222-2222-2222-222222222223', '22222222-2222-2222-2222-222222222222', 'Default', '11111111-1111-1111-1111-111111111111', 1);"],
        3: ["INSERT INTO window_layout (id, name, created_at, updated_at) VALUES ('33333333-3333-3333-3333-333333333333', 'Canary Layout', 0, 0);"],
        5: ["INSERT INTO file_location (id, path, name, added_at) VALUES ('55555555-5555-5555-5555-555555555555', '/canary', 'canary', 0);",
            "INSERT INTO file_operation (id, kind, source, destination, performed_at) VALUES ('55555555-5555-5555-5555-555555555556', 'move', '/a', '/b', 0);"],
        6: ["INSERT INTO companion_command (id, text, source, created_at) VALUES ('66666666-6666-6666-6666-666666666666', 'open my coding room', 'palette', 0);"],
        7: ["INSERT INTO schedule_block (id, title, start_at, end_at, created_at, updated_at) VALUES ('77777777-7777-7777-7777-777777777777', 'Canary Block', 0, 3600, 0, 0);"],
    ]

    func testEveryVersionUpgradesWithoutLosingData() throws {
        for version in 1..<Schema.currentVersion {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("atlas-ladder-v\(version)-\(UUID().uuidString).sqlite")
            defer { for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: url.path + suffix) } }
            do {
                let db = try SQLiteDatabase(path: url.path)
                for (index, sql) in Schema.migrations.prefix(version).enumerated() {
                    try db.transaction {
                        try db.execute(sql)
                        try db.setUserVersion(index + 1)
                    }
                }
                for (since, statements) in Self.canaries.sorted(by: { $0.key < $1.key }) where since <= version {
                    for statement in statements { try db.execute(statement) }
                }
            }

            let store = try AtlasStore(database: SQLiteDatabase(path: url.path))
            XCTAssertEqual(store.database.userVersion, Schema.currentVersion, "v\(version)")
            let workflow = try XCTUnwrap(store.workflow(id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!), "v\(version)")
            XCTAssertEqual(workflow.name, "Canary")
            XCTAssertEqual(workflow.steps.first?.parameters["message"], "hi", "v\(version): steps survive")
            XCTAssertEqual(try store.preference("canary", as: String.self), "kept")
            if version >= 2 { XCTAssertEqual(try store.spaces().first?.name, "Canary Space", "v\(version)") }
            if version >= 3 { XCTAssertEqual(try store.windowLayouts().first?.name, "Canary Layout", "v\(version)") }
            if version >= 5 {
                XCTAssertEqual(try store.locations().first?.path, "/canary", "v\(version)")
                XCTAssertEqual(try store.recentOperations().first?.state, .done, "v\(version): old changes count as finished")
            }
            if version >= 6 { XCTAssertEqual(try store.companionCommands().first?.text, "open my coding room") }
            if version >= 7 { XCTAssertEqual(try store.blocks().first?.title, "Canary Block") }
            XCTAssertNil(DatabaseBackups.integrityProblem(store.database), "v\(version)")
        }
    }
}

final class ParserRobustnessTests: XCTestCase {
    /// Deterministic odd inputs: punctuation, regex characters, emoji,
    /// right-to-left text, control characters, huge numbers, very long text.
    static let inputs: [String] = {
        var inputs = ["", " ", "\n\t", "\0", "{{", "}}", "{{trigger.", "{date:", "{date:yyyy", "{counter}{counter}", "((((", "[a-", "\\",
                      "* + ? ^ $ | ( ) [ ] { }", "for", "for for for", "work on for", "start a -5 minute timer",
                      "start a 99999999999999999999999 hour timer", "every weekday at 99:99", "every day at", "when i open",
                      "when i open ,", "when a file arrives in", "FREQ=", "FREQ=WEEKLY;BYDAY=", "FREQ=DAILY;INTERVAL=0",
                      "FREQ=DAILY;INTERVAL=-3;COUNT=-1", "FREQ=MONTHLY;UNTIL=99999999", "RRULE:", "cmd+", "+++", "cmd+shift+option+ctrl+",
                      "size:>", "size:>>>10zb", "ext:", "modified:<", "created:>2026-13-45", "in:", "name:\"", "\"\"\"",
                      "🙂🚀 open 🧑‍💻 room", "שלום עולם", "مرحبا", "Ä̸̢̛̛͉", "open \u{202E}moor gnidoc", "run 💥",
                      "open my coding room please please please", "I'm going to work on my app for the next ∞ hours",
                      String(repeating: "a", count: 5_000), String(repeating: "open ", count: 500), String(repeating: "{name}", count: 300)]
        var rng = SeededGenerator(seed: 8)
        let pool = Array("abcXYZ019 ,.;:'\"!?-_/\\{}[]()<>*+^$|#@%&~`=🙂é漢\t\n")
        for _ in 0..<300 {
            let length = Int.random(in: 0...60, using: &rng)
            inputs.append(String((0..<length).map { _ in pool.randomElement(using: &rng)! }))
        }
        return inputs
    }()

    func testCompanionParserAndPaletteNeverCrash() {
        let vocabulary = CommandVocabulary(
            spaces: [.init(id: UUID(), name: "Coding Lab", profiles: [(UUID(), "Deep Work", true)], templateID: "coding-lab")],
            workflows: [.init(id: UUID().uuidString, name: "Morning Setup")], apps: [.init(id: "com.apple.Safari", name: "Safari")],
            layouts: [.init(id: UUID().uuidString, name: "Interview")], snapshots: [.init(id: UUID().uuidString, name: "Friday")],
            runningWorkflows: [.init(id: UUID().uuidString, name: "Running")], timers: ["Study"])
        let parser = DeterministicParser(vocabulary: vocabulary)
        let catalog = PaletteCatalog(vocabulary: vocabulary, registry: .standard(), files: nil)
        for input in Self.inputs {
            _ = parser.parse(input)
            _ = catalog.search(input)
            _ = NameMatcher.score(query: input, name: "Coding Lab")
            _ = DeterministicParser.duration(in: input)
        }
    }

    func testOrbitSearchAndRenamePatternsNeverCrash() throws {
        let store = try AtlasStore.inMemory()
        let search = FileSearch(store: store)
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        for input in Self.inputs {
            let query = SearchQuery.parse(input)
            _ = query.text
            _ = try search.search(query, limit: 5)
            _ = FuzzyMatcher.score("Report 2026.pdf", terms: [input])
            _ = RenamePattern.resolve(input, path: "/x/Report.pdf", date: date, match: "CS101", counter: 2)
            let name = RenamePattern.newName(input, path: "/x/Report.pdf", date: date) { _ in false }
            XCTAssertFalse(name.contains("/"), "A pattern can't create a path: \(input.prefix(40))")
        }
    }

    func testTemplatesRulesShortcutsAndWorkflowPhrasesNeverCrash() {
        let block = ScheduleBlock(title: "B", start: Date(timeIntervalSince1970: 0), end: Date(timeIntervalSince1970: 3_600))
        let context = GenerationContext(spaces: ["Coding Lab"], apps: [("com.apple.Safari", "Safari")])
        for input in Self.inputs {
            _ = Templates.resolve(input, scope: ["trigger.path": "/x"])
            _ = Templates.placeholders(in: input)
            _ = HotKey.parse(input)
            _ = RRule(input)
            var repeating = block
            repeating.recurrence = .custom(input)
            _ = RecurrenceExpander.occurrences(of: repeating, in: DateInterval(start: .init(timeIntervalSince1970: 0), duration: 30 * 86_400))
            _ = PhraseWorkflowParser.parse(input, context: context)
            _ = PhraseWorkflowParser.parseTime(input)
            _ = try? JSONDecoder().decode(WorkflowBlueprint.self, from: Data(input.utf8))
        }
    }
}

/// xorshift, so the odd inputs are the same every run.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed == 0 ? 0x9E37_79B9_7F4A_7C15 : seed }
    mutating func next() -> UInt64 {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }
}
