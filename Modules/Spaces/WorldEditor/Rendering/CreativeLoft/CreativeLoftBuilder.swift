import AppKit
import AtlasSpaces
import RealityKit

/// The Creative Studio as a sunlit pink artist's loft: golden-hour light
/// through an arched window, blush walls, brass, cream fabric, plants and a
/// neon heart. Built from primitives in metres (4 × 3 m, 2.6 m tall,
/// origin at the floor centre), then scaled into the room's footprint.
///
/// Static parts that share a material are merged into one mesh each.
/// `detail: false` is the light miniature used in the Mission Control
/// overview: shell, window and sky, desk, easel, rug, neon and fairy lights.
@MainActor
enum CreativeLoftBuilder {
    /// Room units per metre (the loft is 2 × 1.5 room units).
    static let scale: Float = 0.5
    /// Where the loft's origin sits in the room so its back wall is at z = -1.
    static let offset = SIMD3<Float>(0, 0, -0.25)
    /// The loft's front edge, in room units.
    static let frontZ: Float = offset.z + 1.5 * scale

    struct Result {
        let entity: Entity
        /// Bulbs, motes, the screen and lights, for animation.
        let parts: CreativeLoftParts
    }

    static func build(objects: [SpaceObject], detail: Bool, palette: CreativeLoftPalette = .current) -> Result {
        let m = CreativeLoftMaterials(palette)
        let assignment = CreativeLoft.assign(objects)
        let loft = Entity()
        loft.name = "loft"
        loft.scale = SIMD3(repeating: scale)
        loft.position = offset
        var parts = CreativeLoftParts()

        let shell = Batches<LoftMaterial>(m)
        buildShell(shell, detail: detail)
        buildWindow(shell, detail: detail)
        buildRug(shell)
        buildDesk(shell, detail: detail)
        if detail {
            buildShelfDecor(shell)
            buildPlants(shell)
        }
        shell.flush(into: loft)

        // Interactive props: each its own entity, so it can lift and glow.
        func prop(_ role: CreativeLoftRole, _ build: (Batches<LoftMaterial>) -> Void, extra: ((Entity) -> Void)? = nil) {
            let batches = Batches<LoftMaterial>(m)
            build(batches)
            let container = Entity()
            if let object = assignment.roles[role] {
                container.name = RoomBuilder.objectName(object.id)
            } else {
                container.name = "prop:\(role.rawValue)"
            }
            batches.flush(into: container)
            extra?(container)
            loft.addChild(container)
            if assignment.roles[role] != nil { RoomBuilder.makeInteractive(container) }
        }

        prop(.monitor, { buildMonitor($0) }) { container in
            // Two screen faces cross-fade between pink and peach.
            let pink = ModelEntity(mesh: .generatePlane(width: 0.64, height: 0.36, cornerRadius: 0.015), materials: [m.screenPink])
            pink.position = [-0.9, 1.05, -0.759]
            let peach = ModelEntity(mesh: .generatePlane(width: 0.64, height: 0.36, cornerRadius: 0.015), materials: [m.screenPeach])
            peach.position = [-0.9, 1.05, -0.758]
            peach.components.set(OpacityComponent(opacity: 0))
            container.addChild(pink)
            container.addChild(peach)
            parts.screenOverlay = peach
        }
        prop(.easel, { buildEasel($0, detail: detail) })
        prop(.neon, { buildNeon($0) }) { container in
            container.components.set(OpacityComponent(opacity: 1))
            parts.neon = container
        }
        if detail {
            prop(.shelves, { buildShelves($0) })
            prop(.pegboard, { buildPegboard($0) })
            prop(.mug, { buildMug($0) })
            prop(.pouf, { buildPouf($0) })
            prop(.pendant, { buildPendant($0) }) { container in
                let bulb = ModelEntity(mesh: .generateSphere(radius: 1), materials: [m.bulb])
                bulb.scale = SIMD3(repeating: 0.04)
                bulb.position = [-0.9, 1.63, -0.6]
                container.addChild(bulb)
            }
        }

        // Fairy lights across the top of the back wall.
        let wire = Batches<LoftMaterial>(m)
        let bulbCount = 9
        for index in 0..<bulbCount {
            let t = Float(index) / Float(bulbCount - 1)
            let x = -1.85 + t * 3.7
            let y = 2.48 - 0.16 * sin(t * .pi)
            if detail {
                let bulb = ModelEntity(mesh: .generateSphere(radius: 1), materials: [m.bulb])
                bulb.scale = SIMD3(repeating: 0.015)
                bulb.position = [x, y - 0.02, -1.47]
                bulb.components.set(OpacityComponent(opacity: 1))
                loft.addChild(bulb)
                parts.bulbs.append(bulb)
            } else {
                // The miniature merges the string into one mesh that twinkles as one.
                wire.add(.bulb, LoftShapes.unitSphere, at: [x, y - 0.02, -1.47], scale: SIMD3(repeating: 0.02))
            }
            if detail, index < bulbCount - 1 {
                let next = Float(index + 1) / Float(bulbCount - 1)
                let nx = -1.85 + next * 3.7, ny = 2.48 - 0.16 * sin(next * .pi)
                let length = simd_length(SIMD2(nx - x, ny - y))
                let angle = atan2(ny - y, nx - x)
                wire.add(.brass, .generateBox(width: length, height: 0.003, depth: 0.003), at: [(x + nx) / 2, (y + ny) / 2, -1.475],
                         rotation: simd_quatf(angle: angle, axis: [0, 0, 1]))
            }
        }
        let string = Entity()
        string.name = "fairyLights"
        wire.flush(into: string)
        loft.addChild(string)
        if !detail {
            string.components.set(OpacityComponent(opacity: 1))
            parts.bulbs = [string]
        }

        if detail {
            // Dust motes drifting in the sunbeam: three slow groups.
            var random = SystemRandomNumberGenerator()
            for group in 0..<3 {
                let motes = Batches<LoftMaterial>(m)
                for _ in 0..<8 {
                    motes.add(.bulb, LoftShapes.unitSphere, at: [Float.random(in: -0.2...1.3, using: &random), Float.random(in: 0.4...1.9, using: &random),
                                                                 Float.random(in: -1.3 ... -0.3, using: &random)], scale: SIMD3(repeating: 0.006))
                }
                let holder = Entity()
                holder.name = "motes-\(group)"
                motes.flush(into: holder)
                holder.components.set(OpacityComponent(opacity: 0.8))
                loft.addChild(holder)
                parts.motes.append(holder)
            }
        }

        addLights(to: loft, detail: detail, palette: palette, parts: &parts)
        return Result(entity: loft, parts: parts)
    }

