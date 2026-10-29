import AppKit
import AtlasCore
import AtlasCreative
import AtlasOrbitUI
import AtlasSpaces
import Charts
import SwiftUI

// MARK: - End-of-session card

/// "1 h 55 m creating · Poster Series · 4 exports · 6 references saved ·
/// streak 3 days", with the latest export and today's palette.
struct CreativeSummaryCard: View {
    @EnvironmentObject private var creative: CreativeModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let summary = creative.summary {
                HStack(spacing: 12) {
                    Image(systemName: summary.kind == .watch ? "play.tv.fill" : "cup.and.saucer.fill")
                        .font(.title2)
                        .foregroundStyle(.white)
                        .frame(width: 42, height: 42)
                        .background(Circle().fill(Color(nsColor: NSColor(atlasHex: "#E8A6B4")).gradient))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(summary.endedEarly ? "Session ended" : "Session complete").font(.headline)
                        Text(CreativeMath.duration(summary.focusedSeconds) + (summary.kind == .watch ? " of watching" : " of creating"))
                            .foregroundStyle(.secondary)
                    }
                }
                Text(summary.headline).font(.callout).fixedSize(horizontal: false, vertical: true)
                if let export = summary.latestExport, let image = creative.picture(export) {
                    Image(nsImage: image)
                        .resizable().scaledToFit()
                        .frame(maxHeight: 160)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                if !summary.palette.isEmpty {
                    PaletteDots(colors: summary.palette)
                }
                HStack {
                    Button("Stats") { creative.showStats() }
                    Spacer()
                    Button("Close") { creative.closeCard() }.keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(20)
        .frame(width: 360)
    }
}

/// Five colour dots; click one to copy its hex.
struct PaletteDots: View {
    let colors: [String]
    @State private var copied: String?

    var body: some View {
        HStack(spacing: 8) {
            Text("Today's palette").font(.caption).foregroundStyle(.secondary)
            ForEach(colors, id: \.self) { hex in
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(hex, forType: .string)
                    copied = hex
                } label: {
                    Circle().fill(Color(nsColor: NSColor(atlasHex: hex))).frame(width: 20, height: 20)
                        .overlay(Circle().strokeBorder(.primary.opacity(0.15)))
                }
                .buttonStyle(.plain)
                .help("\(hex) · click to copy")
            }
            if let copied { Text("Copied \(copied)").font(.caption2).foregroundStyle(.secondary) }
        }
    }
}

// MARK: - Mug options

struct MugOptionsView: View {
    @EnvironmentObject private var creative: CreativeModel
    @State private var custom = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Creative session", systemImage: "cup.and.saucer").font(.headline)
            if let sessions = creative.sessions, sessions.current != nil {
                HStack {
                    Button(sessions.isPaused ? "Resume" : "Pause") { creative.mugClicked(); creative.closeCard() }
                    Button("End session", role: .destructive) { creative.endSession() }
                }
            } else {
                HStack(spacing: 8) {
                    ForEach([25, 50, 90], id: \.self) { minutes in
                        Button("\(minutes) min") { creative.startSession(minutes: Double(minutes)) }.buttonStyle(.bordered)
                    }
                    TextField("Other", text: $custom).textFieldStyle(.roundedBorder).frame(width: 56).onSubmit(startCustom)
                    Text("min").foregroundStyle(.secondary)
                }
            }
            Toggle("Gentle break reminder every \(creative.settings.breakEveryMinutes) min", isOn: Binding(
                get: { creative.settings.breakReminders },
                set: { creative.settings.breakReminders = $0 }))
            Text("One long block of flow, no pomodoro. Never blocks or hides apps; the reminders are just a notification.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Stats") { creative.showStats() }
                Spacer()
                Button("Close") { creative.closeCard() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 360)
    }

    private func startCustom() {
        guard let minutes = Double(custom), (1...600).contains(minutes) else { return }
        creative.startSession(minutes: minutes)
    }
}

// MARK: - Stats

/// Hours per project per week (watching separately), today and the streak.
struct CreativeStatsView: View {
    @EnvironmentObject private var creative: CreativeModel

