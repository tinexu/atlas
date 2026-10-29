import AppKit
import AtlasSpaces
import RealityKit

/// The loft's living walls: real pictures on the pegboard, paint jars in
/// the colours of your latest work, and finished projects framed on the
/// gallery wall. Built once; the motion refills them when they change.
extension CreativeLoftBuilder {
    // MARK: - Pegboard

    enum Pegboard {
        static let centre = SIMD3<Float>(-1.1, 1.6, -1.485)
        /// The six cards: offset from the centre and tilt.
        static let cards: [(offset: SIMD2<Float>, angle: Float)] = [
            ([-0.33, 0.12], 0.08), ([-0.1, 0.15], -0.05), ([0.15, 0.1], 0.1),
            ([0.36, 0.13], -0.08), ([-0.2, -0.16], -0.06), ([0.08, -0.15], 0.07),
        ]
        static let picture = SIMD2<Float>(0.15, 0.19)
    }

    /// Pictures pinned over the board's coloured cards, each with a brass pin.
    static func fillPegboard(_ content: Entity, _ pictures: [String]) {
        content.children.removeAll()
        let pin = SimpleMaterial(color: NSColor(atlasHex: CreativeLoftPalette.current.brass), roughness: 0.3, isMetallic: true)
        for (path, card) in zip(pictures, Pegboard.cards) {
            let holder = Entity()
            holder.position = Pegboard.centre + [card.offset.x, card.offset.y, 0.026]
            holder.orientation = simd_quatf(angle: card.angle, axis: [0, 0, 1])
            let plane = ModelEntity(mesh: .generatePlane(width: 1, height: 1), materials: [UnlitMaterial(color: .white)])
            CreativeLoftMotion.show(path, on: plane, fitting: Pegboard.picture)
            guard plane.isEnabled else { continue }
            holder.addChild(plane)
            let head = ModelEntity(mesh: .generateSphere(radius: 0.008), materials: [pin])
            head.position = [0, plane.scale.y / 2 - 0.012, 0.006]
            holder.addChild(head)
            content.addChild(holder)
        }
    }

    // MARK: - Paint jars

    enum Jars {
        static let count = 5
        static func position(_ index: Int) -> SIMD3<Float> { [-1.86, 1.355, -0.3 + Float(index) * 0.1] }
    }

    /// Five jars, each its own clickable item (click copies its colour).
    static func buildJars(_ m: CreativeLoftMaterials, into loft: Entity, parts: inout CreativeLoftParts) {
        for index in 0..<Jars.count {
            let jar = Entity()
            jar.name = CreativeRoomState.Item.jar(index).entityName
            jar.position = Jars.position(index)
            let body = ModelEntity(mesh: .generateCylinder(height: 0.08, radius: 0.035),
                                   materials: [m.paint(CreativeLoftPalette.current.rose)])
            jar.addChild(body)
            let lid = ModelEntity(mesh: .generateCylinder(height: 0.015, radius: 0.037), materials: [m.cream])
            lid.position = [0, 0.047, 0]
            jar.addChild(lid)
            loft.addChild(jar)
            RoomBuilder.makeInteractive(jar)
            parts.jarBodies.append(body)
        }
    }

    // MARK: - Gallery wall

    enum Gallery {
        /// The blush wall right of the window: two columns, three rows, newest top left.
        static func position(_ index: Int) -> SIMD3<Float> {
            let column = index % 2, row = index / 2
            return [1.47 + Float(column) * 0.36, 2.05 - Float(row) * 0.4, -1.49]
        }
        static let frame = SIMD2<Float>(0.27, 0.33)
        static let picture = SIMD2<Float>(0.21, 0.27)
    }