    // MARK: - Lights

    static func addLights(to loft: Entity, detail: Bool, palette: CreativeLoftPalette, parts: inout CreativeLoftParts) {
        let warm = NSColor(atlasHex: palette.warmLight)
        // Golden-hour sun: a spotlight outside the window, tilted down ~35°,
        // so only this room is lit by it and the window and plant cast shadows.
        let sun = SpotLight()
        sun.light.color = warm
        sun.light.intensity = palette.sunIntensity
        sun.light.innerAngleInDegrees = 25
        sun.light.outerAngleInDegrees = 55
        sun.light.attenuationRadius = 9 * scale
        if detail { sun.shadow = SpotLightComponent.Shadow() }
        sun.look(at: [-0.3, 0, 0.6], from: [1.0, 3.2, -3.6], relativeTo: loft)
        loft.addChild(sun, preservingWorldTransform: true)

        // Fill: keeps shadows pink, never black.
        let fill = PointLight()
        fill.light.color = NSColor(atlasHex: palette.cream)
        fill.light.intensity = palette.fillIntensity
        fill.light.attenuationRadius = 5 * scale
        fill.position = [0.4, 2.2, 1.2]
        loft.addChild(fill)

        let neon = PointLight()
        neon.light.color = NSColor(atlasHex: palette.neonPink)
        neon.light.intensity = palette.neonLightIntensity
        neon.light.attenuationRadius = 1.2 * scale
        neon.position = [-1.8, 2.1, 0.1]
        loft.addChild(neon)
        parts.neonLight = neon

        if detail {
            let pendant = PointLight()
            pendant.light.color = warm
            pendant.light.intensity = palette.pendantIntensity
            pendant.light.attenuationRadius = 2.5 * scale
            pendant.position = [-0.9, 1.55, -0.6]
            loft.addChild(pendant)
            parts.pendantLight = pendant
        }
    }

