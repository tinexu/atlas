import AppKit
import AtlasCore
import SwiftUI

/// Explains every authorisation ATLAS can ask for, and why (spec 7.6).
struct PermissionsView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("ATLAS only does what you set up, and only with the access you grant. Everything stays on this Mac.")
                    .foregroundStyle(.secondary)

                ForEach(Permission.allCases) { permission in
                    PermissionCard(
                        permission: permission,
                        status: model.permissionStatuses[permission] ?? .notDetermined,
                        usedBy: usage(of: permission)
                    )
                }

                if Bundle.main.bundleIdentifier == nil {
                    Label {
                        Text("ATLAS is running as a bare executable (e.g. from `swift run`), so macOS can't attach notification permission to it. Build the app bundle with `scripts/build-app.sh` to use notifications.")
                    } icon: {
                        Image(systemName: "info.circle")
                    }
                    .font(.callout)
                    .padding(12)
                    .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
                }
            }
            .padding(24)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Permissions")
        .toolbar {
            Button { Task { await model.refreshPermissions() } } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
        }
        .task { await model.refreshPermissions() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            // Users usually grant access in System Settings and switch back.
            Task { await model.refreshPermissions() }
        }
    }

    private func usage(of permission: Permission) -> [String] {
        (model.registry?.descriptors ?? [])
            .filter { $0.permissions.contains(permission) }
            .map(\.title)
    }
}

private struct PermissionCard: View {
    @EnvironmentObject private var model: AppModel
    let permission: Permission
    let status: PermissionStatus
    let usedBy: [String]

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: permission.symbolName)
                .font(.title2)
                .foregroundStyle(Color.accentColor)
                .frame(width: 32)

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(permission.title).font(.headline)
                    Spacer()
                    Label(status.title, systemImage: "circle.fill")
                        .labelStyle(StatusDotLabelStyle(tint: status.tint))
                        .font(.callout)
                }
                Text(permission.explanation).foregroundStyle(.secondary)
                Text(usedBy.isEmpty
                     ? "No current action needs this."
                     : "Used by: \(usedBy.joined(separator: ", "))")
                    .font(.callout)

                HStack {
                    if status == .notDetermined {
                        Button("Request Access") { model.request(permission) }
                            .buttonStyle(.borderedProminent)
                    }
                    if permission.systemSettingsURL != nil {
                        Button("Open System Settings") { model.openSystemSettings(for: permission) }
                    }
                }
                .controlSize(.small)
            }
        }
        .padding(16)
        .background(.background, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator))
    }
}

private struct StatusDotLabelStyle: LabelStyle {
    let tint: Color

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) {
            configuration.icon.font(.system(size: 7)).foregroundStyle(tint)
            configuration.title
        }
    }
}
