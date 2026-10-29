import AtlasCore
import AtlasOrbit
import AtlasSpaces
import Foundation

/// The Study Library's automations. Every one is an ordinary Flow workflow
/// (or Orbit rule) you can see, edit, switch off or delete; this only
/// creates them once and keeps the course-specific ones in step with your
/// courses.
public final class StudyAutomations: @unchecked Sendable {
    public enum Kind: String, CaseIterable, Codable, Sendable {
        case classSoon, weekAhead, examMode, morningCheck

        public var title: String {
            switch self {
            case .classSoon: return "Class soon"
            case .weekAhead: return "Week ahead"
            case .examMode: return "Exam mode"
            case .morningCheck: return "Morning check"
            }
        }

        public var summary: String {
            switch self {
            case .classSoon: return "Before a class starts, the Companion offers to open its book."
            case .weekAhead: return "Sunday evening: what's due this week. Click it for the chalkboard."
            case .examMode: return "With an exam within 3 days, the Study Library switches to Exam cram, and back after."
            case .morningCheck: return "The first time you open the Study Library each day, the Companion says what's due today."
            }
        }
    }

    static let installedKey = "study.automations"
    static let examProfileName = "Exam cram"
    static let rulePrefix = "study.coursePDF."

    let core: AtlasCore
    let service: StudyService
    let assignments: AssignmentService
    let library: SpaceLibrary
    let organizer: FileOrganizer
    var store: AtlasStore { core.store }

    init(core: AtlasCore, service: StudyService, assignments: AssignmentService) {
        self.core = core
        self.service = service
        self.assignments = assignments
        library = SpaceLibrary(core: core)
        organizer = FileOrganizer(core: core)
    }

    // MARK: - Workflows

    /// The workflow IDs created so far, by kind.
    var installed: [Kind: UUID] {
        get {
            let raw = (try? store.preference(Self.installedKey, as: [String: UUID].self)) ?? [:]
            return Dictionary(uniqueKeysWithValues: raw.compactMap { key, id in Kind(rawValue: key).map { ($0, id) } })
        }
        set { try? store.setPreference(Dictionary(uniqueKeysWithValues: newValue.map { ($0.key.rawValue, $0.value) }), for: Self.installedKey) }
    }

    /// Creates the automations that don't exist yet (once each: one you
    /// deleted stays deleted), the Exam cram profiles and the PDF rules.
    public func install() throws {
        var ids = installed
        for kind in Kind.allCases where ids[kind] == nil {
            ids[kind] = try core.save(Self.workflow(kind)).id
        }
        installed = ids
        if service.settings.flashcards == StudySettings().flashcards, core.system.applicationName(for: "net.ankiweb.dtop") != nil {
            var settings = service.settings
            settings.flashcards = "net.ankiweb.dtop"
            service.settings = settings
        }
        try addExamProfiles()
        try syncCourseRules()
    }

    public func workflow(_ kind: Kind) -> Workflow? {
        installed[kind].flatMap { try? store.workflow(id: $0) }
    }

    public func setEnabled(_ enabled: Bool, _ kind: Kind) throws {
        guard var workflow = workflow(kind) else { return }
        workflow.isEnabled = enabled
        _ = try core.save(workflow)
    }

    /// The minutes before class for "Class soon".
    public var classSoonMinutes: Int {
        get { triggerParameter(.classSoon, "minutesBefore")?.numberValue.map(Int.init) ?? 10 }
        set { setTriggerParameter(.classSoon, "minutesBefore", .number(Double(newValue))) }
    }

    /// "19:00" on Sundays, for "Week ahead".
    public var weekAheadTime: String {
        get { triggerParameter(.weekAhead, "time")?.stringValue ?? "19:00" }
        set { setTriggerParameter(.weekAhead, "time", .string(newValue)) }
    }

    private func triggerParameter(_ kind: Kind, _ key: String) -> ActionValue? {
        workflow(kind)?.triggerNodes.first?.parameters[key]
    }

    private func setTriggerParameter(_ kind: Kind, _ key: String, _ value: ActionValue) {
        guard var workflow = workflow(kind), let index = workflow.steps.firstIndex(where: { $0.kind == .trigger }) else { return }
        workflow.steps[index].parameters[key] = value
        _ = try? core.save(workflow)
    }

