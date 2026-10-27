import AtlasCore
import SwiftUI

/// Day and Week views: a calendar grid. Drag a block to reschedule, drag
/// its bottom edge to change its length, drop a Space from the list to
/// plan a session, double-click empty time to add a block. With a block
/// selected, ↑/↓ move it 15 minutes and ⇧↑/⇧↓ change its length (←/→ move
/// it a day in the week view).
struct CalendarGridView: View {
    @ObservedObject var model: TimeArchitectModel
    let columns: [Column]
    private let hourHeight: CGFloat = 52
    private let gutter: CGFloat = 48
    @FocusState private var focused: Bool

    struct Column: Identifiable, Hashable {
        let id: String
        let title: String
        let day: Date
        /// Lane filter (Day view with lanes).
        let lane: String?
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    GeometryReader { geometry in
                        let width = max(80, (geometry.size.width - gutter) / CGFloat(max(columns.count, 1)))
                        ZStack(alignment: .topLeading) {
                            hourLines(width: geometry.size.width)
                            ForEach(Array(columns.enumerated()), id: \.element.id) { index, column in
                                columnView(column, width: width)
                                    .frame(width: width, height: hourHeight * 24)
                                    .offset(x: gutter + CGFloat(index) * width)
                            }
                            nowLine(width: width)
                        }
                    }
                    .frame(height: hourHeight * 24)
                    .id("grid")
                    Color.clear.frame(height: 1).id("hour-\(Calendar.current.component(.hour, from: Date()))")
                }
                .onAppear { proxy.scrollTo("grid", anchor: UnitPoint(x: 0, y: max(0, CGFloat(Calendar.current.component(.hour, from: Date()) - 2) / 24))) }
            }
        }
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onKeyPress(keys: [.upArrow, .downArrow, .leftArrow, .rightArrow]) { press in
            guard let selected = model.selected, !selected.block.isExternal else { return .ignored }
            let resize = press.modifiers.contains(.shift)
            switch press.key {
            case .upArrow: model.move(selected, minutes: -15, resize: resize)
            case .downArrow: model.move(selected, minutes: 15, resize: resize)
            case .leftArrow where model.mode == .week && !resize: model.move(selected, minutes: -1_440)
            case .rightArrow where model.mode == .week && !resize: model.move(selected, minutes: 1_440)
            default: return .ignored
            }
            return .handled
        }
        .onKeyPress(.delete) {
            guard let selected = model.selected else { return .ignored }
            model.delete(selected)
            return .handled
        }
        .onTapGesture { focused = true }
    }

    private var header: some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: gutter, height: 1)
            ForEach(columns) { column in
                VStack(spacing: 1) {
                    Text(column.title).font(.callout.weight(Calendar.current.isDateInToday(column.day) ? .bold : .regular))
                    if let lane = column.lane, !lane.isEmpty { Text(lane).font(.caption2).foregroundStyle(.secondary) }
                }
                .frame(maxWidth: .infinity)
                .foregroundStyle(Calendar.current.isDateInToday(column.day) ? Color.accentColor : .primary)
            }
        }
        .padding(.vertical, 6)
    }

    private func hourLines(width: CGFloat) -> some View {
        ForEach(0..<24, id: \.self) { hour in
            HStack(alignment: .top, spacing: 4) {
                Text(hourLabel(hour)).font(.caption2).foregroundStyle(.secondary).frame(width: gutter - 6, alignment: .trailing)
                Rectangle().fill(Color.secondary.opacity(0.15)).frame(height: 1)
            }
            .frame(width: width, alignment: .leading)
            .offset(y: CGFloat(hour) * hourHeight - 6)
        }
    }

    private func hourLabel(_ hour: Int) -> String {
        let date = Calendar.current.date(bySettingHour: hour, minute: 0, second: 0, of: Date()) ?? Date()
        return date.formatted(.dateTime.hour())
    }

    @ViewBuilder
    private func nowLine(width: CGFloat) -> some View {
        let _ = model.revision
        if let index = columns.firstIndex(where: { Calendar.current.isDateInToday($0.day) }) {
            let minutes = Date().timeIntervalSince(Calendar.current.startOfDay(for: Date())) / 60
            let columnsToday = columns.filter { Calendar.current.isDateInToday($0.day) }.count
            HStack(spacing: 0) {
                Circle().fill(.red).frame(width: 8, height: 8)
                Rectangle().fill(.red).frame(width: width * CGFloat(columnsToday) - 8, height: 1.5)
            }
            .offset(x: gutter + CGFloat(index) * width - 4, y: CGFloat(minutes / 60) * hourHeight - 4)
            .allowsHitTesting(false)
        }
    }

    private func columnView(_ column: Column, width: CGFloat) -> some View {
        let items = model.occurrences(on: column.day).filter { column.lane == nil || model.lane(for: $0.block) == column.lane }
        return ZStack(alignment: .topLeading) {
            Rectangle()
                .fill(Calendar.current.isDateInToday(column.day) ? Color.accentColor.opacity(0.03) : Color.clear)
                .contentShape(Rectangle())
                .onTapGesture(count: 2, coordinateSpace: .local) { location in
                    model.create(at: time(at: location.y, on: column.day), minutes: 60)
                }
                .onTapGesture { model.selectedID = nil }
                .dropDestination(for: String.self) { items, location in
                    guard let item = items.first else { return false }
                    let start = time(at: location.y, on: column.day)
                    if item.hasPrefix("space:"), let id = UUID(uuidString: String(item.dropFirst(6))) {
                        model.create(at: start, minutes: Double(model.time.focus.settings.minutes(forSpace: id)), spaceID: id)
                        return true
                    }
                    return false
                }
            Rectangle().fill(Color.secondary.opacity(0.12)).frame(width: 1).frame(maxHeight: .infinity)
            ForEach(layout(items)) { placed in
                BlockView(model: model, occurrence: placed.occurrence, day: column.day, hourHeight: hourHeight,
                          dayWidth: width)
                    .frame(width: max(30, (width - 6) / CGFloat(placed.columns)) - 2)
                    .offset(x: 3 + CGFloat(placed.column) * ((width - 6) / CGFloat(placed.columns)))
            }
        }
    }

    private func time(at y: CGFloat, on day: Date) -> Date {
        let minutes = max(0, min(24 * 60 - 15, Double(y / hourHeight) * 60))
        return TimeArchitectModel.snap(day.addingTimeInterval(minutes * 60))
    }

    /// Side-by-side columns for overlapping blocks.
    struct Placed: Identifiable {
        let occurrence: Occurrence
        let column: Int
        let columns: Int
        var id: String { occurrence.id }
    }

    private func layout(_ items: [Occurrence]) -> [Placed] {
        var result: [Placed] = []
        var group: [(occurrence: Occurrence, column: Int)] = []
        var groupEnd = Date.distantPast
        func flush() {
            let count = (group.map(\.column).max() ?? 0) + 1
            result += group.map { Placed(occurrence: $0.occurrence, column: $0.column, columns: count) }
            group = []
        }
        for item in items.sorted(by: { $0.start < $1.start }) {
            if item.start >= groupEnd { flush() }
            let busy = Set(group.filter { $0.occurrence.end > item.start }.map(\.column))
            group.append((item, (0...).first { !busy.contains($0) }!))
            groupEnd = max(groupEnd, item.end)
        }
        flush()
        return result
    }
}

