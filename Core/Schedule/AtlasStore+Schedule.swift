import Foundation

/// Storage for Time Architect, calendar links, recommendations and drafts.
extension AtlasStore {
    // MARK: - Blocks

    public func saveBlock(_ block: ScheduleBlock) throws {
        try database.run(
            """
            INSERT INTO schedule_block
                (id, title, start_at, end_at, kind, color, space_id, profile_id, workflow_id, project_id, recurrence,
                 reminder_minutes, start_behavior, end_behavior, end_space_id, missed_policy, source, external_event_id,
                 calendar_id, automation_workflow_id, notes, created_at, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                title = excluded.title, start_at = excluded.start_at, end_at = excluded.end_at, kind = excluded.kind,
                color = excluded.color, space_id = excluded.space_id, profile_id = excluded.profile_id,
                workflow_id = excluded.workflow_id, project_id = excluded.project_id, recurrence = excluded.recurrence,
                reminder_minutes = excluded.reminder_minutes, start_behavior = excluded.start_behavior,
                end_behavior = excluded.end_behavior, end_space_id = excluded.end_space_id,
                missed_policy = excluded.missed_policy, source = excluded.source,
                external_event_id = excluded.external_event_id, calendar_id = excluded.calendar_id,
                automation_workflow_id = excluded.automation_workflow_id, notes = excluded.notes,
                updated_at = excluded.updated_at;
            """,
            [
                .from(block.id), .text(block.title), .from(block.start), .from(block.end), .text(block.kind.rawValue),
                .from(block.color), .from(block.spaceID?.uuidString), .from(block.profileID?.uuidString),
                .from(block.workflowID?.uuidString), .from(block.projectID?.uuidString), .text(block.recurrence.rawValue),
                .from(block.reminderMinutes), .text(block.startBehavior.rawValue), .text(block.endBehavior.rawValue),
                .from(block.endSpaceID?.uuidString), .text(block.missedPolicy.rawValue), .text(block.source.rawValue),
                .from(block.externalEventID), .from(block.calendarID), .from(block.automationWorkflowID?.uuidString),
                .text(block.notes), .from(block.createdAt), .from(block.updatedAt),
            ]
        )
    }

    public func blocks() throws -> [ScheduleBlock] {
        try database.query("SELECT * FROM schedule_block ORDER BY start_at;").compactMap(Self.block(from:))
    }

    public func block(id: UUID) throws -> ScheduleBlock? {
        try database.query("SELECT * FROM schedule_block WHERE id = ?;", [.from(id)]).first.flatMap(Self.block(from:))
    }

    public func block(externalEventID: String) throws -> ScheduleBlock? {
        try database.query("SELECT * FROM schedule_block WHERE external_event_id = ?;", [.text(externalEventID)]).first.flatMap(Self.block(from:))
    }

    public func deleteBlock(id: UUID) throws {
        try database.transaction {
            try database.run("DELETE FROM schedule_block WHERE id = ?;", [.from(id)])
            try database.run("DELETE FROM block_occurrence WHERE block_id = ?;", [.from(id)])
        }
    }

    private static func block(from row: SQLRow) -> ScheduleBlock? {
        guard let id = row.uuid("id"), let title = row.string("title"), let start = row.date("start_at"), let end = row.date("end_at")
        else { return nil }
        return ScheduleBlock(
            id: id, title: title, start: start, end: end,
            kind: row.string("kind").flatMap(ScheduleBlock.Kind.init) ?? .focus, color: row.string("color"),
            spaceID: row.uuid("space_id"), profileID: row.uuid("profile_id"), workflowID: row.uuid("workflow_id"),
            projectID: row.uuid("project_id"), recurrence: Recurrence(rawValue: row.string("recurrence") ?? "none"),
            reminderMinutes: row.int("reminder_minutes"),
            startBehavior: row.string("start_behavior").flatMap(ScheduleBlock.StartBehavior.init) ?? .nothing,
            endBehavior: row.string("end_behavior").flatMap(ScheduleBlock.EndBehavior.init) ?? .nothing,
            endSpaceID: row.uuid("end_space_id"),
            missedPolicy: row.string("missed_policy").flatMap(ScheduleBlock.MissedPolicy.init) ?? .runIfStillInBlock,
            source: row.string("source").flatMap(ScheduleBlock.Source.init) ?? .atlas,
            externalEventID: row.string("external_event_id"), calendarID: row.string("calendar_id"),
            automationWorkflowID: row.uuid("automation_workflow_id"), notes: row.string("notes") ?? "",
            createdAt: row.date("created_at") ?? Date(), updatedAt: row.date("updated_at") ?? Date()
        )
    }

    // MARK: - Occurrences

