import Foundation
import simd

// Mochi's geometry and rig as plain data, built from primitives (spheres,
// capsules, cones, torus arcs). Units: Mochi is 1 tall from the soles to
// the top of its head, ears extra; renderers scale it. Origin between the
// feet on the ground, facing +z.
//
// The joint names double as the contract for a Blender replacement: a USDZ
// with nodes named like `MochiJoint` raw values can be driven the same way.

/// Triangles on the CPU, merged per joint and surface.
public struct MochiMesh: Sendable {
    public var positions: [SIMD3<Float>] = []
    public var normals: [SIMD3<Float>] = []
    public var indices: [UInt32] = []

    public init() {}

    public var isEmpty: Bool { indices.isEmpty }
    public var triangleCount: Int { indices.count / 3 }

    public mutating func append(_ other: MochiMesh, _ matrix: simd_float4x4 = matrix_identity_float4x4) {
        let linear = simd_float3x3(SIMD3(matrix.columns.0.x, matrix.columns.0.y, matrix.columns.0.z),
                                   SIMD3(matrix.columns.1.x, matrix.columns.1.y, matrix.columns.1.z),
                                   SIMD3(matrix.columns.2.x, matrix.columns.2.y, matrix.columns.2.z))
        let normalMatrix = linear.inverse.transpose
        let base = UInt32(positions.count)
        for index in other.positions.indices {
            let p = matrix * SIMD4(other.positions[index], 1)
            positions.append(SIMD3(p.x, p.y, p.z))
            normals.append(simd_normalize(normalMatrix * other.normals[index]))
        }
        indices += other.indices.map { $0 + base }
    }

    public mutating func add(_ other: MochiMesh, at position: SIMD3<Float>, rotation: simd_quatf = MochiMath.identity,
                             scale: SIMD3<Float> = .one) {
        append(other, MochiMath.matrix(position, rotation, scale))
    }

    // MARK: Primitives

    /// A unit sphere.
    public static func sphere(segments: Int, rings: Int) -> MochiMesh {
        var m = MochiMesh()
        for ring in 0...rings {
            let v = Float(ring) / Float(rings)
            let phi = v * .pi
            for segment in 0...segments {
                let theta = Float(segment) / Float(segments) * 2 * .pi
                let n = SIMD3<Float>(sin(phi) * cos(theta), cos(phi), sin(phi) * sin(theta))
                m.positions.append(n)
                m.normals.append(n)
            }
        }
        let columns = UInt32(segments + 1)
        for ring in 0..<UInt32(rings) {
            for segment in 0..<UInt32(segments) {
                let a = ring * columns + segment, b = a + columns
                m.indices += [a, a + 1, b, a + 1, b + 1, b]
            }
        }
        return m
    }

    /// A capsule along y, centred on the origin, `length` end to end.
    public static func capsule(length: Float, radius: Float, segments: Int, rings: Int) -> MochiMesh {
        var m = MochiMesh()
        let half = max(0, length / 2 - radius)
        let rows = rings * 2 + 1
        for row in 0...rows {
            // Upper hemisphere rows, then lower ones; the middle row repeats
            // the equator at the other end to make the straight part.
            let upper = row <= rings
            let k = upper ? row : row - 1
            let phi = Float(k) / Float(rings * 2) * .pi
            let offset: Float = upper ? half : -half
            for segment in 0...segments {
                let theta = Float(segment) / Float(segments) * 2 * .pi
                let n = SIMD3<Float>(sin(phi) * cos(theta), cos(phi), sin(phi) * sin(theta))
                m.positions.append(n * radius + [0, offset, 0])
                m.normals.append(n)
            }
        }
        let columns = UInt32(segments + 1)
        for row in 0..<UInt32(rows) {
            for segment in 0..<UInt32(segments) {
                let a = row * columns + segment, b = a + columns
                m.indices += [a, a + 1, b, a + 1, b + 1, b]
            }
        }
        return m
    }

    /// Part of a torus in the xy plane around the z axis, from `from` to
    /// `to` radians (0 = +x, counter-clockwise), with rounded ends.
    public static func torusArc(radius: Float, tube: Float, from: Float, to: Float, segments: Int, sides: Int) -> MochiMesh {
        var m = MochiMesh()
        for segment in 0...segments {
            let a = from + (to - from) * Float(segment) / Float(segments)
            let centre = SIMD3<Float>(cos(a), sin(a), 0) * radius
            let outward = SIMD3<Float>(cos(a), sin(a), 0)
            for side in 0...sides {
                let b = Float(side) / Float(sides) * 2 * .pi
                let n = outward * cos(b) + SIMD3<Float>(0, 0, 1) * sin(b)
                m.positions.append(centre + n * tube)
                m.normals.append(n)
            }
        }
        let columns = UInt32(sides + 1)
        for segment in 0..<UInt32(segments) {
            for side in 0..<UInt32(sides) {
                let a = segment * columns + side, b = a + columns
                m.indices += [a, b, a + 1, a + 1, b, b + 1]
            }
        }
        // Round caps so the ends of an arc look soft.
        if to - from < 2 * .pi - 0.01 {
            let cap = sphere(segments: max(6, sides), rings: max(4, sides / 2))
            for a in [from, to] {
                m.add(cap, at: SIMD3(cos(a), sin(a), 0) * radius, scale: SIMD3(repeating: tube))
            }
        }
        return m
    }

