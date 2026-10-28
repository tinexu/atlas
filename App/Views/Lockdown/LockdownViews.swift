import AppKit
import AtlasCore
import SwiftUI

// MARK: - "Lock in"

/// Asked when entering a Space that uses lockdown: which mode, how long.
struct LockdownStartView: View {
    @EnvironmentObject private var lockdown: LockdownModel
    let pending: LockdownModel.PendingStart
    @State private var modeID: UUID?
    @State private var minutes: Int
    @State private var custom = ""

    private static let picks: [(String, Int)] = [("25 min", 25), ("50 min", 50), ("1 h", 60), ("2 h", 120), ("3 h", 180)]

    init(pending: LockdownModel.PendingStart) {
        self.pending = pending
        _modeID = State(initialValue: pending.settings.mode(id: nil)?.id)
        let last = pending.settings.lastChoiceMinutes ?? 0
        _minutes = State(initialValue: last > 0 ? last : pending.settings.defaultMinutes)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(spacing: 14) {
                Image(systemName: "lock.fill")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: 46, height: 46)
                    .background(Circle().fill(Color.accentColor.gradient))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Lock in").font(.title2.weight(.bold))
                    Text("Entering \(pending.spaceName)").foregroundStyle(.secondary)
                }
            }

            if !modes.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text("What are you working on?").font(.headline)
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                        ForEach(modes) { mode in
                            ModeCard(mode: mode, isSelected: mode.id == modeID) { modeID = mode.id }
                        }
                    }
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                Text("For how long?").font(.headline)
                HStack(spacing: 6) {
                    ForEach(Self.picks, id: \.1) { title, value in
                        Chip(title: title, isSelected: customMinutes == nil && minutes == value) {
                            minutes = value
                            custom = ""
                        }
                    }
                    HStack(spacing: 4) {
                        TextField("Other", text: $custom)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 56)
                            .onSubmit(lockIn)
                        Text("min").font(.callout).foregroundStyle(.secondary)
                    }
                    .padding(.leading, 4)
                }
            }

            Text("Everything outside this mode stays out of reach until \(Date().addingTimeInterval(Double(chosenMinutes) * 60).formatted(date: .omitted, time: .shortened)). You can always add time or end early.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
                Button("No lockdown") { lockdown.choose(minutes: nil) }
                    .buttonStyle(.link)
                    .help("Enter the Space normally")
                Spacer()
                Button("Cancel", role: .cancel) { lockdown.cancelStart() }
                    .keyboardShortcut(.cancelAction)
                    .controlSize(.large)
                Button(action: lockIn) {
                    Text("Lock in for \(LockdownFormat.duration(Double(chosenMinutes) * 60))")
                        .padding(.horizontal, 6)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(26)
        .frame(width: 480)
    }

    private var modes: [LockdownMode] { pending.settings.modes }

    private var customMinutes: Int? {
        guard let value = Int(custom.trimmingCharacters(in: .whitespaces)), (1...12 * 60).contains(value) else { return nil }
        return value
    }

    private var chosenMinutes: Int { customMinutes ?? minutes }

    private func lockIn() {
        lockdown.choose(minutes: Double(chosenMinutes), modeID: modeID)
    }
}

private struct ModeCard: View {
    let mode: LockdownMode
    let isSelected: Bool
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Image(systemName: mode.symbolName)
                        .font(.title3)
                        .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                    Spacer()
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.accentColor)
                    }
                }
                Text(mode.name).font(.body.weight(.semibold))
                Text(mode.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: 96, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 12).fill(isSelected ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.04)))
            .overlay(RoundedRectangle(cornerRadius: 12)
                .strokeBorder(isSelected ? Color.accentColor : Color.primary.opacity(0.1), lineWidth: isSelected ? 2 : 1))
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct Chip: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.callout.weight(.medium))
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(Capsule().fill(isSelected ? Color.accentColor : Color.primary.opacity(0.07)))
                .foregroundStyle(isSelected ? Color.white : Color.primary)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

// MARK: - Pomodoro window

struct LockdownPanelView: View {
    @EnvironmentObject private var lockdown: LockdownModel

    var body: some View {
        Group {
            if let request = lockdown.exitRequest, let session = lockdown.session {
                ExitConfirmation(request: request, session: session)
            } else if let session = lockdown.session {
                ActiveLockdown(session: session)
            } else if let summary = lockdown.summary {
                LockdownSummaryView(summary: summary)
            } else {
                Text("Lockdown is off.").foregroundStyle(.secondary)
                    .padding(24)
            }
        }
        .frame(width: 300)
        .padding(.top, 10)
    }
}

