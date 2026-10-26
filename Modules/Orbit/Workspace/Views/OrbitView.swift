import AppKit
import AtlasCore
import AtlasOrbit
import SwiftUI

/// Orbit: the File Universe and everything around it. Every tab works on
/// the same index and the same selection.
public struct OrbitView: View {
    @ObservedObject var model: OrbitViewModel

    public init(model: OrbitViewModel) {
        self.model = model
    }

    public var body: some View {
        VStack(spacing: 0) {
            banners
            Group {
                switch model.tab {
                case .universe: UniverseView(model: model)
                case .browser: BrowserView(model: model)
                case .search: SearchView(model: model)
                case .rules: RulesView(model: model)
                case .duplicates: DuplicatesView(model: model)
                case .projects: ProjectsView(model: model)
                case .folders: LocationsView(model: model)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle("Orbit")
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("Orbit", selection: $model.tab) {
                    ForEach(OrbitViewModel.Tab.allCases) { tab in
                        Label(tab == .rules && !model.reviews.isEmpty ? "Rules (\(model.reviews.count))" : tab.title, systemImage: tab.symbol)
                            .tag(tab)
                    }
                }
                .pickerStyle(.segmented)
            }
            ToolbarItem {
                Button { model.showCleanup = true } label: { Label("Cleanup Review", systemImage: "sparkles") }
                    .help("Suggestions for freeing space, from your Orbit folders")
                    .disabled(model.locations.isEmpty)
            }
        }
        .sheet(item: $model.pendingTrash) { request in
            TrashConfirmationSheet(request: request) { model.confirmTrash() }
        }
        .sheet(isPresented: $model.showCleanup) {
            CleanupView(model: model)
        }
    }

    @ViewBuilder
    private var banners: some View {
        if model.locations.isEmpty && model.tab != .folders {
            Banner(symbol: "externaldrive.badge.plus", tint: .blue,
                   text: "Orbit only reads folders you add. Start with Downloads, Documents or Desktop.") {
                Button("Add Folders") { model.tab = .folders }
            }
        }
        if model.isDiskLow {
            Banner(symbol: "internaldrive", tint: .orange,
                   text: "Disk space is low: \(OrbitFormat.bytes(model.health?.diskFree ?? 0)) free.") {
                Button("Review Cleanup") { model.showCleanup = true }
            }
        }
        if !model.reviews.isEmpty && model.tab != .rules {
            Banner(symbol: "hand.raised", tint: .purple,
                   text: "\(model.reviews.count) file\(model.reviews.count == 1 ? " is" : "s are") waiting for your review.") {
                Button("Review") { model.tab = .rules }
            }
        }
    }
}

private struct Banner<Actions: View>: View {
    let symbol: String
    let tint: Color
    let text: String
    @ViewBuilder let actions: Actions

    var body: some View {
        HStack {
            Image(systemName: symbol).foregroundStyle(tint)
            Text(text).font(.callout)
            Spacer()
            actions
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(tint.opacity(0.1))
    }
}

/// Cleanup Review (spec 10): largest files, old installers, large downloads
/// not opened recently and duplicate copies, with the space each frees.
/// Nothing happens until you pick items and confirm.
struct CleanupView: View {
    @ObservedObject var model: OrbitViewModel
    @State private var items: [CleanupItem] = []
    @State private var chosen = Set<String>()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Cleanup Review").font(.title2.weight(.semibold))
                Spacer()
                if let health = model.health {
                    Text("\(OrbitFormat.bytes(health.diskFree)) free of \(OrbitFormat.bytes(health.diskTotal))")
                        .foregroundStyle(.secondary)
                }
            }
            Text("Suggestions from your Orbit folders only. Picked items go to the Trash (you can put them back, or undo in Run History).")
                .font(.callout).foregroundStyle(.secondary)
            if model.duplicateSets.isEmpty {
                Button("Include duplicates (runs Find Duplicates)") { model.findDuplicates(minimumSize: 1_000_000) }
                    .disabled(model.isScanningDuplicates)
            }
            List {
                ForEach(CleanupItem.Reason.allCases, id: \.self) { reason in
                    let group = items.filter { $0.reason == reason }
                    if !group.isEmpty {
                        Section("\(reason.title) · \(OrbitFormat.bytes(group.reduce(0) { $0 + $1.entry.size }))") {
                            ForEach(group) { item in row(item) }
                        }
                    }
                }
            }
            .overlay {
                if items.isEmpty {
                    ContentUnavailableView("Nothing to suggest", systemImage: "checkmark.seal",
                                           description: Text("No large, old or duplicate files stand out in your Orbit folders."))
                }
            }
            HStack {
                Text("Selected: \(chosen.count) · frees \(OrbitFormat.bytes(selectedBytes))").monospacedDigit()
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Move to Trash…", role: .destructive) {
                    let paths = Array(chosen).sorted()
                    dismiss()
                    model.requestTrash(paths, source: "Cleanup Review")
                }
                .disabled(chosen.isEmpty)
                .buttonStyle(.borderedProminent)
                .tint(.red)
            }
        }
        .padding(20)
        .frame(width: 700, height: 600)
        .onAppear { items = model.cleanupSuggestions() }
        .onChange(of: model.duplicateSets) { _, _ in items = model.cleanupSuggestions() }
    }

    private var selectedBytes: Int64 {
        items.filter { chosen.contains($0.entry.path) }.reduce(0) { $0 + $1.entry.size }
    }

    private func row(_ item: CleanupItem) -> some View {
        HStack(spacing: 8) {
            Toggle("", isOn: Binding(
                get: { chosen.contains(item.entry.path) },
                set: { on in if on { chosen.insert(item.entry.path) } else { chosen.remove(item.entry.path) } }
            ))
            .labelsHidden()
            Image(nsImage: NSWorkspace.shared.icon(forFile: item.entry.path)).resizable().frame(width: 18, height: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.entry.name).lineLimit(1)
                Text("\(item.entry.parent.abbreviatedPath) · \(item.detail)").font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer()
            Text(OrbitFormat.bytes(item.entry.size)).monospacedDigit()
            Button { model.showInFinder(item.entry.path) } label: { Image(systemName: "eye") }
                .buttonStyle(.borderless)
                .help("Preview in Finder")
        }
    }
}