    /// A slice of a (possibly tapered) cylinder along y, centred on the
    /// origin, between two angles, with its top and bottom capped.
    public static func cylinderSlice(height: Float, bottom: Float, top: Float, from: Float, to: Float, segments: Int) -> MochiMesh {
        var m = MochiMesh()
        let h = height / 2
        let slope = (bottom - top) / height
        for segment in 0...segments {
            let a = from + (to - from) * Float(segment) / Float(segments)
            let d = SIMD3<Float>(cos(a), 0, sin(a))
            let n = simd_normalize(d + [0, slope, 0])
            m.positions += [d * bottom - [0, h, 0], d * top + [0, h, 0]]
            m.normals += [n, n]
        }
        for segment in 0..<UInt32(segments) {
            let a = segment * 2
            m.indices += [a, a + 1, a + 2, a + 1, a + 3, a + 2]
        }
        for (y, radius, up) in [(h, top, Float(1)), (-h, bottom, -1)] {
            let centre = UInt32(m.positions.count)
            m.positions.append([0, y, 0])
            m.normals.append([0, up, 0])
            for segment in 0...segments {
                let a = from + (to - from) * Float(segment) / Float(segments)
                m.positions.append([cos(a) * radius, y, sin(a) * radius])
                m.normals.append([0, up, 0])
            }
            for segment in 0..<UInt32(segments) {
                let a = centre + 1 + segment
                m.indices += up > 0 ? [centre, a + 1, a] : [centre, a, a + 1]
            }
        }
        return m
    }

    public static func cone(height: Float, radius: Float, segments: Int) -> MochiMesh {
        cylinderSlice(height: height, bottom: radius, top: 0.0001, from: 0, to: 2 * .pi, segments: segments)
    }
}

public enum MochiMath {
    public static let identity = simd_quatf(angle: 0, axis: [0, 1, 0])

    public static func rx(_ a: Float) -> simd_quatf { simd_quatf(angle: a, axis: [1, 0, 0]) }
    public static func ry(_ a: Float) -> simd_quatf { simd_quatf(angle: a, axis: [0, 1, 0]) }
    public static func rz(_ a: Float) -> simd_quatf { simd_quatf(angle: a, axis: [0, 0, 1]) }

    public static func matrix(_ t: SIMD3<Float>, _ r: simd_quatf, _ s: SIMD3<Float>) -> simd_float4x4 {
        var m = simd_float4x4(r)
        m.columns.0 *= s.x
        m.columns.1 *= s.y
        m.columns.2 *= s.z
        m.columns.3 = SIMD4(t, 1)
        return m
    }

    /// The rotation taking a limb that points down (-y) to point along `direction`.
    public static func pointing(_ direction: SIMD3<Float>) -> simd_quatf {
        simd_quatf(from: [0, -1, 0], to: simd_normalize(direction))
    }
}

public enum MochiColor {
    /// "#RRGGBB" mixed `amount` of the way towards `other`.
    public static func mix(_ hex: String, _ other: String, _ amount: Double) -> String {
        let a = rgb(hex), b = rgb(other)
        let mixed = (0..<3).map { Int((a[$0] + (b[$0] - a[$0]) * amount).rounded()) }
        return String(format: "#%02X%02X%02X", mixed[0], mixed[1], mixed[2])
    }

    public static func rgb(_ hex: String) -> [Double] {
        var text = hex.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("#") { text.removeFirst() }
        let value = UInt32(text, radix: 16) ?? 0xFFFFFF
        return [Double((value >> 16) & 0xFF), Double((value >> 8) & 0xFF), Double(value & 0xFF)]
    }
}

/// How a surface is drawn. The renderer picks the material from this.
public struct MochiSurface: Hashable, Sendable {
    public enum Finish: String, Hashable, Sendable {
        /// Matte, soft fur (roughness 1).
        case fur
        /// The tail: matte with a touch of sheen.
        case fluff
        /// Glossy eyes and mouth (roughness 0.1, clearcoat 1).
        case glossy
        /// The white sparkles in the eyes.
        case sparkle
        /// See-through blush.
        case blush
        /// Satin accessories (fabric, plastic).
        case satin
        /// Polished metal (glasses).
        case metal
    }

    public var hex: String
    public var finish: Finish
    public var opacity: Float
    /// Emissive strength for `.sparkle`.
    public var glow: Float

    public init(_ hex: String, _ finish: Finish, opacity: Float = 1, glow: Float = 0) {
        self.hex = hex
        self.finish = finish
        self.opacity = opacity
        self.glow = glow
    }
}

/// Mochi's joints. Each is one entity; parts are merged under it by surface.
public enum MochiJoint: String, CaseIterable, Hashable, Sendable {
    case root = "Mochi"
    case feet = "Feet"
    case body = "Body"
    case pawLeft = "Paw_L"
    case pawRight = "Paw_R"
    case head = "Head"
    case cheeks = "Cheeks"
    case eyes = "Eyes"
    case nose = "Nose"
    case mouth = "Mouth"
    case earLeft = "Ear_L_1"
    case earLeftTip = "Ear_L_2"
    case earRight = "Ear_R_1"
    case earRightTip = "Ear_R_2"
    case sweat = "Sweat"
}

