import AppKit
import AtlasCore
import AtlasSpaces
import AtlasSpacesUI
import SwiftUI

extension SpaceStatus {
    var tint: Color {
        switch self {
        case .inactive: return .secondary
        case .activating: return .accentColor
        case .ready: return .green
        case .partiallyReady: return .orange
        case .failed: return .red
        }
    }
}

struct SpaceStatusBadge: View {
    let status: SpaceStatus

    var body: some View {
        Label(status.title, systemImage: status.symbolName)
            .font(.caption.weight(.medium))
            .foregroundStyle(status.tint)
            .symbolEffect(.pulse, isActive: status == .activating)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(status.tint.opacity(0.12), in: Capsule())
            .help(status.detail ?? status.title)
    }
}

struct AccentDot: View {
    let hex: String
    var size: CGFloat = 12

    var body: some View {
        Circle()
            .fill(Color(nsColor: NSColor(atlasHex: hex)))
            .frame(width: size, height: size)
            .overlay(Circle().strokeBorder(.black.opacity(0.15)))
    }
}

/// "Terminal ● running" with the app's icon.
struct AppPresenceRow: View {
    let app: SpacesModel.AppPresence

    var body: some View {
        HStack(spacing: 8) {
            if let icon = Pickers.applicationIcon(for: app.bundleID) {
                Image(nsImage: icon).resizable().frame(width: 18, height: 18)
            } else {
                Image(systemName: "app.dashed").frame(width: 18, height: 18)
            }
            Text(app.name)
            Spacer()
            Circle()
                .fill(app.isRunning ? Color.green : Color.secondary.opacity(0.35))
                .frame(width: 7, height: 7)
            Text(app.isRunning ? "Running" : "Not running")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Picks one of a Space's activation profiles.
struct ProfilePicker: View {
    @EnvironmentObject private var spaces: SpacesModel
    let spaceID: UUID

    var body: some View {
        let profiles = spaces.profiles(for: spaceID)
        Picker("Profile", selection: Binding(
            get: { spaces.selectedProfile(for: spaceID)?.id },
            set: { spaces.chosenProfileIDs[spaceID] = $0 }
        )) {
            ForEach(profiles) { profile in
                Text(profile.isDefault ? "\(profile.name) (default)" : profile.name).tag(Optional(profile.id))
            }
        }
        .disabled(profiles.count < 2)
    }
}

/// The same commands wherever a Space is shown: 3D panel, list row, menus.
struct SpaceCommandsMenu: View {
    @EnvironmentObject private var spaces: SpacesModel
    let space: Space

    var body: some View {
        Button("Activate") { spaces.activate(space.id) }
        Button("Edit…") { spaces.editingSpaceID = space.id }
        Button("Duplicate") { spaces.duplicate(space.id) }
        Button(space.isPinned ? "Unpin" : "Pin to Front of Group") { spaces.togglePinned(space.id) }
        Divider()
        Button("Move Earlier") { spaces.move(space.id, by: -1) }
            .disabled(!spaces.canMove(space.id, by: -1))
        Button("Move Later") { spaces.move(space.id, by: 1) }
            .disabled(!spaces.canMove(space.id, by: 1))
        Divider()
        Button("Delete…", role: .destructive) { spaces.pendingDeletion = space }
    }
}

/// "New Space" menu listing the templates.
struct NewSpaceMenu: View {
    @EnvironmentObject private var spaces: SpacesModel

    var body: some View {
        Menu {
            ForEach(SpaceTemplates.all) { template in
                Button {
                    spaces.createSpace(from: template)
                } label: {
                    Label(template.name, systemImage: template.symbolName)
                }
            }
        } label: {
            Label("New Space", systemImage: "plus")
        }
        .disabled(!spaces.isAvailable)
        .help("Create a Space from a template")
    }
}
