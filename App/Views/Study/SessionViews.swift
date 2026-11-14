import AppKit
import AtlasCore
import AtlasStudy
import Charts
import SwiftUI

// MARK: - End-of-session card

/// "1 h 40 m studied · 3 pomodoros · CHEM101 notes updated · streak 5 days",
/// with the course ATLAS guessed and a quick "Change".
struct StudySummaryCard: View {
    @EnvironmentObject private var study: StudyModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let summary = study.summary {
                HStack(spacing: 12) {
                    Image(systemName: "hourglass.bottomhalf.filled")
                        .font(.title2)
                        .foregroundStyle(.white)
                        .frame(width: 42, height: 42)
                        .background(Circle().fill(Color(nsColor: NSColor(atlasHex: "#6F8A6E")).gradient))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(summary.endedEarly ? "Session ended" : "Session complete").font(.headline)
                        Text(StudyMath.duration(summary.focusedSeconds) + " of focus").foregroundStyle(.secondary)
                    }
                }
                Text(summary.headline)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                if let tasks = summary.tasks {
                    SummaryTasksSection(tally: tasks, sessionID: summary.sessionID)
                }
                HStack(spacing: 6) {
                    if let code = summary.courseCode, let course = study.courses.first(where: { $0.code == code }) {
                        RoundedRectangle(cornerRadius: 2).fill(Color(nsColor: NSColor(atlasHex: course.color))).frame(width: 6, height: 16)
                        Text(course.displayCode).font(.callout.weight(.semibold))
                        if let reason = summary.guessReason, reason != .chosen {
                            Text("(\(reason.phrase))").font(.caption).foregroundStyle(.secondary)
                        }
                    } else {
                        Text("No course").font(.callout).foregroundStyle(.secondary)
                    }
                    Menu("Change") {
                        ForEach(study.activeCourses) { course in
                            Button("\(course.displayCode) · \(course.name)") { study.setSummaryCourse(course.id) }
                        }
                        Divider()
                        Button("No course") { study.setSummaryCourse(nil) }
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }
                HStack {
                    Button("Stats") { study.itemClicked(.candle, options: false) }
                    Spacer()
                    Button("Close") { study.closeCard() }
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(20)
        .frame(width: 360)
    }
}

// MARK: - Hourglass options

struct HourglassOptionsView: View {
    @EnvironmentObject private var study: StudyModel
    @State private var custom = ""
    @State private var pomodoro = true

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Study timer", systemImage: "hourglass").font(.headline)
            if let sessions = study.sessions, sessions.current != nil {
                HStack {
                    Button(sessions.isPaused ? "Resume" : "Pause") { study.itemClicked(.hourglass, options: false); study.closeCard() }
                    Button("Skip phase") { sessions.skipPhase(); study.closeCard() }
                    Button("End session", role: .destructive) { study.endSession() }
                }
            } else {
                HStack(spacing: 8) {
                    ForEach([25, 50, 90], id: \.self) { minutes in
                        Button("\(minutes) min") { study.startSession(minutes: Double(minutes), pomodoro: pomodoro) }
                            .buttonStyle(.bordered)
                    }
                    TextField("Other", text: $custom)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 56)
                        .onSubmit(startCustom)
                    Text("min").foregroundStyle(.secondary)
                }
                Toggle("Pomodoro (\(study.settings.pomodoro.focusMinutes)/\(study.settings.pomodoro.shortBreakMinutes))", isOn: $pomodoro)
            }
            Text("Never blocks or hides apps. It also counts down in the menu bar and on the Companion.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Close") { study.closeCard() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 360)
        .onAppear { pomodoro = study.settings.usesPomodoro }
    }

    private func startCustom() {
        guard let minutes = Double(custom), (1...600).contains(minutes) else { return }
        study.startSession(minutes: minutes, pomodoro: pomodoro)
    }
}

// MARK: - Stats

/// Hours per course per week, plus today and the streak.
struct StudyStatsView: View {
    @EnvironmentObject private var study: StudyModel