    // MARK: - Shell

    static func buildShell(_ b: Batches<LoftMaterial>, detail: Bool) {
        b.add(.floor, rbox(4.0, 0.08, 3.0, 0.04), at: [0, -0.04, 0])
        if detail {
            // Terrazzo chips: a few dozen tiny flat discs, merged per colour.
            var random = SystemRandomNumberGenerator()
            let colors: [LoftMaterial] = [.paint(CreativeLoftPalette.current.rose), .paint(CreativeLoftPalette.current.mauve),
                                          .paint(CreativeLoftPalette.current.cream)]
            for index in 0..<42 {
                let radius = Float.random(in: 0.01...0.03, using: &random)
                b.add(colors[index % 3], .generateCylinder(height: 0.002, radius: radius),
                      at: [Float.random(in: -1.9...1.9, using: &random), 0.001, Float.random(in: -1.4...1.4, using: &random)])
            }
        }
        // Left wall (rose) and baseboard.
        b.add(.wallRose, rbox(0.1, 2.6, 3.0, 0.045), at: [-2.05, 1.3, 0])
        b.add(.cream, rbox(0.02, 0.06, 3.0, 0.008), at: [-1.99, 0.03, 0])
        // Back wall (blush) around the arched window opening:
        // x -0.1…1.3, y 0.7…1.5, plus a semicircle of radius 0.7 on top.
        let z: Float = -1.55
        b.add(.wallBlush, box(1.9, 2.6, 0.1), at: [-1.05, 1.3, z])                  // left of the window
        b.add(.wallBlush, box(0.7, 2.6, 0.1), at: [1.65, 1.3, z])                   // right
        b.add(.wallBlush, box(1.4, 0.7, 0.1), at: [0.6, 0.35, z])                   // below
        b.add(.wallBlush, box(1.4, 0.4, 0.1), at: [0.6, 2.4, z])                    // above
        b.add(.wallBlush, LoftShapes.archSpandrels(radius: 0.7, depth: 0.1, segments: detail ? 32 : 16), at: [0.6, 1.5, z])
        b.add(.cream, box(1.9, 0.06, 0.02), at: [-1.05, 0.03, -1.49])
        b.add(.cream, box(0.7, 0.06, 0.02), at: [1.65, 0.03, -1.49])
        b.add(.cream, box(1.4, 0.06, 0.02), at: [0.6, 0.03, -1.49])
        // Brass trim line at 1 m, broken by the window.
        b.add(.brass, box(1.9, 0.01, 0.012), at: [-1.05, 1.0, -1.494])
        b.add(.brass, box(0.7, 0.01, 0.012), at: [1.65, 1.0, -1.494])
    }

    static func buildWindow(_ b: Batches<LoftMaterial>, detail: Bool) {
        let cx: Float = 0.6, z: Float = -1.5
        // Sky 10 cm behind the opening.
        b.add(.sky, .generatePlane(width: 1.6, height: 1.7), at: [cx, 1.45, -1.72])
        // Glass: rectangle plus a half disc for the arch.
        b.add(.glass, .generatePlane(width: 1.4, height: 0.8), at: [cx, 1.1, z - 0.03])
        b.add(.glass, LoftShapes.halfDisc(radius: 0.7, segments: detail ? 24 : 10), at: [cx, 1.5, z - 0.03])
        // Brass frame, 3 cm: sides, sill, arch, mullions.
        b.add(.brass, box(0.03, 0.8, 0.05), at: [cx - 0.7, 1.1, z])
        b.add(.brass, box(0.03, 0.8, 0.05), at: [cx + 0.7, 1.1, z])
        b.add(.brass, rbox(1.46, 0.03, 0.08, 0.01), at: [cx, 0.7, z + 0.01])
        b.add(.brass, LoftShapes.ring(radius: 0.7, thickness: 0.015, segments: detail ? 16 : 8, from: 0, to: .pi),
              at: [cx, 1.5, z], rotation: simd_quatf(angle: -.pi / 2, axis: [1, 0, 0]))
        b.add(.brass, box(0.02, 1.5, 0.04), at: [cx, 1.45, z])
        b.add(.brass, box(1.4, 0.02, 0.04), at: [cx, 1.5, z])
        guard detail else { return }
        // Window seat with cushions and a round pillow.
        b.add(.cream, rbox(1.4, 0.45, 0.4, 0.04), at: [cx, 0.225, -1.28])
        b.add(.velvet, rbox(0.62, 0.1, 0.34, 0.045), at: [cx - 0.33, 0.5, -1.28])
        b.add(.velvet, rbox(0.62, 0.1, 0.34, 0.045), at: [cx + 0.33, 0.5, -1.28])
        b.add(.paint(CreativeLoftPalette.current.rose), LoftShapes.unitSphere, at: [cx + 0.5, 0.62, -1.36], scale: [0.11, 0.11, 0.06])
    }

