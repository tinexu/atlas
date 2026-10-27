import AppKit
import AtlasCompanion
import AtlasCore
import SwiftUI
import UniformTypeIdentifiers

/// Companion settings: the character, where it sits, the optional AI layer,
/// what context it may use, and suggestions. Every data source is explained
/// in plain words, like the Permissions screen.
public struct CompanionSettingsView: View {
    @ObservedObject var controller: CompanionController
    @State private var previewState: CompanionState = .idle
    @State private var apiKey = ""
    @State private var hasKey = CompanionKeychain.apiKey() != nil
    @State private var importProblem: String?
    @State private var requestPreview: String?
    @State private var hotKeyDrafts = (companion: "", palette: "")
    @State private var log: [SuggestionLogEntry] = []
    @State private var commands: [AtlasStore.CompanionCommandRecord] = []
    @State private var confirmClear: ClearTarget?

    enum ClearTarget: String, Identifiable {
        case commands, launches, suggestions
        var id: String { rawValue }
    }

    public init(controller: CompanionController) {
        self.controller = controller
    }

    private var settings: CompanionSettings { controller.settings }

    private func binding<T>(_ keyPath: WritableKeyPath<CompanionSettings, T>) -> Binding<T> {
        Binding(get: { controller.settings[keyPath: keyPath] }, set: { value in controller.update { $0[keyPath: keyPath] = value } })
    }

    public var body: some View {
        Form {
            characterSection
            desktopSection
            aiSection
            contextSection
            suggestionsSection
            historySection
        }
        .formStyle(.grouped)
        .navigationTitle("Companion")
        .onAppear(perform: reload)
        .sheet(item: Binding(get: { requestPreview.map(PreviewText.init) }, set: { requestPreview = $0?.text })) { preview in
            RequestPreviewSheet(text: preview.text)
        }
        .confirmationDialog(clearTitle, isPresented: Binding(get: { confirmClear != nil }, set: { if !$0 { confirmClear = nil } })) {
            Button("Clear", role: .destructive) { clear() }
        }
    }

    // MARK: Character

