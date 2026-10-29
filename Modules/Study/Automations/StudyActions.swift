import AtlasCore
import AtlasSpaces
import Foundation

/// What the study actions need, held weakly so actions don't keep the module alive.
final class StudyActionContext: @unchecked Sendable {
    weak var service: StudyService?
    weak var sessions: StudySessions?
    weak var assignments: AssignmentService?
    weak var automations: StudyAutomations?
    weak var windows: WindowService?

    /// Puts an app's windows in a preset position. Returns a problem to
    /// report, or "" (Accessibility missing doesn't fail the profile).
    func arrange(_ bundleID: String, _ preset: WindowPreset) async -> String {
        guard let windows else { return "" }
        do {
            _ = try await windows.arrange(bundleID: bundleID, preset: preset, display: .main)
            return ""
        } catch {
            return "couldn't arrange the windows: \(error.localizedDescription)"
        }
    }

    func require() throws -> (StudyService, StudySessions, AssignmentService) {
        guard let service, let sessions, let assignments else { throw ActionError.failed("The Study Library isn't available right now.") }
        return (service, sessions, assignments)
    }

    /// Asks the Companion to offer running `action`.
    /// `urgent` offers (a class about to start) don't wait for a study break.
    func offer(_ message: String, button: String, action: ActionID, parameters: ActionParameters, events: EventBus, urgent: Bool = false) {
        var payload: ActionParameters = ["message": .string(message), "button": .string(button), "actionId": .string(action.rawValue),
                                         "urgent": .bool(urgent)]
        for (key, value) in parameters { payload["param.\(key)"] = value }
        events.publish(AtlasEvent(AtlasEvent.Name.companionOffer, payload: payload))
    }
}

/// `study.classSoon`: a calendar event is about to start. If it's one of
/// your classes, the Companion offers to open its book.
struct ClassSoonAction: AtlasAction {
    static let id: ActionID = "study.classSoon"
    let context: StudyActionContext
    let descriptor = ActionDescriptor(
        id: ClassSoonAction.id, title: "Offer a Class's Book",
        summary: "If the event is one of your classes, the Companion offers to open its book (folder, notes, site).",
        category: "Study", symbolName: "book.closed",
        parameters: [
            ParameterSpec(key: "title", label: "Event title", kind: .text, help: "From the trigger: {{trigger.title}}"),
            ParameterSpec(key: "eventId", label: "Event ID", kind: .text, isRequired: false, help: "From the trigger: {{trigger.eventId}}"),
        ],
        isIdempotent: true, defaultTimeout: 10
    )

    func perform(_ parameters: ActionParameters, context actionContext: ActionContext) async throws -> ActionOutput {
        let (service, _, _) = try context.require()
        let title = try parameters.requiredString("title")
        guard let course = service.courses().first(where: { $0.matches(title) }) else {
            return ActionOutput("“\(title)” isn't one of your classes")
        }
        let start = parameters.optionalString("eventId").flatMap { id in
            service.classes(of: course, in: DateInterval(start: service.now(), duration: 4 * 3600)).first { $0.id == id }?.start
        }
        let when = start.map { " starts at \($0.formatted(date: .omitted, time: .shortened))" } ?? " starts soon"
        // A class about to start doesn't wait for a study break.
        let soon = start.map { $0.timeIntervalSince(service.now()) <= 20 * 60 } ?? true
        context.offer("\(course.displayCode)\(when) — open its book?", button: "Open", action: OpenCourseAction.id,
                      parameters: ["course": .string(course.id.uuidString)], events: actionContext.events, urgent: soon)
        return ActionOutput("Offered \(course.displayCode)'s book", values: ["course": .string(course.code)])
    }
}

/// `study.weekAhead`: "Your week: 6 assignments, 1 exam." Clicking it opens
/// the Study Library's chalkboard panel.
struct WeekAheadAction: AtlasAction {
    static let id: ActionID = "study.weekAhead"
    let context: StudyActionContext
    let descriptor = ActionDescriptor(
        id: WeekAheadAction.id, title: "Week Ahead",
        summary: "A notification with what's due in the next 7 days; clicking it opens the chalkboard.",
        category: "Study", symbolName: "calendar.badge.clock",
        sideEffects: [.showsUI], isIdempotent: false, defaultTimeout: 15
    )

    func perform(_ parameters: ActionParameters, context actionContext: ActionContext) async throws -> ActionOutput {
        let (_, _, assignments) = try context.require()
        await assignments.sync()
        let week = assignments.upcoming(days: 7)
        let exams = week.filter { $0.kind == .exam }.count
        let work = week.count - exams
        let body: String
        if week.isEmpty {
            body = "Nothing due this week."
        } else {
            var parts: [String] = []
            if work > 0 { parts.append("\(work) assignment\(work == 1 ? "" : "s")") }
            if exams > 0 { parts.append("\(exams) exam\(exams == 1 ? "" : "s")") }
            body = "Your week: \(parts.joined(separator: ", "))."
        }
        try await actionContext.system.postNotification(title: "Week ahead", body: body, link: "atlas://study/board")
        return ActionOutput(body, values: ["assignments": .number(Double(work)), "exams": .number(Double(exams))])
    }
}

/// `study.syncExamMode`: with an exam within 3 days, the Study Library's
/// default profile becomes "Exam cram"; after it, the usual one returns.
struct SyncExamModeAction: AtlasAction {
    static let id: ActionID = "study.syncExamMode"
    let context: StudyActionContext
    let descriptor = ActionDescriptor(
        id: SyncExamModeAction.id, title: "Exam Mode",
        summary: "Switches the Study Library to the Exam cram profile when an exam is within 3 days, and back after.",
        category: "Study", symbolName: "graduationcap",
        isIdempotent: true, defaultTimeout: 15
    )

