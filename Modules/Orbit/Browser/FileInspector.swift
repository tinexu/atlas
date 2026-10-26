import AppKit
import AtlasCore
import AtlasOrbit
import SwiftUI

/// The metadata panel for the selected file or folder, shared by the 3D
/// Universe and the 2D browser, with every action either view offers.
struct FileInspector: View {
    @ObservedObject var model: OrbitViewModel
    let entry: FileEntry
    @State private var renaming = false
    @State private var newName = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: entry.path))
                        .resizable()
                        .frame(width: 40, height: 40)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.name).font(.headline).lineLimit(2).textSelection(.enabled)
                        Label(entry.category == .folder ? "Folder" : entry.category.title, systemImage: entry.category.symbolName)
                            .font(.caption)
                            .foregroundStyle(OrbitFormat.color(entry.category))
                    }
                }

                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 6) {
                    row("Where", entry.parent.abbreviatedPath)
                    row("Size", OrbitFormat.bytes(entry.size) + (entry.isFolder ? " · \(entry.itemCount.formatted()) files" : ""))
                    if let type = entry.typeIdentifier { row("Type", type) }
                    row("Created", OrbitFormat.date(entry.createdAt))
                    row("Modified", OrbitFormat.date(entry.modifiedAt))
                    if !entry.isFolder { row("Last opened", OrbitFormat.date(entry.accessedAt)) }
                }
                .font(.callout)

                FileActionButtons(model: model, entries: [entry], renaming: $renaming)
            }
            .padding(14)
        }
        .sheet(isPresented: $renaming) {
            RenameSheet(name: entry.name) { name in model.rename(entry.path, to: name) }
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value).textSelection(.enabled).lineLimit(3)
        }
    }
}

/// Open, Show in Finder, Rename, Move, Move to Trash, Add to Project.
struct FileActionButtons: View {
    @ObservedObject var model: OrbitViewModel
    let entries: [FileEntry]
    @Binding var renaming: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button { entries.forEach { model.open($0.path) } } label: { Label("Open", systemImage: "arrow.up.forward.app") }
                Button { entries.forEach { model.showInFinder($0.path) } } label: { Label("Show in Finder", systemImage: "folder") }
            }
            HStack {
                Button { renaming = true } label: { Label("Rename…", systemImage: "pencil") }
                    .disabled(entries.count != 1)
                Button {
                    if let url = OrbitViewModel.chooseFolder(prompt: "Move Here", startingAt: entries.first?.parent) {
                        model.move(entries.map(\.path), to: url.path)
                    }
                } label: { Label("Move…", systemImage: "folder.badge.plus") }
            }
            HStack {
                Menu {
                    ForEach(model.projects) { project in
                        Button(project.name) { model.add(entries.map(\.path), to: project) }
                    }
                    if !model.projects.isEmpty { Divider() }
                    Button("New Project…") {
                        model.createProject(named: entries.count == 1 ? (entries[0].name as NSString).deletingPathExtension : "New Project")
                        if let project = model.projects.first(where: { $0.id == model.selectedProjectID }) {
                            model.add(entries.map(\.path), to: project)
                        }
                    }
                } label: {
                    Label("Add to Project", systemImage: "folder.badge.person.crop")
                }
                .fixedSize()
                Button(role: .destructive) { model.requestTrash(entries.map(\.path)) } label: {
                    Label("Move to Trash…", systemImage: "trash")
                }
            }
        }
        .controlSize(.small)
    }
}

struct RenameSheet: View {
    @State var name: String
    let rename: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Rename").font(.headline)
            TextField("Name", text: $name)
                .frame(width: 320)
                .onSubmit(commit)
            Text("If the name is taken, ATLAS adds a number instead of replacing anything.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Rename", action: commit).keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || name.contains("/"))
            }
        }
        .padding(20)
    }

    private func commit() {
        rename(name.trimmingCharacters(in: .whitespaces))
        dismiss()
    }
}

/// The preview and confirmation every Move to Trash goes through.
struct TrashConfirmationSheet: View {
    let request: OrbitViewModel.TrashRequest
    let confirm: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Move \(request.paths.count) item\(request.paths.count == 1 ? "" : "s") to the Trash?", systemImage: "trash")
                .font(.headline)
            Text("Frees about \(OrbitFormat.bytes(request.totalSize)) once you empty the Trash. You can put them back from the Trash, or undo this in Run History.")
                .font(.callout)
                .foregroundStyle(.secondary)
            List(request.paths, id: \.self) { path in
                HStack {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: path)).resizable().frame(width: 16, height: 16)
                    Text((path as NSString).lastPathComponent)
                    Spacer()
                    Text(((path as NSString).deletingLastPathComponent).abbreviatedPath)
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
            }
            .frame(minHeight: 120, maxHeight: 280)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Move to Trash", role: .destructive) {
                    confirm()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 520)
    }
}
