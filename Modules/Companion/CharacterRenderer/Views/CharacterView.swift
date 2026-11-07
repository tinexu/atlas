import AppKit
import AtlasCompanion
import AtlasSpaces
import Metal
import QuartzCore
import RealityKit
import SwiftUI

/// Draws the character.
///
/// A live RealityKit view redraws every frame (about two-thirds of a CPU
/// core even when nothing moves), so it's only on screen while the
/// character is doing something (`live`). The rest of the time it shows a
/// still image of the same 3D model, rendered once off-screen and cached.
/// Mochi idles as a flipbook of a few such images (open, blink, ear
/// twitch, nose wiggle) swapped and gently scaled by Core Animation, which
/// runs in the window server, so breathing and blinking cost ATLAS nothing.
/// "Still" mode, a locked screen, Low Power Mode or a hidden overlay show
/// a still picture.
public struct CharacterView: View {
    let settings: CompanionSettings
    let presentation: CharacterPresentation
    let paused: Bool
    let live: Bool
    let accessories: [MochiAccessory]
    /// The cursor over the overlay (-1…1, y up): Mochi's picture leans towards it.
    let hover: SIMD2<Float>?
    /// A click: Mochi's picture does a happy hop.
    let petted: Bool
    /// A task checked off: a hop with sparkles (a binky for the last one).
    let celebration: MochiCelebration?
    @State private var scene = CharacterScene()
    @State private var snapshot: NSImage?
    @State private var frames: [MochiIdleFrame: NSImage] = [:]

    /// `accessories`: what Mochi wears here (the other characters ignore it).
    public init(settings: CompanionSettings, presentation: CharacterPresentation, paused: Bool, live: Bool = true,
                accessories: [MochiAccessory] = [], hover: SIMD2<Float>? = nil, petted: Bool = false,
                celebration: MochiCelebration? = nil) {
        self.settings = settings
        self.presentation = presentation
        self.paused = paused
        self.live = live
        self.accessories = accessories
        self.hover = hover
        self.petted = petted
        self.celebration = celebration
    }

    private var isMochi: Bool { CharacterSource.from(settings) == .procedural(.mochi) }

    public var body: some View {
        if isMochi {
            mochiBody
        } else if presentation.rendering == .staticImage || paused {
            CharacterStill(settings: settings, presentation: presentation)
        } else if live {
            realityView
        } else {
            Group {
                if let snapshot {
                    Image(nsImage: snapshot).resizable().interpolation(.high).opacity(presentation.opacity)
                } else {
                    CharacterStill(settings: settings, presentation: presentation)
                }
            }
            .task(id: CharacterSnapshotter.key(settings, presentation, accessories: accessories)) {
                snapshot = await CharacterSnapshotter.shared.image(settings: settings, presentation: presentation, accessories: accessories)
            }
        }
    }

    private var realityView: some View {
        RealityView { content in
            content.camera = .virtual
            scene.root.removeFromParent()
            content.add(scene.root)
            scene.build(settings, accessories: accessories)
            scene.apply(presentation)
            scene.resume()
        } update: { _ in
            scene.build(settings, accessories: accessories)
            scene.apply(presentation)
        }
        .onDisappear { scene.pause() }
    }

    @ViewBuilder
    private var mochiBody: some View {
        let still = presentation.rendering == .staticImage || paused
        if live && !still {
            realityView
        } else {
            Group {
                if let base = frames[.base] {
                    MochiFlipbook(frames: frames, pose: presentation.mochi, animate: !still,
                                  lookAt: hover, petted: petted, celebration: celebration)
                        .opacity(presentation.opacity)
                        .id(ObjectIdentifier(base))
                } else {
                    CharacterStill(settings: settings, presentation: presentation)
                }
            }
            .task(id: CharacterSnapshotter.key(settings, presentation, accessories: accessories) + "|\(still)") {
                scene.pause()
                // Still and paused need one picture; the idle loop needs all four.
                let wanted: [MochiIdleFrame] = still ? [.base] : MochiIdleFrame.allCases
                var images: [MochiIdleFrame: NSImage] = [:]
                for frame in wanted {
                    if let image = await CharacterSnapshotter.shared.image(settings: settings, presentation: presentation,
                                                                           accessories: accessories, frame: frame) {
                        images[frame] = image
                    }
                }
                if !images.isEmpty { frames = images }
            }
        }
    }
}