/// One block in the grid.
struct BlockView: View {
    @ObservedObject var model: TimeArchitectModel
    let occurrence: Occurrence
    let day: Date
    let hourHeight: CGFloat
    let dayWidth: CGFloat
    @State private var drag: CGSize = .zero
    @State private var resize: CGFloat = 0

    var body: some View {
        let block = occurrence.block
        let start = max(occurrence.start, day)
        let end = min(occurrence.end, day.addingTimeInterval(86_400))
        let top = CGFloat(start.timeIntervalSince(day) / 3_600) * hourHeight
        let height = max(18, CGFloat(end.timeIntervalSince(start) / 3_600) * hourHeight + resize)
        let selected = model.selectedID == occurrence.id
        let color = model.color(for: block)
        let state = model.time.schedule.state(of: occurrence).state
        let conflicted = model.isConflicted(occurrence)

        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 3) {
                Image(systemName: block.isExternal ? "calendar" : block.kind.symbolName).font(.caption2)
                Text(block.title).font(.caption.weight(.semibold)).lineLimit(1)
            }
            if height > 34 {
                Text("\(occurrence.start.formatted(date: .omitted, time: .shortened)) – \(occurrence.end.formatted(date: .omitted, time: .shortened))")
                    .font(.caption2).opacity(0.8).lineLimit(1)
            }
            if height > 50, state == .missed || state == .skipped {
                Text(state.title).font(.caption2.weight(.bold))
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 3)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .frame(height: height)
        .foregroundStyle(.white)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(block.isExternal ? color.opacity(0.45) : color.opacity(state == .missed || state == .skipped ? 0.4 : 0.85))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 5)
                .strokeBorder(conflicted ? Color.red : selected ? Color.white : Color.clear, style: StrokeStyle(lineWidth: conflicted || selected ? 2 : 0,
                                                                                                                 dash: block.isExternal ? [4, 3] : []))
        )
        .overlay(alignment: .bottom) {
            if !block.isExternal {
                // Resize handle.
                Rectangle().fill(Color.white.opacity(selected ? 0.5 : 0.001)).frame(height: 6)
                    .padding(.horizontal, 12)
                    .onHover { inside in if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() } }
                    .gesture(DragGesture(minimumDistance: 2).onChanged { resize = $0.translation.height }.onEnded { value in
                        let minutes = (Double(value.translation.height / hourHeight) * 60 / 15).rounded() * 15
                        resize = 0
                        if minutes != 0 { model.move(occurrence, minutes: minutes, resize: true) }
                    })
            }
        }
        .offset(x: drag.width, y: top + drag.height)
        .shadow(color: .black.opacity(selected ? 0.25 : 0), radius: 4, y: 2)
        .onTapGesture { model.selectedID = occurrence.id }
        .gesture(DragGesture(minimumDistance: 4).onChanged { value in
            guard !block.isExternal else { return }
            drag = CGSize(width: model.mode == .week ? value.translation.width : 0, height: value.translation.height)
        }.onEnded { value in
            guard !block.isExternal else {
                model.message = "“\(block.title)” is from your calendar, which ATLAS only reads. Allow writing to that calendar to move it here."
                return
            }
            let days = model.mode == .week ? (value.translation.width / dayWidth).rounded() : 0
            let minutes = (Double(value.translation.height / hourHeight) * 60 / 15).rounded() * 15 + Double(days) * 1_440
            drag = .zero
            model.selectedID = occurrence.id
            if minutes != 0 { model.move(occurrence, minutes: minutes) }
        })
        .help(block.isExternal ? "From your calendar (read-only)" : "Drag to move, drag the bottom edge to resize. Arrow keys move it 15 minutes.")
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(block.title), \(occurrence.start.formatted(date: .omitted, time: .shortened)) to \(occurrence.end.formatted(date: .omitted, time: .shortened))\(conflicted ? ", overlaps another block" : "")")
    }
}

