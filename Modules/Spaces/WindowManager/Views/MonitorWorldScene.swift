import AppKit
import AtlasCore
import AtlasSpaces
import RealityKit

/// The RealityKit miniature of the user's real monitor setup: each display
/// as a panel with a bezel and stand at its real relative position, and
/// each window as a small labeled panel with its app's icon.
///
/// The camera looks straight at the monitors, so a drag in the view maps
/// linearly onto the displays and editing stays precise. Window entities
/// are built once per rule and only moved or rescaled while dragging.
@MainActor
final class MonitorWorldScene {
    /// World units per screen point: a 1440-point display is 1.44 units wide.
    static let unitsPerPoint: Float = 1.0 / 1000
    static let fieldOfView: Float = 40

    let root = Entity()
    private let camera = PerspectiveCamera()
    private let displaysRoot = Entity()
    private let windowsRoot = Entity()
    private let guide: ModelEntity

    private var displaySignature: [DisplayInfo] = []
    private var windows: [UUID: (signature: String, entity: Entity)] = [:]
    private var center = SIMD2<Float>.zero
    private(set) var cameraDistance: Float = 3
    /// Aimed a little low so the stands fit; a pure offset keeps drags linear.
    private let cameraHeight: Float = -0.15

    init() {
        camera.camera.fieldOfViewInDegrees = Self.fieldOfView
        root.addChild(camera)
        root.addChild(displaysRoot)
        root.addChild(windowsRoot)

        let light = DirectionalLight()
        light.light.intensity = 2_400
        light.look(at: .zero, from: [-1.5, 2.5, 4], relativeTo: nil)
        root.addChild(light)

        var guideMaterial = UnlitMaterial(color: .controlAccentColor)
        guideMaterial.blending = .transparent(opacity: 0.28)
        guide = ModelEntity(mesh: .generatePlane(width: 1, height: 1), materials: [guideMaterial])
        guide.isEnabled = false
        root.addChild(guide)
    }

    // MARK: - Coordinates

    /// Canvas point (top-left origin, y down) → world position on the screens.
    func world(_ point: CGPoint, z: Float = 0) -> SIMD3<Float> {
        SIMD3(Float(point.x) * Self.unitsPerPoint - center.x, -(Float(point.y) * Self.unitsPerPoint - center.y), z)
    }

    /// View points per world unit on the screens' plane, for a view this tall.
    func pointsPerUnit(viewHeight: CGFloat) -> CGFloat {
        let visibleHeight = 2 * cameraDistance * tan(Self.fieldOfView * .pi / 360)
        return viewHeight / CGFloat(max(visibleHeight, 0.001))
    }

    /// A point in the view → canvas point on the screens' plane. Exact
    /// because the camera looks straight at the screens.
    func canvasPoint(fromView point: CGPoint, viewSize: CGSize) -> CGPoint {
        let ppu = pointsPerUnit(viewHeight: viewSize.height)
        let worldX = Float((point.x - viewSize.width / 2) / ppu)
        let worldY = Float((viewSize.height / 2 - point.y) / ppu) + cameraHeight
        return CGPoint(
            x: CGFloat((worldX + center.x) / Self.unitsPerPoint),
            y: CGFloat((center.y - worldY) / Self.unitsPerPoint)
        )
    }

    // MARK: - Sync

    func sync(
        canvas: LayoutCanvas,
        rules: [WindowRule],
        overrides: [UUID: CGRect],
        selection: UUID?,
        snap: LayoutCanvas.Snap?,
        aspect: CGFloat
    ) {
        if canvas.displays != displaySignature {
            displaySignature = canvas.displays
            rebuildDisplays(canvas)
        }
        frameCamera(canvas, aspect: aspect)

        let present = Set(rules.map(\.id))
        for (id, entry) in windows where !present.contains(id) {
            entry.entity.removeFromParent()
            windows[id] = nil
        }
        // Frontmost rule closest to the camera.
        let stacked = rules.sorted { $0.zOrder > $1.zOrder }
        for (depth, rule) in stacked.enumerated() {
            guard let rect = overrides[rule.id] ?? canvas.frame(of: rule) else { continue }
            let signature = "\(rule.bundleID)|\(rule.displayName)|\(rule.state.rawValue)"
            let entity: Entity
            if let existing = windows[rule.id], existing.signature == signature {
                entity = existing.entity
            } else {
                windows[rule.id]?.entity.removeFromParent()
                entity = Self.makeWindow(rule)
                windowsRoot.addChild(entity)
                windows[rule.id] = (signature, entity)
            }
            layout(entity, rect: rect, depth: depth, selected: rule.id == selection)
        }

        if let snap {
            guide.isEnabled = true
            let size = SIMD2(Float(snap.frame.width), Float(snap.frame.height)) * Self.unitsPerPoint
            guide.position = world(CGPoint(x: snap.frame.midX, y: snap.frame.midY), z: 0.006)
            guide.scale = [size.x, size.y, 1]
        } else {
            guide.isEnabled = false
        }
    }

