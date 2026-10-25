import AtlasCore
import SwiftUI

/// One node on the 2D canvas: a header with its icon, title and summary,
/// then its ports, inputs on the left and outputs on the right.
struct NodeCardView: View {
    let node: WorkflowStep
    let title: String
    let subtitle: String
    let symbol: String
    let ports: [NodePort]
    let isSelected: Bool
    let state: RunState?
    let issues: [ValidationIssue]
    let connectedInputs: Set<String>
    var onPortDrag: ((NodePort, DragGesture.Value) -> Void)?
    var onPortDragEnd: ((NodePort, DragGesture.Value) -> Void)?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false

    private var hasError: Bool { issues.contains { $0.severity == .error } }

    var body: some View {
        let size = NodeLayout.size(ports)
        let (inputs, outputs) = NodeLayout.columns(ports)
        VStack(alignment: .leading, spacing: 0) {
            header
                .frame(height: NodeLayout.header)
            HStack(alignment: .top, spacing: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(inputs) { port in portRow(port, alignment: .leading) }
                }
                Spacer(minLength: 4)
                VStack(alignment: .trailing, spacing: 0) {
                    ForEach(outputs) { port in portRow(port, alignment: .trailing) }
                }
            }
            Spacer(minLength: 0)
        }
        .frame(width: size.width, height: size.height)
        .background(.background, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(borderColor, lineWidth: borderWidth))
        .opacity(node.isEnabled ? 1 : 0.55)
        .shadow(color: .black.opacity(isSelected ? 0.25 : 0.12), radius: isSelected ? 8 : 3, y: 1)
        .overlay(alignment: .topTrailing) {
            if let issue = issues.first {
                Image(systemName: issue.severity == .error ? "exclamationmark.octagon.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(issue.severity == .error ? .red : .orange)
                    .background(Circle().fill(.background))
                    .offset(x: 6, y: -6)
                    .help(issues.map(\.message).joined(separator: "\n"))
            }
        }
        .onAppear { pulse = state == .running }
        .onChange(of: state) { _, new in pulse = new == .running }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title), \(subtitle)\(state.map { ", \($0.title)" } ?? "")\(hasError ? ", has problems" : "")")
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 26, height: 26)
                .background(FlowStyle.color(for: node.kind), in: RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.callout.weight(.semibold)).lineLimit(1)
                Text(subtitle.isEmpty ? node.kind.rawValue.capitalized : subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if let state, state != .pending {
                Image(systemName: Self.symbol(for: state))
                    .foregroundStyle(FlowStyle.color(for: state))
                    .opacity(pulse && !reduceMotion ? 0.35 : 1)
                    .animation(pulse && !reduceMotion ? .easeInOut(duration: 0.6).repeatForever() : .default, value: pulse)
            }
        }
        .padding(.horizontal, 10)
    }

    private func portRow(_ port: NodePort, alignment: HorizontalAlignment) -> some View {
        let isInput = port.direction == .input
        return HStack(spacing: 5) {
            if isInput { dot(port) }
            Text(port.name + (port.isRequired && !connectedInputs.contains(port.id) && node.parameters[port.id].map({ $0.isEmpty }) ?? true ? " *" : ""))
                .font(.caption2)
                .foregroundStyle(port.isControl ? .primary : .secondary)
                .lineLimit(1)
            if !isInput { dot(port) }
        }
        .frame(height: NodeLayout.row)
        .help("\(port.name): \(port.type.title)")
    }

    @ViewBuilder
    private func dot(_ port: NodePort) -> some View {
        let shape = Group {
            if port.isControl {
                Image(systemName: "arrowtriangle.right.fill").font(.system(size: 8))
            } else {
                Circle().frame(width: 8, height: 8)
            }
        }
        .foregroundStyle(FlowStyle.color(for: port.type))
        .frame(width: 14, height: 14)
        .contentShape(Rectangle().inset(by: -4))
        .offset(x: port.direction == .input ? -7 : 7)

        if port.direction == .output, let onPortDrag {
            shape.gesture(
                DragGesture(minimumDistance: 2, coordinateSpace: .named(FlowCanvasView.space))
                    .onChanged { onPortDrag(port, $0) }
                    .onEnded { onPortDragEnd?(port, $0) }
            )
        } else {
            shape
        }
    }

    private var borderColor: Color {
        if hasError { return .red }
        if let state, state != .pending { return FlowStyle.color(for: state) }
        return isSelected ? .accentColor : Color.secondary.opacity(0.35)
    }

    private var borderWidth: CGFloat {
        hasError || isSelected || (state != nil && state != .pending) ? 2.5 : 1
    }

    static func symbol(for state: RunState) -> String {
        switch state {
        case .pending: return "circle.dotted"
        case .running: return "arrow.triangle.2.circlepath"
        case .succeeded: return "checkmark.circle.fill"
        case .partiallySucceeded: return "exclamationmark.circle.fill"
        case .failed: return "xmark.octagon.fill"
        case .skipped: return "minus.circle"
        case .canceled: return "stop.circle"
        }
    }
}
