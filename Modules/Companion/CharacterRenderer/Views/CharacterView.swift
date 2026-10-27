import AtlasCompanion
import Metal
import RealityKit
import SwiftUI

/// Draws the character.
///
/// A live RealityKit view redraws every frame (about two-thirds of a CPU
/// core even when nothing moves), so it's only on screen while the
/// character is doing something (`live`). The rest of the time it shows a
/// still image of the same 3D model, rendered once off-screen and cached.
/// "Still" mode, a locked screen, Low Power Mode or a hidden overlay get
/// the flat drawing.
public struct CharacterView: View {
    let settings: CompanionSettings
    let presentation: CharacterPresentation
    let paused: Bool
    let live: Bool
    @State private var scene = CharacterScene()
    @State private var snapshot: NSImage?

    public init(settings: CompanionSettings, presentation: CharacterPresentation, paused: Bool, live: Bool = true) {
        self.settings = settings
        self.presentation = presentation
        self.paused = paused
        self.live = live
    }

    public var body: some View {
        if presentation.rendering == .staticImage || paused {
            CharacterStill(settings: settings, presentation: presentation)
        } else if live {
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
        } else {
            Group {
                if let snapshot {
                    Image(nsImage: snapshot).resizable().interpolation(.high).opacity(presentation.opacity)
                } else {
                    CharacterStill(settings: settings, presentation: presentation)
                }
            }
            .task(id: CharacterSnapshotter.key(settings, presentation)) {
                snapshot = await CharacterSnapshotter.shared.image(settings: settings, presentation: presentation)
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
    private let scene = CharacterScene()
    private let device = MTLCreateSystemDefaultDevice()

    static func key(_ settings: CompanionSettings, _ presentation: CharacterPresentation) -> String {
        "\(settings.character.rawValue)|\(settings.primaryColor)|\(settings.secondaryColor)|\(settings.accessory.rawValue)|\(settings.customCharacterPath ?? "")|\(presentation.accent)|\(presentation.eyesClosed)"
    }

    func image(settings: CompanionSettings, presentation: CharacterPresentation) async -> NSImage? {
        let key = Self.key(settings, presentation)
        if let cached = cache[key] { return cached }
        guard let device else { return nil }
        do {
            let renderer = try self.renderer ?? RealityRenderer()
            self.renderer = renderer
            var still = presentation
            still.bobAmplitude = 0
            still.spinSpeed = 0
            still.gesture = .none
            still.opacity = 1
            scene.build(settings)
            scene.apply(still)
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
            guard let image = Self.image(from: texture) else { return nil }
            cache[key] = image
            if cache.count > 40 { cache.removeAll() }
            return image
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
