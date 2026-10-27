import AppKit
import AtlasSpaces
import RealityKit

/// The Coding Lab as a calm late-night coder's loft: indigo walls with
/// acoustic panels, lavender and cyan LED strips, a desk lit by code
/// screens and a warm arm lamp, a project hologram, and a big window over
/// a night city. Built from primitives in metres (4 × 3 m, 2.7 m tall,
/// origin at the floor centre), then scaled into the room's footprint,
/// like the other hand-built rooms.
///
/// Keycaps, city windows, server LEDs and buildings are merged per
/// material. `detail: false` is the miniature for the Mission Control
/// overview: shell with LED strips, window with a few buildings, the desk
/// with both screens, the chair, the hologram ring and the rack as a block.
@MainActor
enum CodingLabBuilder {
    /// Room units per metre (the room is 2 × 1.5 room units).
    static let scale: Float = 0.5
    /// Where the origin sits in the room so the back wall is at z = -1.
    static let offset = SIMD3<Float>(0, 0, -0.25)
    nonisolated static let deskTop: Float = 0.76

    struct Result {
        let entity: Entity
        let parts: CodingLabParts
    }

    typealias B = Batches<LabMaterial>

    static func build(objects: [SpaceObject], detail: Bool, palette: CodingLabPalette = .current) -> Result {
        let m = CodingLabMaterials(palette)
        let assignment = CodingLab.assign(objects)
        let room = Entity()
        room.name = "codingLab"
        room.scale = SIMD3(repeating: scale)
        room.position = offset
        var parts = CodingLabParts(palette: palette)

        let shell = B(m)
        buildShell(shell, detail: detail)
        buildWindow(shell, detail: detail)
        buildDesk(shell, detail: detail)
        buildChair(shell, detail: detail)
        if detail {
            buildDeskExtras(shell)
            buildCorner(shell)
        }
        shell.flush(into: room)
        parts.ledSegments = buildLEDs(m, into: room, segments: detail ? 6 : 1)
        if detail {
            parts.cityFlicker = buildCityLights(m, into: room)
        }

        // Interactive props: each its own entity, so it can lift and glow.
        func prop(_ role: CodingLabRole, _ build: (B) -> Void, extra: ((Entity) -> Void)? = nil) {
            let batches = B(m)
            build(batches)
            let container = Entity()
            container.name = assignment.roles[role].map { RoomBuilder.objectName($0.id) } ?? "prop:\(role.rawValue)"
            batches.flush(into: container)
            extra?(container)
            room.addChild(container)
            if assignment.roles[role] != nil { RoomBuilder.makeInteractive(container) }
        }

        let editor = CodeScreen(style: .editor, width: 256, height: 128, seed: 11, palette: palette)
        let terminal = CodeScreen(style: .terminal, width: 128, height: 224, seed: 5, palette: palette)
        parts.codeScreens = [editor, terminal].compactMap { $0 }

        prop(.ultrawide, { buildUltrawide($0, detail: detail) }) { container in
            if let editor, let screen = MeshBatch(curvedScreen()).entity(CodingLabMaterials.screen(editor.texture, intensity: palette.screenIntensity)) {
                screen.position = Ultrawide.centre
                screen.components.set(OpacityComponent(opacity: 1))
                container.addChild(screen)
                parts.screens.append(screen)
            }
        }
        prop(.portrait, { buildPortrait($0, detail: detail) }) { container in
            let holder = Entity()
            holder.position = Portrait.centre
            holder.orientation = simd_quatf(angle: Portrait.yaw, axis: [0, 1, 0])
            if let terminal {
                let screen = ModelEntity(mesh: .generatePlane(width: 0.33, height: 0.56),
                                         materials: [CodingLabMaterials.screen(terminal.texture, intensity: palette.screenIntensity)])
                screen.position = [0, 0, 0.017]
                screen.components.set(OpacityComponent(opacity: 1))
                holder.addChild(screen)
                parts.screens.append(screen)
                if detail {
                    let cursor = ModelEntity(mesh: .generateBox(width: 0.016, height: 0.022, depth: 0.002), materials: [m.material(.ledMint)])
                    cursor.position = [-0.125, -0.245, 0.019]
                    cursor.components.set(OpacityComponent(opacity: 1))
                    holder.addChild(cursor)
                    parts.cursor = cursor
                }
            }
            container.addChild(holder)
        }
        prop(.hologram, { buildPedestal($0, detail: detail) }) { container in
            guard detail else { return }
            let grow = Entity(), bob = Entity(), spin = Entity()
            grow.position = Hologram.base + [0, 0.72, 0]
            let cluster = B(m)
            buildCluster(cluster)
            cluster.flush(into: spin)
            bob.addChild(spin)
            grow.addChild(bob)
            container.addChild(grow)
            (parts.hologramGrow, parts.hologramBob, parts.hologramSpin) = (grow, bob, spin)
        }
        prop(.serverRack, { buildRack($0, detail: detail) }) { container in
            guard detail else { return }
            parts.serverLEDs = buildServerLEDs(m, into: container)
        }
        if detail {
            prop(.keyboard, { buildKeyboard($0) })
            prop(.kanban, { buildKanban($0) })
            prop(.mug, { buildMug($0) })
            if assignment.roles[.clock] != nil {
                prop(.clock, { buildClock($0) })
            }
            if let editor, let laptop = MeshBatch(laptopScreen()).entity(CodingLabMaterials.screen(editor.texture, intensity: palette.laptopScreenIntensity)) {
                room.addChild(laptop)
            }
            parts.lavaBlobs = buildLavaBlobs(palette, into: room)
            parts.steam = buildSteam(m, into: room)
        }

        addLights(to: room, detail: detail, palette: palette, parts: &parts)
        return Result(entity: room, parts: parts)
    }

