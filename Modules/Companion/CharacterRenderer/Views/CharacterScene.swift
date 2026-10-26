import AppKit
import AtlasCompanion
import RealityKit

/// The Companion character in RealityKit, built from primitives so no
/// external assets are needed: a floating robot, a round creature or a
/// geometric orb, in your colours, with an optional accessory. A USDZ
/// character can replace the body (it keeps the same states).
///
/// Motion uses RealityKit's own looping animations, so a still character
/// costs nothing per frame from ATLAS.
@MainActor
final class CharacterScene {
    let root = Entity()
    private let camera = PerspectiveCamera()
    /// Moves up and down (float, hop).
    private let float = Entity()
    /// Turns (thinking, shake).
    private let turn = Entity()
    private var body = Entity()
    /// Parts tinted by the state colour (eyes, core, antenna tip).
    private var accents: [ModelEntity] = []
    private var eyes: [Entity] = []
    private var floatController: AnimationPlaybackController?
    private var spinController: AnimationPlaybackController?
    private var built: (source: CharacterSource, look: String)?
    private var lastPresentation: CharacterPresentation?

    init() {
        camera.camera.fieldOfViewInDegrees = 32
        camera.look(at: [0, 0.02, 0], from: [0, 0.3, 3.6], relativeTo: nil)
        root.addChild(camera)
        let key = DirectionalLight()
        key.light.intensity = 3_200
        key.look(at: .zero, from: [-2, 3, 4], relativeTo: nil)
        root.addChild(key)
        let fill = DirectionalLight()
        fill.light.intensity = 900
        fill.look(at: .zero, from: [3, 1, 2], relativeTo: nil)
        root.addChild(fill)
        root.addChild(float)
        float.addChild(turn)
    }

    // MARK: - Building

    func build(_ settings: CompanionSettings) {
        let source = CharacterSource.from(settings)
        let look = "\(settings.primaryColor)|\(settings.secondaryColor)|\(settings.accessory.rawValue)"
        guard built?.source != source || built?.look != look else { return }
        built = (source, look)
        body.removeFromParent()
        accents = []
        eyes = []
        let primary = NSColor(companionHex: settings.primaryColor) ?? .systemBlue
        let secondary = NSColor(companionHex: settings.secondaryColor) ?? .white
        let character: Entity
        let anchors: Anchors
        switch source {
        case .procedural(.creature): (character, anchors) = buildCreature(primary, secondary)
        case .procedural(.orb): (character, anchors) = buildOrb(primary, secondary)
        case .usdz(let url): (character, anchors) = buildCustom(url, fallback: primary, secondary)
        case .procedural: (character, anchors) = buildRobot(primary, secondary)
        }
        if case .usdz = source {} else { addAccessory(settings.accessory, anchors: anchors, to: character, primary: primary, secondary: secondary) }
        body = character
        turn.addChild(body)
        if let lastPresentation {
            self.lastPresentation = nil
            apply(lastPresentation)
        }
    }

    /// Where accessories attach on a character.
    private struct Anchors {
        var headTop: Float
        var headCenterY: Float
        var headHalfWidth: Float
        var eyeY: Float
        var eyeZ: Float
        var eyeSpacing: Float
        var hasEyes = true
    }

    private func buildRobot(_ primary: NSColor, _ secondary: NSColor) -> (Entity, Anchors) {
        let robot = Entity()
        let head = part(.generateBox(width: 0.92, height: 0.72, depth: 0.7, cornerRadius: 0.2), primary, at: [0, 0.3, 0])
        let face = part(.generateBox(width: 0.74, height: 0.48, depth: 0.05, cornerRadius: 0.14), NSColor(white: 0.08, alpha: 1), at: [0, 0.3, 0.34])
        let torso = part(.generateBox(width: 0.62, height: 0.46, depth: 0.5, cornerRadius: 0.16), secondary, at: [0, -0.32, 0])
        let chest = accent(.generateSphere(radius: 0.06), at: [0, -0.28, 0.26])
        let leftArm = part(.generateSphere(radius: 0.13), primary, at: [-0.44, -0.3, 0])
        let rightArm = part(.generateSphere(radius: 0.13), primary, at: [0.44, -0.3, 0])
        let thruster = accent(.generateCylinder(height: 0.06, radius: 0.16), at: [0, -0.6, 0])
        [head, face, torso, chest, leftArm, rightArm, thruster].forEach { robot.addChild($0) }
        for x: Float in [-0.17, 0.17] {
            let eye = accent(.generateSphere(radius: 0.085), at: [x, 0.32, 0.37])
            robot.addChild(eye)
            eyes.append(eye)
        }
        return (robot, Anchors(headTop: 0.66, headCenterY: 0.3, headHalfWidth: 0.46, eyeY: 0.32, eyeZ: 0.4, eyeSpacing: 0.17))
    }

