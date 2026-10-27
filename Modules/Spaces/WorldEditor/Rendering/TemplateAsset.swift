import AppKit
import AtlasSpaces
import RealityKit

/// Colours an asset is drawn with, derived from the room's template and the
/// Space's accent colour.
public struct AssetStyle {
    public var accent: NSColor
    public var glow: NSColor
    /// Multiplier from the room's lighting preset.
    public var tint: SIMD3<Float>

    public init(accent: NSColor, glow: NSColor, tint: SIMD3<Float>) {
        self.accent = accent
        self.glow = glow
        self.tint = tint
    }

    /// A lit, matte material in the room's light.
    @MainActor
    public func matte(_ hex: String) -> SimpleMaterial {
        SimpleMaterial(color: NSColor(atlasHex: hex).tinted(tint), roughness: 0.9, isMetallic: false)
    }

    @MainActor
    public func matte(_ color: NSColor) -> SimpleMaterial {
        SimpleMaterial(color: color.tinted(tint), roughness: 0.9, isMetallic: false)
    }

    /// Unaffected by light: screens, lamp shades, status lights.
    @MainActor
    public func glowing(_ color: NSColor) -> UnlitMaterial {
        UnlitMaterial(color: color)
    }
}

/// Something that can build the 3D model for a room or a room object.
///
/// Stage 02 ships `PrimitiveAsset`, built from boxes, planes and cylinders.
/// A USDZ-backed asset can replace any of them later by registering itself
/// in `AssetCatalog`; nothing else in Mission Control has to change.
@MainActor
public protocol TemplateAsset {
    /// Returns a model in room units, resting on y = 0 and centred on x/z.
    /// Picking and collision are added by the caller.
    func makeEntity(style: AssetStyle) -> Entity
}

/// Chooses the asset for each object kind.
@MainActor
public enum AssetCatalog {
    private static var overrides: [SpaceObjectKind: any TemplateAsset] = [:]

    /// Replaces the primitive model for `kind`, e.g. with a USDZ asset.
    public static func register(_ asset: any TemplateAsset, for kind: SpaceObjectKind) {
        overrides[kind] = asset
    }

    public static func asset(for kind: SpaceObjectKind) -> any TemplateAsset {
        overrides[kind] ?? PrimitiveAsset(kind: kind)
    }
}

/// Procedural stand-ins built from RealityKit primitives with cheap
/// materials. Each is a handful of meshes so a whole world stays light.
public struct PrimitiveAsset: TemplateAsset {
    public let kind: SpaceObjectKind

    public init(kind: SpaceObjectKind) {
        self.kind = kind
    }

    public func makeEntity(style: AssetStyle) -> Entity {
        let root = Entity()
        switch kind {
        case .monitor: buildMonitor(into: root, style: style)
        case .terminal: buildTerminal(into: root, style: style)
        case .bookshelf: buildBookshelf(into: root, style: style)
        case .clock: buildClock(into: root, style: style)
        case .cube: buildCube(into: root, style: style)
        case .lamp: buildLamp(into: root, style: style)
        case .poster: buildPoster(into: root, style: style)
        case .easel: buildEasel(into: root, style: style)
        case .neon: buildNeon(into: root, style: style)
        case .mug: buildMug(into: root, style: style)
        case .globe: buildGlobe(into: root, style: style)
        case .chalkboard: buildChalkboard(into: root, style: style)
        case .book: buildBook(into: root, style: style)
        case .keyboard: buildKeyboard(into: root, style: style)
        case .hologram: buildHologram(into: root, style: style)
        case .serverRack: buildServerRack(into: root, style: style)
        case .kanban: buildKanban(into: root, style: style)
        }
        return root
    }

    // MARK: - Builders