    // MARK: - Lights

    static func addLights(to room: Entity, detail: Bool, palette: CodingLabPalette, parts: inout CodingLabParts) {
        // 1. Monitor glow: cool light on the desk and chair from the screens.
        let glow = PointLight()
        glow.light.color = NSColor(atlasHex: palette.cityCool)
        glow.light.intensity = palette.monitorGlowIntensity
        glow.light.attenuationRadius = 2 * scale
        glow.position = Ultrawide.centre + [0, -0.05, 0.35]
        room.addChild(glow)
        parts.monitorGlow = glow

        // 4. Violet fill, so shadows stay violet, never black.
        let fill = PointLight()
        fill.light.color = NSColor(atlasHex: palette.softViolet)
        fill.light.intensity = palette.fillIntensity
        fill.light.attenuationRadius = 6 * scale
        fill.position = [-0.9, 2.3, 1.1]
        room.addChild(fill)

        guard detail else { return }
        // 2. The warm arm lamp on the desk, the cozy counterweight.
        let lamp = SpotLight()
        lamp.light.color = NSColor(atlasHex: palette.lampWarm)
        lamp.light.intensity = palette.deskLampIntensity
        lamp.light.innerAngleInDegrees = 30
        lamp.light.outerAngleInDegrees = 75
        lamp.light.attenuationRadius = 2 * scale
        lamp.shadow = SpotLightComponent.Shadow()
        lamp.look(at: [-0.85, deskTop, -0.85], from: DeskLamp.head + [0, -0.05, 0], relativeTo: room)
        room.addChild(lamp, preservingWorldTransform: true)

        // 3. Moon and city light through the window. A spotlight just outside
        // the glass: directional lights are global in RealityKit and would
        // tint every room.
        let moon = SpotLight()
        moon.light.color = NSColor(atlasHex: palette.lavender)
        moon.light.intensity = palette.moonlightIntensity
        moon.light.innerAngleInDegrees = 30
        moon.light.outerAngleInDegrees = 60
        moon.light.attenuationRadius = 7 * scale
        moon.shadow = SpotLightComponent.Shadow()
        moon.look(at: [0.5, 0, 0.6], from: [1.6, 2.2, -1.68], relativeTo: room)
        room.addChild(moon, preservingWorldTransform: true)
    }

    // MARK: - Shell

    static func buildShell(_ b: B, detail: Bool) {
        let height: Float = 2.7, z: Float = -1.6
        b.add(.concrete, rbox(4.0, 0.08, 3.0, 0.04), at: [0, -0.04, 0])
        if detail {
            for x in [Float(-1.0), 0, 1.0] {
                b.add(.seam, box(0.008, 0.002, 2.96), at: [x, 0.001, 0])
            }
            b.add(.seam, box(3.96, 0.002, 0.008), at: [0, 0.001, 0])
        }
        // Left wall (deep night) and the back wall (indigo) around the
        // window (x 0.35…1.85, y 0.9…2.3).
        b.add(.night, rbox(0.2, height, 3.3, 0.1), at: [-2.1, height / 2, -0.15])
        b.add(.wall, rbox(2.55, height, 0.2, 0.1), at: [-0.925, height / 2, z])
        b.add(.wall, rbox(0.35, height, 0.2, 0.1), at: [2.025, height / 2, z])
        b.add(.wall, box(1.7, 0.9, 0.2), at: [1.1, 0.45, z])
        b.add(.wall, box(1.7, 0.4, 0.2), at: [1.1, 2.5, z])

        // Acoustic panels behind the desk, 0.9–2.2 m.
        guard detail else { return }
        for column in 0..<6 {
            for row in 0..<4 {
                b.add(.panel, rbox(0.33, 0.3, 0.025, 0.02),
                      at: [-1.77 + Float(column) * 0.358, 1.05 + Float(row) * 0.325, -1.487])
            }
        }
    }

    /// The LED strips (lavender along the floor edge of both walls, cyan
    /// along the top of the back wall, lavender under the desk), cut into
    /// segments from left to right so activation can sweep them on.
    static func buildLEDs(_ m: CodingLabMaterials, into room: Entity, segments: Int) -> [Entity] {
        let holders = (0..<segments).map { index -> (Entity, B) in
            let holder = Entity()
            holder.name = "led-\(index)"
            holder.components.set(OpacityComponent(opacity: 1))
            return (holder, B(m))
        }
        // The left wall runs first, then the back wall in equal pieces.
        holders[0].1.add(.ledLavender, box(0.012, 0.012, 3.0), at: [-1.99, 0.012, 0])
        let backPieces = max(1, segments - 1)
        let width = 4.0 / Float(backPieces)
        for piece in 0..<backPieces {
            let index = segments == 1 ? 0 : piece + 1
            let x = -2 + width * (Float(piece) + 0.5)
            holders[index].1.add(.ledLavender, box(width, 0.012, 0.012), at: [x, 0.012, -1.49])
            holders[index].1.add(.ledCyan, box(width, 0.012, 0.012), at: [x, 2.66, -1.49])
            if (x - width / 2 ... x + width / 2).contains(-0.7) {
                holders[index].1.add(.ledLavender, box(1.7, 0.012, 0.012), at: [-0.7, deskTop - 0.048, -0.635])
                holders[index].1.add(.floorGlow, LoftGeometry.generatePlane(width: 2.0, height: 0.8), at: [-0.7, 0.004, -0.6],
                                     rotation: simd_quatf(angle: -.pi / 2, axis: [1, 0, 0]))
            }
        }
        return holders.map { holder, batches in
            batches.flush(into: holder)
            room.addChild(holder)
            return holder
        }
    }

