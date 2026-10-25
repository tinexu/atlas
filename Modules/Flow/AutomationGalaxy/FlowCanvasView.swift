import AppKit
import AtlasCore
import SwiftUI

/// The 2D graph editor: pan (scroll, or ⌥-drag), zoom (pinch or ⌘-scroll),
/// click to select, ⇧-click to add to the selection, drag on empty space to
/// marquee-select, drag nodes to move (snapping to the grid), and drag from
/// an output to an input to connect. Incompatible ports refuse with the
/// reason. Also used read-only to show a past run.
struct FlowCanvasView: View {
    static let space = "flow-canvas"

    @ObservedObject var model: FlowEditorModel
    var isEditable = true
    /// States to colour nodes with; defaults to the live run.
    var states: [UUID: RunState]?
    /// Connections a past run followed.
    var taken: Set<UUID> = []

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.undoManager) private var undoManager
    @State private var pending: PendingConnection?
    @State private var marquee: (start: CGPoint, end: CGPoint)?
    @State private var lastDrag: CGSize = .zero
    @State private var panStart: CGPoint?
    @State private var lastMagnification: CGFloat = 1
    @State private var scrollMonitor: Any?
    @State private var isHovering = false
    @State private var viewSize: CGSize = .zero
    @State private var hasFitted = false

    struct PendingConnection {
        let node: UUID
        let port: NodePort
        var location: CGPoint  // view points
    }

    private var nodeStates: [UUID: RunState] { states ?? model.live.nodeStates }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                background
                groupBoxes
                connectionLayer
                nodes
                if let pending, let start = startPoint(pending) {
                    LayoutPath(path: NodeLayout.curve(from: start, to: pending.location))
                        .stroke(FlowStyle.color(for: pending.port.type), style: StrokeStyle(lineWidth: 2, dash: pending.port.isControl ? [] : [5, 4]))
                        .allowsHitTesting(false)
                }
                if let marquee {
                    let rect = CGRect(x: min(marquee.start.x, marquee.end.x), y: min(marquee.start.y, marquee.end.y),
                                      width: abs(marquee.end.x - marquee.start.x), height: abs(marquee.end.y - marquee.start.y))
                    Rectangle()
                        .fill(Color.accentColor.opacity(0.1))
                        .overlay(Rectangle().strokeBorder(Color.accentColor, lineWidth: 1))
                        .frame(width: rect.width, height: rect.height)
                        .offset(x: rect.minX, y: rect.minY)
                        .allowsHitTesting(false)
                }
                if let refusal = model.refusal {
                    Label(refusal.message, systemImage: "nosign")
                        .font(.caption)
                        .padding(8)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                        .frame(maxWidth: 280, alignment: .leading)
                        .offset(x: refusal.at.x + 12, y: refusal.at.y + 12)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }
            }
            .coordinateSpace(name: Self.space)
            .clipped()
            .overlay(alignment: .bottomTrailing) {
                MiniMapView(model: model, viewSize: geometry.size).padding(10)
            }
            .overlay(alignment: .bottomLeading) { zoomControls(size: geometry.size).padding(10) }
            .onAppear {
                viewSize = geometry.size
                model.canvasSize = geometry.size
                model.undoManager = undoManager
                if !hasFitted, !model.draft.steps.isEmpty {
                    hasFitted = true
                    model.fit(in: geometry.size)
                }
            }
            .onChange(of: geometry.size) { _, size in
                viewSize = size
                model.canvasSize = size
            }
            .dropDestination(for: String.self) { items, location in
                guard isEditable, let id = items.first else { return false }
                return model.add(templateID: id, at: model.transform.canvas(location))
            }
            .onHover { isHovering = $0 }
            .onAppear(perform: installScrollMonitor)
            .onDisappear(perform: removeScrollMonitor)
            .gesture(
                MagnifyGesture()
                    .onChanged { value in
                        let factor = value.magnification / lastMagnification
                        lastMagnification = value.magnification
                        model.transform.zoom(by: factor, around: CGPoint(x: geometry.size.width / 2, y: geometry.size.height / 2))
                    }
                    .onEnded { _ in lastMagnification = 1 }
            )
        }
        .focusable(isEditable)
        .focusEffectDisabled()
        .onDeleteCommand { if isEditable { model.deleteSelection() } }
        .onCopyCommand { model.clipboardText().map { [NSItemProvider(object: $0 as NSString)] } ?? [] }
        .onCutCommand {
            let providers = model.clipboardText().map { [NSItemProvider(object: $0 as NSString)] } ?? []
            if isEditable { model.deleteSelection() }
            return providers
        }
        .onPasteCommand(of: [.plainText]) { providers in
            guard isEditable else { return }
            for provider in providers {
                _ = provider.loadObject(ofClass: NSString.self) { object, _ in
                    guard let text = object as? String else { return }
                    Task { @MainActor in model.paste(text: text) }
                }
            }
        }
        .onCommand(#selector(NSResponder.selectAll(_:))) { model.selectAll() }
    }

    // MARK: - Layers

    private var background: some View {
        Canvas { context, size in
            let spacing = FlowEditorModel.gridSize * model.transform.scale
            guard spacing >= 8 else { return }
            let origin = model.transform.offset
            var x = origin.x.truncatingRemainder(dividingBy: spacing)
            while x < size.width {
                var y = origin.y.truncatingRemainder(dividingBy: spacing)
                while y < size.height {
                    context.fill(Path(ellipseIn: CGRect(x: x - 0.75, y: y - 0.75, width: 1.5, height: 1.5)), with: .color(.secondary.opacity(0.35)))
                    y += spacing
                }
                x += spacing
            }
        }
        .background(Color(nsColor: .underPageBackgroundColor))
        .contentShape(Rectangle())
        .gesture(backgroundDrag)
        .onTapGesture { model.selection = [] }
    }

    private var groupBoxes: some View {
        ForEach(model.draft.settings.groups) { group in
            let bounds = model.bounds(of: group)
            if !bounds.isNull {
                let rect = model.transform.view(group.isCollapsed ? collapsedRect(group) : bounds.insetBy(dx: -16, dy: -34))
                GroupBoxView(model: model, group: group, isEditable: isEditable)
                    .frame(width: rect.width, height: rect.height)
                    .offset(x: rect.minX, y: rect.minY)
            }
        }
    }

    func collapsedRect(_ group: NodeGroup) -> CGRect {
        let bounds = model.bounds(of: group)
        return CGRect(x: bounds.minX, y: bounds.minY, width: NodeLayout.width, height: 70)
    }

    private var animating: Bool { !model.live.flowing.isEmpty && !reduceMotion }

    private var connectionLayer: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !animating)) { timeline in
            Canvas { context, _ in
                let phase = CGFloat(timeline.date.timeIntervalSinceReferenceDate * 40).truncatingRemainder(dividingBy: 18)
                let issueConnections = Set(model.issues.compactMap(\.connectionID))
                for connection in model.draft.connections {
                    guard let (a, b, type) = endpoints(connection) else { continue }
                    let path = NodeLayout.curve(from: a, to: b)
                    let isFlowing = model.live.flowing.contains(connection.id)
                    let isTaken = taken.contains(connection.id)
                    var color: Color = connection.isControl ? .primary.opacity(0.5) : FlowStyle.color(for: type).opacity(0.8)
                    var width: CGFloat = connection.isControl ? 2 : 1.5
                    var dash: [CGFloat] = connection.isControl ? [] : [5, 4]
                    if issueConnections.contains(connection.id) { color = .red }
                    if isTaken { color = .green; width = 3.5 }
                    if isFlowing { color = .accentColor; width = 3.5; dash = [10, 8] }
                    context.stroke(path, with: .color(color),
                                   style: StrokeStyle(lineWidth: width * max(model.transform.scale, 0.5), lineCap: .round,
                                                      dash: dash, dashPhase: isFlowing ? -phase : 0))
                }
            }
        }
        .allowsHitTesting(false)
    }

    private var nodes: some View {
        ForEach(model.draft.steps.filter { !model.isHidden($0.id) }) { node in
            let ports = model.ports(for: node)
            let origin = model.transform.view(CGPoint(x: node.position.x, y: node.position.y))
            NodeCardView(
                node: node,
                title: model.title(of: node),
                subtitle: model.subtitle(of: node),
                symbol: model.symbol(of: node),
                ports: ports,
                isSelected: model.selection.contains(node.id),
                state: nodeStates[node.id],
                issues: isEditable ? model.issues(for: node.id) : [],
                connectedInputs: Set(model.draft.connections.filter { $0.toNode == node.id }.map(\.toPort)),
                onPortDrag: isEditable ? { port, value in portDragChanged(node: node, port: port, value: value) } : nil,
                onPortDragEnd: isEditable ? { port, value in portDragEnded(node: node, port: port, value: value) } : nil
            )
            .scaleEffect(model.transform.scale, anchor: .topLeading)
            .frame(width: NodeLayout.width * model.transform.scale, height: NodeLayout.size(ports).height * model.transform.scale,
                   alignment: .topLeading)
            .offset(x: origin.x, y: origin.y)
            .onTapGesture { select(node.id) }
            .gesture(isEditable ? nodeDrag(node.id) : nil)
            .contextMenu { if isEditable { NodeContextMenu(model: model, nodeID: node.id) } }
        }
    }

    // MARK: - Geometry

    /// Where a connection is drawn, redirected to a collapsed group's box.
    private func endpoints(_ connection: WorkflowConnection) -> (CGPoint, CGPoint, PortType)? {
        guard let from = model.node(connection.fromNode), let to = model.node(connection.toNode) else { return nil }
        let fromPorts = model.ports(for: from), toPorts = model.ports(for: to)
        let type = fromPorts.first { $0.id == connection.fromPort }?.type ?? .any
        func point(_ node: WorkflowStep, _ ports: [NodePort], _ port: String, _ direction: PortDirection) -> CGPoint? {
            if let group = model.group(containing: node.id), group.isCollapsed {
                let rect = collapsedRect(group)
                return CGPoint(x: direction == .input ? rect.minX : rect.maxX, y: rect.midY)
            }
            return NodeLayout.portPoint(node, ports: ports, id: port, direction: direction)
        }
        guard let a = point(from, fromPorts, connection.fromPort, .output), let b = point(to, toPorts, connection.toPort, .input) else { return nil }
        if let groupA = model.group(containing: from.id), groupA.isCollapsed, groupA.nodeIDs.contains(to.id) { return nil }
        return (model.transform.view(a), model.transform.view(b), type)
    }

    private func startPoint(_ pending: PendingConnection) -> CGPoint? {
        guard let node = model.node(pending.node),
              let point = NodeLayout.portPoint(node, ports: model.ports(for: node), id: pending.port.id, direction: .output)
        else { return nil }
        return model.transform.view(point)
    }

    /// The input port nearest a view point, if close enough.
    private func inputPort(at location: CGPoint) -> (UUID, NodePort)? {
        let point = model.transform.canvas(location)
        let radius = 16 / model.transform.scale
        var best: (UUID, NodePort, CGFloat)?
        for node in model.draft.steps where !model.isHidden(node.id) {
            let ports = model.ports(for: node)
            for port in ports where port.direction == .input {
                guard let p = NodeLayout.portPoint(node, ports: ports, id: port.id, direction: .input) else { continue }
                let distance = hypot(p.x - point.x, p.y - point.y)
                if distance < radius, distance < (best?.2 ?? .infinity) { best = (node.id, port, distance) }
            }
        }
        // Dropped on a node's body: its flow input.
        if best == nil, let node = model.draft.steps.first(where: { !model.isHidden($0.id) && model.frame(of: $0).contains(point) }),
           let flow = model.ports(for: node).first(where: { $0.id == NodePort.controlIn }) {
            return (node.id, flow)
        }
        return best.map { ($0.0, $0.1) }
    }

    // MARK: - Gestures

    private func select(_ id: UUID) {
        if NSEvent.modifierFlags.contains(.shift) || NSEvent.modifierFlags.contains(.command) {
            if model.selection.contains(id) { model.selection.remove(id) } else { model.selection.insert(id) }
        } else {
            model.selection = [id]
        }
    }

    private func nodeDrag(_ id: UUID) -> some Gesture {
        DragGesture(minimumDistance: 3, coordinateSpace: .named(Self.space))
            .onChanged { value in
                if !model.selection.contains(id) { model.selection = [id] }
                model.beginMove()
                let delta = CGSize(width: value.translation.width - lastDrag.width, height: value.translation.height - lastDrag.height)
                lastDrag = value.translation
                model.moveSelection(by: CGSize(width: delta.width / model.transform.scale, height: delta.height / model.transform.scale))
            }
            .onEnded { _ in
                lastDrag = .zero
                model.endMove()
            }
    }

    private var backgroundDrag: some Gesture {
        DragGesture(minimumDistance: 3, coordinateSpace: .named(Self.space))
            .onChanged { value in
                if NSEvent.modifierFlags.contains(.option) || panStart != nil {
                    if panStart == nil { panStart = model.transform.offset }
                    model.transform.offset = CGPoint(x: panStart!.x + value.translation.width, y: panStart!.y + value.translation.height)
                } else {
                    marquee = (value.startLocation, value.location)
                }
            }
            .onEnded { _ in
                panStart = nil
                if let marquee {
                    let a = model.transform.canvas(marquee.start), b = model.transform.canvas(marquee.end)
                    let rect = CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
                    let hits = Set(model.draft.steps.filter { !model.isHidden($0.id) && model.frame(of: $0).intersects(rect) }.map(\.id))
                    model.selection = NSEvent.modifierFlags.contains(.shift) ? model.selection.union(hits) : hits
                }
                marquee = nil
            }
    }

    private func portDragChanged(node: WorkflowStep, port: NodePort, value: DragGesture.Value) {
        pending = PendingConnection(node: node.id, port: port, location: value.location)
    }

    private func portDragEnded(node: WorkflowStep, port: NodePort, value: DragGesture.Value) {
        pending = nil
        guard let (target, input) = inputPort(at: value.location) else { return }
        if let reason = model.connect(from: node.id, port: port.id, to: target, port: input.id) {
            withAnimation { model.refusal = (reason, value.location) }
            Task {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                withAnimation { if model.refusal?.message == reason { model.refusal = nil } }
            }
        }
    }

    // MARK: - Zoom

    private func zoomControls(size: CGSize) -> some View {
        HStack(spacing: 2) {
            Button { model.transform.zoom(by: 1 / 1.2, around: CGPoint(x: size.width / 2, y: size.height / 2)) } label: {
                Image(systemName: "minus.magnifyingglass")
            }
            .help("Zoom out")
            Text("\(Int((model.transform.scale * 100).rounded()))%")
                .font(.caption.monospacedDigit())
                .frame(width: 44)
            Button { model.transform.zoom(by: 1.2, around: CGPoint(x: size.width / 2, y: size.height / 2)) } label: {
                Image(systemName: "plus.magnifyingglass")
            }
            .help("Zoom in")
            Button { model.fit(in: size) } label: { Image(systemName: "arrow.up.left.and.down.right.magnifyingglass") }
                .help("Fit to screen")
        }
        .buttonStyle(.borderless)
        .padding(6)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
    }

    /// Scroll pans; ⌘-scroll zooms. Only while the pointer is over the canvas.
    private func installScrollMonitor() {
        guard scrollMonitor == nil else { return }
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            guard isHovering else { return event }
            if event.modifierFlags.contains(.command) {
                let location = CGPoint(x: viewSize.width / 2, y: viewSize.height / 2)
                model.transform.zoom(by: exp(event.scrollingDeltaY * 0.01), around: location)
            } else {
                let scale: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 10
                model.transform.offset.x += event.scrollingDeltaX * scale
                model.transform.offset.y += event.scrollingDeltaY * scale
            }
            return nil
        }
    }

    private func removeScrollMonitor() {
        if let scrollMonitor { NSEvent.removeMonitor(scrollMonitor) }
        scrollMonitor = nil
    }
}