    /// One framed piece per finished project, alternating brass and cream
    /// frames around a cream mat.
    static func fillGallery(_ content: Entity, _ frames: [CreativeRoomState.Frame], _ m: CreativeLoftMaterials) {
        content.children.removeAll()
        for (index, frame) in frames.prefix(6).enumerated() {
            let piece = Entity()
            piece.name = CreativeRoomState.Item.frame(frame.projectID).entityName
            piece.position = Gallery.position(index)
            let border = ModelEntity(mesh: .generateBox(width: Gallery.frame.x, height: Gallery.frame.y, depth: 0.02, cornerRadius: 0.004),
                                     materials: [index.isMultiple(of: 2) ? m.brass : m.cream])
            piece.addChild(border)
            let mat = ModelEntity(mesh: .generatePlane(width: Gallery.frame.x - 0.03, height: Gallery.frame.y - 0.03),
                                  materials: [m.ceramicCream])
            mat.position = [0, 0, 0.0105]
            piece.addChild(mat)
            let picture = ModelEntity(mesh: .generatePlane(width: 1, height: 1), materials: [UnlitMaterial(color: .white)])
            picture.position = [0, 0, 0.012]
            CreativeLoftMotion.show(frame.image, on: picture, fitting: Gallery.picture)
            if !picture.isEnabled {
                // No picture yet: a soft colour block instead.
                picture.model?.materials = [m.paint(CreativeLoftPalette.current.rose)]
                picture.scale = [Gallery.picture.x, Gallery.picture.y, 1]
                picture.isEnabled = true
            }
            piece.addChild(picture)
            piece.components.set(CollisionComponent(shapes: [.generateBox(size: [Gallery.frame.x, Gallery.frame.y, 0.04])
                    .offsetBy(translation: [0, 0, 0.03])]))
            piece.components.set(InputTargetComponent())
            content.addChild(piece)
        }
    }
}

// MARK: - Window: real time of day and weather

extension CreativeLoftBuilder {
    enum LoftWindow {
        static let centre: Float = 0.6
        static let skyZ: Float = -1.72
        static let glassZ: Float = -1.53

        /// Bottom, middle and top of the sky for each time of day; golden
        /// hour is the loft's own look.
        static func colors(_ view: StudyRoomState.WindowView) -> [String] {
            var colors: [String]
            switch view.sky {
            case .dawn: colors = ["#FFD9C7", "#F8C6D0", "#C9B8E0"]
            case .day: colors = ["#DCEEFF", "#A9D4F5", "#7FB6EA"]
            case .golden: colors = ["#FFC4A8", "#F6D6DC", "#E8A6B4"]
            case .blueHour: colors = ["#E7C6DD", "#B9A3D6", "#7E6FB0"]
            case .night: colors = ["#3A3560", "#22223F", "#14142A"]
            }
            let (grey, amount): (String, CGFloat)
            switch view.weather {
            case .clear: return colors
            case .clouds: (grey, amount) = ("#A49CA8", 0.3)
            case .rain: (grey, amount) = ("#7C7787", 0.45)
            case .snow: (grey, amount) = ("#D8D3DC", 0.4)
            case .fog: (grey, amount) = ("#C8C2CB", 0.6)
            }
            return colors.map { mix($0, grey, amount) }
        }

        /// The sun through the window: colour and share of full strength.
        static func sun(_ view: StudyRoomState.WindowView, warm: String) -> (color: String, level: Float) {
            var sun: (String, Float)
            switch view.sky {
            case .dawn: sun = ("#FFD1C2", 0.7)
            case .day: sun = ("#FFF6E8", 1)
            case .golden: sun = (warm, 1)
            case .blueHour: sun = ("#C7B5F0", 0.45)
            case .night: sun = ("#8C9BD6", 0.15)
            }
            if view.weather != .clear { sun.1 *= view.weather == .clouds ? 0.75 : 0.5 }
            return sun
        }

        static func isEvening(_ view: StudyRoomState.WindowView) -> Bool { view.sky == .night || view.sky == .blueHour }

        static func mix(_ a: String, _ b: String, _ t: CGFloat) -> String {
            let x = NSColor(atlasHex: a).usingColorSpace(.sRGB) ?? .gray, y = NSColor(atlasHex: b).usingColorSpace(.sRGB) ?? .gray
            func channel(_ p: CGFloat, _ q: CGFloat) -> Int { Int(((p * (1 - t) + q * t) * 255).rounded()) }
            return String(format: "#%02X%02X%02X", channel(x.redComponent, y.redComponent), channel(x.greenComponent, y.greenComponent),
                          channel(x.blueComponent, y.blueComponent))
        }
    }

