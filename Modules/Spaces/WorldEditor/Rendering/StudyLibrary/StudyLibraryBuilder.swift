import AppKit
import AtlasSpaces
import RealityKit

/// The Study Library as a cozy evening reading room: sage walls over a
/// deep-sage wainscot, walnut and brass, golden lamplight, and a tall
/// window onto a blue-hour sky with gentle rain. Built from primitives in
/// metres (4 × 3 m, 2.8 m tall, origin at the floor centre), then scaled
/// into the room's footprint, like the Creative Studio loft.
///
/// Static parts that share a material are merged into one mesh each; the
/// books are merged by spine colour. `detail: false` is the miniature for
/// the Mission Control overview: shell with wainscot, window with sky and
/// moon, the bookcase as coloured blocks, the desk and lamp, armchair, rug.
@MainActor
enum StudyLibraryBuilder {
    /// Room units per metre (the room is 2 × 1.5 room units).
    static let scale: Float = 0.5
    /// Where the origin sits in the room so the back wall is at z = -1.
    static let offset = SIMD3<Float>(0, 0, -0.25)

    struct Result {
        let entity: Entity
        let parts: StudyLibraryParts
    }

    typealias B = Batches<LibraryMaterial>

    static func build(objects: [SpaceObject], detail: Bool, palette: StudyLibraryPalette = .current) -> Result {
        let m = StudyLibraryMaterials(palette)
        let assignment = StudyLibrary.assign(objects)
        let room = Entity()
        room.name = "library"
        room.scale = SIMD3(repeating: scale)
        room.position = offset
        var parts = StudyLibraryParts(palette: palette)

        let shell = B(m)
        buildFloor(shell)
        buildWalls(shell, detail: detail)
        buildWindow(shell, detail: detail)
        buildRug(shell)
        buildDesk(shell, detail: detail)
        buildArmchair(shell, detail: detail)
        if detail {
            buildWindowSeat(shell)
            buildLadder(shell)
            buildDeskChair(shell)
            buildDeskDecor(shell, hasLaptop: assignment.roles[.laptop] != nil)
            buildReadingCorner(shell)
            buildChandelier(shell)
        }
        shell.flush(into: room)

        // Interactive props: each its own entity, so it can lift and glow.
        func prop(_ role: StudyLibraryRole, _ build: (B) -> Void, extra: ((Entity) -> Void)? = nil) {
            let batches = B(m)
            build(batches)
            let container = Entity()
            container.name = assignment.roles[role].map { RoomBuilder.objectName($0.id) } ?? "prop:\(role.rawValue)"
            batches.flush(into: container)
            extra?(container)
            room.addChild(container)
            if assignment.roles[role] != nil { RoomBuilder.makeInteractive(container) }
        }

        prop(.bookshelf, { buildBookcase($0, detail: detail) })
        prop(.lamp, { buildBankerLamp($0) }) { container in
            // The glow under the shade, kept apart so activation can fade it.
            let glow = ModelEntity(mesh: .generatePlane(width: 0.28, height: 0.12), materials: [m.material(.lampGlow)])
            glow.position = Lamp.shade + [0, 0.008, 0]
            glow.orientation = simd_quatf(angle: .pi / 2, axis: [1, 0, 0])
            container.addChild(glow)
            parts.lampGlow = glow
        }
        if detail {
            prop(.calendar, { buildCalendar($0) }) { container in
                container.addChild(calendarDay(material: m.material(.paint(palette.forest))))
            }
            prop(.chalkboard, { buildChalkboard($0) })
            prop(.book, { buildOpenBook($0) }) { container in
                // The top page, hinged at the spine, turns on activation.
                let hinge = Entity()
                hinge.name = "page"
                hinge.position = Book.spine + [0, 0.02, 0]
                hinge.orientation = simd_quatf(angle: Book.pageTilt, axis: [0, 0, 1])
                let page = ModelEntity(mesh: .generateBox(width: 0.2, height: 0.003, depth: 0.27), materials: [m.material(.paper)])
                page.position = [0.1, 0, 0]
                hinge.addChild(page)
                container.addChild(hinge)
                parts.page = hinge
            }
            prop(.globe, { buildGlobeStand($0) }) { container in
                let tilt = Entity()
                tilt.position = Globe.center
                tilt.orientation = simd_quatf(angle: 0.41, axis: [0, 0, 1])
                let spinner = Entity()
                spinner.name = "globe"
                let surface = B(m)
                buildGlobe(surface)
                surface.flush(into: spinner)
                tilt.addChild(spinner)
                container.addChild(tilt)
                parts.globe = spinner
            }
            if assignment.roles[.laptop] != nil {
                prop(.laptop, { buildLaptop($0) })
            }

            // Chandelier candle-bulbs: one mesh, brightened on activation.
            let bulbs = MeshBatch(chandelierBulbs())
            if let entity = bulbs.entity(m.material(.bulb), name: "chandelierBulbs") {
                room.addChild(entity)
                parts.chandelier = entity
            }

            let flame = Entity()
            flame.position = ReadingCorner.flame
            let flameMesh = ModelEntity(mesh: .generateSphere(radius: 1), materials: [m.material(.flame)])
            flameMesh.scale = [0.012, 0.028, 0.012]
            flameMesh.components.set(OpacityComponent(opacity: 1))
            flame.addChild(flameMesh)
            room.addChild(flame)
            parts.flame = flame

            parts.rain = buildRain(m, into: room)
            parts.steam = buildSteam(m, into: room)
        }

        addLights(to: room, detail: detail, palette: palette, parts: &parts)
        return Result(entity: room, parts: parts)
    }

    // MARK: - Lights

