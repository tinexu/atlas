import AppKit
import AtlasSpaces
import RealityKit

/// The loft's small ambient motions: dust drifting in the sunbeam, fairy
/// lights twinkling, a slow neon pulse and the monitor's colour cross-fade.
/// All of it runs on RealityKit's animation clock (no timers or per-frame
/// code), and none of it starts under Reduce Motion.
@MainActor
final class CreativeLoftMotion: RoomMotion {
    private(set) var parts: CreativeLoftParts
    let reduceMotion: Bool
    private var started = false
    private var celebration: Task<Void, Never>?

    init(parts: CreativeLoftParts, reduceMotion: Bool) {
        self.parts = parts
        self.reduceMotion = reduceMotion
    }

    /// Starts the loops. Called once the room is in the scene, since
    /// animations only play on entities that are.
    func start() {
        guard !started, !reduceMotion else { return }
        started = true

        for (index, bulb) in parts.bulbs.enumerated() {
            // Each bulb on its own slightly different rhythm.
            let duration = 1.3 + Double((index * 7) % 5) * 0.25
            loop(bulb, FromToByAnimation<Float>(from: 1, to: 0.45, duration: duration, timing: .easeInOut,
                                                bindTarget: .opacity, repeatMode: .autoReverse))
        }
        for (index, group) in parts.motes.enumerated() {
            var drifted = group.transform
            drifted.translation += SIMD3(0.06 * Float(index - 1), 0.12, 0.04)
            loop(group, FromToByAnimation<Transform>(from: group.transform, to: drifted, duration: 9 + Double(index) * 2,
                                                     timing: .easeInOut, bindTarget: .transform, repeatMode: .autoReverse))
        }
        if let neon = parts.neon {
            loop(neon, FromToByAnimation<Float>(from: 1, to: 0.8, duration: 2.5, timing: .easeInOut,
                                                bindTarget: .opacity, repeatMode: .autoReverse))
        }
        if let overlay = parts.screenOverlay {
            // Pink → peach → pink every 30 s.
            loop(overlay, FromToByAnimation<Float>(from: 0, to: 1, duration: 15, timing: .easeInOut,
                                                   bindTarget: .opacity, repeatMode: .autoReverse))
        }
    }

    /// On activation: the pendant brightens and the fairy lights sparkle
    /// left to right.
    func celebrate(baseIntensity: Float) {
        guard !reduceMotion else { return }
        celebration?.cancel()
        let bulbs = parts.bulbs
        let pendant = parts.pendantLight
        celebration = Task { @MainActor in
            pendant?.light.intensity = baseIntensity * 1.8
            for bulb in bulbs {
                guard !Task.isCancelled else { break }
                var big = bulb.transform
                big.scale *= 2.2
                if let resource = try? AnimationResource.generate(with: FromToByAnimation<Transform>(
                    from: bulb.transform, to: big, duration: 0.18, timing: .easeOut, bindTarget: .transform, repeatMode: .none
                )), let back = try? AnimationResource.generate(with: FromToByAnimation<Transform>(
                    from: big, to: bulb.transform, duration: 0.25, timing: .easeIn, bindTarget: .transform, repeatMode: .none
                )), let sparkle = try? AnimationResource.sequence(with: [resource, back]) {
                    bulb.playAnimation(sparkle, blendLayerOffset: 1)
                }
                try? await Task.sleep(for: .milliseconds(70))
            }
            try? await Task.sleep(for: .seconds(1.5))
            pendant?.light.intensity = baseIntensity
        }
    }

    // MARK: - Creative state

    private var lastCreative: CreativeRoomState?

    /// Puts the current project's picture on the easel and the monitor,
    /// and the session on the mug and neon. Only does work when they change.
    func update(_ creative: CreativeRoomState) {
        defer { lastCreative = creative }
        if lastCreative?.mug != creative.mug { applyMug(creative.mug, previous: lastCreative?.mug) }
        if lastCreative?.pegboard != creative.pegboard, let content = parts.pegboardContent {
            CreativeLoftBuilder.fillPegboard(content, creative.pegboard)
        }
        if lastCreative?.gallery != creative.gallery, let content = parts.galleryContent, let m = parts.materials {
            CreativeLoftBuilder.fillGallery(content, creative.gallery, m)
        }
        if lastCreative?.window != creative.window { applyWindow(creative.window) }
        if lastCreative?.rug != creative.rug, let content = parts.rugContent, let m = parts.materials {
            CreativeLoftBuilder.fillRug(content, creative.rug, m)
        }
        if lastCreative?.streak != creative.streak {
            streakGlow = creative.streak >= 7
            applyNeon()
        }
        if lastCreative?.painter != creative.painter { applyPainter(creative.painter, previous: lastCreative?.painter) }
        if lastCreative?.jars != creative.jars, let m = parts.materials {
            for (body, hex) in zip(parts.jarBodies, creative.jars) { body.model?.materials = [m.paint(hex)] }
        }
        if lastCreative?.easel?.image != creative.easel?.image, let plane = parts.easelPicture {
            Self.show(creative.easel?.image, on: plane, fitting: CreativeLoftBuilder.Easel.pictureArea)
            parts.easelBlobs?.isEnabled = !plane.isEnabled
        }
        if lastCreative?.monitorImage != creative.monitorImage, let plane = parts.monitorPicture {
            Self.show(creative.monitorImage, on: plane, fitting: CreativeLoftBuilder.monitorArea)
        }
    }

