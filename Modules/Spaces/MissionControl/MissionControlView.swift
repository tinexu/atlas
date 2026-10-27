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

    @State private var scene = MissionControlScene()
    @State private var isWindowVisible = true
    @State private var isHovering = false
    @State private var lastDrag: CGSize = .zero
    @State private var lastMagnification: CGFloat = 1
    @State private var scrollMonitor: Any?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(
        rooms: [RoomSnapshot],
        selection: UUID?,
        onSelect: @escaping (UUID) -> Void,
        onActivate: @escaping (UUID) -> Void,
        onObject: @escaping (SpaceObject) -> Void
    ) {
        self.rooms = rooms
        self.selection = selection
        self.onSelect = onSelect
        self.onActivate = onActivate
        self.onObject = onObject
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
        RealityView { content in
            content.camera = .virtual
            // After a pause the old view may still hold the scene; take it back first.
            scene.root.removeFromParent()
            content.add(scene.root)
        } update: { _ in
            scene.sync(rooms: rooms, selection: selection, reduceMotion: reduceMotion)
        }
        .gesture(taps)
        .simultaneousGesture(orbitDrag)
        .simultaneousGesture(pinch)
        .onHover { isHovering = $0 }
        .onAppear(perform: installScrollMonitor)
        .onDisappear(perform: removeScrollMonitor)
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
                    case .object(_, let room): roomID = room
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
                    case nil:
                        break
                    }
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
    }
}
