import AppKit
import AtlasCore
import RealityKit
import SwiftUI

/// The 3D timeline: one ribbon per day running back into space, today in
/// front and the rest of the week fading into the distance. Blocks are
/// solid shapes as long as they last; a glowing line marks now. Click a
/// block to inspect it, drag it to reschedule, drag an end to resize, or
/// drop a Space onto today's ribbon. Everything here also works in the Day,
/// Week and Agenda views.
struct TimelineRibbonView: View {
    @ObservedObject var model: TimeArchitectModel
    @State private var scene = TimelineScene()
    @State private var isVisible = true
    @State private var dragStart: (id: String, isEnd: Bool)?
    @State private var dragMinutes: Double = 0
    @State private var viewWidth: CGFloat = 900
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .bottomLeading) {
                Color(nsColor: NSColor(red: 0.03, green: 0.04, blue: 0.09, alpha: 1))
                if isVisible {
                    realityView
                } else {
                    Label("3D paused while ATLAS is in the background (saves battery)", systemImage: "pause.circle")
                        .foregroundStyle(.white.opacity(0.7)).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                HStack(spacing: 12) {
                    Text("Click to inspect · drag to move · drag an end to resize · drop a Space onto today")
                    Spacer()
                    if dragStart != nil, dragMinutes != 0 {
                        Text("\(dragMinutes > 0 ? "+" : "")\(Int(dragMinutes)) min").monospacedDigit()
                    }
                }
                .font(.caption)
                .foregroundStyle(.white.opacity(0.65))
                .padding(10)
            }
            .onAppear { viewWidth = geometry.size.width }
            .onChange(of: geometry.size.width) { _, width in viewWidth = width }
            .dropDestination(for: String.self) { items, location in
                guard let item = items.first, item.hasPrefix("space:"), let id = UUID(uuidString: String(item.dropFirst(6))) else { return false }
                // Today's ribbon, front and centre: map the drop's x to a time.
                let hours = TimelineScene.centerHour + Double((location.x - geometry.size.width / 2) * unitsPerPoint)
                let start = Calendar.current.startOfDay(for: Date()).addingTimeInterval(max(0, min(23.75, hours)) * 3_600)
                model.create(at: start, minutes: Double(model.time.focus.settings.minutes(forSpace: id)), spaceID: id)
                return true
            }
        }
        .background(TimelineVisibilityReader(isVisible: $isVisible))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("3D timeline of your week. The Day, Week and Agenda views show the same blocks as lists.")
    }

    /// Scene units (hours) per screen point, roughly, at today's ribbon.
    private var unitsPerPoint: CGFloat { TimelineScene.visibleHours / max(viewWidth, 1) }

    private var realityView: some View {
        let snapshot = TimelineSnapshot(model: model)
        return RealityView { content in
            content.camera = .virtual
            scene.root.removeFromParent()
            content.add(scene.root)
        } update: { _ in
            scene.sync(snapshot, reduceMotion: reduceMotion)
        }
        .gesture(
            SpatialTapGesture().targetedToAnyEntity().onEnded { value in
                if let id = scene.identifier(for: value.entity) { model.selectedID = id.occurrence }
            }
        )
        .simultaneousGesture(
            DragGesture(minimumDistance: 4).targetedToAnyEntity()
                .onChanged { value in
                    guard let id = scene.identifier(for: value.entity) else { return }
                    if dragStart == nil { dragStart = (id.occurrence, id.isEnd) }
                    dragMinutes = (Double(value.translation.width * unitsPerPoint) * 60 / 15).rounded() * 15
                    scene.preview(id.occurrence, isEnd: id.isEnd, minutes: dragMinutes)
                }
                .onEnded { _ in
                    defer {
                        dragStart = nil
                        dragMinutes = 0
                    }
                    guard let start = dragStart, let occurrence = model.occurrences.first(where: { $0.id == start.id }) else { return }
                    model.selectedID = occurrence.id
                    if dragMinutes != 0 { model.move(occurrence, minutes: dragMinutes, resize: start.isEnd) } else { scene.preview(start.id, isEnd: false, minutes: 0) }
                }
        )
    }
}

