import AtlasCore
import SwiftUI

/// Debug: the most recent EventBus events, newest first.
struct EventLogView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var events: [AtlasEvent] = []
    @State private var filter = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Recent Events").font(.headline)
                TextField("Filter, e.g. workflow. or focus", text: $filter).textFieldStyle(.roundedBorder).frame(maxWidth: 260)
                Spacer()
                Button("Refresh", action: reload).keyboardShortcut("r")
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(12)
            Divider()
            List(events.filter { filter.isEmpty || $0.name.localizedCaseInsensitiveContains(filter) }.reversed()) { event in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(event.name).font(.system(.callout, design: .monospaced).weight(.semibold))
                        Spacer()
                        Text(event.timestamp.formatted(date: .omitted, time: .standard)).font(.caption).foregroundStyle(.secondary)
                    }
                    Text(event.payload.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value.displayString)" }.joined(separator: "  "))
                        .font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary).lineLimit(3).textSelection(.enabled)
                }
            }
        }
        .frame(width: 760, height: 520)
        .onAppear(perform: reload)
    }

    private func reload() {
        events = model.core?.events.recentEvents ?? []
    }
}
