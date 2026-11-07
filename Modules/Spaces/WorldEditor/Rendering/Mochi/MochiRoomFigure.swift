import AppKit
import AtlasSpaces
import RealityKit

/// Mochi as a small figure in a room (window seat, easel, desk corner):
/// the shared `MochiFigure` at room detail, plus its quiet room motion.
/// Breathing and the head bob loop on RealityKit's animation clock, so they
/// stop with the 3D view; the occasional popcorn bite is a slow timer.
/// Nothing starts under Reduce Motion.
@MainActor
final class MochiRoomFigure {
    let container = Entity()
    let figure: MochiFigure
    private let breath = Entity()
    private var eating: Task<Void, Never>?
    private var bobbing = false

    init(look: MochiLook, accessories: [MochiAccessory], height: Float) {
        figure = MochiFigure(look: look, accessories: accessories, detail: .room)
        container.scale = SIMD3(repeating: height)
        container.addChild(breath)
        breath.addChild(figure.root)
    }

    func pose(_ posture: MochiPosture) {
        figure.apply(posture)
        if bobbing { startBob() }
    }

    /// Slow breathing: a 2% swell from the feet.
    func breathe(period: Double) {
        breath.stopAllAnimations()
        breath.transform = .identity
        guard period > 0, let resource = try? AnimationResource.generate(with: FromToByAnimation<Transform>(
            from: .identity, to: Transform(scale: [1.01, 1.02, 1.01]), duration: period / 2, timing: .easeInOut,
            bindTarget: .transform, repeatMode: .autoReverse)) else { return }
        breath.playAnimation(resource)
    }

    /// Bobbing its head slowly, as if listening to music.
    func setBob(_ on: Bool) {
        bobbing = on
        if on { startBob() } else { stopBob() }
    }

    private func startBob() {
        guard let head = figure[.head], let rest = figure.posed[.head] else { return }
        head.stopAllAnimations()
        var down = rest
        down.rotation = rest.rotation * MochiMath.rx(0.09) * MochiMath.rz(0.03)
        var up = rest
        up.rotation = rest.rotation * MochiMath.rx(-0.03) * MochiMath.rz(-0.03)
        if let resource = try? AnimationResource.generate(with: FromToByAnimation<Transform>(
            from: up, to: down, duration: 0.9, timing: .easeInOut, bindTarget: .transform, repeatMode: .autoReverse)) {
            head.playAnimation(resource)
        }
    }

    private func stopBob() {
        figure[.head]?.stopAllAnimations()
        if let rest = figure.posed[.head] { figure[.head]?.transform = rest }
    }

    /// Now and then: a paw to its mouth and puffed cheeks (Watch mode).
    func setEating(_ on: Bool, base: MochiPosture) {
        eating?.cancel()
        eating = nil
        guard on else { return }
        eating = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Double.random(in: 9...16)))
                guard !Task.isCancelled, let self else { return }
                var bite = base
                bite.paws = .toMouth
                bite.cheeksPuffed = true
                bite.mouth = .open
                self.figure.apply(bite, duration: 0.3)
                try? await Task.sleep(for: .seconds(1.3))
                guard !Task.isCancelled else { return }
                self.figure.apply(base, duration: 0.35)
            }
        }
    }

    func stop() {
        eating?.cancel()
        eating = nil
        breath.stopAllAnimations()
        figure[.head]?.stopAllAnimations()
    }
}