/// Renders the 3D character to an image once per look (RealityRenderer,
/// off-screen), so an idle character costs nothing to keep on screen.
@MainActor
final class CharacterSnapshotter {
    static let shared = CharacterSnapshotter()
    static let pixels = 320

    private var cache: [String: NSImage] = [:]
    private var renderer: RealityRenderer?
    private let scene = CharacterScene(live: false)
    private let device = MTLCreateSystemDefaultDevice()
    /// One render at a time: the scene is shared.
    private var queue: Task<Void, Never>?

    static func key(_ settings: CompanionSettings, _ presentation: CharacterPresentation, accessories: [MochiAccessory] = []) -> String {
        if CharacterSource.from(settings) == .procedural(.mochi) {
            return "mochi|\(settings.mochi.look.key)|\(accessories.map(\.rawValue).joined(separator: ","))|\(presentation.mochi.posture)|\(presentation.isReading)"
        }
        return "\(settings.character.rawValue)|\(settings.primaryColor)|\(settings.secondaryColor)|\(settings.accessory.rawValue)|\(settings.customCharacterPath ?? "")|\(presentation.accent)|\(presentation.eyesClosed)|\(presentation.isReading)"
    }

    func image(settings: CompanionSettings, presentation: CharacterPresentation, accessories: [MochiAccessory] = [],
               frame: MochiIdleFrame = .base) async -> NSImage? {
        let key = Self.key(settings, presentation, accessories: accessories) + "|\(frame.rawValue)"
        if let cached = cache[key] { return cached }
        let previous = queue
        let task = Task { @MainActor [weak self] () -> NSImage? in
            await previous?.value
            guard let self else { return nil }
            if let cached = self.cache[key] { return cached }
            let image = await self.render(settings: settings, presentation: presentation, accessories: accessories, frame: frame)
            if let image {
                if self.cache.count > 60 { self.cache.removeAll() }
                self.cache[key] = image
            }
            return image
        }
        queue = Task { _ = await task.value }
        return await task.value
    }

    private func render(settings: CompanionSettings, presentation: CharacterPresentation, accessories: [MochiAccessory],
                        frame: MochiIdleFrame) async -> NSImage? {
        guard let device else { return nil }
        do {
            let renderer = try self.renderer ?? RealityRenderer()
            self.renderer = renderer
            var still = presentation
            still.bobAmplitude = 0
            still.spinSpeed = 0
            still.gesture = .none
            still.opacity = 1
            // The flipbook draws the z's itself; nothing else moves in a still.
            still.mochi.effect = .none
            still.mochi.motion = .none
            scene.build(settings, accessories: accessories)
            scene.apply(still)
            scene.showIdleFrame(frame)
            if renderer.entities.isEmpty { renderer.entities.append(scene.root) }
            renderer.activeCamera = scene.camera
            renderer.cameraSettings.colorBackground = .color(CGColor(gray: 0, alpha: 0))

            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm_srgb, width: Self.pixels, height: Self.pixels, mipmapped: false)
            descriptor.usage = [.renderTarget, .shaderRead]
            descriptor.storageMode = .shared
            guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
            let output = try RealityRenderer.CameraOutput(.singleProjection(colorTexture: texture))
            // A couple of frames so meshes and materials are uploaded.
            for _ in 0..<3 {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    do {
                        try renderer.updateAndRender(deltaTime: 1 / 60, cameraOutput: output, onComplete: { _ in continuation.resume() })
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
            return Self.image(from: texture)
        } catch {
            return nil
        }
    }

    private static func image(from texture: MTLTexture) -> NSImage? {
        let width = texture.width, height = texture.height, rowBytes = width * 4
        var bytes = [UInt8](repeating: 0, count: rowBytes * height)
        texture.getBytes(&bytes, bytesPerRow: rowBytes, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let cgImage = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: rowBytes,
                                    space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                    bitmapInfo: CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue),
                                    provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: width / 2, height: height / 2))
    }
}

// MARK: - Mochi's idle flipbook

