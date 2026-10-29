import AppKit
import AtlasSpaces
import RealityKit

/// Builds a miniature room procedurally: floor, two walls (the front and
/// one side stay open so you can look in), an accent strip, a name plate,
/// and the Space's objects.
///
/// Entity names carry identity for picking: `room:<uuid>` on the room root
/// and `object:<uuid>` on each object. Children named `status`,
/// `selection` and `active` are toggled without rebuilding the room.
@MainActor
public enum RoomBuilder {
    nonisolated public static let floorSize: Float = 2
    nonisolated public static let wallHeight: Float = 1.15
    static let wallThickness: Float = 0.06

    public static func roomName(_ id: UUID) -> String { "room:\(id.uuidString)" }
    public static func objectName(_ id: UUID) -> String { "object:\(id.uuidString)" }

    /// The rectangle a room stands on, in room units (floor centred on x).
    struct Footprint {
        var width: Float = floorSize
        var depth: Float = floorSize
        var centerZ: Float = 0
        var wallHeight: Float = RoomBuilder.wallHeight

        var back: Float { centerZ - depth / 2 }
        var front: Float { centerZ + depth / 2 }
        static let standard = Footprint()
        static let loft = Footprint(depth: 1.5, centerZ: -0.25, wallHeight: 1.3)
        static let library = Footprint(depth: 1.5, centerZ: -0.25, wallHeight: 1.4)
        static let codingLab = Footprint(depth: 1.5, centerZ: -0.25, wallHeight: 1.35)
    }

    /// Hand-built rooms with a full and a miniature level of detail.
    public static func hasDetailLevels(_ templateID: String) -> Bool {
        [CreativeLoft.templateID, StudyLibrary.templateID, CodingLab.templateID].contains(templateID)
    }

    /// `detail: false` asks for a lighter room where the template has one
    /// (the hand-built rooms' miniatures); other rooms ignore it.
    public static func build(space: Space, room: RoomLayout, objects: [SpaceObject], detail: Bool = true,
                             reduceMotion: Bool = false, study: StudyRoomState? = nil) -> Entity {
        if let diorama = buildDiorama(space: space, room: room, objects: objects, detail: detail, reduceMotion: reduceMotion,
                                      study: study) {
            return diorama
        }
        let accent = NSColor(atlasHex: space.accentColor)
        let style = AssetStyle(accent: accent, glow: NSColor(atlasHex: room.lighting.glowColor), tint: room.lighting.tint)
        let half = floorSize / 2

        let root = Entity()
        root.name = roomName(space.id)

        // Shell.
        let floor = ModelEntity(mesh: .generateBox(size: [floorSize, 0.08, floorSize]), materials: [style.matte(room.floorColor)])
        floor.position = [0, -0.04, 0]
        root.addChild(floor)

        let wall = style.matte(room.wallColor)
        let back = ModelEntity(mesh: .generateBox(size: [floorSize, wallHeight, wallThickness]), materials: [wall])
        back.position = [0, wallHeight / 2, -half - wallThickness / 2]
        root.addChild(back)
        let side = ModelEntity(mesh: .generateBox(size: [wallThickness, wallHeight, floorSize]), materials: [wall])
        side.position = [-half - wallThickness / 2, wallHeight / 2, 0]
        root.addChild(side)

        let strip = ModelEntity(mesh: .generateBox(size: [floorSize, 0.06, 0.01]), materials: [style.matte(accent)])
        strip.position = [0, 0.03, -half + 0.005]
        root.addChild(strip)

        addChrome(to: root, name: space.name, accent: accent, footprint: .standard)

        for object in objects {
            root.addChild(objectEntity(object, style: style))
        }
        return root
    }