    private func frameCamera(_ canvas: LayoutCanvas, aspect: CGFloat) {
        guard !canvas.bounds.isNull else { return }
        let bounds = canvas.bounds
        center = SIMD2(Float(bounds.midX), Float(bounds.midY)) * Self.unitsPerPoint
        let width = Float(bounds.width) * Self.unitsPerPoint
        // Room below for the stands.
        let height = Float(bounds.height) * Self.unitsPerPoint + 0.5
        let neededHeight = max(height, width / Float(max(aspect, 0.2))) * 1.12
        cameraDistance = neededHeight / 2 / tan(Self.fieldOfView * .pi / 360)
        camera.position = [0, cameraHeight, cameraDistance]
        camera.look(at: [0, cameraHeight, 0], from: camera.position, relativeTo: nil)
    }

    // MARK: - Displays

    private func rebuildDisplays(_ canvas: LayoutCanvas) {
        displaysRoot.children.removeAll()
        let bezel = SimpleMaterial(color: NSColor(white: 0.13, alpha: 1), roughness: 0.6, isMetallic: false)
        let metal = SimpleMaterial(color: NSColor(white: 0.7, alpha: 1), roughness: 0.35, isMetallic: true)
        let screen = UnlitMaterial(color: NSColor(red: 0.16, green: 0.19, blue: 0.25, alpha: 1))
        let menuBar = UnlitMaterial(color: NSColor(white: 0.32, alpha: 1))
        let lowest = canvas.displays.map { Float($0.frame.maxY) }.max() ?? 0

        // Centering depends on the camera; compute it here too.
        if !canvas.bounds.isNull {
            center = SIMD2(Float(canvas.bounds.midX), Float(canvas.bounds.midY)) * Self.unitsPerPoint
        }

        for display in canvas.displays {
            let frame = display.frame
            let w = Float(frame.width) * Self.unitsPerPoint, h = Float(frame.height) * Self.unitsPerPoint
            let holder = Entity()
            holder.name = "display:\(display.id)"
            holder.position = world(CGPoint(x: frame.midX, y: frame.midY))

            holder.addChild(Self.part(.generateBox(size: [w + 0.05, h + 0.05, 0.035], cornerRadius: 0.012), bezel, at: [0, 0, -0.02]))
            holder.addChild(Self.part(.generatePlane(width: w, height: h), screen, at: [0, 0, 0.0]))
            let bar = Float(display.visibleFrame.minY - frame.minY) * Self.unitsPerPoint
            if bar > 0 {
                holder.addChild(Self.part(.generatePlane(width: w, height: bar), menuBar, at: [0, h / 2 - bar / 2, 0.001]))
            }
            // Stand down to a shared floor below the lowest display.
            let floorY = -((lowest * Self.unitsPerPoint - center.y) + 0.3) - holder.position.y
            let neckHeight = max(0.05, -h / 2 - floorY)
            holder.addChild(Self.part(.generateBox(size: [0.06, neckHeight, 0.03]), metal, at: [0, -h / 2 - neckHeight / 2, -0.05]))
            holder.addChild(Self.part(.generateBox(size: [min(0.5, w * 0.4), 0.015, 0.22], cornerRadius: 0.005), metal,
                                      at: [0, floorY, -0.05]))

            let label = Self.text(display.isMain ? "\(display.name) · Main" : display.name, size: 0.05, color: NSColor(white: 1, alpha: 0.75))
            label.position = [-w / 2 + 0.03, -h / 2 + 0.03, 0.002]
            holder.addChild(label)
            displaysRoot.addChild(holder)
        }
    }

    // MARK: - Windows

