import AppKit
import AtlasSpaces
import RealityKit

/// Mochi as RealityKit entities, from `MochiRecipe`. Used by the desktop
/// overlay and by every room, so there's one bunny everywhere.
///
/// Each joint is one entity: its first merged part is the joint itself and
/// any other surfaces are children, so Mochi with an accessory stays under
/// 30 entities. Posing moves joints and swaps the eye and mouth meshes;
/// nothing runs per frame.
@MainActor
public final class MochiFigure {
    public let root: Entity
    public let model: MochiModel
    public private(set) var joints: [MochiJoint: Entity] = [:]
    public private(set) var posture = MochiPosture.idle
    /// The rest transform of each joint for the current posture.
    public private(set) var posed: [MochiJoint: Transform] = [:]

    private var eyeMeshes: [String: MeshResource] = [:]
    private var mouthMeshes: [MochiPosture.Mouth: MeshResource] = [:]
    private var highlight: Entity?

    public init(model: MochiModel) {
        self.model = model
        root = Self.entity(for: model.root, joints: &joints)
        for (key, mesh) in model.eyeMeshes { eyeMeshes[key] = Self.resource(mesh) }
        for (key, mesh) in model.mouthMeshes { mouthMeshes[key] = Self.resource(mesh) }
        highlight = joints[.eyes]?.children.first { $0.name == "highlight" }
        apply(.idle)
    }

    public convenience init(look: MochiLook, accessories: [MochiAccessory] = [], detail: MochiRecipe.Detail = .full) {
        self.init(model: MochiRecipe.build(look: look, accessories: accessories, detail: detail))
    }

    public subscript(_ joint: MochiJoint) -> Entity? { joints[joint] }

    /// Model entities in the figure (the performance budget counts these).
    public var modelEntityCount: Int {
        func count(_ entity: Entity) -> Int { (entity is ModelEntity ? 1 : 0) + entity.children.reduce(0) { $0 + count($1) } }
        return count(root)
    }

    /// Moves every joint to `posture`, easing over `duration` (0 snaps).
    public func apply(_ posture: MochiPosture, duration: TimeInterval = 0) {
        self.posture = posture
        let transforms = MochiRig.transforms(posture, floppyEar: model.floppyEar)
        for (joint, t) in transforms {
            guard let entity = joints[joint] else { continue }
            let target = Transform(scale: t.scale, rotation: t.rotation, translation: t.translation)
            posed[joint] = target
            entity.isEnabled = t.visible
            if duration > 0, let parent = entity.parent {
                entity.move(to: target, relativeTo: parent, duration: duration, timingFunction: .easeInOut)
            } else {
                entity.transform = target
            }
        }
        setEyes(posture.eyes)
        setMouth(posture.mouth)
    }

    public func setEyes(_ eyes: MochiPosture.Eyes) {
        guard let entity = joints[.eyes] as? ModelEntity else { return }
        let key: String
        switch eyes {
        case .happy: key = "happy"
        case .closed: key = "closed"
        default: key = "open"
        }
        if let mesh = eyeMeshes[key], entity.model?.mesh !== mesh { entity.model?.mesh = mesh }
        highlight?.isEnabled = key == "open"
    }

    public func setMouth(_ mouth: MochiPosture.Mouth) {
        guard let entity = joints[.mouth] as? ModelEntity, let mesh = mouthMeshes[mouth], entity.model?.mesh !== mesh else { return }
        entity.model?.mesh = mesh
    }

    /// Moves one joint relative to its posed rest (an ear twitch, a nose
    /// wiggle), easing over `duration`.
    public func nudge(_ joint: MochiJoint, rotation: simd_quatf = simd_quatf(angle: 0, axis: [0, 1, 0]),
                      translation: SIMD3<Float> = .zero, scale: SIMD3<Float> = .one, duration: TimeInterval) {
        guard let entity = joints[joint], let rest = posed[joint], let parent = entity.parent else { return }
        var target = rest
        target.rotation = rest.rotation * rotation
        target.translation += translation
        target.scale *= scale
        if duration > 0 {
            entity.move(to: target, relativeTo: parent, duration: duration, timingFunction: .easeInOut)
        } else {
            entity.transform = target
        }
    }

    /// Back to the posed rest.
    public func settle(_ joint: MochiJoint, duration: TimeInterval) {
        nudge(joint, duration: duration)
    }

    // MARK: - Building

    private static func entity(for node: MochiNode, joints: inout [MochiJoint: Entity]) -> Entity {
        let entity: Entity
        if let first = node.parts.first {
            let model = modelEntity(first)
            for part in node.parts.dropFirst() { model.addChild(modelEntity(part)) }
            entity = model
        } else {
            entity = Entity()
        }
        entity.name = node.joint.rawValue
        entity.position = node.pivot
        joints[node.joint] = entity
        for child in node.children { entity.addChild(self.entity(for: child, joints: &joints)) }
        return entity
    }

    private static func modelEntity(_ part: MochiPart) -> ModelEntity {
        let entity = ModelEntity(mesh: resource(part.mesh) ?? .generateSphere(radius: 0.001), materials: [material(part.surface)])
        entity.name = part.name
        return entity
    }

    static func resource(_ mesh: MochiMesh) -> MeshResource? {
        guard !mesh.isEmpty else { return nil }
        var descriptor = MeshDescriptor(name: "mochi")
        descriptor.positions = MeshBuffers.Positions(mesh.positions)
        descriptor.normals = MeshBuffers.Normals(mesh.normals)
        descriptor.primitives = .triangles(mesh.indices)
        return try? MeshResource.generate(from: [descriptor])
    }

    /// Fur is matte (roughness 1), the tail a touch of sheen, eyes glossy
    /// with clearcoat, sparkles emissive, blush see-through and unlit.
    public static func material(_ surface: MochiSurface) -> any RealityKit.Material {
        let color = NSColor(atlasHex: surface.hex)
        if surface.finish == .blush {
            var material = UnlitMaterial(color: color)
            material.blending = .transparent(opacity: .init(floatLiteral: surface.opacity))
            return material
        }
        var material = PhysicallyBasedMaterial()
        material.baseColor = .init(tint: color)
        material.metallic = 0.0
        switch surface.finish {
        case .fur:
            // Matte, with a soft sheen at the edges so it reads as plush.
            material.roughness = 1.0
            material.sheen = .init(tint: NSColor(white: 0.22, alpha: 1))
        case .fluff:
            material.roughness = 1.0
            material.sheen = .init(tint: NSColor(white: 0.4, alpha: 1))
        case .glossy:
            material.roughness = 0.1
            material.clearcoat = 1.0
            material.clearcoatRoughness = 0.05
        case .sparkle:
            material.roughness = 0.2
            material.emissiveColor = .init(color: color)
            material.emissiveIntensity = max(surface.glow, 0.5)
        case .satin:
            material.roughness = 0.55
        case .metal:
            material.metallic = 1.0
            material.roughness = 0.25
        case .blush:
            break
        }
        if surface.opacity < 1 {
            material.blending = .transparent(opacity: .init(floatLiteral: surface.opacity))
        }
        return material
    }
}