    func perform(_ parameters: ActionParameters, context actionContext: ActionContext) async throws -> ActionOutput {
        guard let automations = context.automations else { throw ActionError.failed("The Study Library isn't available right now.") }
        return ActionOutput(try automations.syncExamMode())
    }
}

/// `study.openExamKit`: the Exam cram profile's step. Flashcards, the
/// exam course's practice tests and its notes.
struct OpenExamKitAction: AtlasAction {
    static let id: ActionID = "study.openExamKit"
    let context: StudyActionContext
    let descriptor = ActionDescriptor(
        id: OpenExamKitAction.id, title: "Open Exam Kit",
        summary: "Opens your flashcards (Anki or Quizlet), the exam course's practice tests and its notes.",
        category: "Study", symbolName: "rectangle.on.rectangle.angled",
        sideEffects: [.opensURL, .showsUI], isIdempotent: false, defaultTimeout: 30
    )

    func perform(_ parameters: ActionParameters, context actionContext: ActionContext) async throws -> ActionOutput {
        let (service, _, assignments) = try context.require()
        var opened: [String] = []
        let flashcards = service.settings.flashcards
        if flashcards.hasPrefix("http"), let url = URL(string: flashcards) {
            try await actionContext.system.open(url: url, withApplication: nil)
            opened.append("flashcards")
        } else if !flashcards.isEmpty {
            _ = try await actionContext.system.launchApplication(bundleID: flashcards, activate: true)
            opened.append("flashcards")
        }
        let exam = assignments.upcomingExam(within: 3) ?? assignments.nextDeadline()
        if let course = exam?.courseID.flatMap({ service.course(id: $0) }) {
            if let folder = service.resolvedFolder(of: course) {
                let expanded = (folder as NSString).expandingTildeInPath
                let practice = (expanded as NSString).appendingPathComponent(service.settings.practiceFolderName)
                let target = actionContext.system.fileKind(atPath: practice) == .directory ? practice : expanded
                try await actionContext.system.openFile(atPath: target, withApplication: "com.apple.finder")
                opened.append(target == practice ? "practice tests" : "course folder")
            }
            if (try? await OpenCourseAction.openNotes(course.notes, context: actionContext)) == true {
                opened.append("\(course.displayCode) notes")
            }
        }
        return ActionOutput(opened.isEmpty ? "Nothing to open yet" : "Opened \(opened.joined(separator: ", "))")
    }
}

/// `study.morningCheck`: the first time you open the Study Library each
/// study day, the Companion says what's due today and offers a session.
struct MorningCheckAction: AtlasAction {
    static let id: ActionID = "study.morningCheck"
    let context: StudyActionContext
    let descriptor = ActionDescriptor(
        id: MorningCheckAction.id, title: "Morning Check",
        summary: "Once a day, says what's due today and offers to start a study session on it.",
        category: "Study", symbolName: "sun.max",
        parameters: [ParameterSpec(key: "space", label: "Space ID", kind: .text, isRequired: false, help: "From the trigger: {{trigger.spaceId}}")],
        isIdempotent: true, defaultTimeout: 15
    )

    func perform(_ parameters: ActionParameters, context actionContext: ActionContext) async throws -> ActionOutput {
        let (service, _, assignments) = try context.require()
        if let id = parameters.optionalString("space").flatMap(UUID.init(uuidString:)),
           (try? service.store.space(id: id))??.templateID != StudyLibrary.templateID {
            return ActionOutput("Not the Study Library")
        }
        let day = service.settings.studyDay.start(of: service.now())
        let key = "study.morningCheck.last"
        if let last = try? service.store.preference(key, as: Date.self), last >= day { return ActionOutput("Already checked today") }
        try? service.store.setPreference(day, for: key)
        let today = assignments.upcoming(days: 0)
        guard let first = today.first else { return ActionOutput("Nothing due today") }
        let names = today.prefix(3).map(\.title).joined(separator: ", ")
        context.offer("Due today: \(names). Start a session on \(first.title)?", button: "Start", action: StartStudySessionAction.id,
                      parameters: first.courseID.map { ["course": .string($0.uuidString)] } ?? [:], events: actionContext.events)
        return ActionOutput("Due today: \(names)")
    }
}

/// `study.startSession`: starts a study session (the hourglass) from a workflow or an offer.
struct StartStudySessionAction: AtlasAction {
    static let id: ActionID = "study.startSession"
    let context: StudyActionContext
    let descriptor = ActionDescriptor(
        id: StartStudySessionAction.id, title: "Start Study Session",
        summary: "Turns the Study Library's hourglass: a study session on the focus timer, with pomodoro if it's on.",
        category: "Study", symbolName: "hourglass",
        parameters: [
            ParameterSpec(key: "minutes", label: "Minutes", kind: .number, isRequired: false, minimum: 1, maximum: 600),
            ParameterSpec(key: "course", label: "Course", kind: .text, isRequired: false),
        ],
        isIdempotent: false, defaultTimeout: 5
    )

    func perform(_ parameters: ActionParameters, context actionContext: ActionContext) async throws -> ActionOutput {
        let (service, sessions, _) = try context.require()
        let course = parameters.optionalString("course").flatMap { service.course(reference: $0) }
        let session = try sessions.start(minutes: parameters["minutes"]?.numberValue, courseID: course?.id)
        _ = session
        return ActionOutput("Studying\(course.map { " \($0.displayCode)" } ?? "")")
    }
}