    private struct Bar: Identifiable {
        let id = UUID()
        let week: Date
        let course: String
        let color: Color
        let hours: Double
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Study time", systemImage: "chart.bar.fill").font(.headline)
            HStack(spacing: 18) {
                stat("Today", StudyMath.duration(study.sessions?.studiedToday() ?? 0))
                stat("Streak", "\(study.sessions?.streak() ?? 0) days")
                stat("Goal", StudyMath.duration(study.settings.dailyGoalHours * 3600))
            }
            let bars = self.bars
            if bars.isEmpty {
                Text("No sessions yet. Click the hourglass to start one.")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                Chart(bars) { bar in
                    BarMark(x: .value("Week", bar.week, unit: .weekOfYear), y: .value("Hours", bar.hours))
                        .foregroundStyle(by: .value("Course", bar.course))
                }
                .chartForegroundStyleScale(domain: Array(Set(bars.map(\.course))).sorted(),
                                           range: Array(Set(bars.map(\.course))).sorted().map { name in bars.first { $0.course == name }!.color })
                .chartYAxisLabel("Hours")
                .frame(height: 180)
            }
            TaskStats()
            HStack {
                Spacer()
                Button("Close") { study.closeCard() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    private func stat(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title3.weight(.semibold).monospacedDigit())
        }
    }

    private var bars: [Bar] {
        (study.sessions?.weeklyHours() ?? []).map { row in
            let course = row.courseID.flatMap { id in study.courses.first { $0.id == id } }
            return Bar(week: row.weekStart, course: course?.displayCode ?? "No course",
                       color: Color(nsColor: NSColor(atlasHex: course?.color ?? "#B8BCCB")), hours: row.hours)
        }
    }
}

/// Tasks checked off per day this week, and per course.
private struct TaskStats: View {
    @EnvironmentObject private var study: StudyModel

    private struct Day: Identifiable {
        let id = UUID()
        let day: Date
        let count: Int
    }

