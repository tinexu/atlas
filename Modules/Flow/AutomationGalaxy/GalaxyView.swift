import AppKit
import AtlasCore
import RealityKit
import SwiftUI

/// The 3D Automation Galaxy: the same graph as glowing nodes floating in
/// space, joined by light trails. Drag to orbit, scroll or pinch to zoom,
/// click a node to open it in the inspector. Everything here is also in
/// the 2D canvas, which is the full editor.
///
/// Rendering stops when the window is hidden or this view isn't shown, and
/// nothing moves on its own when Reduce Motion is on.
struct GalaxyView: View {
    @ObservedObject var model: FlowEditorModel
    @ObservedObject private var live: LiveRunMonitor
    @State private var scene = GalaxyScene()
    @State private var isVisible = true
    @State private var lastDrag: CGSize = .zero
    @State private var lastMagnification: CGFloat = 1
    @State private var scrollMonitor: Any?
    @State private var isHovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(model: FlowEditorModel) {
        self.model = model
        self._live = ObservedObject(wrappedValue: model.live)
    }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            Color(nsColor: NSColor(red: 0.03, green: 0.04, blue: 0.09, alpha: 1))
            if isVisible {
                RealityView { content in
                    content.camera = .virtual
                    // After a pause the old view may still hold the scene; take it back first.
                    scene.root.removeFromParent()
                    content.add(scene.root)
                } update: { _ in
                    scene.sync(model: model, states: live.nodeStates, flowing: live.flowing, reduceMotion: reduceMotion)
                }
                .gesture(
                    SpatialTapGesture().targetedToAnyEntity().onEnded { value in
                        if let id = scene.nodeID(for: value.entity) { model.selection = [id] }
                    }
                )
                .simultaneousGesture(
                    DragGesture(minimumDistance: 3)
                        .onChanged { value in
                            scene.orbit(dx: Float(value.translation.width - lastDrag.width), dy: Float(value.translation.height - lastDrag.height))
                            lastDrag = value.translation
                        }
                        .onEnded { _ in lastDrag = .zero }
                )
                .simultaneousGesture(
                    MagnifyGesture()
                        .onChanged { value in
                            scene.zoom(by: Float(value.magnification / lastMagnification))
                            lastMagnification = value.magnification
                        }
                        .onEnded { _ in lastMagnification = 1 }
                )
                .onHover { isHovering = $0 }
                .onAppear(perform: installScrollMonitor)
                .onDisappear(perform: removeScrollMonitor)
            } else {
                Label("Paused while the window is hidden", systemImage: "pause.circle")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            HStack {
                Button { scene.resetView() } label: { Label("Reset View", systemImage: "scope") }
                Text("Drag to orbit · scroll or pinch to zoom · click a node to edit it")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.6))
            }
            .padding(10)
        }
        .background(OcclusionReader(isVisible: $isVisible))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("3D view of this automation. Everything here is also in the 2D editor.")
    }

    private func installScrollMonitor() {
        guard scrollMonitor == nil else { return }
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            guard isHovering else { return event }
            scene.zoom(by: exp(Float(event.scrollingDeltaY) * 0.01))
            return nil
        }
    }

    private func removeScrollMonitor() {
        if let scrollMonitor { NSEvent.removeMonitor(scrollMonitor) }
        scrollMonitor = nil
    }
}

@MainActor
final class GalaxyScene {
    let root = Entity()
    private let camera = PerspectiveCamera()
    private let nodesRoot = Entity()
    private let trailsRoot = Entity()
    private var nodeEntities: [UUID: (signature: String, entity: Entity)] = [:]
    private var yaw: Float = 0.3
    private var pitch: Float = 0.25
    private var distance: Float = 12
    private var target = SIMD3<Float>.zero
    private var hasFramed = false

    /// Canvas points per world unit.
    static let spread: Float = 260

    init() {
        camera.camera.fieldOfViewInDegrees = 50
        root.addChild(camera)
        root.addChild(trailsRoot)
        root.addChild(nodesRoot)
        // A handful of faint stars for depth.
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<60 {
            let star = ModelEntity(mesh: .generateSphere(radius: 0.03), materials: [UnlitMaterial(color: NSColor(white: 1, alpha: 0.5))])
            star.position = [Float.random(in: -30...30, using: &generator), Float.random(in: -18...18, using: &generator),
                             Float.random(in: -30 ... -10, using: &generator)]
            root.addChild(star)
        }
        applyCamera()
    }

    func position(of node: WorkflowStep) -> SIMD3<Float> {
        SIMD3(Float(node.position.x) / Self.spread, -Float(node.position.y) / Self.spread, Float(node.position.z) * 1.5)
    }

    func sync(model: FlowEditorModel, states: [UUID: RunState], flowing: Set<UUID>, reduceMotion: Bool) {
        let steps = model.draft.steps
        let present = Set(steps.map(\.id))
        for (id, entry) in nodeEntities where !present.contains(id) {
            entry.entity.removeFromParent()
            nodeEntities[id] = nil
        }
        for node in steps {
            let state = states[node.id]
            let selected = model.selection.contains(node.id)
            let signature = "\(model.title(of: node))|\(node.kind)|\(state?.rawValue ?? "")|\(selected)|\(model.hasError(node.id))"
            let entity: Entity
            if let existing = nodeEntities[node.id], existing.signature == signature {
                entity = existing.entity
            } else {
                nodeEntities[node.id]?.entity.removeFromParent()
                entity = makeNode(node, title: model.title(of: node), state: state, selected: selected, hasError: model.hasError(node.id))
                nodesRoot.addChild(entity)
                nodeEntities[node.id] = (signature, entity)
            }
            entity.position = position(of: node)
        }

        trailsRoot.children.removeAll()
        for connection in model.draft.connections {
            guard let a = model.node(connection.fromNode), let b = model.node(connection.toNode) else { continue }
            let lit = flowing.contains(connection.id)
            let color: NSColor = lit ? .controlAccentColor : (connection.isControl ? NSColor(white: 0.85, alpha: 1) : .systemPink)
            trailsRoot.addChild(trail(from: position(of: a), to: position(of: b), color: color, radius: lit ? 0.05 : (connection.isControl ? 0.025 : 0.015)))
        }

        if !hasFramed, !steps.isEmpty {
            hasFramed = true
            frame(steps)
        }
    }