    /// The hand-built rooms draw their own shell and props, which stand in
    /// for the Space's objects by role. Objects with an action but no prop
    /// are drawn as usual where they're stored.
    static func buildDiorama(space: Space, room: RoomLayout, objects: [SpaceObject], detail: Bool, reduceMotion: Bool,
                             study: StudyRoomState? = nil) -> Entity? {
        let entity: Entity, motion: any RoomMotion, footprint: Footprint, loose: [SpaceObject]
        switch space.templateID {
        case CreativeLoft.templateID:
            let loft = CreativeLoftBuilder.build(objects: objects, detail: detail)
            (entity, footprint, loose) = (loft.entity, .loft, CreativeLoft.assign(objects).loose)
            motion = CreativeLoftMotion(parts: loft.parts, reduceMotion: reduceMotion)
        case StudyLibrary.templateID:
            let library = StudyLibraryBuilder.build(objects: objects, detail: detail, study: study ?? StudyRoomState())
            (entity, footprint, loose) = (library.entity, .library, StudyLibrary.assign(objects).loose)
            motion = StudyLibraryMotion(parts: library.parts, reduceMotion: reduceMotion)
        case CodingLab.templateID:
            let lab = CodingLabBuilder.build(objects: objects, detail: detail)
            (entity, footprint, loose) = (lab.entity, .codingLab, CodingLab.assign(objects).loose)
            motion = CodingLabMotion(parts: lab.parts, reduceMotion: reduceMotion)
        default:
            return nil
        }
        let accent = NSColor(atlasHex: space.accentColor)
        let style = AssetStyle(accent: accent, glow: NSColor(atlasHex: room.lighting.glowColor), tint: room.lighting.tint)
        let root = Entity()
        root.name = roomName(space.id)
        root.addChild(entity)
        root.components.set(RoomMotionComponent(motion: motion))
        addChrome(to: root, name: space.name, accent: accent, footprint: footprint)
        if detail {
            for object in loose {
                root.addChild(objectEntity(object, style: style))
            }
        }
        return root
    }

    /// Name plate, selection ring, active edge, status light and the
    /// room's own picking shapes, sized to `footprint`.
    static func addChrome(to root: Entity, name: String, accent: NSColor, footprint f: Footprint) {
        root.addChild(namePlate(name, color: .white, z: f.front + 0.3))

        let selection = ModelEntity(
            mesh: .generatePlane(width: f.width + 0.3, depth: f.depth + 0.3, cornerRadius: 0.12),
            materials: [translucent(.white, opacity: 0.55)]
        )
        selection.name = "selection"
        selection.position = [0, -0.085, f.centerZ]
        selection.isEnabled = false
        root.addChild(selection)

        // Glowing edge along the open front when this is the active Space.
        let active = ModelEntity(mesh: .generateBox(size: [f.width, 0.03, 0.05]), materials: [UnlitMaterial(color: accent)])
        active.name = "active"
        active.position = [0, 0.005, f.front - 0.02]
        active.isEnabled = false
        root.addChild(active)

        // Status light above the back corner.
        let status = ModelEntity(mesh: .generateSphere(radius: 0.08), materials: [UnlitMaterial(color: .gray)])
        status.name = "status"
        status.position = [-f.width / 2 + 0.15, f.wallHeight + 0.2, f.back + 0.15]
        root.addChild(status)

        // Picking: floor and walls select the room. Objects carry their own
        // shapes and sit in front of these, so a click on one hits it first.
        let halfWidth = f.width / 2
        root.components.set(CollisionComponent(shapes: [
            ShapeResource.generateBox(size: [f.width, 0.1, f.depth]).offsetBy(translation: [0, -0.04, f.centerZ]),
            ShapeResource.generateBox(size: [f.width, f.wallHeight, wallThickness])
                .offsetBy(translation: [0, f.wallHeight / 2, f.back - wallThickness / 2]),
            ShapeResource.generateBox(size: [wallThickness, f.wallHeight, f.depth])
                .offsetBy(translation: [-halfWidth - wallThickness / 2, f.wallHeight / 2, f.centerZ]),
        ]))
        root.components.set(InputTargetComponent())
    }

    static func objectEntity(_ object: SpaceObject, style: AssetStyle) -> Entity {
        let container = Entity()
        container.name = objectName(object.id)
        let transform = object.transform
        container.position = transform.position
        let radians = transform.rotation * (.pi / 180)
        container.orientation = simd_quatf(angle: radians.y, axis: [0, 1, 0])
            * simd_quatf(angle: radians.x, axis: [1, 0, 0])
            * simd_quatf(angle: radians.z, axis: [0, 0, 1])
        container.scale = transform.scale

        let model = AssetCatalog.asset(for: object.kind).makeEntity(style: style)
        container.addChild(model)

        makeInteractive(container)
        return container
    }