private struct ActiveLockdown: View {
    @EnvironmentObject private var lockdown: LockdownModel
    let session: LockdownSession
    @State private var showsEndPicker = false
    @State private var newEnd = Date()

    var body: some View {
        VStack(spacing: 12) {
            VStack(spacing: 2) {
                Label("Locked in · \(session.spaceName)", systemImage: "lock.fill")
                    .font(.headline)
                if let mode = session.modeName {
                    Text(mode).font(.caption).foregroundStyle(.secondary)
                }
            }
            Text(phaseTitle)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            phaseCountdown
                .font(.system(size: 52, weight: .semibold, design: .rounded).monospacedDigit())
            HStack {
                Button(isRunning ? "Pause" : "Start", systemImage: isRunning ? "pause.fill" : "play.fill") { lockdown.togglePhase() }
                Button("Skip", systemImage: "forward.end.fill") { lockdown.skipPhase() }
            }
            .controlSize(.large)

            Divider()
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text("Lockdown: \(LockdownFormat.duration(session.remaining(at: context.date))) left · until \(session.endsAt.formatted(date: .omitted, time: .shortened))")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Menu("Change time") {
                    Button("Add 15 min") { lockdown.addTime(minutes: 15) }
                    Button("Add 30 min") { lockdown.addTime(minutes: 30) }
                    Button("Add 1 hour") { lockdown.addTime(minutes: 60) }
                    Divider()
                    Button("Remove 15 min…") { lockdown.request(.remove(minutes: 15)) }
                    Button("Remove 30 min…") { lockdown.request(.remove(minutes: 30)) }
                    Divider()
                    Button("New end time…") {
                        newEnd = session.endsAt
                        showsEndPicker = true
                    }
                }
                .fixedSize()
                .popover(isPresented: $showsEndPicker) {
                    VStack(alignment: .leading) {
                        DatePicker("End at", selection: $newEnd, in: Date()..., displayedComponents: .hourAndMinute)
                        HStack {
                            Spacer()
                            Button("Apply") {
                                showsEndPicker = false
                                lockdown.request(.setEnd(newEnd))
                            }
                            .keyboardShortcut(.defaultAction)
                        }
                    }
                    .padding()
                    .frame(width: 240)
                }
                Button("End lockdown…", role: .destructive) { lockdown.request(.end) }
            }
            if !session.skipped.isEmpty {
                Text("Not installed, skipped: \(session.skipped.joined(separator: ", "))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(18)
    }

    private var phase: FocusSession? {
        guard let phase = lockdown.phaseSession, phase.id == session.phase.sessionID else { return nil }
        return phase
    }

    private var isRunning: Bool { phase?.state == .running }

    private var phaseTitle: String {
        let every = max(1, session.settings.pomodoro.longBreakEvery)
        switch session.phase.kind {
        case .focus:
            return "Focus \(session.phase.completedFocus % every + 1) of \(every)"
        case .shortBreak, .longBreak:
            return session.phase.title + (session.settings.pomodoro.unlockDuringBreaks ? " · apps unlocked" : "")
        }
    }

    @ViewBuilder private var phaseCountdown: some View {
        if let phase, phase.state == .running {
            Text(timerInterval: Date()...phase.endsAt(from: Date()), countsDown: true)
        } else if let phase {
            Text(Duration.seconds(phase.remaining(at: Date())).formatted(.time(pattern: .minuteSecond)))
                .foregroundStyle(.secondary)
        } else {
            Text("Ready").foregroundStyle(.secondary)
        }
    }
}

/// The friction: how much time is left, then a countdown on the button
/// (and the phrase, if required) before it works.
private struct ExitConfirmation: View {
    @EnvironmentObject private var lockdown: LockdownModel
    let request: LockdownModel.ExitRequest
    let session: LockdownSession
    @State private var typed = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            Text(detail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let phrase = request.gate.phrase {
                Text("Type “\(phrase)” to continue.").font(.callout)
                TextField(phrase, text: $typed)
                    .textFieldStyle(.roundedBorder)
            }
            TimelineView(.periodic(from: .now, by: 0.25)) { context in
                let left = request.gate.secondsLeft(at: context.date)
                HStack {
                    Button("Keep going", role: .cancel) { lockdown.cancelExit() }
                        .keyboardShortcut(.cancelAction)
                    Spacer()
                    Button(left > 0 ? "\(confirmTitle) (\(left))" : confirmTitle, role: .destructive) {
                        lockdown.confirmExit(typed: typed)
                    }
                    .disabled(!request.gate.canConfirm(at: context.date, typed: typed))
                }
            }
        }
        .padding(18)
    }

    private var left: String { LockdownFormat.duration(session.remaining(at: Date())) }

    private var title: String {
        switch request.kind {
        case .end: return "End lockdown early?"
        case .remove(let minutes): return "Remove \(LockdownFormat.duration(minutes * 60))?"
        case .setEnd: return "End lockdown sooner?"
        }
    }

    private var detail: String {
        switch request.kind {
        case .end:
            return "You have \(left) left in \(session.spaceName). Your other apps will be unlocked."
        case .remove(let minutes):
            let end = max(Date().addingTimeInterval(60), session.endsAt.addingTimeInterval(-minutes * 60))
            return "You have \(left) left. Lockdown would end at \(end.formatted(date: .omitted, time: .shortened))."
        case .setEnd(let date):
            return "You have \(left) left. Lockdown would end at \(date.formatted(date: .omitted, time: .shortened))."
        }
    }

    private var confirmTitle: String {
        request.kind == .end ? "End lockdown" : "Remove time"
    }
}

private struct LockdownSummaryView: View {
    @EnvironmentObject private var lockdown: LockdownModel
    let summary: LockdownSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(summary.reason == .early ? "Lockdown ended" : "Lockdown complete", systemImage: "checkmark.seal.fill")
                .font(.headline)
            Text(summary.headline)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                if !summary.hiddenAtStart.isEmpty {
                    Button("Bring back my other apps") { lockdown.bringBackApps() }
                }
                Spacer()
                Button("Close") { lockdown.closePanel() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
    }
}

// MARK: - Settings (Space editor → Lockdown)

struct LockdownSettingsView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let profileID: UUID
    let profileName: String
    @State private var settings: LockdownSettings
    @State private var selectedModeID: UUID?
    @State private var newLinkURL = ""
    @State private var newLinkBrowser = "com.google.Chrome"

