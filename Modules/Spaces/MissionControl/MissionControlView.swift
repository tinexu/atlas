import AppKit
import AtlasSpaces
import RealityKit
import SwiftUI

/// The 3D overview of every Space. Presentation only: it reports clicks
/// through callbacks and never activates or runs anything itself, so
/// everything here is also reachable from the list view.
///
/// Rendering stops whenever the RealityView isn't on screen: the view is
/// removed when its window is occluded or minimized, and when the Spaces
/// section or the list view is showing instead.
public struct MissionControlView: View {
    let rooms: [RoomSnapshot]
    let selection: UUID?
    let onSelect: (UUID) -> Void
    let onActivate: (UUID) -> Void
    let onObject: (SpaceObject) -> Void
    /// A course's book was clicked (Study Library).
    let onCourse: (UUID) -> Void
    /// A Study Library item was clicked, or (`true`) long-pressed / right-clicked for its options.
    let onItem: (StudyRoomState.Item, Bool) -> Void
    /// A room object was long-pressed or right-clicked (the easel's project switcher).
    let onObjectOptions: (SpaceObject) -> Void
    /// A Creative Studio item was clicked (a paint jar, a gallery frame).
    let onCreativeItem: (CreativeRoomState.Item) -> Void

    @State private var scene = MissionControlScene()
    @State private var isWindowVisible = true
    @State private var isHovering = false
    @State private var hoverLabel: (text: String, point: CGPoint)?
    @State private var lastDrag: CGSize = .zero
    @State private var lastMagnification: CGFloat = 1
    @State private var scrollMonitor: Any?
    @State private var rightClickMonitor: Any?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(
        rooms: [RoomSnapshot],
        selection: UUID?,
        onSelect: @escaping (UUID) -> Void,
        onActivate: @escaping (UUID) -> Void,
        onObject: @escaping (SpaceObject) -> Void,
        onCourse: @escaping (UUID) -> Void = { _ in },
        onItem: @escaping (StudyRoomState.Item, Bool) -> Void = { _, _ in },
        onObjectOptions: @escaping (SpaceObject) -> Void = { _ in },
        onCreativeItem: @escaping (CreativeRoomState.Item) -> Void = { _ in }
    ) {
        self.rooms = rooms
        self.selection = selection
        self.onSelect = onSelect
        self.onActivate = onActivate
        self.onObject = onObject
        self.onCourse = onCourse
        self.onItem = onItem
        self.onObjectOptions = onObjectOptions
        self.onCreativeItem = onCreativeItem
    }

