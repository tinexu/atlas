import AppKit
import AtlasCore
import AtlasOrbit
import SwiftUI

/// Organization rules and the review queue. Each rule runs as a Flow
/// workflow; "Open in Flow" shows it in the Automation Galaxy.
struct RulesView: View {
    @ObservedObject var model: OrbitViewModel
    @State private var editing: FileRule?
    @State private var dryRunRule: FileRule?
    @State private var deleting: FileRule?

    var body: some View {
        List {
            if !model.reviews.isEmpty {
                Section {
                    ForEach(model.reviews) { item in
                        ReviewRow(model: model, item: item)
                    }
                } header: {
                    HStack {
                        Text("Waiting for review (\(model.reviews.count))")
                        Spacer()
                        Button("Approve All") { model.approveAll() }
                            .buttonStyle(.borderless)
                    }
                }
            }
            Section {
                ForEach(model.rules) { rule in
                    RuleRow(model: model, rule: rule,
                            edit: { editing = rule }, dryRun: { dryRunRule = rule }, delete: { deleting = rule })
                }
            } header: {
                HStack {
                    Text("Rules")
                    Spacer()
                    Button {
                        editing = FileRule(name: "", folders: model.locations.first.map { [$0.path.abbreviatedPath] } ?? ["~/Downloads"],
                                           conditions: [.extensions("pdf")], action: .moveTo(folder: "~/Documents/PDFs"))
                    } label: { Label("New Rule", systemImage: "plus") }
                    .buttonStyle(.borderless)
                }
            } footer: {
                Text("Rules act on new files in the folders they watch. Rules about age (like “older than 30 days”) also check existing files once a day. Anything a rule moves can be undone from Run History.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .sheet(item: $editing) { rule in
            RuleEditor(model: model, rule: rule)
        }
        .sheet(item: $dryRunRule) { rule in
            DryRunSheet(model: model, rule: rule)
        }
        .confirmationDialog("Delete “\(deleting?.name ?? "")”?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("Delete Rule", role: .destructive) {
                if let deleting { model.delete(deleting) }
                deleting = nil
            }
        } message: {
            Text("Its automation is deleted too. Files it already organized stay where they are.")
        }
    }
}

private struct RuleRow: View {
    @ObservedObject var model: OrbitViewModel
    let rule: FileRule
    let edit: () -> Void
    let dryRun: () -> Void
    let delete: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Toggle("", isOn: Binding(get: { rule.isEnabled }, set: { model.setEnabled($0, rule: rule) }))
                .toggleStyle(.switch)
                .labelsHidden()
                .disabled(!rule.problems.isEmpty)
                .help(rule.problems.first ?? (rule.isEnabled ? "Turn off" : "Turn on"))
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(rule.name).fontWeight(.medium)
                    if rule.effectiveMode == .askFirst {
                        Text("Asks first").font(.caption2).padding(.horizontal, 5).padding(.vertical, 1)
                            .background(.orange.opacity(0.2), in: Capsule())
                    }
                    if rule.starterID != nil {
                        Text("Starter").font(.caption2).padding(.horizontal, 5).padding(.vertical, 1)
                            .background(.secondary.opacity(0.15), in: Capsule())
                    }
                }
                Text(rule.summary).font(.callout).foregroundStyle(.secondary)
                Text("Watches " + rule.folders.map(\.abbreviatedPath).joined(separator: ", ")).font(.caption).foregroundStyle(.tertiary)
                ForEach(unauthorized, id: \.self) { folder in
                    Label("\(folder.abbreviatedPath) isn't an Orbit folder, so files there can't be changed. Add it in Folders.",
                          systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                ForEach(rule.problems, id: \.self) { problem in
                    Label(problem, systemImage: "exclamationmark.octagon").font(.caption).foregroundStyle(.red)
                }
            }
            Spacer()
            Button("Dry Run", action: dryRun)
            Menu {
                Button("Edit…", action: edit)
                if let id = rule.workflowID {
                    Button("Open in Flow") { model.openWorkflow(id) }
                }
                Divider()
                Button("Delete…", role: .destructive, action: delete)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture(count: 2, perform: edit)
    }

    private var unauthorized: [String] {
        rule.folders.filter { folder in !model.locations.contains { $0.contains(FileLocation.normalize(folder)) } }
    }
}

private struct ReviewRow: View {
    @ObservedObject var model: OrbitViewModel
    let item: ReviewItem

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: item.path)).resizable().frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name).fontWeight(.medium)
                Text("Proposed: \(item.action.summary)").font(.callout)
                Text(item.reason).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Show") { model.showInFinder(item.path) }
            if case .moveTo = item.action {
                Button("Change…") {
                    if let url = OrbitViewModel.chooseFolder(prompt: "Move Here") {
                        model.approve(item, action: .moveTo(folder: url.path))
                    }
                }
                .help("Pick a different folder and move it there")
            }
            Button("Ignore") { model.ignore(item) }
            Button(item.action == .trash ? "Move to Trash" : "Approve") { model.approve(item) }
                .buttonStyle(.borderedProminent)
                .tint(item.action == .trash ? .red : .accentColor)
        }
        .padding(.vertical, 3)
    }
}

