import AppKit
import AtlasSpaces
import RealityKit

/// The Study Library's living parts: the sky and weather in the window,
/// the books earned on the upper shelves, the streak stars on the sill and
/// the Companion reading on the window seat. Built once; the motion swaps
/// materials and toggles parts when the state changes (a few times an
/// hour), never per frame.
extension StudyLibraryBuilder {
    // MARK: - Window: sky and weather

    enum Sky {
        static var centre: SIMD3<Float> { [Window.centre, (Window.bottom + Window.top) / 2, -1.75] }

        /// Bottom and top of the sky gradient.
        static func colors(_ view: StudyRoomState.WindowView, palette: StudyLibraryPalette) -> (low: String, top: String) {
            var colors: (low: String, top: String)
            switch view.sky {
            case .dawn: colors = ("#F2C6A0", "#7C8DB5")
            case .day: colors = ("#CFE3F2", "#6FA3D8")
            case .golden: colors = ("#F6C27A", "#8C9CC4")
            case .blueHour: colors = (palette.skyLow, palette.skyTop)
            case .night: colors = ("#2C3A5C", "#0F1626")
            }
            // Weather greys the sky; fog washes it out (lower contrast).
            let (grey, amount): (String, CGFloat)
            switch view.weather {
            case .clear: return colors
            case .clouds: (grey, amount) = ("#8E97A6", 0.3)
            case .rain: (grey, amount) = ("#6B7482", 0.45)
            case .snow: (grey, amount) = ("#C9CED6", 0.4)
            case .fog: (grey, amount) = ("#B8C0C8", 0.6)
            }
            return (mix(colors.low, grey, amount), mix(colors.top, grey, amount))
        }

        /// The sun or moon: where it sits and how it glows; nil when hidden.
        static func orb(_ view: StudyRoomState.WindowView) -> (position: SIMD3<Float>, color: String, intensity: Float, size: Float)? {
            guard view.weather == .clear || view.weather == .clouds else { return nil }
            let x = Window.centre
            switch view.sky {
            case .night, .blueHour: return ([x + 0.38, 2.05, -1.73], "#F4EBDD", 0.8, 0.075)
            case .day: return ([x + 0.3, 2.12, -1.73], "#FFF3D1", 1.3, 0.085)
            case .dawn: return ([x - 0.35, 1.0, -1.73], "#FFC58A", 1.1, 0.1)
            case .golden: return ([x + 0.35, 1.15, -1.73], "#FFB35C", 1.2, 0.1)
            }
        }

        /// The light through the window: colour and share of full brightness.
        static func light(_ view: StudyRoomState.WindowView, palette: StudyLibraryPalette) -> (color: String, level: Float) {
            var light: (String, Float)
            switch view.sky {
            case .night: light = (palette.skyLow, 1)
            case .blueHour: light = ("#9FB0D0", 1)
            case .dawn: light = ("#FFD1A8", 1.2)
            case .day: light = ("#FFF4E0", 1.7)
            case .golden: light = ("#FFC07A", 1.5)
            }
            if view.weather != .clear { light.1 *= view.weather == .clouds ? 0.8 : 0.6 }
            return light
        }

        static func cloudColor(_ view: StudyRoomState.WindowView) -> String {
            switch view.sky {
            case .night: return "#4E586C"
            case .blueHour: return "#8792AA"
            case .dawn, .golden: return "#E8CFC0"
            case .day: return view.weather == .rain ? "#C3C8D0" : "#F4F6F8"
            }
        }

        static func mix(_ a: String, _ b: String, _ t: CGFloat) -> String {
            let x = NSColor(atlasHex: a).usingColorSpace(.sRGB) ?? .gray, y = NSColor(atlasHex: b).usingColorSpace(.sRGB) ?? .gray
            func channel(_ p: CGFloat, _ q: CGFloat) -> Int { Int(((p * (1 - t) + q * t) * 255).rounded()) }
            return String(format: "#%02X%02X%02X", channel(x.redComponent, y.redComponent), channel(x.greenComponent, y.greenComponent),
                          channel(x.blueComponent, y.blueComponent))
        }
    }