    private func buildCreature(_ primary: NSColor, _ secondary: NSColor) -> (Entity, Anchors) {
        let creature = Entity()
        let bodySphere = part(.generateSphere(radius: 0.62), primary, at: [0, 0, 0])
        let belly = part(.generateSphere(radius: 0.4), secondary, at: [0, -0.12, 0.3])
        belly.scale = [1, 0.9, 0.55]
        let leftEar = part(.generateSphere(radius: 0.16), primary, at: [-0.36, 0.55, 0])
        let rightEar = part(.generateSphere(radius: 0.16), primary, at: [0.36, 0.55, 0])
        let leftFoot = part(.generateSphere(radius: 0.15), secondary, at: [-0.26, -0.6, 0.12])
        let rightFoot = part(.generateSphere(radius: 0.15), secondary, at: [0.26, -0.6, 0.12])
        leftFoot.scale = [1.2, 0.6, 1.3]
        rightFoot.scale = [1.2, 0.6, 1.3]
        [bodySphere, belly, leftEar, rightEar, leftFoot, rightFoot].forEach { creature.addChild($0) }
        for x: Float in [-0.2, 0.2] {
            let white = part(.generateSphere(radius: 0.13), .white, at: [x, 0.2, 0.5])
            creature.addChild(white)
            let pupil = accent(.generateSphere(radius: 0.07), at: [x, 0.2, 0.62])
            creature.addChild(pupil)
            eyes.append(white)
            eyes.append(pupil)
        }
        return (creature, Anchors(headTop: 0.62, headCenterY: 0.1, headHalfWidth: 0.6, eyeY: 0.2, eyeZ: 0.66, eyeSpacing: 0.2))
    }

    private func buildOrb(_ primary: NSColor, _ secondary: NSColor) -> (Entity, Anchors) {
        let orb = Entity()
        let core = accent(.generateSphere(radius: 0.32), at: .zero)
        orb.addChild(core)
        let shell = part(.generateSphere(radius: 0.4), primary.withAlphaComponent(0.25), at: .zero)
        orb.addChild(shell)
        // Three tilted rings of small cubes.
        for (ring, tilt) in [Float(0), 1.05, -1.05].enumerated() {
            let holder = Entity()
            holder.orientation = simd_quatf(angle: tilt, axis: [1, 0, 0]) * simd_quatf(angle: Float(ring) * 0.6, axis: [0, 1, 0])
            for i in 0..<12 {
                let a = Float(i) / 12 * 2 * .pi
                let cube = part(.generateBox(size: 0.09, cornerRadius: 0.015), ring == 0 ? secondary : primary, at: [cos(a) * 0.62, 0, sin(a) * 0.62])
                cube.orientation = simd_quatf(angle: a, axis: [0, 1, 0])
                holder.addChild(cube)
            }
            orb.addChild(holder)
        }
        return (orb, Anchors(headTop: 0.42, headCenterY: 0, headHalfWidth: 0.42, eyeY: 0.05, eyeZ: 0.42, eyeSpacing: 0.15, hasEyes: false))
    }

