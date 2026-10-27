import RealityKit
import simd

/// Triangle geometry on the CPU, ready to be merged. The loft builds its
/// primitives here rather than with `MeshResource.generate…`: those are
/// tessellated for close-ups (a rounded box is ~20k vertices), far more than
/// a miniature room needs and slow to merge.
struct LoftGeometry {
    var positions: [SIMD3<Float>] = []
    var normals: [SIMD3<Float>] = []
    var uvs: [SIMD2<Float>] = []
    var indices: [UInt32] = []

    init() {}

    /// The CPU copy of an existing mesh (used for hover outlines).
    @MainActor
    init(_ mesh: MeshResource) {
        for model in mesh.contents.models {
            for part in model.parts {
                let base = UInt32(positions.count)
                let points = part.positions.elements
                positions += points
                let partNormals = part.normals?.elements ?? []
                normals += partNormals.count == points.count ? partNormals : Array(repeating: [0, 1, 0], count: points.count)
                let partUVs = part.textureCoordinates?.elements ?? []
                uvs += partUVs.count == points.count ? partUVs : Array(repeating: .zero, count: points.count)
                indices += (part.triangleIndices?.elements ?? []).map { $0 + base }
            }
        }
    }

    fileprivate mutating func vertex(_ position: SIMD3<Float>, _ normal: SIMD3<Float>, _ uv: SIMD2<Float> = .zero) {
        positions.append(position)
        normals.append(normal)
        uvs.append(uv)
    }

    fileprivate mutating func quad(_ a: UInt32, _ b: UInt32, _ c: UInt32, _ d: UInt32) {
        indices += [a, b, c, a, c, d]
    }

    /// A box centred on the origin; `cornerRadius` rounds every edge.
    static func generateBox(width: Float, height: Float, depth: Float, cornerRadius: Float = 0) -> LoftGeometry {
        let half = SIMD3<Float>(width, height, depth) / 2
        let radius = max(0, min(cornerRadius, half.min()))
        // Grid samples along a face axis: dense in the rounded bands only.
        func samples(_ h: Float) -> [Float] {
            guard radius > 0 else { return [-h, h] }
            let steps = 3
            let low = (0...steps).map { -h + radius * Float($0) / Float(steps) }
            let high = (0...steps).map { h - radius + radius * Float($0) / Float(steps) }
            return low + high
        }
        let inner = half - radius
        var g = LoftGeometry()
        // Each face: outward normal n, and axes with u × v = n.
        let faces: [(n: SIMD3<Float>, u: SIMD3<Float>, v: SIMD3<Float>)] = [
            ([1, 0, 0], [0, 0, -1], [0, 1, 0]), ([-1, 0, 0], [0, 0, 1], [0, 1, 0]),
            ([0, 1, 0], [1, 0, 0], [0, 0, -1]), ([0, -1, 0], [1, 0, 0], [0, 0, 1]),
            ([0, 0, 1], [1, 0, 0], [0, 1, 0]), ([0, 0, -1], [-1, 0, 0], [0, 1, 0]),
        ]
        for face in faces {
            let us = samples(simd_dot(abs(face.u), half))
            let vs = samples(simd_dot(abs(face.v), half))
            let base = UInt32(g.positions.count)
            for (j, b) in vs.enumerated() {
                for (i, a) in us.enumerated() {
                    let p = face.n * simd_dot(abs(face.n), half) + face.u * a + face.v * b
                    let uv = SIMD2(Float(i) / Float(us.count - 1), Float(j) / Float(vs.count - 1))
                    if radius > 0 {
                        let core = simd_clamp(p, -inner, inner)
                        let offset = p - core
                        let normal = simd_length(offset) > 1e-6 ? simd_normalize(offset) : face.n
                        g.vertex(core + normal * radius, normal, uv)
                    } else {
                        g.vertex(p, face.n, uv)
                    }
                }
            }
            let columns = UInt32(us.count)
            for j in 0..<UInt32(vs.count - 1) {
                for i in 0..<UInt32(us.count - 1) {
                    let a = base + j * columns + i
                    g.quad(a, a + 1, a + 1 + columns, a + columns)
                }
            }
        }
        return g
    }

    /// A cylinder along y, centred on the origin.
    static func generateCylinder(height: Float, radius: Float, segments: Int = 16, capped: Bool = true) -> LoftGeometry {
        cone(height: height, bottom: radius, top: radius, segments: segments, capped: capped)
    }

    /// A cone along y, centred on the origin, tip up.
    static func generateCone(height: Float, radius: Float, segments: Int = 16) -> LoftGeometry {
        cone(height: height, bottom: radius, top: 0, segments: segments)
    }