/// A task was checked off: Mochi hops with sparkles (`big`: the last task, a binky).
public struct MochiCelebration: Equatable, Sendable {
    public let id: UUID
    public let big: Bool

    public init(id: UUID = UUID(), big: Bool) {
        self.id = id
        self.big = big
    }
}

/// Mochi idling from pre-rendered frames: breathing (a slow scale from the
/// feet), random blinks every 3–6 s, an ear twitch every 8–15 s and an
/// occasional nose wiggle, plus drifting z's when asleep. All of it is one
/// Core Animation timeline built when the pose changes, so ATLAS does no
/// work while Mochi idles.
struct MochiFlipbook: NSViewRepresentable {
    let frames: [MochiIdleFrame: NSImage]
    let pose: MochiPose
    let animate: Bool
    var lookAt: SIMD2<Float>? = nil
    var petted = false
    var celebration: MochiCelebration?

    func makeNSView(context: Context) -> FlipbookView { FlipbookView() }

    func updateNSView(_ view: FlipbookView, context: Context) {
        view.configure(frames: frames, pose: pose, animate: animate)
        // Motion only with full animation (Reduced/Reduce Motion: the face changes, nothing moves).
        let moves = animate && pose.breathPeriod > 0 && pose.effectsMove
        view.lean(towards: moves ? lookAt : nil)
        view.setPetted(petted, hop: moves, happy: frames[.happy] ?? frames[.base])
        view.celebrate(celebration, moves: moves, happy: frames[.happy] ?? frames[.base])
    }

    /// Where Mochi's feet are in the picture, from the bottom (the breathing pivot).
    static let feet: CGFloat = 0.15
    /// One timeline of blinks and twitches, repeated.
    static let cycle: Double = 60

    /// The timeline's frames and the times they start (0…1, one more time
    /// than frames, as discrete key frames want).
    static func timeline(_ pose: MochiPose, seed: UInt64 = 7) -> (frames: [MochiIdleFrame], times: [Double]) {
        var random = SplitMix(seed: seed)
        var events: [(start: Double, frames: [(MochiIdleFrame, Double)])] = []
        func schedule(_ range: ClosedRange<Double>, _ frames: [(MochiIdleFrame, Double)]) {
            var t = random.next(in: range)
            while t < cycle - 1 {
                events.append((t, frames))
                t += random.next(in: range)
            }
        }
        if pose.blinks { schedule(3...6, [(.blink, 0.12)]) }
        if pose.earTwitch { schedule(8...15, [(.twitch, 0.22)]) }
        if pose.noseWiggle { schedule(9...18, [(.wiggle, 0.1), (.base, 0.1), (.wiggle, 0.1)]) }
        events.sort { $0.start < $1.start }
        var frames: [MochiIdleFrame] = [.base], times: [Double] = [0]
        var end = 0.0
        for event in events where event.start > end + 0.05 {
            var t = event.start
            for (frame, length) in event.frames {
                frames.append(frame)
                times.append(t / cycle)
                t += length
            }
            frames.append(.base)
            times.append(t / cycle)
            end = t
        }
        times.append(1)
        return (frames, times)
    }

    final class FlipbookView: NSView {
        /// Hops (click), pivoting at the feet.
        private let hop = CALayer()
        /// Leans towards the cursor, pivoting at the feet.
        private let tilt = CALayer()
        private let image = CALayer()
        /// The ^ ^ face, shown during a hop.
        private let happy = CALayer()
        private var zs: [CATextLayer] = []
        private var configured: String?
        private var wasPetted = false

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            for sub in [hop, tilt, image, happy] {
                sub.anchorPoint = CGPoint(x: 0.5, y: MochiFlipbook.feet)
            }
            image.contentsGravity = .resizeAspect
            happy.contentsGravity = .resizeAspect
            happy.opacity = 0
            layer?.addSublayer(hop)
            hop.addSublayer(tilt)
            tilt.addSublayer(image)
            tilt.addSublayer(happy)
        }

        /// Leans a little towards the cursor (nil: upright again).
        func lean(towards point: SIMD2<Float>?) {
            let x = CGFloat(point?.x ?? 0), y = CGFloat(point?.y ?? 0)
            var t = CATransform3DMakeRotation(-x * 0.12, 0, 0, 1)
            t = CATransform3DTranslate(t, x * bounds.width * 0.03, y * bounds.height * 0.015, 0)
            CATransaction.begin()
            CATransaction.setAnimationDuration(0.25)
            tilt.transform = t
            CATransaction.commit()
        }