    private struct Bar: Identifiable {
        let id = UUID()
        let week: Date
        let series: String
        let color: Color
        let hours: Double
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Creative time", systemImage: "chart.bar.fill").font(.headline)
            HStack(spacing: 18) {
                stat("Today", CreativeMath.duration(creative.sessions?.createdToday() ?? 0))
                stat("Streak", "\(creative.sessions?.streak() ?? 0) days")
            }
            let bars = self.bars
            if bars.isEmpty {
                Text("No sessions yet. Click the mug to start one.").font(.callout).foregroundStyle(.secondary)
            } else {
                let series = Array(Set(bars.map(\.series))).sorted()
                Chart(bars) { bar in
                    BarMark(x: .value("Week", bar.week, unit: .weekOfYear), y: .value("Hours", bar.hours))
                        .foregroundStyle(by: .value("Project", bar.series))
                }
                .chartForegroundStyleScale(domain: series, range: series.map { name in bars.first { $0.series == name }!.color })
                .chartYAxisLabel("Hours")
                .frame(height: 180)
            }
            RugHistoryView()
            HStack {
                Button("Past Work…") { creative.showPastWork() }
                Spacer()
                Button("Close") { creative.closeCard() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 440)
    }

    private func stat(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title3.weight(.semibold).monospacedDigit())
        }
    }

    private var bars: [Bar] {
        (creative.sessions?.weeklyHours() ?? []).map { row in
            if row.kind == .watch {
                return Bar(week: row.weekStart, series: "Watching", color: Color(nsColor: NSColor(atlasHex: "#9AA7C7")), hours: row.hours)
            }
            return Bar(week: row.weekStart, series: creative.projectName(row.projectID),
                       color: Color(nsColor: NSColor(atlasHex: creative.projectColor(row.projectID))), hours: row.hours)
        }
    }
}

// MARK: - Settings