    private static func cone(height: Float, bottom: Float, top: Float, segments: Int, capped: Bool = true) -> LoftGeometry {
        var g = LoftGeometry()
        let h = height / 2
        let slope = (bottom - top) / height
        for index in 0...segments {
            let angle = 2 * Float.pi * Float(index) / Float(segments)
            let direction = SIMD3<Float>(cos(angle), 0, -sin(angle))
            let normal = simd_normalize(direction + [0, slope, 0])
            let u = Float(index) / Float(segments)
            g.vertex(direction * bottom - [0, h, 0], normal, [u, 0])
            g.vertex(direction * top + [0, h, 0], normal, [u, 1])
        }
        for index in 0..<UInt32(segments) {
            let a = index * 2
            g.quad(a, a + 2, a + 3, a + 1)
        }
        for (y, radius, up) in [(h, top, Float(1)), (-h, bottom, -1)] where capped && radius > 0 {
            let center = UInt32(g.positions.count)
            g.vertex([0, y, 0], [0, up, 0], [0.5, 0.5])
            for index in 0...segments {
                let angle = 2 * Float.pi * Float(index) / Float(segments)
                g.vertex([cos(angle) * radius, y, -sin(angle) * radius], [0, up, 0], [0.5 + cos(angle) / 2, 0.5 + sin(angle) / 2])
            }
            for index in 1...UInt32(segments) {
                g.indices += up > 0 ? [center, center + index, center + index + 1] : [center, center + index + 1, center + index]
            }
        }
        return g
    }

    static func generateSphere(radius: Float, rings: Int = 8, segments: Int = 12) -> LoftGeometry {
        var g = LoftGeometry()
        for ring in 0...rings {
            let phi = Float.pi * Float(ring) / Float(rings)
            for index in 0...segments {
                let theta = 2 * Float.pi * Float(index) / Float(segments)
                let normal = SIMD3<Float>(sin(phi) * cos(theta), cos(phi), -sin(phi) * sin(theta))
                g.vertex(normal * radius, normal, [Float(index) / Float(segments), 1 - Float(ring) / Float(rings)])
            }
        }
        let columns = UInt32(segments + 1)
        for ring in 0..<UInt32(rings) {
            for index in 0..<UInt32(segments) {
                let a = ring * columns + index
                g.quad(a, a + columns, a + columns + 1, a + 1)
            }
        }
        return g
    }

    /// A plane in xy facing +z; v runs bottom (0) to top (1).
    static func generatePlane(width: Float, height: Float) -> LoftGeometry {
        var g = LoftGeometry()
        let w = width / 2, h = height / 2
        g.vertex([-w, -h, 0], [0, 0, 1], [0, 0])
        g.vertex([w, -h, 0], [0, 0, 1], [1, 0])
        g.vertex([w, h, 0], [0, 0, 1], [1, 1])
        g.vertex([-w, h, 0], [0, 0, 1], [0, 1])
        g.quad(0, 1, 2, 3)
        return g
    }
}

extension LoftGeometry {
    /// The same surface plus a flipped copy, so it shows from both sides
    /// (open shades, thin cloth).
    func doubleSided() -> LoftGeometry {
        var g = self
        let count = UInt32(positions.count)
        g.positions += positions
        g.normals += normals.map { -$0 }
        g.uvs += uvs
        for index in stride(from: 0, to: indices.count, by: 3) {
            g.indices += [indices[index] + count, indices[index + 2] + count, indices[index + 1] + count]
        }
        return g
    }

    /// Half a tube along x with the arch on top (y ≥ 0) and the bottom
    /// open, both sides visible: a banker's-lamp shade.
    static func halfTube(length: Float, radius: Float, segments: Int = 12) -> LoftGeometry {
        var g = LoftGeometry()
        let half = length / 2
        for index in 0...segments {
            let angle = Float.pi * Float(index) / Float(segments)
            let normal = SIMD3<Float>(0, sin(angle), cos(angle))
            g.vertex([-half, normal.y * radius, normal.z * radius], normal, [0, Float(index) / Float(segments)])
            g.vertex([half, normal.y * radius, normal.z * radius], normal, [1, Float(index) / Float(segments)])
        }
        for index in 0..<UInt32(segments) {
            let a = index * 2
            g.quad(a, a + 1, a + 3, a + 2)
        }
        return g.doubleSided()
    }

