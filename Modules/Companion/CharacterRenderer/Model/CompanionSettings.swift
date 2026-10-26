import AtlasCore
import Foundation

/// How the Companion looks and behaves. The character's look never changes
/// what it can do: every option here is cosmetic or a privacy choice.
public struct CompanionSettings: Codable, Equatable, Sendable {
    public enum Character: String, Codable, CaseIterable, Sendable, Identifiable {
        case robot, creature, orb, custom
        public var id: Self { self }
        public var title: String {
            switch self {
            case .robot: return "Floating Robot"
            case .creature: return "Round Creature"
            case .orb: return "Geometric Orb"
            case .custom: return "Custom (USDZ)"
            }
        }
    }

    public enum Accessory: String, Codable, CaseIterable, Sendable, Identifiable {
        case none, antenna, hat, headphones, glasses
        public var id: Self { self }
        public var title: String { rawValue == "none" ? "None" : rawValue.capitalized }
    }

    public enum Size: String, Codable, CaseIterable, Sendable, Identifiable {
        case small, medium, large
        public var id: Self { self }
        public var title: String { rawValue.prefix(1).uppercased() }
        /// Points on screen.
        public var points: Double {
            switch self {
            case .small: return 84
            case .medium: return 116
            case .large: return 156
            }
        }
    }

    public enum Intensity: String, Codable, CaseIterable, Sendable, Identifiable {
        case full, reduced, still
        public var id: Self { self }
        public var title: String {
            switch self {
            case .full: return "Full"
            case .reduced: return "Reduced"
            case .still: return "Still"
            }
        }
    }

    public enum OverlayMode: String, Codable, CaseIterable, Sendable, Identifiable {
        case onTop, normal, hidden
        public var id: Self { self }
        public var title: String {
            switch self {
            case .onTop: return "Always on top"
            case .normal: return "Normal window"
            case .hidden: return "Hidden"
            }
        }
    }

    public enum AIProvider: String, Codable, CaseIterable, Sendable, Identifiable {
        case off, onDevice, cloud
        public var id: Self { self }
        public var title: String {
            switch self {
            case .off: return "Off (built-in commands only)"
            case .onDevice: return "On-device (Apple Intelligence)"
            case .cloud: return "Cloud (Claude, your API key)"
            }
        }
    }

    /// Context the Companion may use for suggestions and, when AI is on,
    /// send with a command. Everything is read locally.
    public struct ContextOptions: Codable, Equatable, Sendable {
        public var activeSpace = true
        public var frontmostApp = true
        public var runs = true
        public var timers = true
        public var health = true
        public var reviews = true

        public init() {}
    }

    public var character: Character = .robot
    public var primaryColor = "#5B8DEF"
    public var secondaryColor = "#F5F7FA"
    public var accessory: Accessory = .none
    public var size: Size = .medium
    public var intensity: Intensity = .full
    public var overlayMode: OverlayMode = .onTop
    /// Clicks pass through the character until the hotkey makes it interactive.
    public var clickThrough = true
    /// Display arrangement signature → bottom-left corner of the character.
    public var positions: [String: StoredPoint] = [:]
    public var aiProvider: AIProvider = .off
    public var context = ContextOptions()

    // Stored together in `extra_json`.
    public var companionHotKey = "opt+space"
    public var paletteHotKey = "cmd+shift+space"
    public var cloudModel = "claude-opus-5-5"
    public var customCharacterPath: String?
    public var suggestionsEnabled = true
    /// Suggestion kinds the person said not to suggest again.
    public var mutedSuggestions: Set<String> = []
    public var favoriteWorkflowIDs: [UUID] = []
    /// Keep the robot calm while a focus session runs (a Focus Space or a timer named "focus").
    public var focusSpaceIDs: [UUID] = []
    public var repetitionDetection = true

    public init() {}
}

public struct StoredPoint: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

/// The fields kept in `extra_json`.
private struct ExtraSettings: Codable {
    var companionHotKey: String?
    var paletteHotKey: String?
    var cloudModel: String?
    var customCharacterPath: String?
    var suggestionsEnabled: Bool?
    var mutedSuggestions: Set<String>?
    var favoriteWorkflowIDs: [UUID]?
    var focusSpaceIDs: [UUID]?
    var repetitionDetection: Bool?
}