struct CreativeSettingsView: View {
    @EnvironmentObject private var creative: CreativeModel
    @Environment(\.dismiss) private var dismiss
    @State private var settings = CreativeSettings()
    @State private var versionSaves = false
    @State private var automationsOn: [CreativeAutomations.Kind: Bool] = [:]

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("Mug") {
                    Stepper("Session: \(settings.sessionMinutes) min", value: $settings.sessionMinutes, in: 5...300, step: 5)
                    Toggle("Gentle break reminders", isOn: $settings.breakReminders)
                    Stepper("Every \(settings.breakEveryMinutes) min", value: $settings.breakEveryMinutes, in: 15...180, step: 15)
                        .disabled(!settings.breakReminders)
                }
                Section {
                    TextField("Weather city", text: Binding(get: { creative.weatherCity?() ?? "" }, set: { creative.setWeatherCity?($0) }),
                              prompt: Text("e.g. Boston, MA"))
                } header: {
                    Text("Window")
                } footer: {
                    Text("Shared with the Study Library: the arched window follows the real time of day (morning pink, day, golden hour, lavender dusk, night) and this city's weather from Open-Meteo.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section {
                    Toggle("Companion paints at its tiny easel", isOn: $settings.companionPaints)
                    Toggle("Quiet during sessions (suggestions wait until the end)", isOn: $settings.quietDuringSessions)
                } header: {
                    Text("Companion")
                }
                Section {
                    ForEach(CreativeAutomations.Kind.allCases, id: \.self) { kind in
                        Toggle(isOn: Binding(get: { automationsOn[kind] ?? false }, set: { automationsOn[kind] = $0 })) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(kind.title)
                                Text(kind.summary).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                } header: {
                    Text("Automations")
                } footer: {
                    Text("Each is a normal automation (Automations → Creative · …) you can edit, e.g. the recap's time.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section {
                    HStack {
                        Text("Inspiration folder")
                        Spacer()
                        Text(settings.inspirationFolder).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        Button("Choose…") {
                            let start = (settings.inspirationFolder as NSString).expandingTildeInPath
                            if let url = OrbitViewModel.chooseFolder(prompt: "Use Folder", startingAt: start) {
                                settings.inspirationFolder = url.path.abbreviatedPath
                            }
                        }
                    }
                    let folder = (settings.inspirationFolder as NSString).expandingTildeInPath
                    if !creative.isAuthorized(folder) {
                        HStack {
                            Label("Not in Orbit yet, so pictures dropped on the room can't be saved there.", systemImage: "exclamationmark.triangle.fill")
                                .font(.caption).foregroundStyle(.orange)
                            Spacer()
                            Button("Add to Orbit") {
                                try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
                                _ = creative.addFolderToOrbit?(folder)
                            }
                        }
                    }
                } header: {
                    Text("Pegboard")
                } footer: {
                    Text("The pegboard pins the 6 newest pictures from this folder and the current project's References. Drag a picture onto the room while you're in the Creative Studio to save and pin it.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section {
                    Picker("Exports", selection: $settings.exportMode) {
                        Text("Ask me first").tag(FileRule.Mode.askFirst)
                        Text("Move automatically").tag(FileRule.Mode.automatic)
                    }
                    Picker("Screenshots in a session", selection: $settings.screenshotMode) {
                        Text("Ask me first").tag(FileRule.Mode.askFirst)
                        Text("Move automatically").tag(FileRule.Mode.automatic)
                    }
                    Toggle("Save a version when I leave the Creative Studio", isOn: $versionSaves)
                    Stepper("Keep the newest \(settings.keepVersions) versions", value: $settings.keepVersions, in: 1...50)
                        .disabled(!versionSaves)
                } header: {
                    Text("File rules")
                } footer: {
                    Text("Exports: new pictures, PDFs and videos in Downloads or on the Desktop while you're in the Creative Studio go to the current project's Exports folder as {project}-{date}-{counter}. Asking first puts them in Orbit's review queue. Renders in a project's Renders folder get a notification. Every rule is a normal automation (Automations → Creative · …); everything they move can be undone in Run History.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section {
                    Stepper("Streak day: \(settings.streakMinutes) min of creating", value: $settings.streakMinutes, in: 5...240, step: 5)
                    Picker("A new day starts at", selection: $settings.dayBoundaryHour) {
                        ForEach(0..<9) { hour in Text(hour == 0 ? "Midnight" : "\(hour) AM").tag(hour) }
                    }
                } header: {
                    Text("Streak")
                } footer: {
                    Text("Late nights count for the day they started.").font(.caption).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    var saved = creative.settings
                    saved.sessionMinutes = settings.sessionMinutes
                    saved.breakReminders = settings.breakReminders
                    saved.breakEveryMinutes = settings.breakEveryMinutes
                    saved.streakMinutes = settings.streakMinutes
                    saved.dayBoundaryHour = settings.dayBoundaryHour
                    saved.exportMode = settings.exportMode
                    saved.screenshotMode = settings.screenshotMode
                    saved.keepVersions = settings.keepVersions
                    saved.inspirationFolder = settings.inspirationFolder
                    saved.companionPaints = settings.companionPaints
                    saved.quietDuringSessions = settings.quietDuringSessions
                    for (kind, on) in automationsOn where creative.automations?.workflow(kind)?.isEnabled != on {
                        try? creative.automations?.setEnabled(on, kind)
                    }
                    creative.settings = saved
                    try? creative.rules?.setEnabled(versionSaves, .versions)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(14)
        }
        .frame(minWidth: 480, minHeight: 520)
        .onAppear {
            settings = creative.settings
            versionSaves = creative.rules?.workflow(.versions)?.isEnabled ?? false
            for kind in CreativeAutomations.Kind.allCases { automationsOn[kind] = creative.automations?.workflow(kind)?.isEnabled ?? false }
        }
    }
}

// MARK: - Past work

/// Finished projects that no longer fit on the gallery wall.
struct PastWorkView: View {
    @EnvironmentObject private var creative: CreativeModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Past work", systemImage: "photo.on.rectangle.angled").font(.headline)
            if creative.pastWork.isEmpty {
                Text("Everything you've finished is on the gallery wall. Mark a project Done to hang it.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 12)], spacing: 12) {
                        ForEach(creative.pastWork) { project in
                            Button { creative.itemClicked(.frame(project.id)) } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    ZStack {
                                        RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: NSColor(atlasHex: project.color)).opacity(0.3))
                                        if let image = creative.thumbnail(for: project) {
                                            Image(nsImage: image).resizable().scaledToFit().padding(4)
                                        }
                                    }
                                    .frame(height: 90)
                                    Text(project.name).font(.callout.weight(.semibold)).lineLimit(1)
                                    if let finished = project.creative?.finishedAt {
                                        Text(finished.formatted(.dateTime.month(.abbreviated).year())).font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .frame(maxHeight: 320)
            }
            HStack {
                Spacer()
                Button("Close") { creative.closeCard() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}

// MARK: - Project picker

/// Entering with more than one project active today: which one? Skippable;
/// the choice is remembered for the day.
struct ProjectPickerView: View {
    @EnvironmentObject private var creative: CreativeModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("What are you working on?", systemImage: "rectangle.stack").font(.headline)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 12)], spacing: 12) {
                ForEach(creative.pickerChoices) { project in
                    Button { creative.pick(project) } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: NSColor(atlasHex: project.color)).opacity(0.35))
                                if let image = creative.thumbnail(for: project) {
                                    Image(nsImage: image).resizable().scaledToFit().padding(4)
                                } else {
                                    Image(systemName: "paintbrush.pointed").font(.title2).foregroundStyle(.secondary)
                                }
                            }
                            .frame(height: 90)
                            Text(project.name).font(.callout.weight(.semibold)).lineLimit(1)
                            Text(creative.lastEdited(project).map { "edited \($0)" } ?? "").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            HStack {
                Text("Remembered for today.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Skip") { creative.closeCard() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(18)
        .frame(width: 440)
    }
}

// MARK: - Rug history

/// This month's rug and the past months', as rows of paint dots.
struct RugHistoryView: View {
    @EnvironmentObject private var creative: CreativeModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("The rug").font(.subheadline.weight(.semibold))
            row(Date(), creative.roomState.rug)
            ForEach(creative.sessions?.rugHistory() ?? [], id: \.month) { month in
                row(month.month, month.splashes)
            }
        }
    }

    private func row(_ month: Date, _ splashes: [CreativeRoomState.Splash]) -> some View {
        HStack(spacing: 4) {
            Text(month.formatted(.dateTime.month(.abbreviated).year(.twoDigits))).font(.caption).foregroundStyle(.secondary).frame(width: 52, alignment: .leading)
            if splashes.isEmpty {
                Text("no creative days yet").font(.caption).foregroundStyle(.tertiary)
            }
            ForEach(splashes, id: \.day) { splash in
                Circle().fill(Color(nsColor: NSColor(atlasHex: splash.color))).frame(width: 9, height: 9).help("Day \(splash.day)")
            }
            Spacer()
            Text("\(splashes.count) day\(splashes.count == 1 ? "" : "s")").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        }
    }
}

// MARK: - Window

/// Clicking the arched window: what it shows, and the weather city (shared
/// with the Study Library).
struct CreativeWindowCard: View {
    @EnvironmentObject private var creative: CreativeModel
    @State private var city = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("The window", systemImage: "sun.haze").font(.headline)
            Text(creative.roomState.windowDetail.isEmpty ? "Golden hour" : creative.roomState.windowDetail)
                .font(.callout).fixedSize(horizontal: false, vertical: true)
            HStack {
                TextField("City", text: $city, prompt: Text("e.g. Boston, MA")).textFieldStyle(.roundedBorder).onSubmit(save)
                Button("Update", action: save)
            }
            Text("Real weather from Open-Meteo (free, no account); only the city name is sent. Shared with the Study Library.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Close") { creative.closeCard() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 360)
        .onAppear { city = creative.weatherCity?() ?? "" }
    }

    private func save() {
        creative.setWeatherCity?(city)
        Task {
            try? await Task.sleep(for: .seconds(3))
            creative.refreshRoom()
        }
    }
}
