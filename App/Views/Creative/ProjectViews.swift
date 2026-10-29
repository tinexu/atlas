import AppKit
import AtlasCore
import AtlasCreative
import AtlasOrbitUI
import SwiftUI

// MARK: - Found projects

/// "Found 3 projects: …": confirm, rename or remove in one sheet.
struct ProjectSetupView: View {
    @EnvironmentObject private var creative: CreativeModel
    @State private var included: Set<String> = []
    @State private var names: [String: String] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let setup = creative.setup {
                Label(title(setup), systemImage: "paintpalette").font(.headline)
                if setup.suggestions.isEmpty {
                    emptyState
                } else {
                    ScrollView {
                        VStack(spacing: 8) {
                            ForEach(setup.suggestions) { suggestion in row(suggestion) }
                        }
                    }
                    .frame(maxHeight: 360)
                }
                HStack {
                    if setup.isFirstRun {
                        Button("Skip for Now") { creative.skipSetup() }
                    } else {
                        Button("Not Now") { creative.closeSetup() }
                    }
                    Spacer()
                    Button(addTitle) {
                        let chosen = setup.suggestions.filter { included.contains($0.id) }.map { suggestion -> ProjectSuggestion in
                            var copy = suggestion
                            if let name = names[suggestion.id]?.trimmingCharacters(in: .whitespaces), !name.isEmpty { copy.name = name }
                            return copy
                        }
                        creative.add(chosen)
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(included.isEmpty)
                }
            }
        }
        .padding(20)
        .frame(width: 520)
        .onAppear { included = Set(creative.setup?.suggestions.map(\.id) ?? []) }
        .onChange(of: creative.setup?.suggestions.map(\.id) ?? []) { _, ids in included = included.union(ids).intersection(ids) }
    }

    private var addTitle: String {
        included.count == 1 ? "Add 1 Project" : "Add \(included.count) Projects"
    }

    private func title(_ setup: CreativeModel.SetupRequest) -> String {
        let count = setup.suggestions.count
        if !setup.isFirstRun { return "New creative files: make \(count == 1 ? "it a project" : "them projects")?" }
        return count == 0 ? "No creative projects found yet" : "Found \(count) project\(count == 1 ? "" : "s")"
    }

    private func row(_ suggestion: ProjectSuggestion) -> some View {
        HStack(spacing: 10) {
            Toggle("", isOn: Binding(get: { included.contains(suggestion.id) },
                                     set: { if $0 { included.insert(suggestion.id) } else { included.remove(suggestion.id) } }))
                .labelsHidden()
            VStack(alignment: .leading, spacing: 2) {
                TextField("Name", text: Binding(get: { names[suggestion.id] ?? suggestion.name }, set: { names[suggestion.id] = $0 }))
                    .textFieldStyle(.plain)
                    .font(.body.weight(.semibold))
                Text(suggestion.summary { creative.appName($0) }).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Text(suggestion.newest.formatted(.relative(presentation: .named))).font(.caption).foregroundStyle(.secondary)
            Button("Ignore") { creative.ignore(suggestion) }.buttonStyle(.borderless)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.08)))
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("ATLAS looks for creative files (.blend, .psd, .afdesign, .sketch, .procreate, video projects…) in the folders you've added to Orbit, grouped by folder.")
                .fixedSize(horizontal: false, vertical: true)
            let creativeFolder = NSHomeDirectory() + "/Creative"
            if FileManager.default.fileExists(atPath: creativeFolder), !creative.isAuthorized(creativeFolder) {
                Text("Your ~/Creative folder isn't in Orbit yet. Add it, then put each project in its own folder there.")
                    .font(.callout).foregroundStyle(.secondary)
                Button("Add ~/Creative to Orbit") {
                    if creative.addFolderToOrbit?(creativeFolder) == true { creative.rescan() }
                }
            }
            Text("You can also add a project by hand in Space editor → Creative Studio → Projects.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .font(.callout)
    }
}

// MARK: - Switcher

