import AppKit
import AtlasCore
import SwiftUI

/// Editing state for one workflow graph. Every change goes through
/// `mutate`, which revalidates and registers with the window's undo
/// manager, so Edit ▸ Undo/Redo and ⌘Z work everywhere.
@MainActor
public final class FlowEditorModel: ObservableObject {
    public enum ViewMode: String, CaseIterable, Identifiable {
        case canvas, galaxy
        public var id: Self { self }
        public var title: String { self == .canvas ? "2D" : "3D Galaxy" }
        public var symbol: String { self == .canvas ? "rectangle.3.group" : "sparkles" }
    }

    @Published public private(set) var draft: Workflow
    @Published public private(set) var saved: Workflow
    @Published public var selection: Set<UUID> = []
    @Published public private(set) var issues: [ValidationIssue] = []
    @Published var transform = CanvasTransform()
    @Published public var snapToGrid = true
    @Published public var viewMode: ViewMode = .canvas
    /// Why the last connection attempt was refused, shown near the pointer.
    @Published var refusal: (message: String, at: CGPoint)?
    @Published public var message: String?

    public let core: AtlasCore
    public let live: LiveRunMonitor
    let templates: [NodeTemplate]
    weak var undoManager: UndoManager?
    /// The canvas's size, for centring on a node.
    var canvasSize: CGSize = .zero
    private var dragSnapshot: Workflow?
    private var eventTask: Task<Void, Never>?
    private let onSaved: (Workflow) -> Void

    public static let gridSize: CGFloat = 20

    public init(workflow: Workflow, core: AtlasCore, onSaved: @escaping (Workflow) -> Void = { _ in }) {
        var normalized = workflow
        Self.layoutIfNeeded(&normalized)
        if normalized.connections.isEmpty && normalized.steps.count > 1 { normalized.connections = normalized.effectiveConnections }
        self.draft = normalized
        self.saved = normalized
        self.core = core
        self.onSaved = onSaved
        self.templates = NodeTemplate.all(registry: core.registry)
        var connections: () -> [WorkflowConnection] = { [] }
        self.live = LiveRunMonitor(workflowID: workflow.id, events: core.events, store: core.store) { connections() }
        connections = { [weak self] in self?.draft.connections ?? [] }
        live.show(live.lastRun)
        revalidate()
        // Orbit folders changing, or a trigger failing to start, change
        // what's wrong with this workflow.
        let stream = core.events.stream()
        let id = workflow.id.uuidString
        eventTask = Task { [weak self] in
            for await event in stream {
                switch event.name {
                case AtlasEvent.Name.fileAccessChanged:
                    self?.revalidate()
                case AtlasEvent.Name.triggerFailed, AtlasEvent.Name.workflowSaved where event.payload["workflowId"]?.stringValue == id:
                    self?.revalidate()
                default:
                    continue
                }
            }
        }
    }

    deinit { eventTask?.cancel() }

    public var isDirty: Bool { draft != saved }
    public var registry: ActionRegistry { core.registry }

    // MARK: - Lookups

    func node(_ id: UUID) -> WorkflowStep? { draft.step(id: id) }

    func ports(for node: WorkflowStep) -> [NodePort] { NodePorts.ports(for: node, registry: registry) }

    func frame(of node: WorkflowStep) -> CGRect { NodeLayout.frame(node, ports: ports(for: node)) }

    func issues(for nodeID: UUID) -> [ValidationIssue] { issues.filter { $0.nodeID == nodeID } }

    func hasError(_ nodeID: UUID) -> Bool { issues.contains { $0.nodeID == nodeID && $0.severity == .error } }

    var errorCount: Int { issues.filter { $0.severity == .error }.count }

    func title(of node: WorkflowStep) -> String {
        WorkflowValidator.displayName(node, registry: registry).trimmingCharacters(in: CharacterSet(charactersIn: "“”"))
    }

