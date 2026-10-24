import AtlasCore
import AtlasSpaces
import AtlasSpacesUI
import SwiftUI

/// The Spaces section: the 3D world with a side panel, or the same Spaces
/// as a plain list. Everything the 3D view does is available in the list.
struct SpacesView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var spaces: SpacesModel

    var body: some View {
        Group {
            if !spaces.isAvailable {
                ContentUnavailableView(
                    "Spaces aren't available",
                    systemImage: "cube.transparent",
                    description: Text("ATLAS couldn't load your Spaces. Automations still work.")
                )
            } else if spaces.spaces.isEmpty {
                ContentUnavailableView {
                    Label("No Spaces yet", systemImage: "cube.transparent")
                } description: {
                    Text("A Space is a room for one activity. Selecting it opens the apps, pages and folders that activity needs.")
                } actions: {
                    NewSpaceMenu().fixedSize()
                }
            } else if spaces.viewMode == .world {
                HSplitView {
                    MissionControlView(
                        rooms: spaces.roomSnapshots,
                        selection: spaces.selectedSpaceID,
                        onSelect: { spaces.selectedSpaceID = $0 },
                        onActivate: { spaces.activate($0) },
                        onObject: { spaces.objectClicked($0) }
                    )
                    .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)

                    Group {
                        if let space = spaces.space(id: spaces.selectedSpaceID) {
                            SpaceDetailPanel(space: space)
                                .id(space.id)
                        } else {
                            ContentUnavailableView(
                                "Select a room",
                                systemImage: "hand.tap",
                                description: Text("Click a room to see what it opens. Double-click to activate it.")
                            )
                        }
                    }
                    .frame(minWidth: 280, idealWidth: 320, maxWidth: 400, maxHeight: .infinity)
                }
            } else {
                SpacesListView()
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if let offer = spaces.restoreOffer, let space = spaces.space(id: offer.spaceID) {
                RestoreOfferBanner(spaceName: space.name, snapshot: offer.snapshot)
            }
        }
        .navigationTitle("Spaces")
        .toolbar {
            ToolbarItem {
                NewSpaceMenu()
            }
            ToolbarItem {
                Picker("View", selection: $spaces.viewMode) {
                    ForEach(SpacesModel.ViewMode.allCases) { mode in
                        Label(mode.title, systemImage: mode.symbol).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .help("Show Spaces as a 3D world or as a list")
            }
        }
        .sheet(item: Binding(
            get: { spaces.space(id: spaces.editingSpaceID) },
            set: { spaces.editingSpaceID = $0?.id }
        )) { space in
            SpaceEditor(original: space)
                .environmentObject(model)
                .environmentObject(spaces)
        }
        .sheet(item: $spaces.editingObject) { object in
            ObjectEditor(original: object)
                .environmentObject(model)
                .environmentObject(spaces)
        }
        .confirmationDialog(
            "Delete “\(spaces.pendingDeletion?.name ?? "")”?",
            isPresented: Binding(
                get: { spaces.pendingDeletion != nil },
                set: { if !$0 { spaces.pendingDeletion = nil } }
            ),
            presenting: spaces.pendingDeletion
        ) { space in
            Button("Delete Space", role: .destructive) {
                spaces.delete(space.id, deleteWorkflows: false)
            }
            Button("Delete Space and Its Automations", role: .destructive) {
                spaces.delete(space.id, deleteWorkflows: true)
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Its room and profiles are removed. Its automations stay under Automations unless you delete them too. Automations another Space uses are always kept.")
        }
    }
}

/// "Restore where you left off" after coming back to a Space.
private struct RestoreOfferBanner: View {
    @EnvironmentObject private var spaces: SpacesModel
    let spaceName: String
    let snapshot: SessionSnapshot

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "arrow.uturn.backward.square.fill")
                .font(.title2)
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text("Pick up where you left off in \(spaceName)?").fontWeight(.medium)
                Text("Puts \(snapshot.rules.count) window\(snapshot.rules.count == 1 ? "" : "s") back and reopens apps. Unsaved work inside apps can't be restored.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Not Now") { spaces.restoreOffer = nil }
            Button("Restore") { spaces.restoreWhereLeftOff(snapshot) }
                .buttonStyle(.borderedProminent)
        }
        .padding(12)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }
}