    private func buildCustom(_ url: URL, fallback primary: NSColor, _ secondary: NSColor) -> (Entity, Anchors) {
        guard let model = try? Entity.load(contentsOf: url) else { return buildRobot(primary, secondary) }
        // Fit it into a unit-ish box, centred.
        let bounds = model.visualBounds(relativeTo: nil)
        let longest = max(bounds.extents.x, bounds.extents.y, bounds.extents.z)
        if longest > 0 { model.scale *= SIMD3(repeating: 1.4 / longest) }
        let fitted = model.visualBounds(relativeTo: nil)
        model.position -= fitted.center
        let holder = Entity()
        holder.addChild(model)
        return (holder, Anchors(headTop: 0.7, headCenterY: 0.3, headHalfWidth: 0.4, eyeY: 0.3, eyeZ: 0.4, eyeSpacing: 0.15, hasEyes: false))
    }

    private func addAccessory(_ accessory: CompanionSettings.Accessory, anchors: Anchors, to character: Entity, primary: NSColor, secondary: NSColor) {
        let dark = NSColor(white: 0.12, alpha: 1)
        switch accessory {
        case .none:
            break
        case .antenna:
            character.addChild(part(.generateCylinder(height: 0.26, radius: 0.025), dark, at: [0, anchors.headTop + 0.12, 0]))
            character.addChild(accent(.generateSphere(radius: 0.07), at: [0, anchors.headTop + 0.28, 0]))
        case .hat:
            character.addChild(part(.generateCylinder(height: 0.04, radius: anchors.headHalfWidth * 1.15), dark, at: [0, anchors.headTop + 0.01, 0]))
            character.addChild(part(.generateCylinder(height: 0.3, radius: anchors.headHalfWidth * 0.68), dark, at: [0, anchors.headTop + 0.17, 0]))
            character.addChild(part(.generateCylinder(height: 0.06, radius: anchors.headHalfWidth * 0.7), secondary, at: [0, anchors.headTop + 0.07, 0]))
        case .headphones:
            for i in 0...8 {
                let a = Float.pi * Float(i) / 8
                let r = anchors.headHalfWidth + 0.08
                character.addChild(part(.generateSphere(radius: 0.045), dark, at: [cos(a) * r, anchors.headCenterY + sin(a) * (anchors.headTop - anchors.headCenterY + 0.08), 0]))
            }
            for side: Float in [-1, 1] {
                let cup = part(.generateCylinder(height: 0.12, radius: 0.15), dark, at: [side * (anchors.headHalfWidth + 0.06), anchors.headCenterY, 0])
                cup.orientation = simd_quatf(angle: .pi / 2, axis: [0, 0, 1])
                character.addChild(cup)
                let pad = accent(.generateCylinder(height: 0.02, radius: 0.08), at: [side * (anchors.headHalfWidth + 0.125), anchors.headCenterY, 0])
                pad.orientation = simd_quatf(angle: .pi / 2, axis: [0, 0, 1])
                character.addChild(pad)
            }
        case .glasses:
            for side: Float in [-1, 1] {
                let lens = part(.generateCylinder(height: 0.02, radius: 0.12), dark.withAlphaComponent(0.85), at: [side * anchors.eyeSpacing, anchors.eyeY, anchors.eyeZ + 0.03])
                lens.orientation = simd_quatf(angle: .pi / 2, axis: [1, 0, 0])
                character.addChild(lens)
            }
            character.addChild(part(.generateBox(width: anchors.eyeSpacing * 0.8, height: 0.025, depth: 0.02), dark, at: [0, anchors.eyeY + 0.04, anchors.eyeZ + 0.03]))
        }
    }

    private func part(_ mesh: MeshResource, _ color: NSColor, at position: SIMD3<Float>) -> ModelEntity {
        let material = SimpleMaterial(color: color, roughness: 0.45, isMetallic: false)
        let entity = ModelEntity(mesh: mesh, materials: [material])
        entity.position = position
        return entity
    }

    private func accent(_ mesh: MeshResource, at position: SIMD3<Float>) -> ModelEntity {
        let entity = ModelEntity(mesh: mesh, materials: [UnlitMaterial(color: .systemTeal)])
        entity.position = position
        accents.append(entity)
        return entity
    }

    // MARK: - States

