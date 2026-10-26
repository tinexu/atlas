import AppKit
import AtlasCore
import AtlasOrbit
import RealityKit

/// What the Universe shows right now, worked out from the index on the
/// main actor. The scene only rebuilds when `signature` changes.
struct UniverseContent: Equatable {
    struct Planet: Equatable {
        let id: String          // "planet:<path>" / "project:<id>"
        let name: String
        let size: Int64
        let detail: String
        let isProject: Bool
        let moons: [Moon]
    }

    struct Moon: Equatable {
        let path: String
        let name: String
        let size: Int64
    }

    struct Item: Equatable {
        let path: String
        let name: String
        let category: FileCategory
        let size: Int64
        let isFolder: Bool
        let dimmed: Bool
    }

    struct Cluster: Equatable {
        let category: FileCategory
        let count: Int
        let size: Int64
    }

    enum Mode: Equatable {
        case overview(planets: [Planet])
        case folder(path: String, name: String, size: Int64, items: [Item], clusters: [Cluster])
    }

    var mode: Mode
    var selection: String?
    var signature: String
}

struct HealthIndicators: Equatable {
    var cpu: Double
    var memoryPercent: Double
    var diskUsedPercent: Double
    var diskFree: Int64
    var battery: Double?

    init(_ sample: HealthSample) {
        cpu = sample.cpu
        memoryPercent = sample.memoryPercent
        diskUsedPercent = sample.diskUsedPercent
        diskFree = sample.diskFree
        battery = sample.battery
    }

    var labels: [String] {
        var lines = ["CPU \(Int(cpu.rounded()))%", "Memory \(Int(memoryPercent.rounded()))%",
                     "Disk \(ByteCountFormatter.string(fromByteCount: diskFree, countStyle: .file)) free"]
        if let battery { lines.append("Battery \(Int(battery))%") }
        return lines
    }
}

/// The RealityKit side of the File Universe. Shapes and colours by file
/// kind, sizes on a log scale so one huge folder can't swallow the view,
/// and never more than a few hundred objects at once.
@MainActor
final class UniverseScene {
    let root = Entity()
    private let camera = PerspectiveCamera()
    private let content = Entity()
    private let healthRoot = Entity()
    private var ring: Entity?
    private var ringController: AnimationPlaybackController?
    private var healthLabels: [ModelEntity] = []
    private var lastSignature = ""
    private var lastHealth: [String] = []
    private var positions: [String: SIMD3<Float>] = [:]

    private var yaw: Float = 0.4
    private var pitch: Float = 0.45
    private var distance: Float = 16
    private var target = SIMD3<Float>.zero

    private static let unitSphere = MeshResource.generateSphere(radius: 1)
    private static let unitBox = MeshResource.generateBox(size: 1.6, cornerRadius: 0.15)
    private static let unitCylinder = MeshResource.generateCylinder(height: 1.4, radius: 0.8)
    private static let flatBox = MeshResource.generateBox(width: 1.7, height: 1.7, depth: 0.25, cornerRadius: 0.1)
    private var materials: [String: UnlitMaterial] = [:]

    init() {
        camera.camera.fieldOfViewInDegrees = 50
        root.addChild(camera)
        root.addChild(content)
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<80 {
            let star = ModelEntity(mesh: .generateSphere(radius: 0.03), materials: [UnlitMaterial(color: NSColor(white: 1, alpha: 0.45))])
            star.position = [Float.random(in: -40...40, using: &generator), Float.random(in: -25...25, using: &generator),
                             Float.random(in: -40 ... -15, using: &generator)]
            root.addChild(star)
        }
        applyCamera()
    }

    // MARK: - Building

    private var lastFocus: String?

    func sync(_ universe: UniverseContent, health: HealthIndicators?, reduceMotion: Bool) {
        if universe.signature != lastSignature {
            lastSignature = universe.signature
            rebuild(universe, reduceMotion: reduceMotion)
            lastHealth = []
        }
        // Fly to a newly selected object (e.g. a search result) once.
        if universe.selection != lastFocus {
            lastFocus = universe.selection
            if let selection = universe.selection { focus(on: selection, animated: !reduceMotion) }
        }
        if case .overview = universe.mode, let health { updateHealth(health, reduceMotion: reduceMotion) }
    }

    private func material(_ color: NSColor, opacity: Float = 1) -> UnlitMaterial {
        let key = "\(color.description)|\(opacity)"
        if let cached = materials[key] { return cached }
        var material = UnlitMaterial(color: color)
        if opacity < 1 { material.blending = .transparent(opacity: .init(floatLiteral: opacity)) }
        materials[key] = material
        return material
    }

