import RealityKit

/// The reading room's gentle motion: rain sliding down the window, the
/// candle flickering, the globe turning once a minute and steam rising from
/// the mug. Activation fades the banker's lamp up, turns the open book's
/// page and brightens the chandelier. Loops run on RealityKit's animation
/// clock; none of them start under Reduce Motion, where activation only
/// switches the lamp and chandelier without animating.
@MainActor
final class StudyLibraryMotion: RoomMotion {
    let parts: StudyLibraryParts
    let reduceMotion: Bool
    private var started = false
    private var fade: Task<Void, Never>?
    private var lampLevel: Float = 0

    init(parts: StudyLibraryParts, reduceMotion: Bool) {
        self.parts = parts
        self.reduceMotion = reduceMotion
    }

    func start() {
        guard !started, !reduceMotion else { return }
        started = true

        for (index, group) in parts.rain.enumerated() {
            let duration = 2.2 + Double((index * 5) % 6) * 0.25
            var low = group.transform
            low.translation.y -= 0.3
            loop(group, FromToByAnimation<Transform>(from: group.transform, to: low, duration: duration, bindTarget: .transform,
                                                     repeatMode: .repeat))
            if let streaks = group.children.first {
                sequence(streaks, [(0, 0.8, duration * 0.25), (0.8, 0.8, duration * 0.5), (0.8, 0, duration * 0.25)])
            }
        }
        for (index, puff) in parts.steam.enumerated() {
            let duration = 2.6 + Double(index) * 0.4
            var high = puff.transform
            high.translation += [0.015 * Float(index - 1), 0.13, 0.01]
            high.scale *= 1.6
            loop(puff, FromToByAnimation<Transform>(from: puff.transform, to: high, duration: duration, timing: .easeOut,
                                                    bindTarget: .transform, repeatMode: .repeat))
            if let mesh = puff.children.first {
                sequence(mesh, [(0, 0.5, duration * 0.3), (0.5, 0, duration * 0.7)])
            }
        }
        if let flame = parts.flame {
            var tall = flame.transform
            tall.scale = [0.92, 1.14, 0.92]
            loop(flame, FromToByAnimation<Transform>(from: flame.transform, to: tall, duration: 0.35, timing: .easeInOut,
                                                     bindTarget: .transform, repeatMode: .autoReverse))
            if let glow = flame.children.first {
                loop(glow, FromToByAnimation<Float>(from: 1, to: 0.78, duration: 0.23, timing: .easeInOut,
                                                    bindTarget: .opacity, repeatMode: .autoReverse))
            }
        }
        if let globe = parts.globe {
            // One turn a minute, in three 120° steps so each is unambiguous.
            let steps = (0..<3).compactMap { step -> AnimationResource? in
                let from = Transform(rotation: simd_quatf(angle: Float(step) * 2 * .pi / 3, axis: [0, 1, 0]))
                let to = Transform(rotation: simd_quatf(angle: Float(step + 1) * 2 * .pi / 3, axis: [0, 1, 0]))
                return try? AnimationResource.generate(with: FromToByAnimation<Transform>(from: from, to: to, duration: 20, bindTarget: .transform))
            }
            if steps.count == 3, let turn = try? AnimationResource.sequence(with: steps) {
                globe.playAnimation(turn.repeat())
            }
        }
    }

    func stop() {
        fade?.cancel()
    }

    func setActive(_ isActive: Bool, animated: Bool) {
        let target: Float = isActive ? 1 : parts.palette.bankerLampIdle
        let animate = animated && !reduceMotion
        setChandelier(bright: isActive)
        fade?.cancel()
        if animate {
            let start = lampLevel
            fade = Task { @MainActor [weak self] in
                // A soft half-second fade.
                for step in 1...15 {
                    try? await Task.sleep(for: .milliseconds(35))
                    guard let self, !Task.isCancelled else { return }
                    let t = Float(step) / 15
                    self.setLamp(start + (target - start) * (t * t * (3 - 2 * t)))
                }
            }
            if isActive { turnPage() }
        } else {
            setLamp(target)
        }
    }

    private func setLamp(_ level: Float) {
        lampLevel = level
        parts.bankerLight?.light.intensity = parts.palette.bankerLampIntensity * level
        parts.lampGlow?.model?.materials = [StudyLibraryMaterials.emissive(parts.palette.lampGlow,
                                                                           intensity: parts.palette.lampGlowIntensity * max(level, 0.12))]
    }

    private func setChandelier(bright: Bool) {
        let palette = parts.palette
        parts.chandelier?.model?.materials = [StudyLibraryMaterials.emissive(
            palette.lampGlow, intensity: palette.bulbIntensity * (bright ? palette.chandelierActiveBoost : 1))]
    }

    /// The open book's top page turns over once, around the spine.
    private func turnPage() {
        guard let page = parts.page else { return }
        var open = page.transform
        open.rotation = simd_quatf(angle: StudyLibraryBuilder.Book.pageTilt, axis: [0, 0, 1])
        var turned = open
        turned.rotation = simd_quatf(angle: .pi - StudyLibraryBuilder.Book.pageTilt, axis: [0, 0, 1])
        page.transform = open
        guard let resource = try? AnimationResource.generate(with: FromToByAnimation<Transform>(
            from: open, to: turned, duration: 1.4, timing: .easeInOut, bindTarget: .transform, fillMode: .forwards
        )) else { return }
        page.playAnimation(resource)
    }

    private func loop<Value>(_ entity: Entity, _ animation: FromToByAnimation<Value>) {
        guard let resource = try? AnimationResource.generate(with: animation) else { return }
        entity.playAnimation(resource.repeat())
    }

    /// Opacity through `(from, to, duration)` steps, repeating.
    private func sequence(_ entity: Entity, _ steps: [(Float, Float, Double)]) {
        let resources = steps.compactMap { step in
            try? AnimationResource.generate(with: FromToByAnimation<Float>(from: step.0, to: step.1, duration: step.2, bindTarget: .opacity))
        }
        guard resources.count == steps.count, let combined = try? AnimationResource.sequence(with: resources) else { return }
        entity.playAnimation(combined.repeat())
    }
}