    static func addLights(to room: Entity, detail: Bool, palette: StudyLibraryPalette, parts: inout StudyLibraryParts) {
        let glow = NSColor(atlasHex: palette.lampGlow)
        // 1. The banker's lamp: the hero light, straight down onto the desk.
        let banker = SpotLight()
        banker.light.color = glow
        banker.light.intensity = palette.bankerLampIntensity
        banker.light.innerAngleInDegrees = 35
        banker.light.outerAngleInDegrees = 80
        banker.light.attenuationRadius = 2.2 * scale
        if detail { banker.shadow = SpotLightComponent.Shadow() }
        banker.look(at: Desk.center + [0.15, Desk.top, 0.1], from: Lamp.shade + [0, -0.01, 0], relativeTo: room)
        room.addChild(banker, preservingWorldTransform: true)
        parts.bankerLight = banker

        // 4. Fill: keeps corners warm and readable, never black.
        let fill = PointLight()
        fill.light.color = NSColor(atlasHex: palette.cream)
        fill.light.intensity = palette.fillIntensity
        fill.light.attenuationRadius = 6 * scale
        fill.position = [0.3, 2.4, 1.4]
        room.addChild(fill)

        guard detail else { return }
        // 2. The floor lamp by the armchair.
        let floorLamp = PointLight()
        floorLamp.light.color = glow
        floorLamp.light.intensity = palette.floorLampIntensity
        floorLamp.light.attenuationRadius = 2.5 * scale
        floorLamp.position = ReadingCorner.bulb
        room.addChild(floorLamp)

        // 3. Moonlight through the window. A spotlight just outside the
        // glass rather than a directional light: directional lights are
        // global in RealityKit and would tint every room.
        let moon = SpotLight()
        moon.light.color = NSColor(atlasHex: palette.skyLow)
        moon.light.intensity = palette.moonlightIntensity
        moon.light.innerAngleInDegrees = 30
        moon.light.outerAngleInDegrees = 60
        moon.light.attenuationRadius = 7 * scale
        moon.shadow = SpotLightComponent.Shadow()
        moon.look(at: [0.1, 0, 0.6], from: [1.25, 2.2, -1.66], relativeTo: room)
        room.addChild(moon, preservingWorldTransform: true)
    }

    // MARK: - Floor

    /// A walnut border slab with a herringbone field of oak planks (the
    /// odd one walnut) laid in alternating diagonals.
    static func buildFloor(_ b: B) {
        b.add(.walnut, rbox(4.0, 0.08, 3.0, 0.04), at: [0, -0.04, 0])
        let minX: Float = -1.9, maxX: Float = 1.9, minZ: Float = -1.45, maxZ: Float = 1.42
        let columns = 14
        let width = (maxX - minX) / Float(columns)
        let height: Float = 0.09
        var oak = LoftGeometry(), walnut = LoftGeometry()
        for column in 0..<columns {
            let x0 = minX + Float(column) * width, x1 = x0 + width
            // Edges rise across even columns and fall across odd ones, so
            // neighbouring columns meet in a chevron.
            let rising = column.isMultiple(of: 2)
            func edge(_ x: Float) -> Float { rising ? x - x0 : x1 - x }
            for row in -2...Int((maxZ - minZ) / height) + 1 {
                let base = minZ + Float(row) * height
                let corners: [SIMD2<Float>] = [[x0, base + edge(x0)], [x1, base + edge(x1)],
                                               [x1, base + edge(x1) + height], [x0, base + edge(x0) + height]]
                var polygon = clip(corners, minZ: minZ, maxZ: maxZ)
                guard polygon.count >= 3 else { continue }
                // A hairline gap between planks.
                let centre = polygon.reduce(SIMD2<Float>.zero, +) / Float(polygon.count)
                polygon = polygon.map { centre + ($0 - centre) * 0.97 }
                let plank = LoftGeometry.flatPolygon(polygon, y: 0.002)
                if (column * 7 + row * 13 + column * row).isMultiple(of: 9) { walnut.append(plank) } else { oak.append(plank) }
            }
        }
        b.add(.oak, oak, at: .zero)
        b.add(.walnut, walnut, at: [0, 0.0005, 0])
    }

    /// Clips a polygon in xz to minZ…maxZ.
    static func clip(_ points: [SIMD2<Float>], minZ: Float, maxZ: Float) -> [SIMD2<Float>] {
        func cut(_ input: [SIMD2<Float>], inside: (SIMD2<Float>) -> Bool, limit: Float) -> [SIMD2<Float>] {
            var output: [SIMD2<Float>] = []
            for index in input.indices {
                let a = input[index], b = input[(index + 1) % input.count]
                if inside(a) { output.append(a) }
                if inside(a) != inside(b) {
                    let t = (limit - a.y) / (b.y - a.y)
                    output.append(a + (b - a) * t)
                }
            }
            return output
        }
        let low = cut(points, inside: { $0.y >= minZ }, limit: minZ)
        guard !low.isEmpty else { return [] }
        return cut(low, inside: { $0.y <= maxZ }, limit: maxZ)
    }

    // MARK: - Walls

    static func buildWalls(_ b: B, detail: Bool) {
        let z: Float = -1.6, height: Float = 2.8
        // Left wall and the back wall around the window (x 0.15…1.45,
        // y 0.6…2.3). Outer pieces have 10 cm rounded edges; the pieces
        // above and below the window are plain and tuck into them.
        b.add(.wall, rbox(0.2, height, 3.3, 0.1), at: [-2.1, height / 2, -0.15])
        b.add(.wall, rbox(2.45, height, 0.2, 0.1), at: [-1.075, height / 2, z])
        b.add(.wall, rbox(0.65, height, 0.2, 0.1), at: [1.725, height / 2, z])
        b.add(.wall, box(1.5, 0.6, 0.2), at: [0.8, 0.3, z])
        b.add(.wall, box(1.5, 0.5, 0.2), at: [0.8, 2.55, z])

        // Deep-sage wainscot to 1 m with grooved panels, walnut chair rail,
        // walnut baseboard and a cream crown molding.
        let face: Float = -1.5
        let backSpans: [(x0: Float, x1: Float, top: Float)] = [(-2.0, 0.15, 1.0), (1.45, 2.0, 1.0), (0.15, 1.45, 0.6)]
        for span in backSpans {
            let width = span.x1 - span.x0, centre = (span.x0 + span.x1) / 2
            b.add(.wainscot, box(width, span.top, 0.03), at: [centre, span.top / 2, face + 0.015])
            b.add(.walnut, rbox(width, 0.08, 0.045, 0.012), at: [centre, 0.04, face + 0.022])
            if span.top == 1.0 {
                b.add(.walnut, rbox(width, 0.05, 0.05, 0.015), at: [centre, 1.0, face + 0.025])
            }
            if detail {
                var x = span.x0 + 0.2
                while x < span.x1 - 0.1 {
                    b.add(.forest, box(0.012, span.top - 0.22, 0.006), at: [x, span.top / 2 + 0.03, face + 0.032])
                    x += 0.4
                }
            }
        }
        b.add(.wainscot, box(0.03, 1.0, 3.0), at: [-1.985, 0.5, 0])
        b.add(.walnut, rbox(0.05, 0.05, 3.0, 0.015), at: [-1.975, 1.0, 0])
        b.add(.walnut, rbox(0.045, 0.08, 3.0, 0.012), at: [-1.978, 0.04, 0])
        b.add(.paper, rbox(4.0, 0.08, 0.08, 0.025), at: [0, height - 0.04, face + 0.03])
        b.add(.paper, rbox(0.08, 0.08, 3.0, 0.025), at: [-1.97, height - 0.04, 0])
    }