    /// Log-scale radius, so 1 KB and 100 GB both stay visible.
    static func radius(for size: Int64, base: Float, scale: Float) -> Float {
        base + scale * log10(Float(max(size, 1)) / 1_000 + 1)
    }

    private func rebuild(_ universe: UniverseContent, reduceMotion: Bool) {
        content.children.removeAll()
        positions = [:]
        ring = nil
        ringController = nil
        healthLabels = []
        switch universe.mode {
        case .overview(let planets):
            buildOverview(planets, selection: universe.selection, reduceMotion: reduceMotion)
            frame(radius: Float(6 + planets.count))
        case .folder(let path, let name, let size, let items, let clusters):
            buildFolder(path: path, name: name, size: size, items: items, clusters: clusters, selection: universe.selection)
            frame(radius: 5 + sqrt(Float(items.count + clusters.count)) * 0.9)
        }
    }

    private func buildOverview(_ planets: [UniverseContent.Planet], selection: String?, reduceMotion: Bool) {
        // The Mac in the middle.
        let mac = ModelEntity(mesh: Self.unitSphere, materials: [material(NSColor(red: 0.35, green: 0.55, blue: 0.95, alpha: 1))])
        mac.scale = .init(repeating: 1.1)
        mac.name = "mac"
        mac.components.set(CollisionComponent(shapes: [.generateSphere(radius: 1)]))
        mac.components.set(InputTargetComponent())
        healthRoot.children.removeAll()
        healthRoot.addChild(mac)
        healthRoot.addChild(label("Mac", size: 0.32, at: [0, -1.6, 0]))
        content.addChild(healthRoot)

        let count = max(planets.count, 1)
        for (index, planet) in planets.enumerated() {
            let angle = Float(index) / Float(count) * 2 * .pi
            let orbit: Float = 5.5 + Float(count > 6 ? 1.5 : 0)
            let position = SIMD3<Float>(cos(angle) * orbit, planet.isProject ? 1.2 : 0, sin(angle) * orbit)
            let radius = Self.radius(for: planet.size, base: 0.35, scale: 0.22)
            let color: NSColor = planet.isProject ? .systemPurple : .systemBlue
            let body = ModelEntity(mesh: Self.unitSphere, materials: [material(color)])
            body.scale = .init(repeating: radius)
            let container = Entity()
            container.name = planet.id
            container.position = position
            container.addChild(body)
            if selection == planet.id.replacingOccurrences(of: "planet:", with: "") || selection == planet.id {
                container.addChild(halo(radius: radius))
            }
            if planet.isProject {
                let band = ModelEntity(mesh: .generateCylinder(height: 0.02, radius: radius * 1.7), materials: [material(.systemPurple, opacity: 0.35)])
                container.addChild(band)
            }
            container.addChild(label(planet.name, size: 0.24, at: [0, -radius - 0.45, 0]))
            container.addChild(label(planet.detail, size: 0.14, at: [0, -radius - 0.75, 0], color: NSColor(white: 1, alpha: 0.6)))
            container.components.set(CollisionComponent(shapes: [.generateSphere(radius: radius * 1.2)]))
            container.components.set(InputTargetComponent())
            content.addChild(container)
            positions[planet.id] = position
            positions[String(planet.id.drop { $0 != ":" }.dropFirst())] = position

            // Top-level subfolders as moons.
            for (m, moon) in planet.moons.enumerated() {
                let moonAngle = Float(m) / Float(max(planet.moons.count, 1)) * 2 * .pi
                let distance = radius + 0.7 + Float(m % 2) * 0.35
                let moonRadius = Self.radius(for: moon.size, base: 0.08, scale: 0.06)
                let entity = ModelEntity(mesh: Self.unitSphere, materials: [material(NSColor.systemTeal)])
                entity.scale = .init(repeating: moonRadius)
                let moonContainer = Entity()
                moonContainer.name = "item:" + moon.path
                moonContainer.position = position + SIMD3(cos(moonAngle) * distance, sin(moonAngle * 2) * 0.25, sin(moonAngle) * distance)
                moonContainer.addChild(entity)
                if selection == moon.path { moonContainer.addChild(halo(radius: moonRadius)) }
                moonContainer.components.set(CollisionComponent(shapes: [.generateSphere(radius: max(moonRadius * 1.5, 0.15))]))
                moonContainer.components.set(InputTargetComponent())
                content.addChild(moonContainer)
                positions[moon.path] = moonContainer.position
            }
        }
    }