    /// Gives an object's entity a pick shape around everything it draws.
    static func makeInteractive(_ container: Entity) {
        let bounds = container.visualBounds(relativeTo: container)
        guard !bounds.isEmpty else { return }
        container.components.set(CollisionComponent(shapes: [
            ShapeResource.generateBox(size: bounds.extents + 0.02).offsetBy(translation: bounds.center),
        ]))
        container.components.set(InputTargetComponent())
    }

    // MARK: - Hover

    struct HoverComponent: Component {
        var rest: SIMD3<Float>
    }

    /// How far an object moves when hovered (default: lifts 1 cm).
    struct HoverOffsetComponent: Component {
        var offset: SIMD3<Float>
    }

    /// Lifts an object 1 cm and draws a rose outline around it, or puts it
    /// back. The outline is made on first hover, so rooms don't pay for it.
    /// Under Reduce Motion it only glows.
    public static func setHovered(_ object: Entity, _ hovered: Bool, lift: Bool = true) {
        let rest = object.components[HoverComponent.self]?.rest ?? object.position
        object.components.set(HoverComponent(rest: rest))
        let offset = object.components[HoverOffsetComponent.self]?.offset ?? [0, 0.01, 0]
        object.position = hovered && lift ? rest + offset : rest
        if hovered, object.findEntity(named: "hoverGlow") == nil, let glow = outline(of: object) {
            object.addChild(glow)
        }
        object.findEntity(named: "hoverGlow")?.isEnabled = hovered
    }

    /// A slightly inflated copy of everything `object` draws, showing only
    /// its back faces: reads as a soft outline.
    static func outline(of object: Entity) -> Entity? {
        var batch = MeshBatch()
        func collect(_ entity: Entity) {
            if let model = entity as? ModelEntity, let mesh = model.model?.mesh {
                batch.add(LoftGeometry(mesh), matrix: entity.transformMatrix(relativeTo: object), inflate: 0.008)
            }
            entity.children.forEach(collect)
        }
        object.children.forEach(collect)
        var material = UnlitMaterial(color: NSColor(atlasHex: CreativeLoftPalette.current.rose))
        material.blending = .transparent(opacity: 0.6)
        material.faceCulling = .front
        return batch.entity(material, name: "hoverGlow")
    }

    /// Updates the cheap per-frame-independent indicators without rebuilding.
    public static func apply(status color: NSColor, isSelected: Bool, isActive: Bool, to room: Entity) {
        if let status = room.findEntity(named: "status") as? ModelEntity {
            status.model?.materials = [UnlitMaterial(color: color)]
        }
        room.findEntity(named: "selection")?.isEnabled = isSelected
        room.findEntity(named: "active")?.isEnabled = isActive
    }

    static func namePlate(_ text: String, color: NSColor, z: Float = floorSize / 2 + 0.3) -> Entity {
        let mesh = MeshResource.generateText(
            text,
            extrusionDepth: 0.005,
            font: .systemFont(ofSize: 0.17, weight: .semibold),
            containerFrame: .zero,
            alignment: .center,
            lineBreakMode: .byTruncatingTail
        )
        let label = ModelEntity(mesh: mesh, materials: [UnlitMaterial(color: color)])
        let bounds = mesh.bounds
        // Centre horizontally and lay it back so it reads from above.
        let holder = Entity()
        holder.position = [0, 0.01, z]
        holder.orientation = simd_quatf(angle: -.pi / 3, axis: [1, 0, 0])
        label.position = [-bounds.center.x, -bounds.min.y, 0]
        holder.addChild(label)
        return holder
    }

    static func translucent(_ color: NSColor, opacity: Float) -> UnlitMaterial {
        var material = UnlitMaterial(color: color)
        material.blending = .transparent(opacity: .init(floatLiteral: opacity))
        return material
    }
}