    static func workflow(_ kind: Kind) -> Workflow {
        var steps: [WorkflowStep] = []
        var connections: [WorkflowConnection] = []
        func chain(_ triggers: [WorkflowStep], _ action: WorkflowStep) {
            var action = action
            action.position = NodePosition(x: 340, y: 0)
            steps.append(action)
            for (index, trigger) in triggers.enumerated() {
                var trigger = trigger
                trigger.position = NodePosition(x: 0, y: Double(index) * 160)
                steps.append(trigger)
                connections.append(WorkflowConnection(fromNode: trigger.id, toNode: action.id))
            }
        }
        switch kind {
        case .classSoon:
            chain([.trigger(TriggerCatalog.calendarEventApproaching, parameters: ["minutesBefore": 10])],
                  WorkflowStep(actionID: ClassSoonAction.id, parameters: ["title": "{{trigger.title}}", "eventId": "{{trigger.eventId}}"],
                               label: "Offer the class's book"))
        case .weekAhead:
            chain([.trigger(TriggerCatalog.timeReached, parameters: ["repeat": "weekly", "days": "sun", "time": "19:00", "ifMissed": "runOnWake"])],
                  WorkflowStep(actionID: WeekAheadAction.id, label: "Your week"))
        case .examMode:
            chain([.trigger(TriggerCatalog.timeReached, parameters: ["repeat": "daily", "time": "06:00", "ifMissed": "runOnWake"]),
                   .trigger(TriggerCatalog.spaceActivated)],
                  WorkflowStep(actionID: SyncExamModeAction.id, label: "Exam cram within 3 days"))
        case .morningCheck:
            chain([.trigger(TriggerCatalog.spaceActivated)],
                  WorkflowStep(actionID: MorningCheckAction.id, parameters: ["space": "{{trigger.spaceId}}"], label: "What's due today"))
        }
        return Workflow(name: "Study · \(kind.title)", summary: kind.summary, isEnabled: kind != .morningCheck,
                        failurePolicy: .continueOnFailure, steps: steps, connections: connections)
    }

    // MARK: - Exam mode

    /// The Study Library's ready-made profiles, each a one-step workflow
    /// you can edit. None of them hides or quits anything.
    static let profiles: [(name: String, summary: String, action: ActionID, label: String)] = [
        (examProfileName, "Flashcards, the exam course's practice tests and its notes.", OpenExamKitAction.id, "Open the exam kit"),
        ("Default", "The course of the moment (from your calendar) and a lo-fi playlist.", OpenDefaultStudyAction.id,
         "Course of the moment + lo-fi"),
        ("Reading", "The course's newest PDF on the left half, its notes on the right.", OpenReadingAction.id, "PDF left, notes right"),
        ("Problem set", "The next assignment's PDF, the course's notes and a calculator.", OpenProblemSetAction.id,
         "Assignment PDF, notes, calculator"),
    ]

    /// Adds each ready-made profile a Study Library doesn't have yet (once
    /// each: one you deleted stays deleted).
    func addExamProfiles() throws {
        for space in try store.spaces() where space.templateID == StudyLibrary.templateID {
            let existing = try store.profiles(spaceID: space.id)
            let key = "study.profiles.added.\(space.id.uuidString)"
            var added = Set((try? store.preference(key, as: [String].self)) ?? [])
            // Exam cram predates this record.
            if existing.contains(where: { $0.name == Self.examProfileName }) { added.insert(Self.examProfileName) }
            for profile in Self.profiles where !added.contains(profile.name) && !existing.contains(where: { $0.name == profile.name }) {
                let workflow = try core.save(Workflow(
                    name: "\(space.name) · \(profile.name)", summary: profile.summary, failurePolicy: .continueOnFailure,
                    steps: [WorkflowStep(actionID: profile.action, label: profile.label)]
                ))
                try library.addProfile(to: space.id, name: profile.name, workflowID: workflow.id)
                added.insert(profile.name)
            }
            try store.setPreference(added.sorted(), for: key)
        }
    }