    /// The live window: sky, sun or moon, clouds, fog and the (hoverable)
    /// glass. The motion fills them in from the state.
    static func buildLiveWindow(_ m: StudyLibraryMaterials, into room: Entity, parts: inout StudyLibraryParts) {
        let height = Window.top - Window.bottom
        let sky = ModelEntity(mesh: .generatePlane(width: 1.7, height: 2.1), materials: [m.material(.sky)])
        sky.position = Sky.centre
        room.addChild(sky)
        parts.sky = sky

        let orb = ModelEntity(mesh: .generateSphere(radius: 1), materials: [m.material(.moon)])
        orb.scale = SIMD3(repeating: 0.075)
        orb.position = [Window.centre + 0.38, 2.05, -1.73]
        room.addChild(orb)
        parts.skyOrb = orb

        parts.room = room
        // The glass is the window's hover target ("Light rain · 9° · Boston").
        let glass = Entity()
        glass.name = StudyRoomState.Item.window.entityName
        // Unlit, so the view's environment light doesn't reflect off it as a
        // grey veil that hides a dark night sky; just a faint sheen.
        let pane = ModelEntity(mesh: .generatePlane(width: Window.width, height: height),
                               materials: [StudyLibraryMaterials.translucent("#E8F0FF", opacity: 0.07)])
        pane.position = [Window.centre, (Window.bottom + Window.top) / 2, -1.58]
        glass.addChild(pane)
        glass.components.set(RoomBuilder.HoverOffsetComponent(offset: .zero))
        // The glass is set into the wall, behind the room's back-wall picking
        // shape (z −1.5), so its click target sits just in front of the wall.
        glass.components.set(CollisionComponent(shapes: [
            ShapeResource.generateBox(size: [Window.width, height, 0.02])
                .offsetBy(translation: [Window.centre, (Window.bottom + Window.top) / 2, Window.clickZ]),
        ]))
        glass.components.set(InputTargetComponent())
        room.addChild(glass)
    }

    /// Soft cloud blobs between the sky and the glass (made the first time
    /// the weather needs them).
    static func buildClouds(into room: Entity) -> ModelEntity? {
        var clouds = MeshBatch()
        let blobs: [(SIMD3<Float>, SIMD3<Float>)] = [
            ([0.35, 2.0, 0], [0.22, 0.07, 0.02]), ([0.55, 2.05, 0], [0.18, 0.08, 0.02]), ([0.45, 1.95, 0.004], [0.2, 0.05, 0.02]),
            ([1.05, 1.75, 0], [0.24, 0.07, 0.02]), ([1.25, 1.8, 0.003], [0.16, 0.06, 0.02]), ([0.7, 1.45, 0], [0.2, 0.05, 0.02]),
            ([0.9, 1.48, 0.003], [0.14, 0.045, 0.02]),
        ]
        for (centre, size) in blobs {
            clouds.add(LoftShapes.unitSphere, at: [centre.x, centre.y, -1.72 + centre.z], scale: size)
        }
        guard let entity = clouds.entity(StudyLibraryMaterials.cloud("#F4F6F8"), name: "clouds") else { return nil }
        room.addChild(entity)
        return entity
    }

    /// A pale veil just behind the glass: fog lowers the contrast.
    static func buildFog(into room: Entity) -> ModelEntity {
        let fog = ModelEntity(mesh: .generatePlane(width: Window.width, height: Window.top - Window.bottom),
                              materials: [StudyLibraryMaterials.translucent("#C9D0D6", opacity: 0.55)])
        fog.position = [Window.centre, (Window.bottom + Window.top) / 2, -1.6]
        room.addChild(fog)
        return fog
    }

    /// Slow white dots in two groups (the motion lets them fall).
    static func buildSnow(into room: Entity) -> [Entity] {
        var random = SeededRandom(seed: 11)
        let flake = LoftGeometry.generateSphere(radius: 0.006, rings: 4, segments: 6)
        return (0..<2).map { group in
            var batch = MeshBatch()
            for _ in 0..<20 {
                batch.add(flake, at: [Float.random(in: 0.2...1.4, using: &random), Float.random(in: 1.25...2.25, using: &random), -1.6])
            }
            let holder = Entity()
            holder.name = "snow-\(group)"
            if let flakes = batch.entity(StudyLibraryMaterials.translucent("#FFFFFF", opacity: 0.9)) {
                flakes.components.set(OpacityComponent(opacity: 0.9))
                holder.addChild(flakes)
            }
            room.addChild(holder)
            return holder
        }
    }