/// Right-click the easel: every active project with its picture; pick one.
struct ProjectSwitcherView: View {
    @EnvironmentObject private var creative: CreativeModel
    private let columns = [GridItem(.adaptive(minimum: 120), spacing: 12)]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if creative.activeProjects.isEmpty {
                Text("No projects yet.").foregroundStyle(.secondary)
                Button("Find Projects…") { creative.closeSwitcher(); creative.findProjects() }
            } else {
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(creative.activeProjects) { project in tile(project) }
                }
            }
            HStack {
                if let current = creative.currentProject {
                    Toggle("Pin \(current.name)", isOn: Binding(get: { creative.settings.pinnedProjectID == current.id },
                                                                set: { creative.setPinned($0, current) }))
                        .toggleStyle(.checkbox)
                }
                Spacer()
                Button("Close") { creative.closeSwitcher() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(16)
        .frame(width: 420)
    }

    private func tile(_ project: Project) -> some View {
        let isCurrent = creative.currentProject?.id == project.id
        return Button {
            creative.makeCurrent(project)
            creative.closeSwitcher()
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: NSColor(atlasHex: project.color)).opacity(0.35))
                    if let image = creative.thumbnail(for: project) {
                        Image(nsImage: image).resizable().scaledToFit().padding(4)
                    } else {
                        Image(systemName: "paintbrush.pointed").font(.title2).foregroundStyle(.secondary)
                    }
                }
                .frame(height: 90)
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(isCurrent ? Color.accentColor : .clear, lineWidth: 2))
                Text(project.name).font(.callout.weight(.semibold)).lineLimit(1)
                Text(project.creative?.status.title ?? "").font(.caption).foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Settings → Projects

struct ProjectsSettingsView: View {
    @EnvironmentObject private var creative: CreativeModel
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var editing: Project?

    var body: some View {
        VStack(spacing: 0) {
            List {
                section("Active", creative.projects.filter { $0.creative?.isArchived == false && $0.creative?.status != .done })
                section("Done", creative.projects.filter { $0.creative?.isArchived == false && $0.creative?.status == .done })
                section("Archived", creative.projects.filter { $0.creative?.isArchived == true })
            }
            Divider()
            HStack {
                Button("Find Projects…") { creative.findProjects() }
                Button("New Project") {
                    editing = Project(name: "New Project", color: "", creative: CreativeInfo())
                }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(14)
        }
        .frame(minWidth: 520, idealWidth: 560, minHeight: 440)
        .sheet(item: $editing) { project in
            ProjectEditorView(original: project).environmentObject(creative).environmentObject(model)
        }
    }

    @ViewBuilder
    private func section(_ title: String, _ projects: [Project]) -> some View {
        if !projects.isEmpty {
            Section(title) {
                ForEach(projects) { project in
                    HStack(spacing: 10) {
                        Circle().fill(Color(nsColor: NSColor(atlasHex: project.color))).frame(width: 12, height: 12)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(project.name).fontWeight(.medium)
                                if creative.currentProject?.id == project.id {
                                    Text("current").font(.caption2).padding(.horizontal, 5).background(Capsule().fill(Color.accentColor.opacity(0.2)))
                                }
                            }
                            Text([project.creative?.kind.title, project.creative?.folder?.abbreviatedPath, creative.lastEdited(project)]
                                .compactMap { $0 }.joined(separator: " · "))
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        Button("Edit…") { editing = project }
                    }
                }
            }
        }
    }
}

/// Everything about one project.
struct ProjectEditorView: View {
    @EnvironmentObject private var creative: CreativeModel
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let original: Project
    @State private var draft: Project
    @State private var info: CreativeInfo
    @State private var confirmDelete = false