    public func saveOccurrence(_ occurrence: BlockOccurrence) throws {
        try database.run(
            """
            INSERT INTO block_occurrence (block_id, starts_at, state, run_ids_json, updated_at) VALUES (?, ?, ?, ?, ?)
            ON CONFLICT(block_id, starts_at) DO UPDATE SET state = excluded.state, run_ids_json = excluded.run_ids_json,
                updated_at = excluded.updated_at;
            """,
            [.from(occurrence.blockID), .from(occurrence.start), .text(occurrence.state.rawValue),
             .text(ScheduleJSON.encode(occurrence.runIDs)), .from(occurrence.updatedAt)]
        )
    }

    public func occurrence(blockID: UUID, start: Date) throws -> BlockOccurrence? {
        try database.query("SELECT * FROM block_occurrence WHERE block_id = ? AND starts_at = ?;", [.from(blockID), .from(start)])
            .first.flatMap(Self.occurrence(from:))
    }

    public func occurrences(from: Date, to: Date) throws -> [BlockOccurrence] {
        try database.query("SELECT * FROM block_occurrence WHERE starts_at >= ? AND starts_at < ? ORDER BY starts_at;",
                           [.from(from), .from(to)]).compactMap(Self.occurrence(from:))
    }

    private static func occurrence(from row: SQLRow) -> BlockOccurrence? {
        guard let blockID = row.uuid("block_id"), let start = row.date("starts_at") else { return nil }
        return BlockOccurrence(blockID: blockID, start: start, state: row.string("state").flatMap(BlockOccurrence.State.init) ?? .upcoming,
                               runIDs: ScheduleJSON.decode([UUID].self, row.string("run_ids_json")) ?? [],
                               updatedAt: row.date("updated_at") ?? Date())
    }

    // MARK: - Focus sessions

    public func saveFocusSession(_ session: FocusSession) throws {
        try database.run(
            """
            INSERT INTO focus_session (id, block_id, title, planned_seconds, extended_seconds, started_at, ended_at, pauses_json, space_id, state)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET block_id = excluded.block_id, title = excluded.title,
                planned_seconds = excluded.planned_seconds, extended_seconds = excluded.extended_seconds,
                ended_at = excluded.ended_at, pauses_json = excluded.pauses_json, space_id = excluded.space_id, state = excluded.state;
            """,
            [.from(session.id), .from(session.blockID?.uuidString), .text(session.title), .real(session.plannedSeconds),
             .real(session.extendedSeconds), .from(session.startedAt), .from(session.endedAt),
             .text(ScheduleJSON.encode(session.pauses)), .from(session.spaceID?.uuidString), .text(session.state.rawValue)]
        )
    }

    public func focusSessions(since: Date, limit: Int = 200) throws -> [FocusSession] {
        try database.query("SELECT * FROM focus_session WHERE started_at >= ? ORDER BY started_at DESC LIMIT ?;", [.from(since), .from(limit)])
            .compactMap(Self.focusSession(from:))
    }

    public func activeFocusSession() throws -> FocusSession? {
        try database.query("SELECT * FROM focus_session WHERE state != 'ended' ORDER BY started_at DESC LIMIT 1;").first
            .flatMap(Self.focusSession(from:))
    }

    private static func focusSession(from row: SQLRow) -> FocusSession? {
        guard let id = row.uuid("id"), let started = row.date("started_at") else { return nil }
        return FocusSession(id: id, blockID: row.uuid("block_id"), title: row.string("title") ?? "Focus",
                            plannedSeconds: row.double("planned_seconds") ?? 0, extendedSeconds: row.double("extended_seconds") ?? 0,
                            startedAt: started, endedAt: row.date("ended_at"),
                            pauses: ScheduleJSON.decode([FocusSession.Pause].self, row.string("pauses_json")) ?? [],
                            spaceID: row.uuid("space_id"), state: row.string("state").flatMap(FocusSession.State.init) ?? .ended)
    }

    // MARK: - Calendar links

    public func saveCalendarLink(_ link: CalendarLink) throws {
        try database.run(
            """
            INSERT INTO calendar_link (id, kind, calendar_id, event_id, title_contains, space_id, profile_id, minutes_before, block_id, note, created_at, undone_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET calendar_id = excluded.calendar_id, event_id = excluded.event_id,
                title_contains = excluded.title_contains, space_id = excluded.space_id, profile_id = excluded.profile_id,
                minutes_before = excluded.minutes_before, block_id = excluded.block_id, note = excluded.note, undone_at = excluded.undone_at;
            """,
            [.from(link.id), .text(link.kind.rawValue), .from(link.calendarID), .from(link.eventID), .from(link.titleContains),
             .from(link.spaceID?.uuidString), .from(link.profileID?.uuidString), .from(link.minutesBefore),
             .from(link.blockID?.uuidString), .text(link.note), .from(link.createdAt), .from(link.undoneAt)]
        )
    }