extension AtlasEvent.Name {
    /// Payload: text, summary, source (palette / click / voice), plan.
    public static let companionCommand = "companion.command"
    /// Payload: kind, title, reason, suggestionId.
    public static let companionSuggestionShown = "companion.suggestion.shown"
    public static let companionSuggestionAccepted = "companion.suggestion.accepted"
    public static let companionSuggestionDismissed = "companion.suggestion.dismissed"
    /// Payload: state, previous.
    public static let companionStateChanged = "companion.state.changed"
    /// Payload: changed settings were saved.
    public static let companionSettingsChanged = "companion.settings.changed"
}

// MARK: - Storage

extension AtlasStore {
    public func companionSettings() throws -> CompanionSettings {
        guard let row = try database.query("SELECT * FROM companion_settings WHERE id = 1;").first else {
            return CompanionSettings()
        }
        var settings = CompanionSettings()
        settings.character = row.string("character").flatMap(CompanionSettings.Character.init) ?? .robot
        settings.primaryColor = row.string("primary_color") ?? settings.primaryColor
        settings.secondaryColor = row.string("secondary_color") ?? settings.secondaryColor
        settings.accessory = row.string("accessory").flatMap(CompanionSettings.Accessory.init) ?? .none
        settings.size = row.string("size").flatMap(CompanionSettings.Size.init) ?? .medium
        settings.intensity = row.string("intensity").flatMap(CompanionSettings.Intensity.init) ?? .full
        settings.overlayMode = row.string("overlay_mode").flatMap(CompanionSettings.OverlayMode.init) ?? .onTop
        settings.clickThrough = row.bool("click_through") ?? true
        settings.positions = CompanionJSON.decode([String: StoredPoint].self, row.string("positions_json")) ?? [:]
        settings.aiProvider = row.string("ai_provider").flatMap(CompanionSettings.AIProvider.init) ?? .off
        settings.context = CompanionJSON.decode(CompanionSettings.ContextOptions.self, row.string("context_json")) ?? .init()
        if let extra = CompanionJSON.decode(ExtraSettings.self, row.string("extra_json")) {
            settings.companionHotKey = extra.companionHotKey ?? settings.companionHotKey
            settings.paletteHotKey = extra.paletteHotKey ?? settings.paletteHotKey
            settings.cloudModel = extra.cloudModel ?? settings.cloudModel
            settings.customCharacterPath = extra.customCharacterPath
            settings.suggestionsEnabled = extra.suggestionsEnabled ?? true
            settings.mutedSuggestions = extra.mutedSuggestions ?? []
            settings.favoriteWorkflowIDs = extra.favoriteWorkflowIDs ?? []
            settings.focusSpaceIDs = extra.focusSpaceIDs ?? []
            settings.repetitionDetection = extra.repetitionDetection ?? true
        }
        return settings
    }

    public func saveCompanionSettings(_ settings: CompanionSettings) throws {
        let extra = ExtraSettings(
            companionHotKey: settings.companionHotKey, paletteHotKey: settings.paletteHotKey, cloudModel: settings.cloudModel,
            customCharacterPath: settings.customCharacterPath, suggestionsEnabled: settings.suggestionsEnabled,
            mutedSuggestions: settings.mutedSuggestions, favoriteWorkflowIDs: settings.favoriteWorkflowIDs,
            focusSpaceIDs: settings.focusSpaceIDs, repetitionDetection: settings.repetitionDetection
        )
        try database.run(
            """
            INSERT INTO companion_settings
                (id, character, primary_color, secondary_color, accessory, size, intensity, overlay_mode, click_through,
                 positions_json, ai_provider, context_json, extra_json, updated_at)
            VALUES (1, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                character = excluded.character, primary_color = excluded.primary_color,
                secondary_color = excluded.secondary_color, accessory = excluded.accessory, size = excluded.size,
                intensity = excluded.intensity, overlay_mode = excluded.overlay_mode, click_through = excluded.click_through,
                positions_json = excluded.positions_json, ai_provider = excluded.ai_provider,
                context_json = excluded.context_json, extra_json = excluded.extra_json, updated_at = excluded.updated_at;
            """,
            [
                .text(settings.character.rawValue), .text(settings.primaryColor), .text(settings.secondaryColor),
                .text(settings.accessory.rawValue), .text(settings.size.rawValue), .text(settings.intensity.rawValue),
                .text(settings.overlayMode.rawValue), .from(settings.clickThrough),
                .text(CompanionJSON.encode(settings.positions)), .text(settings.aiProvider.rawValue),
                .text(CompanionJSON.encode(settings.context)), .text(CompanionJSON.encode(extra)), .from(Date()),
            ]
        )
    }