    /// The live sky, moon and (unlit, faint) glass, with the glass as the
    /// window's hover target. Clouds, fog, rain and snow come later, when
    /// the weather first needs them.
    static func buildLiveWindow(_ m: CreativeLoftMaterials, into loft: Entity, parts: inout CreativeLoftParts) {
        let cx = LoftWindow.centre
        let sky = ModelEntity(mesh: .generatePlane(width: 1.6, height: 1.7), materials: [m.sky])
        sky.position = [cx, 1.45, LoftWindow.skyZ]
        loft.addChild(sky)
        parts.sky = sky
        let moon = ModelEntity(mesh: .generateSphere(radius: 1), materials: [CreativeLoftMaterials.glow("#FFF4EC", intensity: 0.8)])
        moon.scale = SIMD3(repeating: 0.07)
        moon.position = [cx + 0.4, 1.95, -1.7]
        moon.isEnabled = false
        loft.addChild(moon)
        parts.moon = moon

        let glass = Entity()
        glass.name = CreativeRoomState.Item.window.entityName
        var panes = MeshBatch()
        panes.add(.generatePlane(width: 1.4, height: 0.8), at: [cx, 1.1, LoftWindow.glassZ])
        panes.add(LoftShapes.halfDisc(radius: 0.7, segments: 24), at: [cx, 1.5, LoftWindow.glassZ])
        if let entity = panes.entity(CreativeLoftMaterials.translucent("#FFF4EC", opacity: 0.08)) { glass.addChild(entity) }
        glass.components.set(RoomBuilder.HoverOffsetComponent(offset: .zero))
        // In front of the back wall's picking shape (z −1.5).
        glass.components.set(CollisionComponent(shapes: [.generateBox(size: [1.4, 1.5, 0.02]).offsetBy(translation: [cx, 1.45, -1.46])]))
        glass.components.set(InputTargetComponent())
        loft.addChild(glass)
        parts.room = loft
    }

    static func buildClouds(into loft: Entity) -> ModelEntity? {
        var clouds = MeshBatch()
        let blobs: [(SIMD3<Float>, SIMD3<Float>)] = [
            ([0.25, 1.85, 0], [0.2, 0.06, 0.02]), ([0.42, 1.9, 0.004], [0.16, 0.07, 0.02]), ([0.85, 1.65, 0], [0.22, 0.06, 0.02]),
            ([1.02, 1.7, 0.003], [0.14, 0.05, 0.02]), ([0.5, 1.3, 0], [0.18, 0.045, 0.02]),
        ]
        for (centre, size) in blobs { clouds.add(LoftShapes.unitSphere, at: [centre.x, centre.y, -1.69 + centre.z], scale: size) }
        guard let entity = clouds.entity(CreativeLoftMaterials.translucent("#FFFFFF", opacity: 0.85), name: "clouds") else { return nil }
        loft.addChild(entity)
        return entity
    }

    static func buildFog(into loft: Entity) -> ModelEntity {
        var veil = MeshBatch()
        veil.add(.generatePlane(width: 1.4, height: 0.8), at: [LoftWindow.centre, 1.1, -1.55])
        veil.add(LoftShapes.halfDisc(radius: 0.7, segments: 24), at: [LoftWindow.centre, 1.5, -1.55])
        let fog = veil.entity(CreativeLoftMaterials.translucent("#E9E2E8", opacity: 0.55)) ?? ModelEntity()
        loft.addChild(fog)
        return fog
    }

