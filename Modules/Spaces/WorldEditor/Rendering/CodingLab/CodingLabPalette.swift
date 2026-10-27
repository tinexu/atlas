import AppKit
import AtlasSpaces
import RealityKit

/// Every colour, material setting and light of the Coding Lab night loft,
/// in one place. Change a hex value or a roughness here and the room
/// rebuilds with it (`CodingLabPalette.current`). Colours are sRGB hex.
public struct CodingLabPalette: Equatable, Sendable {
    // Colours
    public var indigoWall = "#2B2F5A"
    public var deepNight = "#1B1E3D"
    public var slatePanel = "#3A3F6E"
    public var lavender = "#B9A8F0"
    public var softViolet = "#8C7AE6"
    public var cyanGlow = "#6FE3E8"
    public var mint = "#7FE0B0"
    public var peach = "#FFB59A"
    public var offWhite = "#EDEBFA"
    public var graphite = "#2A2A33"
    public var aluminum = "#B8BCCB"
    public var paleWood = "#D8BFA4"
    public var cityWarm = "#FFD58A"
    public var cityCool = "#9FD8FF"
    public var concrete = "#3C3F55"
    public var leafLight = "#7FE0B0"
    public var leafDark = "#4F7D5E"
    public var lampWarm = "#FFD9C0"

    // Material settings
    public var wallRoughness: Float = 0.85
    public var panelRoughness: Float = 0.7
    public var concreteRoughness: Float = 0.6
    public var concreteClearcoat: Float = 0.25
    public var woodRoughness: Float = 0.6
    public var aluminumRoughness: Float = 0.3
    public var graphiteRoughness: Float = 0.5
    public var glassOpacity: Float = 0.2
    public var hologramOpacity: Float = 0.35
    public var screenIntensity: Float = 1.3
    public var laptopScreenIntensity: Float = 0.5
    public var ledIntensity: Float = 2
    public var cityLightIntensity: Float = 1.4

    // Lights (lumens, scaled for the miniature world)
    public var monitorGlowIntensity: Float = 2_500
    public var deskLampIntensity: Float = 7_000
    public var moonlightIntensity: Float = 8_000
    public var fillIntensity: Float = 9_000

    public static var current = CodingLabPalette()

    public init() {}

    /// Syntax colours for the code screens.
    var syntax: [String] { [lavender, cyanGlow, mint, peach, offWhite] }
}

/// Material slots used while batching.
enum LabMaterial: Hashable {
    case wall, night, panel, concrete, seam, wood, aluminum, graphite, slate, glass
    case ledLavender, ledCyan, ledMint, floorGlow, hologram
    case sky, skyline, moon, moonShadow, cityWarm, cityCool
    case fabric, leaf, leafDark, ceramic, lampBulb
    case paint(String)
}

/// The room's materials, made once per build and shared by every prop.
@MainActor
struct CodingLabMaterials {
    let palette: CodingLabPalette
    private let table: [LabMaterial: any RealityKit.Material]