    func symbol(of node: WorkflowStep) -> String {
        switch node.kind {
        case .trigger: return TriggerCatalog.type(id: node.config.triggerType ?? "")?.symbolName ?? "bolt"
        case .condition: return "questionmark.diamond"
        case .action: return registry.descriptor(for: node.actionID)?.symbolName ?? "app"
        case .control: return node.config.control?.symbolName ?? "gearshape"
        }
    }

    /// One line under the title, e.g. "~/Downloads" or "Extension is pdf".
    func subtitle(of node: WorkflowStep) -> String {
        switch node.kind {
        case .trigger:
            return TriggerCatalog.type(id: node.config.triggerType ?? "")?.parameters.lazy
                .compactMap { node.parameters[$0.key] }.first { !$0.isEmpty }?.displayString ?? "Any"
        case .condition:
            let items = node.config.condition?.items ?? []
            guard let first = items.first else { return "No checks" }
            return items.count == 1 ? first.check.summary : "\(first.check.summary) +\(items.count - 1)"
        case .action:
            return registry.descriptor(for: node.actionID)?.parameters.lazy
                .compactMap { node.parameters[$0.key] }.first { !$0.isEmpty }?.displayString ?? ""
        case .control:
            switch node.config.control {
            case .delay: return node.config.delayUntil.map { "Until \($0)" } ?? "\(node.parameters["seconds"]?.displayString ?? "?") s"
            case .loop: return node.config.loopMode == .repeatCount ? "\(node.parameters["count"]?.displayString ?? "?") times" : "For each item"
            case .switchValue: return (node.config.cases ?? []).joined(separator: " · ")
            case .subworkflow: return node.config.workflowID.flatMap { id in (try? core.store.workflow(id: id))??.name } ?? "Choose an automation"
            case .setVariable, .getVariable: return node.config.variableName ?? ""
            default: return ""
            }
        }
    }

    // MARK: - Changes

    func mutate(_ name: String, _ change: (inout Workflow) -> Void) {
        let before = draft
        change(&draft)
        guard draft != before else { return }
        registerUndo(restoring: before, name: name)
        revalidate()
    }

    private func registerUndo(restoring snapshot: Workflow, name: String) {
        undoManager?.registerUndo(withTarget: self) { model in
            let current = model.draft
            model.draft = snapshot
            model.selection = model.selection.filter { id in snapshot.steps.contains { $0.id == id } }
            model.revalidate()
            model.registerUndo(restoring: current, name: name)
        }
        undoManager?.setActionName(name)
    }

    func revalidate() {
        var found = core.validate(draft)
        // A trigger that's on but couldn't start says why (unless a folder
        // problem on it already does).
        if saved.isEnabled, let triggers = core.triggers {
            for node in draft.triggerNodes where !found.contains(where: { $0.nodeID == node.id && $0.folderToAdd != nil }) {
                if let problem = triggers.problem(for: node.id) { found.append(ValidationIssue(.warning, problem, node: node.id)) }
            }
        }
        issues = found
    }

    /// "Add Downloads to Orbit": the app opens the folder picker there.
    func addFolderToOrbit(_ folder: String) {
        NotificationCenter.default.post(name: .atlasAddFolderToOrbit, object: folder)
    }

    public func updateNode(_ id: UUID, _ name: String = "Edit Step", _ change: (inout WorkflowStep) -> Void) {
        mutate(name) { workflow in
            guard let index = workflow.steps.firstIndex(where: { $0.id == id }) else { return }
            change(&workflow.steps[index])
            // Ports may have changed (e.g. a new action): drop connections to ports that are gone.
            let node = workflow.steps[index]
            let portIDs = Set(NodePorts.ports(for: node, registry: registry).map(\.id))
            workflow.connections.removeAll {
                ($0.fromNode == id && !portIDs.contains($0.fromPort)) || ($0.toNode == id && !portIDs.contains($0.toPort))
            }
        }
    }

    public func updateWorkflow(_ name: String = "Edit Automation", _ change: (inout Workflow) -> Void) {
        mutate(name, change)
    }

    // MARK: Nodes

