import AtlasCompanion
import RealityKit
import SwiftUI

/// Draws the character. Uses RealityKit only while it's animated and
/// visible; "Still" mode, a locked screen, Low Power Mode or a hidden
/// overlay get a static drawing that costs nothing to keep on screen.
public struct CharacterView: View {
    let settings: CompanionSettings
    let presentation: CharacterPresentation
    let paused: Bool
    @State private var scene = CharacterScene()

    public init(settings: CompanionSettings, presentation: CharacterPresentation, paused: Bool) {
        self.settings = settings
        self.presentation = presentation
        self.paused = paused
    }

    public var body: some View {
        if presentation.rendering == .staticImage || paused {
            CharacterStill(settings: settings, presentation: presentation)
        } else {
            RealityView { content in
                content.camera = .virtual
                scene.root.removeFromParent()
                content.add(scene.root)
                scene.build(settings)
                scene.apply(presentation)
            } update: { _ in
                scene.build(settings)
                scene.apply(presentation)
            }
        }
    }
}

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