/// What the scene draws, worked out on the main actor.
struct TimelineSnapshot: Equatable {
    struct Item: Equatable {
        let id: String
        let title: String
        let day: Int
        let lane: Int
        let startHour: Double
        let endHour: Double
        let color: NSColor
        let isExternal: Bool
        let isDimmed: Bool
        let isConflicted: Bool
        let isSelected: Bool
    }

    let items: [Item]
    let dayLabels: [String]
    let laneCount: Int
    let nowHour: Double?
    let signature: String

    @MainActor
    init(model: TimeArchitectModel) {
        let calendar = Calendar.current
        let days = model.days
        let lanes = model.laneNames
        var items: [Item] = []
        for (dayIndex, day) in days.enumerated() {
            for occurrence in model.occurrences(on: day) {
                let start = max(occurrence.start, day), end = min(occurrence.end, day.addingTimeInterval(86_400))
                let state = model.time.schedule.state(of: occurrence).state
                items.append(Item(id: occurrence.id, title: occurrence.block.title, day: dayIndex,
                                  lane: lanes.firstIndex(of: model.lane(for: occurrence.block)) ?? 0,
                                  startHour: start.timeIntervalSince(day) / 3_600, endHour: end.timeIntervalSince(day) / 3_600,
                                  color: NSColor(model.color(for: occurrence.block)), isExternal: occurrence.block.isExternal,
                                  isDimmed: state == .missed || state == .skipped, isConflicted: model.isConflicted(occurrence),
                                  isSelected: model.selectedID == occurrence.id))
            }
        }
        self.items = items
        dayLabels = days.map { calendar.isDateInToday($0) ? "Today" : $0.formatted(.dateTime.weekday(.abbreviated).day()) }
        laneCount = max(1, lanes.count)
        let _ = model.revision
        nowHour = days.first.map { calendar.isDateInToday($0) } == true ? Date().timeIntervalSince(calendar.startOfDay(for: Date())) / 3_600 : nil
        signature = items.map { "\($0.id)\($0.startHour)\($0.endHour)\($0.isSelected)\($0.isConflicted)\($0.isDimmed)\($0.lane)" }.joined()
            + dayLabels.joined() + "\(laneCount)"
    }

    static func == (a: TimelineSnapshot, b: TimelineSnapshot) -> Bool { a.signature == b.signature && a.nowHour == b.nowHour }
}

@MainActor
final class TimelineScene {
    static let centerHour = 14.0
    static let visibleHours: CGFloat = 20
    static let dayDepth: Float = 3.2

    let root = Entity()
    private let camera = PerspectiveCamera()
    private let content = Entity()
    private var nowLine: ModelEntity?
    private var lastSignature = ""
    private var blocks: [String: Entity] = [:]
    private var originals: [String: Transform] = [:]
    private var endHandles: [String: Entity] = [:]
    private var pulse: AnimationPlaybackController?

    init() {
        camera.camera.fieldOfViewInDegrees = 50
        camera.look(at: [0, 0, -5], from: [0, 7.5, 9.5], relativeTo: nil)
        root.addChild(camera)
        let light = DirectionalLight()
        light.light.intensity = 2_800
        light.look(at: .zero, from: [-4, 10, 6], relativeTo: nil)
        root.addChild(light)
        root.addChild(content)
    }

    static func x(_ hour: Double) -> Float { Float(hour - centerHour) }

    func sync(_ snapshot: TimelineSnapshot, reduceMotion: Bool) {
        if snapshot.signature != lastSignature {
            lastSignature = snapshot.signature
            rebuild(snapshot)
        }
        updateNow(snapshot.nowHour, reduceMotion: reduceMotion)
    }