/// Agenda: everything coming up, by day.
struct AgendaView: View {
    @ObservedObject var model: TimeArchitectModel

    var body: some View {
        List(selection: $model.selectedID) {
            ForEach(model.days, id: \.self) { day in
                let items = model.occurrences(on: day)
                Section(day.formatted(.dateTime.weekday(.wide).month().day())) {
                    if items.isEmpty {
                        Text("Nothing planned").foregroundStyle(.secondary)
                    }
                    ForEach(items) { occurrence in
                        HStack(spacing: 10) {
                            RoundedRectangle(cornerRadius: 2).fill(model.color(for: occurrence.block)).frame(width: 4, height: 30)
                            VStack(alignment: .leading, spacing: 2) {
                                HStack {
                                    Text(occurrence.block.title).fontWeight(.medium)
                                    if occurrence.block.isExternal { Image(systemName: "calendar").foregroundStyle(.secondary) }
                                    if model.isConflicted(occurrence) {
                                        Label("Overlaps", systemImage: "exclamationmark.triangle.fill").labelStyle(.iconOnly).foregroundStyle(.red)
                                    }
                                }
                                Text("\(occurrence.start.formatted(date: .omitted, time: .shortened)) – \(occurrence.end.formatted(date: .omitted, time: .shortened))\(model.space(occurrence.block.spaceID).map { " · \($0.name)" } ?? "")")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(model.time.schedule.state(of: occurrence).state.title).font(.caption).foregroundStyle(.secondary)
                        }
                        .tag(occurrence.id)
                    }
                }
            }
        }
    }
}