    private var steaming = false
    /// Whether the mug's steam is showing.
    var isSteaming: Bool { steaming }

    /// Steam while a session runs (still, under Reduce Motion); the neon
    /// glows brighter; a finished session refills the mug.
    private func applyMug(_ mug: CreativeRoomState.Mug, previous: CreativeRoomState.Mug?) {
        let steam = mug.isRunning && !mug.isPaused
        if steam != steaming {
            steaming = steam
            for (index, puff) in parts.steam.enumerated() {
                puff.isEnabled = steam
                puff.stopAllAnimations()
                guard steam, !reduceMotion else { continue }
                var high = puff.transform
                high.translation += [0.008 * Float(index - 1), 0.07, 0]
                high.scale *= 1.8
                loop(puff, FromToByAnimation<Transform>(from: puff.transform, to: high, duration: 2.4 + Double(index) * 0.5,
                                                        timing: .easeOut, bindTarget: .transform, repeatMode: .repeat))
            }
        }
        sessionGlow = mug.isRunning
        applyNeon()
        if let previous, mug.refills > previous.refills, let coffee = parts.mugCoffee {
            refill(coffee)
        }
    }

    private var sessionGlow = false
    private var streakGlow = false

    /// Brighter while a session runs, and a little more on a 7-day streak.
    private func applyNeon() {
        parts.neonLight?.light.intensity = CreativeLoftPalette.current.neonLightIntensity * (sessionGlow ? 1.8 : 1) * (streakGlow ? 1.4 : 1)
    }

    // MARK: Window

    private func applyWindow(_ view: StudyRoomState.WindowView) {
        typealias W = CreativeLoftBuilder.LoftWindow
        let palette = CreativeLoftPalette.current
        parts.sky?.model?.materials = [CreativeLoftMaterials.sky(W.colors(view))]
        let evening = W.isEvening(view)
        parts.moon?.isEnabled = evening && (view.weather == .clear || view.weather == .clouds)
        let sun = W.sun(view, warm: palette.warmLight)
        parts.sunLight?.light.color = NSColor(atlasHex: sun.color)
        parts.sunLight?.light.intensity = palette.sunIntensity * sun.level
        // Fairy lights brighter after dark.
        let bulb = CreativeLoftMaterials.glow(palette.warmLight, intensity: 1.2 * (evening ? 2 : 1))
        for case let light as ModelEntity in parts.bulbs { light.model?.materials = [bulb] }
        guard let room = parts.room else { return }
        let cloudy = view.weather != .clear && view.weather != .fog
        if cloudy && parts.clouds == nil { parts.clouds = CreativeLoftBuilder.buildClouds(into: room) }
        if view.weather == .fog && parts.fog == nil { parts.fog = CreativeLoftBuilder.buildFog(into: room) }
        if view.weather == .rain && parts.rain.isEmpty {
            parts.rain = CreativeLoftBuilder.buildPrecipitation(snow: false, into: room)
            fall(parts.rain, distance: 0.3, duration: 2.2)
        }
        if view.weather == .snow && parts.snow.isEmpty {
            parts.snow = CreativeLoftBuilder.buildPrecipitation(snow: true, into: room)
            fall(parts.snow, distance: 0.45, duration: 7)
        }
        parts.clouds?.isEnabled = cloudy
        if cloudy { parts.clouds?.model?.materials = [CreativeLoftMaterials.translucent(evening ? "#6E6A86" : "#FFFFFF", opacity: 0.85)] }
        parts.fog?.isEnabled = view.weather == .fog
        for group in parts.rain { group.isEnabled = view.weather == .rain }
        for group in parts.snow { group.isEnabled = view.weather == .snow }
    }

    /// Rain or snow slides down and fades, each group on its own loop.
    private func fall(_ groups: [Entity], distance: Float, duration: Double) {
        guard started else { return }
        for (index, group) in groups.enumerated() {
            let time = duration + Double(index) * duration * 0.18
            var low = group.transform
            low.translation.y -= distance
            loop(group, FromToByAnimation<Transform>(from: group.transform, to: low, duration: time, bindTarget: .transform, repeatMode: .repeat))
            if let mesh = group.children.first {
                let steps = [(Float(0), Float(0.85), time * 0.2), (0.85, 0.85, time * 0.6), (0.85, 0, time * 0.2)].compactMap { step in
                    try? AnimationResource.generate(with: FromToByAnimation<Float>(from: step.0, to: step.1, duration: step.2, bindTarget: .opacity))
                }
                if steps.count == 3, let fade = try? AnimationResource.sequence(with: steps) { mesh.playAnimation(fade.repeat()) }
            }
        }
    }