    // MARK: - Earned books (upper shelves)

    /// The upper shelves' sections, in filling order: (shelf, segment).
    static let earnedSlots: [(shelf: Int, segment: Int)] = [(3, 0), (3, 1), (3, 2), (4, 0), (4, 1), (4, 2)]

    /// The z range books can use in a slot (the photo and fern take some).
    static func earnedRange(_ slot: Int) -> ClosedRange<Float> {
        let (shelf, segment) = earnedSlots[slot]
        let bounds = Shelf.segments[segment]
        var limit = bounds.1 - 0.02
        if shelf == 3 && segment == 2 { limit -= 0.22 }   // the photo
        if shelf == 4 && segment == 0 { limit -= 0.25 }   // the fern
        return (bounds.0 + 0.02)...limit
    }

    /// An earned book's thickness, steady across rebuilds.
    static func earnedThickness(term: String, index: Int) -> Float {
        var random = SeededRandom(seed: UInt64(truncatingIfNeeded: term.unicodeScalars.reduce(5381) { ($0 << 5) &+ $0 &+ Int($1.value) }) &+ UInt64(index))
        return Float.random(in: 0.018...0.026, using: &random)
    }

    struct EarnedPlacement: Equatable {
        /// Index into the state's shelf sections.
        let section: Int
        /// Each book's slot and z centre (books that don't fit are left out).
        var books: [(slot: Int, z: Float)]
        /// Where the plaque goes: its slot and z start.
        let plaque: (slot: Int, z: Float)

        static func == (a: EarnedPlacement, b: EarnedPlacement) -> Bool {
            a.section == b.section && a.books.map(\.slot) == b.books.map(\.slot) && a.books.map(\.z) == b.books.map(\.z)
                && a.plaque.slot == b.plaque.slot && a.plaque.z == b.plaque.z
        }
    }

    /// Lays terms out oldest first, each starting a new section and running
    /// on into the next as it fills. When they don't all fit, the oldest
    /// terms are left off (their hours are kept, just not drawn).
    static func earnedLayout(_ sections: [StudyRoomState.ShelfSection]) -> [EarnedPlacement] {
        func place(_ indices: [Int]) -> [EarnedPlacement]? {
            var slot = 0
            var placements: [EarnedPlacement] = []
            for index in indices {
                guard slot < earnedSlots.count else { return nil }
                let section = sections[index]
                var z = earnedRange(slot).lowerBound
                var placement = EarnedPlacement(section: index, books: [], plaque: (slot, z))
                for book in section.colors.indices {
                    let thickness = earnedThickness(term: section.term, index: book)
                    if z + thickness > earnedRange(slot).upperBound {
                        slot += 1
                        // The current term may run out of shelf; the others must fit.
                        guard slot < earnedSlots.count else { return index == sections.count - 1 ? placements + [placement] : nil }
                        z = earnedRange(slot).lowerBound
                    }
                    placement.books.append((slot, z + thickness / 2))
                    z += thickness + 0.002
                }
                placements.append(placement)
                slot += 1
            }
            return placements
        }
        var first = 0
        while first < sections.count {
            if let placements = place(Array(first..<sections.count)) { return placements }
            first += 1
        }
        return []
    }