    private func buildMonitor(into root: Entity, style: AssetStyle) {
        let dark = style.matte("#22252B")
        root.addChild(part(.generateBox(size: [0.28, 0.02, 0.16]), dark, at: [0, 0.01, 0]))
        root.addChild(part(.generateBox(size: [0.04, 0.22, 0.04]), dark, at: [0, 0.12, -0.03]))
        root.addChild(part(.generateBox(size: [0.62, 0.38, 0.04], cornerRadius: 0.015), dark, at: [0, 0.4, 0]))
        root.addChild(part(.generatePlane(width: 0.57, height: 0.33), style.glowing(style.accent.blended(withFraction: 0.55, of: .white) ?? style.accent),
                           at: [0, 0.4, 0.021]))
    }

    private func buildTerminal(into root: Entity, style: AssetStyle) {
        root.addChild(part(.generateBox(size: [0.36, 0.3, 0.3], cornerRadius: 0.03), style.matte("#D8D2C4"), at: [0, 0.15, 0]))
        root.addChild(part(.generatePlane(width: 0.26, height: 0.18), style.glowing(NSColor(atlasHex: "#0E2A12")), at: [0, 0.18, 0.151]))
        // A few lines of green "output".
        for (index, width) in [Float(0.18), 0.12, 0.2].enumerated() {
            root.addChild(part(.generatePlane(width: width, height: 0.012), style.glowing(NSColor(atlasHex: "#4ADE80")),
                               at: [-0.1 + width / 2 - 0.02, 0.23 - Float(index) * 0.035, 0.152]))
        }
        root.addChild(part(.generateBox(size: [0.34, 0.02, 0.12]), style.matte("#C7C0B0"), at: [0, 0.01, 0.24]))
    }

    private func buildBookshelf(into root: Entity, style: AssetStyle) {
        let wood = style.matte("#7A5534")
        let width: Float = 0.6, height: Float = 0.85, depth: Float = 0.22
        root.addChild(part(.generateBox(size: [width, height, 0.02]), wood, at: [0, height / 2, -depth / 2]))
        for x in [-width / 2, width / 2] {
            root.addChild(part(.generateBox(size: [0.03, height, depth]), wood, at: [x, height / 2, 0]))
        }
        let shelfHeights: [Float] = [0.02, 0.3, 0.58, 0.84]
        for y in shelfHeights {
            root.addChild(part(.generateBox(size: [width, 0.025, depth]), wood, at: [0, y, 0]))
        }
        // Books in three colours, alternating heights.
        let colors = [style.accent, NSColor(atlasHex: "#E5D3B3"), NSColor(atlasHex: "#3F4A5A")]
        for (row, y) in shelfHeights.dropLast().enumerated() {
            var x = -width / 2 + 0.05
            var index = row
            while x < width / 2 - 0.08 {
                let bookHeight: Float = index % 3 == 0 ? 0.2 : 0.17
                root.addChild(part(.generateBox(size: [0.05, bookHeight, depth * 0.8]), style.matte(colors[index % colors.count]),
                                   at: [x, y + 0.0125 + bookHeight / 2, 0]))
                x += 0.065
                index += 1
            }
        }
    }

    private func buildClock(into root: Entity, style: AssetStyle) {
        // Wall clock: a disc facing +z, centred at the object's origin.
        let face = part(.generateCylinder(height: 0.04, radius: 0.16), style.matte("#F4F1EA"), at: [0, 0, 0])
        face.orientation = simd_quatf(angle: .pi / 2, axis: [1, 0, 0])
        root.addChild(face)
        let rim = part(.generateCylinder(height: 0.035, radius: 0.175), style.matte(style.accent), at: [0, 0, -0.01])
        rim.orientation = simd_quatf(angle: .pi / 2, axis: [1, 0, 0])
        root.addChild(rim)
        let hands = style.matte("#1F2937")
        let hour = part(.generateBox(size: [0.018, 0.08, 0.01]), hands, at: [0.02, 0.03, 0.025])
        hour.orientation = simd_quatf(angle: -.pi / 5, axis: [0, 0, 1])
        root.addChild(hour)
        let minute = part(.generateBox(size: [0.012, 0.12, 0.01]), hands, at: [-0.03, 0.04, 0.03])
        minute.orientation = simd_quatf(angle: .pi / 7, axis: [0, 0, 1])
        root.addChild(minute)
    }