    private static func makeWindow(_ rule: WindowRule) -> Entity {
        let container = Entity()
        container.name = "window:\(rule.id.uuidString)"

        // Minimized and hidden windows are drawn dimmer.
        let shade: CGFloat = rule.state == .normal ? 0.96 : 0.55
        let body = SimpleMaterial(color: NSColor(white: shade, alpha: 1), roughness: 0.8, isMetallic: false)
        let panel = ModelEntity(mesh: .generateBox(size: [1, 1, 1]), materials: [body])
        panel.name = "panel"
        container.addChild(panel)

        let titleBar = ModelEntity(mesh: .generateBox(size: [1, 1, 1]), materials: [UnlitMaterial(color: NSColor(white: 0.82, alpha: 1))])
        titleBar.name = "titleBar"
        container.addChild(titleBar)

        let outline = ModelEntity(mesh: .generateBox(size: [1, 1, 1]), materials: [UnlitMaterial(color: .controlAccentColor)])
        outline.name = "selection"
        outline.isEnabled = false
        container.addChild(outline)

        if let texture = iconTexture(for: rule.bundleID) {
            var material = UnlitMaterial()
            material.color = .init(tint: .white, texture: .init(texture))
            let icon = ModelEntity(mesh: .generatePlane(width: 0.12, height: 0.12, cornerRadius: 0.025), materials: [material])
            icon.name = "icon"
            container.addChild(icon)
        }
        let label = text(rule.displayName, size: 0.045, color: NSColor(white: 0.12, alpha: 1))
        label.name = "label"
        container.addChild(label)

        container.components.set(InputTargetComponent())
        return container
    }

    /// Positions a window panel without rebuilding it.
    private func layout(_ entity: Entity, rect: CGRect, depth: Int, selected: Bool) {
        let w = max(Float(rect.width) * Self.unitsPerPoint, 0.05)
        let h = max(Float(rect.height) * Self.unitsPerPoint, 0.04)
        let thickness: Float = 0.012
        entity.position = world(CGPoint(x: rect.midX, y: rect.midY), z: 0.012 + Float(depth) * 0.016)

        entity.findEntity(named: "panel")?.scale = [w, h, thickness]
        let barHeight = min(0.035, h * 0.2)
        if let bar = entity.findEntity(named: "titleBar") {
            bar.scale = [w, barHeight, thickness + 0.002]
            bar.position = [0, h / 2 - barHeight / 2, 0]
        }
        if let outline = entity.findEntity(named: "selection") {
            outline.isEnabled = selected
            outline.scale = [w + 0.02, h + 0.02, thickness * 0.5]
            outline.position = [0, 0, -thickness * 0.6]
        }
        let iconSize: Float = min(0.12, min(w, h) * 0.45)
        if let icon = entity.findEntity(named: "icon") {
            icon.scale = .one * (iconSize / 0.12)
            icon.position = [0, 0.01, thickness / 2 + 0.001]
            icon.isEnabled = h > 0.12
        }
        if let label = entity.findEntity(named: "label") as? ModelEntity, let bounds = label.model?.mesh.bounds {
            let fit = min(1, (w * 0.9) / max(bounds.extents.x, 0.001))
            label.scale = .one * fit
            label.position = [-bounds.center.x * fit, -h / 2 + 0.015, thickness / 2 + 0.001]
        }
        let collision = ShapeResource.generateBox(size: [w, h, thickness])
        entity.components.set(CollisionComponent(shapes: [collision]))
    }

    // MARK: - Picking

    func ruleID(for entity: Entity) -> UUID? {
        var current: Entity? = entity
        while let node = current {
            if node.name.hasPrefix("window:") { return UUID(uuidString: String(node.name.dropFirst(7))) }
            current = node.parent
        }
        return nil
    }

    // MARK: - Builders

    private static func part(_ mesh: MeshResource, _ material: some RealityKit.Material, at position: SIMD3<Float>) -> ModelEntity {
        let entity = ModelEntity(mesh: mesh, materials: [material])
        entity.position = position
        return entity
    }

    private static func text(_ string: String, size: CGFloat, color: NSColor) -> ModelEntity {
        let mesh = MeshResource.generateText(string, extrusionDepth: 0.001, font: .systemFont(ofSize: size, weight: .medium))
        return ModelEntity(mesh: mesh, materials: [UnlitMaterial(color: color)])
    }

    private static var textureCache: [String: TextureResource] = [:]

    /// The app icon drawn onto an opaque tile, so no alpha blending is needed.
    private static func iconTexture(for bundleID: String) -> TextureResource? {
        if let cached = textureCache[bundleID] { return cached }
        guard let icon = AppIcons.icon(for: bundleID) else { return nil }
        let pixels = 128
        guard let context = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.setFillColor(NSColor(white: 0.96, alpha: 1).cgColor)
        context.fill(CGRect(x: 0, y: 0, width: pixels, height: pixels))
        var rect = CGRect(x: 0, y: 0, width: pixels, height: pixels)
        guard let cgIcon = icon.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { return nil }
        context.draw(cgIcon, in: rect)
        guard let image = context.makeImage(),
              let texture = try? TextureResource(image: image, options: .init(semantic: .color))
        else { return nil }
        textureCache[bundleID] = texture
        return texture
    }
}