    /// One entity per term: its books (merged by colour) and a brass plaque
    /// on the shelf lip ("Fall 2026 · 63 h"), hoverable for the details.
    static func buildEarnedBooks(_ sections: [StudyRoomState.ShelfSection], _ m: StudyLibraryMaterials, into room: Entity, detail: Bool,
                                 miniature: B? = nil) {
        let spine = simd_quatf(angle: .pi / 2, axis: [0, 1, 0]) * simd_quatf(angle: .pi / 2, axis: [0, 0, 1])
        if let miniature {
            // The overview: one block per filled section, in colours the room already uses.
            let spines = m.palette.spines
            for placement in earnedLayout(sections) {
                for slot in Set(placement.books.map(\.slot)).sorted() {
                    let zs = placement.books.filter { $0.slot == slot }.map(\.z)
                    guard let low = zs.min(), let high = zs.max() else { continue }
                    let floor = Shelf.floors[earnedSlots[slot].shelf]
                    miniature.add(.paint(spines[(slot + placement.section) % 4]), box(0.18, 0.2, high - low + 0.024),
                                  at: [Shelf.front - 0.12, floor + 0.1, (low + high) / 2])
                }
            }
            return
        }
        for placement in earnedLayout(sections) {
            let section = sections[placement.section]
            let batches = B(m)
            var random = SeededRandom(seed: UInt64(placement.section * 31 + section.colors.count))
            for (index, position) in placement.books.enumerated() {
                let floor = Shelf.floors[earnedSlots[position.slot].shelf]
                let height = Float.random(in: 0.17...0.24, using: &random), depth = Float.random(in: 0.15...0.19, using: &random)
                let thickness = earnedThickness(term: section.term, index: index)
                let shape = detail ? rbox(depth, height, thickness, 0.004) : box(depth, height, thickness)
                batches.add(.paint(section.colors[index]), shape, at: [Shelf.front - 0.03 - depth / 2, floor + height / 2, position.z])
            }
            if detail {
                // The plaque: a brass plate on the shelf's front edge.
                let floor = Shelf.floors[earnedSlots[placement.plaque.slot].shelf]
                let label = "\(section.term) · \(section.hours) h"
                let text = MeshResource.generateText(label, extrusionDepth: 0.001, font: .systemFont(ofSize: 0.013, weight: .semibold))
                let width = min(0.36, text.bounds.extents.x + 0.03)
                let centre = SIMD3<Float>(Shelf.front + 0.004, floor - 0.016, placement.plaque.z + width / 2 + 0.01)
                batches.add(.brass, rbox(0.006, 0.026, width, 0.003), at: centre)
                let matrix = Transform(rotation: spine, translation: centre + [0.0035, 0, 0]).matrix
                    * Transform(translation: [-text.bounds.center.x, -text.bounds.center.y, 0]).matrix
                batches.add(.paint(StudyLibraryPalette.current.walnut), LoftGeometry(text), matrix: matrix)
            }
            guard detail else { continue }
            let container = Entity()
            container.name = StudyRoomState.Item.shelf(section.term).entityName
            batches.flush(into: container)
            room.addChild(container)
            RoomBuilder.makeInteractive(container)
        }
    }

    // MARK: - Streak stars (windowsill)

    enum Stars {
        static let sill: Float = Window.bottom + 0.02
        static let z: Float = -1.48
        static let first: Float = 0.9
        static let spacing: Float = 0.072
        static let radius: Float = 0.032
        static let visible = 7
    }

    /// A five-pointed star prism standing in the xy plane, facing +z.
    static func starGeometry(outer: Float, inner: Float, depth: Float) -> LoftGeometry {
        var g = LoftGeometry()
        let points = (0..<10).map { index -> SIMD2<Float> in
            let angle = Float.pi / 2 + Float(index) * .pi / 5
            let r = index.isMultiple(of: 2) ? outer : inner
            return [cos(angle) * r, sin(angle) * r]
        }
        for (z, normal) in [(depth / 2, SIMD3<Float>(0, 0, 1)), (-depth / 2, SIMD3<Float>(0, 0, -1))] {
            let centre = UInt32(g.positions.count)
            g.positions.append([0, 0, z]); g.normals.append(normal); g.uvs.append([0.5, 0.5])
            for p in points {
                g.positions.append([p.x, p.y, z]); g.normals.append(normal); g.uvs.append([0.5 + p.x / outer / 2, 0.5 + p.y / outer / 2])
            }
            for i in 0..<UInt32(10) {
                let a = centre + 1 + i, b = centre + 1 + (i + 1) % 10
                g.indices += normal.z > 0 ? [centre, a, b] : [centre, b, a]
            }
        }
        // Sides.
        for i in 0..<10 {
            let p = points[i], q = points[(i + 1) % 10]
            let edge = q - p
            let normal = simd_normalize(SIMD3<Float>(edge.y, -edge.x, 0))
            let base = UInt32(g.positions.count)
            for (point, z) in [(p, depth / 2), (q, depth / 2), (q, -depth / 2), (p, -depth / 2)] {
                g.positions.append([point.x, point.y, z]); g.normals.append(normal); g.uvs.append([0, 0])
            }
            g.indices += [base, base + 3, base + 2, base, base + 2, base + 1]
        }
        return g
    }

