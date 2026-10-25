import AtlasCore
import AtlasSpaces
import RealityKit
import SwiftUI

/// 3D miniature of the real monitor setup. Drag a window panel to move it
/// (across displays too); drag with ⌥ held to resize from the nearest
/// corner. It snaps to presets with a visible guide, exactly like the 2D
/// diagram, which offers everything this view does.
///
/// Rendering stops when the window is hidden or minimized, and when this
/// view isn't shown.
public struct MonitorWorldView: View {
    let canvas: LayoutCanvas
    let rules: [WindowRule]
    @Binding var selection: UUID?
    let onCommit: (WindowRule) -> Void

    @State private var scene = MonitorWorldScene()
    @State private var isWindowVisible = true
    @State private var drag: DragState?

    private struct DragState {
        let ruleID: UUID
        let start: CGRect
        let edge: LayoutCanvas.Edge?
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
            ZStack(alignment: .bottomLeading) {
                Color(nsColor: NSColor(white: 0.09, alpha: 1))
                if isWindowVisible {
                    world(size: proxy.size)
                } else {
                    Label("Paused while the window is hidden", systemImage: "pause.circle")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                Text("Drag a window to move it · ⌥-drag to resize · it snaps to halves and thirds")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.6))
                    .padding(10)
            }
        }
        .background(WindowVisibilityReader(isVisible: $isWindowVisible))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("3D view of your displays and windows. Everything here is also in the 2D view and the table below.")
    }

    private func world(size: CGSize) -> some View {
        RealityView { content in
            content.camera = .virtual
            // After a pause the old view may still hold the scene; take it back first.
            scene.root.removeFromParent()
            content.add(scene.root)
        } update: { _ in
            scene.sync(
                canvas: canvas,
                rules: rules,
                overrides: drag.map { [$0.ruleID: $0.rect] } ?? [:],
                selection: selection,
                snap: drag?.snap,
                aspect: size.width / max(size.height, 1)
            )
        }
        .gesture(
            DragGesture(minimumDistance: 2)
                .targetedToAnyEntity()
                .onChanged { value in changed(value, viewSize: size) }
                .onEnded { _ in finish() }
        )
        .simultaneousGesture(
            SpatialTapGesture()
                .targetedToAnyEntity()
                .onEnded { value in selection = scene.ruleID(for: value.entity) }
        )
    }

    private func changed(_ value: EntityTargetValue<DragGesture.Value>, viewSize: CGSize) {
        guard let id = drag?.ruleID ?? scene.ruleID(for: value.entity),
              let rule = rules.first(where: { $0.id == id })
        else { return }
        selection = id
        let start: CGRect
        let edge: LayoutCanvas.Edge?
        if let drag {
            start = drag.start
            edge = drag.edge
        } else {
            guard let frame = canvas.frame(of: rule) else { return }
            start = frame
            let grabbed = scene.canvasPoint(fromView: value.gestureValue.startLocation, viewSize: viewSize)
            edge = NSEvent.modifierFlags.contains(.option) ? Self.nearestCorner(of: frame, to: grabbed) : nil
        }
        // View points → screen points on the displays.
        let pointsPerUnit = scene.pointsPerUnit(viewHeight: viewSize.height)
        let scale = CGFloat(MonitorWorldScene.unitsPerPoint) * pointsPerUnit
        let translation = value.gestureValue.translation
        let delta = CGSize(width: translation.width / scale, height: translation.height / scale)
        let rect = edge.map { canvas.resized(start, edge: $0, by: delta) } ?? canvas.moved(start, by: delta)
        drag = DragState(ruleID: id, start: start, edge: edge, rect: rect, snap: canvas.snap(for: rect))
    }

    private func finish() {
        guard let drag, let rule = rules.first(where: { $0.id == drag.ruleID }) else {
            self.drag = nil
            return
        }
        onCommit(canvas.commit(rule, rect: drag.rect))
        self.drag = nil
    }

    /// Which corner a resize grabs: the one nearest where the drag started.
    private static func nearestCorner(of frame: CGRect, to point: CGPoint) -> LayoutCanvas.Edge {
        switch (point.x >= frame.midX, point.y < frame.midY) {
        case (true, true): return .topRight
        case (true, false): return .bottomRight
        case (false, true): return .topLeft
        case (false, false): return .bottomLeft
        }
    }
}