/// One merged piece of a joint: everything under that joint drawn with one surface.
public struct MochiPart: Sendable {
    /// "fur", "eye", "highlight", "accessory.glasses", …
    public var name: String
    public var surface: MochiSurface
    public var mesh: MochiMesh
}

public struct MochiNode: Sendable {
    public var joint: MochiJoint
    /// Where the joint pivots, in its parent's space, at rest.
    public var pivot: SIMD3<Float>
    public var parts: [MochiPart] = []
    public var children: [MochiNode] = []

    public func all() -> [MochiNode] { [self] + children.flatMap { $0.all() } }
}

/// A built Mochi: its joint tree plus the meshes swapped in for expressions.
public struct MochiModel: Sendable {
    public var root: MochiNode
    /// The eyes part's mesh for "open" (also wide/half/down), "happy" (^ ^) and "closed" (‿ ‿).
    public var eyeMeshes: [String: MochiMesh]
    public var mouthMeshes: [MochiPosture.Mouth: MochiMesh]
    public var palette: MochiPalette
    public var floppyEar: MochiFloppyEar
    public var accessories: [MochiAccessory]

    public var nodes: [MochiNode] { root.all() }
    public var partCount: Int { nodes.reduce(0) { $0 + $1.parts.count } }
    public var triangleCount: Int { nodes.reduce(0) { $0 + $1.parts.reduce(0) { $0 + $1.mesh.triangleCount } } }
}

/// A joint's local transform for a posture.
public struct MochiTransform: Equatable, Sendable {
    public var translation: SIMD3<Float>
    public var rotation: simd_quatf
    public var scale: SIMD3<Float>
    public var visible: Bool

    public init(translation: SIMD3<Float>, rotation: simd_quatf = MochiMath.identity, scale: SIMD3<Float> = .one, visible: Bool = true) {
        self.translation = translation
        self.rotation = rotation
        self.scale = scale
        self.visible = visible
    }
}

public enum MochiRecipe {
    public enum Detail: Sendable {
        /// The overlay and close-ups.
        case full
        /// A small figure in a room.
        case room

        var sphere: MochiMesh {
            switch self {
            case .full: return MochiMesh.sphere(segments: 28, rings: 18)
            case .room: return MochiMesh.sphere(segments: 14, rings: 9)
            }
        }
        var segments: Int { self == .full ? 20 : 10 }
        var rings: Int { self == .full ? 6 : 3 }
    }

    // Rest pivots (parent space).
    public static let headPivot = SIMD3<Float>(0, 0.36, 0)
    public static let pawPivot = SIMD3<Float>(0.115, 0.285, 0.09)
    public static let earPivot = SIMD3<Float>(0.125, 0.55, -0.03)
    public static let earBaseLength: Float = 0.165
    public static let eyesPivot = SIMD3<Float>(0, 0.2, 0.255)
    public static let eyeX: Float = 0.148
    public static let eyeYaw: Float = 0.45
    static let feetPivot = SIMD3<Float>(0, 0, -0.02)
    static let cheeksPivot = SIMD3<Float>(0, 0.125, 0.165)
    static let nosePivot = SIMD3<Float>(0, 0.163, 0.29)
    static let mouthPivot = SIMD3<Float>(0, 0.133, 0.276)
    static let sweatPivot = SIMD3<Float>(0.32, 0.42, 0.08)

    /// Accessory colours.
    public enum Colors {
        public static let lavender = "#C9B6F2"
        public static let lavenderDeep = "#A992E3"
        public static let brass = "#C9A45C"
        public static let sage = "#A9C3A0"
        public static let rose = "#E58FA5"
        public static let cream = "#FFF4DC"
        public static let sprout = "#8CC77E"
        public static let bow = "#F28DAA"
        public static let paint = "#8FB8E8"
        public static let sweat = "#9ED8FF"
        public static let sparkle = "#FFFFFF"
    }

    /// Side of each ear (-1 your left, +1 your right) and whether it flops.
    public static func earIsFloppy(_ side: Float, _ floppy: MochiFloppyEar) -> Bool {
        (floppy == .left && side < 0) || (floppy == .right && side > 0)
    }

