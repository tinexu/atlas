import AppKit
import AtlasCompanion
import AtlasCore
import AtlasOrbit
import SwiftUI

/// The palette's state: type-ahead, the plan preview, choices, file results.
@MainActor
final class PaletteModel: ObservableObject {
    enum Mode: Equatable {
        case browse
        /// "Activate Coding Lab — Deep Work". Return runs it; Esc goes back.
        case preview(CommandPlan, note: String?)
        case choices(String, [CommandPlan])
        case files(String, [FileEntry])
        case message(String, note: String?)
        case thinking
    }

    @Published var text = "" {
        didSet { if text != oldValue, !isRecalling { textChanged() } }
    }
    @Published private(set) var items: [PaletteItem] = []
    @Published var selection = 0
    @Published private(set) var mode: Mode = .browse

    private weak var controller: CompanionController?
    private var catalog: PaletteCatalog?
    private var history: [String] = []
    private var historyIndex: Int?
    private var isRecalling = false
    private var parseTask: Task<Void, Never>?
    /// What goes in history for the command being run: the typed command, or
    /// the name of the item picked from the list.
    private var recordedText = ""
    var close: () -> Void = {}
    var cancelled: () -> Void = {}

    init(controller: CompanionController) {
        self.controller = controller
    }

    func opened(text initial: String) {
        guard let controller else { return }
        catalog = controller.catalog()
        history = controller.history()
        historyIndex = nil
        recordedText = ""
        mode = .browse
        isRecalling = true
        text = initial
        isRecalling = false
        textChanged()
        controller.commandOpened()
    }

    func closed() {
        parseTask?.cancel()
        controller?.commandClosed()
        controller?.scheduleClickThrough()
    }

