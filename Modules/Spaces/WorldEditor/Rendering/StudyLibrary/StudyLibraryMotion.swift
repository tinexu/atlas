import AppKit
import Foundation
import AtlasSpaces
import RealityKit

/// The reading room's gentle motion: rain sliding down the window, the
/// candle flickering, the globe turning once a minute and steam rising from
/// the mug. Activation fades the banker's lamp up, turns the open book's
/// page and brightens the chandelier. Loops run on RealityKit's animation
/// clock; none of them start under Reduce Motion, where activation only
/// switches the lamp and chandelier without animating.
@MainActor
final class StudyLibraryMotion: RoomMotion {
    private(set) var parts: StudyLibraryParts
    let reduceMotion: Bool
    private var started = false
    private var fade: Task<Void, Never>?
    private var lampLevel: Float = 0
    /// The study state last applied (hourglass, candle).
    private var lastStudy: StudyRoomState?
    private var flickering = false
    private var flipping = false

    init(parts: StudyLibraryParts, reduceMotion: Bool) {
        self.parts = parts
        self.reduceMotion = reduceMotion
    }

    func start() {
        guard !started, !reduceMotion else { return }
        started = true
        defer { if let state = lastStudy { lastStudy = nil; update(state) } }

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
        animateSnow()
        turnReaderPages()
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
        // The candle flame flickers only while a session runs (see `update`).
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

    /// Slow falling snow, with a little sideways drift.
    private func animateSnow() {
        guard started else { return }
        for (index, group) in parts.snow.enumerated() {
            let duration = 7.0 + Double(index) * 1.3
            var low = group.transform
            low.translation += [index == 0 ? -0.03 : 0.04, -0.55, 0]
            loop(group, FromToByAnimation<Transform>(from: group.transform, to: low, duration: duration, bindTarget: .transform,
                                                     repeatMode: .repeat))
            if let flakes = group.children.first {
                sequence(flakes, [(0, 0.9, duration * 0.2), (0.9, 0.9, duration * 0.6), (0.9, 0, duration * 0.2)])
            }
        }
    }

    /// The reader turns a page about every 20 s: over in 1.4 s, then still.
    private func turnReaderPages() {
        guard let page = parts.readerPage else { return }
        let flat = Transform(rotation: simd_quatf(angle: 0.02, axis: [0, 0, 1]), translation: page.position)
        let over = Transform(rotation: simd_quatf(angle: .pi - 0.02, axis: [0, 0, 1]), translation: page.position)
        let steps = [
            FromToByAnimation<Transform>(from: flat, to: flat, duration: 18.6, bindTarget: .transform),
            FromToByAnimation<Transform>(from: flat, to: over, duration: 1.4, timing: .easeInOut, bindTarget: .transform),
        ].compactMap { try? AnimationResource.generate(with: $0) }
        guard steps.count == 2, let cycle = try? AnimationResource.sequence(with: steps) else { return }
        page.playAnimation(cycle.repeat())
    }

    // MARK: - Study state

    /// Applies the hourglass and candle from the room state. Called on
    /// every sync but only does work when they changed (a few times a
    /// minute while studying), never per frame.
    func update(_ study: StudyRoomState) {
        let previous = lastStudy
        if let m = parts.materials {
            if let before = previous?.board, before != study.board, let content = parts.boardContent {
                // Only rows newly checked off: strike them, keep the rest as is.
                var unstruck = study.board
                for index in unstruck.rows.indices { unstruck.rows[index].isStruck = false }
                let struck = study.board.rows.filter { row in row.isStruck && !(before.rows.first { $0.id == row.id }?.isStruck ?? false) }
                if !struck.isEmpty, unstruck.rows.map(\.id) == before.rows.map(\.id) {
                    struck.forEach { strikeRow($0.id) }
                } else {
                    StudyLibraryBuilder.fillBoard(content, study.board, m)
                }
            } else if previous == nil, let content = parts.boardContent {
                StudyLibraryBuilder.fillBoard(content, study.board, m)
            }
            if previous?.deskCalendar != study.deskCalendar, let face = parts.calendarFace {
                StudyLibraryBuilder.fillCalendarFace(face, study.deskCalendar, m)
            }
        }
        if previous?.window != study.window { applyWindow(study.window) }
        if previous?.streak != study.streak, let content = parts.starsContent, let m = parts.materials {
            StudyLibraryBuilder.fillStars(content, study.streak, m)
        }
        if previous?.reader != study.reader, let reader = study.reader { applyReader(reader) }
        guard previous?.hourglass != study.hourglass || previous?.candle != study.candle else {
            lastStudy = study
            return
        }
        lastStudy = study
        applyCandle(study.candle)
        if let previous, study.hourglass.flips > previous.hourglass.flips, !reduceMotion {
            flip(then: study.hourglass)
        } else if !flipping {
            applySand(study.hourglass)
        }
    }

    /// The sky, sun or moon, clouds, fog, rain or snow, and the light
    /// through the window.
    private func applyWindow(_ view: StudyRoomState.WindowView) {
        typealias Sky = StudyLibraryBuilder.Sky
        let palette = parts.palette
        parts.sky?.model?.materials = [StudyLibraryMaterials.sky(view, palette: palette)]
        if let orb = parts.skyOrb {
            if let look = Sky.orb(view) {
                orb.isEnabled = true
                orb.position = look.position
                orb.scale = SIMD3(repeating: look.size)
                orb.model?.materials = [StudyLibraryMaterials.emissive(look.color, intensity: look.intensity)]
            } else {
                orb.isEnabled = false
            }
        }
        let cloudy = view.weather != .clear && view.weather != .fog
        // Clouds, fog and snow are made the first time the weather needs them.
        if let room = parts.room {
            if cloudy && parts.clouds == nil { parts.clouds = StudyLibraryBuilder.buildClouds(into: room) }
            if view.weather == .fog && parts.fog == nil { parts.fog = StudyLibraryBuilder.buildFog(into: room) }
            if view.weather == .snow && parts.snow.isEmpty {
                parts.snow = StudyLibraryBuilder.buildSnow(into: room)
                animateSnow()
            }
        }
        parts.clouds?.isEnabled = cloudy
        if cloudy { parts.clouds?.model?.materials = [StudyLibraryMaterials.cloud(Sky.cloudColor(view))] }
        parts.fog?.isEnabled = view.weather == .fog
        for group in parts.rain { group.isEnabled = view.weather == .rain }
        for group in parts.snow { group.isEnabled = view.weather == .snow }
        let light = Sky.light(view, palette: palette)
        parts.windowLight?.light.color = NSColor(atlasHex: light.color)
        parts.windowLight?.light.intensity = palette.moonlightIntensity * light.level
    }

    /// Focus: a calm indigo glow and nothing waiting shown; otherwise its
    /// usual colour, with a small warm light when suggestions are waiting.
    private func applyReader(_ reader: StudyRoomState.Reader) {
        typealias R = StudyLibraryBuilder.Reader
        for eye in parts.readerAccents {
            eye.model?.materials = [StudyLibraryMaterials.emissive(reader.isFocused ? R.focusAccent : R.idleAccent, intensity: 1.2)]
        }
        guard let dot = parts.readerDot else { return }
        let show = reader.waiting > 0 && !reader.isFocused
        guard dot.isEnabled != show else { return }
        dot.isEnabled = show
        dot.stopAllAnimations()
        guard show, !reduceMotion, started else { return }
        let rest = Transform(translation: dot.position)
        loop(dot, FromToByAnimation<Transform>(from: rest, to: Transform(translation: dot.position + [0, 0.012, 0]), duration: 0.9,
                                               timing: .easeInOut, bindTarget: .transform, repeatMode: .autoReverse))
    }

    private func applyCandle(_ candle: StudyRoomState.Candle) {
        let palette = parts.palette
        let height = StudyLibraryBuilder.ReadingCorner.candleHeight
        // Burns down to a short stub when the daily goal is met.
        let remaining = Float(1 - 0.85 * min(1, max(0, candle.burned)))
        parts.candleWax?.scale = [1, remaining, 1]
        parts.flame?.position = [0, height * remaining + 0.012, 0]
        if let glow = parts.flame?.children.first as? ModelEntity {
            // Goal reached: a brighter, warmer flame for the rest of the day.
            glow.model?.materials = [StudyLibraryMaterials.emissive(candle.goalReached ? "#FFA04D" : palette.candleWarm,
                                                                    intensity: palette.candleIntensity * (candle.goalReached ? 1.6 : 1))]
        }
        let shouldFlicker = candle.flickers && !reduceMotion && started
        guard shouldFlicker != flickering, let flame = parts.flame else { return }
        flickering = shouldFlicker
        if shouldFlicker {
            let rest = Transform(translation: flame.position)
            var tall = rest
            tall.scale = [0.92, 1.14, 0.92]
            loop(flame, FromToByAnimation<Transform>(from: rest, to: tall, duration: 0.35, timing: .easeInOut,
                                                     bindTarget: .transform, repeatMode: .autoReverse))
            if let glow = flame.children.first {
                loop(glow, FromToByAnimation<Float>(from: 1, to: 0.78, duration: 0.23, timing: .easeInOut,
                                                    bindTarget: .opacity, repeatMode: .autoReverse))
            }
        } else {
            // A calm glow.
            flame.stopAllAnimations()
            flame.children.first?.stopAllAnimations()
            flame.scale = .one
            flame.children.first?.components.set(OpacityComponent(opacity: 1))
        }
    }

    private func applySand(_ hourglass: StudyRoomState.Hourglass) {
        guard let parts = parts.hourglass else { return }
        typealias H = StudyLibraryBuilder.Hourglass
        let drained = Float(min(1, max(0, hourglass.drained)))
        // Volumes scale with the cube, so the sizes use cube roots.
        let top = cbrt(1 - drained), pile = cbrt(drained)
        parts.topSand.scale = SIMD3(repeating: max(0.001, top))
        parts.pile.scale = SIMD3(repeating: max(0.001, pile))
        let flowing = hourglass.isRunning && !hourglass.isPaused && drained > 0.001 && drained < 0.999
        parts.stream.isEnabled = flowing
        if flowing {
            let bottom = H.floor + H.pile.height * pile
            parts.stream.scale = [1, max(0.001, H.neck - bottom), 1]
            parts.stream.position = [0, (H.neck + bottom) / 2, 0]
        }
    }

    /// The session ended: the full bottom turns over to the top.
    private func flip(then hourglass: StudyRoomState.Hourglass) {
        guard let parts = parts.hourglass else { return }
        flipping = true
        applySand(StudyRoomState.Hourglass(drained: 1))
        // Turning about the middle of the glass, not the base.
        let middle = SIMD3<Float>(0, StudyLibraryBuilder.Hourglass.neck, 0)
        func turned(_ angle: Float) -> Transform {
            let rotation = simd_quatf(angle: angle, axis: [0, 0, 1])
            return Transform(rotation: rotation, translation: middle - rotation.act(middle))
        }
        let steps = [Float.pi / 2, .pi].compactMap { angle -> AnimationResource? in
            try? AnimationResource.generate(with: FromToByAnimation<Transform>(
                from: turned(angle - .pi / 2), to: turned(angle),
                duration: 0.4, timing: angle == .pi / 2 ? .easeIn : .easeOut, bindTarget: .transform
            ))
        }
        if steps.count == 2, let resource = try? AnimationResource.sequence(with: steps) {
            parts.flipper.playAnimation(resource)
        }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(850))
            parts.flipper.stopAllAnimations()
            parts.flipper.transform = Transform()
            self?.flipping = false
            if let state = self?.lastStudy?.hourglass { self?.applySand(state) }
        }
    }

    /// A row was checked off: a chalk line strikes it through and a little
    /// dust puffs up. (The row leaves the board when the state updates.)
    func strikeRow(_ id: UUID) {
        guard let content = parts.boardContent, let m = parts.materials,
              let checkbox = content.findEntity(named: StudyRoomState.Item.boardRow(id).entityName) else { return }
        let start = checkbox.position + [0.035, 0, 0.002]
        let length: Float = 0.62
        var line = MeshBatch()
        line.add(.generateBox(width: length, height: 0.004, depth: 0.002), at: [length / 2, 0, 0])
        if let strike = line.entity(m.material(.paper)) {
            strike.position = start
            content.addChild(strike)
            if reduceMotion {
                strike.scale = .one
            } else {
                strike.scale = [0.001, 1, 1]
                if let grow = try? AnimationResource.generate(with: FromToByAnimation<Transform>(
                    from: Transform(scale: [0.001, 1, 1], translation: start), to: Transform(translation: start),
                    duration: 0.45, timing: .easeOut, bindTarget: .transform)) {
                    strike.playAnimation(grow)
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(480))
                        strike.scale = .one
                    }
                }
            }
        }
        // A tick in the box, and a small puff of chalk dust.
        var tick = MeshBatch()
        tick.add(.generateBox(width: 0.012, height: 0.004, depth: 0.002), at: [-0.005, -0.003, 0.001], rotation: simd_quatf(angle: -0.8, axis: [0, 0, 1]))
        tick.add(.generateBox(width: 0.024, height: 0.004, depth: 0.002), at: [0.006, 0.002, 0.001], rotation: simd_quatf(angle: 0.9, axis: [0, 0, 1]))
        if let mark = tick.entity(m.material(.paper)) { checkbox.addChild(mark) }
        guard !reduceMotion else { return }
        var dust = MeshBatch()
        for index in 0..<6 {
            let angle = Float(index) * 1.05
            dust.add(.generateSphere(radius: 0.004), at: [cos(angle) * 0.012, sin(angle) * 0.012, 0.004])
        }
        guard let puff = dust.entity(m.material(.paper)) else { return }
        puff.position = checkbox.position
        puff.components.set(OpacityComponent(opacity: 0.8))
        content.addChild(puff)
        let spread = Transform(scale: SIMD3(repeating: 3), translation: checkbox.position + [0, 0.01, 0.005])
        if let grow = try? AnimationResource.generate(with: FromToByAnimation<Transform>(
            from: Transform(translation: checkbox.position), to: spread, duration: 0.6, timing: .easeOut, bindTarget: .transform)),
           let fade = try? AnimationResource.generate(with: FromToByAnimation<Float>(from: 0.8, to: 0, duration: 0.6, bindTarget: .opacity)) {
            puff.playAnimation(grow)
            puff.playAnimation(fade, blendLayerOffset: 1)
        }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(650))
            puff.removeFromParent()
        }
    }

    /// New course books slide onto the shelf from the room side.
    func slideIn(_ ids: Set<UUID>) {
        for id in ids {
            guard let book = parts.courseBooks[id] else { continue }
            guard !reduceMotion else { continue }
            var start = book.transform
            start.translation += [0.35, 0.06, 0]
            let rest = book.transform
            guard let resource = try? AnimationResource.generate(with: FromToByAnimation<Transform>(
                from: start, to: rest, duration: 0.7, timing: .easeOut, bindTarget: .transform
            )) else { continue }
            book.transform = start
            book.playAnimation(resource)
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(750))
                book.transform = rest
            }
        }
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