    public static func build(look: MochiLook, accessories: [MochiAccessory] = [], detail: Detail = .full) -> MochiModel {
        let palette = look.palette
        let sphere = detail.sphere
        let seg = detail.segments, rings = detail.rings
        let fur = MochiSurface(palette.fur, .fur)
        let shade = MochiSurface(palette.shade, .fur)
        let pink = MochiSurface(palette.accent, .fur)
        let eye = MochiSurface(palette.eye, .glossy)
        let worn = Array(accessories.prefix(MochiAccessory.maxWorn))

        func parts(_ list: [(String, MochiSurface, MochiMesh)]) -> [MochiPart] {
            list.filter { !$0.2.isEmpty }.map { MochiPart(name: $0.0, surface: $0.1, mesh: $0.2) }
        }

        // Feet: two flattened ovals with tiny pink pads (three dots and a bean).
        var feetFur = MochiMesh(), pads = MochiMesh()
        for x: Float in [-0.1, 0.1] {
            feetFur.add(sphere, at: [x, 0.048, 0.09], scale: [0.085, 0.05, 0.11])
            pads.add(sphere, at: [x, 0.004, 0.095], scale: [0.03, 0.009, 0.024])
            for dx: Float in [-0.024, 0, 0.024] {
                pads.add(sphere, at: [x + dx, 0.008, 0.145 - abs(dx) * 0.4], scale: [0.012, 0.006, 0.012])
            }
        }
        let feet = MochiNode(joint: .feet, pivot: feetPivot, parts: parts([("fur", fur, feetFur), ("pads", pink, pads)]))

        // Body: a small pear, two-tone at the back, a lighter tummy, a fluffy tail.
        var bodyFur = MochiMesh(), bodyShade = MochiMesh(), tummy = MochiMesh(), tail = MochiMesh()
        bodyFur.add(sphere, at: [0, 0.18, 0], scale: [0.195, 0.175, 0.17])
        bodyFur.add(sphere, at: [0, 0.28, 0], scale: [0.15, 0.13, 0.135])
        // A fluffy ruff of little puffs around the chest.
        for index in 0..<7 {
            let a = -Float.pi * 0.85 + Float(index) / 6 * Float.pi * 0.7
            let r: Float = index % 2 == 0 ? 0.062 : 0.056
            bodyFur.add(sphere, at: [cos(a) * 0.105, 0.325 - Float(index % 2) * 0.012, -sin(a) * 0.1], scale: [r, r * 0.85, r])
        }
        bodyShade.add(sphere, at: [0, 0.2, -0.04], scale: [0.184, 0.168, 0.16])
        bodyShade.add(sphere, at: [0, 0.29, -0.035], scale: [0.14, 0.12, 0.125])
        tummy.add(sphere, at: [0, 0.19, 0.14], scale: [0.115, 0.125, 0.04])
        tail.add(sphere, at: [0, 0.15, -0.175], scale: SIMD3(repeating: 0.09))
        for (offset, r) in [(SIMD3<Float>(0.05, 0.045, -0.2), Float(0.055)), ([-0.052, 0.03, -0.2], 0.055), ([0.0, -0.03, -0.21], 0.052),
                            ([0.0, 0.075, -0.205], 0.05), ([0.04, -0.01, -0.235], 0.045), ([-0.04, 0.0, -0.235], 0.045),
                            ([0.0, 0.03, -0.25], 0.05)] {
            tail.add(sphere, at: offset, scale: SIMD3(repeating: r))
        }

        // Front paws: small nubby capsules hanging from the shoulders.
        let pawMesh = MochiMesh.capsule(length: 0.105, radius: 0.044, segments: seg, rings: rings)
        func paw(_ joint: MochiJoint, _ side: Float) -> MochiNode {
            var m = MochiMesh()
            m.add(pawMesh, at: [0, -0.052, 0])
            return MochiNode(joint: joint, pivot: pawPivot * [side, 1, 1], parts: parts([("fur", fur, m)]))
        }

        // Head: a squashed sphere, a shaded back cap.
        var headFur = MochiMesh(), headShade = MochiMesh()
        headFur.add(sphere, at: [0, 0.29, 0], scale: [0.345, 0.3, 0.315])
        headShade.add(sphere, at: [0, 0.28, -0.05], scale: [0.334, 0.287, 0.305])
        // A little tuft of fluff on top, swept forward.
        for (offset, r) in [(SIMD3<Float>(0, 0.575, 0.06), Float(0.042)), ([-0.032, 0.565, 0.085], 0.03), ([0.03, 0.57, 0.08], 0.032)] {
            headFur.add(sphere, at: offset, scale: [r, r * 0.85, r])
        }

        // Puffy cheeks with blush ovals on them.
        var cheekFur = MochiMesh(), blush = MochiMesh()
        for side: Float in [-1, 1] {
            cheekFur.add(sphere, at: [side * 0.175, 0, 0], scale: [0.125, 0.1, 0.105])
            blush.add(sphere, at: [side * 0.205, -0.004, 0.1], rotation: MochiMath.ry(side * 0.45), scale: [0.062, 0.036, 0.012])
        }
        let cheeks = MochiNode(joint: .cheeks, pivot: cheeksPivot,
                               parts: parts([("fur", fur, cheekFur), ("blush", MochiSurface(palette.blush, .blush, opacity: MochiPalette.blushOpacity), blush)]))

        // Eyes: large glossy plum ovals, low and wide, two sparkles each.
        var eyesOpen = MochiMesh(), highlights = MochiMesh(), happy = MochiMesh(), closed = MochiMesh()
        let arcUp = MochiMesh.torusArc(radius: 0.045, tube: 0.01, from: 0.45, to: .pi - 0.45, segments: seg, sides: 8)
        let arcDown = MochiMesh.torusArc(radius: 0.045, tube: 0.01, from: .pi + 0.5, to: 2 * .pi - 0.5, segments: seg, sides: 8)
        for side: Float in [-1, 1] {
            let frame = MochiMath.matrix([side * eyeX, 0, 0.012], MochiMath.ry(side * eyeYaw), .one)
            func local(_ m: MochiMesh, _ t: SIMD3<Float>, _ s: SIMD3<Float>) -> (MochiMesh, simd_float4x4) {
                (m, frame * MochiMath.matrix(t, MochiMath.identity, s))
            }
            eyesOpen.append(sphere, local(sphere, .zero, [0.064, 0.075, 0.029]).1)
            highlights.append(sphere, local(sphere, [-0.024, 0.028, 0.024], [0.024, 0.024, 0.008]).1)
            highlights.append(sphere, local(sphere, [0.022, -0.024, 0.026], [0.01, 0.01, 0.005]).1)
            happy.append(arcUp, local(arcUp, [0, -0.012, 0.02], .one).1)
            closed.append(arcDown, local(arcDown, [0, 0.02, 0.02], .one).1)
        }
        let eyes = MochiNode(joint: .eyes, pivot: eyesPivot,
                             parts: parts([("eye", eye, eyesOpen), ("highlight", MochiSurface(Colors.sparkle, .sparkle, glow: palette.highlight), highlights)]))

        // Nose: a tiny soft triangle of three merged spheres.
        var noseMesh = MochiMesh()
        for p: SIMD3<Float> in [[-0.01, 0.004, 0], [0.01, 0.004, 0], [0, -0.007, 0]] {
            noseMesh.add(sphere, at: p, scale: [0.012, 0.011, 0.008])
        }
        let nose = MochiNode(joint: .nose, pivot: nosePivot, parts: parts([("nose", pink, noseMesh)]))

        // Mouths: the "w" smile, a small "o", a wobbly frown.
        let mouthArc = MochiMesh.torusArc(radius: 0.017, tube: 0.0052, from: .pi + 0.3, to: 2 * .pi - 0.3, segments: seg / 2 + 2, sides: 6)
        var smile = MochiMesh(), open = MochiMesh(), frown = MochiMesh()
        smile.add(mouthArc, at: [-0.0165, 0.005, 0])
        smile.add(mouthArc, at: [0.0165, 0.005, 0])
        open.add(sphere, at: [0, -0.006, 0], scale: [0.019, 0.023, 0.007])
        frown.add(MochiMesh.torusArc(radius: 0.026, tube: 0.0058, from: 0.5, to: .pi - 0.5, segments: seg / 2 + 2, sides: 6), at: [0, -0.022, 0])
        let mouth = MochiNode(joint: .mouth, pivot: mouthPivot, parts: parts([("mouth", eye, smile)]))

        // A tiny blue sweat drop (shown on failure).
        var drop = MochiMesh()
        drop.add(sphere, at: .zero, scale: SIMD3(repeating: 0.026))
        drop.add(MochiMesh.cone(height: 0.042, radius: 0.0245, segments: seg), at: [0, 0.03, 0])
        let sweat = MochiNode(joint: .sweat, pivot: sweatPivot,
                              parts: parts([("sweat", MochiSurface(Colors.sweat, .glossy, opacity: 0.9), drop)]))

        // Ears: two long, slightly flattened capsules in two segments, pink inside.
        let earBase = MochiMesh.capsule(length: 0.19, radius: 0.066, segments: seg, rings: rings)
        let earTipMesh = MochiMesh.capsule(length: 0.17, radius: 0.064, segments: seg, rings: rings)
        let innerBase = MochiMesh.capsule(length: 0.17, radius: 0.036, segments: seg, rings: rings)
        let innerTip = MochiMesh.capsule(length: 0.13, radius: 0.034, segments: seg, rings: rings)
        func ear(_ side: Float) -> MochiNode {
            var baseFur = MochiMesh(), baseInner = MochiMesh(), tipFur = MochiMesh(), tipInner = MochiMesh()
            baseFur.add(earBase, at: [0, 0.085, 0], scale: [1, 1, 0.55])
            baseInner.add(innerBase, at: [0, 0.1, 0.03], scale: [1, 1, 0.3])
            tipFur.add(earTipMesh, at: [0, 0.075, 0], scale: [1, 1, 0.55])
            tipInner.add(innerTip, at: [0, 0.065, 0.029], scale: [1, 1, 0.3])
            let floppy = earIsFloppy(side, look.floppyEar)
            var tipParts = parts([("fur", fur, tipFur), ("inner", pink, tipInner)])
            var baseParts = parts([("fur", fur, baseFur), ("inner", pink, baseInner)])
            if floppy {
                tipParts += earDecorations(worn, sphere: sphere, seg: seg, onTip: true)
                baseParts += earDecorations(worn, sphere: sphere, seg: seg, onTip: false)
            }
            let tip = MochiNode(joint: side < 0 ? .earLeftTip : .earRightTip, pivot: [0, earBaseLength, 0], parts: tipParts)
            return MochiNode(joint: side < 0 ? .earLeft : .earRight, pivot: earPivot * [side, 1, 1], parts: baseParts, children: [tip])
        }

        var headParts = parts([("fur", fur, headFur), ("shade", shade, headShade)])
        headParts += headAccessories(worn, look: look, sphere: sphere, seg: seg)
        if look.floppyEar == .none {
            // Nothing to pin a sprout or bow to: it sits on top of the head.
            headParts += earDecorations(worn, sphere: sphere, seg: seg, onTip: true).map { part in
                var part = part
                var moved = MochiMesh()
                moved.add(part.mesh, at: [0.06, 0.56, 0.05])
                part.mesh = moved
                return part
            } + earDecorations(worn, sphere: sphere, seg: seg, onTip: false).map { part in
                var part = part
                var moved = MochiMesh()
                moved.add(part.mesh, at: [0.12, 0.53, 0.07])
                part.mesh = moved
                return part
            }
        }
        let head = MochiNode(joint: .head, pivot: headPivot, parts: headParts,
                             children: [cheeks, eyes, nose, mouth, sweat, ear(-1), ear(1)])

        var bodyParts = parts([("fur", fur, bodyFur), ("shade", shade, bodyShade), ("tummy", MochiSurface(palette.tummy, .fur), tummy),
                               ("tail", MochiSurface(palette.fur, .fluff), tail)])
        bodyParts += bodyAccessories(worn, sphere: sphere, seg: seg, rings: rings)
        let body = MochiNode(joint: .body, pivot: .zero, parts: bodyParts,
                             children: [paw(.pawLeft, -1), paw(.pawRight, 1), head])
        let root = MochiNode(joint: .root, pivot: .zero, children: [feet, body])
        return MochiModel(root: root, eyeMeshes: ["open": eyesOpen, "happy": happy, "closed": closed],
                          mouthMeshes: [.smile: smile, .open: open, .frown: frown],
                          palette: palette, floppyEar: look.floppyEar, accessories: worn)
    }