    // MARK: Painter

    private func applyPainter(_ painter: CreativeRoomState.Painter?, previous: CreativeRoomState.Painter?) {
        typealias P = CreativeLoftBuilder.Painter
        let look: (CreativeRoomState.Painter?) -> String = { $0.map { "\($0.style)|\($0.primary)|\($0.secondary)" } ?? "" }
        if look(painter) != look(previous) || (painter != nil && parts.painter == nil) {
            parts.painter?.container.removeFromParent()
            parts.painter = nil
            if let painter, let room = parts.room, let m = parts.materials {
                parts.painter = CreativeLoftBuilder.buildPainter(painter, m, into: room)
                paint()
            }
        }
        guard let painter, let figure = parts.painter else { return }
        let accent = CreativeLoftMaterials.glow(painter.isFocused ? P.focusAccent : P.idleAccent, intensity: 1.2)
        for eye in figure.eyes { eye.model?.materials = [accent] }
        figure.dot.isEnabled = painter.waiting > 0 && !painter.isFocused
        if let previous, painter.bounces > previous.bounces { bounce(figure.body) }
    }

    /// A slow brush stroke about every 10 s.
    private func paint() {
        guard started, let arm = parts.painter?.arm else { return }
        let rest = arm.transform
        var reach = rest
        reach.rotation = simd_quatf(angle: -0.45, axis: [1, 0, 0]) * simd_quatf(angle: 0.25, axis: [0, 0, 1])
        let steps = [
            FromToByAnimation<Transform>(from: rest, to: rest, duration: 8.6, bindTarget: .transform),
            FromToByAnimation<Transform>(from: rest, to: reach, duration: 0.7, timing: .easeInOut, bindTarget: .transform),
            FromToByAnimation<Transform>(from: reach, to: rest, duration: 0.7, timing: .easeInOut, bindTarget: .transform),
        ].compactMap { try? AnimationResource.generate(with: $0) }
        if steps.count == 3, let stroke = try? AnimationResource.sequence(with: steps) { arm.playAnimation(stroke.repeat()) }
    }

    /// One small happy bounce (an export was saved).
    private func bounce(_ body: Entity) {
        guard !reduceMotion else { return }
        let rest = body.transform
        var up = rest
        up.translation.y += 0.06
        let steps = [
            FromToByAnimation<Transform>(from: rest, to: up, duration: 0.18, timing: .easeOut, bindTarget: .transform),
            FromToByAnimation<Transform>(from: up, to: rest, duration: 0.24, timing: .easeIn, bindTarget: .transform),
        ].compactMap { try? AnimationResource.generate(with: $0) }
        if steps.count == 2, let hop = try? AnimationResource.sequence(with: steps) { body.playAnimation(hop) }
    }

    /// The mug drains, then fills back up.
    private func refill(_ coffee: ModelEntity) {
        typealias Mug = CreativeLoftBuilder.Mug
        guard !reduceMotion,
              let fill = try? AnimationResource.generate(with: FromToByAnimation<Transform>(
                  from: Transform(translation: Mug.empty), to: Transform(translation: Mug.full), duration: 1.2, timing: .easeOut,
                  bindTarget: .transform)) else { return }
        coffee.position = Mug.empty
        coffee.playAnimation(fill)
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(1250))
            coffee.position = Mug.full
        }
    }

    /// A picture file as an unlit texture, sized to fit `area` (nil or
    /// unreadable hides the plane, so the room's own art shows).
    static func show(_ path: String?, on plane: ModelEntity, fitting area: SIMD2<Float>) {
        guard let path, let image = NSImage(contentsOfFile: path),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let texture = try? TextureResource(image: cgImage, options: .init(semantic: .color)) else {
            plane.isEnabled = false
            return
        }
        var material = UnlitMaterial()
        material.color = .init(tint: .white, texture: .init(texture))
        plane.model?.materials = [material]
        let aspect = Float(cgImage.width) / Float(max(1, cgImage.height))
        let size = aspect > area.x / area.y ? SIMD2(area.x, area.x / aspect) : SIMD2(area.y * aspect, area.y)
        plane.scale = [size.x, size.y, 1]
        plane.isEnabled = true
    }

    func stop() {
        celebration?.cancel()
    }

    func setActive(_ isActive: Bool, animated: Bool) {
        if isActive, animated { celebrate(baseIntensity: CreativeLoftPalette.current.pendantIntensity) }
    }

    private func loop<Value>(_ entity: Entity, _ animation: FromToByAnimation<Value>) {
        guard let resource = try? AnimationResource.generate(with: animation) else { return }
        entity.playAnimation(resource.repeat())
    }
}