    static func buildRug(_ b: Batches<LoftMaterial>) {
        b.add(.cream, .generateCylinder(height: 0.01, radius: 0.9, segments: 48), at: [0.1, 0.005, 0.35])
        b.add(.paint(CreativeLoftPalette.current.rose), .generateCylinder(height: 0.012, radius: 0.75, segments: 48), at: [0.1, 0.006, 0.35])
        b.add(.paint(CreativeLoftPalette.current.blush), .generateCylinder(height: 0.014, radius: 0.5, segments: 48), at: [0.1, 0.007, 0.35])
    }

    // MARK: - Desk

    static func buildDesk(_ b: Batches<LoftMaterial>, detail: Bool) {
        let x: Float = -0.9, z: Float = -0.6
        b.add(.wood, rbox(1.5, 0.04, 0.7, 0.02), at: [x, 0.75, z])
        for dx in [Float(-0.7), 0.7] {
            for dz in [Float(-0.3), 0.3] {
                b.add(.brass, .generateCylinder(height: 0.73, radius: 0.015), at: [x + dx, 0.365, z + dz])
            }
        }
        guard detail else { return }
        // Drawing tablet and pen.
        b.add(.mauveDark, rbox(0.35, 0.01, 0.25, 0.004), at: [x + 0.05, 0.775, z + 0.15])
        b.add(.brass, .generateCylinder(height: 0.15, radius: 0.005), at: [x + 0.27, 0.776, z + 0.15],
              rotation: simd_quatf(angle: .pi / 2, axis: [1, 0, 0]) * simd_quatf(angle: 0.3, axis: [0, 0, 1]))
        // Three sketchbooks, slightly askew.
        let palette = CreativeLoftPalette.current
        for (index, hex) in [palette.cream, palette.rose, palette.sage].enumerated() {
            b.add(.paint(hex), rbox(0.22, 0.02, 0.3, 0.006), at: [x - 0.52, 0.78 + Float(index) * 0.021, z + 0.05],
                  rotation: simd_quatf(angle: Float(index) * 0.12 - 0.1, axis: [0, 1, 0]))
        }
        // Cactus in a rose pot.
        b.add(.ceramicRose, .generateCylinder(height: 0.06, radius: 0.04), at: [x - 0.6, 0.8, z - 0.22])
        b.add(.leafLight, LoftShapes.capsule(height: 0.13, radius: 0.028), at: [x - 0.6, 0.88, z - 0.22])
        // Chair: velvet seat on a brass stem.
        b.add(.velvet, rbox(0.45, 0.08, 0.45, 0.035), at: [x, 0.47, z + 0.55])
        b.add(.velvet, rbox(0.45, 0.4, 0.06, 0.03), at: [x, 0.72, z + 0.78])
        b.add(.brass, .generateCylinder(height: 0.42, radius: 0.025), at: [x, 0.22, z + 0.55])
        b.add(.brass, .generateCylinder(height: 0.02, radius: 0.22), at: [x, 0.01, z + 0.55])
    }

    static func buildMonitor(_ b: Batches<LoftMaterial>) {
        let x: Float = -0.9, z: Float = -0.78
        b.add(.brass, .generateCylinder(height: 0.015, radius: 0.09), at: [x, 0.778, z])
        b.add(.brass, .generateCylinder(height: 0.2, radius: 0.012), at: [x, 0.87, z])
        b.add(.mauveDark, rbox(0.7, 0.42, 0.03, 0.02), at: [x, 1.05, z])
    }