    @discardableResult
    func add(_ template: NodeTemplate, at point: CGPoint? = nil) -> UUID {
        var node = template.make()
        let target = point ?? nextFreeSpot()
        node.position = NodePosition(x: snap(target.x), y: snap(target.y), z: Double.random(in: -1...1))
        let added = node
        mutate("Add \(template.title)") { workflow in
            workflow.steps.append(added)
            // Added with one node selected: connect after it.
            if self.selection.count == 1, let previous = self.selection.first, let from = workflow.step(id: previous),
               let out = NodePorts.controlOutputs(of: from, registry: self.registry).first,
               added.kind != .trigger,
               !workflow.connections.contains(where: { $0.fromNode == previous && $0.fromPort == out }) {
                workflow.connections.append(WorkflowConnection(fromNode: previous, fromPort: out, toNode: added.id))
            }
        }
        selection = [node.id]
        return node.id
    }

    func add(templateID: String, at point: CGPoint) -> Bool {
        guard let template = templates.first(where: { $0.id == templateID }) else { return false }
        add(template, at: point)
        return true
    }

    private func nextFreeSpot() -> CGPoint {
        if let selected = selection.first.flatMap(node) {
            return CGPoint(x: selected.position.x + 280, y: selected.position.y)
        }
        let maxX = draft.steps.map(\.position.x).max() ?? -280
        return CGPoint(x: maxX + 280, y: draft.steps.last?.position.y ?? 0)
    }

    func deleteSelection() {
        guard !selection.isEmpty else { return }
        let doomed = selection
        mutate(doomed.count == 1 ? "Delete Step" : "Delete Steps") { workflow in
            workflow.steps.removeAll { doomed.contains($0.id) }
            workflow.connections.removeAll { doomed.contains($0.fromNode) || doomed.contains($0.toNode) }
            for index in workflow.settings.groups.indices {
                workflow.settings.groups[index].nodeIDs.removeAll { doomed.contains($0) }
            }
            workflow.settings.groups.removeAll { $0.nodeIDs.isEmpty }
        }
        selection = []
    }

    func duplicateSelection() {
        guard let pasted = insert(Clipboard(workflow: draft, nodeIDs: selection), offset: 40, name: "Duplicate") else { return }
        selection = pasted
    }

    func selectAll() { selection = Set(draft.steps.map(\.id)) }

    // MARK: Moving

    func beginMove() {
        if dragSnapshot == nil { dragSnapshot = draft }
    }

    func moveSelection(by delta: CGSize) {
        let moving = selection
        for index in draft.steps.indices where moving.contains(draft.steps[index].id) {
            draft.steps[index].position.x += delta.width
            draft.steps[index].position.y += delta.height
        }
    }

    func endMove() {
        guard let snapshot = dragSnapshot else { return }
        dragSnapshot = nil
        if snapToGrid {
            for index in draft.steps.indices where selection.contains(draft.steps[index].id) {
                draft.steps[index].position.x = snap(draft.steps[index].position.x)
                draft.steps[index].position.y = snap(draft.steps[index].position.y)
            }
        }
        if draft != snapshot { registerUndo(restoring: snapshot, name: "Move") }
    }

    private func snap(_ value: CGFloat) -> CGFloat {
        snapToGrid ? (value / Self.gridSize).rounded() * Self.gridSize : value
    }

    private func snap(_ value: Double) -> Double {
        Double(snap(CGFloat(value)))
    }

    // MARK: Connections