    // MARK: - Window

    enum Window {
        static let centre: Float = 1.1, width: Float = 1.5, bottom: Float = 0.9, top: Float = 2.3
        static var mid: Float { (bottom + top) / 2 }
    }

    static func buildWindow(_ b: B, detail: Bool) {
        let cx = Window.centre, frameZ: Float = -1.56, height = Window.top - Window.bottom
        b.add(.sky, .generatePlane(width: 2.0, height: 1.8), at: [cx, 1.6, -1.95])
        b.add(.moon, LoftShapes.unitSphere, at: [1.62, 2.1, -1.9], scale: SIMD3(repeating: 0.065))
        b.add(.moonShadow, LoftShapes.unitSphere, at: [1.655, 2.125, -1.885], scale: SIMD3(repeating: 0.06))
        if detail {
            b.add(.glass, .generatePlane(width: Window.width, height: height), at: [cx, Window.mid, -1.58])
        }
        // Slim graphite frame with one horizontal mullion.
        for side in [Float(-1), 1] {
            b.add(.graphite, rbox(0.04, height + 0.04, 0.1, 0.012), at: [cx + side * Window.width / 2, Window.mid, frameZ])
        }
        b.add(.graphite, rbox(Window.width + 0.04, 0.04, 0.1, 0.012), at: [cx, Window.top, frameZ])
        b.add(.graphite, rbox(Window.width + 0.1, 0.03, 0.18, 0.012), at: [cx, Window.bottom, -1.5])
        b.add(.graphite, box(Window.width, 0.025, 0.05), at: [cx, Window.mid, frameZ])

        // Skyline: flat rounded blocks against the sky.
        var random = SeededRandom(seed: 17)
        var x: Float = 0.3
        while x < 1.9 {
            let width = Float.random(in: detail ? 0.09...0.18 : 0.16...0.28, using: &random)
            let height = Float.random(in: 0.15...0.55, using: &random)
            b.add(.skyline, rbox(width, height, 0.04, 0.01), at: [x + width / 2, 0.85 + height / 2, -1.85])
            x += width + 0.01
        }

        guard detail else { return }
        // Window seat: a low graphite bench, a lavender beanbag, a small plant.
        b.add(.graphite, rbox(1.3, 0.38, 0.42, 0.04), at: [cx, 0.19, -1.27])
        b.add(.fabric, LoftShapes.unitSphere, at: [cx - 0.3, 0.5, -1.25], scale: [0.3, 0.17, 0.27])
        b.add(.graphite, .generateCylinder(height: 0.1, radius: 0.06), at: [cx + 0.48, 0.43, -1.32])
        for index in 0..<5 {
            let angle = Float(index) * 1.3
            b.add(index.isMultiple(of: 2) ? .leaf : .leafDark, LoftShapes.unitSphere,
                  at: [cx + 0.48 + cos(angle) * 0.03, 0.53, -1.32 + sin(angle) * 0.03],
                  rotation: simd_quatf(angle: -angle, axis: [0, 1, 0]) * simd_quatf(angle: 0.4, axis: [0, 0, 1]),
                  scale: [0.022, 0.08, 0.012])
        }
    }

    /// Tiny lit windows on the skyline, merged; a few sit in two groups that
    /// fade on and off very slowly.
    static func buildCityLights(_ m: CodingLabMaterials, into room: Entity) -> [Entity] {
        var warm = MeshBatch(), cool = MeshBatch()
        var flicker = [MeshBatch(), MeshBatch()]
        var random = SeededRandom(seed: 17)
        let dot = LoftGeometry.generateBox(width: 0.012, height: 0.016, depth: 0.003)
        var x: Float = 0.3, lit = 0
        while x < 1.9 {
            let width = Float.random(in: 0.09...0.18, using: &random)
            let height = Float.random(in: 0.15...0.55, using: &random)
            var row: Float = 0.85 + height - 0.04
            while row > 0.92 {
                var column = x + 0.02
                while column < x + width - 0.02 {
                    if Float.random(in: 0...1, using: &random) < 0.35 {
                        let position = SIMD3<Float>(column + 0.006, row, -1.828)
                        lit += 1
                        if lit.isMultiple(of: 7) {
                            flicker[lit % 2].add(dot, at: position)
                        } else if Float.random(in: 0...1, using: &random) < 0.6 {
                            warm.add(dot, at: position)
                        } else {
                            cool.add(dot, at: position)
                        }
                    }
                    column += 0.03
                }
                row -= 0.045
            }
            x += width + 0.01
        }
        for (batch, key) in [(warm, LabMaterial.cityWarm), (cool, .cityCool)] {
            if let entity = batch.entity(m.material(key)) { room.addChild(entity) }
        }
        return flicker.compactMap { batch in
            guard let entity = batch.entity(m.material(.cityWarm)) else { return nil }
            entity.components.set(OpacityComponent(opacity: 1))
            room.addChild(entity)
            return entity
        }
    }

