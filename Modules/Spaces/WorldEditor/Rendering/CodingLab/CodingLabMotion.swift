import Combine
import RealityKit

/// The night loft's gentle motion: the hologram turning once every 40 s
/// and bobbing, server LEDs blinking softly out of step, lava-lamp blobs
/// rising and falling, a few city windows fading, steam from the mug, a
/// blinking terminal cursor, and new lines of code every few seconds.
/// Activation boots the room: the LED strips sweep on from left to right,
/// the monitors fade in and the hologram grows out of its ring.
///
/// Loops run on RealityKit's animation clock, and the code screens advance
/// on the scene's update events, so nothing runs while the 3D view isn't
/// drawing (hidden, in the background or in Low Power Mode). None of it
/// starts under Reduce Motion.
@MainActor
final class CodingLabMotion: RoomMotion {
    /// Seconds between new lines of code.
    static let codeInterval: Double = 3

    let parts: CodingLabParts
    let reduceMotion: Bool
    private var started = false
    private var boot: Task<Void, Never>?
    private var updates: (any Cancellable)?
    private var sinceLine: Double = 0
    private var ticks = 0

    init(parts: CodingLabParts, reduceMotion: Bool) {
        self.parts = parts
        self.reduceMotion = reduceMotion
    }

    func start() {
        guard !started, !reduceMotion else { return }
        started = true

        if let spin = parts.hologramSpin {
            let steps = (0..<3).compactMap { step -> AnimationResource? in
                let from = Transform(rotation: simd_quatf(angle: Float(step) * 2 * .pi / 3, axis: [0, 1, 0]))
                let to = Transform(rotation: simd_quatf(angle: Float(step + 1) * 2 * .pi / 3, axis: [0, 1, 0]))
                return try? AnimationResource.generate(with: FromToByAnimation<Transform>(from: from, to: to, duration: 40.0 / 3, bindTarget: .transform))
            }
            if steps.count == 3, let turn = try? AnimationResource.sequence(with: steps) {
                spin.playAnimation(turn.repeat())
            }
        }
        if let bob = parts.hologramBob {
            loop(bob, FromToByAnimation<Transform>(from: Transform(translation: [0, -0.025, 0]), to: Transform(translation: [0, 0.025, 0]),
                                                   duration: 3.2, timing: .easeInOut, bindTarget: .transform, repeatMode: .autoReverse))
        }
        for (index, led) in parts.serverLEDs.enumerated() {
            let duration = 0.9 + Double((index * 7) % 6) * 0.28
            loop(led, FromToByAnimation<Float>(from: 1, to: 0.25, duration: duration, timing: .easeInOut, bindTarget: .opacity,
                                               repeatMode: .autoReverse, delay: Double(index) * 0.37))
        }
        for (index, blob) in parts.lavaBlobs.enumerated() {
            var high = blob.transform
            high.translation.y += index == 0 ? 0.11 : -0.09
            high.scale *= 1.15
            loop(blob, FromToByAnimation<Transform>(from: blob.transform, to: high, duration: 6 + Double(index) * 1.7,
                                                    timing: .easeInOut, bindTarget: .transform, repeatMode: .autoReverse))
        }
        for (index, group) in parts.cityFlicker.enumerated() {
            loop(group, FromToByAnimation<Float>(from: 1, to: 0, duration: 7 + Double(index) * 4, timing: .easeInOut,
                                                 bindTarget: .opacity, repeatMode: .autoReverse))
        }
        for (index, puff) in parts.steam.enumerated() {
            let duration = 2.6 + Double(index) * 0.4
            var high = puff.transform
            high.translation += [0.015 * Float(index - 1), 0.13, 0.01]
            high.scale *= 1.6
            loop(puff, FromToByAnimation<Transform>(from: puff.transform, to: high, duration: duration, timing: .easeOut,
                                                    bindTarget: .transform, repeatMode: .repeat))
            if let mesh = puff.children.first {
                let fade = [(Float(0), Float(0.5), duration * 0.3), (0.5, 0, duration * 0.7)].compactMap { step in
                    try? AnimationResource.generate(with: FromToByAnimation<Float>(from: step.0, to: step.1, duration: step.2, bindTarget: .opacity))
                }
                if fade.count == 2, let sequence = try? AnimationResource.sequence(with: fade) {
                    mesh.playAnimation(sequence.repeat())
                }
            }
        }
        if let cursor = parts.cursor {
            loop(cursor, FromToByAnimation<Float>(from: 1, to: 0, duration: 0.55, timing: .easeInOut, bindTarget: .opacity,
                                                  repeatMode: .autoReverse))
        }
    }

    /// New lines of code on the scene's update clock: a check per frame,
    /// a texture redraw every `codeInterval` seconds.
    func attach(to scene: RealityKit.Scene) {
        guard !reduceMotion, !parts.codeScreens.isEmpty else { return }
        updates = scene.subscribe(to: SceneEvents.Update.self) { [weak self] event in
            MainActor.assumeIsolated { self?.tick(event.deltaTime) }
        }
    }

    private func tick(_ deltaTime: Double) {
        sinceLine += deltaTime
        guard sinceLine >= Self.codeInterval else { return }
        sinceLine = 0
        ticks += 1
        parts.codeScreens.first?.advance()
        if ticks.isMultiple(of: 2) { parts.codeScreens.dropFirst().first?.advance() }
    }

    func stop() {
        boot?.cancel()
        updates?.cancel()
        updates = nil
    }

    func setActive(_ isActive: Bool, animated: Bool) {
        guard isActive, animated, !reduceMotion else { return }
        boot?.cancel()
        let parts = self.parts
        boot = Task { @MainActor in
            let duration: Float = 1.6, step: Float = 0.035
            var time: Float = 0
            while time <= duration + step, !Task.isCancelled {
                func ramp(_ start: Float, _ length: Float) -> Float {
                    let t = min(1, max(0, (time - start) / length))
                    return t * t * (3 - 2 * t)
                }
                for (index, segment) in parts.ledSegments.enumerated() {
                    segment.components.set(OpacityComponent(opacity: ramp(Float(index) * 0.15, 0.35)))
                }
                let screens = ramp(0.35, 0.6)
                for screen in parts.screens {
                    screen.components.set(OpacityComponent(opacity: screens))
                }
                parts.monitorGlow?.light.intensity = parts.palette.monitorGlowIntensity * screens
                parts.hologramGrow?.scale = SIMD3(repeating: max(0.02, ramp(0.25, 0.9)))
                try? await Task.sleep(for: .milliseconds(Int(step * 1000)))
                time += step
            }
        }
    }

    private func loop<Value>(_ entity: Entity, _ animation: FromToByAnimation<Value>) {
        guard let resource = try? AnimationResource.generate(with: animation) else { return }
        entity.playAnimation(resource.repeat())
    }
}