    public func calendarLinks(kind: CalendarLink.Kind? = nil) throws -> [CalendarLink] {
        let rows = if let kind {
            try database.query("SELECT * FROM calendar_link WHERE kind = ? ORDER BY created_at DESC;", [.text(kind.rawValue)])
        } else {
            try database.query("SELECT * FROM calendar_link ORDER BY created_at DESC;")
        }
        return rows.compactMap { row in
            guard let id = row.uuid("id"), let kind = row.string("kind").flatMap(CalendarLink.Kind.init) else { return nil }
            return CalendarLink(id: id, kind: kind, calendarID: row.string("calendar_id"), eventID: row.string("event_id"),
                                titleContains: row.string("title_contains"), spaceID: row.uuid("space_id"),
                                profileID: row.uuid("profile_id"), minutesBefore: row.int("minutes_before") ?? 15,
                                blockID: row.uuid("block_id"), note: row.string("note") ?? "",
                                createdAt: row.date("created_at") ?? Date(), undoneAt: row.date("undone_at"))
        }
    }

    public func deleteCalendarLink(id: UUID) throws {
        try database.run("DELETE FROM calendar_link WHERE id = ?;", [.from(id)])
    }

    // MARK: - Recommendation log

    public func logRecommendation(_ recommendation: Recommendation, at date: Date = Date()) throws {
        try database.run(
            "INSERT INTO suggestion_log (id, kind, title, reason, confidence, state, action_json, created_at) VALUES (?, ?, ?, ?, ?, 'shown', ?, ?);",
            [.from(recommendation.id), .text(recommendation.kind.rawValue), .text(recommendation.title), .text(recommendation.reason),
             .real(recommendation.confidence), .text(ScheduleJSON.encode(recommendation.action)), .from(date)]
        )
    }

    public func resolveRecommendation(id: UUID, state: RecommendationLogEntry.State, at date: Date = Date()) throws {
        try database.run("UPDATE suggestion_log SET state = ?, resolved_at = ? WHERE id = ?;", [.text(state.rawValue), .from(date), .from(id)])
    }

    public func recommendationLog(limit: Int = 200) throws -> [RecommendationLogEntry] {
        try database.query("SELECT * FROM suggestion_log ORDER BY created_at DESC LIMIT ?;", [.from(limit)]).compactMap { row in
            guard let id = row.uuid("id"), let kind = row.string("kind").flatMap(Recommendation.Kind.init) else { return nil }
            return RecommendationLogEntry(id: id, kind: kind, title: row.string("title") ?? "", reason: row.string("reason") ?? "",
                                          confidence: row.double("confidence") ?? 0.5,
                                          state: row.string("state").flatMap(RecommendationLogEntry.State.init) ?? .shown,
                                          createdAt: row.date("created_at") ?? Date(), resolvedAt: row.date("resolved_at"))
        }
    }

    // MARK: - Generated workflow drafts

    public func saveDraft(_ draft: GeneratedDraft) throws {
        try database.run(
            """
            INSERT INTO generated_workflow_draft (id, workflow_id, prompt, summary, assumptions_json, source, state, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET summary = excluded.summary, assumptions_json = excluded.assumptions_json, state = excluded.state;
            """,
            [.from(draft.id), .from(draft.workflowID), .text(draft.prompt), .text(draft.summary),
             .text(ScheduleJSON.encode(draft.assumptions)), .text(draft.source.rawValue), .text(draft.state.rawValue), .from(draft.createdAt)]
        )
    }

    public func draft(workflowID: UUID) throws -> GeneratedDraft? {
        try database.query("SELECT * FROM generated_workflow_draft WHERE workflow_id = ? ORDER BY created_at DESC LIMIT 1;", [.from(workflowID)])
            .first.flatMap { row in
                guard let id = row.uuid("id"), let workflowID = row.uuid("workflow_id") else { return nil }
                return GeneratedDraft(id: id, workflowID: workflowID, prompt: row.string("prompt") ?? "", summary: row.string("summary") ?? "",
                                      assumptions: ScheduleJSON.decode([String].self, row.string("assumptions_json")) ?? [],
                                      source: row.string("source").flatMap(GeneratedDraft.Source.init) ?? .rules,
                                      state: row.string("state").flatMap(GeneratedDraft.State.init) ?? .draft,
                                      createdAt: row.date("created_at") ?? Date())
            }
    }
}

enum ScheduleJSON {
    static func encode<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(value)).flatMap { String(data: $0, encoding: .utf8) } ?? "null"
    }

    static func decode<T: Decodable>(_ type: T.Type, _ text: String?) -> T? {
        guard let data = text?.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}