    /// Connects two ports, or explains why not.
    @discardableResult
    func connect(from: UUID, port fromPort: String, to: UUID, port toPort: String) -> String? {
        guard from != to else { return "A step can't connect to itself." }
        guard let source = node(from), let target = node(to) else { return "That step no longer exists." }
        guard let out = ports(for: source).first(where: { $0.id == fromPort && $0.direction == .output }),
              let input = ports(for: target).first(where: { $0.id == toPort && $0.direction == .input })
        else { return "Connect an output (right side) to an input (left side)." }
        if let problem = out.type.incompatibility(with: input.type) { return problem }
        if draft.connections.contains(where: { $0.fromNode == from && $0.fromPort == fromPort && $0.toNode == to && $0.toPort == toPort }) {
            return nil
        }
        var proposed = draft.connections.filter { input.isControl || !($0.toNode == to && $0.toPort == toPort) }
        proposed.append(WorkflowConnection(fromNode: from, fromPort: fromPort, toNode: to, toPort: toPort))
        if WorkflowValidator.findCycle(nodes: draft.steps.map(\.id), connections: proposed) != nil {
            return "That would connect steps in a circle. Use a Loop node to repeat steps."
        }
        mutate("Connect") { $0.connections = proposed }
        return nil
    }

    func disconnect(_ id: UUID) {
        mutate("Disconnect") { $0.connections.removeAll { $0.id == id } }
    }

    // MARK: Clipboard

    struct Clipboard: Codable {
        var steps: [WorkflowStep]
        var connections: [WorkflowConnection]

        init(workflow: Workflow, nodeIDs: Set<UUID>) {
            steps = workflow.steps.filter { nodeIDs.contains($0.id) }
            connections = workflow.connections.filter { nodeIDs.contains($0.fromNode) && nodeIDs.contains($0.toNode) }
        }

        static let type = "app.atlas.flow-nodes"
    }

    /// The selection as text for the pasteboard (Edit ▸ Copy).
    func clipboardText() -> String? {
        guard !selection.isEmpty, let data = try? JSONEncoder().encode(Clipboard(workflow: draft, nodeIDs: selection)) else { return nil }
        return Clipboard.type + "\n" + String(decoding: data, as: UTF8.self)
    }

    /// Pastes nodes copied from any workflow (Edit ▸ Paste).
    func paste(text: String) {
        guard text.hasPrefix(Clipboard.type + "\n"),
              let clipboard = try? JSONDecoder().decode(Clipboard.self, from: Data(text.dropFirst(Clipboard.type.count + 1).utf8)),
              let pasted = insert(clipboard, offset: 60, name: "Paste")
        else { return }
        selection = pasted
    }

    /// Adds copies with fresh IDs, keeping connections among them.
    private func insert(_ clipboard: Clipboard, offset: Double, name: String) -> Set<UUID>? {
        guard !clipboard.steps.isEmpty else { return nil }
        var map: [UUID: UUID] = [:]
        let steps = clipboard.steps.map { step -> WorkflowStep in
            var copy = step
            copy.id = UUID()
            copy.position.x += offset
            copy.position.y += offset
            map[step.id] = copy.id
            return copy
        }
        let connections = clipboard.connections.compactMap { c -> WorkflowConnection? in
            guard let from = map[c.fromNode], let to = map[c.toNode] else { return nil }
            return WorkflowConnection(fromNode: from, fromPort: c.fromPort, toNode: to, toPort: c.toPort)
        }
        mutate(name) { workflow in
            workflow.steps += steps
            workflow.connections += connections
        }
        return Set(steps.map(\.id))
    }

    // MARK: Groups & blocks

    func groupSelection(named name: String = "Group") {
        guard selection.count > 1 else { return }
        let members = draft.steps.map(\.id).filter(selection.contains)
        mutate("Group") { workflow in
            for index in workflow.settings.groups.indices {
                workflow.settings.groups[index].nodeIDs.removeAll { members.contains($0) }
            }
            workflow.settings.groups.removeAll { $0.nodeIDs.isEmpty }
            workflow.settings.groups.append(NodeGroup(name: name, nodeIDs: members))
        }
    }

    func ungroup(_ id: UUID) {
        mutate("Ungroup") { $0.settings.groups.removeAll { $0.id == id } }
    }

    func renameGroup(_ id: UUID, to name: String) {
        mutate("Rename Group") { workflow in
            if let index = workflow.settings.groups.firstIndex(where: { $0.id == id }) { workflow.settings.groups[index].name = name }
        }
    }