    // MARK: Accessories

    private static func headAccessories(_ worn: [MochiAccessory], look: MochiLook, sphere: MochiMesh, seg: Int) -> [MochiPart] {
        var result: [MochiPart] = []
        let upright: Float = look.floppyEar == .left ? 1 : -1
        if worn.contains(.headphones) {
            var m = MochiMesh()
            // The band arcs over the head and around the upright ear's base.
            m.add(MochiMesh.torusArc(radius: 0.385, tube: 0.02, from: 0.28, to: .pi - 0.28, segments: seg * 2, sides: 8), at: [0, 0.27, 0])
            let cup = MochiMesh.cylinderSlice(height: 0.055, bottom: 0.085, top: 0.085, from: 0, to: 2 * .pi, segments: seg)
            for side: Float in [-1, 1] {
                m.add(cup, at: [side * 0.375, 0.27, 0], rotation: MochiMath.rz(.pi / 2))
            }
            var cushions = MochiMesh()
            let pad = MochiMesh.torusArc(radius: 0.055, tube: 0.018, from: 0, to: 2 * .pi, segments: seg, sides: 8)
            for side: Float in [-1, 1] {
                cushions.add(pad, at: [side * 0.348, 0.27, 0], rotation: MochiMath.ry(.pi / 2))
                cushions.add(sphere, at: [side * 0.407, 0.27, 0], scale: [0.006, 0.05, 0.05])
            }
            result.append(MochiPart(name: "accessory.headphones", surface: MochiSurface(Colors.lavender, .satin), mesh: m))
            result.append(MochiPart(name: "accessory.headphones.pads", surface: MochiSurface(Colors.lavenderDeep, .satin), mesh: cushions))
        }
        if worn.contains(.glasses) {
            var m = MochiMesh()
            let ring = MochiMesh.torusArc(radius: 0.084, tube: 0.0075, from: 0, to: 2 * .pi, segments: seg * 2, sides: 6)
            for side: Float in [-1, 1] {
                let centre = eyesPivot + SIMD3(side * eyeX, 0, 0.05)
                m.add(ring, at: centre, rotation: MochiMath.ry(side * eyeYaw))
                // Temples back to the sides of the head.
                let from = centre + SIMD3(side * 0.08, 0.01, -0.03), to = SIMD3<Float>(side * 0.325, 0.27, 0.04)
                let length = simd_length(to - from)
                m.add(MochiMesh.capsule(length: length, radius: 0.006, segments: 6, rings: 2), at: (from + to) / 2,
                      rotation: simd_quatf(from: [0, 1, 0], to: simd_normalize(to - from)))
            }
            m.add(MochiMesh.torusArc(radius: 0.03, tube: 0.0065, from: 0.5, to: .pi - 0.5, segments: seg / 2 + 2, sides: 6),
                  at: eyesPivot + [0, 0.0, 0.06])
            result.append(MochiPart(name: "accessory.glasses", surface: MochiSurface(Colors.brass, .metal), mesh: m))
        }
        if worn.contains(.beret) {
            var m = MochiMesh()
            let tilt = MochiMath.rz(-upright * 0.28) * MochiMath.rx(-0.12)
            m.add(sphere, at: [upright * 0.07, 0.575, -0.03], rotation: tilt, scale: [0.225, 0.075, 0.225])
            m.add(sphere, at: [upright * 0.09, 0.65, -0.035], rotation: tilt, scale: SIMD3(repeating: 0.024))
            result.append(MochiPart(name: "accessory.beret", surface: MochiSurface(Colors.rose, .fur), mesh: m))
        }
        if worn.contains(.paintSmudge) {
            var m = MochiMesh()
            let side = -upright
            m.add(sphere, at: [side * 0.225, 0.075, 0.255], rotation: MochiMath.ry(side * 0.5) * MochiMath.rz(0.4), scale: [0.034, 0.016, 0.01])
            m.add(sphere, at: [side * 0.198, 0.055, 0.272], rotation: MochiMath.ry(side * 0.45), scale: [0.01, 0.01, 0.006])
            result.append(MochiPart(name: "accessory.paintSmudge", surface: MochiSurface(Colors.paint, .fur), mesh: m))
        }
        return result
    }

