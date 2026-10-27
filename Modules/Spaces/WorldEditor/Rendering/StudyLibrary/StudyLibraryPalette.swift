import AppKit
import AtlasSpaces
import RealityKit

/// Every colour, material setting and light of the Study Library reading
/// room, in one place. Change a hex value or a roughness here and the room
/// rebuilds with it (`StudyLibraryPalette.current`). Colours are sRGB hex.
public struct StudyLibraryPalette: Equatable, Sendable {
    // Colours
    public var sageWall = "#A9BBA3"
    public var deepSage = "#6F8A6E"
    public var forest = "#3F5A4A"
    public var walnut = "#7A5238"
    public var lightOak = "#C9A27E"
    public var cream = "#F4EBDD"
    public var parchment = "#E8D9BF"
    public var brass = "#C9A15A"
    public var lampGlow = "#FFD9A0"
    public var candleWarm = "#FFB870"
    public var skyTop = "#4A5D8A"
    public var skyLow = "#9FB0D0"
    public var dustyRose = "#C99A9A"
    public var navy = "#34466B"
    public var burgundy = "#7D3B45"
    public var leatherBrown = "#6B4A3A"

    // Material settings
    public var wallRoughness: Float = 0.9
    public var wainscotRoughness: Float = 0.75
    public var walnutRoughness: Float = 0.55
    public var walnutClearcoat: Float = 0.4
    public var oakRoughness: Float = 0.65
    public var brassRoughness: Float = 0.35
    public var leatherRoughness: Float = 0.6
    public var leatherClearcoat: Float = 0.2
    public var glassOpacity: Float = 0.2
    public var lampGlowIntensity: Float = 1.2
    public var candleIntensity: Float = 3
    public var moonIntensity: Float = 0.8
    public var bulbIntensity: Float = 1.0
    /// How much brighter the chandelier glows while the Space is active.
    public var chandelierActiveBoost: Float = 1.6

    // Lights (lumens, scaled for the miniature world)
    public var bankerLampIntensity: Float = 9_000
    /// The banker's lamp's share of full brightness while the Space is
    /// inactive; activating it fades up to full.
    public var bankerLampIdle: Float = 0.25
    public var floorLampIntensity: Float = 5_000
    public var moonlightIntensity: Float = 9_000
    public var fillIntensity: Float = 9_000

    public static var current = StudyLibraryPalette()

    public init() {}

    /// Book spine colours.
    var spines: [String] { [navy, burgundy, deepSage, dustyRose, parchment, cream] }
}

/// Material slots used while batching.
enum LibraryMaterial: Hashable {
    case wall, wainscot, forest, walnut, oak, brass, paper, leather, leatherBrown, velvet, knit, glass, shade
    case lampGlow, flame, bulb, moon, sky, rain, steam, ceramic, leaf
    case paint(String)
}

/// The room's materials, made once per build and shared by every prop.
@MainActor
struct StudyLibraryMaterials {
    let palette: StudyLibraryPalette
    private let table: [LibraryMaterial: any RealityKit.Material]

    init(_ palette: StudyLibraryPalette) {
        self.palette = palette
        func color(_ hex: String) -> NSColor { NSColor(atlasHex: hex) }
        func pbr(_ hex: String, roughness: Float, metallic: Float = 0, clearcoat: Float? = nil) -> PhysicallyBasedMaterial {
            var material = PhysicallyBasedMaterial()
            material.baseColor = .init(tint: color(hex))
            material.roughness = .init(floatLiteral: roughness)
            material.metallic = .init(floatLiteral: metallic)
            if let clearcoat { material.clearcoat = .init(floatLiteral: clearcoat) }
            return material
        }
        func translucent(_ hex: String, opacity: Float) -> UnlitMaterial {
            var material = UnlitMaterial(color: color(hex))
            material.blending = .transparent(opacity: .init(floatLiteral: opacity))
            return material
        }

        var table: [LibraryMaterial: any RealityKit.Material] = [:]
        table[.wall] = pbr(palette.sageWall, roughness: palette.wallRoughness)
        table[.wainscot] = pbr(palette.deepSage, roughness: palette.wainscotRoughness)
        table[.forest] = pbr(palette.forest, roughness: 0.8)
        table[.walnut] = pbr(palette.walnut, roughness: palette.walnutRoughness, clearcoat: palette.walnutClearcoat)
        table[.oak] = pbr(palette.lightOak, roughness: palette.oakRoughness)
        table[.brass] = pbr(palette.brass, roughness: palette.brassRoughness, metallic: 1)
        table[.paper] = pbr(palette.cream, roughness: 1)
        table[.leather] = pbr(palette.burgundy, roughness: palette.leatherRoughness, clearcoat: palette.leatherClearcoat)
        table[.leatherBrown] = pbr(palette.leatherBrown, roughness: palette.leatherRoughness, clearcoat: palette.leatherClearcoat)
        var velvet = pbr(palette.deepSage, roughness: 0.95)
        velvet.sheen = .init(tint: color(palette.sageWall))
        table[.velvet] = velvet
        var knit = pbr(palette.cream, roughness: 1)
        knit.sheen = .init(tint: color(palette.parchment))
        table[.knit] = knit
        var glass = PhysicallyBasedMaterial()
        glass.baseColor = .init(tint: .white)
        glass.roughness = 0.05
        glass.blending = .transparent(opacity: .init(floatLiteral: palette.glassOpacity))
        table[.glass] = glass
        // Banker's-lamp glass: deep green and glossy outside; the warm glow
        // comes from the separate `lampGlow` surface under it.
        table[.shade] = pbr(palette.forest, roughness: 0.15, clearcoat: 0.8)
        table[.lampGlow] = Self.emissive(palette.lampGlow, intensity: palette.lampGlowIntensity)
        table[.flame] = Self.emissive(palette.candleWarm, intensity: palette.candleIntensity)
        table[.bulb] = Self.emissive(palette.lampGlow, intensity: palette.bulbIntensity)
        table[.moon] = Self.emissive(palette.cream, intensity: palette.moonIntensity)
        var sky = UnlitMaterial(color: .white)
        if let texture = CreativeLoftMaterials.gradient([palette.skyLow, palette.skyTop]) {
            sky.color = .init(tint: .white, texture: .init(texture))
        } else {
            sky.color = .init(tint: color(palette.skyLow))
        }
        table[.sky] = sky
        table[.rain] = translucent("#E4ECF7", opacity: 0.45)
        table[.steam] = translucent("#FFFFFF", opacity: 0.3)
        table[.ceramic] = pbr(palette.cream, roughness: 0.35, clearcoat: 0.6)
        table[.leaf] = pbr(palette.deepSage, roughness: 0.8)
        for hex in palette.spines + [palette.forest, palette.sageWall, palette.lightOak, palette.walnut] {
            table[.paint(hex)] = pbr(hex, roughness: 0.7)
        }
        self.table = table
    }

    func material(_ key: LibraryMaterial) -> any RealityKit.Material {
        table[key] ?? table[.paper]!
    }

    /// A warm glowing surface; also used to fade the lamp and chandelier.
    static func emissive(_ hex: String, intensity: Float) -> PhysicallyBasedMaterial {
        var material = PhysicallyBasedMaterial()
        material.baseColor = .init(tint: NSColor(atlasHex: hex))
        material.emissiveColor = .init(color: NSColor(atlasHex: hex))
        material.emissiveIntensity = intensity
        material.roughness = 0.6
        return material
    }
}

extension Batches where Key == LibraryMaterial {
    convenience init(_ materials: StudyLibraryMaterials) {
        self.init { key in materials.material(key) }
    }
}
