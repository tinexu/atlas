import AppKit
import AtlasCore
import AtlasOrbit
import SwiftUI
import UniformTypeIdentifiers

/// Projects: files and folders from anywhere, grouped without moving them.
struct ProjectsView: View {
    @ObservedObject var model: OrbitViewModel
    @State private var newName = ""
    @State private var deleting: Project?

    private var selected: Project? { model.projects.first { $0.id == model.selectedProjectID } }

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                List(selection: $model.selectedProjectID) {
                    ForEach(model.projects) { project in
                        HStack {
                            Image(systemName: "folder.badge.person.crop").foregroundStyle(.purple)
                            Text(project.name)
                            Spacer()
                            let broken = project.links.filter(\.isBroken).count
                            if broken > 0 {
                                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                                    .help("\(broken) broken link\(broken == 1 ? "" : "s")")
                            }
                            Text("\(project.links.count)").foregroundStyle(.secondary)
                        }
                        .tag(project.id)
                        .contextMenu { Button("Delete…", role: .destructive) { deleting = project } }
                    }
                }
                Divider()
                HStack {
                    TextField("New project", text: $newName).onSubmit(create)
                    Button(action: create) { Image(systemName: "plus") }
                }
                .padding(8)
            }
            .frame(minWidth: 200, idealWidth: 240, maxWidth: 320)

            Group {
                if let project = selected {
                    ProjectDetail(model: model, project: project)
                        .id(project.id)
                } else {
                    ContentUnavailableView {
                        Label("No project selected", systemImage: "folder.badge.person.crop")
                    } description: {
                        Text("A project links a repo, specs, notes and downloads from anywhere without moving them. Link one to a Space to open its key items when you switch to it.")
                    }
                }
            }
            .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
        }
        .confirmationDialog("Delete “\(deleting?.name ?? "")”?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("Delete Project", role: .destructive) {
                if let deleting { model.delete(deleting) }
                deleting = nil
            }
        } message: {
            Text("Only the project is deleted. The files it links to stay where they are.")
        }
    }

    private func create() {
        model.createProject(named: newName)
        newName = ""
    }
}

private struct ProjectDetail: View {
    @ObservedObject var model: OrbitViewModel
    @State var project: Project
    @State private var repairing: ProjectLink?
    @State private var dropTargeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                Section {
                    TextField("Name", text: $project.name).onSubmit { model.save(project) }
                    Picker("Space", selection: Binding(get: { project.spaceID }, set: { project.spaceID = $0; model.save(project) })) {
                        Text("None").tag(UUID?.none)
                        ForEach(model.spaces(), id: \.id) { space in Text(space.name).tag(Optional(space.id)) }
                    }
                    Picker("When the Space activates", selection: Binding(get: { project.spaceBehavior },
                                                                         set: { project.spaceBehavior = $0; model.save(project) })) {
                        ForEach(Project.SpaceBehavior.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .disabled(project.spaceID == nil)
                }
                Section {
                    ForEach(project.links) { link in linkRow(link) }
                    if project.links.isEmpty {
                        Text("Drop files or folders here, or use Add Items.").foregroundStyle(.secondary)
                    }
                } header: {
                    HStack {
                        Text("Items")
                        Spacer()
                        Button("Add Items…") {
                            let urls = OrbitViewModel.chooseItems()
                            if !urls.isEmpty { model.add(urls.map(\.path), to: project) }
                        }
                        .buttonStyle(.borderless)
                    }
                } footer: {
                    Text("Key items (★) are opened or shown when the linked Space activates. Links follow files the indexer sees move.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
        }
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            Task {
                var paths: [String] = []
                for provider in providers {
                    if let url = try? await provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) as? Data,
                       let fileURL = URL(dataRepresentation: url, relativeTo: nil) {
                        paths.append(fileURL.path)
                    }
                }
                if !paths.isEmpty { await MainActor.run { model.add(paths, to: project) } }
            }
            return true
        }
        .overlay { if dropTargeted { RoundedRectangle(cornerRadius: 8).strokeBorder(Color.accentColor, lineWidth: 2).padding(4) } }
        .onChange(of: model.projects) { _, projects in
            if let fresh = projects.first(where: { $0.id == project.id }) { project = fresh }
        }
        .sheet(item: $repairing) { link in
            RepairSheet(model: model, project: project, link: link)
        }
    }

    private func linkRow(_ link: ProjectLink) -> some View {
        HStack(spacing: 8) {
            Button {
                if let index = project.links.firstIndex(where: { $0.id == link.id }) {
                    project.links[index].isKey.toggle()
                    model.save(project)
                }
            } label: { Image(systemName: link.isKey ? "star.fill" : "star").foregroundStyle(link.isKey ? .yellow : .secondary) }
            .buttonStyle(.borderless)
            .help("Key item: opened or shown when the Space activates")
            Image(nsImage: NSWorkspace.shared.icon(forFile: link.path)).resizable().frame(width: 18, height: 18)
                .opacity(link.isBroken ? 0.4 : 1)
            VStack(alignment: .leading, spacing: 1) {
                Text(link.name).strikethrough(link.isBroken)
                Text(((link.path as NSString).deletingLastPathComponent).abbreviatedPath)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            if link.isBroken {
                Button("Repair…") { repairing = link }
                    .foregroundStyle(.orange)
            } else {
                Button { model.open(link.path) } label: { Image(systemName: "arrow.up.forward.app") }.buttonStyle(.borderless)
                Button { model.reveal(inUniverse: link.path) } label: { Image(systemName: "globe.americas") }.buttonStyle(.borderless)
                    .help("Reveal in Universe")
            }
            Button {
                project.links.removeAll { $0.id == link.id }
                model.save(project)
            } label: { Image(systemName: "minus.circle") }
            .buttonStyle(.borderless)
            .help("Remove from project (the file stays)")
        }
    }
}

private struct RepairSheet: View {
    @ObservedObject var model: OrbitViewModel
    let project: Project
    let link: ProjectLink
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let candidates = model.repairCandidates(for: link)
        VStack(alignment: .leading, spacing: 12) {
            Text("Repair “\(link.name)”").font(.headline)
            Text("It's no longer at \(link.path.abbreviatedPath). It may have been moved or deleted outside ATLAS.")
                .font(.callout).foregroundStyle(.secondary)
            if candidates.isEmpty {
                Text("No file with that name is in your Orbit folders.").foregroundStyle(.secondary)
            } else {
                Text("Files with the same name:").font(.callout)
                List(candidates) { entry in
                    Button {
                        model.repair(link, in: project, to: entry.path)
                        dismiss()
                    } label: {
                        VStack(alignment: .leading) {
                            Text(entry.path.abbreviatedPath)
                            Text("Modified \(OrbitFormat.date(entry.modifiedAt)) · \(OrbitFormat.bytes(entry.size))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                }
                .frame(minHeight: 120)
            }
            HStack {
                Button("Choose…") {
                    if let url = OrbitViewModel.chooseItems().first {
                        model.repair(link, in: project, to: url.path)
                        dismiss()
                    }
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 480)
    }
}