    // MARK: - Desk

    static func buildDesk(_ b: B, detail: Bool) {
        let c = SIMD3<Float>(-0.7, 0, -1.0)
        b.add(.wood, rbox(1.8, 0.04, 0.75, 0.02), at: c + [0, deskTop - 0.02, 0])
        for dx in [Float(-0.86), 0.86] {
            for dz in [Float(-0.33), 0.33] {
                b.add(.aluminum, rbox(0.04, deskTop - 0.04, 0.04, 0.012), at: c + [dx, (deskTop - 0.04) / 2, dz])
            }
        }
        // The short return on the left, for the laptop.
        b.add(.wood, rbox(0.5, 0.04, 0.6, 0.02), at: [-1.35, deskTop - 0.02, -0.33])
        for x in [Float(-1.56), -1.14] {
            b.add(.aluminum, rbox(0.04, deskTop - 0.04, 0.04, 0.012), at: [x, (deskTop - 0.04) / 2, -0.08])
        }
        // Rug under the chair: lavender ring, slate centre.
        b.add(.fabric, .generateCylinder(height: 0.01, radius: 0.75, segments: 48), at: [-0.75, 0.005, -0.3])
        b.add(.slate, .generateCylinder(height: 0.012, radius: 0.6, segments: 48), at: [-0.75, 0.006, -0.3])
    }

    enum Ultrawide {
        static let centre = SIMD3<Float>(-0.75, 1.12, -1.27)
        static let radius: Float = 1.5
    }

    enum Portrait {
        static let centre = SIMD3<Float>(0.02, 1.2, -1.25)
        static let yaw: Float = -0.4
    }

    /// The ultrawide's screen: a gentle curve facing +z, edges forward.
    static func curvedScreen(width: Float = 0.88, height: Float = 0.35, segments: Int = 12) -> LoftGeometry {
        var g = LoftGeometry()
        let span = width / Ultrawide.radius
        for index in 0...segments {
            let angle = -span / 2 + span * Float(index) / Float(segments)
            let normal = SIMD3<Float>(-sin(angle), 0, cos(angle))
            let point = SIMD3<Float>(Ultrawide.radius * sin(angle), 0, Ultrawide.radius * (1 - cos(angle)) + 0.001)
            for v in [Float(0), 1] {
                g.positions.append(point + [0, (v - 0.5) * height, 0])
                g.normals.append(normal)
                g.uvs.append([Float(index) / Float(segments), v])
            }
        }
        for index in 0..<UInt32(segments) {
            let a = index * 2
            g.indices += [a, a + 2, a + 3, a, a + 3, a + 1]
        }
        return g
    }

    static func buildUltrawide(_ b: B, detail: Bool) {
        let c = Ultrawide.centre
        // Housing as three angled panels following the curve.
        for angle in [Float(-0.2), 0, 0.2] {
            let point = SIMD3<Float>(Ultrawide.radius * sin(angle), 0, Ultrawide.radius * (1 - cos(angle)) - 0.017)
            b.add(.graphite, rbox(0.31, 0.39, 0.03, 0.012), at: c + point, rotation: simd_quatf(angle: -angle, axis: [0, 1, 0]))
        }
        addArm(b, from: [c.x, deskTop, -1.45], to: c + [0, -0.02, -0.035], metal: detail ? .aluminum : .graphite)
    }

    static func buildPortrait(_ b: B, detail: Bool) {
        let yaw = simd_quatf(angle: Portrait.yaw, axis: [0, 1, 0])
        b.add(.graphite, rbox(0.37, 0.62, 0.03, 0.012), at: Portrait.centre, rotation: yaw)
        addArm(b, from: [Portrait.centre.x + 0.02, deskTop, -1.45], to: Portrait.centre + yaw.act([0, 0, -0.03]),
               metal: detail ? .aluminum : .graphite)
    }

    /// A monitor arm: a clamp, a pole, ball joints and a short arm. The
    /// miniature draws it in the housing's graphite (one mesh fewer).
    static func addArm(_ b: B, from clamp: SIMD3<Float>, to mount: SIMD3<Float>, metal: LabMaterial) {
        b.add(metal, rbox(0.06, 0.03, 0.08, 0.008), at: clamp + [0, 0.015, 0])
        let top = SIMD3<Float>(clamp.x, mount.y, clamp.z)
        addRod(b, metal, from: clamp, to: top, radius: 0.012)
        addRod(b, metal, from: top, to: mount, radius: 0.01)
        for joint in [top, mount] {
            b.add(metal, LoftShapes.unitSphere, at: joint, scale: SIMD3(repeating: 0.02))
        }
    }