    // MARK: - Window

    enum Window {
        static let centre: Float = 0.8, width: Float = 1.3, bottom: Float = 0.6, top: Float = 2.3
    }

    static func buildWindow(_ b: B, detail: Bool) {
        let cx = Window.centre, frameZ: Float = -1.56
        let midY = (Window.bottom + Window.top) / 2, height = Window.top - Window.bottom
        b.add(.sky, .generatePlane(width: 1.7, height: 2.1), at: [cx, midY, -1.75])
        b.add(.moon, LoftShapes.unitSphere, at: [cx + 0.38, 2.05, -1.73], scale: SIMD3(repeating: 0.075))
        b.add(.glass, .generatePlane(width: Window.width, height: height), at: [cx, midY, -1.58])
        // Walnut frame with a 2 × 3 grid of panes.
        b.add(.walnut, rbox(0.06, height + 0.06, 0.14, 0.015), at: [cx - Window.width / 2, midY, frameZ])
        b.add(.walnut, rbox(0.06, height + 0.06, 0.14, 0.015), at: [cx + Window.width / 2, midY, frameZ])
        b.add(.walnut, rbox(Window.width + 0.06, 0.06, 0.14, 0.015), at: [cx, Window.top, frameZ])
        b.add(.oak, rbox(Window.width + 0.16, 0.04, 0.22, 0.015), at: [cx, Window.bottom, -1.5])
        b.add(.walnut, box(0.03, height, 0.05), at: [cx, midY, frameZ])
        for row in 1...2 {
            b.add(.walnut, box(Window.width, 0.03, 0.05), at: [cx, Window.bottom + height * Float(row) / 3, frameZ])
        }
    }

    /// Rain streaks on the glass, in six groups that each slide and fade on
    /// their own loop (the motion animates the groups).
    static func buildRain(_ m: StudyLibraryMaterials, into room: Entity) -> [Entity] {
        var random = SeededRandom(seed: 7)
        return (0..<6).map { group in
            var batch = MeshBatch()
            for _ in 0..<6 {
                let length = Float.random(in: 0.06...0.14, using: &random)
                batch.add(.generateBox(width: 0.003, height: length, depth: 0.002),
                          at: [Float.random(in: 0.2...1.4, using: &random), Float.random(in: 1.0...2.18, using: &random), -1.595])
            }
            let holder = Entity()
            holder.name = "rain-\(group)"
            if let streaks = batch.entity(m.material(.rain)) {
                streaks.components.set(OpacityComponent(opacity: 0.8))
                holder.addChild(streaks)
            }
            room.addChild(holder)
            return holder
        }
    }

    static func buildWindowSeat(_ b: B) {
        let cx = Window.centre
        b.add(.walnut, rbox(1.4, 0.42, 0.45, 0.03), at: [cx, 0.21, -1.27])
        b.add(.velvet, rbox(1.36, 0.1, 0.42, 0.045), at: [cx, 0.47, -1.27])
        let palette = StudyLibraryPalette.current
        b.add(.paint(palette.dustyRose), rbox(0.32, 0.28, 0.1, 0.05), at: [cx - 0.42, 0.66, -1.39],
              rotation: simd_quatf(angle: 0.12, axis: [0, 0, 1]) * simd_quatf(angle: -0.2, axis: [1, 0, 0]))
        b.add(.paint(palette.cream), rbox(0.28, 0.25, 0.1, 0.05), at: [cx - 0.12, 0.64, -1.4],
              rotation: simd_quatf(angle: -0.1, axis: [0, 0, 1]) * simd_quatf(angle: -0.2, axis: [1, 0, 0]))
        // Folded knit blanket draping off the right end in three segments.
        b.add(.knit, rbox(0.36, 0.035, 0.4, 0.015), at: [cx + 0.5, 0.537, -1.25])
        b.add(.knit, rbox(0.1, 0.035, 0.4, 0.015), at: [cx + 0.70, 0.51, -1.25], rotation: simd_quatf(angle: -1.0, axis: [0, 0, 1]))
        b.add(.knit, rbox(0.035, 0.26, 0.4, 0.015), at: [cx + 0.72, 0.36, -1.25])
    }

    // MARK: - Bookcase

    enum Shelf {
        static let front: Float = -1.65, back: Float = -2.0
        static let start: Float = -1.48, end: Float = 1.12
        static let floors: [Float] = [0.115, 0.575, 1.035, 1.495, 1.955]
        static let segments: [(Float, Float)] = [(-1.44, -0.615), (-0.585, 0.225), (0.255, 1.08)]
    }