    /// The sprout or bow, on the floppy ear (`onTip`: the hanging segment).
    private static func earDecorations(_ worn: [MochiAccessory], sphere: MochiMesh, seg: Int, onTip: Bool) -> [MochiPart] {
        var result: [MochiPart] = []
        if worn.contains(.sprout), onTip {
            var m = MochiMesh()
            m.add(MochiMesh.capsule(length: 0.06, radius: 0.007, segments: 6, rings: 2), at: [0, 0.07, 0.045], rotation: MochiMath.rx(0.5))
            m.add(sphere, at: [-0.022, 0.1, 0.07], rotation: MochiMath.rz(0.5), scale: [0.03, 0.01, 0.018])
            m.add(sphere, at: [0.022, 0.105, 0.07], rotation: MochiMath.rz(-0.5), scale: [0.03, 0.01, 0.018])
            result.append(MochiPart(name: "accessory.sprout", surface: MochiSurface(Colors.sprout, .fur), mesh: m))
        }
        if worn.contains(.bow), !onTip {
            var m = MochiMesh()
            m.add(sphere, at: [-0.03, 0.06, 0.04], rotation: MochiMath.rz(0.3), scale: [0.034, 0.024, 0.014])
            m.add(sphere, at: [0.03, 0.06, 0.04], rotation: MochiMath.rz(-0.3), scale: [0.034, 0.024, 0.014])
            m.add(sphere, at: [0, 0.06, 0.046], scale: [0.013, 0.013, 0.012])
            result.append(MochiPart(name: "accessory.bow", surface: MochiSurface(Colors.bow, .satin), mesh: m))
        }
        return result
    }