    static func addRod(_ b: B, _ key: LabMaterial, from a: SIMD3<Float>, to c: SIMD3<Float>, radius: Float, segments: Int = 8) {
        let length = simd_length(c - a)
        guard length > 0.0001 else { return }
        b.add(key, .generateCylinder(height: length, radius: radius, segments: segments), at: (a + c) / 2,
              rotation: simd_quatf(from: [0, 1, 0], to: (c - a) / length))
    }

    enum Keyboard {
        static let centre = SIMD3<Float>(-0.75, deskTop + 0.004, -0.82)
    }

    static func buildKeyboard(_ b: B) {
        let c = Keyboard.centre
        let palette = CodingLabPalette.current
        b.add(.graphite, rbox(0.38, 0.025, 0.13, 0.008), at: c + [0, 0.0125, 0])
        let key = rbox(0.021, 0.008, 0.019, 0.004)
        for row in 0..<5 {
            for column in 0..<14 {
                let position = c + [-0.159 + Float(column) * 0.0245, 0.029, -0.049 + Float(row) * 0.0245]
                if row == 4, (5...8).contains(column) {
                    if column == 5 {
                        b.add(.paint(palette.offWhite), rbox(0.095, 0.008, 0.019, 0.004), at: position + [0.0367, 0, 0])
                    }
                    continue
                }
                let color: String
                switch (row, column) {
                case (0, 0): color = palette.peach
                case (2, 13): color = palette.cyanGlow
                case (_, 0), (_, 13): color = palette.lavender
                case (4, _): color = palette.lavender
                default: color = palette.offWhite
                }
                b.add(.paint(color), key, at: position)
            }
        }
        // Soft lavender underglow.
        b.add(.floorGlow, LoftGeometry.generatePlane(width: 0.43, height: 0.18), at: c + [0, -0.002, 0],
              rotation: simd_quatf(angle: -.pi / 2, axis: [1, 0, 0]))
    }

    enum DeskLamp {
        static let base = SIMD3<Float>(-1.45, deskTop, -1.25)
        static let elbow = SIMD3<Float>(-1.42, deskTop + 0.36, -1.18)
        static let head = SIMD3<Float>(-1.2, deskTop + 0.42, -0.98)
    }

    enum Mug {
        static let position = SIMD3<Float>(-0.22, deskTop, -0.86)
    }

    static func buildMug(_ b: B) {
        let p = Mug.position
        b.add(.ceramic, .generateCylinder(height: 0.09, radius: 0.04), at: p + [0, 0.045, 0])
        b.add(.paint(CodingLabPalette.current.lavender), .generateCylinder(height: 0.016, radius: 0.0415), at: p + [0, 0.06, 0])
        b.add(.ceramic, LoftShapes.ring(radius: 0.024, thickness: 0.006, segments: 10), at: p + [0.045, 0.045, 0],
              rotation: simd_quatf(angle: .pi / 2, axis: [1, 0, 0]))
        b.add(.paint(CodingLabPalette.current.graphite), .generateCylinder(height: 0.003, radius: 0.035), at: p + [0, 0.088, 0])
    }

    static func buildDeskExtras(_ b: B) {
        // Desk mat and mouse.
        b.add(.slate, rbox(0.85, 0.004, 0.34, 0.01), at: [-0.68, deskTop + 0.002, -0.8])
        b.add(.graphite, LoftShapes.unitSphere, at: [-0.42, deskTop + 0.016, -0.8], scale: [0.03, 0.016, 0.05])
        // Cable from the keyboard to the back edge of the desk.
        let points: [SIMD3<Float>] = (0...10).map { step in
            let t = Float(step) / 10
            let a = SIMD3<Float>(-0.75, deskTop + 0.015, -0.89), c = SIMD3<Float>(-0.62, deskTop + 0.004, -1.0)
            let d = SIMD3<Float>(-0.55, deskTop + 0.003, -1.37)
            return (1 - t) * (1 - t) * a + 2 * (1 - t) * t * c + t * t * d
        }
        for index in 0..<points.count - 1 {
            addRod(b, .graphite, from: points[index], to: points[index + 1], radius: 0.004, segments: 6)
        }
        // Laptop on a stand on the return, facing the chair.
        let laptop = Laptop.frame
        let tilt = simd_quatf(angle: 0.22, axis: [1, 0, 0])
        b.add(.aluminum, rbox(0.24, 0.012, 0.2, 0.004), at: laptop.point([0, 0.035, 0]), rotation: laptop.rotation * tilt)
        b.add(.aluminum, box(0.2, 0.05, 0.012), at: laptop.point([0, 0.022, -0.09]), rotation: laptop.rotation)
        b.add(.aluminum, rbox(0.3, 0.012, 0.21, 0.006), at: laptop.point([0, 0.05, 0]), rotation: laptop.rotation * tilt)
        b.add(.aluminum, rbox(0.3, 0.2, 0.008, 0.006), at: laptop.point(Laptop.lidCentre), rotation: laptop.rotation * Laptop.lidTilt)
        // Slim arm lamp with a warm bulb.
        b.add(.aluminum, .generateCylinder(height: 0.02, radius: 0.06), at: DeskLamp.base + [0, 0.01, 0])
        addRod(b, .aluminum, from: DeskLamp.base + [0, 0.02, 0], to: DeskLamp.elbow, radius: 0.008)
        addRod(b, .aluminum, from: DeskLamp.elbow, to: DeskLamp.head, radius: 0.008)
        b.add(.aluminum, LoftShapes.unitSphere, at: DeskLamp.elbow, scale: SIMD3(repeating: 0.014))
        b.add(.aluminum, LoftGeometry.generateCone(height: 0.08, radius: 0.05).doubleSided(), at: DeskLamp.head + [0, -0.02, 0])
        b.add(.lampBulb, LoftShapes.unitSphere, at: DeskLamp.head + [0, -0.055, 0], scale: [0.035, 0.01, 0.035])
    }

