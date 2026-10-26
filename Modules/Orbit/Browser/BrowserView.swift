import AppKit
import AtlasCore
import AtlasOrbit
import SwiftUI

/// The 2D alternative to the Universe: a folder tree, a table with the
/// same filters, columns and actions, and a treemap storage chart.
struct BrowserView: View {
    @ObservedObject var model: OrbitViewModel
    @State private var tableSelection = Set<String>()
    @State private var sortOrder = [KeyPathComparator(\FileEntry.size, order: .reverse)]
    @State private var showChart = false
    @State private var renaming: FileEntry?

    var body: some View {
        HSplitView {
            FolderTree(model: model)
                .frame(minWidth: 200, idealWidth: 240, maxWidth: 320)
            VStack(spacing: 0) {
                HStack {
                    Breadcrumb(model: model)
                    Spacer()
                    Picker("View", selection: $showChart) {
                        Label("Table", systemImage: "tablecells").tag(false)
                        Label("Storage", systemImage: "square.grid.3x3.square").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                FilterBar(model: model)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
                Divider()
                content
            }
            .frame(minWidth: 420, maxWidth: .infinity)
            inspector
                .frame(minWidth: 240, idealWidth: 280, maxWidth: 340)
        }
        .onChange(of: tableSelection) { _, new in
            if new.count == 1 { model.selection = new.first }
        }
        .onChange(of: model.selection) { _, new in
            if let new, !tableSelection.contains(new) { tableSelection = [new] }
        }
        .sheet(item: $renaming) { entry in
            RenameSheet(name: entry.name) { model.rename(entry.path, to: $0) }
        }
    }

    @ViewBuilder
    private var content: some View {
        if let folder = model.currentFolder {
            let rows = model.children(of: folder).sorted(using: sortOrder)
            if showChart {
                TreemapView(model: model, entries: rows)
            } else {
                table(rows)
            }
        } else {
            OverviewList(model: model)
        }
    }

    private func table(_ rows: [FileEntry]) -> some View {
        Table(rows, selection: $tableSelection, sortOrder: $sortOrder) {
            TableColumn("Name", value: \.name) { entry in
                HStack(spacing: 6) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: entry.path)).resizable().frame(width: 16, height: 16)
                    Text(entry.name).lineLimit(1)
                }
                .opacity(model.highlight == .none || model.highlight.matches(entry) ? 1 : 0.35)
            }
            .width(min: 180, ideal: 280)
            TableColumn("Kind", value: \.category.rawValue) { entry in
                Text(entry.isFolder ? "Folder" : entry.category.title).foregroundStyle(.secondary)
            }
            .width(min: 70, ideal: 100)
            TableColumn("Size", value: \.size) { entry in
                Text(OrbitFormat.bytes(entry.size)).monospacedDigit()
            }
            .width(min: 60, ideal: 80)
            TableColumn("Modified", value: \.modifiedSortKey) { entry in
                Text(OrbitFormat.date(entry.modifiedAt)).foregroundStyle(.secondary)
            }
            .width(min: 100, ideal: 140)
            TableColumn("Created", value: \.createdSortKey) { entry in
                Text(OrbitFormat.date(entry.createdAt)).foregroundStyle(.secondary)
            }
            .width(min: 100, ideal: 140)
        }
        .contextMenu(forSelectionType: String.self) { paths in
            let entries = paths.compactMap { model.entry($0) }
            if !entries.isEmpty { contextMenu(entries) }
        } primaryAction: { paths in
            guard let path = paths.first, let entry = model.entry(path) else { return }
            if entry.isFolder { model.enter(entry.path) } else { model.open(entry.path) }
        }
        .overlay {
            if rows.isEmpty {
                ContentUnavailableView(model.filters.isActive ? "Nothing matches the filters" : "Empty folder", systemImage: "folder")
            }
        }
    }

    @ViewBuilder
    private func contextMenu(_ entries: [FileEntry]) -> some View {
        Button("Open") { entries.forEach { model.open($0.path) } }
        Button("Show in Finder") { entries.forEach { model.showInFinder($0.path) } }
        Button("Reveal in Universe") { model.reveal(inUniverse: entries[0].path) }
        Divider()
        Button("Rename…") { renaming = entries.first }.disabled(entries.count != 1)
        Button("Move…") {
            if let url = OrbitViewModel.chooseFolder(prompt: "Move Here", startingAt: entries.first?.parent) {
                model.move(entries.map(\.path), to: url.path)
            }
        }
        Menu("Add to Project") {
            ForEach(model.projects) { project in Button(project.name) { model.add(entries.map(\.path), to: project) } }
        }
        Divider()
        Button("Move to Trash…", role: .destructive) { model.requestTrash(entries.map(\.path)) }
    }

    @ViewBuilder
    private var inspector: some View {
        let selected = tableSelection.compactMap { model.entry($0) }
        if selected.count > 1 {
            VStack(alignment: .leading, spacing: 12) {
                Text("\(selected.count) items").font(.headline)
                Text(OrbitFormat.bytes(selected.reduce(0) { $0 + $1.size })).foregroundStyle(.secondary)
                FileActionButtons(model: model, entries: selected, renaming: .constant(false))
                Spacer()
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        } else if let entry = model.entry(model.selection) {
            FileInspector(model: model, entry: entry)
                .id(entry.path)
        } else {
            ContentUnavailableView("Select a file", systemImage: "doc.text.magnifyingglass",
                                   description: Text("Double-click a folder to open it."))
        }
    }
}