    /// Streaks (rain) or slow dots (snow) on the arched glass, in groups the motion moves.
    static func buildPrecipitation(snow: Bool, into loft: Entity) -> [Entity] {
        var random = LoftRandom(seed: snow ? 5 : 3)
        let piece: LoftGeometry = snow ? .generateSphere(radius: 0.006, rings: 4, segments: 6) : .generateBox(width: 0.003, height: 0.09, depth: 0.002)
        return (0..<(snow ? 2 : 3)).map { group in
            var batch = MeshBatch()
            for _ in 0..<(snow ? 18 : 10) {
                let x = Float.random(in: 0.0...1.2, using: &random)
                // Inside the arch: lower over the edges.
                let top = 1.5 + sqrt(max(0, 0.49 - (x - LoftWindow.centre) * (x - LoftWindow.centre))) - 0.05
                batch.add(piece, at: [x, Float.random(in: 0.95...max(1.0, top), using: &random), -1.545])
            }
            let holder = Entity()
            holder.name = (snow ? "snow-" : "rain-") + "\(group)"
            if let mesh = batch.entity(CreativeLoftMaterials.translucent(snow ? "#FFFFFF" : "#EEF2FA", opacity: snow ? 0.9 : 0.45)) {
                mesh.components.set(OpacityComponent(opacity: 0.85))
                holder.addChild(mesh)
            }
            loft.addChild(holder)
            return holder
        }
    }

    // MARK: - Rug splashes

    enum Rug {
        static let centre = SIMD3<Float>(0.1, 0.016, 0.35)
        static let radius: Float = 0.66
    }

    /// Where day `day`'s splash lands: spread over the rug, always the same place.
    static func splashPlacement(day: Int) -> (position: SIMD3<Float>, angle: Float, size: SIMD2<Float>) {
        var random = LoftRandom(seed: UInt64(day) &* 2_654_435_761)
        let angle = Float(day) * 2.39996 + Float.random(in: -0.3...0.3, using: &random)   // the golden angle
        let distance = Rug.radius * sqrt(Float(day) / 31) * Float.random(in: 0.85...1, using: &random)
        let size = SIMD2(Float.random(in: 0.05...0.08, using: &random), Float.random(in: 0.035...0.06, using: &random))
        return (Rug.centre + [cos(angle) * distance, 0, sin(angle) * distance], Float.random(in: 0...(.pi), using: &random), size)
    }

    /// The rug as a hover target (for the streak), with its splashes inside.
    static func buildRugItem(into loft: Entity) -> Entity {
        let rug = Entity()
        rug.name = CreativeRoomState.Item.rug.entityName
        rug.components.set(CollisionComponent(shapes: [.generateBox(size: [1.5, 0.02, 1.5]).offsetBy(translation: Rug.centre)]))
        rug.components.set(InputTargetComponent())
        let content = Entity()
        content.name = "rugSplashes"
        rug.addChild(content)
        loft.addChild(rug)
        return content
    }

    /// One flattened splash per creative day; the same colours share a mesh.
    static func fillRug(_ content: Entity, _ splashes: [CreativeRoomState.Splash], _ m: CreativeLoftMaterials) {
        content.children.removeAll()
        let batches = Batches<LoftMaterial>(m)
        for splash in splashes {
            let place = splashPlacement(day: splash.day)
            batches.add(.paint(splash.color), LoftShapes.unitSphere, at: place.position,
                        rotation: simd_quatf(angle: place.angle, axis: [0, 1, 0]), scale: [place.size.x, 0.004, place.size.y])
            // A droplet or two beside it.
            batches.add(.paint(splash.color), LoftShapes.unitSphere, at: place.position + [place.size.x * 0.9, 0, place.size.y * 0.4],
                        scale: [0.012, 0.003, 0.012])
        }
        batches.flush(into: content)
    }

    // MARK: - The Companion at its tiny easel

    enum Painter {
        /// On the open floor left of your easel, in front of the window seat.
        static let base = SIMD3<Float>(0.7, 0, -0.45)
        static let easel = SIMD3<Float>(0.95, 0, -0.62)
        static let easelYaw: Float = -0.6
        static let figureYaw: Float = 1.0
        static let focusAccent = "#818CF8"
        static let idleAccent = "#7DD3FC"
        /// Watching: on the window seat, turned towards the TV.
        static let seat = SIMD3<Float>(0.75, 0.52, -1.2)
        static let seatYaw: Float = -0.9
    }