    static func buildBookcase(_ b: B, detail: Bool) {
        let depth = Shelf.front - Shelf.back, x = (Shelf.front + Shelf.back) / 2
        let length = Shelf.end - Shelf.start, z = (Shelf.start + Shelf.end) / 2
        b.add(.wainscot, box(0.02, 2.3, length - 0.04), at: [Shelf.back + 0.012, 1.2, z])
        for endZ in [Shelf.start + 0.02, Shelf.end - 0.02] {
            b.add(.walnut, rbox(depth, 2.4, 0.04, 0.015), at: [x, 1.2, endZ])
        }
        b.add(.walnut, rbox(depth + 0.03, 0.05, length + 0.03, 0.02), at: [x + 0.015, 2.39, z])
        b.add(.walnut, rbox(depth, 0.1, length, 0.015), at: [x, 0.05, z])
        for floor in Shelf.floors.dropFirst() {
            b.add(.walnut, rbox(depth - 0.01, 0.03, length - 0.06, 0.008), at: [x, floor - 0.015, z])
        }
        for divider in [Float(-0.6), 0.24] {
            b.add(.walnut, rbox(depth - 0.01, 2.3, 0.03, 0.008), at: [x, 1.2, divider])
        }
        let palette = StudyLibraryPalette.current
        let spines = palette.spines
        var random = SeededRandom(seed: 21)
        guard detail else {
            // Miniature: a couple of coloured blocks per shelf.
            for (shelf, floor) in Shelf.floors.enumerated() {
                for (index, segment) in Shelf.segments.enumerated() {
                    let length = (segment.1 - segment.0) * Float.random(in: 0.55...0.85, using: &random)
                    b.add(.paint(spines[(shelf + index * 2) % 4]), rbox(0.2, 0.25, length, 0.01),
                          at: [Shelf.front - 0.13, floor + 0.125, segment.0 + length / 2 + 0.03])
                }
            }
            return
        }

        // Decor by (shelf, segment); everything else is books.
        enum Decor { case fern, photo, hourglass, bookends, stack }
        let decor: [Int: Decor] = [4 * 3 + 0: .fern, 3 * 3 + 2: .photo, 2 * 3 + 1: .hourglass, 1 * 3 + 0: .bookends,
                                   0 * 3 + 2: .stack, 3 * 3 + 0: .stack]
        for (shelf, floor) in Shelf.floors.enumerated() {
            for (index, segment) in Shelf.segments.enumerated() {
                var cursor = segment.0 + 0.02
                var limit = segment.1 - 0.02
                switch decor[shelf * 3 + index] {
                case .fern:
                    addFern(b, at: [Shelf.front - 0.16, floor, limit - 0.1])
                    limit -= 0.25
                case .photo:
                    addPhoto(b, at: [Shelf.front - 0.12, floor, limit - 0.1])
                    limit -= 0.22
                case .hourglass:
                    addHourglass(b, at: [Shelf.front - 0.15, floor, segment.0 + 0.12])
                    cursor += 0.26
                case .bookends:
                    cursor += 0.15
                    addBookend(b, at: [Shelf.front - 0.12, floor, cursor - 0.012], facing: 1)
                    limit = cursor + 0.42
                    addBookend(b, at: [Shelf.front - 0.12, floor, limit + 0.012], facing: -1)
                case .stack:
                    addStack(b, at: [Shelf.front - 0.13, floor, limit - 0.15], random: &random)
                    limit -= 0.32
                case nil:
                    break
                }
                // Books standing spine-out, with the odd gap and a leaning one.
                var count = 0
                let wanted = Int.random(in: 4...8, using: &random)
                while count < wanted {
                    let thickness = Float.random(in: 0.02...0.05, using: &random)
                    guard cursor + thickness < limit else { break }
                    let height = Float.random(in: 0.18...0.3, using: &random)
                    let depth = Float.random(in: 0.16...0.23, using: &random)
                    let color = spines[Int.random(in: 0..<spines.count, using: &random)]
                    let leaning = count == wanted - 1 && Int.random(in: 0..<4, using: &random) == 0
                    let zCentre = cursor + thickness / 2 + (leaning ? height * 0.12 : 0)
                    let rotation = leaning ? simd_quatf(angle: -0.32, axis: [1, 0, 0]) : simd_quatf(angle: 0, axis: [0, 1, 0])
                    let centre = SIMD3<Float>(Shelf.front - 0.03 - depth / 2, floor + height / 2 - (leaning ? height * 0.025 : 0), zCentre)
                    b.add(.paint(color), rbox(depth, height, thickness, 0.004), at: centre, rotation: rotation)
                    if Int.random(in: 0..<3, using: &random) == 0 {
                        for band in [Float(0.3), -0.32] {
                            b.add(.brass, box(0.003, 0.007, thickness * 0.9),
                                  at: centre + rotation.act([depth / 2 + 0.001, height * band, 0]), rotation: rotation)
                        }
                    }
                    cursor += thickness + 0.002 + (Int.random(in: 0..<9, using: &random) == 0 ? 0.04 : 0)
                    count += 1
                }
            }
        }
    }

    static func addFern(_ b: B, at base: SIMD3<Float>) {
        b.add(.ceramic, .generateCylinder(height: 0.1, radius: 0.055), at: base + [0, 0.05, 0])
        for index in 0..<7 {
            let angle = Float(index) * 0.9
            b.add(.leaf, LoftShapes.unitSphere, at: base + [cos(angle) * 0.06, 0.15, sin(angle) * 0.06],
                  rotation: simd_quatf(angle: -angle, axis: [0, 1, 0]) * simd_quatf(angle: 0.5, axis: [0, 0, 1]),
                  scale: [0.11, 0.012, 0.03])
        }
    }

    static func addPhoto(_ b: B, at base: SIMD3<Float>) {
        let tilt = simd_quatf(angle: 0.15, axis: [0, 0, 1])
        b.add(.paper, rbox(0.025, 0.18, 0.14, 0.006), at: base + [0, 0.09, 0], rotation: tilt)
        b.add(.wainscot, box(0.004, 0.13, 0.095), at: base + tilt.act([0.014, 0.09, 0]) + [0, 0, 0], rotation: tilt)
    }

    static func addHourglass(_ b: B, at base: SIMD3<Float>) {
        b.add(.brass, .generateCylinder(height: 0.012, radius: 0.045), at: base + [0, 0.006, 0])
        b.add(.brass, .generateCylinder(height: 0.012, radius: 0.045), at: base + [0, 0.174, 0])
        b.add(.glass, .generateCone(height: 0.075, radius: 0.035), at: base + [0, 0.0495, 0], rotation: simd_quatf(angle: .pi, axis: [1, 0, 0]))
        b.add(.glass, .generateCone(height: 0.075, radius: 0.035), at: base + [0, 0.1305, 0])
        b.add(.paint(StudyLibraryPalette.current.parchment), .generateCone(height: 0.03, radius: 0.026), at: base + [0, 0.027, 0])
        for angle in [Float(0), 2.1, 4.2] {
            b.add(.brass, .generateCylinder(height: 0.16, radius: 0.004, segments: 6), at: base + [cos(angle) * 0.04, 0.09, sin(angle) * 0.04])
        }
    }