    /// The stars' container: a fixed hover area on the sill; the motion
    /// fills its content from the streak.
    static func buildStars(into room: Entity) -> Entity {
        let container = Entity()
        container.name = StudyRoomState.Item.stars.entityName
        let content = Entity()
        content.name = "starsContent"
        container.addChild(content)
        let width = Stars.spacing * Float(Stars.visible) + 0.1
        container.components.set(CollisionComponent(shapes: [
            ShapeResource.generateBox(size: [width, 0.08, 0.06])
                .offsetBy(translation: [Stars.first - Stars.spacing / 2 + width / 2, Stars.sill + 0.03, Stars.z]),
        ]))
        container.components.set(InputTargetComponent())
        room.addChild(container)
        return content
    }

    /// Up to seven brass stars and the day count; one dim star with no streak.
    static func fillStars(_ content: Entity, _ streak: StudyRoomState.Streak, _ m: StudyLibraryMaterials) {
        content.children.removeAll()
        let star = starGeometry(outer: Stars.radius, inner: Stars.radius * 0.45, depth: 0.008)
        var stars = MeshBatch()
        let count = max(1, min(streak.days, Stars.visible))
        for index in 0..<count {
            stars.add(star, at: [Stars.first + Float(index) * Stars.spacing, Stars.sill + Stars.radius + 0.002, Stars.z],
                      rotation: simd_quatf(angle: Float(index % 3 - 1) * 0.12, axis: [0, 0, 1]))
        }
        if streak.days > 0 {
            // The day count, in the same mesh.
            let text = MeshResource.generateText("\(streak.days)", extrusionDepth: 0.004, font: .systemFont(ofSize: 0.055, weight: .bold))
            stars.add(LoftGeometry(text), at: [Stars.first + Float(count) * Stars.spacing - 0.01 - text.bounds.min.x,
                                               Stars.sill + 0.004 - text.bounds.min.y, Stars.z])
        }
        let material = streak.days > 0 ? StudyLibraryMaterials.emissive("#E6B85C", intensity: 0.9)
            : StudyLibraryMaterials.emissive(m.palette.parchment, intensity: 0.05)
        if let entity = stars.entity(material, name: "stars") { content.addChild(entity) }
    }

    // MARK: - The Companion, reading on the window seat

    enum Reader {
        /// Sitting on the cushion in front of the pillows, turned a little to the room.
        static let seat = SIMD3<Float>(0.6, 0.52, -1.18)
        static let yaw: Float = 0.3
        /// The book it holds, in the reader's own space.
        static let book = SIMD3<Float>(0, 0.14, 0.13)
        static let bookTilt: Float = -0.75
        static let focusAccent = "#818CF8"
        static let idleAccent = "#7DD3FC"
    }

