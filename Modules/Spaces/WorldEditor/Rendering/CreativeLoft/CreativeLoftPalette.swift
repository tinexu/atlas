import AppKit
import AtlasSpaces
import RealityKit

/// Every colour and material of the Creative Studio loft, in one place.
/// Change a hex value or a roughness here and the loft rebuilds with it
/// (`CreativeLoftPalette.current`). Colours are sRGB hex.
public struct CreativeLoftPalette: Equatable, Sendable {
    // Colours
    public var blush = "#F6D6DC"
    public var rose = "#E8A6B4"
    public var mauve = "#C98A9B"
    public var berry = "#8E3B5B"
    public var cream = "#FFF4EC"
    public var warmLight = "#FFE9D6"
    public var peach = "#FFC4A8"
    public var brass = "#D4A55A"
    public var sage = "#8FB59A"
    public var deepGreen = "#4F7D5E"
    public var paleWood = "#E9CDB4"
    public var neonPink = "#FF7FB0"
    public var terrazzo = "#F3E1DC"

    // Material settings
    public var wallRoughness: Float = 0.9
    public var roseWallRoughness: Float = 0.85
    public var floorRoughness: Float = 0.55
    public var floorClearcoat: Float = 0.3
    public var woodRoughness: Float = 0.7
    public var brassRoughness: Float = 0.3
    public var ceramicRoughness: Float = 0.35
    public var ceramicClearcoat: Float = 0.6
    public var glassOpacity: Float = 0.25
    public var neonIntensity: Float = 2.5
    public var screenIntensity: Float = 1.0

    // Lights (lumens, scaled for the miniature world)
    public var sunIntensity: Float = 45_000
    public var pendantIntensity: Float = 9_000
    public var neonLightIntensity: Float = 2_500
    public var fillIntensity: Float = 14_000

    public static var current = CreativeLoftPalette()

    public init() {}
}

/// The loft's materials, made once per build and shared by every prop.
@MainActor
struct CreativeLoftMaterials {
    let wallBlush: PhysicallyBasedMaterial
    let wallRose: PhysicallyBasedMaterial
    let floor: PhysicallyBasedMaterial
    let wood: PhysicallyBasedMaterial
    let brass: PhysicallyBasedMaterial
    let cream: PhysicallyBasedMaterial
    let velvet: PhysicallyBasedMaterial
    let glass: PhysicallyBasedMaterial
    let leafLight: PhysicallyBasedMaterial
    let leafDark: PhysicallyBasedMaterial
    let ceramicCream: PhysicallyBasedMaterial
    let ceramicRose: PhysicallyBasedMaterial
    let neon: PhysicallyBasedMaterial
    let bulb: PhysicallyBasedMaterial
    let berry: PhysicallyBasedMaterial
    let mauveDark: PhysicallyBasedMaterial
    let sky: UnlitMaterial
    let screenPink: PhysicallyBasedMaterial
    let screenPeach: PhysicallyBasedMaterial
    /// Small solid colours: paint, cards, books, chips.
    let paints: [String: PhysicallyBasedMaterial]

