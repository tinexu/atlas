import AppKit
import AtlasCore
import SwiftUI

/// Colours shared by the 2D canvas, the 3D galaxy and run history.
public enum FlowStyle {
    static func color(for kind: NodeKind) -> Color {
        switch kind {
        case .trigger: return .orange
        case .condition: return .purple
        case .action: return .blue
        case .control: return .teal
        }
    }

    static func nsColor(for kind: NodeKind) -> NSColor {
        switch kind {
        case .trigger: return .systemOrange
        case .condition: return .systemPurple
        case .action: return .systemBlue
        case .control: return .systemTeal
        }
    }

    static func color(for category: NodeTemplate.Category) -> Color {
        switch category {
        case .triggers: return color(for: .trigger)
        case .conditions: return color(for: .condition)
        case .actions: return color(for: .action)
        case .control: return color(for: NodeKind.control)
        }
    }

    static func color(for type: PortType) -> Color {
        switch type {
        case .control: return .primary
        case .string: return .pink
        case .number: return .green
        case .bool: return .yellow
        case .filePath: return .cyan
        case .bundleId: return .indigo
        case .url: return .mint
        case .any: return .gray
        }
    }

    static func color(for state: RunState) -> Color {
        switch state {
        case .running, .pending: return .accentColor
        case .succeeded: return .green
        case .partiallySucceeded: return .orange
        case .failed: return .red
        case .skipped, .canceled: return .gray
        }
    }
}

/// Where things are on a node card, in canvas points. A node's position is
/// its top-left corner.
enum NodeLayout {
    static let width: CGFloat = 220
    static let header: CGFloat = 48
    static let row: CGFloat = 22
    static let padding: CGFloat = 8

    /// Inputs on the left, outputs on the right; flow ports first.
    static func columns(_ ports: [NodePort]) -> (inputs: [NodePort], outputs: [NodePort]) {
        func ordered(_ direction: PortDirection) -> [NodePort] {
            let side = ports.filter { $0.direction == direction }
            return side.filter(\.isControl) + side.filter { !$0.isControl }
        }
        return (ordered(.input), ordered(.output))
    }

    static func size(_ ports: [NodePort]) -> CGSize {
        let (inputs, outputs) = columns(ports)
        return CGSize(width: width, height: header + CGFloat(max(inputs.count, outputs.count, 1)) * row + padding)
    }

    static func frame(_ node: WorkflowStep, ports: [NodePort]) -> CGRect {
        CGRect(origin: CGPoint(x: node.position.x, y: node.position.y), size: size(ports))
    }

    static func portPoint(_ node: WorkflowStep, ports: [NodePort], id: String, direction: PortDirection) -> CGPoint? {
        let (inputs, outputs) = columns(ports)
        let side = direction == .input ? inputs : outputs
        guard let index = side.firstIndex(where: { $0.id == id }) else { return nil }
        return CGPoint(
            x: node.position.x + (direction == .input ? 0 : width),
            y: node.position.y + header + CGFloat(index) * row + row / 2
        )
    }

    /// A smooth curve between two ports, leaving and entering horizontally.
    static func curve(from a: CGPoint, to b: CGPoint) -> Path {
        var path = Path()
        path.move(to: a)
        let pull = max(60, abs(b.x - a.x) / 2)
        path.addCurve(to: b, control1: CGPoint(x: a.x + pull, y: a.y), control2: CGPoint(x: b.x - pull, y: b.y))
        return path
    }
}

/// Converts between canvas points and view points.
struct CanvasTransform: Equatable {
    var offset: CGPoint = CGPoint(x: 40, y: 40)
    var scale: CGFloat = 1

    static let scaleRange: ClosedRange<CGFloat> = 0.25...2.5

    func view(_ point: CGPoint) -> CGPoint {
        CGPoint(x: point.x * scale + offset.x, y: point.y * scale + offset.y)
    }

    func canvas(_ point: CGPoint) -> CGPoint {
        CGPoint(x: (point.x - offset.x) / scale, y: (point.y - offset.y) / scale)
    }

    func view(_ rect: CGRect) -> CGRect {
        CGRect(origin: view(rect.origin), size: CGSize(width: rect.width * scale, height: rect.height * scale))
    }

    /// Zooms by `factor` keeping `anchor` (a view point) still.
    mutating func zoom(by factor: CGFloat, around anchor: CGPoint) {
        let before = canvas(anchor)
        scale = min(max(scale * factor, Self.scaleRange.lowerBound), Self.scaleRange.upperBound)
        offset = CGPoint(x: anchor.x - before.x * scale, y: anchor.y - before.y * scale)
    }

    /// Fits `bounds` (canvas points) into a view of `size`.
    static func fitting(_ bounds: CGRect, in size: CGSize, padding: CGFloat = 40) -> CanvasTransform {
        guard !bounds.isNull, bounds.width > 0, size.width > 0 else { return CanvasTransform() }
        let scale = min(max(min((size.width - padding * 2) / bounds.width, (size.height - padding * 2) / bounds.height),
                            scaleRange.lowerBound), 1.2)
        return CanvasTransform(
            offset: CGPoint(x: (size.width - bounds.width * scale) / 2 - bounds.minX * scale,
                            y: (size.height - bounds.height * scale) / 2 - bounds.minY * scale),
            scale: scale
        )
    }
}
