import AppKit
import AtlasCore
import AtlasStudy
import SwiftUI

/// Everything due: sort, filter by course, check off, add your own.
struct AssignmentsPanel: View {
    @EnvironmentObject private var study: StudyModel
    @State private var courseFilter: UUID?
    @State private var sortByCourse = false
    @State private var showDone = false
    @State private var newTitle = ""
    @State private var newCourse: UUID?
    @State private var newDue = Calendar.current.date(byAdding: .day, value: 1, to: Date()) ?? Date()
    @State private var hasDue = true
    @State private var revision = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Picker("Course", selection: $courseFilter) {
                    Text("All courses").tag(UUID?.none)
                    ForEach(study.activeCourses) { Text($0.displayCode).tag(UUID?.some($0.id)) }
                }
                .fixedSize()
                Picker("Sort", selection: $sortByCourse) {
                    Text("By due date").tag(false)
                    Text("By course").tag(true)
                }
                .labelsHidden()
                .fixedSize()
                Toggle("Show done", isOn: $showDone)
                Spacer()
                Button {
                    study.syncAssignments()
                    revision += 1
                } label: { Image(systemName: "arrow.clockwise") }
                .help("Sync with Calendar and Reminders")
            }
            let items = self.items
            if items.isEmpty {
                Text(showDone ? "Nothing here yet." : "Nothing due. Add one below, or connect your school calendar feed or a Reminders list in Study Settings.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 80)
            } else {
                ScrollView {
                    VStack(spacing: 4) {
                        ForEach(items) { item in row(item) }
                    }
                }
                .frame(minHeight: 120, maxHeight: 320)
            }
            Divider()
            HStack {
                TextField("Add an assignment", text: $newTitle)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(add)
                Picker("", selection: $newCourse) {
                    Text("No course").tag(UUID?.none)
                    ForEach(study.activeCourses) { Text($0.displayCode).tag(UUID?.some($0.id)) }
                }
                .labelsHidden()
                .fixedSize()
                Toggle("Due", isOn: $hasDue).toggleStyle(.checkbox)
                if hasDue {
                    DatePicker("", selection: $newDue, displayedComponents: [.date])
                        .labelsHidden()
                        .fixedSize()
                }
                Button("Add", action: add).disabled(newTitle.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            HStack {
                if let folder = study.spaces?.objects(for: study.studySpaceID ?? UUID()).first(where: { $0.kind == .chalkboard }),
                   folder.hasAssignment {
                    Button("Open Assignments Folder") { study.spaces?.run(folder) }
                }
                Spacer()
                Button("Close") { study.closeBoard() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(18)
        .frame(width: 600)
        .id(revision)
    }

    private var items: [MergedAssignment] {
        _ = revision
        var list = (study.assignments?.all() ?? []).filter { showDone || !$0.isDone }
        if let courseFilter { list = list.filter { $0.courseID == courseFilter } }
        if sortByCourse {
            let order = Dictionary(uniqueKeysWithValues: study.activeCourses.enumerated().map { ($1.id, $0) })
            list.sort { (order[$0.courseID ?? UUID()] ?? .max, $0.dueAt ?? .distantFuture) < (order[$1.courseID ?? UUID()] ?? .max, $1.dueAt ?? .distantFuture) }
        }
        return list
    }

    private func row(_ item: MergedAssignment) -> some View {
        let course = item.courseID.flatMap { id in study.courses.first { $0.id == id } }
        return HStack(spacing: 10) {
            Toggle("", isOn: Binding(get: { item.isDone }, set: { done in
                study.setDone(done, item.id)
                revision += 1
            }))
            .labelsHidden()
            .toggleStyle(.checkbox)
            .disabled(item.isDone && item.sources.contains(.reminders))
            .help(item.sources.contains(.reminders) ? "Checking off also completes the reminder" : "")
            Circle().fill(Color(nsColor: NSColor(atlasHex: course?.color ?? "#B8BCCB"))).frame(width: 9, height: 9)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    if item.kind == .exam { Image(systemName: "star.fill").font(.caption2).foregroundStyle(.orange) }
                    Text(item.title).strikethrough(item.isDone).lineLimit(1)
                }
                Text([course?.displayCode, item.sources.map(\.title).joined(separator: " + ")].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let due = item.dueAt {
                Text(due.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()))
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(due < Date() && !item.isDone ? .red : .secondary)
            }
            if item.primary.source == .manual {
                Button(role: .destructive) {
                    try? study.assignments?.delete(assignmentID: item.primary.id)
                    revision += 1
                } label: { Image(systemName: "trash") }
                .buttonStyle(.borderless)
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
    }

    private func add() {
        let title = newTitle.trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty else { return }
        _ = try? study.assignments?.add(title: title, courseID: newCourse, dueAt: hasDue ? newDue : nil)
        newTitle = ""
        revision += 1
    }
}

/// Study Settings → Assignment sources.
struct AssignmentSourcesSection: View {
    @EnvironmentObject private var study: StudyModel
    @Binding var settings: StudySettings
    @State private var asking = false
    @State private var access: CalendarAccess = .notDetermined

    var body: some View {
        Section {
            if study.calendars.isEmpty {
                Text("Connect your calendar first (Time Architect → Calendar, or Courses → Find Courses).")
                    .foregroundStyle(.secondary)
            }
            ForEach(study.calendars) { calendar in
                Toggle(calendar.title, isOn: Binding(
                    get: { settings.assignmentCalendarIDs.contains(calendar.id) },
                    set: { on in
                        settings.assignmentCalendarIDs.removeAll { $0 == calendar.id }
                        if on { settings.assignmentCalendarIDs.append(calendar.id) }
                    }
                ))
            }
            if access == .granted {
                Picker("Reminders list", selection: $settings.remindersListID) {
                    Text("None").tag(String?.none)
                    ForEach(study.reminderLists) { Text($0.title).tag(String?.some($0.id)) }
                }
            } else {
                HStack {
                    Text("Reminders list")
                    Spacer()
                    Button(asking ? "Asking…" : "Allow Reminders Access…") {
                        asking = true
                        Task {
                            _ = await study.requestRemindersAccess()
                            access = study.remindersAccess
                            asking = false
                        }
                    }
                    .disabled(asking || access == .denied)
                }
                if access == .denied {
                    Text("Reminders access is off. Turn it on in System Settings → Privacy & Security → Reminders.")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
        } header: {
            Text("Assignment sources")
        } footer: {
            Text("Tick your school's calendar feed (e.g. Canvas → Calendar → Calendar Feed, added to the Calendar app): its events become assignments. In other calendars only events that say due, exam, midterm, quiz… and name a course count. Reminders access lets ATLAS read one list and mark a reminder complete when you check it off in the room; it never changes anything else. Calendar events are never edited.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .onAppear { access = study.remindersAccess }
    }
}

/// Study Settings → Automations: each one's on/off and timing. They're
/// ordinary workflows, so the Flow editor can change anything else.
struct StudyAutomationsSection: View {
    @EnvironmentObject private var study: StudyModel
    @EnvironmentObject private var model: AppModel
    @Binding var settings: StudySettings
    @State private var enabled: [StudyAutomations.Kind: Bool] = [:]
    @State private var minutes = 10
    @State private var weekTime = Date()
    @State private var pdfRulesOn = true

    var body: some View {
        Section {
            ForEach(StudyAutomations.Kind.allCases, id: \.self) { kind in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Toggle(kind.title, isOn: Binding(
                            get: { enabled[kind] ?? false },
                            set: { on in
                                enabled[kind] = on
                                try? study.automations?.setEnabled(on, kind)
                            }
                        ))
                        Spacer()
                        if let workflow = study.automations?.workflow(kind) {
                            Button("Edit in Flow…") {
                                model.selectedWorkflowID = workflow.id
                                model.section = .automations
                            }
                            .buttonStyle(.link)
                        } else {
                            Text("Deleted").foregroundStyle(.secondary)
                        }
                    }
                    Text(kind.summary).font(.caption).foregroundStyle(.secondary)
                    if kind == .classSoon {
                        Stepper("\(minutes) min before class", value: $minutes, in: 1...60)
                            .onChange(of: minutes) { _, value in study.automations?.classSoonMinutes = value }
                    }
                    if kind == .weekAhead {
                        DatePicker("Sundays at", selection: $weekTime, displayedComponents: .hourAndMinute)
                            .onChange(of: weekTime) { _, value in
                                study.automations?.weekAheadTime = value.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))
                            }
                    }
                    if kind == .examMode {
                        TextField("Flashcards (app bundle ID or link)", text: $settings.flashcards)
                        TextField("Practice tests folder (inside each course folder)", text: $settings.practiceFolderName)
                    }
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                Toggle("Course PDFs", isOn: Binding(get: { pdfRulesOn }, set: { on in
                    pdfRulesOn = on
                    study.setCoursePDFRules(on)
                }))
                Text("A PDF in Downloads whose name has a course code moves into that course's folder (a “Downloads” folder inside it). If it names two courses, it waits in Orbit's review queue. Every move shows in Run History and can be undone. Needs the course to have a folder.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        } header: {
            Text("Automations")
        }
        .onAppear {
            for kind in StudyAutomations.Kind.allCases { enabled[kind] = study.automations?.workflow(kind)?.isEnabled ?? false }
            minutes = study.automations?.classSoonMinutes ?? 10
            let parts = (study.automations?.weekAheadTime ?? "19:00").split(separator: ":").compactMap { Int($0) }
            weekTime = Calendar.current.date(bySettingHour: parts.first ?? 19, minute: parts.dropFirst().first ?? 0, second: 0, of: Date()) ?? Date()
            pdfRulesOn = study.coursePDFRulesOn
        }
    }
}