    enum Laptop {
        struct Frame {
            let origin: SIMD3<Float>
            let rotation: simd_quatf
            func point(_ local: SIMD3<Float>) -> SIMD3<Float> { origin + rotation.act(local) }
        }

        static let frame = Frame(origin: [-1.35, deskTop, -0.36], rotation: simd_quatf(angle: .pi / 2 - 0.35, axis: [0, 1, 0]))
        static let lidTilt = simd_quatf(angle: -0.2, axis: [1, 0, 0])
        static let lidCentre = SIMD3<Float>(0, 0.16, -0.1)
    }

    static func laptopScreen() -> LoftGeometry {
        var batch = MeshBatch()
        let frame = Laptop.frame
        batch.add(.generatePlane(width: 0.27, height: 0.17), at: frame.point(Laptop.lidCentre + Laptop.lidTilt.act([0, 0, 0.005])),
                  rotation: frame.rotation * Laptop.lidTilt)
        return batch.geometry
    }

    static func buildChair(_ b: B, detail: Bool) {
        let c = SIMD3<Float>(-0.75, 0, -0.32)
        b.add(.aluminum, .generateCylinder(height: 0.05, radius: 0.04), at: c + [0, 0.09, 0])
        for leg in 0..<5 {
            let angle = Float(leg) * 2 * .pi / 5 + 0.3
            let direction = SIMD3<Float>(cos(angle), 0, sin(angle))
            b.add(.aluminum, rbox(0.3, 0.025, 0.04, 0.01), at: c + direction * 0.15 + [0, 0.075, 0],
                  rotation: simd_quatf(angle: -angle, axis: [0, 1, 0]))
            if detail {
                b.add(.graphite, LoftShapes.unitSphere, at: c + direction * 0.29 + [0, 0.025, 0], scale: SIMD3(repeating: 0.025))
            }
        }
        b.add(.aluminum, .generateCylinder(height: 0.32, radius: 0.02, segments: 10), at: c + [0, 0.26, 0])
        b.add(.graphite, rbox(0.5, 0.08, 0.48, 0.035), at: c + [0, 0.46, 0])
        let lean = simd_quatf(angle: 0.12, axis: [1, 0, 0])
        b.add(.graphite, rbox(0.46, 0.62, 0.06, 0.03), at: c + [0, 0.93, 0.27], rotation: lean)
        b.add(.aluminum, rbox(0.05, 0.3, 0.025, 0.01), at: c + [0, 0.6, 0.25])
        b.add(.fabric, rbox(0.32, 0.16, 0.05, 0.025), at: c + [0, 0.78, 0.225], rotation: lean)
        if detail {
            for side in [Float(-1), 1] {
                b.add(.graphite, rbox(0.05, 0.03, 0.25, 0.012), at: c + [side * 0.27, 0.66, 0.02])
                b.add(.aluminum, rbox(0.025, 0.18, 0.025, 0.008), at: c + [side * 0.27, 0.56, 0.08])
            }
        }
    }

    // MARK: - Hologram

    enum Hologram {
        static let base = SIMD3<Float>(0.9, 0, 0.0)
        static let nodes: [SIMD3<Float>] = [[0, 0, 0], [0.16, 0.06, 0.04], [-0.12, 0.1, -0.08], [0.05, -0.12, 0.13],
                                            [-0.1, -0.06, 0.14], [0.08, 0.15, -0.12], [-0.17, -0.1, -0.05]]
        static let links: [(Int, Int)] = [(0, 1), (0, 2), (0, 3), (0, 4), (1, 5), (2, 5), (3, 4), (2, 6), (4, 6)]
    }

    static func buildPedestal(_ b: B, detail: Bool) {
        let base = Hologram.base
        b.add(.graphite, rbox(0.4, 0.4, 0.4, 0.06), at: base + [0, 0.2, 0])
        if detail {
            b.add(.aluminum, .generateCylinder(height: 0.015, radius: 0.17, segments: 24), at: base + [0, 0.4, 0])
        }
        b.add(.ledCyan, LoftShapes.ring(radius: 0.15, thickness: 0.009, segments: 24), at: base + [0, 0.412, 0])
    }

    static func buildCluster(_ b: B) {
        for (index, node) in Hologram.nodes.enumerated() {
            if index.isMultiple(of: 2) {
                let size: Float = index == 0 ? 0.08 : 0.06
                b.add(.hologram, rbox(size, size, size, 0.012), at: node, rotation: simd_quatf(angle: Float(index) * 0.5, axis: simd_normalize([1, 1, 0])))
            } else {
                b.add(.hologram, .generateSphere(radius: 0.035), at: node)
            }
        }
        for (a, c) in Hologram.links {
            addRod(b, .ledCyan, from: Hologram.nodes[a], to: Hologram.nodes[c], radius: 0.003, segments: 5)
        }
    }

    // MARK: - Left wall