    static func buildMug(_ b: Batches<LoftMaterial>) {
        let x: Float = -0.45, z: Float = -0.45
        b.add(.ceramicRose, .generateCylinder(height: 0.09, radius: 0.04), at: [x, 0.815, z])
        b.add(.ceramicRose, LoftShapes.ring(radius: 0.025, thickness: 0.006, segments: 10),
              at: [x + 0.045, 0.815, z], rotation: simd_quatf(angle: .pi / 2, axis: [1, 0, 0]))
    }

    static func buildPendant(_ b: Batches<LoftMaterial>) {
        let x: Float = -0.9, z: Float = -0.6
        b.add(.brass, .generateCylinder(height: 0.9, radius: 0.004), at: [x, 2.15, z])
        b.add(.brass, .generateCone(height: 0.18, radius: 0.2), at: [x, 1.74, z])
        b.add(.cream, .generateCone(height: 0.16, radius: 0.185), at: [x, 1.725, z])
    }

    // MARK: - Easel

    static func buildEasel(_ b: Batches<LoftMaterial>, detail: Bool) {
        let x: Float = 1.3, z: Float = -0.2
        for (dx, tilt) in [(Float(-0.25), Float(-0.14)), (0.25, 0.14)] {
            b.add(.wood, .generateCylinder(height: 1.6, radius: 0.02), at: [x + dx, 0.78, z + 0.05],
                  rotation: simd_quatf(angle: tilt, axis: [0, 0, 1]) * simd_quatf(angle: -0.1, axis: [1, 0, 0]))
        }
        b.add(.wood, .generateCylinder(height: 1.5, radius: 0.02), at: [x, 0.72, z - 0.22],
              rotation: simd_quatf(angle: 0.3, axis: [1, 0, 0]))
        b.add(.wood, box(0.75, 0.03, 0.06), at: [x, 0.58, z + 0.11])
        let canvasTilt = simd_quatf(angle: -0.1, axis: [1, 0, 0])
        b.add(.cream, rbox(0.7, 0.9, 0.03, 0.012), at: [x, 1.05, z + 0.09], rotation: canvasTilt)
        let palette = CreativeLoftPalette.current
        for (hex, offset, size) in [(palette.peach, SIMD2<Float>(-0.12, 0.12), SIMD2<Float>(0.16, 0.12)),
                                    (palette.rose, [0.1, -0.05], [0.13, 0.16]),
                                    (palette.sage, [-0.05, -0.22], [0.1, 0.07])] {
            b.add(.paint(hex), LoftShapes.unitSphere, at: [x + offset.x, 1.05 + offset.y, z + 0.11 + offset.y * 0.1],
                  rotation: canvasTilt, scale: [size.x, size.y, 0.008])
        }
        guard detail else { return }
        // Side table with a palette and a jar of brushes.
        let tx: Float = 1.8, tz: Float = 0.25
        b.add(.wood, .generateCylinder(height: 0.03, radius: 0.2), at: [tx, 0.55, tz])
        b.add(.brass, .generateCylinder(height: 0.54, radius: 0.015), at: [tx, 0.27, tz])
        b.add(.wood, .generateCylinder(height: 0.01, radius: 0.1), at: [tx - 0.05, 0.57, tz + 0.02], scale: [1.3, 1, 1])
        for (index, hex) in [palette.rose, palette.peach, palette.sage, palette.berry, palette.cream].enumerated() {
            let angle = Float(index) * 0.9
            b.add(.paint(hex), LoftShapes.unitSphere, at: [tx - 0.05 + cos(angle) * 0.07, 0.578, tz + 0.02 + sin(angle) * 0.05],
                  scale: [0.016, 0.006, 0.016])
        }
        b.add(.ceramicCream, .generateCylinder(height: 0.1, radius: 0.04), at: [tx + 0.1, 0.615, tz - 0.05])
        for index in 0..<3 {
            b.add(.wood, .generateCylinder(height: 0.2, radius: 0.004), at: [tx + 0.1 + Float(index - 1) * 0.012, 0.7, tz - 0.05],
                  rotation: simd_quatf(angle: Float(index - 1) * 0.15, axis: [0, 0, 1]))
        }
    }

