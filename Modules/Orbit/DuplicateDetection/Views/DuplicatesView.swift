import AppKit
import AtlasCore
import AtlasOrbit
import SwiftUI

/// Exact duplicates, grouped by set. You pick which copies to keep; the
/// rest go to the Trash after a confirmation. Nothing is removed on its own.
struct DuplicatesView: View {
    @ObservedObject var model: OrbitViewModel
    @State private var minimumMB: Double = 1
    /// Paths chosen to go to the Trash. By default every copy but the oldest.
    @State private var toTrash = Set<String>()

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if model.duplicateSets.isEmpty {
                ContentUnavailableView {
                    Label(model.lastDuplicateScan == nil ? "Find exact duplicates" : "No duplicates found", systemImage: "doc.on.doc")
                } description: {
                    Text("Files count as duplicates only when every byte matches. Similar photos or documents are never listed.")
                }
                .frame(maxHeight: .infinity)
            } else {
                List {
                    ForEach(model.duplicateSets) { set in
                        Section {
                            ForEach(set.files) { file in
                                fileRow(file, in: set)
                            }
                        } header: {
                            HStack {
                                Text("\(set.files.count) copies · \(OrbitFormat.bytes(set.size)) each")
                                Spacer()
                                Text("\(OrbitFormat.bytes(set.recoverable)) recoverable").foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            if !toTrash.isEmpty {
                Divider()
                HStack {
                    Text("\(toTrash.count) cop\(toTrash.count == 1 ? "y" : "ies") selected · \(OrbitFormat.bytes(selectedBytes))")
                    Spacer()
                    Button("Clear") { toTrash = [] }
                    Button("Move to Trash…", role: .destructive) {
                        model.requestTrash(Array(toTrash).sorted(), source: "Find Duplicates")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                }
                .padding(12)
            }
        }
        .onChange(of: model.duplicateSets) { _, sets in
            let present = Set(sets.flatMap { $0.files.map(\.path) })
            toTrash = toTrash.intersection(present)
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            if let progress = model.duplicateProgress {
                ProgressView(value: progress.total > 0 ? Double(progress.checked) / Double(progress.total) : nil)
                    .frame(width: 160)
                Text(progress.total > 0 ? "\(progress.phase)… \(progress.checked) of \(progress.total)" : progress.phase + "…")
                    .font(.callout)
                Button("Cancel") { model.cancelDuplicateScan() }
            } else {
                Button {
                    toTrash = []
                    model.findDuplicates(minimumSize: Int64(minimumMB * 1_000_000))
                } label: { Label("Find Duplicates", systemImage: "magnifyingglass") }
                .buttonStyle(.borderedProminent)
                .disabled(model.locations.isEmpty)
                Picker("Ignore files smaller than", selection: $minimumMB) {
                    Text("Any size").tag(0.0)
                    Text("1 MB").tag(1.0)
                    Text("10 MB").tag(10.0)
                    Text("100 MB").tag(100.0)
                }
                .fixedSize()
                if !model.duplicateSets.isEmpty {
                    Button("Select all but the oldest") {
                        toTrash = Set(model.duplicateSets.flatMap { $0.files.dropFirst().map(\.path) })
                    }
                }
            }
            Spacer()
            if !model.duplicateSets.isEmpty {
                Text("\(model.duplicateSets.count) sets · \(OrbitFormat.bytes(model.duplicateSets.reduce(0) { $0 + $1.recoverable })) recoverable")
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
    }

    private var selectedBytes: Int64 {
        model.duplicateSets.flatMap(\.files).filter { toTrash.contains($0.path) }.reduce(0) { $0 + $1.size }
    }

    private func fileRow(_ file: FileEntry, in set: DuplicateSet) -> some View {
        let keepingNone = set.files.allSatisfy { toTrash.contains($0.path) || $0.path == file.path } && !toTrash.contains(file.path)
        return HStack(spacing: 10) {
            Toggle("Move to Trash", isOn: Binding(
                get: { toTrash.contains(file.path) },
                set: { on in if on { toTrash.insert(file.path) } else { toTrash.remove(file.path) } }
            ))
            .labelsHidden()
            // At least one copy always stays.
            .disabled(keepingNone)
            .help(keepingNone ? "Keep at least one copy" : "Move this copy to the Trash")
            Image(nsImage: NSWorkspace.shared.icon(forFile: file.path)).resizable().frame(width: 18, height: 18)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(file.name)
                    if file.path == set.oldest?.path { tag("Oldest", .blue) }
                    if file.path == set.newest?.path { tag("Newest", .green) }
                }
                Text(file.parent.abbreviatedPath).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            Text(OrbitFormat.date(file.createdAt ?? file.modifiedAt)).font(.caption).foregroundStyle(.secondary)
            Button { model.showInFinder(file.path) } label: { Image(systemName: "folder") }.buttonStyle(.borderless).help("Show in Finder")
        }
    }

    private func tag(_ text: String, _ color: Color) -> some View {
        Text(text).font(.caption2).padding(.horizontal, 5).padding(.vertical, 1).background(color.opacity(0.18), in: Capsule())
    }
}