    private func buildFolder(path: String, name: String, size: Int64, items: [UniverseContent.Item],
                             clusters: [UniverseContent.Cluster], selection: String?) {
        let centerRadius: Float = 1.2
        let center = ModelEntity(mesh: Self.unitSphere, materials: [material(.systemBlue, opacity: 0.35)])
        center.scale = .init(repeating: centerRadius)
        center.name = "center:" + path
        content.addChild(center)
        content.addChild(label(name, size: 0.3, at: [0, -centerRadius - 0.5, 0]))
        content.addChild(label(ByteCountFormatter.string(fromByteCount: size, countStyle: .file), size: 0.16,
                               at: [0, -centerRadius - 0.85, 0], color: NSColor(white: 1, alpha: 0.6)))

        // Folders on an inner spiral, files further out.
        let golden = Float.pi * (3 - sqrt(5))
        var folderIndex = 0, fileIndex = 0
        for item in items {
            let position: SIMD3<Float>
            if item.isFolder {
                let r = centerRadius + 1.4 + sqrt(Float(folderIndex)) * 0.9
                let a = Float(folderIndex) * golden
                position = [cos(a) * r, 0.25 * sin(Float(folderIndex)), sin(a) * r]
                folderIndex += 1
            } else {
                let r = centerRadius + 4 + sqrt(Float(fileIndex)) * 0.55
                let a = Float(fileIndex) * golden
                let layer = Float(FileCategory.allCases.firstIndex(of: item.category) ?? 0) - 4
                position = [cos(a) * r, layer * 0.18, sin(a) * r]
                fileIndex += 1
            }
            let radius = item.isFolder ? Self.radius(for: item.size, base: 0.18, scale: 0.09)
                                       : Self.radius(for: item.size, base: 0.06, scale: 0.05)
            let container = Entity()
            container.name = "item:" + item.path
            container.position = position
            let body = ModelEntity(mesh: mesh(for: item.category, isFolder: item.isFolder),
                                   materials: [material(OrbitColors.nsColor(item.category), opacity: item.dimmed ? 0.15 : 1)])
            body.scale = .init(repeating: radius)
            container.addChild(body)
            if item.path == selection {
                container.addChild(halo(radius: radius))
                container.addChild(label(item.name, size: 0.16, at: [0, -radius - 0.3, 0]))
            } else if item.isFolder {
                container.addChild(label(item.name, size: 0.14, at: [0, -radius - 0.25, 0], color: NSColor(white: 1, alpha: item.dimmed ? 0.3 : 0.8)))
            }
            container.components.set(CollisionComponent(shapes: [.generateSphere(radius: max(radius * 1.4, 0.12))]))
            container.components.set(InputTargetComponent())
            content.addChild(container)
            positions[item.path] = position
        }

        // "N files" clusters for whatever didn't fit, one per kind.
        for (index, cluster) in clusters.enumerated() {
            let a = Float(index) / Float(max(clusters.count, 1)) * 2 * .pi + 0.3
            let r = centerRadius + 4 + sqrt(Float(fileIndex)) * 0.55 + 1.5
            let position = SIMD3<Float>(cos(a) * r, -0.6, sin(a) * r)
            let container = Entity()
            container.name = "cluster:" + cluster.category.rawValue
            container.position = position
            var generator = SystemRandomNumberGenerator()
            let dots = min(30, max(6, cluster.count / 10))
            for _ in 0..<dots {
                let dot = ModelEntity(mesh: Self.unitSphere, materials: [material(OrbitColors.nsColor(cluster.category), opacity: 0.8)])
                dot.scale = .init(repeating: 0.05)
                dot.position = [Float.random(in: -0.5...0.5, using: &generator), Float.random(in: -0.3...0.3, using: &generator),
                                Float.random(in: -0.5...0.5, using: &generator)]
                container.addChild(dot)
            }
            container.addChild(label("\(cluster.count.formatted()) \(cluster.category.title.lowercased())", size: 0.14, at: [0, -0.7, 0]))
            container.components.set(CollisionComponent(shapes: [.generateSphere(radius: 0.7)]))
            container.components.set(InputTargetComponent())
            content.addChild(container)
        }
    }

    private func mesh(for category: FileCategory, isFolder: Bool) -> MeshResource {
        if isFolder { return Self.unitSphere }
        switch category {
        case .document, .image: return Self.flatBox
        case .code, .archive: return Self.unitBox
        case .video, .audio: return Self.unitCylinder
        case .app, .folder, .other: return Self.unitSphere
        }
    }

    private func halo(radius: Float) -> ModelEntity {
        let halo = ModelEntity(mesh: Self.unitSphere, materials: [material(.white, opacity: 0.25)])
        halo.scale = .init(repeating: radius * 1.8)
        return halo
    }