        /// On a click: a happy hop with ^ ^ eyes (or just the face, without motion).
        func setPetted(_ petted: Bool, hop moves: Bool, happy image: NSImage?) {
            defer { wasPetted = petted }
            guard petted, !wasPetted else { return }
            showHappyFace(image, seconds: 1.0)
            if moves { jump(height: 0.12, twist: 0, duration: 0.55) }
        }

        /// A task checked off: a small hop and a few sparkles; the last one,
        /// a binky (higher, with a twist) and more. Without motion, just the
        /// happy face.
        func celebrate(_ celebration: MochiCelebration?, moves: Bool, happy image: NSImage?) {
            guard let celebration, celebration.id != celebrated else { return }
            celebrated = celebration.id
            showHappyFace(image, seconds: celebration.big ? 1.6 : 1.1)
            guard moves else { return }
            if celebration.big {
                jump(height: 0.22, twist: 0.35, duration: 0.8)
                sparkle(count: 8, delay: 0.3)
            } else {
                jump(height: 0.1, twist: 0, duration: 0.5)
                sparkle(count: 5, delay: 0.18)
            }
        }

        private var celebrated: UUID?

        private func showHappyFace(_ image: NSImage?, seconds: Double) {
            happy.contents = image?.cgImage(forProposedRect: nil, context: nil, hints: nil)
            let face = CAKeyframeAnimation(keyPath: "opacity")
            face.values = [1, 1, 0]
            face.keyTimes = [0, 0.85, 1]
            face.duration = seconds
            happy.add(face, forKey: "happy")
            let hide = CAKeyframeAnimation(keyPath: "opacity")
            hide.values = [0, 0, 1]
            hide.keyTimes = [0, 0.85, 1]
            hide.duration = seconds
            self.image.add(hide, forKey: "happy")
        }

        /// Crouch, up (stretched, twisting for a binky), land with an 8% squash.
        private func jump(height: CGFloat, twist: CGFloat, duration: Double) {
            let up = bounds.height * height
            let top = CATransform3DRotate(CATransform3DScale(CATransform3DMakeTranslation(0, up, 0), 0.97, 1.05, 1), twist, 0, 0, 1)
            let jump = CAKeyframeAnimation(keyPath: "transform")
            jump.values = [
                CATransform3DIdentity,
                CATransform3DMakeScale(1.04, 0.94, 1),
                top,
                CATransform3DIdentity,
                CATransform3DMakeScale(1.04, 0.92, 1),
                CATransform3DIdentity,
            ].map { NSValue(caTransform3D: $0) }
            jump.keyTimes = [0, 0.12, 0.45, 0.75, 0.85, 1]
            jump.timingFunctions = [CAMediaTimingFunction(name: .easeOut), CAMediaTimingFunction(name: .easeOut),
                                    CAMediaTimingFunction(name: .easeIn), CAMediaTimingFunction(name: .easeOut),
                                    CAMediaTimingFunction(name: .easeInEaseOut)]
            jump.duration = duration
            hop.add(jump, forKey: "hop")
        }

