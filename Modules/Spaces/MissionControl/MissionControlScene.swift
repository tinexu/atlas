import AppKit
import AtlasSpaces
import RealityKit

/// Owns the RealityKit world for Mission Control: rooms, group labels, one
/// light and the camera. Rebuilds only rooms whose geometry changed; status
/// and selection changes just flip indicators. Nothing here animates while
/// idle, so a still world costs next to nothing to show.
@MainActor
final class MissionControlScene {
    let root = Entity()
    private let world = Entity()
    private let camera = PerspectiveCamera()
    private let labels = Entity()

    private(set) var orbit = OrbitCamera(target: .zero, yaw: 0, pitch: 0.62, distance: 10)
    private var home = OrbitCamera(target: .zero, yaw: 0, pitch: 0.62, distance: 10)
    private var rooms: [UUID: (geometry: RoomSnapshot.Geometry, entity: Entity)] = [:]
    private var positions: [UUID: SIMD3<Float>] = [:]
    private var rowSignature: [String] = []
    private var cameraAnimation: AnimationPlaybackController?
    private var focusedSpaceID: UUID?
    private var hasFramedWorld = false

    init() {
        camera.camera.fieldOfViewInDegrees = 45
        root.addChild(camera)
        root.addChild(world)
        root.addChild(labels)

        // One shadowless directional light keeps every material readable at
        // a fixed, small cost.
        let sun = DirectionalLight()
        sun.light.intensity = 2_600
        sun.look(at: .zero, from: [-3, 8, 6], relativeTo: nil)
        root.addChild(sun)

        let ground = ModelEntity(
            mesh: .generatePlane(width: 200, depth: 200),
            materials: [UnlitMaterial(color: NSColor(atlasHex: "#141821"))]
        )
        ground.position = [0, -0.1, 0]
        root.addChild(ground)

        applyCamera(animated: false)
    }

    // MARK: - Sync

    func sync(rooms snapshots: [RoomSnapshot], selection: UUID?, reduceMotion: Bool) {
        let layout = WorldLayout.layout(snapshots)
        let present = Set(snapshots.map(\.id))

        for (id, entry) in rooms where !present.contains(id) {
            entry.entity.removeFromParent()
            rooms[id] = nil
        }

        for snapshot in snapshots {
            let entity: Entity
            if let existing = rooms[snapshot.id], existing.geometry == snapshot.geometry {
                entity = existing.entity
            } else {
                rooms[snapshot.id]?.entity.removeFromParent()
                entity = RoomBuilder.build(space: snapshot.space, room: snapshot.room, objects: snapshot.objects)
                world.addChild(entity)
                rooms[snapshot.id] = (snapshot.geometry, entity)
            }
            if let position = layout.positions[snapshot.id], entity.position != position {
                entity.position = position
            }
            RoomBuilder.apply(
                status: Self.color(for: snapshot.status),
                isSelected: snapshot.id == selection,
                isActive: snapshot.isActive,
                to: entity
            )
        }
        positions = layout.positions

        let signature = layout.rows.map { "\($0.group.rawValue)@\($0.z),\($0.labelX)" }
        if signature != rowSignature {
            rowSignature = signature
            rebuildLabels(layout.rows)
        }

        let newHome = OrbitCamera.overview(min: layout.min, max: layout.max)
        if newHome != home || newHome.bounds != home.bounds {
            home = newHome
            orbit.bounds = home.bounds
            orbit.distanceRange = home.distanceRange
            orbit.clamp()
        }
        if !hasFramedWorld, !snapshots.isEmpty {
            hasFramedWorld = true
            orbit = home
            applyCamera(animated: false)
        }

        if selection != focusedSpaceID {
            focusedSpaceID = selection
            if let selection, let position = positions[selection] {
                orbit.focus(on: position, distance: 5.2)
                applyCamera(animated: !reduceMotion)
            }
        }
    }

    // MARK: - Camera

    func orbit(dx: Float, dy: Float) {
        orbit.orbit(dx: dx, dy: dy)
        applyCamera(animated: false)
    }

    func zoom(by factor: Float) {
        orbit.zoom(by: factor)
        applyCamera(animated: false)
    }

    func resetView(reduceMotion: Bool) {
        orbit = home
        applyCamera(animated: !reduceMotion)
    }

    /// Camera moves never block anything: activation has already started
    /// by the time a fly-to begins, and the move runs on RealityKit's clock.
    private func applyCamera(animated: Bool) {
        cameraAnimation?.stop()
        cameraAnimation = nil
        if animated {
            cameraAnimation = camera.move(to: orbit.transform, relativeTo: nil, duration: 0.6, timingFunction: .easeInOut)
        } else {
            camera.transform = orbit.transform
        }
    }

    // MARK: - Picking

    enum Hit {
        case room(UUID)
        case object(UUID, room: UUID)
    }

    /// Resolves a clicked entity (possibly a deep child) to a room or object.
    func hit(for entity: Entity) -> Hit? {
        var current: Entity? = entity
        var objectID: UUID?
        while let node = current {
            if objectID == nil, let id = Self.id(in: node.name, prefix: "object:") {
                objectID = id
            }
            if let roomID = Self.id(in: node.name, prefix: "room:") {
                if let objectID { return .object(objectID, room: roomID) }
                return .room(roomID)
            }
            current = node.parent
        }
        return nil
    }

    private static func id(in name: String, prefix: String) -> UUID? {
        guard name.hasPrefix(prefix) else { return nil }
        return UUID(uuidString: String(name.dropFirst(prefix.count)))
    }

    // MARK: - Labels & colours

    private func rebuildLabels(_ rows: [WorldLayout.Row]) {
        labels.children.removeAll()
        for row in rows {
            let mesh = MeshResource.generateText(
                row.group.rawValue.uppercased(),
                extrusionDepth: 0.005,
                font: .systemFont(ofSize: 0.26, weight: .bold)
            )
            let text = ModelEntity(mesh: mesh, materials: [UnlitMaterial(color: NSColor(white: 1, alpha: 1).withAlphaComponent(0.7))])
            let holder = Entity()
            holder.position = [row.labelX, 0.02, row.z + 0.4]
            holder.orientation = simd_quatf(angle: -.pi / 3, axis: [1, 0, 0])
            text.position = [-mesh.bounds.max.x, 0, 0]
            holder.addChild(text)
            labels.addChild(holder)
        }
    }

    static func color(for status: SpaceStatus) -> NSColor {
        switch status {
        case .inactive: return NSColor(white: 0.55, alpha: 1)
        case .activating: return .systemBlue
        case .ready: return .systemGreen
        case .partiallyReady: return .systemOrange
        case .failed: return .systemRed
        }
    }
}