    static func addBookend(_ b: B, at base: SIMD3<Float>, facing: Float) {
        b.add(.brass, box(0.12, 0.006, 0.07), at: base + [0, 0.003, facing * 0.035])
        b.add(.brass, rbox(0.12, 0.16, 0.012, 0.004), at: base + [0, 0.08, 0])
    }

    static func addStack(_ b: B, at base: SIMD3<Float>, random: inout SeededRandom) {
        var y = base.y
        let spines = StudyLibraryPalette.current.spines
        for index in 0..<Int.random(in: 3...4, using: &random) {
            let thickness = Float.random(in: 0.025...0.045, using: &random)
            b.add(.paint(spines[(index * 2 + 1) % spines.count]), rbox(0.19, thickness, 0.27, 0.004),
                  at: [base.x, y + thickness / 2, base.z], rotation: simd_quatf(angle: Float(index) * 0.06 - 0.05, axis: [0, 1, 0]))
            y += thickness
        }
    }

    /// A rolling ladder leaning on the shelves, hooked on a brass rail.
    static func buildLadder(_ b: B) {
        b.add(.brass, .generateCylinder(height: 2.5, radius: 0.012, segments: 10), at: [-1.6, 2.3, -0.18],
              rotation: simd_quatf(angle: .pi / 2, axis: [1, 0, 0]))
        for z in [Float(-1.2), 0.85] {
            b.add(.brass, box(0.06, 0.015, 0.015), at: [-1.625, 2.3, z])
        }
        let bottom = SIMD3<Float>(-1.25, 0, 0), top = SIMD3<Float>(-1.6, 2.3, 0)
        let length = simd_length(top - bottom)
        let lean = simd_quatf(angle: atan2(bottom.x - top.x, top.y - bottom.y), axis: [0, 0, 1])
        for z in [Float(0.35), 0.75] {
            b.add(.oak, rbox(0.05, length, 0.035, 0.012), at: (bottom + top) / 2 + [0, 0, z], rotation: lean)
            b.add(.brass, box(0.05, 0.02, 0.03), at: top + [0.01, 0.03, z])
        }
        for rung in 1...6 {
            let point = bottom + (top - bottom) * (Float(rung) / 7)
            b.add(.oak, .generateCylinder(height: 0.4, radius: 0.014, segments: 10), at: point + [0, 0, 0.55],
                  rotation: simd_quatf(angle: .pi / 2, axis: [1, 0, 0]))
        }
    }

    // MARK: - Desk

    enum Desk {
        static let center = SIMD3<Float>(-0.4, 0, -0.5)
        static let top: Float = 0.785
    }

    enum Lamp {
        static let base = SIMD3<Float>(-0.82, Desk.top, -0.74)
        static let shade = SIMD3<Float>(-0.82, 1.06, -0.68)
    }

    enum Book {
        static let spine = SIMD3<Float>(-0.32, Desk.top + 0.012, -0.44)
        static let pageTilt: Float = 0.1
    }

    static func buildDesk(_ b: B, detail: Bool) {
        let c = Desk.center
        b.add(.walnut, rbox(1.4, 0.05, 0.7, 0.02), at: c + [0, 0.76, 0])
        b.add(.walnut, rbox(1.28, 0.08, 0.58, 0.015), at: c + [0, 0.695, 0])
        for dx in [Float(-0.64), 0.64] {
            for dz in [Float(-0.29), 0.29] {
                let leg = c + [dx, 0, dz]
                guard detail else {
                    b.add(.walnut, .generateCylinder(height: 0.735, radius: 0.026, segments: 10), at: leg + [0, 0.3675, 0])
                    continue
                }
                // Turned legs: stacked cylinders of slightly different radii.
                for (y0, y1, radius) in [(Float(0), Float(0.06), Float(0.03)), (0.06, 0.3, 0.022), (0.3, 0.4, 0.034),
                                         (0.4, 0.68, 0.024), (0.68, 0.735, 0.032)] {
                    b.add(.walnut, .generateCylinder(height: y1 - y0, radius: radius, segments: 12), at: leg + [0, (y0 + y1) / 2, 0])
                }
            }
        }
    }

    static func buildBankerLamp(_ b: B) {
        b.add(.brass, .generateCylinder(height: 0.025, radius: 0.07), at: Lamp.base + [0, 0.0125, 0])
        b.add(.brass, .generateCylinder(height: 0.27, radius: 0.009, segments: 10), at: Lamp.base + [0, 0.16, 0])
        b.add(.brass, box(0.012, 0.012, 0.07), at: Lamp.base + [0, 0.29, 0.03])
        b.add(.shade, LoftGeometry.halfTube(length: 0.32, radius: 0.075, segments: 14), at: Lamp.shade)
        for side in [Float(-1), 1] {
            b.add(.brass, LoftShapes.halfDisc(radius: 0.075, segments: 10), at: Lamp.shade + [side * 0.16, 0, 0],
                  rotation: simd_quatf(angle: .pi / 2, axis: [0, 1, 0]))
        }
        b.add(.brass, .generateCylinder(height: 0.09, radius: 0.0025, segments: 6), at: Lamp.shade + [0.1, -0.05, 0.05])
        b.add(.brass, LoftShapes.unitSphere, at: Lamp.shade + [0.1, -0.1, 0.05], scale: SIMD3(repeating: 0.008))
    }

    static func buildOpenBook(_ b: B) {
        let spine = Book.spine
        b.add(.leather, rbox(0.44, 0.012, 0.3, 0.005), at: spine + [0, -0.006, 0])
        b.add(.paper, box(0.205, 0.016, 0.28), at: spine + [-0.104, 0.009, 0], rotation: simd_quatf(angle: -0.1, axis: [0, 0, 1]))
        b.add(.paper, box(0.205, 0.016, 0.28), at: spine + [0.104, 0.009, 0], rotation: simd_quatf(angle: 0.1, axis: [0, 0, 1]))
        // Faint text lines.
        let ink = LibraryMaterial.paint(StudyLibraryPalette.current.parchment)
        for side in [Float(-1), 1] {
            for line in 0..<6 {
                let x = side * 0.105, tilt = simd_quatf(angle: side * 0.1, axis: [0, 0, 1])
                b.add(ink, box(0.15, 0.001, 0.008), at: spine + tilt.act([x, 0.018, 0]) + [0, 0, -0.09 + Float(line) * 0.035], rotation: tilt)
            }
        }
    }