    private func buildCube(into root: Entity, style: AssetStyle) {
        root.addChild(part(.generateBox(size: [0.25, 0.25, 0.25], cornerRadius: 0.02), style.matte(style.accent), at: [0, 0.125, 0]))
    }

    private func buildLamp(into root: Entity, style: AssetStyle) {
        let metal = style.matte("#2D2F33")
        root.addChild(part(.generateCylinder(height: 0.025, radius: 0.09), metal, at: [0, 0.0125, 0]))
        root.addChild(part(.generateCylinder(height: 0.5, radius: 0.012), metal, at: [0, 0.27, 0]))
        root.addChild(part(.generateCone(height: 0.16, radius: 0.12), style.glowing(style.glow), at: [0, 0.56, 0]))
    }

    private func buildGlobe(into root: Entity, style: AssetStyle) {
        root.addChild(part(.generateCylinder(height: 0.02, radius: 0.08), style.matte("#C9A15A"), at: [0, 0.01, 0]))
        root.addChild(part(.generateCylinder(height: 0.2, radius: 0.012), style.matte("#C9A15A"), at: [0, 0.11, 0]))
        root.addChild(part(.generateSphere(radius: 0.12), style.matte(style.accent), at: [0, 0.32, 0]))
    }

    private func buildChalkboard(into root: Entity, style: AssetStyle) {
        // Hangs on a wall, centred at the origin, facing +z.
        root.addChild(part(.generateBox(size: [0.5, 0.36, 0.02], cornerRadius: 0.008), style.matte("#7A5238"), at: [0, 0, 0]))
        root.addChild(part(.generatePlane(width: 0.44, height: 0.3), style.matte("#3F5A4A"), at: [0, 0, 0.011]))
    }

    private func buildBook(into root: Entity, style: AssetStyle) {
        root.addChild(part(.generateBox(size: [0.24, 0.02, 0.17], cornerRadius: 0.004), style.matte(style.accent), at: [0, 0.01, 0]))
        root.addChild(part(.generateBox(size: [0.22, 0.012, 0.16]), style.matte("#F4EBDD"), at: [0, 0.026, 0]))
    }

    private func buildKeyboard(into root: Entity, style: AssetStyle) {
        root.addChild(part(.generateBox(size: [0.26, 0.02, 0.09], cornerRadius: 0.006), style.matte("#2A2A33"), at: [0, 0.01, 0]))
        root.addChild(part(.generatePlane(width: 0.23, depth: 0.07), style.matte("#EDEBFA"), at: [0, 0.021, 0]))
    }

    private func buildHologram(into root: Entity, style: AssetStyle) {
        root.addChild(part(.generateCylinder(height: 0.2, radius: 0.1), style.matte("#2A2A33"), at: [0, 0.1, 0]))
        root.addChild(part(.generateBox(size: [0.1, 0.1, 0.1], cornerRadius: 0.015), style.glowing(style.accent), at: [0, 0.34, 0]))
    }

    private func buildServerRack(into root: Entity, style: AssetStyle) {
        root.addChild(part(.generateBox(size: [0.3, 0.7, 0.25], cornerRadius: 0.02), style.matte("#2A2A33"), at: [0, 0.35, 0]))
        root.addChild(part(.generatePlane(width: 0.2, height: 0.015), style.glowing(style.accent), at: [0, 0.55, 0.126]))
    }

    private func buildKanban(into root: Entity, style: AssetStyle) {
        // Hangs on a wall, centred at the origin, facing +z.
        root.addChild(part(.generateBox(size: [0.5, 0.32, 0.015], cornerRadius: 0.008), style.matte("#3A3F6E"), at: [0, 0, 0]))
        for (index, x) in [Float(-0.15), 0, 0.15].enumerated() {
            root.addChild(part(.generatePlane(width: 0.1, height: 0.07), style.matte(index == 1 ? style.accent : NSColor(atlasHex: "#EDEBFA")),
                               at: [x, 0.05, 0.009]))
        }
    }

