import AtlasCore
import CoreGraphics
import Foundation

/// Editing geometry for the Spatial Window Manager, shared by the 3D
/// miniature and the flat 2D diagram. Works in Accessibility screen
/// coordinates (points, top-left origin); each view only converts between
/// these and its own pixels or world units.
public struct LayoutCanvas: Sendable {
    public let displays: [DisplayInfo]
    /// The union of every display's frame.
    public let bounds: CGRect

    /// How close (sum of edge distances, in display fractions) a window must
    /// be to a preset before it snaps.
    public static let snapThreshold = 0.22
    public static let minimumSize = CGSize(width: 160, height: 120)

    public init(displays: [DisplayInfo]) {
        self.displays = displays
        self.bounds = displays.map(\.frame).reduce(CGRect.null) { $0.union($1) }
    }

    public enum Edge: String, CaseIterable, Sendable {
        case left, right, top, bottom, topLeft, topRight, bottomLeft, bottomRight
    }

    public struct Snap: Sendable, Equatable {
        public let display: DisplayInfo
        public let preset: WindowPreset
        public let frame: CGRect
    }

    /// Where a rule's window goes on these displays.
    public func frame(of rule: WindowRule) -> CGRect? {
        LayoutResolver.target(for: rule, displays: displays)?.frame
    }

    public func display(of rule: WindowRule) -> DisplayInfo? {
        LayoutResolver.target(for: rule, displays: displays)?.display
    }

    /// A rect dragged by `delta`.
    public func moved(_ start: CGRect, by delta: CGSize) -> CGRect {
        start.offsetBy(dx: delta.width, dy: delta.height)
    }

    /// A rect with one edge or corner dragged by `delta`, never smaller than
    /// `minimumSize`.
    public func resized(_ start: CGRect, edge: Edge, by delta: CGSize) -> CGRect {
        var minX = start.minX, maxX = start.maxX, minY = start.minY, maxY = start.maxY
        let w = Self.minimumSize.width, h = Self.minimumSize.height
        if [.left, .topLeft, .bottomLeft].contains(edge) { minX = min(minX + delta.width, maxX - w) }
        if [.right, .topRight, .bottomRight].contains(edge) { maxX = max(maxX + delta.width, minX + w) }
        if [.top, .topLeft, .topRight].contains(edge) { minY = min(minY + delta.height, maxY - h) }
        if [.bottom, .bottomLeft, .bottomRight].contains(edge) { maxY = max(maxY + delta.height, minY + h) }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// The preset `rect` is close to on the display under its center, to
    /// show as a guide while dragging.
    public func snap(for rect: CGRect) -> Snap? {
        guard let display = displays.display(containing: rect) ?? displays.main else { return nil }
        let fraction = FractionalRect(rect, in: display.visibleFrame)
        let best = WindowPreset.allCases
            .map { ($0, $0.rect.distance(to: fraction)) }
            .min { $0.1 < $1.1 }
        guard let (preset, distance) = best, distance <= Self.snapThreshold else { return nil }
        return Snap(display: display, preset: preset, frame: preset.rect.absolute(in: display.visibleFrame))
    }

    /// The rule after the user drops its window at `rect`: on the display
    /// under the rect's center, clamped to that display, snapped to a preset
    /// if one is close.
    public func commit(_ rule: WindowRule, rect: CGRect, snapping: Bool = true) -> WindowRule {
        var updated = rule
        if snapping, let snap = snap(for: rect) {
            updated.display = target(for: snap.display, keeping: rule)
            updated.frame = snap.preset.rect
            return updated
        }
        guard let display = displays.display(containing: rect) ?? displays.main else { return rule }
        let clamped = LayoutResolver.clamp(rect, to: display.visibleFrame)
        updated.display = target(for: display, keeping: rule)
        updated.frame = FractionalRect(clamped, in: display.visibleFrame).clamped
        return updated
    }

    /// Keeps the rule's display role (main, secondary, …) when it stays on
    /// the same display; otherwise names the new one.
    private func target(for display: DisplayInfo, keeping rule: WindowRule) -> DisplayTarget {
        if self.display(of: rule)?.id == display.id, rule.display != .sameAsBefore { return rule.display }
        return display.isMain ? .main : .display(id: display.id, name: display.name)
    }

    /// Maps canvas points into a view of `size`, keeping the aspect ratio
    /// and leaving `padding` around the edge.
    public func fitting(into size: CGSize, padding: CGFloat = 24) -> (scale: CGFloat, offset: CGPoint) {
        guard !bounds.isNull, bounds.width > 0, bounds.height > 0 else { return (1, .zero) }
        let scale = min((size.width - padding * 2) / bounds.width, (size.height - padding * 2) / bounds.height)
        let offset = CGPoint(
            x: (size.width - bounds.width * scale) / 2 - bounds.minX * scale,
            y: (size.height - bounds.height * scale) / 2 - bounds.minY * scale
        )
        return (max(scale, 0.0001), offset)
    }
}