    // MARK: Command history

    public struct CompanionCommandRecord: Identifiable, Hashable, Sendable {
        public let id: UUID
        public let text: String
        public let summary: String
        public let source: String
        public let createdAt: Date
    }

    /// Keeps the newest 50.
    public func recordCompanionCommand(text: String, summary: String, source: String, at date: Date = Date()) throws {
        try database.transaction {
            try database.run("INSERT INTO companion_command (id, text, summary, source, created_at) VALUES (?, ?, ?, ?, ?);",
                             [.from(UUID()), .text(text), .text(summary), .text(source), .from(date)])
            try database.run("""
                DELETE FROM companion_command WHERE id NOT IN
                    (SELECT id FROM companion_command ORDER BY created_at DESC LIMIT 50);
                """)
        }
    }

    /// Newest first.
    public func companionCommands(limit: Int = 50) throws -> [CompanionCommandRecord] {
        try database.query("SELECT * FROM companion_command ORDER BY created_at DESC LIMIT ?;", [.from(limit)]).compactMap { row in
            guard let id = row.uuid("id"), let text = row.string("text") else { return nil }
            return CompanionCommandRecord(id: id, text: text, summary: row.string("summary") ?? "", source: row.string("source") ?? "",
                                          createdAt: row.date("created_at") ?? Date())
        }
    }

    public func clearCompanionCommands() throws {
        try database.run("DELETE FROM companion_command;")
    }

    // MARK: Suggestion log

    public func logSuggestion(_ suggestion: Suggestion, at date: Date = Date()) throws {
        try database.run("INSERT INTO companion_suggestion (id, kind, title, reason, state, created_at) VALUES (?, ?, ?, ?, 'shown', ?);",
                         [.from(suggestion.id), .text(suggestion.kind.rawValue), .text(suggestion.title), .text(suggestion.reason), .from(date)])
    }

    public func resolveSuggestion(id: UUID, state: SuggestionLogEntry.State, at date: Date = Date()) throws {
        try database.run("UPDATE companion_suggestion SET state = ?, resolved_at = ? WHERE id = ?;",
                         [.text(state.rawValue), .from(date), .from(id)])
    }

    public func suggestionLog(limit: Int = 100) throws -> [SuggestionLogEntry] {
        try database.query("SELECT * FROM companion_suggestion ORDER BY created_at DESC LIMIT ?;", [.from(limit)]).compactMap { row in
            guard let id = row.uuid("id"), let kind = row.string("kind").flatMap(Suggestion.Kind.init) else { return nil }
            return SuggestionLogEntry(id: id, kind: kind, title: row.string("title") ?? "", reason: row.string("reason") ?? "",
                                      state: row.string("state").flatMap(SuggestionLogEntry.State.init) ?? .shown,
                                      createdAt: row.date("created_at") ?? Date(), resolvedAt: row.date("resolved_at"))
        }
    }

    public func clearSuggestionLog() throws {
        try database.run("DELETE FROM companion_suggestion;")
    }

    // MARK: App launches (repetition detection)

    public func recordAppLaunch(bundleID: String, at date: Date = Date()) throws {
        try database.run("INSERT INTO app_launch (bundle_id, launched_at) VALUES (?, ?);", [.text(bundleID), .from(date)])
    }

    /// Oldest first, from `since`.
    public func appLaunches(since: Date) throws -> [AppLaunch] {
        try database.query("SELECT * FROM app_launch WHERE launched_at >= ? ORDER BY launched_at;", [.from(since)]).compactMap { row in
            guard let bundleID = row.string("bundle_id"), let date = row.date("launched_at") else { return nil }
            return AppLaunch(bundleID: bundleID, date: date)
        }
    }

    public func pruneAppLaunches(olderThan date: Date) throws {
        try database.run("DELETE FROM app_launch WHERE launched_at < ?;", [.from(date)])
    }

    public func clearAppLaunches() throws {
        try database.run("DELETE FROM app_launch;")
    }
}

enum CompanionJSON {
    static func encode<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(value)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }

    static func decode<T: Decodable>(_ type: T.Type, _ text: String?) -> T? {
        guard let data = text?.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}