    struct PainterParts {
        let container: Entity
        let body: Entity
        let arm: Entity
        let eyes: [ModelEntity]
        let dot: ModelEntity
        /// The tiny easel (hidden while watching) and the popcorn bowl (shown).
        let easel: Entity
        let popcorn: Entity
    }

    /// A small Companion in your colours at a tiny easel, holding a brush.
    static func buildPainter(_ painter: CreativeRoomState.Painter, _ m: CreativeLoftMaterials, into loft: Entity) -> PainterParts {
        let container = Entity()
        container.name = CreativeRoomState.Item.painter.entityName
        // The tiny easel: three legs and a small canvas with a few strokes.
        let easelEntity = Entity()
        let easel = Batches<LoftMaterial>(m)
        let e = Painter.easel
        let turn = simd_quatf(angle: Painter.easelYaw, axis: [0, 1, 0])
        for (dx, tilt) in [(Float(-0.09), Float(-0.12)), (0.09, 0.12)] {
            easel.add(.wood, .generateCylinder(height: 0.5, radius: 0.008), at: e + turn.act([dx, 0.24, 0.02]),
                      rotation: turn * simd_quatf(angle: tilt, axis: [0, 0, 1]))
        }
        easel.add(.wood, .generateCylinder(height: 0.48, radius: 0.008), at: e + turn.act([0, 0.22, -0.07]),
                  rotation: turn * simd_quatf(angle: 0.25, axis: [1, 0, 0]))
        easel.add(.cream, rbox(0.2, 0.24, 0.012, 0.004), at: e + turn.act([0, 0.37, 0.03]), rotation: turn)
        let strokes: [(String, SIMD2<Float>)] = [(CreativeLoftPalette.current.rose, [-0.03, 0.02]), (CreativeLoftPalette.current.sage, [0.04, -0.04])]
        for (hex, offset) in strokes {
            easel.add(.paint(hex), LoftShapes.unitSphere, at: e + turn.act([offset.x, 0.37 + offset.y, 0.038]), rotation: turn,
                      scale: [0.045, 0.03, 0.003])
        }
        easel.flush(into: easelEntity)
        container.addChild(easelEntity)

        // The figure, standing at the floor.
        let body = Entity()
        body.position = Painter.base
        body.orientation = simd_quatf(angle: Painter.figureYaw, axis: [0, 1, 0])
        let primary = LoftMaterial.paint(painter.primary), secondary = LoftMaterial.paint(painter.secondary)
        let shape = Batches<LoftMaterial>(m)
        var eyes: [(SIMD3<Float>, Float)] = []
        var top: Float
        switch painter.style {
        case .robot:
            shape.add(secondary, rbox(0.13, 0.14, 0.1, 0.03), at: [0, 0.1, 0])
            shape.add(primary, rbox(0.17, 0.13, 0.13, 0.035), at: [0, 0.25, 0])
            shape.add(.paint("#141414"), rbox(0.13, 0.08, 0.01, 0.02), at: [0, 0.25, 0.062])
            eyes = [([-0.03, 0.255, 0.069], 0.011), ([0.03, 0.255, 0.069], 0.011)]
            top = 0.32
        case .creature:
            shape.add(primary, LoftShapes.unitSphere, at: [0, 0.13, 0], scale: [0.11, 0.12, 0.1])
            shape.add(secondary, LoftShapes.unitSphere, at: [0, 0.1, 0.05], scale: [0.07, 0.07, 0.04])
            for x: Float in [-0.065, 0.065] {
                shape.add(primary, LoftShapes.unitSphere, at: [x, 0.24, 0], scale: SIMD3(repeating: 0.03))
                shape.add(.cream, LoftShapes.unitSphere, at: [x * 0.55, 0.18, 0.085], scale: SIMD3(repeating: 0.02))
            }
            eyes = [([-0.036, 0.177, 0.1], 0.01), ([0.036, 0.177, 0.1], 0.01)]
            top = 0.27
        case .orb:
            shape.add(primary, LoftShapes.unitSphere, at: [0, 0.2, 0], scale: SIMD3(repeating: 0.075))
            eyes = [([0, 0.2, 0], 0.05)]
            top = 0.28
        }
        shape.flush(into: body)
        var eyeEntities: [ModelEntity] = []
        for (position, radius) in eyes {
            let eye = ModelEntity(mesh: .generateSphere(radius: radius),
                                  materials: [CreativeLoftMaterials.glow(painter.isFocused ? Painter.focusAccent : Painter.idleAccent, intensity: 1.2)])
            eye.position = position
            body.addChild(eye)
            eyeEntities.append(eye)
        }
        // The brush arm, pivoting at the shoulder, reaching towards the canvas.
        let arm = Entity()
        arm.position = [0.08, 0.17, 0.02]
        let armBatch = Batches<LoftMaterial>(m)
        armBatch.add(primary, LoftShapes.unitSphere, at: [0.02, 0, 0.03], scale: SIMD3(repeating: 0.025))
        armBatch.add(.wood, .generateCylinder(height: 0.11, radius: 0.004), at: [0.03, 0.03, 0.08],
                     rotation: simd_quatf(angle: -1.0, axis: [1, 0, 0]))
        armBatch.add(.paint(CreativeLoftPalette.current.berry), LoftShapes.unitSphere, at: [0.03, 0.06, 0.13], scale: SIMD3(repeating: 0.008))
        armBatch.flush(into: arm)
        body.addChild(arm)
        // A small amber light beside its head: suggestions are waiting
        // (dim enough to stay amber rather than glare white).
        let dot = ModelEntity(mesh: .generateSphere(radius: 0.008), materials: [CreativeLoftMaterials.glow("#F2A03D", intensity: 0.6)])
        dot.position = [0.07, top + 0.03, 0]
        dot.isEnabled = painter.waiting > 0 && !painter.isFocused
        body.addChild(dot)
        // A bowl of popcorn for Watch mode, held in front.
        let popcorn = Entity()
        popcorn.position = [0, 0.1, 0.11]
        let bowl = Batches<LoftMaterial>(m)
        bowl.add(.paint(CreativeLoftPalette.current.rose), .generateCylinder(height: 0.035, radius: 0.045), at: [0, 0, 0])
        for (index, offset) in [SIMD3<Float>(-0.02, 0.025, 0), [0.018, 0.027, 0.01], [0, 0.03, -0.015], [0.01, 0.038, 0], [-0.012, 0.035, 0.014]].enumerated() {
            bowl.add(.cream, LoftShapes.unitSphere, at: offset, scale: SIMD3(repeating: 0.012 + Float(index % 2) * 0.002))
        }
        bowl.flush(into: popcorn)
        popcorn.isEnabled = false
        body.addChild(popcorn)
        container.addChild(body)
        loft.addChild(container)
        RoomBuilder.makeInteractive(container)
        return PainterParts(container: container, body: body, arm: arm, eyes: eyeEntities, dot: dot, easel: easelEntity, popcorn: popcorn)
    }
}