    private static let symbols = ["lock", "sparkles", "brain.head.profile", "chevron.left.forwardslash.chevron.right", "terminal",
                                  "book", "graduationcap", "hammer", "paintbrush", "music.note", "cup.and.saucer", "bolt"]

    /// Browsers a page can open in, if they're installed.
    private static let installedBrowsers: [(name: String, bundleID: String)] = [
        ("Google Chrome", "com.google.Chrome"), ("Safari", "com.apple.Safari"), ("Firefox", "org.mozilla.firefox"),
        ("Arc", "company.thebrowser.Browser"), ("Microsoft Edge", "com.microsoft.edgemac"), ("Brave", "com.brave.Browser"),
    ].filter { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0.1) != nil }

    init(profileID: UUID, profileName: String, settings: LockdownSettings) {
        self.profileID = profileID
        self.profileName = profileName
        var settings = settings
        if settings.modes.isEmpty { settings.modes = [LockdownMode(name: "Lockdown")] }
        _settings = State(initialValue: settings)
        _selectedModeID = State(initialValue: settings.modes.first?.id)
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    Toggle("Offer lockdown when entering with this profile", isOn: $settings.isEnabled)
                    Picker("Default length", selection: $settings.defaultMinutes) {
                        ForEach([25, 50, 60, 90, 120, 180, 240], id: \.self) { Text(LockdownFormat.duration(Double($0) * 60)).tag($0) }
                    }
                } footer: {
                    Text("Lockdown keeps everything except the apps below out of reach until the timer ends or you end it. Quitting ATLAS always ends it.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Section {
                    ForEach($settings.modes) { $mode in
                        HStack(spacing: 10) {
                            Menu {
                                ForEach(Self.symbols, id: \.self) { symbol in
                                    Button { mode.symbolName = symbol } label: { Label(symbol, systemImage: symbol) }
                                }
                            } label: {
                                Image(systemName: mode.symbolName)
                            }
                            .menuStyle(.borderlessButton)
                            .fixedSize()
                            TextField("Name", text: $mode.name)
                            Button(selectedModeID == mode.id ? "Editing" : "Edit") { selectedModeID = mode.id }
                                .disabled(selectedModeID == mode.id)
                            Button(role: .destructive) {
                                settings.modes.removeAll { $0.id == mode.id }
                                if selectedModeID == mode.id { selectedModeID = settings.modes.first?.id }
                            } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless)
                            .disabled(settings.modes.count <= 1)
                        }
                    }
                    Button("Add Mode") {
                        let mode = LockdownMode(name: "New mode")
                        settings.modes.append(mode)
                        selectedModeID = mode.id
                    }
                } header: {
                    Text("Modes")
                } footer: {
                    Text("Modes are offered when you enter, e.g. vibe coding or LeetCode. Each keeps its own apps and pages; ATLAS and its pomodoro window are always allowed.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                if let index = settings.modes.firstIndex(where: { $0.id == selectedModeID }) {
                    Section {
                        ForEach(settings.modes[index].apps) { app in
                            HStack {
                                Text(app.name)
                                Spacer()
                                Text(app.bundleID == LockdownApp.claudeToken ? "Desktop app or Safari web app" : app.bundleID)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                                Button(role: .destructive) {
                                    settings.modes[index].apps.removeAll { $0.id == app.id }
                                } label: { Image(systemName: "minus.circle") }
                                .buttonStyle(.borderless)
                            }
                        }
                        HStack {
                            Button("Add App…") { addApp(to: index) }
                            if !settings.modes[index].apps.contains(where: { $0.bundleID == LockdownApp.claudeToken }) {
                                Button("Add Claude") { settings.modes[index].apps.append(.claude) }
                            }
                        }
                    } header: {
                        Text("Apps in “\(settings.modes[index].name)”")
                    } footer: {
                        Text("Browsers are blocked like any other app. Claude uses the desktop app if it's installed, otherwise a Safari web app named Claude in ~/Applications. Missing apps are skipped and listed in the summary.")
                            .font(.caption).foregroundStyle(.secondary)
                    }

                    Section {
                        ForEach(settings.modes[index].links) { link in
                            HStack {
                                Text(link.url).lineLimit(1).truncationMode(.middle)
                                Spacer()
                                Text(link.browserName).foregroundStyle(.secondary)
                                Button(role: .destructive) {
                                    settings.modes[index].links.removeAll { $0.id == link.id }
                                } label: { Image(systemName: "minus.circle") }
                                .buttonStyle(.borderless)
                            }
                        }
                        HStack {
                            TextField("https://…", text: $newLinkURL)
                            Picker("", selection: $newLinkBrowser) {
                                ForEach(Self.installedBrowsers, id: \.bundleID) { Text($0.name).tag($0.bundleID) }
                            }
                            .labelsHidden()
                            .fixedSize()
                            Button("Add") { addLink(to: index) }
                                .disabled(URL(string: newLinkURL)?.host == nil)
                        }
                    } header: {
                        Text("Pages in “\(settings.modes[index].name)”")
                    } footer: {
                        Text("Each page opens in its browser, and that browser stays available during this mode, so every tab in it is reachable. For one site only, make it a Safari web app (Safari → File → Add to Dock) and add it as an app instead.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }

                Section("Pomodoro") {
                    Stepper("Focus: \(settings.pomodoro.focusMinutes) min", value: $settings.pomodoro.focusMinutes, in: 5...120, step: 5)
                    Stepper("Short break: \(settings.pomodoro.shortBreakMinutes) min", value: $settings.pomodoro.shortBreakMinutes, in: 1...30)
                    Stepper("Long break: \(settings.pomodoro.longBreakMinutes) min", value: $settings.pomodoro.longBreakMinutes, in: 5...60, step: 5)
                    Stepper("Long break every \(settings.pomodoro.longBreakEvery) breaks", value: $settings.pomodoro.longBreakEvery, in: 2...8)
                    Toggle("Play a sound at each phase change", isOn: $settings.pomodoro.playsSounds)
                    Toggle("Unlock other apps during breaks", isOn: $settings.pomodoro.unlockDuringBreaks)
                }

                Section {
                    Stepper("Wait \(settings.exitCountdownSeconds) s before confirming", value: $settings.exitCountdownSeconds, in: 0...60, step: 5)
                    Toggle("Require typing a phrase", isOn: $settings.requiresPhrase)
                    if settings.requiresPhrase {
                        TextField("Phrase", text: $settings.phrase)
                    }
                } header: {
                    Text("Ending early")
                } footer: {
                    Text("Adding time is instant. Removing time or ending early asks first, then waits before the button works, so it's a decision and not an accident.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Section {
                    TextField("Shortcut at start", text: Binding(get: { settings.shortcutOnStart ?? "" },
                                                                 set: { settings.shortcutOnStart = $0.isEmpty ? nil : $0 }),
                              prompt: Text("e.g. Turn On Do Not Disturb"))
                    TextField("Shortcut at end", text: Binding(get: { settings.shortcutOnEnd ?? "" },
                                                               set: { settings.shortcutOnEnd = $0.isEmpty ? nil : $0 }),
                              prompt: Text("e.g. Turn Off Do Not Disturb"))
                } header: {
                    Text("Do Not Disturb")
                } footer: {
                    Text("macOS doesn't let apps turn a Focus on or off directly. Make a Shortcut in the Shortcuts app with “Set Focus” (Do Not Disturb on, or off) and type its exact name here; ATLAS runs it when lockdown starts and ends.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Section("After lockdown") {
                    Picker("Run automation", selection: $settings.afterWorkflowID) {
                        Text("Nothing").tag(UUID?.none)
                        ForEach(model.workflows) { workflow in
                            Text(workflow.name).tag(UUID?.some(workflow.id))
                        }
                    }
                }

                Section {
                    ForEach(LockdownEssentials.apps) { app in
                        HStack {
                            Text(app.name)
                            Spacer()
                            Text(app.bundleID).font(.caption.monospaced()).foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("Always available")
                } footer: {
                    Text("System essentials lockdown never quits, hides or blocks, so your Mac always stays usable. Finder is tidied away when lockdown starts but never quit.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                Text("Lockdown for “\(profileName)”").foregroundStyle(.secondary)
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    model.core?.time?.lockdown.setSettings(settings, forProfile: profileID)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(14)
        }
        .frame(minWidth: 520, idealWidth: 560, minHeight: 560, idealHeight: 720)
    }

    private func addApp(to index: Int) {
        guard let bundleID = Pickers.chooseApplication(), !settings.modes[index].apps.contains(where: { $0.bundleID == bundleID }) else { return }
        let name = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
            .map { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") } ?? bundleID
        settings.modes[index].apps.append(LockdownApp(name: name, bundleID: bundleID))
    }

    private func addLink(to index: Int) {
        var url = newLinkURL.trimmingCharacters(in: .whitespaces)
        if !url.contains("://") { url = "https://" + url }
        guard URL(string: url)?.host != nil else { return }
        let browser = Self.installedBrowsers.first { $0.bundleID == newLinkBrowser } ?? ("Google Chrome", "com.google.Chrome")
        settings.modes[index].links.append(LockdownLink(url: url, browserBundleID: browser.bundleID, browserName: browser.name))
        newLinkURL = ""
    }
}

// MARK: - Menu bar

struct LockdownMenuItems: View {
    @ObservedObject var lockdown: LockdownModel

    var body: some View {
        if let session = lockdown.session {
            Section("Lockdown") {
                Text("\(session.spaceName): \(LockdownFormat.duration(session.remaining(at: Date()))) left")
                Button("Show Pomodoro") { lockdown.showPanel() }
                Menu("Change Time") {
                    Button("Add 15 Minutes") { lockdown.addTime(minutes: 15) }
                    Button("Add 30 Minutes") { lockdown.addTime(minutes: 30) }
                    Button("Add 1 Hour") { lockdown.addTime(minutes: 60) }
                    Divider()
                    Button("Remove 15 Minutes…") { lockdown.request(.remove(minutes: 15)) }
                    Button("Remove 30 Minutes…") { lockdown.request(.remove(minutes: 30)) }
                }
                Button("End Lockdown…") { lockdown.request(.end) }
            }
            Divider()
        } else if lockdown.hasHiddenApps {
            Button("Bring Back My Other Apps") { lockdown.bringBackApps() }
            Divider()
        }
    }
}

/// The menu-bar icon: a lockdown countdown, else the focus countdown, in
/// minutes (see `LockdownModel.menuBar` for why not a live timer).
struct MenuBarLabel: View {
    @ObservedObject var model: AppModel
    @ObservedObject var lockdown: LockdownModel

    var body: some View {
        if let menuBar = lockdown.menuBar {
            Image(systemName: menuBar.symbol)
            Text(menuBar.text)
        } else {
            Image(systemName: model.isPaused ? "pause.circle" : "globe.americas.fill")
        }
    }
}