private struct LayoutPath: Shape {
    let path: Path
    func path(in rect: CGRect) -> Path { path }
}

/// A named box around grouped nodes; collapsed, it stands in for them.
private struct GroupBoxView: View {
    @ObservedObject var model: FlowEditorModel
    let group: NodeGroup
    let isEditable: Bool

    var body: some View {
        RoundedRectangle(cornerRadius: 14)
            .fill(group.isCollapsed ? AnyShapeStyle(.background) : AnyShapeStyle(Color.accentColor.opacity(0.06)))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.accentColor.opacity(0.45), style: StrokeStyle(lineWidth: 1.5, dash: [6, 4])))
            .overlay(alignment: .topLeading) {
                HStack(spacing: 6) {
                    Button { model.toggleCollapsed(group.id) } label: {
                        Image(systemName: group.isCollapsed ? "chevron.right" : "chevron.down")
                    }
                    .buttonStyle(.borderless)
                    Text(group.name).font(.caption.weight(.semibold))
                    if group.isCollapsed {
                        Text("\(group.nodeIDs.count) steps").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .padding(8)
            }
            .contextMenu {
                if isEditable {
                    Button(group.isCollapsed ? "Expand" : "Collapse") { model.toggleCollapsed(group.id) }
                    Button("Make Reusable Block") { model.makeBlock(from: group.id) }
                    Button("Ungroup") { model.ungroup(group.id) }
                }
            }
    }
}