    static func buildRack(_ b: B, detail: Bool) {
        let c = SIMD3<Float>(-1.8, 0, 0.2)
        b.add(.graphite, rbox(0.4, 1.4, 0.5, 0.03), at: c + [0, 0.7, 0])
        guard detail else {
            // Miniature: three LEDs.
            for index in 0..<3 {
                b.add(.ledMint, box(0.006, 0.02, 0.02), at: [-1.598, 1.2, c.z - 0.06 + Float(index) * 0.06])
            }
            return
        }
        for unit in 0..<4 {
            let y = 0.22 + Float(unit) * 0.33
            b.add(.slate, rbox(0.02, 0.28, 0.44, 0.008), at: [-1.595, y, c.z])
            for vent in 0..<5 {
                b.add(.night, box(0.004, 0.006, 0.26), at: [-1.584, y - 0.09 + Float(vent) * 0.03, c.z + 0.06])
            }
        }
        // Lava lamp and a tiny cactus on top.
        let lamp = SIMD3<Float>(-1.8, 1.4, 0.08)
        b.add(.aluminum, .generateCone(height: 0.08, radius: 0.05), at: lamp + [0, 0.04, 0])
        b.add(.glass, LoftShapes.capsule(height: 0.26, radius: 0.042), at: lamp + [0, 0.2, 0])
        b.add(.aluminum, .generateCylinder(height: 0.03, radius: 0.024), at: lamp + [0, 0.345, 0])
        let cactus = SIMD3<Float>(-1.8, 1.4, 0.36)
        b.add(.graphite, .generateCylinder(height: 0.06, radius: 0.04), at: cactus + [0, 0.03, 0])
        b.add(.leaf, LoftShapes.capsule(height: 0.13, radius: 0.025), at: cactus + [0, 0.11, 0])
        b.add(.leaf, LoftShapes.capsule(height: 0.06, radius: 0.013), at: cactus + [0.03, 0.12, 0],
              rotation: simd_quatf(angle: -0.6, axis: [0, 0, 1]))
    }

    /// Tiny LEDs on each unit, merged into six groups (by colour and
    /// alternating position) that blink on their own rhythms.
    static func buildServerLEDs(_ m: CodingLabMaterials, into container: Entity) -> [Entity] {
        let colors: [LabMaterial] = [.ledMint, .ledCyan, .ledLavender]
        var groups = Array(repeating: MeshBatch(), count: 6)
        let led = LoftGeometry.generateBox(width: 0.006, height: 0.012, depth: 0.012)
        for unit in 0..<4 {
            let y = 0.22 + Float(unit) * 0.33 + 0.1
            for index in 0..<6 {
                let group = (index % 3) * 2 + (unit + index) % 2
                groups[group].add(led, at: [-1.583, y, 0.02 + Float(index) * 0.03])
            }
        }
        return groups.enumerated().compactMap { index, batch in
            guard let entity = batch.entity(m.material(colors[index / 2])) else { return nil }
            entity.components.set(OpacityComponent(opacity: 1))
            container.addChild(entity)
            return entity
        }
    }

    static func buildLavaBlobs(_ palette: CodingLabPalette, into room: Entity) -> [Entity] {
        let lamp = SIMD3<Float>(-1.8, 1.4, 0.08)
        let blobs: [(String, Float, Float)] = [(palette.lavender, 0.13, 0.024), (palette.peach, 0.2, 0.018), (palette.lavender, 0.26, 0.015)]
        return blobs.map { hex, height, radius in
            let blob = ModelEntity(mesh: .generateSphere(radius: radius), materials: [CodingLabMaterials.emissive(hex, intensity: 1.1)])
            blob.position = lamp + [0, height, 0]
            room.addChild(blob)
            return blob
        }
    }

    static func buildKanban(_ b: B) {
        let c = SIMD3<Float>(-1.985, 1.6, -0.8)
        let palette = CodingLabPalette.current
        let facing = simd_quatf(angle: .pi / 2, axis: [0, 1, 0])
        b.add(.slate, rbox(0.03, 0.6, 1.0, 0.02), at: c)
        for column in 0..<3 {
            let z = c.z + Float(column - 1) * 0.333
            b.add(.paint(palette.lavender), box(0.004, 0.012, 0.2), at: [c.x + 0.017, c.y + 0.25, z])
            if column > 0 {
                b.add(.paint(palette.lavender), box(0.004, 0.5, 0.005), at: [c.x + 0.017, c.y - 0.02, z - 0.1665])
            }
        }
        let cards: [(String, Int, Float)] = [(palette.lavender, 0, 0.13), (palette.mint, 0, 0.0), (palette.peach, 0, -0.13),
                                             (palette.offWhite, 1, 0.13), (palette.lavender, 1, -0.01), (palette.mint, 2, 0.13),
                                             (palette.offWhite, 2, 0.0), (palette.peach, 2, -0.13), (palette.mint, 1, -0.15)]
        for (index, card) in cards.enumerated() {
            let z = c.z + Float(card.1 - 1) * 0.333 + (index.isMultiple(of: 2) ? -0.03 : 0.03)
            b.add(.paint(card.0), rbox(0.11, 0.09, 0.006, 0.008), at: [c.x + 0.02, c.y + card.2, z],
                  rotation: facing * simd_quatf(angle: Float(index % 3 - 1) * 0.06, axis: [0, 0, 1]))
        }
    }

