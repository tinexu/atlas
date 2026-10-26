import CoreGraphics
import Foundation

/// Where the Companion sits. Positions are remembered per display
/// arrangement, and always end up fully on a screen, even after a display
/// is unplugged or rearranged. Pure geometry (AppKit coordinates: origin at
/// the bottom-left of the main display, y up), so it's easy to test.
public enum OverlayGeometry {
    public struct Screen: Equatable, Sendable {
        public let frame: CGRect
        /// Without the menu bar and Dock.
        public let visibleFrame: CGRect
        public let isMain: Bool

        public init(frame: CGRect, visibleFrame: CGRect, isMain: Bool) {
            self.frame = frame
            self.visibleFrame = visibleFrame
            self.isMain = isMain
        }
    }

    public static let margin: CGFloat = 16

    /// Identifies a display arrangement: the same screens in the same places.
    public static func arrangementKey(_ screens: [Screen]) -> String {
        screens.map { s in
            "\(Int(s.frame.minX)),\(Int(s.frame.minY)),\(Int(s.frame.width))x\(Int(s.frame.height))"
        }
        .sorted()
        .joined(separator: "|")
    }

    /// Bottom-right corner of the main display, above the Dock.
    public static func defaultOrigin(size: CGSize, screens: [Screen]) -> CGPoint {
        guard let main = screens.first(where: \.isMain) ?? screens.first else { return .zero }
        let visible = main.visibleFrame
        return CGPoint(x: visible.maxX - size.width - margin, y: visible.minY + margin)
    }

    /// The saved position for this arrangement if there is one, otherwise
    /// the default, moved fully onto a screen either way.
    public static func restore(saved: [String: CGPoint], size: CGSize, screens: [Screen]) -> CGPoint {
        guard !screens.isEmpty else { return .zero }
        let origin = saved[arrangementKey(screens)] ?? defaultOrigin(size: size, screens: screens)
        return clamp(origin: origin, size: size, screens: screens)
    }

    /// Moves a window fully inside the visible area of the screen it overlaps
    /// most, or the nearest screen when it's off every screen.
    public static func clamp(origin: CGPoint, size: CGSize, screens: [Screen]) -> CGPoint {
        guard !screens.isEmpty else { return origin }
        let rect = CGRect(origin: origin, size: size)
        let overlaps = screens.map { ($0, $0.visibleFrame.intersection(rect)) }
        let target: Screen
        if let best = overlaps.filter({ !$0.1.isNull && $0.1.width > 0 && $0.1.height > 0 })
            .max(by: { $0.1.width * $0.1.height < $1.1.width * $1.1.height }) {
            target = best.0
        } else {
            let center = CGPoint(x: rect.midX, y: rect.midY)
            target = screens.min { distance(center, to: $0.visibleFrame) < distance(center, to: $1.visibleFrame) }!
        }
        let visible = target.visibleFrame
        let x = min(max(origin.x, visible.minX), max(visible.minX, visible.maxX - size.width))
        let y = min(max(origin.y, visible.minY), max(visible.minY, visible.maxY - size.height))
        return CGPoint(x: x, y: y)
    }

    static func distance(_ point: CGPoint, to rect: CGRect) -> CGFloat {
        let dx = max(rect.minX - point.x, 0, point.x - rect.maxX)
        let dy = max(rect.minY - point.y, 0, point.y - rect.maxY)
        return (dx * dx + dy * dy).squareRoot()
    }

    /// Where the speech bubble goes: beside the character, on whichever
    /// side has room, kept on the same screen.
    public static func bubbleOrigin(character: CGRect, bubble: CGSize, screens: [Screen]) -> CGPoint {
        let screen = screens.first { $0.frame.intersects(character) } ?? screens.first
        let visible = screen?.visibleFrame ?? character.insetBy(dx: -2_000, dy: -2_000)
        let spacing: CGFloat = 6
        var x = character.minX - bubble.width - spacing
        if x < visible.minX { x = character.maxX + spacing }
        var y = character.midY - bubble.height / 2 + character.height * 0.25
        y = min(max(y, visible.minY), visible.maxY - bubble.height)
        x = min(max(x, visible.minX), visible.maxX - bubble.width)
        return CGPoint(x: x, y: y)
    }
}