    /// A small Companion in your colours (robot, creature or orb) holding
    /// an open book whose page the motion turns every ~20 s.
    static func buildReader(_ reader: StudyRoomState.Reader, _ m: StudyLibraryMaterials, into room: Entity,
                            parts: inout StudyLibraryParts) {
        let container = Entity()
        container.name = StudyRoomState.Item.reader.entityName
        container.position = Reader.seat
        container.orientation = simd_quatf(angle: Reader.yaw, axis: [0, 1, 0])
        let primary = LibraryMaterial.paint(reader.primary), secondary = LibraryMaterial.paint(reader.secondary)
        let body = B(m)
        var accents: [(SIMD3<Float>, Float)] = []
        var headTop: Float
        switch reader.style {
        case .robot:
            body.add(secondary, rbox(0.13, 0.11, 0.1, 0.03), at: [0, 0.06, 0])
            let tilt = simd_quatf(angle: 0.28, axis: [1, 0, 0])
            body.add(primary, rbox(0.17, 0.13, 0.13, 0.035), at: [0, 0.19, 0], rotation: tilt)
            body.add(.paint("#141414"), rbox(0.13, 0.08, 0.01, 0.02), at: [0, 0.188, 0.062], rotation: tilt)
            accents = [([-0.03, 0.193, 0.069], 0.011), ([0.03, 0.193, 0.069], 0.011)]
            for x: Float in [-0.085, 0.085] { body.add(primary, LoftShapes.unitSphere, at: [x, 0.09, 0.07], scale: SIMD3(repeating: 0.028)) }
            headTop = 0.26
        case .creature:
            body.add(primary, LoftShapes.unitSphere, at: [0, 0.11, 0], scale: [0.11, 0.105, 0.1])
            body.add(secondary, LoftShapes.unitSphere, at: [0, 0.08, 0.05], scale: [0.07, 0.06, 0.04])
            for x: Float in [-0.065, 0.065] {
                body.add(primary, LoftShapes.unitSphere, at: [x, 0.205, 0], scale: SIMD3(repeating: 0.03))
                body.add(.paper, LoftShapes.unitSphere, at: [x * 0.55, 0.15, 0.085], scale: SIMD3(repeating: 0.02))
                body.add(primary, LoftShapes.unitSphere, at: [x * 1.3, 0.085, 0.07], scale: SIMD3(repeating: 0.026))
            }
            accents = [([-0.036, 0.147, 0.1], 0.01), ([0.036, 0.147, 0.1], 0.01)]
            headTop = 0.23
        case .orb:
            body.add(.paint(reader.primary), LoftShapes.unitSphere, at: [0, 0.14, 0], scale: SIMD3(repeating: 0.075))
            body.add(.paint("#141414"), LoftShapes.unitSphere, at: [-0.025, 0.15, 0.07], scale: SIMD3(repeating: 0.009))
            body.add(.paint("#141414"), LoftShapes.unitSphere, at: [0.025, 0.15, 0.07], scale: SIMD3(repeating: 0.009))
            accents = [([0, 0.14, 0], 0.05)]
            headTop = 0.22
        }
        body.flush(into: container)

        // Eyes (or the orb's core), recoloured by mood.
        var lights: [ModelEntity] = []
        for (position, radius) in accents {
            let eye = ModelEntity(mesh: .generateSphere(radius: radius),
                                  materials: [StudyLibraryMaterials.emissive(reader.isFocused ? Reader.focusAccent : Reader.idleAccent, intensity: 1.2)])
            eye.position = position
            container.addChild(eye)
            lights.append(eye)
        }
        parts.readerAccents = lights

        // The open book, tilted up towards its face.
        let book = Entity()
        book.position = Reader.book
        book.orientation = simd_quatf(angle: Reader.bookTilt, axis: [1, 0, 0])
        let pages = B(m)
        pages.add(.paint(m.palette.burgundy), rbox(0.15, 0.006, 0.1, 0.002), at: [0, -0.004, 0])
        pages.add(.paper, box(0.07, 0.01, 0.094), at: [-0.037, 0.004, 0])
        pages.add(.paper, box(0.07, 0.01, 0.094), at: [0.037, 0.004, 0])
        pages.flush(into: book)
        let hinge = Entity()
        hinge.position = [0, 0.0095, 0]
        let page = ModelEntity(mesh: .generateBox(width: 0.068, height: 0.0015, depth: 0.092), materials: [m.material(.paper)])
        page.position = [0.034, 0, 0]
        hinge.addChild(page)
        book.addChild(hinge)
        container.addChild(book)
        parts.readerPage = hinge

        // A small warm light above its head: suggestions are waiting.
        let dot = ModelEntity(mesh: .generateSphere(radius: 0.012), materials: [StudyLibraryMaterials.emissive("#FFD27A", intensity: 1.6)])
        dot.position = [0, headTop + 0.05, 0]
        dot.isEnabled = reader.waiting > 0 && !reader.isFocused
        container.addChild(dot)
        parts.readerDot = dot

        room.addChild(container)
        RoomBuilder.makeInteractive(container)
    }
}

extension StudyLibraryMaterials {
    static func translucent(_ hex: String, opacity: Float) -> UnlitMaterial {
        var material = UnlitMaterial(color: NSColor(atlasHex: hex))
        material.blending = .transparent(opacity: .init(floatLiteral: opacity))
        return material
    }

    static func cloud(_ hex: String) -> UnlitMaterial { translucent(hex, opacity: 0.85) }

    /// The sky's gradient for this view.
    static func sky(_ view: StudyRoomState.WindowView, palette: StudyLibraryPalette) -> UnlitMaterial {
        let colors = StudyLibraryBuilder.Sky.colors(view, palette: palette)
        var sky = UnlitMaterial(color: .white)
        if let texture = CreativeLoftMaterials.gradient([colors.low, colors.top]) {
            sky.color = .init(tint: .white, texture: .init(texture))
        } else {
            sky.color = .init(tint: NSColor(atlasHex: colors.low))
        }
        return sky
    }
}