extension FileEntry {
    var modifiedSortKey: Date { modifiedAt ?? .distantPast }
    var createdSortKey: Date { createdAt ?? .distantPast }
}

/// Orbit › Downloads › Photos, each part clickable.
struct Breadcrumb: View {
    @ObservedObject var model: OrbitViewModel

    var body: some View {
        HStack(spacing: 4) {
            Button { model.goUp() } label: { Image(systemName: "chevron.up") }
                .buttonStyle(.borderless)
                .disabled(model.currentFolder == nil)
                .help("Up one level")
            ForEach(Array(model.breadcrumb.enumerated()), id: \.offset) { index, crumb in
                if index > 0 { Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary) }
                Button(crumb.name) { model.enter(crumb.path) }
                    .buttonStyle(.borderless)
                    .fontWeight(index == model.breadcrumb.count - 1 ? .semibold : .regular)
                    .lineLimit(1)
            }
        }
    }
}

/// Type, size, date and highlight menus.
struct FilterBar: View {
    @ObservedObject var model: OrbitViewModel

    var body: some View {
        HStack(spacing: 8) {
            Menu {
                Button("All types") { model.filters.categories = [] }
                Divider()
                ForEach(FileCategory.allCases.filter { $0 != .folder }) { category in
                    Toggle(isOn: Binding(
                        get: { model.filters.categories.contains(category) },
                        set: { on in
                            if on { model.filters.categories.insert(category) } else { model.filters.categories.remove(category) }
                        }
                    )) { Label(category.title, systemImage: category.symbolName) }
                }
            } label: {
                Label(model.filters.categories.isEmpty ? "All types" : model.filters.categories.map(\.title).sorted().joined(separator: ", "),
                      systemImage: "line.3.horizontal.decrease.circle")
            }
            .fixedSize()
            Picker("Size", selection: $model.filters.size) {
                ForEach(FileFilters.SizeRange.allCases) { Text($0.title).tag($0) }
            }
            .labelsHidden()
            .fixedSize()
            Picker("Date", selection: $model.filters.date) {
                ForEach(FileFilters.DateRange.allCases) { Text($0.title).tag($0) }
            }
            .labelsHidden()
            .fixedSize()
            Picker("Highlight", selection: $model.highlight) {
                ForEach(FileHighlight.allCases) { Text($0.title).tag($0) }
            }
            .labelsHidden()
            .fixedSize()
            if model.filters.isActive || model.highlight != .none {
                Button("Clear") {
                    model.filters = FileFilters()
                    model.highlight = .none
                }
                .buttonStyle(.borderless)
            }
            Spacer()
        }
        .controlSize(.small)
    }
}

/// Lazily loaded folder tree of every Orbit folder.
struct FolderTree: View {
    @ObservedObject var model: OrbitViewModel

    var body: some View {
        List(selection: Binding(get: { model.currentFolder }, set: { model.enter($0) })) {
            Section("Orbit Folders") {
                ForEach(model.locations) { location in
                    FolderNode(model: model, path: location.path, name: location.name, depth: 0)
                }
            }
        }
        .listStyle(.sidebar)
        .overlay {
            if model.locations.isEmpty {
                Text("Add a folder in the Folders tab.").font(.callout).foregroundStyle(.secondary).padding()
            }
        }
    }
}

private struct FolderNode: View {
    @ObservedObject var model: OrbitViewModel
    let path: String
    let name: String
    let depth: Int
    @State private var expanded = false

    var body: some View {
        if expanded {
            DisclosureGroup(isExpanded: $expanded) {
                ForEach(subfolders, id: \.path) { child in
                    FolderNode(model: model, path: child.path, name: child.name, depth: depth + 1)
                }
            } label: { label }
        } else {
            DisclosureGroup(isExpanded: $expanded) { EmptyView() } label: { label }
        }
    }

    private var label: some View {
        Label(name, systemImage: depth == 0 ? "externaldrive.fill" : "folder.fill")
            .tag(Optional(path))
            .lineLimit(1)
    }

    private var subfolders: [FileEntry] {
        _ = model.revision
        return model.children(of: path, limit: 500, applyFilters: false).filter(\.isFolder)
    }
}

/// With no folder open: every Orbit folder and project.
struct OverviewList: View {
    @ObservedObject var model: OrbitViewModel

    var body: some View {
        List {
            Section("Folders") {
                ForEach(model.locations) { location in
                    Button { model.enter(location.path) } label: {
                        HStack {
                            Image(systemName: "externaldrive.fill").foregroundStyle(.blue)
                            Text(location.name)
                            Spacer()
                            Text("\(location.fileCount.formatted()) files · \(OrbitFormat.bytes(location.totalSize))")
                                .foregroundStyle(.secondary).monospacedDigit()
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            if !model.projects.isEmpty {
                Section("Projects") {
                    ForEach(model.projects) { project in
                        Button {
                            model.selectedProjectID = project.id
                            model.tab = .projects
                        } label: {
                            HStack {
                                Image(systemName: "folder.badge.person.crop").foregroundStyle(.purple)
                                Text(project.name)
                                Spacer()
                                Text("\(project.links.count) items").foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .overlay {
            if model.locations.isEmpty {
                ContentUnavailableView("No folders yet", systemImage: "externaldrive.badge.plus",
                                       description: Text("Add Downloads, Documents or any folder in the Folders tab."))
            }
        }
    }
}