        /// Tiny pink and white stars that burst out around the head and fade.
        private func sparkle(count: Int, delay: Double) {
            let centre = CGPoint(x: bounds.midX, y: bounds.height * 0.62)
            let size = bounds.height * 0.07
            let begin = CACurrentMediaTime() + delay
            for index in 0..<count {
                let star = CAShapeLayer()
                star.path = Self.starPath(size)
                star.fillColor = index % 2 == 0 ? CGColor(red: 1, green: 1, blue: 1, alpha: 1)
                    : CGColor(srgbRed: 1, green: 0.62, blue: 0.74, alpha: 1)
                star.bounds = CGRect(x: 0, y: 0, width: size, height: size)
                star.position = centre
                star.opacity = 0
                layer?.addSublayer(star)
                let angle = Double(index) / Double(count) * 2 * .pi + 0.3
                let distance = bounds.height * (0.3 + 0.06 * Double(index % 3))
                let move = CABasicAnimation(keyPath: "position")
                move.fromValue = NSValue(point: centre)
                move.toValue = NSValue(point: CGPoint(x: centre.x + cos(angle) * distance, y: centre.y + sin(angle) * distance * 0.8))
                move.timingFunction = CAMediaTimingFunction(name: .easeOut)
                let fade = CAKeyframeAnimation(keyPath: "opacity")
                fade.values = [0, 1, 1, 0]
                fade.keyTimes = [0, 0.15, 0.55, 1]
                let grow = CAKeyframeAnimation(keyPath: "transform.scale")
                grow.values = [0.2, 1.1, 0.6]
                let spin = CABasicAnimation(keyPath: "transform.rotation.z")
                spin.toValue = Double.pi / 2
                let group = CAAnimationGroup()
                group.animations = [move, fade, grow, spin]
                group.duration = 0.9
                group.beginTime = begin
                group.fillMode = .backwards
                group.isRemovedOnCompletion = true
                star.add(group, forKey: "sparkle")
                DispatchQueue.main.asyncAfter(deadline: .now() + delay + 1) { star.removeFromSuperlayer() }
            }
        }

        private static func starPath(_ size: CGFloat) -> CGPath {
            let path = CGMutablePath()
            let c = size / 2, inner = size * 0.13
            path.move(to: CGPoint(x: c, y: 0))
            path.addLine(to: CGPoint(x: c + inner, y: c - inner))
            path.addLine(to: CGPoint(x: size, y: c))
            path.addLine(to: CGPoint(x: c + inner, y: c + inner))
            path.addLine(to: CGPoint(x: c, y: size))
            path.addLine(to: CGPoint(x: c - inner, y: c + inner))
            path.addLine(to: CGPoint(x: 0, y: c))
            path.addLine(to: CGPoint(x: c - inner, y: c - inner))
            path.closeSubpath()
            return path
        }

        required init?(coder: NSCoder) { nil }

        override func layout() {
            super.layout()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            for sub in [hop, tilt, image, happy] {
                sub.bounds = bounds
                sub.position = CGPoint(x: bounds.midX, y: bounds.height * MochiFlipbook.feet)
                sub.contentsScale = window?.backingScaleFactor ?? 2
            }
            for (index, z) in zs.enumerated() { place(z, index) }
            CATransaction.commit()
        }

        func configure(frames: [MochiIdleFrame: NSImage], pose: MochiPose, animate: Bool) {
            let key = frames.map { "\($0.key.rawValue)\(ObjectIdentifier($0.value).hashValue)" }.sorted().joined()
                + "\(pose.breathPeriod)\(pose.blinks)\(pose.earTwitch)\(pose.noseWiggle)\(pose.effect)\(pose.effectsMove)\(animate)"
            guard key != configured else { return }
            configured = key
            image.removeAllAnimations()
            zs.forEach { $0.removeFromSuperlayer() }
            zs = []
            func cg(_ frame: MochiIdleFrame) -> CGImage? {
                (frames[frame] ?? frames[.base])?.cgImage(forProposedRect: nil, context: nil, hints: nil)
            }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            image.contents = cg(.base)
            CATransaction.commit()

            if pose.effect == .zzz { addZs(moving: animate && pose.effectsMove) }
            guard animate else { return }
            if pose.breathPeriod > 0 {
                let breathe = CABasicAnimation(keyPath: "transform")
                breathe.fromValue = CATransform3DIdentity
                breathe.toValue = CATransform3DMakeScale(1 + CGFloat(MochiPose.breath) / 2, 1 + CGFloat(MochiPose.breath), 1)
                breathe.duration = pose.breathPeriod / 2
                breathe.autoreverses = true
                breathe.repeatCount = .infinity
                breathe.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                image.add(breathe, forKey: "breathe")
            }
            let timeline = MochiFlipbook.timeline(pose)
            if timeline.frames.count > 1 {
                let flip = CAKeyframeAnimation(keyPath: "contents")
                flip.values = timeline.frames.compactMap { cg($0) }
                flip.keyTimes = timeline.times.map { NSNumber(value: $0) }
                flip.calculationMode = .discrete
                flip.duration = MochiFlipbook.cycle
                flip.repeatCount = .infinity
                if flip.values?.count == timeline.frames.count { image.add(flip, forKey: "flip") }
            }
        }