    init(_ palette: CreativeLoftPalette) {
        func color(_ hex: String) -> NSColor { NSColor(atlasHex: hex) }
        func pbr(_ hex: String, roughness: Float, metallic: Float = 0, clearcoat: Float? = nil) -> PhysicallyBasedMaterial {
            var material = PhysicallyBasedMaterial()
            material.baseColor = .init(tint: color(hex))
            material.roughness = .init(floatLiteral: roughness)
            material.metallic = .init(floatLiteral: metallic)
            if let clearcoat { material.clearcoat = .init(floatLiteral: clearcoat) }
            return material
        }
        func emissive(_ hex: String, intensity: Float, texture: TextureResource? = nil) -> PhysicallyBasedMaterial {
            var material = PhysicallyBasedMaterial()
            material.baseColor = .init(tint: color(hex))
            if let texture {
                material.emissiveColor = .init(texture: .init(texture))
            } else {
                material.emissiveColor = .init(color: color(hex))
            }
            material.emissiveIntensity = intensity
            material.roughness = 0.6
            return material
        }

        wallBlush = pbr(palette.blush, roughness: palette.wallRoughness)
        wallRose = pbr(palette.rose, roughness: palette.roseWallRoughness)
        floor = pbr(palette.terrazzo, roughness: palette.floorRoughness, clearcoat: palette.floorClearcoat)
        wood = pbr(palette.paleWood, roughness: palette.woodRoughness)
        brass = pbr(palette.brass, roughness: palette.brassRoughness, metallic: 1)
        cream = pbr(palette.cream, roughness: 1)
        var velvet = pbr(palette.mauve, roughness: 0.95)
        velvet.sheen = .init(tint: color(palette.rose))
        self.velvet = velvet
        var glass = PhysicallyBasedMaterial()
        glass.baseColor = .init(tint: .white)
        glass.roughness = 0.05
        glass.blending = .transparent(opacity: .init(floatLiteral: palette.glassOpacity))
        self.glass = glass
        leafLight = pbr(palette.sage, roughness: 0.8)
        leafDark = pbr(palette.deepGreen, roughness: 0.8)
        ceramicCream = pbr(palette.cream, roughness: palette.ceramicRoughness, clearcoat: palette.ceramicClearcoat)
        ceramicRose = pbr(palette.rose, roughness: palette.ceramicRoughness, clearcoat: palette.ceramicClearcoat)
        neon = emissive(palette.neonPink, intensity: palette.neonIntensity)
        bulb = emissive(palette.warmLight, intensity: 1.2)
        berry = pbr(palette.berry, roughness: 0.6)
        mauveDark = pbr("#7A4A5C", roughness: 0.7)

        var sky = UnlitMaterial(color: .white)
        if let texture = Self.gradient([palette.peach, palette.blush, palette.rose]) {
            sky.color = .init(tint: .white, texture: .init(texture))
        } else {
            sky.color = .init(tint: color(palette.blush))
        }
        self.sky = sky
        screenPink = emissive(palette.rose, intensity: palette.screenIntensity, texture: Self.gradient([palette.rose, palette.peach]))
        screenPeach = emissive(palette.peach, intensity: palette.screenIntensity, texture: Self.gradient([palette.peach, palette.blush]))

        var paints: [String: PhysicallyBasedMaterial] = [:]
        for hex in [palette.rose, palette.peach, palette.sage, palette.berry, palette.cream, palette.mauve, palette.blush, palette.deepGreen] {
            paints[hex] = pbr(hex, roughness: 0.5)
        }
        self.paints = paints
    }

    func paint(_ hex: String) -> PhysicallyBasedMaterial {
        paints[hex] ?? cream
    }

    /// A vertical gradient (bottom → top), 1×256, for the sky and the screen.
    static func gradient(_ hexes: [String]) -> TextureResource? {
        let height = 256
        var pixels = [UInt8](repeating: 255, count: height * 4)
        let colors = hexes.map { NSColor(atlasHex: $0).usingColorSpace(.sRGB) ?? .white }
        for row in 0..<height {
            // Row 0 is the top of the image; the texture's top is the last colour.
            let t = 1 - Double(row) / Double(height - 1)
            let scaled = t * Double(colors.count - 1)
            let index = min(Int(scaled), colors.count - 2)
            let f = CGFloat(scaled - Double(index))
            let a = colors[index], b = colors[index + 1]
            pixels[row * 4] = UInt8(((a.redComponent * (1 - f) + b.redComponent * f) * 255).rounded())
            pixels[row * 4 + 1] = UInt8(((a.greenComponent * (1 - f) + b.greenComponent * f) * 255).rounded())
            pixels[row * 4 + 2] = UInt8(((a.blueComponent * (1 - f) + b.blueComponent * f) * 255).rounded())
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let image = CGImage(width: 1, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        else { return nil }
        return try? TextureResource.generate(from: image, options: .init(semantic: .color))
    }
}
