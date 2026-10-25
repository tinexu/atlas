import AppKit
import AtlasCore
import AtlasSpaces
import AtlasSpacesUI
import AtlasFlow
import SwiftUI

/// Form editor for a Space: identity, look, transition and profiles. Each
/// profile links to an existing automation or creates a new one, which
/// opens in the Stage 01 workflow editor.
struct SpaceEditor: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var spaces: SpacesModel
    @Environment(\.dismiss) private var dismiss

    let original: Space
    @State private var draft: Space
    @State private var profiles: [ActivationProfile]
    @State private var removedProfileIDs: [UUID] = []
    @State private var customGroup = ""
    @State private var editingWorkflowID: UUID?
    @State private var editingObject: SpaceObject?

    init(original: Space) {
        self.original = original
        _draft = State(initialValue: original)
        _profiles = State(initialValue: [])
    }

    private var isCustomGroup: Bool { !draft.group.isPreset }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("Space") {
                    TextField("Name", text: $draft.name)
                    groupPicker
                    ColorPicker("Accent colour", selection: Binding(
                        get: { Color(nsColor: NSColor(atlasHex: draft.accentColor)) },
                        set: { draft.accentColor = NSColor($0).atlasHex }
                    ), supportsOpacity: false)
                    Picker("Room", selection: $draft.templateID) {
                        ForEach(SpaceTemplates.all) { template in
                            Label(template.name, systemImage: template.symbolName).tag(template.id)
                        }
                    }
                    Toggle("Pin to the front of its group", isOn: $draft.isPinned)
                }

                Section {
                    Picker("When activated", selection: $draft.transitionBehavior) {
                        ForEach(TransitionBehavior.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    Toggle("Remember windows when leaving this Space", isOn: $draft.snapshotOnLeave)
                } header: {
                    Text("Switching Spaces")
                } footer: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(transitionFooter)
                        Text("Remembering windows saves a snapshot when you switch away, so coming back offers “Restore where you left off”. It restores window positions and reopens apps, not unsaved work inside them. Needs Accessibility permission.")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                Section {
                    ForEach($profiles) { $profile in
                        ProfileRow(
                            profile: $profile,
                            canRemove: profiles.count > 1,
                            makeDefault: { makeDefault(profile.id) },
                            remove: { remove(profile.id) },
                            newAutomation: { createAutomation(for: profile.id) },
                            editAutomation: { editingWorkflowID = profile.workflowID }
                        )
                    }
                    addProfileMenu
                } header: {
                    Text("Activation profiles")
                } footer: {
                    Text("Each profile runs one automation, then arranges windows with its layout if it has one. The default runs when you activate the Space without choosing.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Room objects") {
                    let objects = spaces.objects(for: original.id)
                    if objects.isEmpty {
                        Text("No objects").foregroundStyle(.secondary)
                    }
                    ForEach(objects) { object in
                        HStack {
                            Label(object.displayName, systemImage: object.kind.symbolName)
                            Spacer()
                            Text(spaces.describeAssignment(of: object))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            Button("Edit…") { editingObject = object }
                        }
                    }
                    Text("Objects are saved as you edit them.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                Button("Delete Space…", role: .destructive) {
                    spaces.pendingDeletion = original
                    dismiss()
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(draft.name.trimmingCharacters(in: .whitespaces).isEmpty || !hasValidProfiles)
            }
            .padding(14)
        }
        .frame(minWidth: 560, idealWidth: 620, minHeight: 560, idealHeight: 680)
        .onAppear {
            profiles = spaces.profiles(for: original.id)
            customGroup = isCustomGroup ? draft.group.rawValue : ""
        }
        // Nested sheets need the environment passed again.
        .sheet(item: Binding(
            get: { editingWorkflowID.flatMap { id in model.workflow(id: id) } },
            set: { editingWorkflowID = $0?.id }
        )) { workflow in
            WorkflowEditorSheet(workflow: workflow)
                .environmentObject(model)
        }
        .sheet(item: $editingObject) { object in
            ObjectEditor(original: object)
                .environmentObject(model)
                .environmentObject(spaces)
        }
    }

    // MARK: - Pieces

    @ViewBuilder
    private var groupPicker: some View {
        Picker("Group", selection: Binding(
            get: { isCustomGroup ? "custom" : draft.group.rawValue },
            set: { choice in
                if choice == "custom" {
                    draft.group = SpaceGroup(customGroup.isEmpty ? "My Group" : customGroup)
                    if customGroup.isEmpty { customGroup = "My Group" }
                } else {
                    draft.group = SpaceGroup(choice)
                }
            }
        )) {
            ForEach(SpaceGroup.presets, id: \.self) { Text($0.rawValue).tag($0.rawValue) }
            Divider()
            Text("Custom…").tag("custom")
        }
        if isCustomGroup {
            TextField("Group name", text: Binding(
                get: { customGroup },
                set: { customGroup = $0; draft.group = SpaceGroup($0) }
            ))
        }
    }

    private var transitionFooter: String {
        switch draft.transitionBehavior {
        case .leaveRunning:
            return "The previous Space's apps stay as they are. ATLAS never quits apps when you switch Spaces."
        case .hidePrevious:
            return "Apps the previous Space opened are hidden (not quit), except ones this Space also uses. Bring them back from the Dock."
        case .minimizePrevious:
            return "The previous Space's windows are minimized to the Dock. This needs Accessibility permission. Apps are never quit."
        }
    }

    private var addProfileMenu: some View {
        Menu {
            Button("New Automation") { addProfile(workflowID: nil) }
            if !model.workflows.isEmpty {
                Divider()
                Section("Use an existing automation") {
                    ForEach(model.workflows) { workflow in
                        Button(workflow.name) { addProfile(workflowID: workflow.id) }
                    }
                }
            }
        } label: {
            Label("Add Profile", systemImage: "plus")
        }
        .fixedSize()
    }

    private var hasValidProfiles: Bool {
        !profiles.isEmpty && profiles.filter(\.isDefault).count == 1
    }

    // MARK: - Actions

    private func makeDefault(_ id: UUID) {
        for index in profiles.indices {
            profiles[index].isDefault = profiles[index].id == id
        }
    }

    private func remove(_ id: UUID) {
        guard profiles.count > 1 else { return }
        let wasDefault = profiles.first { $0.id == id }?.isDefault ?? false
        profiles.removeAll { $0.id == id }
        // Only profiles already saved need deleting; new ones just vanish.
        if spaces.profiles(for: original.id).contains(where: { $0.id == id }) {
            removedProfileIDs.append(id)
        }
        if wasDefault, let first = profiles.first?.id { makeDefault(first) }
    }

    private func addProfile(workflowID: UUID?) {
        let name = "Profile \(profiles.count + 1)"
        var profile = ActivationProfile(
            spaceID: original.id,
            name: name,
            workflowID: workflowID ?? UUID(),
            isDefault: profiles.isEmpty,
            position: profiles.count
        )
        if workflowID == nil, let created = newWorkflow(named: name) {
            profile.workflowID = created.id
            editingWorkflowID = created.id
        }
        profiles.append(profile)
    }

    private func createAutomation(for profileID: UUID) {
        guard let index = profiles.firstIndex(where: { $0.id == profileID }),
              let created = newWorkflow(named: profiles[index].name)
        else { return }
        profiles[index].workflowID = created.id
        editingWorkflowID = created.id
    }

    /// New automations start with one step so there's something to edit.
    private func newWorkflow(named profileName: String) -> Workflow? {
        model.save(Workflow(
            name: "\(draft.name) · \(profileName)",
            summary: "Runs when \(draft.name) is activated with the \(profileName) profile.",
            failurePolicy: .continueOnFailure,
            steps: [WorkflowStep(actionID: LaunchApplicationAction.id, parameters: ["bundleId": "com.apple.Notes"])]
        ))
    }

    private func save() {
        spaces.save(draft)
        spaces.saveProfiles(profiles, removing: removedProfileIDs)
        dismiss()
    }
}

private struct ProfileRow: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var spaces: SpacesModel
    @Binding var profile: ActivationProfile
    let canRemove: Bool
    let makeDefault: () -> Void
    let remove: () -> Void
    let newAutomation: () -> Void
    let editAutomation: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                TextField("Profile name", text: $profile.name)
                    .textFieldStyle(.roundedBorder)
                Toggle("Default", isOn: Binding(
                    get: { profile.isDefault },
                    set: { if $0 { makeDefault() } }
                ))
                .disabled(profile.isDefault)
                .help(profile.isDefault ? "Runs when the Space is activated without choosing a profile" : "Make this the default")
                Button(role: .destructive, action: remove) { Image(systemName: "trash") }
                    .buttonStyle(.borderless)
                    .disabled(!canRemove)
                    .help(canRemove ? "Remove profile (its automation is kept)" : "A Space needs at least one profile")
            }
            HStack {
                Picker("Automation", selection: $profile.workflowID) {
                    if model.workflow(id: profile.workflowID) == nil {
                        Text("Missing automation").tag(profile.workflowID)
                    }
                    ForEach(model.workflows) { workflow in
                        Text(workflow.name).tag(workflow.id)
                    }
                }
                Button("Edit…", action: editAutomation)
                    .disabled(model.workflow(id: profile.workflowID) == nil)
                Button("New", action: newAutomation)
                    .help("Create a new automation for this profile")
            }
            Picker("Window layout", selection: $profile.windowLayoutID) {
                Text("Don't arrange windows").tag(UUID?.none)
                if let id = profile.windowLayoutID, spaces.layouts[id] == nil {
                    Text("Missing layout").tag(Optional(id))
                }
                if !spaces.layouts.isEmpty { Divider() }
                ForEach(spaces.sortedLayouts) { layout in
                    Text(layout.name).tag(Optional(layout.id))
                }
            }
            .help("Applied after the automation, as the activation's last step. Make layouts under Windows.")
        }
        .padding(.vertical, 4)
    }
}

/// The Stage 01 workflow editor in a sheet, for editing a profile's
/// automation without leaving the Space editor.
struct WorkflowEditorSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let workflow: Workflow

    var body: some View {
        VStack(spacing: 0) {
            let current = model.workflow(id: workflow.id) ?? workflow
            if current.isLinear {
                WorkflowEditor(original: current)
                    .id(workflow.id)
            } else if let editor = model.editor(for: current) {
                FlowEditorView(model: editor)
            }
            Divider()
            HStack {
                Text("Save your changes before closing.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(12)
        }
        .frame(minWidth: 900, idealWidth: 1100, minHeight: 600, idealHeight: 720)
    }
}