    /// With an exam within 3 days, Exam cram becomes the default profile
    /// (remembering the usual one); afterwards the usual one comes back.
    @discardableResult
    public func syncExamMode() throws -> String {
        let exam = assignments.upcomingExam(within: 3)
        var notes: [String] = []
        for space in try store.spaces() where space.templateID == StudyLibrary.templateID {
            let profiles = try store.profiles(spaceID: space.id)
            guard let cram = profiles.first(where: { $0.name == Self.examProfileName }) else { continue }
            let key = "study.examMode.previous.\(space.id.uuidString)"
            let current = profiles.first(where: \.isDefault)
            if exam != nil, current?.id != cram.id {
                try store.setPreference(current?.id, for: key)
                var promoted = cram
                promoted.isDefault = true
                try library.saveProfile(promoted)
                notes.append("\(space.name): Exam cram on")
            } else if exam == nil, current?.id == cram.id {
                let previousID = try store.preference(key, as: UUID.self)
                if var previous = profiles.first(where: { $0.id == previousID }) ?? profiles.first(where: { $0.id != cram.id }) {
                    previous.isDefault = true
                    try library.saveProfile(previous)
                    notes.append("\(space.name): back to \(previous.name)")
                }
                try store.setPreference(UUID?.none, for: key)
            }
        }
        if !notes.isEmpty { core.events.publish(AtlasEvent(AtlasEvent.Name.studyChanged)) }
        if let exam { return notes.isEmpty ? "Exam cram (\(exam.title))" : notes.joined(separator: "; ") }
        return notes.isEmpty ? "No exam within 3 days" : notes.joined(separator: "; ")
    }

    // MARK: - Course PDFs

    /// One pair of Orbit rules per course with a folder, on ~/Downloads: a
    /// PDF naming only this course moves to its "Downloads" folder by
    /// itself; one naming this and another course waits in the review
    /// queue. Rules of removed or folderless courses are deleted.
    public func syncCourseRules(watching folder: String = "~/Downloads") throws {
        let courses = service.courses()
        let existing = organizer.rules().filter { $0.starterID?.hasPrefix(Self.rulePrefix) == true }
        var wanted: [String: FileRule] = [:]
        for course in courses {
            guard let base = service.resolvedFolder(of: course) else { continue }
            let mine = Self.pattern(for: course)
            let others = courses.filter { $0.id != course.id }.map(Self.pattern(for:))
            let destination = ((base as NSString).abbreviatingWithTildeInPath as NSString).appendingPathComponent("Downloads")
            let clear = others.isEmpty ? mine : "^(?!.*(?:\(others.joined(separator: "|")))).*\(mine)"
            wanted[Self.rulePrefix + course.id.uuidString] = FileRule(
                name: "Course PDFs: \(course.displayCode)", isEnabled: true, mode: .automatic, folders: [folder],
                conditions: [.extensions("pdf"), .nameMatches(pattern: clear)], action: .moveTo(folder: destination),
                starterID: Self.rulePrefix + course.id.uuidString
            )
            if !others.isEmpty {
                wanted[Self.rulePrefix + course.id.uuidString + ".shared"] = FileRule(
                    name: "Course PDFs: \(course.displayCode) (or another course)", isEnabled: true, mode: .askFirst, folders: [folder],
                    conditions: [.extensions("pdf"), .nameMatches(pattern: "(?=.*\(mine))(?=.*(?:\(others.joined(separator: "|"))))")],
                    action: .moveTo(folder: destination), starterID: Self.rulePrefix + course.id.uuidString + ".shared"
                )
            }
        }
        for rule in existing where wanted[rule.starterID ?? ""] == nil {
            try organizer.delete(rule)
        }
        for (starter, var rule) in wanted {
            if let current = existing.first(where: { $0.starterID == starter }) {
                // Keep its identity and your on/off choice; update what it matches.
                rule.id = current.id
                rule.workflowID = current.workflowID
                rule.isEnabled = current.isEnabled
                rule.createdAt = current.createdAt
                guard rule.conditions != current.conditions || rule.action != current.action || rule.name != current.name else { continue }
            }
            try organizer.save(rule)
        }
    }

    /// A course code in any spelling, e.g. `(?<![A-Za-z0-9])CHEM[ _.-]?101(?![0-9])`, plus aliases.
    static func pattern(for course: Course) -> String {
        let codes = ([course.code] + course.aliases).compactMap(CourseCode.parse)
        let alternatives = codes.map { "\(NSRegularExpression.escapedPattern(for: $0.subject))[ _.-]?\(NSRegularExpression.escapedPattern(for: $0.number))" }
        return "(?<![A-Za-z0-9])(?:\(alternatives.joined(separator: "|")))(?![0-9])"
    }
}
