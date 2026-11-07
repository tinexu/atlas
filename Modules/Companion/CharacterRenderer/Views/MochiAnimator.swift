import AppKit
import AtlasCompanion
import AtlasSpaces
import AtlasSpacesUI
import RealityKit

/// Single frames of the idle loop, rendered once each and swapped by Core
/// Animation while Mochi idles (see `MochiFlipbook`).
enum MochiIdleFrame: String, CaseIterable {
    case base, blink, twitch, wiggle
    /// ^ ^ eyes, for the hop when clicked.
    case happy
}

/// Brings Mochi to life in the overlay: the posture from `MochiPose`, then
/// breathing, blinks, ear twitches, hops with squash-and-stretch, the
/// binky, sighs and the little effects (thinking dots, sparkles, z's).
///
/// Everything is a transform eased by RealityKit or a few timers: no
/// physics, nothing per frame from ATLAS. Ears "spring" by trailing the
/// head with a short delay and a small overshoot. `pause()` stops it all.
@MainActor
final class MochiAnimator {
    /// Goes under the scene's turn entity.
    let holder = Entity()
    let figure: MochiFigure
    /// Hops and twists.
    private let hop = Entity()
    /// Squash-and-stretch, pivoting at the feet.
    private let squash = Entity()
    /// Breathing, pivoting at the feet.
    private let breath = Entity()
    private let effects = Entity()
    private var book: Entity?

    private(set) var pose: MochiPose?
    private var reading = false
    private var live: Bool
    private var paused = false
    /// Bumped to cancel every scheduled step.
    private var generation = 0
    private var breathController: AnimationPlaybackController?
    private var dots: [Entity] = []

    /// Scene units per Mochi unit, and where its feet stand in the scene.
    static let scale: Float = 0.95
    static let ground: Float = -0.72

    init(look: MochiLook, accessories: [MochiAccessory], live: Bool) {
        figure = MochiFigure(look: look, accessories: accessories)
        self.live = live
        holder.name = "mochi"
        holder.position = [0, Self.ground, 0]
        holder.scale = SIMD3(repeating: Self.scale)
        holder.addChild(hop)
        hop.addChild(squash)
        squash.addChild(breath)
        breath.addChild(figure.root)
        holder.addChild(effects)
    }

    // MARK: - Pose

    func apply(_ next: MochiPose, reading: Bool) {
        let previous = pose
        pose = next
        let snap = !live || paused || next.motion == .none && !next.effectsMove
        if previous?.posture != next.posture {
            figure.apply(next.posture, duration: snap ? 0 : 0.35)
        }
        if reading != self.reading || book == nil && reading {
            self.reading = reading
            setBook(reading)
        }
        if previous?.effect != next.effect || previous?.effectsMove != next.effectsMove {
            showEffect(next.effect, moving: next.effectsMove && live && !paused)
        }
        let loopsChanged = previous.map {
            $0.motion != next.motion || $0.breathPeriod != next.breathPeriod || $0.blinks != next.blinks
                || $0.earTwitch != next.earTwitch || $0.noseWiggle != next.noseWiggle
        } ?? true
        let startedHovering = next.lookAt != nil && previous?.lookAt == nil
        if loopsChanged { restartLoops() }
        if startedHovering, live, !paused, next.noseWiggle { wiggleNose() }
    }

    /// A still frame for the idle flipbook (snapshots only).
    func showFrame(_ frame: MochiIdleFrame) {
        guard let pose else { return }
        figure.apply(pose.posture)
        switch frame {
        case .base:
            break
        case .blink:
            figure.nudge(.eyes, scale: [1, 0.1, 1], duration: 0)
        case .twitch:
            figure.nudge(MochiRig.uprightEar(figure.model.floppyEar).tip, rotation: MochiMath.rx(-0.45), duration: 0)
            figure.nudge(MochiRig.uprightEar(figure.model.floppyEar).base, rotation: MochiMath.rx(-0.12), duration: 0)
        case .wiggle:
            figure.nudge(.nose, translation: [0, 0.007, 0], scale: [1.08, 0.92, 1], duration: 0)
        case .happy:
            figure.setEyes(.happy)
        }
    }

    func pause() {
        guard !paused else { return }
        paused = true
        generation += 1
        breathController?.pause()
        effects.children.forEach { $0.stopAllAnimations() }
    }

    func resume() {
        guard paused else { return }
        paused = false
        breathController?.resume()
        if let pose {
            showEffect(pose.effect, moving: pose.effectsMove && live)
            restartLoops()
        }
    }

    // MARK: - Loops