struct NodeContextMenu: View {
    @ObservedObject var model: FlowEditorModel
    let nodeID: UUID

    var body: some View {
        Button("Duplicate") {
            if !model.selection.contains(nodeID) { model.selection = [nodeID] }
            model.duplicateSelection()
        }
        if model.selection.count > 1 {
            Button("Group Selection") { model.groupSelection() }
        }
        if let node = model.node(nodeID) {
            Button(node.isEnabled ? "Turn Off Step" : "Turn On Step") {
                model.updateNode(nodeID, node.isEnabled ? "Turn Off Step" : "Turn On Step") { $0.isEnabled.toggle() }
            }
        }
        Divider()
        Button("Delete", role: .destructive) {
            if !model.selection.contains(nodeID) { model.selection = [nodeID] }
            model.deleteSelection()
        }
    }
}

/// A small overview of the whole graph with the visible area outlined.
/// Click or drag to move the view.
private struct MiniMapView: View {
    @ObservedObject var model: FlowEditorModel
    let viewSize: CGSize
    private let size = CGSize(width: 170, height: 110)

    private struct Geometry {
        let world: CGRect
        let visible: CGRect
        let scale: CGFloat

        func map(_ rect: CGRect) -> CGRect {
            CGRect(x: (rect.minX - world.minX) * scale, y: (rect.minY - world.minY) * scale,
                   width: rect.width * scale, height: rect.height * scale)
        }
    }