        private func addZs(moving: Bool) {
            for index in 0..<3 {
                let z = CATextLayer()
                z.string = "z"
                z.alignmentMode = .center
                z.foregroundColor = CGColor(srgbRed: 0.72, green: 0.68, blue: 0.9, alpha: 1)
                z.contentsScale = window?.backingScaleFactor ?? 2
                z.opacity = moving ? 0 : 0.75
                layer?.addSublayer(z)
                zs.append(z)
                place(z, index)
                guard moving else { continue }
                let rise = CABasicAnimation(keyPath: "position.y")
                rise.byValue = bounds.height * 0.08
                let fade = CAKeyframeAnimation(keyPath: "opacity")
                fade.values = [0, 0.9, 0]
                fade.keyTimes = [0, 0.3, 1]
                let group = CAAnimationGroup()
                group.animations = [rise, fade]
                group.duration = 3
                group.repeatCount = .infinity
                group.beginTime = CACurrentMediaTime() + Double(index)
                z.add(group, forKey: "drift")
            }
        }

        private func place(_ z: CATextLayer, _ index: Int) {
            let size = bounds.height * (0.07 + CGFloat(index) * 0.02)
            z.fontSize = size
            z.font = NSFont.systemFont(ofSize: size, weight: .bold)
            z.bounds = CGRect(x: 0, y: 0, width: size, height: size * 1.25)
            z.position = CGPoint(x: bounds.width * (0.66 + CGFloat(index) * 0.07), y: bounds.height * (0.6 + CGFloat(index) * 0.08))
        }
    }
}

/// Repeatable "random" numbers, so a timeline is the same each time.
struct SplitMix {
    private var state: UInt64
    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func next(in range: ClosedRange<Double>) -> Double {
        range.lowerBound + Double(next() >> 11) / Double(1 << 53) * (range.upperBound - range.lowerBound)
    }
}

// MARK: - Flat drawing

/// A flat drawing of the character, in its colours, with the state colour.
struct CharacterStill: View {
    let settings: CompanionSettings
    let presentation: CharacterPresentation