extension CreativeLoftMaterials {
    static func translucent(_ hex: String, opacity: Float) -> UnlitMaterial {
        var material = UnlitMaterial(color: NSColor(atlasHex: hex))
        material.blending = .transparent(opacity: .init(floatLiteral: opacity))
        return material
    }

    static func glow(_ hex: String, intensity: Float) -> PhysicallyBasedMaterial {
        var material = PhysicallyBasedMaterial()
        material.baseColor = .init(tint: NSColor(atlasHex: hex))
        material.emissiveColor = .init(color: NSColor(atlasHex: hex))
        material.emissiveIntensity = intensity
        return material
    }

    /// A sky gradient from bottom to top.
    static func sky(_ colors: [String]) -> UnlitMaterial {
        var sky = UnlitMaterial(color: .white)
        if let texture = gradient(colors) {
            sky.color = .init(tint: .white, texture: .init(texture))
        } else {
            sky.color = .init(tint: NSColor(atlasHex: colors[0]))
        }
        return sky
    }
}

/// Repeatable "random" numbers for the loft, so it rebuilds identically.
struct LoftRandom: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed &* 0x9E37_79B9_7F4A_7C15 | 1
    }

    mutating func next() -> UInt64 {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return state ^ (state >> 29)
    }
}

// MARK: - The TV (Watch mode)

