import AtlasCore
import Foundation

/// The Creative Studio's file rules, as ordinary Flow workflows you can
/// see, edit, switch off or delete: exports, screenshots, version saves,
/// and one "render done" per project with a render folder. Each is made
/// once (one you delete stays deleted); the render ones follow projects.
public final class CreativeRules: @unchecked Sendable {
    public enum Kind: String, CaseIterable, Codable, Sendable {
        case exports, screenshots, versions

        public var title: String {
            switch self {
            case .exports: return "Exports"
            case .screenshots: return "Screenshots"
            case .versions: return "Version save"
            }
        }

        public var summary: String {
            switch self {
            case .exports: return "While the Creative Studio is active, new exports in Downloads or on the Desktop go to the current project's Exports folder, renamed {project}-{date}-{counter}."
            case .screenshots: return "During a creative session, new screenshots go to the current project's References folder."
            case .versions: return "Leaving the Creative Studio saves a dated copy of the project's main file in Versions, keeping the newest 10."
            }
        }
    }

    static let installedKey = "creative.rules"
    static let rendersKey = "creative.rules.renders"
    /// What counts as an export.
    static let exportExtensions = "png, jpg, jpeg, svg, pdf, mp4, mov, gif, webp, heic"

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

    /// Render workflows by project.
    var renderWorkflows: [UUID: UUID] {
        get { (try? store.preference(Self.rendersKey, as: [UUID: UUID].self)) ?? [:] }
        set { try? store.setPreference(newValue, for: Self.rendersKey) }
    }

    public func workflow(_ kind: Kind) -> Workflow? {
        installed[kind].flatMap { try? store.workflow(id: $0) }
    }

    /// Makes the rules that don't exist yet, then the render ones.
    public func install() throws {
        var ids = installed
        for kind in Kind.allCases where ids[kind] == nil {
            ids[kind] = try core.save(workflow(for: kind)).id
        }
        installed = ids
        if service.settings.rulesInstalledAt == nil { service.settings.rulesInstalledAt = service.now() }
        try syncRenders()
    }

    public func setEnabled(_ enabled: Bool, _ kind: Kind) throws {
        guard var workflow = workflow(kind) else { return }
        workflow.isEnabled = enabled
        _ = try core.save(workflow)
    }

    /// One "render done" workflow per project with a render folder; ones
    /// for removed projects or folders are deleted.
    public func syncRenders() throws {
        var ids = renderWorkflows
        var wanted: [UUID: String] = [:]
        for project in service.projects() {
            if let folder = service.renderFolder(of: project) { wanted[project.id] = folder }
        }
        for (projectID, workflowID) in ids where wanted[projectID] == nil {
            if (try? store.workflow(id: workflowID)) != nil { try core.delete(workflowID: workflowID) }
            ids[projectID] = nil
        }
        for (projectID, folder) in wanted {
            let name = service.project(id: projectID)?.name ?? "Project"
            if let id = ids[projectID], var existing = try store.workflow(id: id) {
                // Follow a renamed project or render folder; keep your on/off choice.
                guard let trigger = existing.steps.firstIndex(where: { $0.kind == .trigger }),
                      existing.steps[trigger].parameters["folder"]?.stringValue != folder || existing.name != "Creative · Renders: \(name)"
                else { continue }
                existing.steps[trigger].parameters["folder"] = .string(folder)
                existing.name = "Creative · Renders: \(name)"
                _ = try core.save(existing)
            } else if ids[projectID] == nil {
                ids[projectID] = try core.save(Self.chain(
                    name: "Creative · Renders: \(name)", summary: "A notification when a render lands in \(folder.abbreviatedPath), and it goes on the easel.",
                    triggers: [.trigger(TriggerCatalog.fileCreated, parameters: ["folder": .string(folder)])],
                    action: WorkflowStep(actionID: RenderDoneAction.id, parameters: ["path": "{{trigger.path}}"], label: "Render done"),
                    enabled: true
                )).id
            }
        }
        renderWorkflows = ids
    }