    static func buildPouf(_ b: Batches<LoftMaterial>) {
        b.add(.velvet, .generateCylinder(height: 0.3, radius: 0.25), at: [0.75, 0.15, 0.4])
        b.add(.velvet, LoftShapes.unitSphere, at: [0.75, 0.3, 0.4], scale: [0.25, 0.06, 0.25])
    }

    // MARK: - Left wall

    static func buildShelves(_ b: Batches<LoftMaterial>) {
        for y in [Float(1.3), 1.7] {
            b.add(.wood, rbox(0.25, 0.03, 1.0, 0.01), at: [-1.875, y, 0.1])
            for z in [Float(-0.3), 0.5] {
                b.add(.brass, box(0.2, 0.012, 0.02), at: [-1.9, y - 0.03, z])
                b.add(.brass, box(0.012, 0.08, 0.02), at: [-1.99, y - 0.06, z])
            }
        }
    }

    static func buildShelfDecor(_ b: Batches<LoftMaterial>) {
        let palette = CreativeLoftPalette.current
        // Paint jars with cream lids.
        for (index, hex) in [palette.rose, palette.peach, palette.sage, palette.berry, palette.mauve].enumerated() {
            let z = -0.3 + Float(index) * 0.1
            b.add(.paint(hex), .generateCylinder(height: 0.08, radius: 0.035), at: [-1.86, 1.355, z])
            b.add(.cream, .generateCylinder(height: 0.015, radius: 0.037), at: [-1.86, 1.402, z])
        }
        // Books standing on the top shelf.
        for (index, hex) in [palette.cream, palette.rose, palette.sage].enumerated() {
            b.add(.paint(hex), rbox(0.15, 0.2, 0.03, 0.005), at: [-1.88, 1.815, 0.42 + Float(index) * 0.035])
        }
        // Brass candle holder with a cream candle.
        b.add(.brass, .generateCylinder(height: 0.02, radius: 0.04), at: [-1.86, 1.725, 0.2])
        b.add(.cream, .generateCylinder(height: 0.1, radius: 0.015), at: [-1.86, 1.785, 0.2])
        // Trailing plant: a pot and leaves drooping over the edge.
        b.add(.ceramicCream, .generateCylinder(height: 0.09, radius: 0.05), at: [-1.86, 1.76, -0.2])
        for index in 0..<7 {
            let t = Float(index) / 6
            b.add(index.isMultiple(of: 2) ? .leafLight : .leafDark, LoftShapes.unitSphere,
                  at: [-1.76 + t * 0.03, 1.78 - t * 0.38, -0.2 + sin(t * 4) * 0.05], scale: [0.03, 0.018, 0.04])
        }
    }

    static func buildNeon(_ b: Batches<LoftMaterial>) {
        // A heart outline on the left wall, as a dense string of small spheres.
        for index in 0..<64 {
            let t = Float(index) / 64 * 2 * .pi
            let hx = 16 * pow(sin(t), 3)
            let hy = 13 * cos(t) - 5 * cos(2 * t) - 2 * cos(3 * t) - cos(4 * t)
            b.add(.neon, LoftShapes.unitSphere, at: [-1.985, 2.1 + hy * 0.011, 0.1 + hx * 0.011], scale: SIMD3(repeating: 0.008))
        }
    }

