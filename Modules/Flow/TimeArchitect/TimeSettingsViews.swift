import AtlasCore
import SwiftUI

/// Calendar integration: off until turned on, read-only by default, and
/// writing allowed only per calendar. Every write is logged and undoable.
struct CalendarSettingsView: View {
    @ObservedObject var model: TimeArchitectModel
    @Environment(\.dismiss) private var dismiss
    @State private var settings = CalendarSettings()
    @State private var links: [CalendarLink] = []
    @State private var newRuleText = ""
    @State private var newRuleSpace: UUID?
    @State private var newRuleMinutes = 15
    @State private var working = false

    private var calendar: CalendarService { model.time.calendar }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    Toggle("Show my calendar events on the timeline", isOn: Binding(get: { settings.enabled }, set: { on in
                        if on {
                            working = true
                            Task {
                                await calendar.enable()
                                working = false
                                reload()
                            }
                        } else {
                            calendar.disable()
                            reload()
                        }
                    }))
                    .disabled(working)
                    Text(statusText).font(.caption).foregroundStyle(calendar.access == .denied ? .orange : .secondary)
                    Text("ATLAS reads events from the calendars you pick below, including Google and Outlook accounts added to macOS Calendar. It asks macOS for access only when you turn this on, and changes nothing unless you allow writing for a calendar.")
                        .font(.caption).foregroundStyle(.secondary)
                } header: { Text("Calendar") }

                if settings.enabled {
                    Section("Calendars") {
                        ForEach(calendar.calendars()) { info in
                            HStack {
                                Circle().fill(Color(timeHex: info.color) ?? .gray).frame(width: 10, height: 10)
                                Toggle(info.title, isOn: binding(\.visibleCalendarIDs, info.id))
                                Spacer()
                                Text(info.source).font(.caption).foregroundStyle(.secondary)
                                Toggle("Allow writing", isOn: binding(\.writableCalendarIDs, info.id))
                                    .toggleStyle(.checkbox)
                                    .disabled(!info.allowsWriting)
                                    .help(info.allowsWriting ? "Let ATLAS add focus blocks to this calendar (it asks the first time)" : "This calendar is read-only in macOS")
                            }
                        }
                    }

                    Section {
                        ForEach(links.filter { $0.kind == .rule }) { link in
                            HStack {
                                Text("Title contains “\(link.titleContains ?? "")” → \(model.space(link.spaceID)?.name ?? "?") \(link.minutesBefore) min before")
                                Spacer()
                                Button(role: .destructive) { try? calendar.deleteLink(link.id); reload() } label: { Image(systemName: "minus.circle") }
                                    .buttonStyle(.borderless)
                            }
                        }
                        HStack {
                            TextField("Title contains, e.g. Interview", text: $newRuleText)
                            Picker("Space", selection: $newRuleSpace) {
                                Text("Space…").tag(UUID?.none)
                                ForEach(model.spaces) { Text($0.name).tag(Optional($0.id)) }
                            }
                            .labelsHidden()
                            Stepper("\(newRuleMinutes) min", value: $newRuleMinutes, in: 5...120, step: 5)
                            Button("Add") {
                                try? calendar.saveLink(CalendarLink(kind: .rule, titleContains: newRuleText, spaceID: newRuleSpace, minutesBefore: newRuleMinutes))
                                newRuleText = ""
                                reload()
                            }
                            .disabled(newRuleText.trimmingCharacters(in: .whitespaces).isEmpty || newRuleSpace == nil)
                        }
                    } header: { Text("Link rules") } footer: {
                        Text("Before a matching event, the Companion suggests opening that Space. Nothing changes until you accept.").font(.caption)
                    }

                    let log = calendar.writeLog()
                    if !log.isEmpty {
                        Section("What ATLAS wrote") {
                            ForEach(log) { entry in
                                HStack {
                                    VStack(alignment: .leading) {
                                        Text(entry.note)
                                        Text(entry.createdAt.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    if entry.undoneAt != nil {
                                        Text(entry.eventID != nil && entry.blockID == nil ? "Logged" : "Undone").font(.caption).foregroundStyle(.secondary)
                                    } else {
                                        Button("Undo") {
                                            do { try calendar.undo(entry) } catch { model.message = error.localizedDescription }
                                            reload()
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 640, height: 560)
        .onAppear(perform: reload)
    }

    private var statusText: String {
        switch calendar.access {
        case .granted: return settings.enabled ? "On. Showing \(settings.visibleCalendarIDs.count) calendar\(settings.visibleCalendarIDs.count == 1 ? "" : "s")." : "Access granted; integration is off."
        case .notDetermined: return "macOS will ask for access when you turn this on."
        case .denied, .restricted: return "Access is off in System Settings → Privacy & Security → Calendars."
        }
    }

    private func binding(_ keyPath: WritableKeyPath<CalendarSettings, [String]>, _ id: String) -> Binding<Bool> {
        Binding(get: { settings[keyPath: keyPath].contains(id) }, set: { on in
            var next = calendar.settings
            if on { if !next[keyPath: keyPath].contains(id) { next[keyPath: keyPath].append(id) } } else { next[keyPath: keyPath].removeAll { $0 == id } }
            calendar.settings = next
            reload()
        })
    }

    private func reload() {
        settings = calendar.settings
        links = calendar.links()
        model.reload()
    }
}

/// Focus session defaults and what happens when one ends.
struct FocusSettingsView: View {
    @ObservedObject var model: TimeArchitectModel
    @Environment(\.dismiss) private var dismiss
    @State private var settings = FocusSettings()

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("Length") {
                    Stepper("Default: \(settings.defaultMinutes) minutes", value: $settings.defaultMinutes, in: 5...240, step: 5)
                    ForEach(model.spaces) { space in
                        Stepper("\(space.name): \(settings.defaultMinutesBySpace[space.id.uuidString].map { "\($0) minutes" } ?? "default")",
                                value: Binding(get: { settings.defaultMinutesBySpace[space.id.uuidString] ?? settings.defaultMinutes },
                                               set: { settings.defaultMinutesBySpace[space.id.uuidString] = $0 }), in: 5...240, step: 5)
                    }
                }
                Section("When a session ends") {
                    Toggle("Notify me", isOn: $settings.notifyAtEnd)
                    Picker("Then add a break", selection: $settings.breakMinutes) {
                        Text("No break").tag(Int?.none)
                        ForEach([5, 10, 15], id: \.self) { Text("\($0) minutes").tag(Optional($0)) }
                    }
                    Picker("And", selection: $settings.endAction) {
                        ForEach(FocusSettings.EndAction.allCases) { Text($0.title).tag($0) }
                    }
                    if settings.endAction == .activateSpace {
                        Picker("Space", selection: Binding(get: { settings.endSpaceName ?? "" }, set: { settings.endSpaceName = $0.isEmpty ? nil : $0 })) {
                            Text("Choose…").tag("")
                            ForEach(model.spaces) { Text($0.name).tag($0.name) }
                        }
                    }
                }
                Section {
                    TextField("Shortcut to run when a session starts", text: Binding(get: { settings.shortcutOnStart ?? "" },
                                                                                    set: { settings.shortcutOnStart = $0.isEmpty ? nil : $0 }))
                    TextField("Shortcut to run when it ends", text: Binding(get: { settings.shortcutOnEnd ?? "" },
                                                                          set: { settings.shortcutOnEnd = $0.isEmpty ? nil : $0 }))
                } header: { Text("macOS Focus (optional)") } footer: {
                    Text("macOS doesn't let apps turn Focus or Do Not Disturb on directly. Make a shortcut in the Shortcuts app with the “Set Focus” action (e.g. “Turn On Do Not Disturb”), then type its exact name here. ATLAS runs it with the shortcuts command-line tool.")
                        .font(.caption)
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") {
                    model.time.focus.settings = settings
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 520, height: 560)
        .onAppear { settings = model.time.focus.settings }
    }
}