    private func rebuild(_ snapshot: TimelineSnapshot) {
        content.children.removeAll()
        blocks = [:]
        originals = [:]
        endHandles = [:]
        nowLine = nil
        pulse = nil
        let laneDepth = 2.2 / Float(snapshot.laneCount)
        for (index, label) in snapshot.dayLabels.enumerated() {
            let z = -Float(index) * Self.dayDepth
            let fade = max(0.18, 1 - Float(index) * 0.13)
            // The ribbon.
            let ribbon = ModelEntity(mesh: .generateBox(width: 24, height: 0.04, depth: 2.4, cornerRadius: 0.02),
                                     materials: [UnlitMaterial(color: NSColor(white: 0.16 + (index == 0 ? 0.06 : 0), alpha: 1))])
            ribbon.position = [0, 0, z]
            ribbon.components.set(OpacityComponent(opacity: fade))
            content.addChild(ribbon)
            content.addChild(text(label, size: 0.42, at: [-12.8, 0.05, z + 0.2], color: NSColor(white: 1, alpha: CGFloat(fade))))
            // Hour ticks on today's ribbon.
            if index == 0 {
                for hour in stride(from: 6, through: 24, by: 3) {
                    let tick = ModelEntity(mesh: .generateBox(width: 0.02, height: 0.02, depth: 2.4), materials: [UnlitMaterial(color: NSColor(white: 0.4, alpha: 1))])
                    tick.position = [Self.x(Double(hour)), 0.03, z]
                    content.addChild(tick)
                    let date = Calendar.current.date(bySettingHour: hour % 24, minute: 0, second: 0, of: Date()) ?? Date()
                    content.addChild(text(date.formatted(.dateTime.hour()), size: 0.3, at: [Self.x(Double(hour)) - 0.3, 0.05, z + 1.5]))
                }
            }
        }
        for item in snapshot.items {
            let fade: Float = max(0.2, 1 - Float(item.day) * 0.13) * (item.isDimmed ? 0.4 : 1) * (item.isExternal ? 0.7 : 1)
            let length = max(0.15, Float(item.endHour - item.startHour))
            let z = -Float(item.day) * Self.dayDepth - 1.1 + laneDepth * (Float(item.lane) + 0.5)
            let container = Entity()
            container.name = "block:\(item.id)"
            container.position = [Self.x((item.startHour + item.endHour) / 2), 0.25, z]
            let body = ModelEntity(mesh: .generateBox(width: length, height: item.isExternal ? 0.2 : 0.4, depth: laneDepth * 0.8, cornerRadius: 0.06),
                                   materials: [SimpleMaterial(color: item.color, roughness: 0.4, isMetallic: false)])
            body.components.set(OpacityComponent(opacity: fade))
            container.addChild(body)
            if item.isConflicted || item.isSelected {
                let outline = ModelEntity(mesh: .generateBox(width: length + 0.12, height: 0.06, depth: laneDepth * 0.8 + 0.12),
                                          materials: [UnlitMaterial(color: item.isConflicted ? .systemRed : .white)])
                outline.position = [0, -0.2, 0]
                container.addChild(outline)
            }
            if item.isSelected || item.day == 0 {
                container.addChild(text(item.title, size: 0.24, at: [-length / 2, 0.3, 0]))
            }
            container.components.set(CollisionComponent(shapes: [.generateBox(width: length, height: 0.5, depth: laneDepth * 0.8)]))
            container.components.set(InputTargetComponent())
            content.addChild(container)
            blocks[item.id] = container
            originals[item.id] = container.transform
            if !item.isExternal {
                let handle = ModelEntity(mesh: .generateSphere(radius: 0.12), materials: [UnlitMaterial(color: NSColor(white: 1, alpha: 0.85))])
                handle.name = "end:\(item.id)"
                handle.position = container.position + [length / 2, 0.05, 0]
                handle.components.set(CollisionComponent(shapes: [.generateSphere(radius: 0.22)]))
                handle.components.set(InputTargetComponent())
                content.addChild(handle)
                endHandles[item.id] = handle
            }
        }
    }