    private func makeNode(_ node: WorkflowStep, title: String, state: RunState?, selected: Bool, hasError: Bool) -> Entity {
        let container = Entity()
        container.name = "node:\(node.id.uuidString)"
        let color: NSColor = hasError ? .systemRed : (state.map(Self.color(for:)) ?? FlowStyle.nsColor(for: node.kind))
        let radius: Float = node.kind == .trigger ? 0.42 : 0.32
        let core = ModelEntity(mesh: .generateSphere(radius: radius), materials: [UnlitMaterial(color: color)])
        container.addChild(core)
        // A soft halo makes it read as glowing without lights.
        var haloMaterial = UnlitMaterial(color: color)
        haloMaterial.blending = .transparent(opacity: .init(floatLiteral: selected ? 0.4 : 0.18))
        let halo = ModelEntity(mesh: .generateSphere(radius: radius * (selected ? 1.9 : 1.5)), materials: [haloMaterial])
        container.addChild(halo)
        let mesh = MeshResource.generateText(title, extrusionDepth: 0.002, font: .systemFont(ofSize: 0.22, weight: .semibold))
        let label = ModelEntity(mesh: mesh, materials: [UnlitMaterial(color: NSColor(white: 1, alpha: 0.9))])
        label.position = [-mesh.bounds.center.x, -radius - 0.38, 0]
        container.addChild(label)
        container.components.set(CollisionComponent(shapes: [.generateSphere(radius: radius * 1.5)]))
        container.components.set(InputTargetComponent())
        return container
    }

    private func trail(from a: SIMD3<Float>, to b: SIMD3<Float>, color: NSColor, radius: Float) -> Entity {
        let vector = b - a
        let length = simd_length(vector)
        let entity = ModelEntity(mesh: .generateCylinder(height: max(length, 0.01), radius: radius), materials: [UnlitMaterial(color: color)])
        entity.position = (a + b) / 2
        if length > 0.0001 {
            entity.orientation = simd_quatf(from: [0, 1, 0], to: simd_normalize(vector))
        }
        return entity
    }

    static func color(for state: RunState) -> NSColor {
        switch state {
        case .running, .pending: return .controlAccentColor
        case .succeeded: return .systemGreen
        case .partiallySucceeded: return .systemOrange
        case .failed: return .systemRed
        case .skipped, .canceled: return .systemGray
        }
    }

    func nodeID(for entity: Entity) -> UUID? {
        var current: Entity? = entity
        while let node = current {
            if node.name.hasPrefix("node:") { return UUID(uuidString: String(node.name.dropFirst(5))) }
            current = node.parent
        }
        return nil
    }

    // MARK: Camera

    func orbit(dx: Float, dy: Float) {
        yaw -= dx * 0.008
        pitch = min(max(pitch + dy * 0.006, -1.2), 1.2)
        applyCamera()
    }

    func zoom(by factor: Float) {
        guard factor.isFinite, factor > 0 else { return }
        distance = min(max(distance / factor, 3), 60)
        applyCamera()
    }

    func resetView() {
        yaw = 0.3
        pitch = 0.25
        hasFramed = false
        applyCamera()
    }

    private func frame(_ steps: [WorkflowStep]) {
        let points = steps.map(position(of:))
        let minPoint = points.reduce(points[0]) { simd_min($0, $1) }
        let maxPoint = points.reduce(points[0]) { simd_max($0, $1) }
        target = (minPoint + maxPoint) / 2
        distance = min(max(simd_length(maxPoint - minPoint) * 1.1 + 4, 6), 50)
        applyCamera()
    }

    private func applyCamera() {
        let offset = SIMD3<Float>(cos(pitch) * sin(yaw), sin(pitch), cos(pitch) * cos(yaw)) * distance
        camera.look(at: target, from: target + offset, relativeTo: nil)
    }
}

/// Whether the hosting window is actually on screen (not minimized,
/// covered or on another desktop), so 3D rendering can stop.
struct OcclusionReader: NSViewRepresentable {
    @Binding var isVisible: Bool

    func makeNSView(context: Context) -> ObservingView {
        let view = ObservingView()
        view.onChange = { visible in if isVisible != visible { isVisible = visible } }
        return view
    }

    func updateNSView(_ nsView: ObservingView, context: Context) {
        nsView.onChange = { visible in if isVisible != visible { isVisible = visible } }
    }

    final class ObservingView: NSView {
        var onChange: ((Bool) -> Void)?
        private var observer: NSObjectProtocol?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
            guard let window else { return }
            observer = NotificationCenter.default.addObserver(
                forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main
            ) { [weak self] _ in MainActor.assumeIsolated { self?.report() } }
            report()
        }

        private func report() {
            let visible = window?.occlusionState.contains(.visible) ?? false
            DispatchQueue.main.async { [onChange] in onChange?(visible) }
        }

        deinit {
            if let observer { NotificationCenter.default.removeObserver(observer) }
        }
    }
}