    static func buildDeskDecor(_ b: B, hasLaptop: Bool) {
        let palette = StudyLibraryPalette.current
        if !hasLaptop {
            // Notebook and a brass fountain pen.
            b.add(.paint(palette.forest), rbox(0.16, 0.016, 0.22, 0.005), at: [-0.82, Desk.top + 0.008, -0.36],
                  rotation: simd_quatf(angle: 0.2, axis: [0, 1, 0]))
            b.add(.brass, .generateCylinder(height: 0.14, radius: 0.005, segments: 8), at: [-0.7, Desk.top + 0.006, -0.33],
                  rotation: simd_quatf(angle: 0.4, axis: [0, 1, 0]) * simd_quatf(angle: .pi / 2, axis: [1, 0, 0]))
        }
        // A small stack of three books.
        var y = Desk.top
        for (index, hex) in [palette.navy, palette.dustyRose, palette.burgundy].enumerated() {
            b.add(.paint(hex), rbox(0.2, 0.035, 0.26, 0.005), at: [0.12, y + 0.0175, -0.68],
                  rotation: simd_quatf(angle: Float(index) * 0.1 - 0.08, axis: [0, 1, 0]))
            y += 0.035
        }
        // Mug.
        b.add(.ceramic, .generateCylinder(height: 0.09, radius: 0.04), at: [Mug.position.x, Desk.top + 0.045, Mug.position.z])
        b.add(.ceramic, LoftShapes.ring(radius: 0.024, thickness: 0.006, segments: 10), at: [Mug.position.x + 0.045, Desk.top + 0.045, Mug.position.z],
              rotation: simd_quatf(angle: .pi / 2, axis: [1, 0, 0]))
        b.add(.paint(palette.walnut), .generateCylinder(height: 0.004, radius: 0.035), at: [Mug.position.x, Desk.top + 0.08, Mug.position.z])
    }

    enum Mug {
        static let position = SIMD3<Float>(0.15, Desk.top, -0.36)
    }

    /// Steam over the mug: three faint puffs that drift up and fade.
    static func buildSteam(_ m: StudyLibraryMaterials, into room: Entity) -> [Entity] {
        (0..<3).map { index in
            let holder = Entity()
            holder.position = Mug.position + [0.005 * Float(index - 1), 0.1, 0]
            let puff = ModelEntity(mesh: .generateSphere(radius: 0.018 + 0.004 * Float(index)), materials: [m.material(.steam)])
            puff.components.set(OpacityComponent(opacity: 0))
            holder.addChild(puff)
            room.addChild(holder)
            return holder
        }
    }

    static func buildCalendar(_ b: B) {
        let base = SIMD3<Float>(-0.04, Desk.top, -0.76)
        let tilt = simd_quatf(angle: -0.22, axis: [1, 0, 0])
        b.add(.brass, rbox(0.13, 0.012, 0.07, 0.004), at: base + [0, 0.006, 0])
        b.add(.brass, box(0.006, 0.13, 0.006), at: base + [-0.055, 0.07, -0.01], rotation: tilt)
        b.add(.brass, box(0.006, 0.13, 0.006), at: base + [0.055, 0.07, -0.01], rotation: tilt)
        b.add(.paper, rbox(0.11, 0.13, 0.006, 0.004), at: base + [0, 0.085, 0], rotation: tilt)
        b.add(.leather, box(0.11, 0.028, 0.008), at: base + [0, 0.085, 0] + tilt.act([0, 0.051, 0.001]), rotation: tilt)
    }

    /// The calendar card's big day number.
    static func calendarDay(material: any RealityKit.Material) -> Entity {
        let day = Calendar.current.component(.day, from: Date())
        let mesh = MeshResource.generateText("\(day)", extrusionDepth: 0.002, font: .systemFont(ofSize: 0.055, weight: .bold))
        let text = ModelEntity(mesh: mesh, materials: [material])
        let tilt = simd_quatf(angle: -0.22, axis: [1, 0, 0])
        let holder = Entity()
        holder.position = SIMD3<Float>(-0.04, Desk.top, -0.76) + [0, 0.085, 0] + tilt.act([0, -0.012, 0.004])
        holder.orientation = tilt
        text.position = [-mesh.bounds.center.x, -mesh.bounds.center.y, 0]
        holder.addChild(text)
        return holder
    }

    static func buildLaptop(_ b: B) {
        let base = SIMD3<Float>(-0.8, Desk.top, -0.36)
        let yaw = simd_quatf(angle: 0.25, axis: [0, 1, 0])
        b.add(.paint(StudyLibraryPalette.current.parchment), rbox(0.3, 0.012, 0.21, 0.006), at: base + [0, 0.006, 0], rotation: yaw)
        b.add(.paint(StudyLibraryPalette.current.parchment), rbox(0.3, 0.2, 0.01, 0.006),
              at: base + yaw.act([0, 0.1, -0.11]), rotation: yaw * simd_quatf(angle: -0.25, axis: [1, 0, 0]))
        b.add(.paint(StudyLibraryPalette.current.navy), box(0.27, 0.17, 0.002),
              at: base + yaw.act([0, 0.1, -0.104]) , rotation: yaw * simd_quatf(angle: -0.25, axis: [1, 0, 0]))
    }

    static func buildDeskChair(_ b: B) {
        let c = Desk.center + [0, 0, 0.42]
        for dx in [Float(-0.2), 0.2] {
            for dz in [Float(-0.19), 0.19] {
                b.add(.walnut, .generateCylinder(height: 0.43, radius: 0.02, segments: 10), at: c + [dx, 0.215, dz])
            }
            b.add(.walnut, rbox(0.035, 0.45, 0.035, 0.012), at: c + [dx * 1.05, 0.66, 0.2])
        }
        b.add(.walnut, rbox(0.5, 0.045, 0.045, 0.015), at: c + [0, 0.88, 0.2])
        b.add(.leather, rbox(0.46, 0.08, 0.44, 0.03), at: c + [0, 0.47, 0])
        b.add(.leather, rbox(0.4, 0.3, 0.06, 0.025), at: c + [0, 0.7, 0.19])
        // Tufting buttons.
        for dx in [Float(-0.1), 0.1] {
            for dz in [Float(-0.1), 0.1] {
                b.add(.leatherBrown, LoftShapes.unitSphere, at: c + [dx, 0.51, dz], scale: [0.012, 0.006, 0.012])
            }
            for dy in [Float(0.64), 0.76] {
                b.add(.leatherBrown, LoftShapes.unitSphere, at: c + [dx, dy, 0.158], scale: [0.012, 0.012, 0.006])
            }
        }
    }

