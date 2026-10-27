import RealityKit

/// The loft's small ambient motions: dust drifting in the sunbeam, fairy
/// lights twinkling, a slow neon pulse and the monitor's colour cross-fade.
/// All of it runs on RealityKit's animation clock (no timers or per-frame
/// code), and none of it starts under Reduce Motion.
@MainActor
final class CreativeLoftMotion {
    let parts: CreativeLoftParts
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

    func stop() {
        celebration?.cancel()
    }

    private func loop<Value>(_ entity: Entity, _ animation: FromToByAnimation<Value>) {
        guard let resource = try? AnimationResource.generate(with: animation) else { return }
        entity.playAnimation(resource.repeat())
    }
}

/// Keeps a loft's motion with its room entity, so Mission Control can find
/// it without tracking loft rooms separately.
struct CreativeLoftMotionComponent: Component {
    let motion: CreativeLoftMotion
}