    init(_ palette: CodingLabPalette) {
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

        var table: [LabMaterial: any RealityKit.Material] = [:]
        table[.wall] = pbr(palette.indigoWall, roughness: palette.wallRoughness)
        table[.night] = pbr(palette.deepNight, roughness: palette.wallRoughness)
        table[.panel] = pbr(palette.slatePanel, roughness: palette.panelRoughness)
        table[.concrete] = pbr(palette.concrete, roughness: palette.concreteRoughness, clearcoat: palette.concreteClearcoat)
        table[.seam] = pbr("#2E3146", roughness: 0.8)
        table[.wood] = pbr(palette.paleWood, roughness: palette.woodRoughness)
        table[.aluminum] = pbr(palette.aluminum, roughness: palette.aluminumRoughness, metallic: 1)
        table[.graphite] = pbr(palette.graphite, roughness: palette.graphiteRoughness)
        table[.slate] = pbr(palette.slatePanel, roughness: 0.9)
        var glass = PhysicallyBasedMaterial()
        glass.baseColor = .init(tint: .white)
        glass.roughness = 0.05
        glass.blending = .transparent(opacity: .init(floatLiteral: palette.glassOpacity))
        table[.glass] = glass
        table[.ledLavender] = Self.emissive(palette.lavender, intensity: palette.ledIntensity)
        table[.ledCyan] = Self.emissive(palette.cyanGlow, intensity: palette.ledIntensity)
        table[.ledMint] = Self.emissive(palette.mint, intensity: palette.ledIntensity)
        var floorGlow = UnlitMaterial(color: color(palette.lavender))
        if let falloff = Self.softFalloff() {
            floorGlow.blending = .transparent(opacity: .init(scale: 0.35, texture: .init(falloff)))
        } else {
            floorGlow.blending = .transparent(opacity: 0.15)
        }
        table[.floorGlow] = floorGlow
        table[.hologram] = translucent(palette.cyanGlow, opacity: palette.hologramOpacity)
        var sky = UnlitMaterial(color: .white)
        if let texture = CreativeLoftMaterials.gradient([palette.softViolet, palette.slatePanel, palette.deepNight]) {
            sky.color = .init(tint: .white, texture: .init(texture))
        } else {
            sky.color = .init(tint: color(palette.slatePanel))
        }
        table[.sky] = sky
        table[.skyline] = UnlitMaterial(color: color(palette.deepNight))
        table[.moon] = Self.emissive(palette.offWhite, intensity: 1.2)
        // The sky's colour where the moon hangs, to bite the crescent.
        table[.moonShadow] = UnlitMaterial(color: color("#272A52"))
        table[.cityWarm] = Self.emissive(palette.cityWarm, intensity: palette.cityLightIntensity)
        table[.cityCool] = Self.emissive(palette.cityCool, intensity: palette.cityLightIntensity)
        table[.fabric] = pbr(palette.lavender, roughness: 1)
        table[.leaf] = pbr("#67AE87", roughness: 0.8)
        table[.leafDark] = pbr(palette.leafDark, roughness: 0.8)
        table[.ceramic] = pbr(palette.offWhite, roughness: 0.35, clearcoat: 0.6)
        table[.lampBulb] = Self.emissive(palette.lampWarm, intensity: 1.5)
        for hex in palette.syntax + [palette.softViolet, palette.slatePanel, palette.graphite] {
            table[.paint(hex)] = pbr(hex, roughness: 0.6)
        }
        self.table = table
    }

    func material(_ key: LabMaterial) -> any RealityKit.Material {
        table[key] ?? table[.graphite]!
    }

    static func emissive(_ hex: String, intensity: Float) -> PhysicallyBasedMaterial {
        var material = PhysicallyBasedMaterial()
        material.baseColor = .init(tint: NSColor(atlasHex: hex))
        material.emissiveColor = .init(color: NSColor(atlasHex: hex))
        material.emissiveIntensity = intensity
        material.roughness = 0.5
        return material
    }

    /// An oval that fades from opaque in the middle to clear at the edges,
    /// for soft glows on the floor and desk.
    static func softFalloff(width: Int = 64, height: Int = 32) -> TextureResource? {
        var pixels = [UInt8](repeating: 0, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                let dx = (Float(x) + 0.5) / Float(width) * 2 - 1, dy = (Float(y) + 0.5) / Float(height) * 2 - 1
                let t = max(0, 1 - sqrt(dx * dx + dy * dy))
                pixels[y * width + x] = UInt8(t * t * (3 - 2 * t) * 255)
            }
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: width,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        else { return nil }
        return try? TextureResource.generate(from: image, options: .init(semantic: .raw))
    }

    /// A screen that glows with `texture`.
    static func screen(_ texture: TextureResource, intensity: Float) -> PhysicallyBasedMaterial {
        var material = PhysicallyBasedMaterial()
        material.baseColor = .init(tint: .black)
        material.emissiveColor = .init(texture: .init(texture))
        material.emissiveIntensity = intensity
        // Matte, so the monitor glow doesn't put a hotspot on the screen.
        material.roughness = 1.0
        material.specular = 0.0
        return material
    }
}