    private static func bodyAccessories(_ worn: [MochiAccessory], sphere: MochiMesh, seg: Int, rings: Int) -> [MochiPart] {
        var result: [MochiPart] = []
        if worn.contains(.scarf) {
            var m = MochiMesh()
            m.add(MochiMesh.torusArc(radius: 0.15, tube: 0.045, from: 0, to: 2 * .pi, segments: seg * 2, sides: 10), at: [0, 0.365, 0],
                  rotation: MochiMath.rx(.pi / 2), scale: [1, 0.92, 1])
            let end = MochiMesh.capsule(length: 0.12, radius: 0.033, segments: seg, rings: rings)
            m.add(end, at: [0.07, 0.3, 0.17], rotation: MochiMath.rz(0.12) * MochiMath.rx(-0.15), scale: [1, 1, 0.6])
            m.add(end, at: [0.115, 0.315, 0.15], rotation: MochiMath.rz(0.4) * MochiMath.rx(-0.15), scale: [1, 1, 0.6])
            result.append(MochiPart(name: "accessory.scarf", surface: MochiSurface(Colors.sage, .fur), mesh: m))
        }
        if worn.contains(.popcorn) {
            // A striped box (cream and rose), popcorn heaped on top, held in front.
            var cream = MochiMesh(), rose = MochiMesh()
            let stripes = 8
            for index in 0..<stripes {
                let from = Float(index) / Float(stripes) * 2 * .pi, to = Float(index + 1) / Float(stripes) * 2 * .pi
                let slice = MochiMesh.cylinderSlice(height: 0.12, bottom: 0.058, top: 0.074, from: from, to: to, segments: 3)
                if index % 2 == 0 { cream.add(slice, at: [0, 0.21, 0.245]) } else { rose.add(slice, at: [0, 0.21, 0.245]) }
            }
            for (offset, r) in [(SIMD3<Float>(-0.03, 0.28, 0.24), Float(0.024)), ([0.028, 0.282, 0.25], 0.022), ([0, 0.29, 0.225], 0.024),
                                ([0.005, 0.302, 0.26], 0.02), ([-0.025, 0.295, 0.265], 0.018), ([0.03, 0.295, 0.22], 0.018)] {
                cream.add(sphere, at: offset, scale: SIMD3(repeating: r))
            }
            result.append(MochiPart(name: "accessory.popcorn", surface: MochiSurface(Colors.cream, .satin), mesh: cream))
            result.append(MochiPart(name: "accessory.popcorn.stripes", surface: MochiSurface(Colors.rose, .satin), mesh: rose))
        }
        return result
    }
}

// MARK: - Rig