    private var geometry: Geometry? {
        let content = model.contentBounds
        guard !content.isNull else { return nil }
        let visible = CGRect(origin: model.transform.canvas(.zero),
                             size: CGSize(width: viewSize.width / model.transform.scale, height: viewSize.height / model.transform.scale))
        let world = content.union(visible).insetBy(dx: -40, dy: -40)
        return Geometry(world: world, visible: visible, scale: min(size.width / world.width, size.height / world.height))
    }

    var body: some View {
        if let geometry {
            Canvas { context, _ in
                for node in model.draft.steps where !model.isHidden(node.id) {
                    context.fill(Path(roundedRect: geometry.map(model.frame(of: node)), cornerRadius: 2),
                                 with: .color(FlowStyle.color(for: node.kind).opacity(0.8)))
                }
                context.stroke(Path(geometry.map(geometry.visible)), with: .color(.accentColor), lineWidth: 1.5)
            }
            .frame(width: size.width, height: size.height)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                let target = CGPoint(x: value.location.x / geometry.scale + geometry.world.minX,
                                     y: value.location.y / geometry.scale + geometry.world.minY)
                model.transform.offset = CGPoint(x: viewSize.width / 2 - target.x * model.transform.scale,
                                                 y: viewSize.height / 2 - target.y * model.transform.scale)
            })
            .accessibilityHidden(true)
        }
    }
}