    /// A flat convex polygon in the xz plane at height `y`, facing up.
    static func flatPolygon(_ points: [SIMD2<Float>], y: Float) -> LoftGeometry {
        var g = LoftGeometry()
        guard points.count >= 3 else { return g }
        for point in points { g.vertex([point.x, y, point.y], [0, 1, 0], [point.x, point.y]) }
        // Fan from the first point, wound to face +y whichever way the points run.
        let a = SIMD3(points[0].x, 0, points[0].y), b = SIMD3(points[1].x, 0, points[1].y), c = SIMD3(points[2].x, 0, points[2].y)
        let up = simd_cross(b - a, c - a).y > 0
        for index in 1..<UInt32(points.count - 1) {
            g.indices += up ? [0, index, index + 1] : [0, index + 1, index]
        }
        return g
    }
}

/// Merges many small static meshes that share one material into a single
/// mesh, so a detailed room stays a few dozen entities instead of hundreds.
struct MeshBatch {
    private(set) var geometry = LoftGeometry()

    var isEmpty: Bool { geometry.indices.isEmpty }

    /// Adds `g` transformed by `matrix`, every vertex pushed `inflate`
    /// along its normal (a slightly fatter copy, for outlines).
    mutating func add(_ g: LoftGeometry, matrix: float4x4, inflate: Float = 0) {
        let linear = simd_float3x3(SIMD3(matrix.columns.0.x, matrix.columns.0.y, matrix.columns.0.z),
                                   SIMD3(matrix.columns.1.x, matrix.columns.1.y, matrix.columns.1.z),
                                   SIMD3(matrix.columns.2.x, matrix.columns.2.y, matrix.columns.2.z))
        let normalMatrix = linear.inverse.transpose
        let base = UInt32(geometry.positions.count)
        geometry.positions.reserveCapacity(geometry.positions.count + g.positions.count)
        geometry.normals.reserveCapacity(geometry.normals.count + g.normals.count)
        for index in g.positions.indices {
            let normal = simd_normalize(normalMatrix * g.normals[index])
            let p = matrix * SIMD4(g.positions[index], 1)
            geometry.positions.append(SIMD3(p.x, p.y, p.z) + normal * inflate)
            geometry.normals.append(normal)
        }
        geometry.uvs += g.uvs
        geometry.indices += g.indices.map { $0 + base }
    }

    mutating func add(_ g: LoftGeometry, at position: SIMD3<Float>, rotation: simd_quatf = simd_quatf(angle: 0, axis: [0, 1, 0]),
                      scale: SIMD3<Float> = .one) {
        add(g, matrix: Transform(scale: scale, rotation: rotation, translation: position).matrix)
    }

    /// One entity with everything added so far, or nil when empty.
    @MainActor
    func entity(_ material: some RealityKit.Material, name: String = "") -> ModelEntity? {
        guard !isEmpty else { return nil }
        var descriptor = MeshDescriptor(name: name)
        descriptor.positions = MeshBuffers.Positions(geometry.positions)
        descriptor.normals = MeshBuffers.Normals(geometry.normals)
        descriptor.textureCoordinates = MeshBuffers.TextureCoordinates(geometry.uvs)
        descriptor.primitives = .triangles(geometry.indices)
        guard let mesh = try? MeshResource.generate(from: [descriptor]) else { return nil }
        let entity = ModelEntity(mesh: mesh, materials: [material])
        entity.name = name
        return entity
    }
}

/// Shapes the loft uses that aren't plain primitives.
enum LoftShapes {
    static let unitSphere = LoftGeometry.generateSphere(radius: 1)

    /// A ring of short cylinders around the y axis, `from`…`to` radians
    /// (a full ring by default).
    static func ring(radius: Float, thickness: Float, segments: Int = 18, from: Float = 0, to: Float = 2 * .pi) -> LoftGeometry {
        var batch = MeshBatch()
        let step = (to - from) / Float(segments)
        let piece = LoftGeometry.generateCylinder(height: 2 * radius * sin(step / 2) * 1.08, radius: thickness, segments: 8)
        for index in 0..<segments {
            let angle = from + step * (Float(index) + 0.5)
            let position = SIMD3<Float>(cos(angle) * radius, 0, sin(angle) * radius)
            // Cylinders run along y; lay each one along the ring's tangent.
            let rotation = simd_quatf(angle: -angle, axis: [0, 1, 0]) * simd_quatf(angle: .pi / 2, axis: [1, 0, 0])
            batch.add(piece, at: position, rotation: rotation)
        }
        return batch.geometry
    }