/// The simple rule form; "Open in Flow" covers anything more advanced.
struct RuleEditor: View {
    @ObservedObject var model: OrbitViewModel
    @State var rule: FileRule
    @State private var dryRun: [DryRunItem]?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    TextField("Name", text: $rule.name, prompt: Text("e.g. Invoices into Finance"))
                    folderList
                }
                Section {
                    Picker("When", selection: $rule.match) {
                        Text("All of these are true").tag(ConditionGroup.Match.all)
                        Text("Any of these is true").tag(ConditionGroup.Match.any)
                    }
                    ForEach(rule.conditions.indices, id: \.self) { index in
                        // Guarded: a removed row can still be drawn once more.
                        ConditionRow(condition: Binding(
                            get: { rule.conditions.indices.contains(index) ? rule.conditions[index] : .extensions("") },
                            set: { if rule.conditions.indices.contains(index) { rule.conditions[index] = $0 } }
                        ), remove: { if rule.conditions.indices.contains(index) { rule.conditions.remove(at: index) } })
                    }
                    Menu {
                        ForEach(Array(RuleCondition.templates.enumerated()), id: \.offset) { _, template in
                            Button(template.title) { rule.conditions.append(template) }
                        }
                    } label: { Label("Add Condition", systemImage: "plus") }
                    .fixedSize()
                } header: {
                    Text("Conditions")
                }
                Section {
                    actionEditor
                    Picker("If the name is taken", selection: $rule.ifExists) {
                        ForEach(ConflictMode.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    Picker("Do it", selection: $rule.mode) {
                        ForEach(FileRule.Mode.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .disabled(rule.action == .trash)
                    if rule.action == .trash {
                        Text("Moving to the Trash always waits for your approval in the review queue.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Then")
                } footer: {
                    Text("Patterns: {name} {ext} {date:yyyy-MM-dd} {counter} {parentFolder}. Folders may also use {folder} (the file's folder) and {match} (what a name pattern matched, e.g. CS101).")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if !rule.problems.isEmpty {
                    Section {
                        ForEach(rule.problems, id: \.self) { Label($0, systemImage: "exclamationmark.octagon").foregroundStyle(.red) }
                    }
                }
                if let dryRun {
                    Section("Dry run: \(dryRun.count) existing file\(dryRun.count == 1 ? "" : "s") would match") {
                        DryRunList(items: dryRun)
                    }
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                Toggle("Turn on", isOn: $rule.isEnabled).disabled(!rule.problems.isEmpty)
                Spacer()
                Button("Dry Run") { Task { dryRun = await model.dryRun(rule) } }
                    .disabled(rule.folders.isEmpty)
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    model.save(rule)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(14)
        }
        .frame(width: 620, height: 640)
    }

    private var folderList: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Watches").font(.callout)
            ForEach(Array(rule.folders.enumerated()), id: \.offset) { index, folder in
                HStack {
                    Image(systemName: "folder")
                    Text(folder.abbreviatedPath)
                    Spacer()
                    Button { rule.folders.remove(at: index) } label: { Image(systemName: "minus.circle") }.buttonStyle(.borderless)
                }
            }
            HStack {
                Menu("Add Orbit Folder") {
                    ForEach(model.locations) { location in
                        Button(location.name) { rule.folders.append(location.path.abbreviatedPath) }
                    }
                }
                .fixedSize()
                Button("Choose…") {
                    if let url = OrbitViewModel.chooseFolder() { rule.folders.append(url.path.abbreviatedPath) }
                }
            }
            .controlSize(.small)
        }
    }

    @ViewBuilder
    private var actionEditor: some View {
        Picker("Action", selection: Binding(
            get: { ActionKind(rule.action) },
            set: { kind in rule.action = kind.defaultAction }
        )) {
            ForEach(ActionKind.allCases, id: \.self) { Text($0.title).tag($0) }
        }
        switch rule.action {
        case .moveTo(let folder):
            HStack {
                TextField("Folder", text: Binding(get: { folder }, set: { rule.action = .moveTo(folder: $0) }))
                Button("Choose…") {
                    if let url = OrbitViewModel.chooseFolder() { rule.action = .moveTo(folder: url.path.abbreviatedPath) }
                }
            }
        case .rename(let pattern):
            TextField("New name", text: Binding(get: { pattern }, set: { rule.action = .rename(pattern: $0) }),
                      prompt: Text("{date:yyyy-MM-dd} {name}"))
        case .tag(let tags):
            TextField("Tags", text: Binding(get: { tags }, set: { rule.action = .tag($0) }), prompt: Text("Work, Red"))
        case .trash:
            EmptyView()
        }
    }

    enum ActionKind: CaseIterable {
        case move, rename, tag, trash
        init(_ action: RuleAction) {
            switch action {
            case .moveTo: self = .move
            case .rename: self = .rename
            case .tag: self = .tag
            case .trash: self = .trash
            }
        }
        var title: String {
            switch self {
            case .move: return "Move to folder"
            case .rename: return "Rename"
            case .tag: return "Add Finder tags"
            case .trash: return "Move to Trash"
            }
        }
        var defaultAction: RuleAction {
            switch self {
            case .move: return .moveTo(folder: "~/Documents")
            case .rename: return .rename(pattern: "{date:yyyy-MM-dd} {name}")
            case .tag: return .tag("")
            case .trash: return .trash
            }
        }
    }
}

private struct ConditionRow: View {
    @Binding var condition: RuleCondition
    let remove: () -> Void

    var body: some View {
        HStack {
            Text(condition.title).frame(width: 100, alignment: .leading)
            fields
            Button(action: remove) { Image(systemName: "minus.circle") }.buttonStyle(.borderless)
        }
        if let problem = condition.validationError {
            Text(problem).font(.caption).foregroundStyle(.red)
        }
    }

    @ViewBuilder
    private var fields: some View {
        switch condition {
        case .extensions(let list):
            TextField("pdf, png", text: Binding(get: { list }, set: { condition = .extensions($0) }))
        case .nameContains(let text):
            TextField("Text", text: Binding(get: { text }, set: { condition = .nameContains($0) }))
        case .nameMatches(let pattern):
            TextField("Regular expression", text: Binding(get: { pattern }, set: { condition = .nameMatches(pattern: $0) }))
                .font(.body.monospaced())
        case .sizeAbove(let mb):
            HStack {
                TextField("MB", value: Binding(get: { mb }, set: { condition = .sizeAbove(megabytes: $0) }), format: .number).frame(width: 80)
                Text("MB")
            }
        case .sizeBelow(let mb):
            HStack {
                TextField("MB", value: Binding(get: { mb }, set: { condition = .sizeBelow(megabytes: $0) }), format: .number).frame(width: 80)
                Text("MB")
            }
        case .olderThan(let days, let field):
            dateFields(days, field) { .olderThan(days: $0, field: $1) }
        case .newerThan(let days, let field):
            dateFields(days, field) { .newerThan(days: $0, field: $1) }
        case .conformsTo(let type):
            Picker("", selection: Binding(get: { type }, set: { condition = .conformsTo(typeIdentifier: $0) })) {
                Text("Image").tag("public.image")
                Text("Movie").tag("public.movie")
                Text("Audio").tag("public.audio")
                Text("PDF").tag("com.adobe.pdf")
                Text("Text").tag("public.text")
                Text("Archive").tag("public.archive")
                Text("Disk image").tag("public.disk-image")
                Text("Source code").tag("public.source-code")
                if !["public.image", "public.movie", "public.audio", "com.adobe.pdf", "public.text", "public.archive",
                     "public.disk-image", "public.source-code"].contains(type) {
                    Text(type).tag(type)
                }
            }
            .labelsHidden()
        case .sourceContains(let text):
            TextField("Site or app, e.g. github.com", text: Binding(get: { text }, set: { condition = .sourceContains($0) }))
        }
    }

    private func dateFields(_ days: Int, _ field: RuleCondition.DateField,
                            make: @escaping (Int, RuleCondition.DateField) -> RuleCondition) -> some View {
        HStack {
            TextField("Days", value: Binding(get: { days }, set: { condition = make($0, field) }), format: .number).frame(width: 60)
            Text("days, by")
            Picker("", selection: Binding(get: { field }, set: { condition = make(days, $0) })) {
                Text("created").tag(RuleCondition.DateField.created)
                Text("modified").tag(RuleCondition.DateField.modified)
            }
            .labelsHidden()
            .fixedSize()
        }
    }
}

struct DryRunSheet: View {
    @ObservedObject var model: OrbitViewModel
    let rule: FileRule
    @State private var items: [DryRunItem]?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Dry run: \(rule.name)").font(.headline)
            Text("What this rule would do to files already in its folders. Nothing is changed.")
                .font(.callout).foregroundStyle(.secondary)
            if let items {
                if items.isEmpty {
                    ContentUnavailableView("No existing files match", systemImage: "checkmark.circle")
                } else {
                    DryRunList(items: items)
                }
            } else {
                ProgressView().frame(maxWidth: .infinity)
            }
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 600, height: 460)
        .task { items = await model.dryRun(rule) }
    }
}

private struct DryRunList: View {
    let items: [DryRunItem]

    var body: some View {
        List(items) { item in
            VStack(alignment: .leading, spacing: 2) {
                Text((item.path as NSString).lastPathComponent).lineLimit(1)
                Label(item.outcome, systemImage: item.needsReview ? "hand.raised" : "arrow.right")
                    .font(.caption)
                    .foregroundStyle(item.outcome.hasPrefix("Can't") ? .orange : .secondary)
            }
        }
        .frame(minHeight: 160)
    }
}