    // MARK: - Chalkboard

    static func buildChalkboard(_ b: B) {
        let c = SIMD3<Float>(-1.0, 1.6, -1.48)
        b.add(.walnut, rbox(1.0, 0.7, 0.04, 0.02), at: c)
        b.add(.forest, box(0.9, 0.6, 0.02), at: c + [0, 0, 0.015])
        let chalk = LibraryMaterial.paper
        var random = SeededRandom(seed: 3)
        for line in 0..<6 {
            let width = Float.random(in: 0.12...0.3, using: &random)
            b.add(chalk, box(width, 0.007, 0.003), at: c + [-0.38 + width / 2, 0.2 - Float(line) * 0.075, 0.027])
        }
        b.add(chalk, box(0.2, 0.007, 0.003), at: c + [-0.27, 0.26, 0.027])
        // A small grid on the right.
        for index in 0...4 {
            b.add(chalk, box(0.004, 0.24, 0.003), at: c + [0.08 + Float(index) * 0.06, -0.1, 0.027])
        }
        for index in 0...3 {
            b.add(chalk, box(0.24, 0.004, 0.003), at: c + [0.2, -0.22 + Float(index) * 0.08, 0.027])
        }
        // Brass clip with two paper cards.
        b.add(.brass, rbox(0.07, 0.022, 0.016, 0.005), at: c + [0.33, 0.29, 0.035])
        b.add(.paper, box(0.11, 0.15, 0.004), at: c + [0.31, 0.2, 0.03], rotation: simd_quatf(angle: 0.06, axis: [0, 0, 1]))
        b.add(.paint(StudyLibraryPalette.current.parchment), box(0.11, 0.15, 0.004), at: c + [0.355, 0.19, 0.033],
              rotation: simd_quatf(angle: -0.1, axis: [0, 0, 1]))
    }

    // MARK: - Reading corner

    enum ReadingCorner {
        static let chair = SIMD3<Float>(1.4, 0, 0.3)
        static let yaw: Float = -0.53
        static func point(_ local: SIMD3<Float>) -> SIMD3<Float> {
            chair + simd_quatf(angle: yaw, axis: [0, 1, 0]).act(local)
        }
        static var bulb: SIMD3<Float> { point([0.62, 1.47, -0.25]) }
        static var table: SIMD3<Float> { point([-0.66, 0, 0.12]) }
        static var flame: SIMD3<Float> { table + [-0.05, 0.705, 0] }
    }

    static func buildArmchair(_ b: B, detail: Bool) {
        let rotation = simd_quatf(angle: ReadingCorner.yaw, axis: [0, 1, 0])
        func add(_ key: LibraryMaterial, _ g: LoftGeometry, _ local: SIMD3<Float>) {
            b.add(key, g, at: ReadingCorner.point(local), rotation: rotation)
        }
        add(.velvet, rbox(0.8, 0.22, 0.74, 0.05), [0, 0.19, 0])
        add(.velvet, rbox(0.56, 0.12, 0.58, 0.05), [0, 0.36, 0.05])
        add(.velvet, rbox(0.8, 0.74, 0.18, 0.06), [0, 0.7, -0.29])
        for side in [Float(-1), 1] {
            add(.velvet, rbox(0.12, 0.42, 0.44, 0.05), [side * 0.34, 0.8, -0.08])
            add(.velvet, rbox(0.14, 0.2, 0.62, 0.05), [side * 0.33, 0.42, 0.04])
            for dz in [Float(-0.28), 0.3] {
                add(.walnut, .generateCone(height: 0.09, radius: 0.03, segments: 10), [side * 0.32, 0.04, dz])
            }
        }
        if detail {
            add(.paint(StudyLibraryPalette.current.dustyRose), rbox(0.34, 0.26, 0.1, 0.05), [0.05, 0.56, -0.16])
        }
    }

    static func buildReadingCorner(_ b: B) {
        // Floor lamp: brass pole, cream drum shade, warm bulb.
        let lamp = ReadingCorner.point([0.62, 0, -0.25])
        b.add(.brass, .generateCylinder(height: 0.03, radius: 0.15), at: lamp + [0, 0.015, 0])
        b.add(.brass, .generateCylinder(height: 1.5, radius: 0.012, segments: 10), at: lamp + [0, 0.78, 0])
        b.add(.paper, LoftGeometry.generateCylinder(height: 0.26, radius: 0.2, segments: 24, capped: false).doubleSided(), at: lamp + [0, 1.5, 0])
        b.add(.brass, LoftShapes.ring(radius: 0.2, thickness: 0.004, segments: 20), at: lamp + [0, 1.63, 0])
        b.add(.bulb, LoftShapes.unitSphere, at: ReadingCorner.bulb, scale: SIMD3(repeating: 0.045))

        // Round oak side table with a candle and a teacup.
        let table = ReadingCorner.table
        b.add(.oak, .generateCylinder(height: 0.03, radius: 0.24, segments: 24), at: table + [0, 0.56, 0])
        b.add(.oak, .generateCylinder(height: 0.52, radius: 0.03, segments: 10), at: table + [0, 0.29, 0])
        b.add(.oak, .generateCylinder(height: 0.025, radius: 0.16, segments: 20), at: table + [0, 0.0125, 0])
        let candle = table + [-0.05, 0.575, 0]
        b.add(.brass, .generateCylinder(height: 0.012, radius: 0.045), at: candle + [0, 0.006, 0])
        b.add(.brass, .generateCylinder(height: 0.025, radius: 0.025), at: candle + [0, 0.02, 0])
        b.add(.paper, .generateCylinder(height: 0.09, radius: 0.017, segments: 10), at: candle + [0, 0.077, 0])
        let cup = table + [0.1, 0.575, 0.05]
        b.add(.ceramic, .generateCylinder(height: 0.006, radius: 0.055), at: cup + [0, 0.003, 0])
        b.add(.ceramic, .generateCone(height: 0.05, radius: 0.04), at: cup + [0, 0.03, 0], rotation: simd_quatf(angle: .pi, axis: [1, 0, 0]))
        b.add(.paint(StudyLibraryPalette.current.walnut), .generateCylinder(height: 0.002, radius: 0.033), at: cup + [0, 0.05, 0])
    }