    private var characterSection: some View {
        Section {
            HStack(alignment: .top, spacing: 20) {
                VStack(spacing: 8) {
                    CharacterView(settings: settings,
                                  presentation: .make(for: previewState, intensity: settings.intensity,
                                                      reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion),
                                  paused: false)
                        .frame(width: 150, height: 150)
                        .background(Color.black.opacity(0.25), in: RoundedRectangle(cornerRadius: 12))
                    Picker("Preview", selection: $previewState) {
                        ForEach(CompanionState.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .labelsHidden()
                    .frame(width: 150)
                }
                VStack(alignment: .leading, spacing: 10) {
                    Picker("Character", selection: binding(\.character)) {
                        ForEach(CompanionSettings.Character.allCases) { Text($0.title).tag($0) }
                    }
                    if settings.character == .custom {
                        HStack {
                            Text(settings.customCharacterPath.map { ($0 as NSString).lastPathComponent } ?? "No file chosen")
                                .foregroundStyle(.secondary)
                            Button("Choose USDZ…", action: chooseCustom)
                        }
                        if let importProblem { Text(importProblem).font(.caption).foregroundStyle(.orange) }
                        Text("Up to \(CharacterLimits.maxTriangles.formatted()) polygons and \(ByteCountFormatter.string(fromByteCount: CharacterLimits.maxFileBytes, countStyle: .file)). Accessories don't apply to custom characters.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    HStack {
                        ColorPicker("Primary", selection: colorBinding(\.primaryColor), supportsOpacity: false)
                        ColorPicker("Secondary", selection: colorBinding(\.secondaryColor), supportsOpacity: false)
                    }
                    Picker("Accessory", selection: binding(\.accessory)) {
                        ForEach(CompanionSettings.Accessory.allCases) { Text($0.title).tag($0) }
                    }
                    .disabled(settings.character == .custom)
                    Picker("Size", selection: binding(\.size)) {
                        ForEach(CompanionSettings.Size.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    Picker("Animation", selection: binding(\.intensity)) {
                        ForEach(CompanionSettings.Intensity.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    Text("Reduced swaps motion for colour changes; Still shows a picture. Reduce Motion in System Settings is always respected. The look never changes what the Companion can do.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Character")
        }
    }

    private func colorBinding(_ keyPath: WritableKeyPath<CompanionSettings, String>) -> Binding<Color> {
        Binding(get: { Color(nsColor: NSColor(companionHex: controller.settings[keyPath: keyPath]) ?? .systemBlue) },
                set: { color in controller.update { $0[keyPath: keyPath] = NSColor(color).companionHex } })
    }

    private func chooseCustom() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "usdz") ?? .data]
        panel.prompt = "Use Character"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if let problem = CharacterImport.problem(with: url) {
            importProblem = problem
        } else {
            importProblem = nil
            controller.update {
                $0.customCharacterPath = url.path
                $0.character = .custom
            }
        }
    }

    // MARK: Desktop

    private var desktopSection: some View {
        Section {
            Picker("Show the Companion", selection: binding(\.overlayMode)) {
                ForEach(CompanionSettings.OverlayMode.allCases) { Text($0.title).tag($0) }
            }
            Toggle("Click-through (never blocks clicks)", isOn: binding(\.clickThrough))
            Text(settings.clickThrough
                 ? "Clicks pass through the character. Press \(display(settings.companionHotKey)) to make it clickable and open the command box."
                 : "The character can be clicked for quick controls and dragged to move it.")
                .font(.caption).foregroundStyle(.secondary)
            hotKeyField("Companion shortcut", text: $hotKeyDrafts.companion, current: settings.companionHotKey) { value in
                controller.update { $0.companionHotKey = value }
            }
            hotKeyField("Command palette shortcut", text: $hotKeyDrafts.palette, current: settings.paletteHotKey) { value in
                controller.update { $0.paletteHotKey = value }
            }
            ForEach(controller.hotKeyProblems, id: \.self) { problem in
                Label(problem, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
            }
            Button("Move Back to the Corner") { controller.update { $0.positions = [:] } }
            Text("Its position is remembered for each display arrangement and snaps back on-screen when displays change. It stops animating while hidden, while the screen is locked and in Low Power Mode.")
                .font(.caption).foregroundStyle(.secondary)
        } header: {
            Text("On the Desktop")
        }
    }

    private func hotKeyField(_ label: String, text: Binding<String>, current: String, apply: @escaping (String) -> Void) -> some View {
        HStack {
            Text(label)
            Spacer()
            TextField("e.g. opt+space", text: text)
                .frame(width: 150)
                .onSubmit { apply(text.wrappedValue.trimmingCharacters(in: .whitespaces)) }
            Text(display(current)).foregroundStyle(.secondary).frame(minWidth: 50)
        }
    }

    private func display(_ text: String) -> String {
        (try? HotKey.parse(text).get())?.display ?? text
    }

    // MARK: AI

    private var aiSection: some View {
        Section {
            Picker("AI", selection: binding(\.aiProvider)) {
                ForEach(CompanionSettings.AIProvider.allCases) { Text($0.title).tag($0) }
            }
            if let status = controller.aiStatus {
                Label(status, systemImage: status.hasPrefix("Active") ? "checkmark.circle" : "exclamationmark.circle")
                    .font(.caption)
                    .foregroundStyle(status.hasPrefix("Active") ? .green : .orange)
            }
            switch settings.aiProvider {
            case .off:
                Text("Commands are understood by ATLAS's built-in parser. Nothing leaves your Mac.")
                    .font(.caption).foregroundStyle(.secondary)
            case .onDevice:
                Text("Commands the built-in parser can't match are planned by Apple's on-device model. Nothing leaves your Mac.")
                    .font(.caption).foregroundStyle(.secondary)
            case .cloud:
                TextField("Model", text: binding(\.cloudModel))
                HStack {
                    SecureField(hasKey ? "API key saved in Keychain" : "Claude API key", text: $apiKey)
                    Button("Save Key") {
                        CompanionKeychain.setAPIKey(apiKey.trimmingCharacters(in: .whitespaces))
                        apiKey = ""
                        hasKey = CompanionKeychain.apiKey() != nil
                        Task { await controller.refreshAIStatus() }
                    }
                    .disabled(apiKey.isEmpty)
                    if hasKey {
                        Button("Remove", role: .destructive) {
                            CompanionKeychain.setAPIKey(nil)
                            hasKey = false
                            Task { await controller.refreshAIStatus() }
                        }
                    }
                }
                Text("Only commands the built-in parser can't match are sent to Anthropic, with the list of actions, the names of your Spaces, workflows and layouts, and the context you allow below. Never file contents, screen contents or keystrokes.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Preview Request…") { previewRequest() }
            }
            Text("An AI plan is always shown first and runs only when you press Return or click Run. It can only choose actions ATLAS already has; anything else is rejected. If AI is off or fails, the built-in parser is used and the palette says so.")
                .font(.caption).foregroundStyle(.secondary)
        } header: {
            Text("AI (optional)")
        }
    }

    private func previewRequest() {
        let vocabulary = controller.vocabulary()
        let request = AIRequest.make(text: "set up for my interview", registry: controller.core.registry, vocabulary: vocabulary,
                                     context: controller.context())
        let provider = CloudModelProvider(model: settings.cloudModel)
        var body = provider.body(for: request.modelRequest)
        body["system"] = request.instructions
        let json = (try? JSONSerialization.data(withJSONObject: body, options: [.prettyPrinted, .sortedKeys]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? request.preview
        requestPreview = "POST https://api.anthropic.com/v1/messages\n(example command: “set up for my interview”)\n\n" + json
    }

    // MARK: Context

    private var contextSection: some View {
        Section {
            contextToggle("Active Space", \.activeSpace, "The name of the Space you're in, so “open my notes” can mean that Space's notes.")
            contextToggle("Frontmost app", \.frontmostApp, "The name of the app in front. Never its windows or what's in them.")
            contextToggle("Running workflows and recent results", \.runs, "Names and outcomes from Run History, used to explain failures.")
            contextToggle("ATLAS timers", \.timers, "Timers started by ATLAS and when they end.")
            contextToggle("Mac Health readings", \.health, "CPU, memory and free disk, for low-disk suggestions.")
            contextToggle("Orbit review queue", \.reviews, "How many files are waiting for your review.")
            Text("All of this is read on your Mac. It's sent anywhere only if you turn on the cloud AI provider, and then only with a command it has to plan. ATLAS never reads your screen, logs keystrokes or captures window contents.")
                .font(.caption).foregroundStyle(.secondary)
        } header: {
            Text("What the Companion May Use")
        }
    }

    private func contextToggle(_ title: String, _ keyPath: WritableKeyPath<CompanionSettings.ContextOptions, Bool>, _ explanation: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Toggle(title, isOn: Binding(get: { controller.settings.context[keyPath: keyPath] },
                                        set: { value in controller.update { $0.context[keyPath: keyPath] = value } }))
            Text(explanation).font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: Suggestions

    private var suggestionsSection: some View {
        Section {
            Toggle("Show suggestions", isOn: binding(\.suggestionsEnabled))
            Text("At most one every 15 minutes, always dismissible.").font(.caption).foregroundStyle(.secondary)
            ForEach(Suggestion.Kind.allCases, id: \.self) { kind in
                Toggle(kind.title, isOn: Binding(
                    get: { !controller.settings.mutedSuggestions.contains(kind.rawValue) },
                    set: { on in controller.update { if on { $0.mutedSuggestions.remove(kind.rawValue) } else { $0.mutedSuggestions.insert(kind.rawValue) } } }
                ))
                .disabled(!settings.suggestionsEnabled)
            }
            VStack(alignment: .leading, spacing: 2) {
                Toggle("Notice repeated app launches", isOn: binding(\.repetitionDetection))
                Text("Keeps the bundle IDs and times of apps you open yourself for 14 days, to spot the same 2–4 apps opened in the same order on 3 or more days. It suggests a workflow; it never creates one on its own.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Button("Clear App Launch History…") { confirmClear = .launches }
            if !log.isEmpty {
                DisclosureGroup("Why suggestions appeared (\(log.count))") {
                    ForEach(log) { entry in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(entry.title).font(.callout)
                                Spacer()
                                Text(entry.state.rawValue.capitalized).font(.caption).foregroundStyle(.secondary)
                            }
                            Text("\(entry.createdAt.formatted(date: .abbreviated, time: .shortened)) · \(entry.reason)")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Button("Clear Log…") { confirmClear = .suggestions }
                }
            }
            Group {
                DisclosureGroup("Focus Spaces") {
                    Text("While one of these Spaces is active (or a timer named focus, study or deep work runs), the Companion stays calm and still.")
                        .font(.caption).foregroundStyle(.secondary)
                    ForEach(controller.vocabulary().spaces, id: \.id) { space in
                        Toggle(space.name, isOn: Binding(
                            get: { controller.settings.focusSpaceIDs.contains(space.id) },
                            set: { on in controller.update { if on { $0.focusSpaceIDs.append(space.id) } else { $0.focusSpaceIDs.removeAll { $0 == space.id } } } }
                        ))
                    }
                }
                DisclosureGroup("Favourite workflows") {
                    Text("Shown first in quick controls and the palette.").font(.caption).foregroundStyle(.secondary)
                    ForEach(controller.vocabulary().workflows, id: \.id) { workflow in
                        Toggle(workflow.name, isOn: Binding(
                            get: { controller.settings.favoriteWorkflowIDs.map(\.uuidString).contains(workflow.id) },
                            set: { on in
                                guard let id = UUID(uuidString: workflow.id) else { return }
                                controller.update { if on { $0.favoriteWorkflowIDs.append(id) } else { $0.favoriteWorkflowIDs.removeAll { $0 == id } } }
                            }
                        ))
                    }
                }
            }
        } header: {
            Text("Suggestions")
        }
    }

    // MARK: History

    private var historySection: some View {
        Section {
            if commands.isEmpty {
                Text("No commands yet. Press \(display(settings.paletteHotKey)) to open the command palette.").foregroundStyle(.secondary)
            } else {
                ForEach(commands.prefix(10)) { command in
                    HStack {
                        Text(command.text)
                        Spacer()
                        Text(command.summary).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Button("Clear Command History…") { confirmClear = .commands }
            }
            Text("The last 50 commands are kept on this Mac for ↑ in the palette.").font(.caption).foregroundStyle(.secondary)
        } header: {
            Text("Command History")
        }
    }

    // MARK: Helpers

    private var clearTitle: String {
        switch confirmClear {
        case .commands: return "Clear command history?"
        case .launches: return "Clear app launch history?"
        case .suggestions: return "Clear the suggestion log?"
        case nil: return ""
        }
    }

    private func clear() {
        let store = controller.core.store
        switch confirmClear {
        case .commands: try? store.clearCompanionCommands()
        case .launches: try? store.clearAppLaunches()
        case .suggestions: try? store.clearSuggestionLog()
        case nil: break
        }
        confirmClear = nil
        reload()
    }

    private func reload() {
        hotKeyDrafts = (settings.companionHotKey, settings.paletteHotKey)
        log = (try? controller.core.store.suggestionLog()) ?? []
        commands = (try? controller.core.store.companionCommands()) ?? []
        hasKey = CompanionKeychain.apiKey() != nil
    }
}

private struct PreviewText: Identifiable {
    let text: String
    var id: String { text }
}

private struct RequestPreviewSheet: View {
    let text: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Exactly what would be sent").font(.headline)
            Text("Your API key goes in a header and isn't shown. Nothing is sent from this preview.")
                .font(.caption).foregroundStyle(.secondary)
            ScrollView {
                Text(text).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(8)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 640, height: 520)
    }
}