    static func buildPegboard(_ b: Batches<LoftMaterial>) {
        let x: Float = -1.1, y: Float = 1.6, z: Float = -1.485
        b.add(.cream, rbox(1.0, 0.7, 0.03, 0.012), at: [x, y, z])
        for row in 0..<4 {
            for column in 0..<7 {
                b.add(.brass, .generateCylinder(height: 0.02, radius: 0.005),
                      at: [x - 0.42 + Float(column) * 0.14, y - 0.24 + Float(row) * 0.16, z + 0.02],
                      rotation: simd_quatf(angle: .pi / 2, axis: [1, 0, 0]))
            }
        }
        let palette = CreativeLoftPalette.current
        let cards: [(String, SIMD2<Float>, Float)] = [(palette.rose, [-0.33, 0.12], 0.08), (palette.peach, [-0.1, 0.15], -0.05),
                                                      (palette.sage, [0.15, 0.1], 0.1), (palette.cream, [0.36, 0.13], -0.08),
                                                      (palette.rose, [-0.2, -0.16], -0.06), (palette.peach, [0.08, -0.15], 0.07)]
        for (hex, offset, angle) in cards {
            b.add(.paint(hex), rbox(0.16, 0.2, 0.005, 0.002), at: [x + offset.x, y + offset.y, z + 0.022],
                  rotation: simd_quatf(angle: angle, axis: [0, 0, 1]))
        }
        // Small brass scissors.
        b.add(.brass, box(0.12, 0.008, 0.004), at: [x + 0.33, y - 0.2, z + 0.024], rotation: simd_quatf(angle: 0.35, axis: [0, 0, 1]))
        b.add(.brass, box(0.12, 0.008, 0.004), at: [x + 0.33, y - 0.2, z + 0.026], rotation: simd_quatf(angle: -0.35, axis: [0, 0, 1]))
        for dx in [Float(-0.03), 0.03] {
            b.add(.brass, LoftShapes.ring(radius: 0.015, thickness: 0.003, segments: 8), at: [x + 0.27 + dx, y - 0.23, z + 0.025],
                  rotation: simd_quatf(angle: .pi / 2, axis: [1, 0, 0]))
        }
    }

    // MARK: - Plants and extras

    static func buildPlants(_ b: Batches<LoftMaterial>) {
        let x: Float = 1.7, z: Float = -1.2
        b.add(.ceramicCream, .generateCylinder(height: 0.32, radius: 0.17), at: [x, 0.16, z])
        b.add(.ceramicCream, .generateCone(height: 0.05, radius: 0.19), at: [x, 0.345, z], rotation: simd_quatf(angle: .pi, axis: [1, 0, 0]))
        b.add(.leafDark, .generateCylinder(height: 0.9, radius: 0.012), at: [x, 0.75, z])
        for index in 0..<10 {
            let angle = Float(index) * 2.4
            let height = 0.55 + Float(index) * 0.08
            b.add(index.isMultiple(of: 2) ? .leafLight : .leafDark, LoftShapes.unitSphere,
                  at: [x + cos(angle) * 0.17, height, z + sin(angle) * 0.17],
                  rotation: simd_quatf(angle: -angle, axis: [0, 1, 0]) * simd_quatf(angle: 0.5, axis: [0, 0, 1]),
                  scale: [0.19, 0.03, 0.09])
        }
    }

    // MARK: - Mesh helpers

    /// A box with rounded edges (radius clamped to what fits).
    static func rbox(_ width: Float, _ height: Float, _ depth: Float, _ radius: Float) -> LoftGeometry {
        .generateBox(width: width, height: height, depth: depth, cornerRadius: min(radius, min(width, height, depth) * 0.49))
    }

    static func box(_ width: Float, _ height: Float, _ depth: Float) -> LoftGeometry {
        .generateBox(width: width, height: height, depth: depth)
    }
}

/// Things the loft animates.
@MainActor
struct CreativeLoftParts {
    var bulbs: [Entity] = []
    var motes: [Entity] = []
    var screenOverlay: Entity?
    var neon: Entity?
    var neonLight: PointLight?
    var pendantLight: PointLight?
}

/// Material slots used while batching.
enum LoftMaterial: Hashable {
    case wallBlush, wallRose, floor, wood, brass, cream, velvet, glass, leafLight, leafDark, ceramicCream, ceramicRose
    case neon, bulb, berry, mauveDark, sky
    case paint(String)
}

extension Batches where Key == LoftMaterial {
    convenience init(_ materials: CreativeLoftMaterials) {
        self.init { key in materials.material(key) }
    }
}

extension CreativeLoftMaterials {
    func material(_ key: LoftMaterial) -> any RealityKit.Material {
        switch key {
        case .wallBlush: return wallBlush
        case .wallRose: return wallRose
        case .floor: return floor
        case .wood: return wood
        case .brass: return brass
        case .cream: return cream
        case .velvet: return velvet
        case .glass: return glass
        case .leafLight: return leafLight
        case .leafDark: return leafDark
        case .ceramicCream: return ceramicCream
        case .ceramicRose: return ceramicRose
        case .neon: return neon
        case .bulb: return bulb
        case .berry: return berry
        case .mauveDark: return mauveDark
        case .sky: return sky
        case .paint(let hex): return paint(hex)
        }
    }
}