    private func textChanged() {
        if case .browse = mode {} else { mode = .browse }
        historyIndex = nil
        guard let catalog, let controller else { return }
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            items = catalog.defaults(favorites: controller.settings.favoriteWorkflowIDs, recent: history)
        } else {
            var found = catalog.search(trimmed)
            // Typed text as a command, first when nothing names it closely.
            let command = PaletteItem(id: "command", section: .command, title: "“\(trimmed)”", subtitle: "Do this",
                                      symbol: "return", plan: CommandPlan(kind: .findFiles(trimmed), summary: trimmed, hasSideEffects: false),
                                      score: 0)
            let strong = (found.first?.score ?? 0) >= 0.85 && trimmed.split(separator: " ").count <= 3
            if strong { found.append(command) } else { found.insert(command, at: 0) }
            items = found
        }
        selection = 0
    }

    func move(_ delta: Int) {
        if case .choices(_, let plans) = mode {
            selection = max(0, min(plans.count - 1, selection + delta))
            return
        }
        guard !items.isEmpty else { return }
        selection = max(0, min(items.count - 1, selection + delta))
    }

    /// Up arrow on an empty field (or while recalling) walks back through history.
    func recall(_ delta: Int) -> Bool {
        guard case .browse = mode, text.isEmpty || historyIndex != nil, !history.isEmpty else { return false }
        let next = (historyIndex ?? -1) + delta
        guard next >= -1, next < history.count else { return true }
        historyIndex = next
        isRecalling = true
        text = next == -1 ? "" : history[next]
        isRecalling = false
        if next == -1 { textChanged() } else if let catalog { items = catalog.search(text); selection = 0 }
        return true
    }

    /// Return.
    func submit() {
        switch mode {
        case .preview(let plan, _):
            run(plan)
        case .choices(_, let plans):
            guard plans.indices.contains(selection) else { return }
            choose(plans[selection])
        case .files(_, let entries):
            guard entries.indices.contains(selection) else { return }
            run(PaletteCatalog.openFilePlan(entries[selection]))
        case .message, .thinking:
            break
        case .browse:
            guard items.indices.contains(selection) else { return }
            let item = items[selection]
            if item.section == .command {
                recordedText = text
                interpret(text)
            } else {
                recordedText = item.title
                choose(item.plan)
            }
        }
    }

    /// Esc: back out of a preview, otherwise close.
    func cancel() {
        switch mode {
        case .browse: cancelled()
        default:
            mode = .browse
            textChanged()
        }
    }

    func choose(_ plan: CommandPlan) {
        if case .findFiles(let query) = plan.kind {
            showFiles(query)
        } else if plan.needsConfirmation {
            mode = .preview(plan, note: nil)
        } else {
            run(plan)
        }
    }

    private func interpret(_ raw: String) {
        guard let controller else { return }
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        mode = .thinking
        controller.commandParsing()
        let vocabulary = controller.vocabulary()
        let resolver = controller.resolver(for: vocabulary)
        let context = controller.context()
        parseTask?.cancel()
        parseTask = Task { [weak self] in
            let result = await resolver.resolve(text, context: context)
            guard let self, !Task.isCancelled else { return }
            controller.commandParsed()
            switch result.outcome {
            case .plan(let plan):
                if case .findFiles(let query) = plan.kind {
                    self.showFiles(query, note: result.note)
                } else if plan.needsConfirmation {
                    self.mode = .preview(plan, note: result.note)
                } else {
                    self.run(plan)
                }
            case .choices(let prompt, let plans):
                self.selection = 0
                self.mode = .choices(prompt, plans)
            case .unknown(let message):
                self.mode = .message(message, note: result.note)
            }
        }
    }

    private func showFiles(_ query: String, note: String? = nil) {
        guard let controller else { return }
        let results = (try? controller.files?.search(SearchQuery.parse(query), limit: 30)) ?? []
        var entries = results.map(\.entry)
        if entries.isEmpty {
            // "project specifications" → try each word, and word stems.
            let words = NameMatcher.keywords(query).filter { $0.count >= 3 }
            var seen = Set<String>()
            for word in words {
                for term in [word, String(word.prefix(max(4, word.count - 5)))] {
                    for result in (try? controller.files?.search(SearchQuery.parse(term), limit: 10)) ?? [] where seen.insert(result.entry.path).inserted {
                        entries.append(result.entry)
                    }
                }
            }
        }
        selection = 0
        if entries.isEmpty {
            let hint = controller.files == nil || (try? controller.core.store.locations().isEmpty) ?? true
                ? " Add folders in Orbit so ATLAS can search them." : ""
            mode = .message("No files match “\(query)”.\(hint)", note: note)
        } else {
            mode = .files(query, Array(entries.prefix(30)))
        }
        controller.run(findCommand: query, text: recordedText.isEmpty ? text : recordedText)
    }

    private func run(_ plan: CommandPlan) {
        controller?.execute(plan, text: recordedText.isEmpty ? text : recordedText, source: .palette)
        recordedText = ""
        close()
    }
}

extension CompanionController {
    /// Records a file search as a command (history and companion.command).
    func run(findCommand query: String, text: String) {
        let plan = CommandPlan(kind: .findFiles(query), summary: "Find files matching “\(query)”", hasSideEffects: false)
        Task { _ = await runner.run(plan, text: text, source: .palette) }
    }
}

/// Owns the palette panel: Spotlight-style, near the Companion or centred.
@MainActor
final class PaletteWindowController: NSObject, NSWindowDelegate {
    private weak var controller: CompanionController?
    private var panel: OverlayPanel?
    private let model: PaletteModel
    /// The app that was in front before the palette opened.
    private var previousApp: NSRunningApplication?
    private var shownAt = Date.distantPast

    init(controller: CompanionController) {
        self.controller = controller
        model = PaletteModel(controller: controller)
        super.init()
        model.close = { [weak self] in self?.hide() }
        model.cancelled = { [weak self] in self?.hide(returningFocus: true) }
    }

    var isVisible: Bool { panel?.isVisible ?? false }