extension CreativeLoftBuilder {
    enum TV {
        /// On a low round table between the desk and the window seat, turned so
        /// both the room and the window seat can see the screen.
        static let base = SIMD3<Float>(0.15, 0, -0.72)
        static let yaw: Float = 0.93
        static let tableTop: Float = 0.4
        static let body = SIMD3<Float>(0.26, 0.2, 0.18)
        static let screen = SIMD2<Float>(0.19, 0.14)
        static let screenOff = "#2B2633"
        static let screenOn = "#BFD7FF"
    }

    /// A rounded cream TV with a brass antenna on a little table: under 10
    /// entities. The screen glows (and the motion flickers it) while watching.
    static func buildTV(_ m: CreativeLoftMaterials, into loft: Entity, parts: inout CreativeLoftParts) {
        let container = Entity()
        container.name = CreativeRoomState.Item.tv.entityName
        container.position = TV.base
        container.orientation = simd_quatf(angle: TV.yaw, axis: [0, 1, 0])
        let shape = Batches<LoftMaterial>(m)
        // Table.
        shape.add(.wood, .generateCylinder(height: 0.03, radius: 0.18), at: [0, TV.tableTop - 0.015, 0])
        shape.add(.brass, .generateCylinder(height: TV.tableTop - 0.03, radius: 0.012), at: [0, (TV.tableTop - 0.03) / 2, 0])
        shape.add(.brass, .generateCylinder(height: 0.012, radius: 0.1), at: [0, 0.006, 0])
        // Body, feet, bezel and knobs.
        let centre = SIMD3<Float>(0, TV.tableTop + 0.02 + TV.body.y / 2, 0)
        shape.add(.cream, rbox(TV.body.x, TV.body.y, TV.body.z, 0.04), at: centre)
        for x: Float in [-0.09, 0.09] {
            shape.add(.brass, .generateCylinder(height: 0.02, radius: 0.012), at: [x, TV.tableTop + 0.01, 0.04])
        }
        shape.add(.mauveDark, rbox(TV.screen.x + 0.025, TV.screen.y + 0.025, 0.01, 0.02), at: centre + [-0.02, 0, TV.body.z / 2 - 0.002])
        for y: Float in [0.03, -0.03] {
            shape.add(.brass, .generateCylinder(height: 0.012, radius: 0.01), at: centre + [0.105, y, TV.body.z / 2 + 0.004],
                      rotation: simd_quatf(angle: .pi / 2, axis: [1, 0, 0]))
        }
        // Antenna: two brass rods in a V, with little balls.
        let top = centre + [0, TV.body.y / 2, -0.02]
        for angle: Float in [0.45, -0.45] {
            let rotation = simd_quatf(angle: angle, axis: [0, 0, 1])
            shape.add(.brass, .generateCylinder(height: 0.17, radius: 0.003), at: top + rotation.act([0, 0.085, 0]), rotation: rotation)
            shape.add(.brass, LoftShapes.unitSphere, at: top + rotation.act([0, 0.17, 0]), scale: SIMD3(repeating: 0.008))
        }
        shape.flush(into: container)
        let screen = ModelEntity(mesh: .generatePlane(width: TV.screen.x, height: TV.screen.y, cornerRadius: 0.015),
                                 materials: [m.paint(TV.screenOff)])
        screen.position = centre + [-0.02, 0, TV.body.z / 2 + 0.0045]
        screen.components.set(OpacityComponent(opacity: 1))
        container.addChild(screen)
        loft.addChild(container)
        RoomBuilder.makeInteractive(container)
        parts.tvScreen = screen

        // A soft bluish glow from the screen, off until watching.
        let glow = PointLight()
        glow.light.color = NSColor(atlasHex: TV.screenOn)
        glow.light.intensity = 0
        glow.light.attenuationRadius = 0.9 * scale
        glow.position = TV.base + simd_quatf(angle: TV.yaw, axis: [0, 1, 0]).act(centre + [0, 0, 0.25])
        loft.addChild(glow)
        parts.tvLight = glow
    }
}