    private func buildPoster(into root: Entity, style: AssetStyle) {
        // Hangs on a wall, centred at the origin, facing +z.
        root.addChild(part(.generateBox(size: [0.5, 0.36, 0.015]), style.matte("#F8F5EE"), at: [0, 0, 0]))
        root.addChild(part(.generatePlane(width: 0.42, height: 0.28), style.matte(style.accent), at: [0, 0, 0.009]))
        root.addChild(part(.generateSphere(radius: 0.05), style.matte(NSColor(atlasHex: "#FDE68A")), at: [0.1, 0.05, 0.012]))
    }

    private func buildEasel(into root: Entity, style: AssetStyle) {
        let wood = style.matte("#C8A27A")
        for (x, tilt) in [(Float(-0.12), Float(0.12)), (0.12, -0.12)] {
            let leg = part(.generateCylinder(height: 0.8, radius: 0.012), wood, at: [x, 0.4, 0])
            leg.orientation = simd_quatf(angle: tilt, axis: [0, 0, 1])
            root.addChild(leg)
        }
        root.addChild(part(.generateBox(size: [0.36, 0.44, 0.02], cornerRadius: 0.01), style.matte("#FFF4EC"), at: [0, 0.52, 0.03]))
        root.addChild(part(.generateSphere(radius: 0.06), style.matte(style.accent), at: [0.05, 0.55, 0.045]))
    }

    private func buildNeon(into root: Entity, style: AssetStyle) {
        // A small glowing heart outline on the wall, facing +z.
        let glow = style.glowing(style.accent)
        for index in 0..<16 {
            let t = Float(index) / 16 * 2 * .pi
            let x = 16 * pow(sin(t), 3), y = 13 * cos(t) - 5 * cos(2 * t) - 2 * cos(3 * t) - cos(4 * t)
            root.addChild(part(.generateSphere(radius: 0.012), glow, at: [x * 0.008, y * 0.008, 0]))
        }
    }

    private func buildMug(into root: Entity, style: AssetStyle) {
        root.addChild(part(.generateCylinder(height: 0.1, radius: 0.045), style.matte(style.accent), at: [0, 0.05, 0]))
        root.addChild(part(.generateBox(size: [0.02, 0.05, 0.015], cornerRadius: 0.006), style.matte(style.accent), at: [0.055, 0.05, 0]))
    }

    private func part(_ mesh: MeshResource, _ material: some RealityKit.Material, at position: SIMD3<Float>) -> ModelEntity {
        let entity = ModelEntity(mesh: mesh, materials: [material])
        entity.position = position
        return entity
    }
}

// MARK: - Colours

extension NSColor {
    /// Parses `#RRGGBB`; anything else becomes grey.
    public convenience init(atlasHex hex: String) {
        let digits = hex.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "#", with: "")
        var value: UInt64 = 0x80_80_80
        if digits.count == 6, let parsed = UInt64(digits, radix: 16) { value = parsed }
        self.init(
            srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255,
            alpha: 1
        )
    }

    /// `#RRGGBB` in sRGB.
    public var atlasHex: String {
        let color = usingColorSpace(.sRGB) ?? self
        let r = Int((color.redComponent * 255).rounded())
        let g = Int((color.greenComponent * 255).rounded())
        let b = Int((color.blueComponent * 255).rounded())
        return String(format: "#%02X%02X%02X", max(0, min(255, r)), max(0, min(255, g)), max(0, min(255, b)))
    }

    func tinted(_ tint: SIMD3<Float>) -> NSColor {
        let color = usingColorSpace(.sRGB) ?? self
        return NSColor(
            srgbRed: color.redComponent * CGFloat(tint.x),
            green: color.greenComponent * CGFloat(tint.y),
            blue: color.blueComponent * CGFloat(tint.z),
            alpha: color.alphaComponent
        )
    }
}