    var body: some View {
        let primary = Color(nsColor: NSColor(companionHex: settings.primaryColor) ?? .systemBlue)
        let secondary = Color(nsColor: NSColor(companionHex: settings.secondaryColor) ?? .white)
        let accent = Color(nsColor: NSColor(companionHex: presentation.accent) ?? .systemTeal)
        GeometryReader { proxy in
            let s = min(proxy.size.width, proxy.size.height)
            ZStack {
                switch settings.character {
                case .mochi:
                    MochiDrawing(look: settings.mochi.look, posture: presentation.mochi.posture, s: s)
                case .creature:
                    Circle().fill(primary).frame(width: s * 0.62)
                    Ellipse().fill(secondary).frame(width: s * 0.38, height: s * 0.3).offset(y: s * 0.1)
                    eyes(accent, s: s, y: -s * 0.06, size: s * 0.09, spacing: s * 0.11, white: true)
                case .orb:
                    Circle().stroke(primary, lineWidth: s * 0.04).frame(width: s * 0.66)
                    Circle().stroke(secondary.opacity(0.8), lineWidth: s * 0.02).frame(width: s * 0.78, height: s * 0.32)
                    Circle().fill(accent).frame(width: s * 0.32)
                case .robot, .custom:
                    RoundedRectangle(cornerRadius: s * 0.08).fill(secondary).frame(width: s * 0.36, height: s * 0.24).offset(y: s * 0.18)
                    RoundedRectangle(cornerRadius: s * 0.1).fill(primary).frame(width: s * 0.5, height: s * 0.38).offset(y: -s * 0.1)
                    RoundedRectangle(cornerRadius: s * 0.07).fill(Color.black.opacity(0.85)).frame(width: s * 0.4, height: s * 0.24).offset(y: -s * 0.1)
                    eyes(accent, s: s, y: -s * 0.1, size: s * 0.08, spacing: s * 0.09, white: false)
                }
            }
            .overlay {
                if presentation.isReading {
                    // A small open book held in front.
                    HStack(spacing: s * 0.01) {
                        RoundedRectangle(cornerRadius: s * 0.01).fill(Color(white: 0.96)).frame(width: s * 0.15, height: s * 0.13)
                        RoundedRectangle(cornerRadius: s * 0.01).fill(Color(white: 0.96)).frame(width: s * 0.15, height: s * 0.13)
                    }
                    .padding(s * 0.012)
                    .background(RoundedRectangle(cornerRadius: s * 0.02).fill(Color(red: 0.49, green: 0.23, blue: 0.27)))
                    .rotation3DEffect(.degrees(35), axis: (x: 1, y: 0, z: 0))
                    .offset(y: s * 0.2)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .opacity(presentation.opacity)
        }
        .animation(.easeInOut(duration: 0.3), value: presentation.accent)
    }

    @ViewBuilder
    private func eyes(_ accent: Color, s: CGFloat, y: CGFloat, size: CGFloat, spacing: CGFloat, white: Bool) -> some View {
        ForEach([-1.0, 1.0], id: \.self) { side in
            ZStack {
                if white { Circle().fill(.white).frame(width: size * 1.5) }
                Capsule().fill(accent).frame(width: size, height: presentation.eyesClosed ? size * 0.2 : size)
            }
            .offset(x: side * spacing, y: y)
        }
    }
}

/// Mochi as a flat picture (before the 3D still is ready, or if it can't be
/// rendered): ears, head, body, eyes with sparkles, blush and the "w".
struct MochiDrawing: View {
    let look: MochiLook
    let posture: MochiPosture
    let s: CGFloat

    var body: some View {
        let p = look.palette
        let fur = color(p.fur), accent = color(p.accent), eye = color(p.eye)
        let loaf = posture.body == .loaf
        ZStack {
            // Ears behind the head.
            ForEach([-1.0, 1.0], id: \.self) { side in
                let floppy = MochiRecipe.earIsFloppy(Float(side), look.floppyEar) && !posture.droop
                ZStack {
                    Capsule().fill(fur).frame(width: s * 0.11, height: s * 0.3)
                    Capsule().fill(accent).frame(width: s * 0.055, height: s * 0.22)
                }
                .rotationEffect(.degrees(posture.droop || posture.earsBack ? side * 70 : floppy ? side * 105 : side * 8), anchor: .bottom)
                .offset(x: side * s * 0.09, y: -s * (floppy ? 0.27 : 0.32) + (loaf ? s * 0.05 : 0))
            }
            Ellipse().fill(fur).frame(width: s * 0.34, height: s * 0.3).offset(y: s * (loaf ? 0.25 : 0.2))
            Ellipse().fill(color(p.tummy)).frame(width: s * 0.18, height: s * 0.17).offset(y: s * (loaf ? 0.26 : 0.21))
            Ellipse().fill(fur).frame(width: s * 0.5, height: s * 0.4).offset(y: -s * (loaf ? 0.03 : 0.08))
            ForEach([-1.0, 1.0], id: \.self) { side in
                Ellipse().fill(color(p.blush).opacity(Double(MochiPalette.blushOpacity)))
                    .frame(width: s * 0.08, height: s * 0.045)
                    .offset(x: side * s * 0.15, y: s * (loaf ? 0.04 : -0.01))
                Group {
                    if posture.eyes == .closed || posture.eyes == .happy {
                        Capsule().fill(eye).frame(width: s * 0.06, height: s * 0.014)
                    } else {
                        ZStack(alignment: .topLeading) {
                            Ellipse().fill(eye)
                            Circle().fill(.white).frame(width: s * 0.022).offset(x: s * 0.008, y: s * 0.01)
                        }
                        .frame(width: s * 0.072, height: posture.eyes == .half ? s * 0.035 : s * 0.085)
                    }
                }
                .offset(x: side * s * 0.1, y: s * (loaf ? -0.02 : -0.07))
            }
            Ellipse().fill(accent).frame(width: s * 0.03, height: s * 0.02).offset(y: s * (loaf ? 0.02 : -0.03))
        }
        .offset(y: s * 0.05)
    }

    private func color(_ hex: String) -> Color { Color(nsColor: NSColor(companionHex: hex) ?? .white) }
}
