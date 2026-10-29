import AtlasCore
import AtlasSpaces
import Foundation

extension AtlasEvent.Name {
    /// More than one project is active today: ask which (the app shows the
    /// picker). Payload: projectIds (comma-separated), spaceId.
    public static let creativePickProject = "creative.pickProject"
}

/// The Creative Studio's automations, as ordinary Flow workflows you can
/// see, edit, switch off or delete. Made once each.
public final class CreativeAutomations: @unchecked Sendable {
    public enum Kind: String, CaseIterable, Codable, Sendable {
        case offerStudio, projectPicker, staleNudge, weeklyRecap

        public var title: String {
            switch self {
            case .offerStudio: return "Offer the studio"
            case .projectPicker: return "Project on entry"
            case .staleNudge: return "Stale project nudge"
            case .weeklyRecap: return "Weekly recap"
            }
        }

        public var summary: String {
            switch self {
            case .offerStudio: return "When Blender, Figma, Affinity or Photoshop opens outside the Creative Studio, the Companion offers to open it (at most once an hour)."
            case .projectPicker: return "Entering the Creative Studio opens the current project; with more than one active today, a quick picker first."
            case .staleNudge: return "A project in progress untouched for 14 days gets one gentle nudge."
            case .weeklyRecap: return "Sunday at 6 PM: hours per project, exports and the week's palette."
            }
        }
    }

    static let installedKey = "creative.automations"
    /// The apps that suggest it's time for the studio.
    static let creativeApps = ["org.blenderfoundation.blender", "com.figma.Desktop", "com.seriflabs.affinitydesigner2",
                               "com.seriflabs.affinityphoto2", "com.adobe.Photoshop", "com.adobe.illustrator"]

    let core: AtlasCore
    let service: CreativeService
    var store: AtlasStore { core.store }

    init(core: AtlasCore, service: CreativeService) {
        self.core = core
        self.service = service
    }

    var installed: [Kind: UUID] {
        get {
            let raw = (try? store.preference(Self.installedKey, as: [String: UUID].self)) ?? [:]
            return Dictionary(uniqueKeysWithValues: raw.compactMap { key, id in Kind(rawValue: key).map { ($0, id) } })
        }
        set { try? store.setPreference(Dictionary(uniqueKeysWithValues: newValue.map { ($0.key.rawValue, $0.value) }), for: Self.installedKey) }
    }

    public func workflow(_ kind: Kind) -> Workflow? {
        installed[kind].flatMap { try? store.workflow(id: $0) }
    }

    public func install() throws {
        var ids = installed
        for kind in Kind.allCases where ids[kind] == nil {
            ids[kind] = try core.save(Self.workflow(kind)).id
        }
        installed = ids
    }

    public func setEnabled(_ enabled: Bool, _ kind: Kind) throws {
        guard var workflow = workflow(kind) else { return }
        workflow.isEnabled = enabled
        _ = try core.save(workflow)
    }

    static func workflow(_ kind: Kind) -> Workflow {
        let name = "Creative · \(kind.title)"
        switch kind {
        case .offerStudio:
            return CreativeRules.chain(name: name, summary: kind.summary,
                                       triggers: creativeApps.map { .trigger(TriggerCatalog.appLaunched, parameters: ["app": .string($0)]) },
                                       action: WorkflowStep(actionID: OfferStudioAction.id, parameters: ["app": "{{trigger.bundleId}}"],
                                                            label: "Offer the Creative Studio"),
                                       enabled: true)
        case .projectPicker:
            return CreativeRules.chain(name: name, summary: kind.summary, triggers: [.trigger(TriggerCatalog.spaceActivated)],
                                       action: WorkflowStep(actionID: ProjectOnEntryAction.id, parameters: ["space": "{{trigger.spaceId}}"],
                                                            label: "Open the current project"),
                                       enabled: true)
        case .staleNudge:
            return CreativeRules.chain(name: name, summary: kind.summary,
                                       triggers: [.trigger(TriggerCatalog.timeReached, parameters: ["repeat": "daily", "time": "10:00", "ifMissed": "runOnWake"])],
                                       action: WorkflowStep(actionID: StaleNudgeAction.id, label: "Nudge a waiting project"),
                                       enabled: false)
        case .weeklyRecap:
            return CreativeRules.chain(name: name, summary: kind.summary,
                                       triggers: [.trigger(TriggerCatalog.timeReached, parameters: ["repeat": "weekly", "days": "sun", "time": "18:00",
                                                                                                    "ifMissed": "runOnWake"])],
                                       action: WorkflowStep(actionID: WeeklyRecapAction.id, label: "Your creative week"),
                                       enabled: true)
        }
    }
}