    private func updateNow(_ hour: Double?, reduceMotion: Bool) {
        guard let hour else {
            nowLine?.removeFromParent()
            nowLine = nil
            return
        }
        if nowLine == nil {
            let line = ModelEntity(mesh: .generateBox(width: 0.05, height: 1.0, depth: 2.6), materials: [UnlitMaterial(color: .systemRed)])
            content.addChild(line)
            nowLine = line
            if !reduceMotion, let resource = try? AnimationResource.generate(with: FromToByAnimation<Float>(
                from: 1, to: 0.45, duration: 1.2, timing: .easeInOut, bindTarget: .opacity, repeatMode: .autoReverse)) {
                line.components.set(OpacityComponent(opacity: 1))
                pulse = line.playAnimation(resource)
            }
        }
        nowLine?.position = [Self.x(hour), 0.5, 0]
    }

    /// Shows a drag before it's committed.
    func preview(_ id: String, isEnd: Bool, minutes: Double) {
        guard let block = blocks[id], var transform = originals[id] else { return }
        let offset = Float(minutes / 60)
        if isEnd {
            if let body = block.children.first {
                let width = body.visualBounds(relativeTo: block).extents.x
                let scale = max(0.1, (width + offset) / max(width, 0.01))
                transform.scale = [scale, 1, 1]
                transform.translation.x += offset / 2
            }
            if let handle = endHandles[id], let original = originals[id] {
                let width = (block.children.first?.visualBounds(relativeTo: block).extents.x ?? 0)
                handle.position = original.translation + [width / 2 + offset, 0.05, 0]
            }
        } else {
            transform.translation.x += offset
        }
        block.transform = transform
    }

    /// "block:<occurrence>" or "end:<occurrence>".
    func identifier(for entity: Entity) -> (occurrence: String, isEnd: Bool)? {
        var current: Entity? = entity
        while let node = current {
            if node.name.hasPrefix("block:") { return (String(node.name.dropFirst(6)), false) }
            if node.name.hasPrefix("end:") { return (String(node.name.dropFirst(4)), true) }
            current = node.parent
        }
        return nil
    }

    private func text(_ string: String, size: CGFloat, at position: SIMD3<Float>, color: NSColor = NSColor(white: 1, alpha: 0.85)) -> ModelEntity {
        let mesh = MeshResource.generateText(String(string.prefix(28)), extrusionDepth: 0.002, font: .systemFont(ofSize: size, weight: .medium))
        let entity = ModelEntity(mesh: mesh, materials: [UnlitMaterial(color: color)])
        entity.position = position
        entity.orientation = simd_quatf(angle: -.pi / 2.6, axis: [1, 0, 0])
        return entity
    }
}

/// Stops 3D rendering while the window is hidden.
struct TimelineVisibilityReader: NSViewRepresentable {
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
            observer = NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.report() }
            }
            report()
        }

        /// Low Power Mode and switching apps change whether 3D draws.
        private lazy var powerObserver: [NSObjectProtocol] = [
            NSNotification.Name.NSProcessInfoPowerStateDidChange, NSApplication.didBecomeActiveNotification,
            NSApplication.didResignActiveNotification,
        ].map { name in
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.report() }
            }
        }

        private func report() {
            _ = powerObserver
            // A RealityKit view redraws every frame, so 3D only draws while
            // it's on screen, ATLAS is the app in front, and Low Power Mode is off.
            let visible = RenderPolicy.shouldDraw(windowVisible: window?.occlusionState.contains(.visible) ?? false,
                                                  appActive: NSApp.isActive, lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled)
            DispatchQueue.main.async { [onChange] in onChange?(visible) }
        }

        deinit {
            if let observer { NotificationCenter.default.removeObserver(observer) }
            powerObserver.forEach(NotificationCenter.default.removeObserver)
        }
    }
}
