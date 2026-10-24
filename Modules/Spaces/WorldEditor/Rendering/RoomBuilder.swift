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
    public static let floorSize: Float = 2
    public static let wallHeight: Float = 1.15
    static let wallThickness: Float = 0.06

    public static func roomName(_ id: UUID) -> String { "room:\(id.uuidString)" }
    public static func objectName(_ id: UUID) -> String { "object:\(id.uuidString)" }

    public static func build(space: Space, room: RoomLayout, objects: [SpaceObject]) -> Entity {
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

        // Name plate leaning toward the camera in front of the room.
        root.addChild(namePlate(space.name, color: .white))

        // Selection ring: a slightly larger translucent plate under the floor.
        let selection = ModelEntity(
            mesh: .generatePlane(width: floorSize + 0.3, depth: floorSize + 0.3, cornerRadius: 0.12),
            materials: [translucent(.white, opacity: 0.55)]
        )
        selection.name = "selection"
        selection.position = [0, -0.085, 0]
        selection.isEnabled = false
        root.addChild(selection)

        // Glowing edge along the open front when this is the active Space.
        let active = ModelEntity(mesh: .generateBox(size: [floorSize, 0.03, 0.05]), materials: [UnlitMaterial(color: accent)])
        active.name = "active"
        active.position = [0, 0.005, half - 0.02]
        active.isEnabled = false
        root.addChild(active)

        // Status light above the back corner.
        let status = ModelEntity(mesh: .generateSphere(radius: 0.08), materials: [UnlitMaterial(color: .gray)])
        status.name = "status"
        status.position = [-half + 0.15, wallHeight + 0.2, -half + 0.15]
        root.addChild(status)

        for object in objects {
            root.addChild(objectEntity(object, style: style))
        }

        // Picking: floor and walls select the room. Objects carry their own
        // shapes and sit in front of these, so a click on one hits it first.
        root.components.set(CollisionComponent(shapes: [
            ShapeResource.generateBox(size: [floorSize, 0.1, floorSize]).offsetBy(translation: [0, -0.04, 0]),
            ShapeResource.generateBox(size: [floorSize, wallHeight, wallThickness])
                .offsetBy(translation: [0, wallHeight / 2, -half - wallThickness / 2]),
            ShapeResource.generateBox(size: [wallThickness, wallHeight, floorSize])
                .offsetBy(translation: [-half - wallThickness / 2, wallHeight / 2, 0]),
        ]))
        root.components.set(InputTargetComponent())
        return root
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

        let bounds = model.visualBounds(relativeTo: container)
        if !bounds.isEmpty {
            container.components.set(CollisionComponent(shapes: [
                ShapeResource.generateBox(size: bounds.extents + 0.02).offsetBy(translation: bounds.center),
            ]))
            container.components.set(InputTargetComponent())
        }
        return container
    }

    /// Updates the cheap per-frame-independent indicators without rebuilding.
    public static func apply(status color: NSColor, isSelected: Bool, isActive: Bool, to room: Entity) {
        if let status = room.findEntity(named: "status") as? ModelEntity {
            status.model?.materials = [UnlitMaterial(color: color)]
        }
        room.findEntity(named: "selection")?.isEnabled = isSelected
        room.findEntity(named: "active")?.isEnabled = isActive
    }

    static func namePlate(_ text: String, color: NSColor) -> Entity {
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
        holder.position = [0, 0.01, floorSize / 2 + 0.3]
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