extension CreativeService {
    /// The Creative Studio Space, if there is one.
    var studioSpace: Space? {
        ((try? store.spaces()) ?? []).first { $0.templateID == CreativeLoft.templateID }
    }

    func offer(_ message: String, button: String, action: ActionID, parameters: ActionParameters = [:]) {
        var payload: ActionParameters = ["message": .string(message), "button": .string(button), "actionId": .string(action.rawValue)]
        for (key, value) in parameters { payload["param.\(key)"] = value }
        core.events.publish(AtlasEvent(AtlasEvent.Name.companionOffer, payload: payload))
    }

    /// Active projects whose files changed in the last 24 hours, newest first.
    public func recentlyActive() -> [Project] {
        let since = now().addingTimeInterval(-86_400)
        return projects().filter { $0.creative?.status != .done }
            .compactMap { project in lastChanged(project).map { (project, $0) } }
            .filter { $0.1 >= since }
            .sorted { $0.1 > $1.1 }
            .map(\.0)
    }

    /// Remembers the picker's choice for today (nil: just watching).
    public func pick(_ projectID: UUID?) {
        settings.pickedToday = CreativeSettings.PickedProject(day: settings.day.start(of: now()), projectID: projectID)
        if let projectID { noteOpened(projectID) }
    }

    /// Today's pick, if made.
    var pickToday: CreativeSettings.PickedProject? {
        guard let picked = settings.pickedToday, picked.day == settings.day.start(of: now()) else { return nil }
        return picked
    }
}

/// `creative.offerStudio`: a creative app opened outside the Creative Studio.
struct OfferStudioAction: AtlasAction {
    static let id: ActionID = "creative.offerStudio"
    static let lastKey = "creative.offerStudio.last"
    let ref = CreativeRef()

    let descriptor = ActionDescriptor(
        id: OfferStudioAction.id, title: "Offer the Creative Studio",
        summary: "The Companion offers to open the Creative Studio for the current project (at most once an hour, and not when you're already there).",
        category: "Creative", symbolName: "paintbrush",
        parameters: [ParameterSpec(key: "app", label: "App", kind: .text, isRequired: false, help: "From the trigger: {{trigger.bundleId}}")],
        isIdempotent: true, defaultTimeout: 10
    )

    init(service: CreativeService) { ref.service = service }

    func perform(_ parameters: ActionParameters, context: ActionContext) async throws -> ActionOutput {
        let service = try ref.require()
        guard !service.isStudioActive else { return ActionOutput("Already in the Creative Studio") }
        guard let space = service.studioSpace else { return ActionOutput("No Creative Studio") }
        if let last = try? service.store.preference(Self.lastKey, as: Date.self), service.now().timeIntervalSince(last) < 3600 {
            return ActionOutput("Offered less than an hour ago")
        }
        try? service.store.setPreference(service.now(), for: Self.lastKey)
        let app = parameters.optionalString("app").map(service.appName) ?? "That app"
        let project = service.currentProject()?.name
        service.offer("\(app) is open. Open the Creative Studio\(project.map { " for \($0)" } ?? "")?", button: "Open",
                      action: "space.activate", parameters: ["space": .string(space.id.uuidString)])
        return ActionOutput("Offered the Creative Studio")
    }
}

/// `creative.projectOnEntry`: entering the Creative Studio opens the
/// current project, or (more than one active today) asks which first.
struct ProjectOnEntryAction: AtlasAction {
    static let id: ActionID = "creative.projectOnEntry"
    let ref = CreativeRef()

    let descriptor = ActionDescriptor(
        id: ProjectOnEntryAction.id, title: "Open Project on Entry",
        summary: "Opens the current creative project; when more than one changed in the last 24 hours, shows a quick picker first (remembered for the day).",
        category: "Creative", symbolName: "rectangle.stack",
        parameters: [ParameterSpec(key: "space", label: "Space ID", kind: .text, isRequired: false, help: "From the trigger: {{trigger.spaceId}}")],
        sideEffects: [.opensURL, .showsUI, .launchesApplication], isIdempotent: false, defaultTimeout: 30
    )

    init(service: CreativeService) { ref.service = service }