    func toggleCollapsed(_ id: UUID) {
        mutate("Collapse Group") { workflow in
            if let index = workflow.settings.groups.firstIndex(where: { $0.id == id }) { workflow.settings.groups[index].isCollapsed.toggle() }
        }
    }

    func group(containing nodeID: UUID) -> NodeGroup? {
        draft.settings.groups.first { $0.nodeIDs.contains(nodeID) }
    }

    func isHidden(_ nodeID: UUID) -> Bool {
        group(containing: nodeID)?.isCollapsed ?? false
    }

    func bounds(of group: NodeGroup) -> CGRect {
        group.nodeIDs.compactMap(node).map(frame(of:)).reduce(CGRect.null) { $0.union($1) }
    }

    /// Turns a group into a reusable block: its steps become a new
    /// automation, replaced here by one Subworkflow step. Flow into and out
    /// of the group is kept; values passed across the edge can't be, and
    /// the message says so.
    func makeBlock(from groupID: UUID) {
        guard let group = draft.settings.groups.first(where: { $0.id == groupID }) else { return }
        let members = Set(group.nodeIDs)
        let inside = draft.steps.filter { members.contains($0.id) }
        guard !inside.isEmpty, !inside.contains(where: { $0.kind == .trigger }) else {
            message = "Blocks can't contain triggers."
            return
        }
        let origin = bounds(of: group).origin
        var block = Workflow(
            name: group.name,
            summary: "Made from a group in “\(draft.name)”.",
            failurePolicy: draft.failurePolicy,
            steps: inside.map { var step = $0; step.position.x -= origin.x; step.position.y -= origin.y; return step },
            connections: draft.connections.filter { members.contains($0.fromNode) && members.contains($0.toNode) }
        )
        block = block.duplicate(named: group.name)
        let savedBlock: Workflow
        do {
            savedBlock = try core.save(block)
        } catch {
            message = error.localizedDescription
            return
        }
        let call = WorkflowStep.control(.subworkflow, config: NodeConfig(workflowID: savedBlock.id), label: group.name,
                                        at: NodePosition(x: origin.x, y: origin.y))
        let crossingData = draft.connections.filter { !$0.isControl && (members.contains($0.fromNode) != members.contains($0.toNode)) }
        mutate("Make Block") { workflow in
            let incoming = workflow.connections.filter { $0.isControl && !members.contains($0.fromNode) && members.contains($0.toNode) }
            let outgoing = workflow.connections.filter { $0.isControl && members.contains($0.fromNode) && !members.contains($0.toNode) }
            workflow.steps.removeAll { members.contains($0.id) }
            workflow.steps.append(call)
            workflow.connections.removeAll { members.contains($0.fromNode) || members.contains($0.toNode) }
            for edge in incoming where !workflow.connections.contains(where: { $0.fromNode == edge.fromNode && $0.fromPort == edge.fromPort && $0.toNode == call.id }) {
                workflow.connections.append(WorkflowConnection(fromNode: edge.fromNode, fromPort: edge.fromPort, toNode: call.id))
            }
            for edge in outgoing where !workflow.connections.contains(where: { $0.fromNode == call.id && $0.toNode == edge.toNode }) {
                workflow.connections.append(WorkflowConnection(fromNode: call.id, toNode: edge.toNode))
            }
            workflow.settings.groups.removeAll { $0.id == groupID }
        }
        selection = [call.id]
        message = crossingData.isEmpty
            ? "Saved “\(savedBlock.name)” as a reusable automation."
            : "Saved “\(savedBlock.name)”. \(crossingData.count) value connection(s) crossed the group's edge and were removed; pass them as subworkflow inputs instead."
    }

    // MARK: Saving & running

    @discardableResult
    public func save() -> Bool {
        do {
            let wantedEnabled = draft.isEnabled
            let result = try core.save(draft)
            saved = result
            draft = result
            revalidate()
            if wantedEnabled && !result.isEnabled {
                message = "Saved as a draft. Fix \(errorCount) problem\(errorCount == 1 ? "" : "s") to turn its triggers on."
            }
            onSaved(result)
            return true
        } catch {
            message = error.localizedDescription
            return false
        }
    }