    enum Globe {
        static let base = SIMD3<Float>(1.72, 0, 1.08)
        static var center: SIMD3<Float> { base + [0, 0.72, 0] }
        static let radius: Float = 0.17
    }

    static func buildGlobeStand(_ b: B) {
        b.add(.brass, .generateCylinder(height: 0.025, radius: 0.13, segments: 20), at: Globe.base + [0, 0.0125, 0])
        b.add(.brass, .generateCylinder(height: 0.5, radius: 0.016, segments: 10), at: Globe.base + [0, 0.27, 0])
        b.add(.brass, LoftShapes.unitSphere, at: Globe.base + [0, 0.52, 0], scale: SIMD3(repeating: 0.03))
        // Meridian ring, tilted with the globe's axis.
        let tilt = simd_quatf(angle: 0.41, axis: [0, 0, 1])
        b.add(.brass, LoftShapes.ring(radius: Globe.radius + 0.02, thickness: 0.007, segments: 24), at: Globe.center,
              rotation: tilt * simd_quatf(angle: .pi / 2, axis: [1, 0, 0]))
    }

    static func buildGlobe(_ b: B) {
        let palette = StudyLibraryPalette.current
        b.add(.paint(palette.navy), .generateSphere(radius: Globe.radius, rings: 12, segments: 18), at: .zero)
        b.add(.brass, .generateCylinder(height: 0.42, radius: 0.004, segments: 6), at: .zero)
        let continents: [(SIMD3<Float>, SIMD2<Float>)] = [([0.6, 0.5, 0.62], [0.05, 0.04]), ([-0.4, 0.3, 0.86], [0.04, 0.055]),
                                                          ([-0.8, -0.2, -0.5], [0.055, 0.04]), ([0.3, -0.5, -0.8], [0.035, 0.03]),
                                                          ([0.9, -0.3, 0.1], [0.035, 0.045])]
        for (direction, size) in continents {
            let normal = simd_normalize(direction)
            b.add(.paint(palette.deepSage), LoftShapes.unitSphere, at: normal * (Globe.radius - 0.003),
                  rotation: simd_quatf(from: [0, 0, 1], to: normal), scale: [size.x, size.y, 0.008])
        }
    }

    // MARK: - Rug and chandelier

    static func buildRug(_ b: B) {
        let centre = SIMD3<Float>(0.15, 0, 0.35), oval = SIMD3<Float>(1.25, 1, 0.8)
        let palette = StudyLibraryPalette.current
        for (key, radius, y) in [(LibraryMaterial.paper, Float(1.0), Float(0.008)), (.paint(palette.dustyRose), 0.93, 0.01),
                                 (.paint(palette.deepSage), 0.6, 0.012), (.paint(palette.dustyRose), 0.54, 0.014)] {
            b.add(key, .generateCylinder(height: y, radius: radius, segments: 48), at: centre + [0, y / 2 + 0.003, 0], scale: oval)
        }
    }

    enum Chandelier {
        static let centre = SIMD3<Float>(0, 2.38, 0.1)
        static let arms = 4
        static let reach: Float = 0.22
    }

    static func buildChandelier(_ b: B) {
        let c = Chandelier.centre
        b.add(.brass, .generateCylinder(height: 0.36, radius: 0.005, segments: 6), at: c + [0, 0.24, 0])
        b.add(.brass, LoftShapes.unitSphere, at: c + [0, 0.05, 0], scale: [0.06, 0.08, 0.06])
        b.add(.brass, .generateCone(height: 0.06, radius: 0.03, segments: 10), at: c + [0, -0.05, 0], rotation: simd_quatf(angle: .pi, axis: [1, 0, 0]))
        for arm in 0..<Chandelier.arms {
            let angle = Float(arm) * .pi / 2 + .pi / 4
            let direction = SIMD3<Float>(cos(angle), 0, sin(angle))
            b.add(.brass, .generateCylinder(height: Chandelier.reach, radius: 0.007, segments: 6), at: c + direction * (Chandelier.reach / 2),
                  rotation: simd_quatf(from: [0, 1, 0], to: direction))
            let tip = c + direction * Chandelier.reach
            b.add(.brass, .generateCylinder(height: 0.02, radius: 0.025, segments: 12), at: tip + [0, 0.01, 0])
            b.add(.paper, .generateCylinder(height: 0.05, radius: 0.011, segments: 8), at: tip + [0, 0.045, 0])
        }
    }

    static func chandelierBulbs() -> LoftGeometry {
        var batch = MeshBatch()
        for arm in 0..<Chandelier.arms {
            let angle = Float(arm) * .pi / 2 + .pi / 4
            let tip = Chandelier.centre + SIMD3(cos(angle), 0, sin(angle)) * Chandelier.reach
            batch.add(LoftShapes.unitSphere, at: tip + [0, 0.09, 0], scale: [0.018, 0.028, 0.018])
        }
        return batch.geometry
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

/// Things the Study Library animates.
@MainActor
struct StudyLibraryParts {
    var palette: StudyLibraryPalette
    var bankerLight: SpotLight?
    var lampGlow: ModelEntity?
    var page: Entity?
    var chandelier: ModelEntity?
    var flame: Entity?
    var globe: Entity?
    /// Each holds one child mesh; the holder moves, the child fades.
    var rain: [Entity] = []
    var steam: [Entity] = []
}

/// Repeatable "random" numbers, so a room rebuilds identically.
struct SeededRandom: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed &* 0x9E37_79B9_7F4A_7C15 | 1
    }

    mutating func next() -> UInt64 {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return state ^ (state >> 29)
    }
}

extension LoftGeometry {
    mutating func append(_ other: LoftGeometry) {
        let base = UInt32(positions.count)
        positions += other.positions
        normals += other.normals
        uvs += other.uvs
        indices += other.indices.map { $0 + base }
    }
}

extension MeshBatch {
    init(_ geometry: LoftGeometry) {
        self.init()
        add(geometry, matrix: matrix_identity_float4x4)
    }
}