    var body: some View {
        let tasks = study.module?.tasks
        let days = (tasks?.completedPerDay() ?? []).map { Day(day: $0.day, count: $0.count) }
        let courses = tasks?.completedPerCourse() ?? []
        if days.contains(where: { $0.count > 0 }) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Tasks done · \(days.reduce(0) { $0 + $1.count }) this week").font(.subheadline.weight(.semibold))
                Chart(days) { day in
                    BarMark(x: .value("Day", day.day, unit: .day), y: .value("Tasks", day.count))
                        .foregroundStyle(Color.green.gradient)
                }
                .chartXAxis { AxisMarks(values: .stride(by: .day)) { _ in AxisValueLabel(format: .dateTime.weekday(.narrow)) } }
                .frame(height: 90)
                HStack(spacing: 10) {
                    ForEach(Array(courses.prefix(5).enumerated()), id: \.offset) { _, row in
                        HStack(spacing: 4) {
                            Circle().fill(Color(nsColor: NSColor(atlasHex: row.link?.color ?? "#B8BCCB"))).frame(width: 7, height: 7)
                            Text("\(row.link?.label ?? "No course") \(row.count)").font(.caption)
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Study settings

struct StudySettingsView: View {
    @EnvironmentObject private var study: StudyModel
    @Environment(\.dismiss) private var dismiss
    @State private var settings = StudySettings()

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    Stepper("Daily goal: \(StudyMath.duration(settings.dailyGoalHours * 3600))", value: $settings.dailyGoalHours,
                            in: 0.5...12, step: 0.5)
                    Picker("A new day starts at", selection: $settings.dayBoundaryHour) {
                        ForEach(0..<9) { hour in Text(hour == 0 ? "Midnight" : "\(hour) AM").tag(hour) }
                    }
                } header: {
                    Text("Candle")
                } footer: {
                    Text("Today's candle burns down as you study and is fully burned at your daily goal. A fresh one appears when the new day starts, so late nights count for the right day.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section {
                    TextField("Weather city", text: $settings.weatherCity, prompt: Text("e.g. Boston, MA"))
                    Stepper("Streak day: \(settings.streakMinutes) min of study", value: $settings.streakMinutes, in: 5...240, step: 5)
                } header: {
                    Text("Window and shelf")
                } footer: {
                    Text("The window shows that city's real weather (from Open-Meteo, free, no account; only the city name is sent) and the sky for the time of day. Leave it empty for just the time of day. A book joins the upper shelves for every hour you study.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section {
                    Toggle("Companion reads on the window seat", isOn: $settings.companionReads)
                    Toggle("Hold suggestions until a break", isOn: $settings.holdSuggestions)
                } header: {
                    Text("Companion")
                } footer: {
                    Text("During a session's focus time the Companion reads quietly; offers and suggestions wait for the next break or the end. A class about to start still comes right away.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section {
                    TextField("Lo-fi playlist", text: $settings.lofiPlaylist, prompt: Text("spotify:playlist:…"))
                    TextField("PDF reader", text: $settings.pdfReader, prompt: Text("com.apple.Preview"))
                    TextField("Calculator", text: $settings.calculator, prompt: Text("https://www.desmos.com/calculator"))
                } header: {
                    Text("Profiles")
                } footer: {
                    Text("Default plays the playlist (a Spotify URI or link) with the course of the moment. Reading and Problem set open PDFs with the reader (an app's bundle ID). The calculator is a link or an app's bundle ID.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section {
                    Toggle("Ask what you want to get done at the start", isOn: $settings.tasks.promptAtStart)
                    LabeledContent("Quick add shortcut") {
                        TextField("opt+shift+t", text: $settings.tasks.quickAddHotKey).frame(width: 140)
                    }
                    Toggle("Check in at breaks (“Did you finish …?”)", isOn: $settings.tasks.breakCheckIn)
                    Picker("Unfinished tasks", selection: $settings.tasks.carryOver) {
                        ForEach(SessionTaskSettings.CarryOver.allCases) { Text($0.title).tag($0) }
                    }
                    Toggle("Mochi celebrates finished tasks", isOn: $settings.tasks.celebrations)
                    Toggle("Checking off a task completes its assignment in Reminders", isOn: $settings.tasks.syncAssignments)
                } header: {
                    Text("Session tasks")
                } footer: {
                    Text("Type “x2” or “🍅2” at the end of a task for an estimate, and “#CHEM101” to link a course. The quick add shortcut works from any app; write it like “opt+shift+t” or “cmd+ctrl+t”.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section {
                    Toggle("Let me out during breaks", isOn: $settings.windowLock.unlockDuringBreaks)
                    Stepper("Wait \(settings.windowLock.exitCountdownSeconds) s before ending a locked session",
                            value: $settings.windowLock.exitCountdownSeconds, in: 0...60, step: 5)
                } header: {
                    Text("Lock in")
                } footer: {
                    Text("Pick windows under “Lock me in” when you plan a session. Everything else hides until it ends; quitting ATLAS always unlocks.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                AssignmentSourcesSection(settings: $settings)
                StudyAutomationsSection(settings: $settings)
                Section("Hourglass") {
                    Stepper("Session: \(settings.sessionMinutes) min", value: $settings.sessionMinutes, in: 5...240, step: 5)
                    Toggle("Pomodoro", isOn: $settings.usesPomodoro)
                    Stepper("Focus: \(settings.pomodoro.focusMinutes) min", value: $settings.pomodoro.focusMinutes, in: 5...90, step: 5)
                    Stepper("Short break: \(settings.pomodoro.shortBreakMinutes) min", value: $settings.pomodoro.shortBreakMinutes, in: 1...30)
                    Stepper("Long break: \(settings.pomodoro.longBreakMinutes) min", value: $settings.pomodoro.longBreakMinutes, in: 5...60, step: 5)
                    Stepper("Long break every \(settings.pomodoro.longBreakEvery) breaks", value: $settings.pomodoro.longBreakEvery, in: 2...8)
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    let cityChanged = settings.weatherCity != study.settings.weatherCity
                    study.settings = settings
                    if cityChanged { study.refreshWeather(force: true) }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(14)
        }
        .frame(minWidth: 460, idealWidth: 500, minHeight: 480)
        .onAppear { settings = study.settings }
    }
}

// MARK: - Window weather

/// Clicking the window: what it shows, and the city to show.
struct WeatherCard: View {
    @EnvironmentObject private var study: StudyModel
    @State private var city = ""
    @State private var checking = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("The window", systemImage: "cloud.sun").font(.headline)
            Text(study.weatherDetail).font(.callout).fixedSize(horizontal: false, vertical: true)
            HStack {
                TextField("City", text: $city, prompt: Text("e.g. Boston, MA"))
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(save)
                Button(checking ? "Checking…" : "Update", action: save).disabled(checking)
            }
            if let place = study.weatherPlace(for: city), !city.isEmpty {
                Text("Found: \(place.name)\(place.region.isEmpty ? "" : ", \(place.region)")").font(.caption).foregroundStyle(.secondary)
            }
            Text("Real weather from Open-Meteo (free, no account); only the city name is sent. Empty: just the time of day.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Close") { study.closeCard() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 360)
        .onAppear { city = study.settings.weatherCity }
    }

    private func save() {
        var settings = study.settings
        settings.weatherCity = city.trimmingCharacters(in: .whitespaces)
        study.settings = settings
        checking = true
        study.refreshWeather(force: true)
        Task {
            try? await Task.sleep(for: .seconds(3))
            checking = false
        }
    }
}
