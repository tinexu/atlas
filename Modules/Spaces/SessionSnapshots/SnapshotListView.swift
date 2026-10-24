import AtlasCore
import SwiftUI

/// Saved session snapshots: save one now, restore, turn one into an
/// editable layout, or delete. Says plainly what a snapshot can't restore.
public struct SnapshotListView: View {
    @ObservedObject var model: WindowManagerModel
    /// Names Spaces for automatic snapshots.
    let spaceName: (UUID) -> String?
    @State private var naming = false
    @State private var newName = ""
    @State private var pendingDeletion: SessionSnapshot?

    public init(model: WindowManagerModel, spaceName: @escaping (UUID) -> String?) {
        self.model = model
        self.spaceName = spaceName
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Session Snapshots").font(.headline)
                Spacer()
                Button {
                    newName = ""
                    naming = true
                } label: {
                    Label("Save Snapshot…", systemImage: "square.and.arrow.down.on.square")
                }
                .disabled(model.isBusy)
            }
            SnapshotLimitsNote()

            if model.snapshots.isEmpty {
                Text("No snapshots yet. ATLAS also saves one when you leave a Space, so you can pick up where you left off.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            ForEach(model.snapshots) { snapshot in
                SnapshotRow(snapshot: snapshot, spaceName: snapshot.spaceID.flatMap(spaceName))
                    .contextMenu {
                        Button("Restore") { model.restore(snapshot) }
                        Button("Save as Layout") { model.makeLayout(from: snapshot) }
                        Divider()
                        Button("Delete…", role: .destructive) { pendingDeletion = snapshot }
                    }
                    .overlay(alignment: .trailing) {
                        HStack {
                            Button("Restore") { model.restore(snapshot) }
                                .disabled(model.isBusy)
                            Menu {
                                Button("Save as Layout") { model.makeLayout(from: snapshot) }
                                Button("Delete…", role: .destructive) { pendingDeletion = snapshot }
                            } label: {
                                Image(systemName: "ellipsis.circle")
                            }
                            .menuStyle(.borderlessButton)
                            .menuIndicator(.hidden)
                            .fixedSize()
                        }
                    }
                Divider()
            }
        }
        .alert("Save a snapshot", isPresented: $naming) {
            TextField("Name (optional)", text: $newName)
            Button("Save") { model.saveSnapshot(named: newName) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Records every window and running app.")
        }
        .confirmationDialog(
            "Delete “\(pendingDeletion?.name ?? "")”?",
            isPresented: Binding(get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } }),
            presenting: pendingDeletion
        ) { snapshot in
            Button("Delete Snapshot", role: .destructive) { model.delete(snapshot) }
            Button("Cancel", role: .cancel) {}
        }
    }
}

/// Snapshots restore window positions and reopen apps, nothing more.
public struct SnapshotLimitsNote: View {
    public init() {}

    public var body: some View {
        Label("Snapshots put windows back and reopen apps. They don't restore unsaved work, tabs or documents inside apps.",
              systemImage: "info.circle")
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}

private struct SnapshotRow: View {
    let snapshot: SessionSnapshot
    let spaceName: String?

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: snapshot.isAutomatic ? "clock.arrow.circlepath" : "camera")
                .foregroundStyle(Color.accentColor)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(snapshot.name).fontWeight(.medium)
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 140)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    private var detail: String {
        var parts = [snapshot.createdAt.formatted(date: .abbreviated, time: .shortened)]
        parts.append("\(snapshot.rules.count) window\(snapshot.rules.count == 1 ? "" : "s")")
        parts.append("\(snapshot.runningApps.count) app\(snapshot.runningApps.count == 1 ? "" : "s")")
        if let spaceName { parts.append(snapshot.isAutomatic ? "left \(spaceName)" : spaceName) }
        if let profile = snapshot.displayProfile { parts.append(profile.name) }
        return parts.joined(separator: " · ")
    }
}