    func apply(_ presentation: CharacterPresentation) {
        guard presentation != lastPresentation else { return }
        let previous = lastPresentation
        lastPresentation = presentation

        let glow = NSColor(companionHex: presentation.accent) ?? .systemTeal
        for entity in accents { entity.model?.materials = [UnlitMaterial(color: glow)] }
        body.components.set(OpacityComponent(opacity: Float(presentation.opacity)))
        for eye in eyes {
            var scale = eye.scale
            scale.y = presentation.eyesClosed ? max(scale.x * 0.12, 0.01) : scale.x
            eye.scale = scale
        }

        if previous?.bobAmplitude != presentation.bobAmplitude || previous?.bobPeriod != presentation.bobPeriod {
            floatController?.stop()
            floatController = nil
            float.position = .zero
            if presentation.bobAmplitude > 0 {
                let rise = Transform(translation: [0, Float(presentation.bobAmplitude) * 2.4, 0])
                if let resource = try? AnimationResource.generate(with: FromToByAnimation<Transform>(
                    from: Transform(translation: [0, -Float(presentation.bobAmplitude) * 1.2, 0]), to: rise,
                    duration: presentation.bobPeriod / 2, timing: .easeInOut, bindTarget: .transform, repeatMode: .autoReverse)) {
                    floatController = float.playAnimation(resource)
                }
            }
        }
        if previous?.spinSpeed != presentation.spinSpeed {
            spinController?.stop()
            spinController = nil
            if presentation.spinSpeed > 0 {
                if let resource = try? AnimationResource.generate(with: FromToByAnimation<Transform>(
                    by: Transform(rotation: simd_quatf(angle: .pi / 2, axis: [0, 1, 0])), duration: 0.25 / presentation.spinSpeed,
                    bindTarget: .transform, repeatMode: .cumulative)) {
                    spinController = turn.playAnimation(resource)
                }
            } else {
                turn.move(to: Transform.identity, relativeTo: float, duration: 0.4, timingFunction: .easeInOut)
            }
        }
        if presentation.gesture != previous?.gesture { perform(presentation.gesture) }
    }

    private func perform(_ gesture: CharacterPresentation.Gesture) {
        switch gesture {
        case .none:
            break
        case .hop:
            body.move(to: Transform(translation: [0, 0.22, 0]), relativeTo: turn, duration: 0.18, timingFunction: .easeOut)
            after(0.2) { [weak self] in
                guard let self else { return }
                self.body.move(to: Transform.identity, relativeTo: self.turn, duration: 0.28, timingFunction: .easeIn)
            }
        case .shake:
            for (index, angle) in [Float(0.28), -0.28, 0.18, -0.12, 0].enumerated() {
                after(Double(index) * 0.11) { [weak self] in
                    guard let self else { return }
                    self.body.move(to: Transform(rotation: simd_quatf(angle: angle, axis: [0, 1, 0])), relativeTo: self.turn,
                                   duration: 0.1, timingFunction: .easeInOut)
                }
            }
        case .nod:
            body.move(to: Transform(rotation: simd_quatf(angle: 0.18, axis: [1, 0, 0])), relativeTo: turn, duration: 0.18, timingFunction: .easeOut)
            after(0.22) { [weak self] in
                guard let self else { return }
                self.body.move(to: Transform.identity, relativeTo: self.turn, duration: 0.22, timingFunction: .easeInOut)
            }
        }
    }

    private func after(_ seconds: Double, _ work: @escaping @MainActor () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { MainActor.assumeIsolated(work) }
    }

    /// Stops every animation (hidden, locked screen, Low Power Mode).
    func pause() {
        floatController?.pause()
        spinController?.pause()
    }

    func resume() {
        floatController?.resume()
        spinController?.resume()
    }
}

extension NSColor {
    /// "#RRGGBB"
    convenience init?(companionHex hex: String) {
        var text = hex.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("#") { text.removeFirst() }
        guard text.count == 6, let value = UInt32(text, radix: 16) else { return nil }
        self.init(srgbRed: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255,
                  blue: CGFloat(value & 0xFF) / 255, alpha: 1)
    }

    var companionHex: String {
        guard let rgb = usingColorSpace(.sRGB) else { return "#5B8DEF" }
        return String(format: "#%02X%02X%02X", Int(rgb.redComponent * 255), Int(rgb.greenComponent * 255), Int(rgb.blueComponent * 255))
    }
}