    /// Picks up a version saved elsewhere (e.g. the step list), unless
    /// there are unsaved edits here.
    public func reload(from workflow: Workflow) {
        guard !isDirty, workflow != saved else { return }
        var normalized = workflow
        Self.layoutIfNeeded(&normalized)
        saved = normalized
        draft = normalized
        revalidate()
    }

    public func revert() {
        let before = draft
        draft = saved
        registerUndo(restoring: before, name: "Revert")
        revalidate()
    }

    public func setEnabled(_ enabled: Bool) {
        if enabled && WorkflowValidator.hasErrors(issues) && draft.hasTriggers {
            message = "Fix \(errorCount) problem\(errorCount == 1 ? "" : "s") before turning this automation on."
            return
        }
        mutate(enabled ? "Turn On" : "Turn Off") { $0.isEnabled = enabled }
    }

    /// Sample values for "Run now", from the first trigger's outputs.
    func samplePayload() -> ActionParameters {
        guard let trigger = draft.triggerNodes.first, let type = TriggerCatalog.type(id: trigger.config.triggerType ?? "") else { return [:] }
        var payload: ActionParameters = [:]
        let folder = (trigger.parameters["folder"]?.stringValue).map { ($0 as NSString).expandingTildeInPath } ?? NSHomeDirectory() + "/Downloads"
        for output in type.outputs {
            switch output.key {
            case "path": payload["path"] = .string(folder + "/Sample.pdf")
            case "fileName": payload["fileName"] = "Sample.pdf"
            case "extension": payload["extension"] = "pdf"
            case "folder": payload["folder"] = .string(folder)
            case "bundleId": payload["bundleId"] = .string(trigger.parameters["app"]?.stringValue ?? "com.apple.Safari")
            case "appName": payload["appName"] = "Safari"
            case "displayCount": payload["displayCount"] = 2
            case "batteryPercent": payload["batteryPercent"] = 15
            default: payload[output.key] = .string("sample")
            }
        }
        return payload
    }

    /// Runs the current draft now, starting at its first trigger with
    /// `payload` as what the trigger reported.
    public func testRun(payload: ActionParameters) {
        let workflow = draft
        let entry = workflow.triggerNodes.first?.id
        Task { await core.engine.start(workflow, trigger: RunTrigger.test, payload: payload, entryNodeID: entry) }
    }

    public func cancelRun() {
        guard let runID = live.runID else { return }
        Task { await core.engine.cancel(runID: runID) }
    }

    // MARK: View

    var contentBounds: CGRect {
        draft.steps.filter { !isHidden($0.id) }.map(frame(of:)).reduce(CGRect.null) { $0.union($1) }
    }

    func fit(in size: CGSize) {
        transform = CanvasTransform.fitting(contentBounds, in: size)
    }

    /// Centers a node, e.g. from a "Fix" link in Run History.
    public func focus(on nodeID: UUID) {
        focus(on: nodeID, in: canvasSize == .zero ? CGSize(width: 800, height: 500) : canvasSize)
    }

    public func focus(on nodeID: UUID, in size: CGSize) {
        guard let node = node(nodeID) else { return }
        selection = [nodeID]
        let center = CGPoint(x: frame(of: node).midX, y: frame(of: node).midY)
        transform.offset = CGPoint(x: size.width / 2 - center.x * transform.scale, y: size.height / 2 - center.y * transform.scale)
    }

    /// Gives old step lists a left-to-right layout the first time they're opened.
    static func layoutIfNeeded(_ workflow: inout Workflow) {
        let positions = Set(workflow.steps.map { "\($0.position.x),\($0.position.y)" })
        guard workflow.steps.count > 1, positions.count < workflow.steps.count else { return }
        for index in workflow.steps.indices {
            workflow.steps[index].position = NodePosition(x: Double(index) * 280, y: 0, z: workflow.steps[index].position.z)
        }
    }
}