/// Joint transforms for a posture: the shared answer to "where is each
/// joint" for the overlay and the rooms. Animation adds on top.
public enum MochiRig {
    public static func transforms(_ posture: MochiPosture, floppyEar: MochiFloppyEar) -> [MochiJoint: MochiTransform] {
        var t: [MochiJoint: MochiTransform] = [:]
        let R = MochiRecipe.self

        t[.root] = MochiTransform(translation: .zero)
        // Body height: standing, sitting a little lower, the loaf lower still.
        let drop: Float
        switch posture.body {
        case .stand: drop = 0
        case .sit: drop = -0.025
        case .loaf: drop = -0.075
        }
        t[.body] = MochiTransform(translation: [0, drop, 0], scale: posture.body == .loaf ? [1.06, 1, 1.03] : .one)
        let toes: Float = posture.body == .sit ? -0.45 : posture.body == .loaf ? -0.15 : 0
        t[.feet] = MochiTransform(translation: R.feetPivot, rotation: MochiMath.rx(toes))

        // Head: turn, nod (the loaf nods a touch), tilt.
        let nod = posture.headNod + (posture.body == .loaf ? 0.08 : 0)
        t[.head] = MochiTransform(translation: R.headPivot,
                                  rotation: MochiMath.ry(posture.headTurn) * MochiMath.rx(nod) * MochiMath.rz(-posture.headTilt))

        // Expression.
        var eyeScale = SIMD3<Float>(repeating: posture.eyeScale * (posture.eyes == .wide ? 1.1 : 1))
        if posture.eyes == .half { eyeScale.y *= 0.42 }
        let eyeDrop: Float = posture.eyes == .down ? -0.014 : posture.eyes == .half ? -0.006 : 0
        t[.eyes] = MochiTransform(translation: R.eyesPivot + [0, eyeDrop, 0], scale: eyeScale)
        t[.cheeks] = MochiTransform(translation: R.cheeksPivot, scale: posture.cheeksPuffed ? [1.14, 1.08, 1.12] : .one)
        t[.nose] = MochiTransform(translation: R.nosePivot)
        t[.mouth] = MochiTransform(translation: R.mouthPivot)
        t[.sweat] = MochiTransform(translation: R.sweatPivot, visible: posture.sweat)

        // Paws.
        for (joint, side) in [(MochiJoint.pawLeft, Float(-1)), (.pawRight, 1)] {
            let pivot = R.pawPivot * [side, 1, 1]
            var direction = SIMD3<Float>(-side * 0.32, -0.62, 0.72)   // resting on the tummy
            var position = pivot
            switch posture.paws {
            case .rest: break
            case .chin where side > 0:
                direction = [-0.3, 0.6, 0.74]
                position = pivot + [-0.01, 0.0, 0.07]
            case .toMouth where side > 0:
                direction = [-0.35, 0.75, 0.6]
                position = pivot + [-0.01, 0.02, 0.08]
            case .brush where side > 0: direction = [0.42, 0.05, 0.9]
            case .hold: direction = [-side * 0.32, -0.18, 0.93]
            case .tucked:
                direction = [-side * 0.25, -0.85, 0.45]
                position = pivot + [-side * 0.03, -0.09, -0.04]
            default: break
            }
            t[joint] = MochiTransform(translation: position, rotation: MochiMath.pointing(direction))
        }

        // Ears. The upright one curves gently back; the floppy one bends
        // over the side of the head at its middle joint.
        for side: Float in [-1, 1] {
            let floppy = MochiRecipe.earIsFloppy(side, floppyEar)
            let base: simd_quatf, tip: simd_quatf
            if posture.droop {
                base = MochiMath.rz(-side * 0.55) * MochiMath.rx(-1.25)
                tip = floppy ? MochiMath.rz(-side * 0.5) * MochiMath.rx(-0.3) : MochiMath.rx(-0.32)
            } else if posture.earsBack {
                base = MochiMath.rz(-side * 0.25) * MochiMath.rx(-0.85)
                tip = floppy ? MochiMath.rz(-side * 1.2) * MochiMath.rx(0.1) : MochiMath.rx(-0.25)
            } else if floppy {
                let lift = min(max(posture.floppyLift, 0), 1)
                base = MochiMath.rz(-side * (0.62 - 0.5 * lift)) * MochiMath.rx(-0.05 + 0.03 * posture.perk)
                tip = MochiMath.rz(-side * 2.25 * (1 - lift)) * MochiMath.rx(0.35 * (1 - lift) - 0.16 * lift)
            } else {
                base = MochiMath.rz(-side * (0.12 - 0.05 * posture.perk)) * MochiMath.rx(-0.12 + 0.1 * posture.perk)
                tip = MochiMath.rx(-0.2 + 0.15 * posture.perk)
            }
            t[side < 0 ? .earLeft : .earRight] = MochiTransform(translation: R.earPivot * [side, 1, 1], rotation: base)
            t[side < 0 ? .earLeftTip : .earRightTip] = MochiTransform(translation: [0, R.earBaseLength, 0], rotation: tip)
        }
        return t
    }

    /// The ear that twitches and leads the spring motion: the upright one
    /// (your left when both are up).
    public static func uprightEar(_ floppy: MochiFloppyEar) -> (base: MochiJoint, tip: MochiJoint) {
        floppy == .left ? (.earRight, .earRightTip) : (.earLeft, .earLeftTip)
    }

    public static func floppyEar(_ floppy: MochiFloppyEar) -> (base: MochiJoint, tip: MochiJoint)? {
        switch floppy {
        case .left: return (.earLeft, .earLeftTip)
        case .right: return (.earRight, .earRightTip)
        case .none: return nil
        }
    }
}