    private func restartLoops() {
        generation += 1
        breathController?.stop()
        breathController = nil
        breath.transform = .identity
        hop.transform = .identity
        squash.transform = .identity
        guard live, !paused, let pose else { return }
        if pose.breathPeriod > 0 {
            let full = Transform(scale: [1 + MochiPose.breath * 0.5, 1 + MochiPose.breath, 1 + MochiPose.breath * 0.5])
            if let resource = try? AnimationResource.generate(with: FromToByAnimation<Transform>(
                from: .identity, to: full, duration: pose.breathPeriod / 2, timing: .easeInOut, bindTarget: .transform,
                repeatMode: .autoReverse)) {
                breathController = breath.playAnimation(resource)
            }
        }
        if pose.blinks { scheduleBlink() }
        if pose.earTwitch { scheduleTwitch() }
        if pose.noseWiggle { scheduleWiggle() }
        switch pose.motion {
        case .none, .idle: break
        case .hops: hopLoop()
        case .binky: binky()
        case .sigh: sigh()
        case .happyHop: jump(height: 0.32, rise: 0.2)
        }
    }

    /// Runs `work` after `seconds` unless loops restarted or paused since.
    private func after(_ seconds: Double, _ work: @escaping @MainActor () -> Void) {
        let token = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.generation == token, !self.paused else { return }
                work()
            }
        }
    }

    private func scheduleBlink() {
        after(Double.random(in: 3...6)) { [weak self] in
            guard let self else { return }
            self.blink()
            self.scheduleBlink()
        }
    }

    /// Eyes squeeze shut vertically for 120 ms.
    private func blink() {
        figure.nudge(.eyes, scale: [1, 0.1, 1], duration: 0.05)
        after(0.12) { [weak self] in self?.figure.settle(.eyes, duration: 0.06) }
    }

    private func scheduleTwitch() {
        after(Double.random(in: 8...15)) { [weak self] in
            guard let self else { return }
            let ear = MochiRig.uprightEar(self.figure.model.floppyEar)
            self.figure.nudge(ear.tip, rotation: MochiMath.rx(-0.45), duration: 0.08)
            self.figure.nudge(ear.base, rotation: MochiMath.rx(-0.12), duration: 0.08)
            self.after(0.1) { [weak self] in
                self?.figure.settle(ear.tip, duration: 0.18)
                self?.figure.settle(ear.base, duration: 0.18)
            }
            self.scheduleTwitch()
        }
    }

    private func scheduleWiggle() {
        after(Double.random(in: 7...16)) { [weak self] in
            self?.wiggleNose()
            self?.scheduleWiggle()
        }
    }

    /// A tiny up-and-down for 400 ms.
    private func wiggleNose() {
        let steps: [Float] = [0.006, 0, 0.005, 0]
        for (index, y) in steps.enumerated() {
            after(Double(index) * 0.1) { [weak self] in
                self?.figure.nudge(.nose, translation: [0, y, 0], scale: y > 0 ? [1.06, 0.94, 1] : .one, duration: 0.09)
            }
        }
    }

    // MARK: - Hops

    /// Hops in place, one every 0.6 s.
    private func hopLoop() {
        jump(height: MochiPose.hopHeight, rise: 0.2)
        after(MochiPose.hopInterval) { [weak self] in self?.hopLoop() }
    }

    /// One hop: up (ease-out), down (ease-in), squash on landing with a
    /// quick recovery. The ears trail the head and overshoot; the feet
    /// tip up in the air so the pink pads show.
    private func jump(height: Float, rise: Double, twist: Float = 0, onApex: (() -> Void)? = nil) {
        let up = Transform(rotation: MochiMath.ry(twist) * MochiMath.rz(twist * 0.25), translation: [0, height, 0])
        hop.move(to: up, relativeTo: holder, duration: rise, timingFunction: .easeOut)
        springEars(lag: rise)
        figure.nudge(.feet, rotation: MochiMath.rx(-0.9), duration: rise * 0.6)
        after(rise) { [weak self] in
            guard let self else { return }
            onApex?()
            self.hop.move(to: .identity, relativeTo: self.holder, duration: rise * 0.95, timingFunction: .easeIn)
            self.after(rise * 0.95) { [weak self] in
                guard let self else { return }
                self.land()
                self.figure.settle(.feet, duration: 0.1)
            }
        }
    }

    private func land() {
        let s = MochiPose.squash
        squash.move(to: Transform(scale: [1 + s * 0.5, 1 - s, 1 + s * 0.5]), relativeTo: hop, duration: 0.05, timingFunction: .easeOut)
        after(0.06) { [weak self] in
            guard let self else { return }
            self.squash.move(to: .identity, relativeTo: self.hop, duration: 0.12, timingFunction: .easeInOut)
        }
    }

    /// Spring follow: tips lag down while rising, flick up past rest, settle.
    private func springEars(lag: Double) {
        let ears = [MochiJoint.earLeftTip, .earRightTip]
        for ear in ears { figure.nudge(ear, rotation: MochiMath.rx(-0.32), duration: lag * 0.7) }
        after(lag * 0.8) { [weak self] in
            for ear in ears { self?.figure.nudge(ear, rotation: MochiMath.rx(0.18), duration: lag * 0.7) }
        }
        after(lag * 1.6) { [weak self] in
            for ear in ears { self?.figure.settle(ear, duration: lag * 0.8) }
        }
    }

    /// The binky: a little crouch, one higher hop with a mid-air twist,
    /// a sparkle burst at the top.
    private func binky() {
        let s = MochiPose.squash
        squash.move(to: Transform(scale: [1 + s * 0.4, 1 - s * 0.8, 1 + s * 0.4]), relativeTo: hop, duration: 0.1, timingFunction: .easeOut)
        after(0.11) { [weak self] in
            guard let self else { return }
            self.squash.move(to: Transform(scale: [0.97, 1.05, 0.97]), relativeTo: self.hop, duration: 0.1, timingFunction: .easeOut)
            self.jump(height: MochiPose.binkyHeight, rise: 0.28, twist: 0.55) { [weak self] in
                guard let self else { return }
                self.squash.move(to: .identity, relativeTo: self.hop, duration: 0.1, timingFunction: .easeInOut)
                self.burst()
            }
        }
    }

    /// A slow sigh: the body squashes a little and recovers.
    private func sigh() {
        squash.move(to: Transform(scale: [1.035, 0.94, 1.035]), relativeTo: hop, duration: 0.55, timingFunction: .easeInOut)
        after(0.9) { [weak self] in
            guard let self else { return }
            self.squash.move(to: .identity, relativeTo: self.hop, duration: 0.5, timingFunction: .easeInOut)
        }
    }

    // MARK: - Effects

    private func showEffect(_ effect: MochiPose.Effect, moving: Bool) {
        effects.children.forEach { $0.removeFromParent() }
        dots = []
        switch effect {
        case .none, .sparkles:
            break   // Sparkles burst from `binky`.
        case .thinkingDots:
            let material = UnlitMaterial(color: NSColor(srgbRed: 0.79, green: 0.71, blue: 0.95, alpha: 1))
            for index in 0..<3 {
                let dot = ModelEntity(mesh: .generateSphere(radius: 0.035), materials: [material])
                dot.position = [-0.1 + Float(index) * 0.1, 1.42 + (index == 1 ? 0.04 : 0), 0.05]
                effects.addChild(dot)
                dots.append(dot)
            }
            if moving { pulseDots() }
        case .zzz:
            let material = UnlitMaterial(color: NSColor(srgbRed: 0.72, green: 0.68, blue: 0.9, alpha: 1))
            for index in 0..<3 {
                let mesh = MeshResource.generateText("z", extrusionDepth: 0.005, font: .systemFont(ofSize: 0.09 + CGFloat(index) * 0.03, weight: .bold))
                let z = ModelEntity(mesh: mesh, materials: [material])
                let rest = SIMD3<Float>(0.28 + Float(index) * 0.1, 1.05 + Float(index) * 0.13, 0.05)
                z.position = rest
                effects.addChild(z)
                if moving { drift(z, from: rest, delay: Double(index)) }
            }
        }
    }

    /// The three dots swell one by one.
    private func pulseDots() {
        for (index, dot) in dots.enumerated() {
            let rest = dot.transform
            var big = rest
            big.scale = SIMD3(repeating: 1.6)
            let steps = [
                FromToByAnimation<Transform>(from: rest, to: rest, duration: 0.3 * Double(index) + 0.001, bindTarget: .transform),
                FromToByAnimation<Transform>(from: rest, to: big, duration: 0.15, timing: .easeOut, bindTarget: .transform),
                FromToByAnimation<Transform>(from: big, to: rest, duration: 0.15, timing: .easeIn, bindTarget: .transform),
                FromToByAnimation<Transform>(from: rest, to: rest, duration: 0.3 * Double(2 - index) + 0.001, bindTarget: .transform),
            ].compactMap { try? AnimationResource.generate(with: $0) }
            if steps.count == 4, let cycle = try? AnimationResource.sequence(with: steps) { dot.playAnimation(cycle.repeat()) }
        }
    }

    /// A slow "z" floating up, fading in and out.
    private func drift(_ z: Entity, from rest: SIMD3<Float>, delay: Double) {
        let start = Transform(scale: SIMD3(repeating: 0.6), translation: rest - [0.04, 0.08, 0])
        let end = Transform(scale: SIMD3(repeating: 1.1), translation: rest + [0.05, 0.1, 0])
        let steps = [
            FromToByAnimation<Transform>(from: start, to: start, duration: delay + 0.001, bindTarget: .transform),
            FromToByAnimation<Transform>(from: start, to: end, duration: 3, timing: .easeOut, bindTarget: .transform),
        ].compactMap { try? AnimationResource.generate(with: $0) }
        if steps.count == 2, let cycle = try? AnimationResource.sequence(with: steps) { z.playAnimation(cycle.repeat()) }
        let fade = [
            FromToByAnimation<Float>(from: 0, to: 0, duration: delay + 0.001, bindTarget: .opacity),
            FromToByAnimation<Float>(from: 0, to: 0.9, duration: 0.8, bindTarget: .opacity),
            FromToByAnimation<Float>(from: 0.9, to: 0, duration: 2.2, timing: .easeIn, bindTarget: .opacity),
        ].compactMap { try? AnimationResource.generate(with: $0) }
        z.components.set(OpacityComponent(opacity: 0))
        if fade.count == 3, let cycle = try? AnimationResource.sequence(with: fade) { z.playAnimation(cycle.repeat()) }
    }

    /// 7 tiny emissive stars, pink and white, flying out and fading.
    private func burst() {
        guard live, !paused else { return }
        let colors = [NSColor.white, NSColor(srgbRed: 1, green: 0.62, blue: 0.74, alpha: 1)]
        var stars: [Entity] = []
        for index in 0..<7 {
            var material = PhysicallyBasedMaterial()
            let color = colors[index % 2]
            material.baseColor = .init(tint: color)
            material.emissiveColor = .init(color: color)
            material.emissiveIntensity = 2
            let star = Entity()
            for angle: Float in [0, .pi / 2] {
                let ray = ModelEntity(mesh: Self.starRay, materials: [material])
                ray.orientation = MochiMath.rz(angle + .pi / 4)
                star.addChild(ray)
            }
            let a = Float(index) / 7 * 2 * .pi + 0.3
            let centre = SIMD3<Float>(0, 0.75, 0.15)
            star.position = centre
            star.scale = SIMD3(repeating: 0.2)
            effects.addChild(star)
            stars.append(star)
            let out = Transform(scale: .one, rotation: MochiMath.rz(a), translation: centre + SIMD3(cos(a) * 0.7, sin(a) * 0.55 + 0.1, 0.1))
            star.move(to: out, relativeTo: effects, duration: 0.45, timingFunction: .easeOut)
        }
        after(0.5) { [weak self] in
            guard let self else { return }
            for star in stars {
                var gone = star.transform
                gone.scale = SIMD3(repeating: 0.01)
                gone.translation.y += 0.1
                star.move(to: gone, relativeTo: self.effects, duration: 0.5, timingFunction: .easeIn)
            }
            self.after(0.55) { stars.forEach { $0.removeFromParent() } }
        }
    }

    private static let starRay: MeshResource = .generateBox(width: 0.02, height: 0.11, depth: 0.01, cornerRadius: 0.008)

    // MARK: - Reading

    /// A tiny open book held in both paws (a study session's focus).
    private func setBook(_ reading: Bool) {
        book?.removeFromParent()
        book = nil
        guard reading else { return }
        let book = Entity()
        let cover = SimpleMaterial(color: NSColor(srgbRed: 0.49, green: 0.23, blue: 0.27, alpha: 1), roughness: 0.6, isMetallic: false)
        let paper = SimpleMaterial(color: NSColor(white: 0.97, alpha: 1), roughness: 0.9, isMetallic: false)
        book.addChild(ModelEntity(mesh: .generateBox(width: 0.3, height: 0.012, depth: 0.2, cornerRadius: 0.004), materials: [cover]))
        for x: Float in [-0.072, 0.072] {
            let page = ModelEntity(mesh: .generateBox(width: 0.136, height: 0.02, depth: 0.184), materials: [paper])
            page.position = [x, 0.014, 0]
            page.orientation = MochiMath.rz(x < 0 ? 0.07 : -0.07)
            book.addChild(page)
        }
        book.position = [0, 0.2, 0.3]
        book.orientation = MochiMath.rx(1.0)
        breath.addChild(book)
        self.book = book
    }
}
