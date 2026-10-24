import AtlasCore
import AtlasSpaces
import SwiftUI

/// Every Space as a plain list, grouped like the 3D world. Everything the
/// 3D view can do is available here, so 3D is never required.
struct SpacesListView: View {
    @EnvironmentObject private var spaces: SpacesModel

    var body: some View {
        List(selection: $spaces.selectedSpaceID) {
            ForEach(spaces.groupedSpaces, id: \.group) { entry in
                Section(entry.group.rawValue) {
                    ForEach(entry.spaces) { space in
                        SpaceListRow(space: space)
                            .tag(space.id)
                            .contextMenu { SpaceCommandsMenu(space: space) }
                    }
                    .onMove { source, destination in
                        move(in: entry.spaces, from: source, to: destination)
                    }
                }
            }
        }
        .listStyle(.inset)
    }

    /// Translates a drag within one group into a library move.
    private func move(in row: [Space], from source: IndexSet, to destination: Int) {
        guard let from = source.first else { return }
        let offset = destination > from ? destination - from - 1 : destination - from
        guard offset != 0 else { return }
        spaces.move(row[from].id, by: offset)
    }
}

private struct SpaceListRow: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var spaces: SpacesModel
    let space: Space

    var body: some View {
        let status = spaces.status(for: space.id)
        let apps = spaces.apps(for: space.id)
        HStack(spacing: 12) {
            AccentDot(hex: space.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(space.name).fontWeight(.medium)
                    if space.isPinned {
                        Image(systemName: "pin.fill").font(.caption2).foregroundStyle(.secondary)
                    }
                    if space.id == spaces.activeSpaceID {
                        Pill(text: "Active", tint: .green)
                    }
                }
                Text(apps.isEmpty
                     ? spaces.template(for: space).name
                     : "\(apps.filter(\.isRunning).count) of \(apps.count) apps running · \(apps.map(\.name).joined(separator: ", "))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            SpaceStatusBadge(status: status)
            ProfilePicker(spaceID: space.id)
                .labelsHidden()
                .frame(width: 170)
            Button {
                spaces.activate(space.id)
            } label: {
                Label("Activate", systemImage: "play.fill")
            }
            .disabled(status == .activating || model.isPaused)
            Button { spaces.editingSpaceID = space.id } label: {
                Image(systemName: "slider.horizontal.3")
            }
            .buttonStyle(.borderless)
            .help("Edit Space")
        }
        .padding(.vertical, 4)
    }
}