    init(original: Project) {
        self.original = original
        _draft = State(initialValue: original)
        _info = State(initialValue: original.creative ?? CreativeInfo())
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    TextField("Name", text: $draft.name)
                    Picker("Kind", selection: $info.kind) {
                        ForEach(CreativeInfo.Kind.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    Picker("Status", selection: $info.status) {
                        ForEach(CreativeInfo.Status.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    Picker("Colour", selection: $draft.color) {
                        ForEach(Array(zip(CreativeService.palette, CreativeService.paletteNames)), id: \.0) { hex, name in
                            Label { Text(name) } icon: { Image(systemName: "circle.fill").foregroundStyle(Color(nsColor: NSColor(atlasHex: hex))) }
                                .tag(hex)
                        }
                    }
                }
                Section {
                    pathRow("Folder", info.folder, choose: chooseFolder, clear: { info.folder = nil; info.folderBookmark = nil })
                    if let folder = info.folder, !creative.isAuthorized(folder) {
                        HStack {
                            Label("This folder isn't in Orbit, so ATLAS can't organize files there.", systemImage: "exclamationmark.triangle.fill")
                                .font(.caption).foregroundStyle(.orange)
                            Spacer()
                            Button("Add to Orbit") { _ = model.addFolderToOrbit(folder) }
                        }
                    }
                    pathRow("Exports", info.exportsFolder ?? info.resolvedExportsFolder.map { $0 + " (default)" }, choose: chooseExports,
                            clear: info.exportsFolder == nil ? nil : { info.exportsFolder = nil })
                    pathRow("Cover image", info.coverImage, choose: chooseCover, clear: info.coverImage == nil ? nil : { info.coverImage = nil })
                } header: {
                    Text("Folders")
                }
                Section {
                    ForEach(info.mainFiles, id: \.self) { file in
                        HStack {
                            Text((file as NSString).lastPathComponent)
                            Text(((file as NSString).deletingLastPathComponent).abbreviatedPath).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            Spacer()
                            Button { info.mainFiles.removeAll { $0 == file } } label: { Image(systemName: "minus.circle") }.buttonStyle(.borderless)
                        }
                    }
                    Button("Add Main File…", action: addMainFile)
                    ForEach(info.apps, id: \.self) { app in
                        HStack {
                            Text(creative.appName(app))
                            Spacer()
                            Button { info.apps.removeAll { $0 == app } } label: { Image(systemName: "minus.circle") }.buttonStyle(.borderless)
                        }
                    }
                    Button("Add App…", action: addApp)
                } header: {
                    Text("Opens")
                } footer: {
                    Text("Clicking the easel opens the main files in the first app, the folder in Finder and any Figma link. The monitor opens the first app.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Links") {
                    ForEach($info.links) { $link in
                        HStack {
                            Picker("", selection: $link.kind) {
                                ForEach(CreativeInfo.Link.Kind.allCases, id: \.self) { Text($0.title).tag($0) }
                            }
                            .labelsHidden()
                            .frame(width: 110)
                            TextField("https://…", text: $link.url)
                            Button { info.links.removeAll { $0.id == link.id } } label: { Image(systemName: "minus.circle") }.buttonStyle(.borderless)
                        }
                    }
                    Button("Add Link") { info.links.append(CreativeInfo.Link(kind: .figma, url: "")) }
                }
                Section {
                    Toggle("Pinned as the current project", isOn: Binding(
                        get: { creative.settings.pinnedProjectID == original.id },
                        set: { creative.setPinned($0, original) }))
                    Toggle("Archived", isOn: $info.isArchived)
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                if creative.projects.contains(where: { $0.id == original.id }) {
                    Button("Delete…", role: .destructive) { confirmDelete = true }
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    var project = draft
                    info.links.removeAll { $0.url.trimmingCharacters(in: .whitespaces).isEmpty }
                    project.creative = info
                    creative.save(project)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(draft.name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(14)
        }
        .frame(minWidth: 520, idealWidth: 580, minHeight: 600)
        .confirmationDialog("Delete “\(original.name)”?", isPresented: $confirmDelete) {
            Button("Delete Project", role: .destructive) {
                creative.delete(original)
                dismiss()
            }
        } message: {
            Text("Only the project is removed from ATLAS; its files stay where they are.")
        }
    }

    private func pathRow(_ title: String, _ path: String?, choose: @escaping () -> Void, clear: (() -> Void)?) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(path?.abbreviatedPath ?? "None").foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            Button("Choose…", action: choose)
            if let clear { Button { clear() } label: { Image(systemName: "xmark.circle") }.buttonStyle(.borderless) }
        }
    }

    private func chooseFolder() {
        guard let url = OrbitViewModel.chooseFolder(prompt: "Use Folder", startingAt: info.folder ?? NSHomeDirectory() + "/Creative") else { return }
        info.folder = url.path
        info.folderBookmark = nil
    }

    private func chooseExports() {
        guard let url = OrbitViewModel.chooseFolder(prompt: "Use Folder", startingAt: info.resolvedExportsFolder ?? info.folder) else { return }
        info.exportsFolder = url.path
    }

    private func chooseCover() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.directoryURL = info.folder.map { URL(fileURLWithPath: $0) }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        info.coverImage = url.path
    }

    private func addMainFile() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.treatsFilePackagesAsDirectories = false
        panel.allowsMultipleSelection = true
        panel.directoryURL = info.folder.map { URL(fileURLWithPath: $0) }
        guard panel.runModal() == .OK else { return }
        for url in panel.urls where !info.mainFiles.contains(url.path) {
            info.mainFiles.append(url.path)
            // Its app, and the folder, when not set yet.
            if let type = CreativeFiles.type(of: url.path) {
                for app in type.apps where !info.apps.contains(app) && NSWorkspace.shared.urlForApplication(withBundleIdentifier: app) != nil {
                    info.apps.append(app)
                }
                if info.kind == .other { info.kind = type.kind }
            }
            if info.folder == nil { info.folder = url.deletingLastPathComponent().path }
        }
    }

    private func addApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        guard panel.runModal() == .OK, let url = panel.url, let id = Bundle(url: url)?.bundleIdentifier, !info.apps.contains(id) else { return }
        info.apps.append(id)
    }
}
