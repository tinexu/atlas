import AtlasCore
import AtlasSpaces
import SwiftUI

/// Side panel for the selected room: what it opens, what's running, how the
/// last activation went, and its objects.
struct SpaceDetailPanel: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var spaces: SpacesModel
    let space: Space

    var body: some View {
        let status = spaces.status(for: space.id)
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header(status: status)
                    profileSection
                    appsSection
                    if let run = spaces.lastRuns[space.id] {
                        lastRunSection(run)
                    }
                    objectsSection
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            footer(status: status)
        }
    }

    private func header(status: SpaceStatus) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                AccentDot(hex: space.accentColor, size: 14)
                Text(space.name)
                    .font(.title2.weight(.semibold))
                    .lineLimit(2)
                if space.isPinned {
                    Image(systemName: "pin.fill").foregroundStyle(.secondary).help("Pinned")
                }
            }
            HStack(spacing: 6) {
                Pill(text: space.group.rawValue, tint: .accentColor)
                Pill(text: spaces.template(for: space).name)
                if space.id == spaces.activeSpaceID {
                    Pill(text: "Active", tint: .green)
                }
            }
            SpaceStatusBadge(status: status)
            if let detail = status.detail {
                Text(detail).font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var profileSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Profile").font(.headline)
            ProfilePicker(spaceID: space.id)
                .labelsHidden()
            if let profile = spaces.selectedProfile(for: space.id) {
                if let workflow = spaces.workflows[profile.workflowID] {
                    Button("Open “\(workflow.name)”") {
                        model.selectedWorkflowID = workflow.id
                        model.section = .automations
                    }
                    .buttonStyle(.link)
                    .font(.callout)
                } else {
                    Label("This profile's automation was deleted. Choose another in Edit.", systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(.orange)
                }
            }
        }
    }

    @ViewBuilder
    private var appsSection: some View {
        let apps = spaces.apps(for: space.id)
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Apps").font(.headline)
                Spacer()
                if !apps.isEmpty {
                    Text("\(apps.filter(\.isRunning).count) of \(apps.count) running")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if apps.isEmpty {
                Text("This profile doesn't open any apps.").font(.callout).foregroundStyle(.secondary)
            }
            ForEach(apps) { AppPresenceRow(app: $0) }
        }
    }

    private func lastRunSection(_ run: WorkflowRun) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Last activation").font(.headline)
                StateBadge(state: run.state)
                Spacer()
                Text(run.startedAt, style: .relative)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(run.steps) { StepResultRow(step: $0) }
        }
        .padding(12)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder
    private var objectsSection: some View {
        let objects = spaces.objects(for: space.id)
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Room objects").font(.headline)
                Spacer()
                Menu {
                    ForEach(SpaceObjectKind.allCases, id: \.self) { kind in
                        Button { spaces.addObject(kind, to: space.id) } label: {
                            Label(kind.title, systemImage: kind.symbolName)
                        }
                    }
                } label: {
                    Image(systemName: "plus")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Add an object to this room")
            }
            ForEach(objects) { object in
                HStack(spacing: 8) {
                    Image(systemName: object.kind.symbolName)
                        .frame(width: 18)
                        .foregroundStyle(Color.accentColor)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(object.displayName)
                        Text(spaces.describeAssignment(of: object))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                    if object.hasAssignment {
                        Button { spaces.run(object) } label: { Image(systemName: "play.fill") }
                            .buttonStyle(.borderless)
                            .help("Run what this object does")
                    }
                    Button { spaces.editingObject = object } label: { Image(systemName: "slider.horizontal.3") }
                        .buttonStyle(.borderless)
                        .help("Edit object")
                }
            }
        }
    }

    private func footer(status: SpaceStatus) -> some View {
        HStack(spacing: 8) {
            Menu {
                SpaceCommandsMenu(space: space)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            Button("Edit…") { spaces.editingSpaceID = space.id }
            Spacer()
            Button {
                spaces.activate(space.id)
            } label: {
                Label(status == .activating ? "Activating…" : "Activate", systemImage: "play.fill")
            }
            // Return activates the selected Space.
            .keyboardShortcut(.defaultAction)
            .disabled(status == .activating || model.isPaused)
            .help(model.isPaused ? "Automations are paused" : "Open this Space's apps (Return)")
        }
        .padding(12)
        .background(.bar)
    }
}