    private func label(_ text: String, size: CGFloat, at position: SIMD3<Float>, color: NSColor = NSColor(white: 1, alpha: 0.9)) -> ModelEntity {
        let mesh = MeshResource.generateText(String(text.prefix(40)), extrusionDepth: 0.002, font: .systemFont(ofSize: size, weight: .medium))
        let entity = ModelEntity(mesh: mesh, materials: [material(color)])
        entity.position = position - SIMD3(mesh.bounds.center.x, 0, 0)
        return entity
    }

    // MARK: - Health planet

    /// Busier CPU spins the ring faster; a fuller disk crowds it with more
    /// particles. Exact values are always shown next to it.
    private func updateHealth(_ health: HealthIndicators, reduceMotion: Bool) {
        let labels = health.labels
        let particleCount = Int((health.diskUsedPercent / 100 * 60).rounded())
        let wantRing = "\(particleCount)"
        if ring?.name != "ring:" + wantRing {
            ring?.removeFromParent()
            let newRing = Entity()
            newRing.name = "ring:" + wantRing
            for i in 0..<max(particleCount, 1) {
                let a = Float(i) / 60 * 2 * .pi
                let dot = ModelEntity(mesh: Self.unitSphere, materials: [material(.systemTeal, opacity: 0.9)])
                dot.scale = .init(repeating: 0.06)
                dot.position = [cos(a) * 1.8, 0, sin(a) * 1.8]
                newRing.addChild(dot)
            }
            newRing.orientation = simd_quatf(angle: 0.35, axis: [1, 0, 0])
            healthRoot.addChild(newRing)
            ring = newRing
            ringController = nil
        }
        if !reduceMotion {
            if ringController == nil, let ring,
               let resource = try? AnimationResource.generate(with: FromToByAnimation<Transform>(
                   by: Transform(rotation: simd_quatf(angle: .pi / 2, axis: [0, 1, 0])), duration: 6,
                   bindTarget: .transform, repeatMode: .cumulative)) {
                ringController = ring.playAnimation(resource)
            }
            ringController?.speed = Float(0.15 + health.cpu / 100 * 2.5)
        } else {
            ringController?.stop()
            ringController = nil
        }
        guard labels != lastHealth else { return }
        lastHealth = labels
        healthLabels.forEach { $0.removeFromParent() }
        healthLabels = labels.enumerated().map { index, text in
            label(text, size: 0.17, at: [2.4, 0.6 - Float(index) * 0.32, 0])
        }
        healthLabels.forEach { healthRoot.addChild($0) }
    }

    // MARK: - Picking

    /// "item:<path>", "planet:<path>", "project:<id>", "cluster:<kind>" or "mac".
    func identifier(for entity: Entity) -> String? {
        var current: Entity? = entity
        while let node = current {
            if node.name.hasPrefix("item:") || node.name.hasPrefix("planet:") || node.name.hasPrefix("project:")
                || node.name.hasPrefix("cluster:") || node.name == "mac" {
                return node.name
            }
            current = node.parent
        }
        return nil
    }

    // MARK: - Camera

    func orbit(dx: Float, dy: Float) {
        yaw -= dx * 0.008
        pitch = min(max(pitch + dy * 0.006, -1.3), 1.3)
        applyCamera()
    }

    func zoom(by factor: Float) {
        guard factor.isFinite, factor > 0 else { return }
        distance = min(max(distance / factor, 2.5), 80)
        applyCamera()
    }

    var cameraDistance: Float { distance }

    func resetView() {
        yaw = 0.4
        pitch = 0.45
        target = .zero
        lastSignature = ""
        lastFocus = nil
    }

    func focus(on id: String, animated: Bool) {
        guard let position = positions[id] else { return }
        target = position
        distance = min(distance, 7)
        applyCamera(animated: animated)
    }

    private func frame(radius: Float) {
        target = .zero
        distance = min(max(radius * 2.1, 8), 70)
        applyCamera()
    }

    private func applyCamera(animated: Bool = false) {
        let offset = SIMD3<Float>(cos(pitch) * sin(yaw), sin(pitch), cos(pitch) * cos(yaw)) * distance
        if animated {
            var transform = Transform(matrix: camera.transformMatrix(relativeTo: nil))
            transform.translation = target + offset
            transform.rotation = simd_quatf(from: [0, 0, -1], to: simd_normalize(target - (target + offset)))
            camera.move(to: transform, relativeTo: nil, duration: 0.6, timingFunction: .easeInOut)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.65) { [weak self] in
                guard let self else { return }
                self.camera.look(at: self.target, from: self.target + offset, relativeTo: nil)
            }
        } else {
            camera.look(at: target, from: target + offset, relativeTo: nil)
        }
    }
}

enum OrbitColors {
    static func nsColor(_ category: FileCategory) -> NSColor { OrbitFormat.nsColor(category) }
}