extension Batches where Key == LabMaterial {
    convenience init(_ materials: CodingLabMaterials) {
        self.init { key in materials.material(key) }
    }
}

/// A small generated "code" texture: rows of rounded colour bars like
/// syntax-highlighted code (no real text). `advance()` scrolls it up a row
/// with a new line at the bottom; it's called every few seconds, never per
/// frame.
@MainActor
final class CodeScreen {
    enum Style { case editor, terminal }

    let texture: TextureResource
    private let style: Style
    private let width: Int, height: Int
    private let rowHeight = 10
    private var lines: [[(color: String, length: Int)]] = []
    private var indent: [Int] = []
    private var random: SeededRandom
    private let palette: CodingLabPalette

    init?(style: Style, width: Int, height: Int, seed: UInt64, palette: CodingLabPalette) {
        self.style = style
        self.width = width
        self.height = height
        self.palette = palette
        random = SeededRandom(seed: seed)
        guard let image = Self.image(width: width, height: height, draw: { _ in }),
              let texture = try? TextureResource.generate(from: image, options: .init(semantic: .color))
        else { return nil }
        self.texture = texture
        for _ in 0..<(height - 6) / rowHeight { appendLine() }
        redraw()
    }

    func advance() {
        lines.removeFirst()
        indent.removeFirst()
        appendLine()
        redraw()
    }

    private func appendLine() {
        var line: [(String, Int)] = []
        let count = Int.random(in: 0...4, using: &random)
        for index in 0..<count {
            let color: String
            switch style {
            case .editor: color = palette.syntax[Int.random(in: 0..<palette.syntax.count, using: &random)]
            case .terminal: color = index == 0 ? palette.mint : (Int.random(in: 0..<4, using: &random) == 0 ? palette.cyanGlow : palette.offWhite)
            }
            line.append((color, Int.random(in: 3...(style == .editor ? 9 : 7), using: &random)))
        }
        lines.append(line)
        let previous = indent.last ?? 0
        indent.append(style == .terminal ? 0 : max(0, min(3, previous + Int.random(in: -1...1, using: &random))))
    }

    private func redraw() {
        let background = NSColor(atlasHex: style == .editor ? palette.deepNight : "#101220")
        guard let image = Self.image(width: width, height: height, draw: { context in
            context.setFillColor(background.cgColor)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            let unit = CGFloat(self.width) / 64
            for (row, line) in self.lines.enumerated() {
                let y = CGFloat(self.height - 6 - (row + 1) * self.rowHeight) + 2
                if self.style == .editor {
                    // Faint line-number gutter.
                    context.setFillColor(NSColor(atlasHex: self.palette.softViolet).withAlphaComponent(0.45).cgColor)
                    context.addPath(CGPath(roundedRect: CGRect(x: 3, y: y, width: unit * 2, height: 5), cornerWidth: 2, cornerHeight: 2, transform: nil))
                    context.fillPath()
                }
                var x = (self.style == .editor ? unit * 4 : 4) + CGFloat(self.indent[row]) * unit * 2.5
                for bar in line {
                    let barWidth = CGFloat(bar.length) * unit
                    guard x + barWidth < CGFloat(self.width) - 3 else { break }
                    context.setFillColor(NSColor(atlasHex: bar.color).cgColor)
                    context.addPath(CGPath(roundedRect: CGRect(x: x, y: y, width: barWidth, height: 5), cornerWidth: 2.5, cornerHeight: 2.5, transform: nil))
                    context.fillPath()
                    x += barWidth + unit
                }
            }
        }) else { return }
        try? texture.replace(withImage: image, options: .init(semantic: .color))
    }

    private static func image(width: Int, height: Int, draw: (CGContext) -> Void) -> CGImage? {
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return nil }
        draw(context)
        return context.makeImage()
    }
}
