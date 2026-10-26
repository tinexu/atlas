import AppKit
import AtlasCore
import AtlasOrbit
import SwiftUI

/// Every folder Orbit may read, with its size, file count, when it was last
/// indexed, and a Remove button that also deletes its index. Used in
/// Orbit's Folders tab and on the Permissions screen.
public struct LocationsList: View {
    @ObservedObject var model: OrbitViewModel
    @State private var removing: FileLocation?

    public init(model: OrbitViewModel) {
        self.model = model
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(model.locations) { location in
                row(location)
                Divider()
            }
            if model.locations.isEmpty {
                Text("No folders yet. Orbit reads only folders you add here; it never scans the whole disk.")
                    .foregroundStyle(.secondary)
            }
            HStack {
                Button {
                    if let url = OrbitViewModel.chooseFolder(prompt: "Add to Orbit") { model.addFolder(url) }
                } label: { Label("Add Folder…", systemImage: "plus") }
                ForEach(model.module.locations.suggestions, id: \.path) { suggestion in
                    Button("Add \(suggestion.name)") {
                        // The panel opens at the folder; choosing it is the permission.
                        if let url = OrbitViewModel.chooseFolder(prompt: "Add to Orbit", startingAt: suggestion.path) { model.addFolder(url) }
                    }
                }
                Spacer()
                if model.progress.values.contains(where: \.isActive) || model.isIndexingPaused {
                    Toggle("Pause indexing", isOn: Binding(get: { model.isIndexingPaused }, set: { model.setIndexingPaused($0) }))
                        .toggleStyle(.switch)
                        .controlSize(.small)
                }
            }
        }
        .confirmationDialog("Remove “\(removing?.name ?? "")” from Orbit?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
            Button("Remove Folder", role: .destructive) {
                if let removing { model.removeLocation(removing) }
                removing = nil
            }
        } message: {
            Text("Its index is deleted and ATLAS stops changing files there. The files themselves aren't touched.")
        }
    }

    private func row(_ location: FileLocation) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: location.indexState == .unavailable ? "externaldrive.badge.xmark" : "externaldrive.fill")
                .foregroundStyle(location.indexState == .unavailable ? .orange : .blue)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(location.name).fontWeight(.medium)
                Text(location.path.abbreviatedPath).font(.caption).foregroundStyle(.secondary)
                if let progress = model.progress[location.id], progress.isActive || progress.phase == .paused {
                    HStack(spacing: 6) {
                        if progress.isActive { ProgressView().controlSize(.mini) }
                        Text(progress.description).font(.caption)
                    }
                } else if location.indexState == .unavailable {
                    Text("Not available: the folder was moved, deleted or is on a disconnected drive.").font(.caption).foregroundStyle(.orange)
                } else {
                    Text("\(location.fileCount.formatted()) files · \(OrbitFormat.bytes(location.totalSize)) · indexed \(location.lastIndexedAt.map { $0.formatted(.relative(presentation: .named)) } ?? "never")")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button("Re-index") { model.reindex(location) }
                .controlSize(.small)
            Button("Remove…", role: .destructive) { removing = location }
                .controlSize(.small)
        }
    }
}

/// The Folders tab.
struct LocationsView: View {
    @ObservedObject var model: OrbitViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Orbit Folders").font(.title2.weight(.semibold))
                Text("Orbit reads only the folders you add, and ATLAS changes files only inside them. macOS asks once for each protected folder like Desktop, Documents or Downloads. Hidden files, .git, node_modules, .build and caches are skipped; apps and libraries count as single files.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                LocationsList(model: model)
            }
            .padding(24)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }
}
