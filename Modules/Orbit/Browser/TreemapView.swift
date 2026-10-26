import AtlasCore
import AtlasOrbit
import SwiftUI

/// Squarified treemap layout: rectangles proportional to size, kept as
/// close to square as possible.
enum Treemap {
    static func layout(_ sizes: [Double], in rect: CGRect) -> [CGRect] {
        let total = sizes.reduce(0, +)
        guard total > 0, rect.width > 0, rect.height > 0 else { return sizes.map { _ in .zero } }
        let scale = Double(rect.width * rect.height) / total
        let areas = sizes.map { $0 * scale }
        var result = [CGRect](repeating: .zero, count: sizes.count)
        var remaining = rect
        var index = 0
        while index < areas.count {
            let side = Double(min(remaining.width, remaining.height))
            var row: [Int] = [index]
            var worstSoFar = worst([areas[index]], side: side)
            var next = index + 1
            while next < areas.count {
                let candidate = (row + [next]).map { areas[$0] }
                let w = worst(candidate, side: side)
                if w > worstSoFar { break }
                worstSoFar = w
                row.append(next)
                next += 1
            }
            let rowArea = row.reduce(0) { $0 + areas[$1] }
            let horizontal = remaining.width >= remaining.height
            let thickness = rowArea / side
            var offset = 0.0
            for i in row {
                let length = areas[i] / max(thickness, 0.0001)
                result[i] = horizontal
                    ? CGRect(x: remaining.minX, y: remaining.minY + offset, width: thickness, height: length)
                    : CGRect(x: remaining.minX + offset, y: remaining.minY, width: length, height: thickness)
                offset += length
            }
            if horizontal {
                remaining = CGRect(x: remaining.minX + thickness, y: remaining.minY, width: max(0, remaining.width - thickness), height: remaining.height)
            } else {
                remaining = CGRect(x: remaining.minX, y: remaining.minY + thickness, width: remaining.width, height: max(0, remaining.height - thickness))
            }
            index = next
        }
        return result
    }

    /// Worst aspect ratio in a row laid along a side of length `side`.
    private static func worst(_ row: [Double], side: Double) -> Double {
        let sum = row.reduce(0, +)
        guard sum > 0, side > 0, let maxArea = row.max(), let minArea = row.min(), minArea > 0 else { return .infinity }
        let s2 = side * side
        return max(s2 * maxArea / (sum * sum), (sum * sum) / (s2 * minArea))
    }
}

/// Storage chart of the current folder: click to select, double-click a
/// folder to go into it.
struct TreemapView: View {
    @ObservedObject var model: OrbitViewModel
    let entries: [FileEntry]

    var body: some View {
        let items = Array(entries.filter { $0.size > 0 }.sorted { $0.size > $1.size }.prefix(300))
        GeometryReader { proxy in
            let rects = Treemap.layout(items.map { Double($0.size) }, in: CGRect(origin: .zero, size: proxy.size).insetBy(dx: 4, dy: 4))
            ZStack(alignment: .topLeading) {
                ForEach(Array(items.enumerated()), id: \.element.path) { index, entry in
                    let rect = rects[index]
                    let dimmed = model.highlight != .none && !model.highlight.matches(entry)
                    RoundedRectangle(cornerRadius: 3)
                        .fill(OrbitFormat.color(entry.category).opacity(dimmed ? 0.15 : (entry.isFolder ? 0.45 : 0.7)))
                        .overlay {
                            RoundedRectangle(cornerRadius: 3)
                                .strokeBorder(model.selection == entry.path ? Color.accentColor : Color.black.opacity(0.25),
                                              lineWidth: model.selection == entry.path ? 2 : 0.5)
                        }
                        .overlay(alignment: .topLeading) {
                            if rect.width > 70 && rect.height > 30 {
                                VStack(alignment: .leading, spacing: 0) {
                                    Text(entry.name).font(.caption.weight(.medium)).lineLimit(1)
                                    Text(OrbitFormat.bytes(entry.size)).font(.caption2).foregroundStyle(.secondary)
                                }
                                .padding(4)
                            }
                        }
                        .frame(width: max(0, rect.width - 1), height: max(0, rect.height - 1))
                        .offset(x: rect.minX, y: rect.minY)
                        .onTapGesture(count: 2) {
                            if entry.isFolder { model.enter(entry.path) } else { model.open(entry.path) }
                        }
                        .onTapGesture { model.selection = entry.path }
                        .help("\(entry.name) · \(OrbitFormat.bytes(entry.size))")
                        .accessibilityElement()
                        .accessibilityLabel("\(entry.name), \(OrbitFormat.bytes(entry.size))")
                        .accessibilityAddTraits(.isButton)
                }
            }
        }
        .overlay {
            if items.isEmpty { ContentUnavailableView("Nothing to chart", systemImage: "square.grid.3x3") }
        }
    }
}