    static func buildClock(_ b: B) {
        let c = SIMD3<Float>(-1.98, 1.95, 0.95)
        let wall = simd_quatf(angle: .pi / 2, axis: [0, 0, 1])
        b.add(.slate, .generateCylinder(height: 0.012, radius: 0.12, segments: 24), at: c, rotation: wall)
        b.add(.aluminum, LoftShapes.ring(radius: 0.125, thickness: 0.01, segments: 20), at: c, rotation: wall)
        b.add(.paint(CodingLabPalette.current.offWhite), box(0.004, 0.08, 0.01), at: c + [0.01, 0.035, 0])
        b.add(.paint(CodingLabPalette.current.offWhite), box(0.004, 0.01, 0.06), at: c + [0.01, 0, 0.025])
        b.add(.paint(CodingLabPalette.current.lavender), LoftShapes.unitSphere, at: c + [0.012, 0, 0], scale: SIMD3(repeating: 0.012))
    }

    // MARK: - Corner details

    static func buildCorner(_ b: B) {
        // Tall plant in the front-left corner.
        let pot = SIMD3<Float>(-1.7, 0, 1.2)
        b.add(.graphite, rbox(0.32, 0.4, 0.32, 0.06), at: pot + [0, 0.2, 0])
        for index in 0..<9 {
            let angle = Float(index) * 0.7
            let direction = SIMD3<Float>(cos(angle), 0, sin(angle))
            let tilt = simd_quatf(angle: 0.25 + Float(index % 3) * 0.12, axis: simd_normalize(simd_cross([0, 1, 0], direction)))
            b.add(index.isMultiple(of: 2) ? .leaf : .leafDark, LoftShapes.unitSphere,
                  at: pot + [0, 0.4, 0] + tilt.act([0, 0.32 + Float(index % 3) * 0.05, 0]) + direction * 0.03,
                  rotation: tilt * simd_quatf(angle: -angle, axis: [0, 1, 0]), scale: [0.05, 0.34, 0.012])
        }
        // A lavender cat bed with a curled-up cat, by the window bench.
        let bed = SIMD3<Float>(1.55, 0, -0.7)
        let palette = CodingLabPalette.current
        b.add(.fabric, LoftShapes.ring(radius: 0.19, thickness: 0.06, segments: 18), at: bed + [0, 0.06, 0])
        b.add(.slate, .generateCylinder(height: 0.04, radius: 0.17, segments: 24), at: bed + [0, 0.03, 0])
        let cat = LabMaterial.paint(palette.offWhite)
        b.add(cat, LoftShapes.unitSphere, at: bed + [0, 0.11, 0], scale: [0.13, 0.075, 0.1])
        b.add(cat, LoftShapes.unitSphere, at: bed + [0.09, 0.13, 0.06], scale: SIMD3(repeating: 0.055))
        for side in [Float(-1), 1] {
            b.add(cat, .generateCone(height: 0.035, radius: 0.017, segments: 8), at: bed + [0.09 + side * 0.025, 0.185, 0.06],
                  rotation: simd_quatf(angle: -side * 0.3, axis: [0, 0, 1]))
        }
        b.add(.paint(palette.peach), LoftShapes.unitSphere, at: bed + [0.11, 0.13, 0.115], scale: SIMD3(repeating: 0.007))
        b.add(cat, LoftShapes.ring(radius: 0.11, thickness: 0.018, segments: 8, from: 0.6, to: 2.6), at: bed + [0, 0.07, 0])
    }

    /// Steam over the mug: three faint puffs that drift up and fade.
    static func buildSteam(_ m: CodingLabMaterials, into room: Entity) -> [Entity] {
        (0..<3).map { index in
            let holder = Entity()
            holder.position = Mug.position + [0.005 * Float(index - 1), 0.12, 0]
            var material = UnlitMaterial(color: .white)
            material.blending = .transparent(opacity: 0.3)
            let puff = ModelEntity(mesh: .generateSphere(radius: 0.016 + 0.004 * Float(index)), materials: [material])
            puff.components.set(OpacityComponent(opacity: 0))
            holder.addChild(puff)
            room.addChild(holder)
            return holder
        }
    }

    // MARK: - Mesh helpers

    static func rbox(_ width: Float, _ height: Float, _ depth: Float, _ radius: Float) -> LoftGeometry {
        .generateBox(width: width, height: height, depth: depth, cornerRadius: min(radius, min(width, height, depth) * 0.49))
    }

    static func box(_ width: Float, _ height: Float, _ depth: Float) -> LoftGeometry {
        .generateBox(width: width, height: height, depth: depth)
    }
}

/// Things the Coding Lab animates.
@MainActor
struct CodingLabParts {
    var palette: CodingLabPalette
    /// LED strip segments, left to right.
    var ledSegments: [Entity] = []
    var screens: [Entity] = []
    var codeScreens: [CodeScreen] = []
    var cursor: Entity?
    var hologramGrow: Entity?
    var hologramBob: Entity?
    var hologramSpin: Entity?
    var serverLEDs: [Entity] = []
    var lavaBlobs: [Entity] = []
    var cityFlicker: [Entity] = []
    var steam: [Entity] = []
    var monitorGlow: PointLight?
}
