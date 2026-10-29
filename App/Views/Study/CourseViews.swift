import AppKit
import AtlasCore
import AtlasStudy
import SwiftUI

// MARK: - "Found 4 classes"

/// The classes ATLAS found, to confirm, rename or drop in one go.
struct CourseSetupView: View {
    @EnvironmentObject private var study: StudyModel
    @State private var included: Set<String> = []
    @State private var names: [String: String] = [:]
    @State private var seeded = false
    @State private var editing: Course?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if let request = study.setup {
                header(request)
                if request.suggestions.isEmpty {
                    emptyState
                } else {
                    VStack(spacing: 8) {
                        ForEach(Array(request.suggestions.enumerated()), id: \.element.id) { index, suggestion in
                            row(suggestion, color: CourseColors.palette[(study.activeCourses.count + index) % CourseColors.palette.count])
                        }
                    }
                }
                if request.isFirstRun {
                    HStack {
                        Text("Notes live in")
                        TextField("e.g. Notability on iPad", text: Binding(get: { study.notesRemark }, set: { study.notesRemark = $0 }))
                            .textFieldStyle(.roundedBorder)
                    }
                    .font(.callout)
                }
                sourcesBar
                footer(request)
            }
        }
        .padding(24)
        .frame(width: 520)
        .onAppear(perform: seed)
        .onChange(of: study.setup?.suggestions.map(\.id) ?? []) { _, _ in seed() }
        .sheet(item: $editing) { course in
            CourseEditorView(course: course, isNew: true).environmentObject(study)
        }
    }

    private func header(_ request: StudyModel.SetupRequest) -> some View {
        HStack(spacing: 14) {
            Image(systemName: "books.vertical.fill")
                .font(.title2)
                .foregroundStyle(.white)
                .frame(width: 46, height: 46)
                .background(Circle().fill(Color(nsColor: NSColor(atlasHex: "#6F8A6E")).gradient))
            VStack(alignment: .leading, spacing: 2) {
                Text(request.isFirstRun ? "Your classes" : "New class found").font(.title2.weight(.bold))
                Text(subtitle(request))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func subtitle(_ request: StudyModel.SetupRequest) -> String {
        let count = request.suggestions.count
        guard count > 0 else { return "Nothing found yet. Connect your calendar or scan a folder, or add one yourself." }
        let found = "Found \(count) class\(count == 1 ? "" : "es") in your calendar and folders."
        return request.isFirstRun ? "\(found) Each gets a book on the shelf; edit them any time in Courses." : found
    }

    private func row(_ suggestion: CourseSuggestion, color: String) -> some View {
        HStack(spacing: 12) {
            Toggle("", isOn: Binding(
                get: { included.contains(suggestion.id) },
                set: { if $0 { included.insert(suggestion.id) } else { included.remove(suggestion.id) } }
            ))
            .labelsHidden()
            RoundedRectangle(cornerRadius: 3)
                .fill(Color(nsColor: NSColor(atlasHex: color)))
                .frame(width: 10, height: 34)
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(suggestion.code.display).font(.body.monospaced().weight(.semibold))
                    TextField("Name", text: Binding(get: { names[suggestion.id] ?? suggestion.name },
                                                    set: { names[suggestion.id] = $0 }))
                        .textFieldStyle(.plain)
                }
                Text(suggestion.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            Button("Not a class") { study.ignore(suggestion) }
                .buttonStyle(.link)
                .font(.caption)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.04)))
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.title).foregroundStyle(.secondary)
            Text("Class codes look like CHEM 101 or CS180. ATLAS looks for them in recurring calendar events and folder names.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }

    private var sourcesBar: some View {
        HStack(spacing: 12) {
            if !study.isCalendarConnected {
                Button("Connect Calendar") { Task { await study.connectCalendar() } }
            }
            Button("Scan a Folder…") {
                if let folder = Pickers.choosePath(folders: true) { study.findCourses(scanning: folder) }
            }
            Button("Add Manually…") {
                editing = Course(name: "", code: "", color: CourseColors.next(after: study.courses))
            }
        }
        .font(.callout)
    }

    private func footer(_ request: StudyModel.SetupRequest) -> some View {
        HStack {
            Button(request.isFirstRun ? "Skip for now" : "Not now") {
                request.isFirstRun ? study.skipSetup() : study.closeSetup()
            }
            .keyboardShortcut(.cancelAction)
            Spacer()
            let chosen = request.suggestions.filter { included.contains($0.id) }
            Button("Add \(chosen.count) class\(chosen.count == 1 ? "" : "es")") {
                study.add(chosen.map { suggestion in
                    var edited = suggestion
                    if let name = names[suggestion.id]?.trimmingCharacters(in: .whitespaces), !name.isEmpty { edited.name = name }
                    return edited
                })
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
            .disabled(chosen.isEmpty)
        }
    }

    private func seed() {
        guard let request = study.setup else { return }
        // Everything found starts checked.
        included = Set(request.suggestions.map(\.id))
    }
}

// MARK: - Settings → Courses

struct CoursesSettingsView: View {
    @EnvironmentObject private var study: StudyModel
    @Environment(\.dismiss) private var dismiss
    @State private var editing: Course?
    @State private var isNew = false

    var body: some View {
        VStack(spacing: 0) {
            List {
                Section {
                    if study.activeCourses.isEmpty {
                        Text("No courses yet. Find them from your calendar and folders, or add one.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(study.activeCourses) { course in
                        CourseRow(course: course) {
                            isNew = false
                            editing = course
                        } trailing: {
                            Button("Archive") { study.setArchived(true, course) }
                                .buttonStyle(.borderless)
                        }
                    }
                    .onMove { study.move(from: $0, to: $1) }
                } header: {
                    Text("Courses (drag to reorder the shelf)")
                }
                if !study.archivedCourses.isEmpty {
                    Section("Archived") {
                        ForEach(study.archivedCourses) { course in
                            CourseRow(course: course) {
                                isNew = false
                                editing = course
                            } trailing: {
                                HStack {
                                    Button("Restore") { study.setArchived(false, course) }
                                    Button("Delete", role: .destructive) { study.delete(course) }
                                }
                                .buttonStyle(.borderless)
                            }
                        }
                    }
                }
            }
            Divider()
            HStack {
                Button("Find Courses…") { study.findCourses() }
                Button("Add Course…") {
                    isNew = true
                    editing = Course(name: "", code: "", color: CourseColors.next(after: study.courses))
                }
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(14)
        }
        .frame(minWidth: 520, idealWidth: 560, minHeight: 420, idealHeight: 520)
        .sheet(item: $editing) { course in
            CourseEditorView(course: course, isNew: isNew).environmentObject(study)
        }
    }
}

private struct CourseRow<Trailing: View>: View {
    let course: Course
    let edit: () -> Void
    @ViewBuilder let trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 2)
                .fill(Color(nsColor: NSColor(atlasHex: course.color)))
                .frame(width: 8, height: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(course.displayCode) · \(course.name)").lineLimit(1)
                Text([course.term, course.folderPath.map { ($0 as NSString).abbreviatingWithTildeInPath }]
                    .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Button("Edit…", action: edit).buttonStyle(.borderless)
            trailing()
        }
    }
}

// MARK: - Course editor

struct CourseEditorView: View {
    @EnvironmentObject private var study: StudyModel
    @Environment(\.dismiss) private var dismiss
    @State private var course: Course
    @State private var codeText: String
    @State private var aliasesText: String
    @State private var matchText: String
    @State private var notesKind: NotesKind
    @State private var notesValue: String
    @State private var notesExtra: String
    let isNew: Bool

    enum NotesKind: String, CaseIterable, Identifiable {
        case none, folder, obsidian, app, link
        var id: Self { self }
        var title: String {
            switch self {
            case .none: return "Not on this Mac"
            case .folder: return "A folder"
            case .obsidian: return "Obsidian note"
            case .app: return "An app"
            case .link: return "A link"
            }
        }
    }

    init(course: Course, isNew: Bool) {
        self.isNew = isNew
        _course = State(initialValue: course)
        _codeText = State(initialValue: course.code.isEmpty ? "" : course.displayCode)
        _aliasesText = State(initialValue: course.aliases.joined(separator: ", "))
        _matchText = State(initialValue: course.matchTerms.joined(separator: ", "))
        switch course.notes {
        case .none(let remark):
            _notesKind = State(initialValue: .none); _notesValue = State(initialValue: remark ?? ""); _notesExtra = State(initialValue: "")
        case .folder(let path):
            _notesKind = State(initialValue: .folder); _notesValue = State(initialValue: path); _notesExtra = State(initialValue: "")
        case .obsidian(let vault, let relative):
            _notesKind = State(initialValue: .obsidian); _notesValue = State(initialValue: vault); _notesExtra = State(initialValue: relative)
        case .app(let bundleID, let name):
            _notesKind = State(initialValue: .app); _notesValue = State(initialValue: bundleID); _notesExtra = State(initialValue: name)
        case .url(let url):
            _notesKind = State(initialValue: .link); _notesValue = State(initialValue: url); _notesExtra = State(initialValue: "")
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("Course") {
                    TextField("Name", text: $course.name, prompt: Text("Chemistry 101"))
                    TextField("Code", text: $codeText, prompt: Text("CHEM 101"))
                    if !codeText.isEmpty, CourseCode.parse(codeText) == nil {
                        Text("A code is 2–5 letters and 3–4 digits, like CHEM 101 or CS180.")
                            .font(.caption).foregroundStyle(.orange)
                    }
                    TextField("Also known as", text: $aliasesText, prompt: Text("Cross-listed codes, comma-separated"))
                    TextField("Term", text: $course.term, prompt: Text("Fall 2026"))
                    HStack {
                        Text("Colour")
                        Spacer()
                        ForEach(Array(CourseColors.palette.enumerated()), id: \.element) { index, hex in
                            Button { course.color = hex } label: {
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(Color(nsColor: NSColor(atlasHex: hex)))
                                    .frame(width: 16, height: 26)
                                    .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(Color.accentColor, lineWidth: course.color == hex ? 2 : 0))
                            }
                            .buttonStyle(.plain)
                            .help(CourseColors.names[index])
                        }
                        ColorPicker("", selection: Binding(
                            get: { Color(nsColor: NSColor(atlasHex: course.color)) },
                            set: { course.color = NSColor($0).atlasHex }
                        ), supportsOpacity: false)
                        .labelsHidden()
                    }
                }

                Section {
                    HStack {
                        Text("Folder")
                        Spacer()
                        Text(course.folderPath.map { ($0 as NSString).abbreviatingWithTildeInPath } ?? "None")
                            .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        Button("Choose…") {
                            if let path = Pickers.choosePath(folders: true) {
                                course.folderPath = path
                                course.folderBookmark = nil
                            }
                        }
                        if course.folderPath != nil {
                            Button("Clear") { course.folderPath = nil; course.folderBookmark = nil }
                        }
                    }
                    Picker("Notes", selection: $notesKind) {
                        ForEach(NotesKind.allCases) { Text($0.title).tag($0) }
                    }
                    notesFields
                    ForEach($course.links) { $link in
                        HStack {
                            Picker("", selection: $link.kind) {
                                ForEach(Course.Link.Kind.allCases, id: \.self) { Text($0.title).tag($0) }
                            }
                            .labelsHidden()
                            .fixedSize()
                            TextField("https://…", text: $link.url)
                            Button(role: .destructive) { course.links.removeAll { $0.id == link.id } } label: {
                                Image(systemName: "minus.circle")
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                    Button("Add Link") { course.links.append(Course.Link(kind: course.site == nil ? .site : .other, url: "")) }
                } header: {
                    Text("Where things are")
                }

                Section {
                    Toggle("Open the folder in Finder", isOn: $course.opens.folder)
                    Toggle("Open the notes", isOn: $course.opens.notes)
                    Toggle("Open the course site", isOn: $course.opens.site)
                } header: {
                    Text("Clicking the book")
                }

                Section {
                    TextField("Also match", text: $matchText, prompt: Text("Extra words in event titles, comma-separated"))
                } header: {
                    Text("Calendar")
                } footer: {
                    Text("Events count as this class when their title has its code (any spelling), its name, or one of these words.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(isNew ? "Add" : "Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(course.name.trimmingCharacters(in: .whitespaces).isEmpty || CourseCode.parse(codeText) == nil)
            }
            .padding(14)
        }
        .frame(minWidth: 520, idealWidth: 560, minHeight: 560, idealHeight: 680)
    }

    @ViewBuilder private var notesFields: some View {
        switch notesKind {
        case .none:
            TextField("Where they are", text: $notesValue, prompt: Text("e.g. Notability on iPad"))
        case .folder:
            HStack {
                Text(notesValue.isEmpty ? "No folder" : (notesValue as NSString).abbreviatingWithTildeInPath)
                    .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                Spacer()
                Button("Choose…") { if let path = Pickers.choosePath(folders: true) { notesValue = path } }
            }
        case .obsidian:
            HStack {
                Text(notesValue.isEmpty ? "No vault" : (notesValue as NSString).abbreviatingWithTildeInPath)
                    .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                Spacer()
                Button("Choose Vault…") { if let path = Pickers.choosePath(folders: true) { notesValue = path } }
            }
            TextField("Note or folder in the vault", text: $notesExtra, prompt: Text("Chemistry/CHEM101"))
        case .app:
            HStack {
                Text(notesExtra.isEmpty ? "No app" : notesExtra).foregroundStyle(.secondary)
                Spacer()
                Button("Choose App…") {
                    if let bundleID = Pickers.chooseApplication() {
                        notesValue = bundleID
                        notesExtra = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
                            .map { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") } ?? bundleID
                    }
                }
            }
        case .link:
            TextField("Link", text: $notesValue, prompt: Text("https://…"))
        }
    }

    private func save() {
        if let code = CourseCode.parse(codeText) { course.code = code.canonical }
        course.aliases = aliasesText.split(separator: ",").compactMap { CourseCode.parse(String($0))?.canonical }
        course.matchTerms = matchText.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        course.links.removeAll { $0.url.trimmingCharacters(in: .whitespaces).isEmpty }
        switch notesKind {
        case .none: course.notes = .none(remark: notesValue.isEmpty ? nil : notesValue)
        case .folder: course.notes = notesValue.isEmpty ? .none(remark: nil) : .folder(path: notesValue)
        case .obsidian: course.notes = notesValue.isEmpty ? .none(remark: nil) : .obsidian(vaultPath: notesValue, relativePath: notesExtra)
        case .app: course.notes = notesValue.isEmpty ? .none(remark: nil) : .app(bundleID: notesValue, name: notesExtra)
        case .link: course.notes = notesValue.isEmpty ? .none(remark: nil) : .url(notesValue)
        }
        study.save(course)
        dismiss()
    }
}