    /// A flat half disc in the xy plane (the top of an arch), facing both ways.
    static func halfDisc(radius: Float, segments: Int) -> LoftGeometry {
        var g = LoftGeometry()
        g.positions = [.zero]
        g.uvs = [[0.5, 0]]
        for index in 0...segments {
            let angle = Float.pi * Float(index) / Float(segments)
            g.positions.append([cos(angle) * radius, sin(angle) * radius, 0])
            g.uvs.append([0.5 + cos(angle) / 2, sin(angle)])
        }
        g.normals = Array(repeating: [0, 0, 1], count: g.positions.count)
        for index in 1...UInt32(segments) {
            g.indices += [0, index, index + 1, 0, index + 1, index]
        }
        return g
    }

    /// The wall around the top of an arched opening: the two corners of the
    /// square [-r, r] × [0, r] outside a half circle of radius `r`, `depth`
    /// thick along z, with the curved reveal facing into the opening.
    static func archSpandrels(radius r: Float, depth: Float, segments: Int) -> LoftGeometry {
        var g = LoftGeometry()
        let h = depth / 2
        func arc(_ k: Int) -> SIMD2<Float> {
            let angle = Float.pi * Float(k) / Float(segments)
            return [cos(angle) * r, sin(angle) * r]
        }
        let half = segments / 2
        for (z, normal) in [(h, SIMD3<Float>(0, 0, 1)), (-h, SIMD3<Float>(0, 0, -1))] {
            for (corner, range) in [(SIMD2<Float>(r, r), 0..<half), (SIMD2<Float>(-r, r), half..<segments)] {
                let c = UInt32(g.positions.count)
                g.vertex([corner.x, corner.y, z], normal)
                for k in range.lowerBound...range.upperBound {
                    let p = arc(k)
                    g.vertex([p.x, p.y, z], normal)
                }
                for i in 1...UInt32(range.count) {
                    g.indices += normal.z > 0 ? [c, c + i + 1, c + i] : [c, c + i, c + i + 1]
                }
            }
        }
        let base = UInt32(g.positions.count)
        for k in 0...segments {
            let p = arc(k)
            let inward = SIMD3<Float>(-p.x / r, -p.y / r, 0)
            g.vertex([p.x, p.y, h], inward)
            g.vertex([p.x, p.y, -h], inward)
        }
        for k in 0..<UInt32(segments) {
            let f = base + k * 2
            g.quad(f, f + 2, f + 3, f + 1)
        }
        return g
    }

    /// A capsule along y: a cylinder with a sphere at each end.
    static func capsule(height: Float, radius: Float) -> LoftGeometry {
        var batch = MeshBatch()
        batch.add(.generateCylinder(height: max(0.001, height - 2 * radius), radius: radius, segments: 12), at: .zero)
        batch.add(unitSphere, at: [0, height / 2 - radius, 0], scale: SIMD3(repeating: radius))
        batch.add(unitSphere, at: [0, -height / 2 + radius, 0], scale: SIMD3(repeating: radius))
        return batch.geometry
    }
}

/// Collects meshes per material slot, then makes one entity per slot.
@MainActor
final class Batches<Key: Hashable> {
    private let material: (Key) -> any RealityKit.Material
    private var batches: [Key: MeshBatch] = [:]
    private var order: [Key] = []

    init(material: @escaping (Key) -> any RealityKit.Material) {
        self.material = material
    }

    func add(_ key: Key, _ mesh: LoftGeometry, at position: SIMD3<Float>,
             rotation: simd_quatf = simd_quatf(angle: 0, axis: [0, 1, 0]), scale: SIMD3<Float> = .one) {
        if batches[key] == nil { order.append(key) }
        batches[key, default: MeshBatch()].add(mesh, at: position, rotation: rotation, scale: scale)
    }

    func add(_ key: Key, _ mesh: LoftGeometry, matrix: float4x4) {
        if batches[key] == nil { order.append(key) }
        batches[key, default: MeshBatch()].add(mesh, matrix: matrix)
    }

    func flush(into parent: Entity) {
        for key in order {
            guard let batch = batches[key], let entity = batch.entity(material(key)) else { continue }
            parent.addChild(entity)
        }
        batches = [:]
        order = []
    }
}

/// Ambient motion and activation effects of a hand-built room. Kept on the
/// room entity (`RoomMotionComponent`) so Mission Control can drive it.
@MainActor
protocol RoomMotion: AnyObject {
    /// Starts the loops; called once the room is in the scene.
    func start()
    func stop()
    /// The Space became active or inactive (`animated` false on first build).
    func setActive(_ isActive: Bool, animated: Bool)
    /// The room is in `scene` (again, after a pause); for motion driven by
    /// scene update events.
    func attach(to scene: RealityKit.Scene)
}

extension RoomMotion {
    func attach(to scene: RealityKit.Scene) {}
}

struct RoomMotionComponent: Component {
    let motion: any RoomMotion
}