    public var body: some View {
        ZStack(alignment: .bottomLeading) {
            Color(nsColor: NSColor(atlasHex: "#141821"))

            if isWindowVisible {
                world
            } else {
                Label("3D paused while ATLAS is in the background (saves battery)", systemImage: "pause.circle")
                    .foregroundStyle(.white.opacity(0.7))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            HStack(spacing: 8) {
                Button {
                    scene.resetView(reduceMotion: reduceMotion)
                } label: {
                    Label("Reset View", systemImage: "scope")
                }
                Text("Drag to orbit · scroll or pinch to zoom · double-click a room to activate")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.6))
            }
            .padding(10)
        }
        .background(WindowVisibilityReader(isVisible: $isWindowVisible))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("3D view of your Spaces. Every action here is also available in the list view.")
    }

    private var world: some View {
        GeometryReader { proxy in
            RealityView { content in
                content.camera = .virtual
                // After a pause the old view may still hold the scene; take it back first.
                scene.root.removeFromParent()
                content.add(scene.root)
            } update: { _ in
                scene.sync(rooms: rooms, selection: selection, reduceMotion: reduceMotion)
            }
            .gesture(taps)
            .simultaneousGesture(longPress)
            .simultaneousGesture(orbitDrag)
            .simultaneousGesture(pinch)
            .onContinuousHover(coordinateSpace: .local) { phase in
                switch phase {
                case .active(let point):
                    hover(at: point, in: proxy.size)
                case .ended:
                    hover(at: nil, in: proxy.size)
                }
            }
            .overlay(alignment: .topLeading) {
                if let hoverLabel {
                    Text(hoverLabel.text)
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .multilineTextAlignment(.leading)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                        .fixedSize()
                        .position(x: hoverLabel.point.x, y: max(20, hoverLabel.point.y - 30))
                        .allowsHitTesting(false)
                }
            }
        }
        .onHover { isHovering = $0 }
        .onAppear(perform: installScrollMonitor)
        .onDisappear(perform: removeScrollMonitor)
    }

    private func object(_ id: UUID, in roomID: UUID) -> SpaceObject? {
        rooms.first(where: { $0.id == roomID })?.objects.first(where: { $0.id == id })
    }

    /// Lifts and outlines the object under the pointer and names it.
    private func hover(at point: CGPoint?, in size: CGSize) {
        guard let point, lastDrag == .zero, let hit = scene.hover(at: point, in: size, reduceMotion: reduceMotion) else {
            _ = scene.hover(at: nil, in: size, reduceMotion: reduceMotion)
            hoverLabel = nil
            return
        }
        switch hit {
        case .object(let objectID, let roomID):
            guard let object = rooms.first(where: { $0.id == roomID })?.objects.first(where: { $0.id == objectID }) else {
                hoverLabel = nil
                return
            }
            let study = rooms.first(where: { $0.id == roomID })?.study
            switch (object.kind, study) {
            case (.clock, let study?) where !study.deskCalendar.detail.isEmpty:
                hoverLabel = (study.deskCalendar.detail, point)
            case (.chalkboard, let study?):
                let count = study.board.rows.count + study.board.more
                hoverLabel = (count == 0 ? "Nothing due this week · click for all assignments"
                              : "\(count) due this week · click for all assignments", point)
            default:
                let creative = rooms.first(where: { $0.id == roomID })?.creative?.detail(for: object.kind)
                hoverLabel = (creative ?? object.label.flatMap { $0.isEmpty ? nil : $0 } ?? object.kind.title, point)
            }
        case .course(let courseID, let roomID):
            let book = rooms.first(where: { $0.id == roomID })?.study?.books.first(where: { $0.id == courseID })
            hoverLabel = book.map { ($0.detail, point) }
        case .item(let item, let roomID):
            guard let study = rooms.first(where: { $0.id == roomID })?.study else { hoverLabel = nil; return }
            hoverLabel = study.detail(for: item).flatMap { $0.isEmpty ? nil : ($0, point) }
        case .creative(let item, let roomID):
            hoverLabel = rooms.first(where: { $0.id == roomID })?.creative?.detail(for: item).map { ($0, point) }
        case .room:
            hoverLabel = nil
        }
    }

    // MARK: - Gestures

    /// Double-click activates; a single click selects, or runs an object's
    /// assigned action. Double-click is tried first so a double-click never
    /// also runs an object's action twice.
    private var taps: some Gesture {
        SpatialTapGesture(count: 2).targetedToAnyEntity()
            .exclusively(before: SpatialTapGesture(count: 1).targetedToAnyEntity())
            .onEnded { value in
                switch value {
                case .first(let double):
                    guard let hit = scene.hit(for: double.entity) else { return }
                    let roomID: UUID
                    switch hit {
                    case .room(let id): roomID = id
                    case .object(_, let room), .course(_, let room), .item(_, let room), .creative(_, let room): roomID = room
                    }
                    // Activation first; the fly-to triggered by selecting
                    // runs alongside it.
                    onActivate(roomID)
                    onSelect(roomID)
                case .second(let single):
                    switch scene.hit(for: single.entity) {
                    case .room(let id):
                        onSelect(id)
                    case .object(let objectID, let roomID):
                        onSelect(roomID)
                        if let object = rooms.first(where: { $0.id == roomID })?.objects.first(where: { $0.id == objectID }) {
                            onObject(object)
                        }
                    case .course(let courseID, let roomID):
                        onSelect(roomID)
                        onCourse(courseID)
                    case .item(let item, let roomID):
                        onSelect(roomID)
                        onItem(item, false)
                    case .creative(let item, let roomID):
                        onSelect(roomID)
                        onCreativeItem(item)
                    case nil:
                        break
                    }
                }
            }
    }

    /// Long-press (or right-click) the hourglass for its options.
    private var longPress: some Gesture {
        LongPressGesture(minimumDuration: 0.5).targetedToAnyEntity()
            .onEnded { value in
                switch scene.hit(for: value.entity) {
                case .item(let item, _): onItem(item, true)
                case .object(let objectID, let roomID): object(objectID, in: roomID).map(onObjectOptions)
                default: break
                }
            }
    }

    private var orbitDrag: some Gesture {
        DragGesture(minimumDistance: 3)
            .onChanged { value in
                let dx = Float(value.translation.width - lastDrag.width)
                let dy = Float(value.translation.height - lastDrag.height)
                lastDrag = value.translation
                scene.orbit(dx: dx, dy: dy)
            }
            .onEnded { _ in lastDrag = .zero }
    }

    private var pinch: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                let factor = value.magnification / lastMagnification
                lastMagnification = value.magnification
                scene.zoom(by: Float(factor))
            }
            .onEnded { _ in lastMagnification = 1 }
    }

    /// SwiftUI has no scroll-wheel gesture on macOS, so listen locally while
    /// the pointer is over the world and leave every other scroll alone.
    private func installScrollMonitor() {
        guard scrollMonitor == nil else { return }
        rightClickMonitor = NSEvent.addLocalMonitorForEvents(matching: .rightMouseDown) { event in
            guard isHovering else { return event }
            switch scene.hoveredHit {
            case .item(let item, _)?:
                onItem(item, true)
            case .object(let objectID, let roomID)?:
                guard let object = object(objectID, in: roomID) else { return event }
                onObjectOptions(object)
            default:
                return event
            }
            return nil
        }
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            guard isHovering else { return event }
            let delta = Float(event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.scrollingDeltaY * 8)
            scene.zoom(by: exp(delta * 0.01))
            return nil
        }
    }

    private func removeScrollMonitor() {
        if let scrollMonitor { NSEvent.removeMonitor(scrollMonitor) }
        scrollMonitor = nil
        if let rightClickMonitor { NSEvent.removeMonitor(rightClickMonitor) }
        rightClickMonitor = nil
    }
}