    func show(near character: CGRect, text: String = "") {
        let size = CGSize(width: 620, height: 420)
        if panel == nil {
            let panel = OverlayPanel(size: size, acceptsKey: true)
            panel.level = .floating
            panel.hasShadow = true
            panel.delegate = self
            panel.contentView = NSHostingView(rootView: PaletteView(model: model))
            self.panel = panel
        }
        guard let panel else { return }
        let screen = NSScreen.screens.first { $0.frame.intersects(character) } ?? NSScreen.main ?? NSScreen.screens.first
        let visible = screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        var origin = CGPoint(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2 + visible.height * 0.12)
        if character != .zero {
            // Above or beside the character, kept on its screen.
            origin = CGPoint(x: character.midX - size.width / 2, y: character.maxY + 8)
            if origin.y + size.height > visible.maxY { origin.y = character.minY - size.height - 8 }
            if origin.y < visible.minY { origin = CGPoint(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2) }
            origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - size.width - 8)
        }
        panel.setFrame(CGRect(origin: origin, size: size), display: true)
        model.opened(text: text)
        // Typing needs ATLAS to be the active app. Remember what was in front
        // so Esc can hand focus straight back.
        if !NSApp.isActive {
            previousApp = NSWorkspace.shared.frontmostApplication
            NSApp.activate()
        }
        panel.makeKeyAndOrderFront(nil)
        shownAt = Date()
        controller?.paletteVisible = true
        focusField(attempt: 0)
    }

    /// Puts the cursor in the text field through AppKit, which keeps ATLAS in
    /// the background. The field may not exist yet the first time, so retry.
    private func focusField(attempt: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + (attempt == 0 ? 0 : 0.05)) { [weak self] in
            guard let self, let panel = self.panel, panel.isVisible else { return }
            guard let field = Self.textField(in: panel.contentView) else {
                if attempt < 10 { self.focusField(attempt: attempt + 1) }
                return
            }
            panel.makeFirstResponder(field)
        }
    }

    private static func textField(in view: NSView?) -> NSTextField? {
        guard let view else { return nil }
        if let field = view as? NSTextField, field.isEditable { return field }
        for child in view.subviews {
            if let field = textField(in: child) { return field }
        }
        return nil
    }

    /// `returningFocus`: Esc gives focus back to the app you were using. After
    /// running a command, focus stays wherever the command put it.
    func hide(returningFocus: Bool = false) {
        guard let panel, panel.isVisible else { return }
        panel.orderOut(nil)
        model.closed()
        controller?.paletteVisible = false
        if returningFocus, let previousApp, !previousApp.isTerminated {
            previousApp.activate()
        }
        previousApp = nil
    }

    /// Clicking elsewhere closes the palette. If macOS hands focus straight
    /// back to the previous app as it opens, it stays up so one click focuses it.
    func windowDidResignKey(_ notification: Notification) {
        guard Date().timeIntervalSince(shownAt) > 1 else { return }
        hide()
    }
}

