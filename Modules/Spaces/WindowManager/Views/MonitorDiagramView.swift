import AtlasCore
import AtlasSpaces
import SwiftUI

/// The flat 2D equivalent of the 3D miniature: monitors at their real
/// relative positions with draggable window rectangles. Drag a window to
/// move it (across displays too), drag its handles to resize, and it snaps
/// to halves, thirds and the other presets with a visible guide.
public struct MonitorDiagramView: View {
    let canvas: LayoutCanvas
    let rules: [WindowRule]
    @Binding var selection: UUID?
    let onCommit: (WindowRule) -> Void

    @State private var drag: DragState?

    private struct DragState {
        let ruleID: UUID
        let start: CGRect
        var rect: CGRect
        var snap: LayoutCanvas.Snap?
    }

    public init(canvas: LayoutCanvas, rules: [WindowRule], selection: Binding<UUID?>, onCommit: @escaping (WindowRule) -> Void) {
        self.canvas = canvas
        self.rules = rules
        self._selection = selection
        self.onCommit = onCommit
    }

    public var body: some View {
        GeometryReader { proxy in
            let fit = canvas.fitting(into: proxy.size)
            ZStack(alignment: .topLeading) {
                Color.clear.contentShape(Rectangle()).onTapGesture { selection = nil }
                ForEach(canvas.displays) { display in
                    displayView(display, fit: fit)
                }
                if let snap = drag?.snap {
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                        .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
                        .overlay(alignment: .bottom) {
                            Text(snap.preset.title).font(.caption2.weight(.semibold)).padding(4)
                        }
                        .frame(width: snap.frame.width * fit.scale, height: snap.frame.height * fit.scale)
                        .offset(x: snap.frame.minX * fit.scale + fit.offset.x, y: snap.frame.minY * fit.scale + fit.offset.y)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
                // Back to front, so the frontmost window draws last.
                ForEach(rules.sorted { $0.zOrder > $1.zOrder }) { rule in
                    if let frame = drag?.ruleID == rule.id ? drag?.rect : canvas.frame(of: rule) {
                        windowView(rule, frame: frame, fit: fit)
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Diagram of your displays and where each window goes. Every window is also listed in the table below.")
    }

    private func displayView(_ display: DisplayInfo, fit: (scale: CGFloat, offset: CGPoint)) -> some View {
        let frame = display.frame
        let menuBar = max(0, display.visibleFrame.minY - frame.minY) * fit.scale
        return ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .underPageBackgroundColor))
            Rectangle().fill(Color.secondary.opacity(0.25)).frame(height: menuBar)
            HStack(spacing: 4) {
                Text(display.name).font(.caption.weight(.medium))
                if display.isMain { Text("Main").font(.caption2).foregroundStyle(.secondary) }
            }
            .padding(.horizontal, 6)
            .padding(.top, menuBar + 4)
        }
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator, lineWidth: 1.5))
        .frame(width: frame.width * fit.scale, height: frame.height * fit.scale)
        .offset(x: frame.minX * fit.scale + fit.offset.x, y: frame.minY * fit.scale + fit.offset.y)
        .allowsHitTesting(false)
    }

    private func windowView(_ rule: WindowRule, frame: CGRect, fit: (scale: CGFloat, offset: CGPoint)) -> some View {
        let isSelected = selection == rule.id
        let size = CGSize(width: frame.width * fit.scale, height: frame.height * fit.scale)
        return ZStack {
            RoundedRectangle(cornerRadius: 5)
                .fill(.background.opacity(rule.state == .normal ? 0.95 : 0.55))
            RoundedRectangle(cornerRadius: 5)
                .strokeBorder(isSelected ? Color.accentColor : Color.secondary.opacity(0.6), lineWidth: isSelected ? 2.5 : 1)
            VStack(spacing: 4) {
                if let icon = AppIcons.icon(for: rule.bundleID), size.height > 46 {
                    Image(nsImage: icon).resizable().frame(width: 28, height: 28)
                }
                Text(rule.displayName).font(.caption.weight(.medium)).lineLimit(1)
                if rule.state != .normal {
                    Text(rule.state.title).font(.caption2).foregroundStyle(.secondary)
                }
            }
            .padding(4)
        }
        .frame(width: size.width, height: size.height)
        .overlay { if isSelected { handles(rule, frame: frame, size: size, scale: fit.scale) } }
        .contentShape(Rectangle())
        .gesture(moveGesture(rule, frame: frame, scale: fit.scale))
        .onTapGesture { selection = rule.id }
        .offset(x: frame.minX * fit.scale + fit.offset.x, y: frame.minY * fit.scale + fit.offset.y)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(rule.displayName), \(rule.display.title)")
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
    }

    private func handles(_ rule: WindowRule, frame: CGRect, size: CGSize, scale: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(LayoutCanvas.Edge.allCases, id: \.self) { edge in
                let point = Self.handlePoint(edge, in: size)
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: 10, height: 10)
                    .contentShape(Rectangle().inset(by: -6))
                    .position(point)
                    .gesture(resizeGesture(rule, frame: frame, edge: edge, scale: scale))
            }
        }
        .frame(width: size.width, height: size.height)
    }

    private static func handlePoint(_ edge: LayoutCanvas.Edge, in size: CGSize) -> CGPoint {
        switch edge {
        case .left: return CGPoint(x: 0, y: size.height / 2)
        case .right: return CGPoint(x: size.width, y: size.height / 2)
        case .top: return CGPoint(x: size.width / 2, y: 0)
        case .bottom: return CGPoint(x: size.width / 2, y: size.height)
        case .topLeft: return .zero
        case .topRight: return CGPoint(x: size.width, y: 0)
        case .bottomLeft: return CGPoint(x: 0, y: size.height)
        case .bottomRight: return CGPoint(x: size.width, y: size.height)
        }
    }

    // MARK: - Gestures

    private func moveGesture(_ rule: WindowRule, frame: CGRect, scale: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                selection = rule.id
                let start = drag?.ruleID == rule.id ? drag!.start : frame
                let delta = CGSize(width: value.translation.width / scale, height: value.translation.height / scale)
                let rect = canvas.moved(start, by: delta)
                drag = DragState(ruleID: rule.id, start: start, rect: rect, snap: canvas.snap(for: rect))
            }
            .onEnded { _ in finish(rule) }
    }

    private func resizeGesture(_ rule: WindowRule, frame: CGRect, edge: LayoutCanvas.Edge, scale: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                let start = drag?.ruleID == rule.id ? drag!.start : frame
                let delta = CGSize(width: value.translation.width / scale, height: value.translation.height / scale)
                let rect = canvas.resized(start, edge: edge, by: delta)
                drag = DragState(ruleID: rule.id, start: start, rect: rect, snap: canvas.snap(for: rect))
            }
            .onEnded { _ in finish(rule) }
    }

    private func finish(_ rule: WindowRule) {
        guard let drag, drag.ruleID == rule.id else { return }
        onCommit(canvas.commit(rule, rect: drag.rect))
        self.drag = nil
    }
}
