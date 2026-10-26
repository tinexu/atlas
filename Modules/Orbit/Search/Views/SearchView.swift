import AppKit
import AtlasCore
import AtlasOrbit
import SwiftUI

/// Metadata search over the Orbit index, with optional Spotlight content
/// search and optional plain-English queries (shown translated first).
struct SearchView: View {
    @ObservedObject var model: OrbitViewModel
    @AppStorage("orbit.search.naturalLanguage") private var naturalLanguage = false
    @State private var text = ""
    @State private var searchContents = false
    @State private var results: [SearchResult] = []
    @State private var contentResults: [String] = []
    @State private var translation: SearchQuery?
    @State private var problems: [String] = []
    @State private var selection: String?
    @State private var spotlight = SpotlightSearch()
    @State private var searching = false

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        TextField(naturalLanguage ? "e.g. the PDF about neural networks from last month"
                                                  : "e.g. ext:pdf modified:<30d size:>10mb neural", text: $text)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit(submit)
                        Button("Search", action: submit).keyboardShortcut(.defaultAction)
                    }
                    HStack(spacing: 14) {
                        Toggle("Plain English", isOn: $naturalLanguage)
                            .help("Translates a sentence into the search syntax on this Mac, with fixed rules. You see the translation before it runs.")
                        Toggle("Also search inside files (Spotlight)", isOn: $searchContents)
                        Spacer()
                        Menu("Syntax") {
                            Text("ext:pdf,png  type:image  size:>10mb  size:<1gb")
                            Text("modified:<30d  created:>2026-01-01  opened:>6mo")
                            Text("in:Downloads  name:\"exact words\"  other words match names")
                        }
                        .fixedSize()
                    }
                    .controlSize(.small)
                    if let translation {
                        HStack {
                            Label("Searching for: \(translation.text.isEmpty ? "everything" : translation.text)", systemImage: "text.magnifyingglass")
                                .font(.callout)
                            Button("Edit") {
                                text = translation.text
                                naturalLanguage = false
                                self.translation = nil
                            }
                            .buttonStyle(.borderless)
                        }
                        .padding(6)
                        .background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
                    }
                    ForEach(problems, id: \.self) { problem in
                        Label(problem, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                    }
                }
                .padding(12)
                Divider()
                List(selection: $selection) {
                    if !results.isEmpty {
                        Section("\(results.count) by name and details") {
                            ForEach(results) { result in row(result.entry.path, entry: result.entry) }
                        }
                    }
                    if !contentResults.isEmpty {
                        Section("\(contentResults.count) with matching contents (Spotlight)") {
                            ForEach(contentResults, id: \.self) { path in row(path, entry: model.entry(path)) }
                        }
                    }
                }
                .overlay {
                    if searching {
                        ProgressView()
                    } else if results.isEmpty && contentResults.isEmpty {
                        ContentUnavailableView(text.isEmpty ? "Search your Orbit folders" : "No matches",
                                               systemImage: "magnifyingglass",
                                               description: Text(model.locations.isEmpty ? "Add a folder first, in the Folders tab." : "Only folders you've added are searched."))
                    }
                }
            }
            .frame(minWidth: 420, maxWidth: .infinity)

            Group {
                if let entry = model.entry(selection) {
                    FileInspector(model: model, entry: entry).id(entry.path)
                } else {
                    ContentUnavailableView("Select a result", systemImage: "doc.text.magnifyingglass")
                }
            }
            .frame(minWidth: 240, idealWidth: 280, maxWidth: 340)
        }
    }

    private func row(_ path: String, entry: FileEntry?) -> some View {
        HStack(spacing: 8) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: path)).resizable().frame(width: 18, height: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text((path as NSString).lastPathComponent).lineLimit(1)
                Text(((path as NSString).deletingLastPathComponent).abbreviatedPath)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            if let entry {
                Text(OrbitFormat.bytes(entry.size)).font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
        }
        .tag(path)
        .contextMenu {
            Button("Open") { model.open(path) }
            Button("Show in Finder") { model.showInFinder(path) }
            Button("Reveal in Universe") { model.reveal(inUniverse: path) }
        }
    }

    private func submit() {
        let query: SearchQuery
        if naturalLanguage {
            query = NaturalLanguageQuery.translate(text, folderNames: model.locations.map(\.name))
            translation = query
        } else {
            query = SearchQuery.parse(text)
            translation = nil
        }
        problems = query.problems
        do {
            results = query.isEmpty ? [] : try model.module.search.search(query)
        } catch {
            results = []
            problems.append(error.localizedDescription)
        }
        contentResults = []
        guard searchContents else { return }
        let words = query.terms.joined(separator: " ")
        guard !words.isEmpty else { return }
        searching = true
        let roots = model.locations.map(\.path)
        Task {
            let found = await spotlight.search(words, in: roots)
            let shown = Set(results.map(\.entry.path))
            contentResults = found.filter { !shown.contains($0) }
            searching = false
        }
    }
}