    func workflow(for kind: Kind) -> Workflow {
        switch kind {
        case .exports:
            let triggers = ["~/Downloads", "~/Desktop"].map { folder in
                WorkflowStep.trigger(TriggerCatalog.fileCreated, parameters: ["folder": .string(folder), "extensions": .string(Self.exportExtensions)])
            }
            return Self.chain(name: "Creative · Exports", summary: kind.summary, triggers: triggers,
                              action: WorkflowStep(actionID: FileExportAction.id, parameters: ["path": "{{trigger.path}}"], label: "To the project's Exports"),
                              enabled: true)
        case .screenshots:
            return Self.chain(name: "Creative · Screenshots", summary: kind.summary,
                              triggers: [.trigger(TriggerCatalog.fileCreated, parameters: ["folder": .string(Self.screenshotFolder().abbreviatedPath),
                                                                                           "extensions": "png, jpg, heic, mov"])],
                              action: WorkflowStep(actionID: FileReferenceAction.id, parameters: ["path": "{{trigger.path}}"], label: "To References"),
                              enabled: true)
        case .versions:
            return Self.chain(name: "Creative · Version save", summary: kind.summary,
                              triggers: [.trigger(TriggerCatalog.spaceDeactivated)],
                              action: WorkflowStep(actionID: SaveVersionAction.id, parameters: ["space": "{{trigger.spaceId}}"], label: "Save a dated copy"),
                              enabled: false)
        }
    }

    /// Where macOS saves screenshots (Desktop unless changed in Screenshot.app).
    static func screenshotFolder() -> String {
        let saved = UserDefaults(suiteName: "com.apple.screencapture")?.string(forKey: "location")
        return saved.map { ($0 as NSString).expandingTildeInPath } ?? (NSHomeDirectory() as NSString).appendingPathComponent("Desktop")
    }

    static func chain(name: String, summary: String, triggers: [WorkflowStep], action: WorkflowStep, enabled: Bool) -> Workflow {
        var steps: [WorkflowStep] = []
        var connections: [WorkflowConnection] = []
        var action = action
        action.position = NodePosition(x: 340, y: 0)
        steps.append(action)
        for (index, trigger) in triggers.enumerated() {
            var trigger = trigger
            trigger.position = NodePosition(x: 0, y: Double(index) * 160)
            steps.append(trigger)
            connections.append(WorkflowConnection(fromNode: trigger.id, toNode: action.id))
        }
        return Workflow(name: name, summary: summary, isEnabled: enabled, failurePolicy: .continueOnFailure,
                        steps: steps, connections: connections,
                        settings: WorkflowSettings(reentrancy: .runInParallel, minimumInterval: 1, maxRunsPerMinute: 60, selfTriggerLimit: 3))
    }
}

extension CreativeService {
    /// Approved creative exports in a row (most recent first), from the review queue.
    func approvedExportsInARow() -> Int {
        let resolved = ((try? store.reviewItems(state: nil, limit: 500)) ?? [])
            .filter { $0.reason.hasPrefix(CreativeFileRules.exportReason) && $0.resolvedAt != nil }
            .sorted { ($0.resolvedAt ?? .distantPast) > ($1.resolvedAt ?? .distantPast) }
        return resolved.prefix { $0.state == .approved }.count
    }

    /// After a week of asking, and 5 approvals in a row: offer (once) to
    /// move exports automatically from now on.
    func offerAutomaticExportsIfEarned() {
        let settings = self.settings
        guard settings.exportMode == .askFirst, !settings.offeredAutomaticExports, let since = settings.rulesInstalledAt,
              now().timeIntervalSince(since) >= 7 * 86_400, approvedExportsInARow() >= 5 else { return }
        self.settings.offeredAutomaticExports = true
        core.events.publish(AtlasEvent(AtlasEvent.Name.companionOffer, payload: [
            "message": "Your last 5 exports all went to the right project. Move them automatically from now on?",
            "button": "Yes, automatically", "actionId": .string(SetExportModeAction.id.rawValue), "param.mode": "automatic",
        ]))
    }
}
