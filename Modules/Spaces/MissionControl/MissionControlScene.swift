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
    /// What a room was built from; a change rebuilds it.
    private struct BuildKey: Equatable {
        var geometry: RoomSnapshot.Geometry
        var detail: Bool
        var reduceMotion: Bool
    }

    private var rooms: [UUID: (key: BuildKey, entity: Entity)] = [:]
    private var activeRooms: Set<UUID> = []
    private var hovered: Entity?
    /// The RealityKit scene room motion is attached to; a new one after a pause.
    private weak var attachedScene: RealityKit.Scene?
    private var positions: [UUID: SIMD3<Float>] = [:]
    private var rowSignature: [String] = []
    private var cameraAnimation: AnimationPlaybackController?
    private var focusedSpaceID: UUID?
    private var hasFramedWorld = false

    init() {
        RoomMotionComponent.registerComponent()
        RoomBuilder.HoverComponent.registerComponent()
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
            // Hand-built rooms are detailed only when selected (and the camera
            // is close); other rooms have a single level of detail.
            let levels = RoomBuilder.hasDetailLevels(snapshot.space.templateID)
            let key = BuildKey(geometry: snapshot.geometry, detail: !levels || snapshot.id == selection,
                               reduceMotion: levels && reduceMotion)
            let entity: Entity
            if let existing = rooms[snapshot.id], existing.key == key {
                entity = existing.entity
            } else {
                if let old = rooms[snapshot.id]?.entity {
                    old.components[RoomMotionComponent.self]?.motion.stop()
                    old.removeFromParent()
                    if let hovered, sequence(first: hovered, next: \.parent).contains(where: { $0 === old }) { self.hovered = nil }
                }
                entity = RoomBuilder.build(space: snapshot.space, room: snapshot.room, objects: snapshot.objects,
                                           detail: key.detail, reduceMotion: reduceMotion)
                world.addChild(entity)
                if let motion = entity.components[RoomMotionComponent.self]?.motion {
                    motion.start()
                    if let scene = root.scene { motion.attach(to: scene) }
                    motion.setActive(snapshot.isActive, animated: false)
                }
                rooms[snapshot.id] = (key, entity)
            }
            if snapshot.isActive != activeRooms.contains(snapshot.id) {
                // Only a change animates, not a room that was already active.
                entity.components[RoomMotionComponent.self]?.motion.setActive(snapshot.isActive, animated: hasFramedWorld)
                if snapshot.isActive { activeRooms.insert(snapshot.id) } else { activeRooms.remove(snapshot.id) }
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
        if let scene = root.scene, scene !== attachedScene {
            attachedScene = scene
            for entry in rooms.values {
                entry.entity.components[RoomMotionComponent.self]?.motion.attach(to: scene)
            }
        }
        activeRooms.formIntersection(present)

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

    /// Highlights the object under the pointer (`point` in view coordinates,
    /// nil when the pointer leaves) and returns it. Rays are cast from the
    /// camera by hand, since RealityView on macOS has no hit test.
    func hover(at point: CGPoint?, in size: CGSize, reduceMotion: Bool) -> (object: UUID, room: UUID)? {
        var target: Entity?
        var result: (UUID, UUID)?
        if let point, size.width > 0, size.height > 0, let scene = root.scene {
            let tanHalf = tan(camera.camera.fieldOfViewInDegrees * .pi / 360)
            let aspect = Float(size.width / size.height)
            let local = SIMD3<Float>(
                (2 * Float(point.x / size.width) - 1) * tanHalf * aspect,
                (1 - 2 * Float(point.y / size.height)) * tanHalf,
                -1
            )
            let matrix = camera.transformMatrix(relativeTo: nil)
            let direction = simd_normalize(SIMD3(
                simd_dot(SIMD3(matrix.columns.0.x, matrix.columns.1.x, matrix.columns.2.x), local),
                simd_dot(SIMD3(matrix.columns.0.y, matrix.columns.1.y, matrix.columns.2.y), local),
                simd_dot(SIMD3(matrix.columns.0.z, matrix.columns.1.z, matrix.columns.2.z), local)
            ))
            let origin = SIMD3(matrix.columns.3.x, matrix.columns.3.y, matrix.columns.3.z)
            if let entity = scene.raycast(origin: origin, direction: direction, length: 200, query: .nearest).first?.entity,
               case .object(let objectID, let roomID) = hit(for: entity) {
                target = objectContainer(entity)
                result = (objectID, roomID)
            }
        }
        if target !== hovered {
            if let hovered { RoomBuilder.setHovered(hovered, false) }
            if let target { RoomBuilder.setHovered(target, true, lift: !reduceMotion) }
            hovered = target
        }
        return result
    }

    private func objectContainer(_ entity: Entity) -> Entity? {
        var current: Entity? = entity
        while let node = current {
            if node.name.hasPrefix("object:") { return node }
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