    func perform(_ parameters: ActionParameters, context: ActionContext) async throws -> ActionOutput {
        let service = try ref.require()
        guard let id = parameters.optionalString("space").flatMap(UUID.init(uuidString:)),
              ((try? service.store.space(id: id)) ?? nil)?.templateID == CreativeLoft.templateID else {
            return ActionOutput("Not the Creative Studio")
        }
        if let picked = service.pickToday {
            guard let projectID = picked.projectID else { return ActionOutput("Just watching today") }
            return try await OpenCreativeProjectAction(service: service).perform(["project": .string(projectID.uuidString)], context: context)
        }
        let active = service.recentlyActive()
        if active.count > 1 {
            service.core.events.publish(AtlasEvent(AtlasEvent.Name.creativePickProject, payload: [
                "projectIds": .string(active.map(\.id.uuidString).joined(separator: ",")), "spaceId": .string(id.uuidString),
            ]))
            return ActionOutput("Asked which project: \(active.map(\.name).joined(separator: ", "))")
        }
        guard service.currentProject() != nil else { return ActionOutput("No project yet") }
        return try await OpenCreativeProjectAction(service: service).perform([:], context: context)
    }
}

/// `creative.staleNudge`: once per project, a gentle word about one that's
/// been waiting two weeks.
struct StaleNudgeAction: AtlasAction {
    static let id: ActionID = "creative.staleNudge"
    static let nudgedKey = "creative.nudged"
    let ref = CreativeRef()

    let descriptor = ActionDescriptor(
        id: StaleNudgeAction.id, title: "Nudge a Waiting Project",
        summary: "A project in progress untouched for 14 days: the Companion mentions it, once.",
        category: "Creative", symbolName: "hourglass.bottomhalf.filled",
        isIdempotent: true, defaultTimeout: 15
    )

    init(service: CreativeService) { ref.service = service }

    func perform(_ parameters: ActionParameters, context: ActionContext) async throws -> ActionOutput {
        let service = try ref.require()
        var nudged = Set((try? service.store.preference(Self.nudgedKey, as: [UUID].self)) ?? [])
        let cutoff = service.now().addingTimeInterval(-14 * 86_400)
        guard let project = service.projects().first(where: { project in
            project.creative?.status == .inProgress && !nudged.contains(project.id)
                && (service.lastChanged(project) ?? project.createdAt) < cutoff
        }) else { return ActionOutput("Nothing's been waiting") }
        nudged.insert(project.id)
        try? service.store.setPreference(Array(nudged), for: Self.nudgedKey)
        let weeks = Int(service.now().timeIntervalSince(service.lastChanged(project) ?? project.createdAt) / (7 * 86_400))
        service.offer("\(project.name) has been waiting \(weeks) weeks. Open it, or set it to Idea in Projects?", button: "Open it",
                      action: OpenCreativeProjectAction.id, parameters: ["project": .string(project.id.uuidString)])
        return ActionOutput("Nudged \(project.name)")
    }
}

/// `creative.weeklyRecap`: Sunday evening, your creative week.
struct WeeklyRecapAction: AtlasAction {
    static let id: ActionID = "creative.weeklyRecap"
    let ref = CreativeRef()

    let descriptor = ActionDescriptor(
        id: WeeklyRecapAction.id, title: "Creative Weekly Recap",
        summary: "A notification with this week's hours per project, exports and palette; clicking it opens the Stats panel.",
        category: "Creative", symbolName: "calendar.badge.clock",
        sideEffects: [.showsUI], isIdempotent: false, defaultTimeout: 15
    )

    init(service: CreativeService) { ref.service = service }

    func perform(_ parameters: ActionParameters, context: ActionContext) async throws -> ActionOutput {
        let service = try ref.require()
        let body = Self.recap(service: service)
        try await context.system.postNotification(title: "Your creative week", body: body, link: "atlas://creative/stats")
        return ActionOutput(body)
    }

    /// "Robot 4 h 10 m · Poster 1 h · 6 exports · palette #E8A6B4 #FFC4A8…"
    static func recap(service: CreativeService) -> String {
        let since = service.now().addingTimeInterval(-7 * 86_400)
        let sessions = ((try? service.store.creativeSessions(in: DateInterval(start: since, end: service.now().addingTimeInterval(1)))) ?? [])
            .filter { $0.kind == .create }
        guard !sessions.isEmpty else { return "A quiet week. The studio's ready when you are." }
        var seconds: [UUID?: TimeInterval] = [:]
        for session in sessions { seconds[session.projectID, default: 0] += session.focusedSeconds }
        let projects = seconds.sorted { $0.value > $1.value }.prefix(4).map { id, time in
            "\(id.flatMap { service.project(id: $0)?.name } ?? "No project") \(CreativeMath.duration(time))"
        }
        let exports = sessions.reduce(0) { $0 + $1.exports.count }
        var palette: [String] = []
        for color in sessions.flatMap(\.palette) where !palette.contains(color) && palette.count < 5 { palette.append(color) }
        var parts = projects
        parts.append("\(exports) export\(exports == 1 ? "" : "s")")
        if !palette.isEmpty { parts.append("palette " + palette.joined(separator: " ")) }
        return parts.joined(separator: " · ")
    }
}