struct PaletteView: View {
    @ObservedObject var model: PaletteModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "sparkle.magnifyingglass").font(.title2).foregroundStyle(.secondary)
                TextField("Open my coding room, run morning setup, find…", text: $model.text)
                    .textFieldStyle(.plain)
                    .font(.title2)
                    .onSubmit { model.submit() }
                    .onKeyPress(.downArrow) { model.move(1); return .handled }
                    .onKeyPress(.upArrow) {
                        if model.recall(1) { return .handled }
                        model.move(-1)
                        return .handled
                    }
                    .onKeyPress(.escape) { model.cancel(); return .handled }
            }
            .padding(14)
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            footer
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.separator))

        .onExitCommand { model.cancel() }
    }

    @ViewBuilder
    private var content: some View {
        switch model.mode {
        case .browse:
            ScrollViewReader { proxy in
                List {
                    ForEach(Array(model.items.enumerated()), id: \.element.id) { index, item in
                        row(icon: item.symbol, title: item.title, subtitle: item.subtitle, section: item.section.rawValue, selected: index == model.selection)
                            .id(item.id)
                            .onTapGesture {
                                model.selection = index
                                model.submit()
                            }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .onChange(of: model.selection) { _, new in
                    if model.items.indices.contains(new) { proxy.scrollTo(model.items[new].id) }
                }
                .overlay {
                    if model.items.isEmpty {
                        Text("Type a Space, workflow, app, layout or file, or a short command.")
                            .foregroundStyle(.secondary)
                    }
                }
            }
        case .preview(let plan, let note):
            VStack(alignment: .leading, spacing: 12) {
                Label(plan.fromAI ? "Suggested plan" : "This will:", systemImage: plan.fromAI ? "sparkles" : "list.bullet.clipboard")
                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Text(plan.summary).font(.title3.weight(.semibold))
                ForEach(plan.details, id: \.self) { line in
                    Label(line, systemImage: "chevron.right").font(.callout).foregroundStyle(.secondary)
                }
                if let note { noteView(note) }
                Spacer()
                HStack {
                    Spacer()
                    Button("Cancel") { model.cancel() }
                    Button(plan.fromAI ? "Run This Plan" : "Run") { model.submit() }
                        .buttonStyle(.borderedProminent)
                }
            }
            .padding(18)
        case .choices(let prompt, let plans):
            VStack(alignment: .leading, spacing: 6) {
                Text(prompt).font(.headline).padding(.horizontal, 14).padding(.top, 12)
                List {
                    ForEach(Array(plans.enumerated()), id: \.element.id) { index, plan in
                        row(icon: "questionmark.circle", title: plan.summary, subtitle: plan.details.first ?? "", section: "", selected: index == model.selection)
                            .onTapGesture {
                                model.selection = index
                                model.submit()
                            }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        case .files(let query, let entries):
            VStack(alignment: .leading, spacing: 6) {
                Text("Files matching “\(query)”").font(.headline).padding(.horizontal, 14).padding(.top, 12)
                List {
                    ForEach(Array(entries.enumerated()), id: \.element.path) { index, entry in
                        row(icon: entry.isFolder ? "folder" : "doc", title: entry.name, subtitle: entry.parent.abbreviatedPath, section: "",
                            selected: index == model.selection)
                            .onTapGesture {
                                model.selection = index
                                model.submit()
                            }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        case .message(let message, let note):
            VStack(alignment: .leading, spacing: 10) {
                Label(message, systemImage: "questionmark.bubble").font(.callout)
                if let note { noteView(note) }
                Text("Try: “open my coding room”, “run morning setup”, “start a 25 minute study timer”, “show me what's taking up storage”.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
            }
            .padding(18)
        case .thinking:
            ProgressView("Working out what you mean…").padding()
        }
    }

    private func noteView(_ note: String) -> some View {
        Label(note, systemImage: "info.circle").font(.caption).foregroundStyle(.secondary)
    }

    private func row(icon: String, title: String, subtitle: String, section: String, selected: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).frame(width: 22).foregroundStyle(selected ? .white : .secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).lineLimit(1)
                if !subtitle.isEmpty {
                    Text(subtitle).font(.caption).lineLimit(1).foregroundStyle(selected ? .white.opacity(0.85) : .secondary)
                }
            }
            Spacer()
            if !section.isEmpty {
                Text(section).font(.caption2).foregroundStyle(selected ? .white.opacity(0.8) : .secondary)
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .foregroundStyle(selected ? .white : .primary)
        .background(selected ? Color.accentColor : .clear, in: RoundedRectangle(cornerRadius: 7))
        .contentShape(Rectangle())
        .listRowSeparator(.hidden)
        .listRowInsets(EdgeInsets(top: 1, leading: 6, bottom: 1, trailing: 6))
    }

    private var footer: some View {
        HStack(spacing: 14) {
            switch model.mode {
            case .preview: hint("return", "Run"); hint("esc", "Back")
            case .browse: hint("↑↓", "Choose"); hint("return", "Open"); hint("↑", "History"); hint("esc", "Close")
            default: hint("↑↓", "Choose"); hint("return", "Open"); hint("esc", "Back")
            }
            Spacer()
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private func hint(_ key: String, _ label: String) -> some View {
        HStack(spacing: 4) {
            Text(key).padding(.horizontal, 4).background(.quaternary, in: RoundedRectangle(cornerRadius: 3))
            Text(label)
        }
    }
}
