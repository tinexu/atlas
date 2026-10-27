import AtlasCore
import SwiftUI

/// Time Architect: plan sessions on a timeline (3D, Day, Week, Agenda),
/// with focus sessions, calendar events and conflicts in one place.
public struct TimeArchitectView: View {
    @ObservedObject var model: TimeArchitectModel

    public init(model: TimeArchitectModel) {
        self.model = model
    }

    public var body: some View {
        // A plain HStack: RealityView collapses inside a split view.
        HStack(spacing: 0) {
            SpacesPalette(model: model)
                .frame(width: 190)
            Divider()
            VStack(spacing: 0) {
                FocusBar(model: model)
                if let conflict = model.conflicts.first {
                    HStack {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                        Text("“\(conflict.first.block.title)” and “\(conflict.second.block.title)” overlap.").font(.callout)
                        Spacer()
                        if !conflict.movable.occurrence.block.isExternal {
                            Button(conflict.suggestion) { model.fix(conflict) }.controlSize(.small)
                        }
                    }
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(Color.red.opacity(0.08))
                }
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            Group {
                if let occurrence = model.selected {
                    BlockInspector(model: model, occurrence: occurrence).id(occurrence.id)
                } else {
                    TimelineHelp(model: model)
                }
            }
            .frame(width: 290)
        }
        .navigationTitle("Time Architect")
        .toolbar { toolbar }
        .alert("Time Architect", isPresented: Binding(get: { model.message != nil }, set: { if !$0 { model.message = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.message ?? "")
        }
        .confirmationDialog("Add events to “\(model.pendingWrite?.calendarName ?? "")”?",
                            isPresented: Binding(get: { model.pendingWrite != nil }, set: { if !$0 { model.pendingWrite = nil } })) {
            Button("Allow and Add") {
                if let pending = model.pendingWrite { model.writeToCalendar(pending.block, confirmed: true) }
                model.pendingWrite = nil
            }
            Button("Cancel", role: .cancel) { model.pendingWrite = nil }
        } message: {
            Text("This is the first time ATLAS writes to this calendar. Every change it makes is logged, and you can undo it in Calendar settings.")
        }
        .sheet(isPresented: $model.showCalendarSettings) { CalendarSettingsView(model: model) }
        .sheet(isPresented: $model.showFocusSettings) { FocusSettingsView(model: model) }
        .onChange(of: model.mode) { _, _ in model.reload() }
        .onChange(of: model.lanes) { _, _ in model.reload() }
    }

    @ViewBuilder
    private var content: some View {
        switch model.mode {
        case .ribbon:
            TimelineRibbonView(model: model)
        case .day:
            if model.lanes == .none {
                CalendarGridView(model: model, columns: [.init(id: "day", title: model.anchor.formatted(.dateTime.weekday(.wide).month().day()),
                                                               day: model.anchor, lane: nil)])
            } else {
                CalendarGridView(model: model, columns: model.laneNames.map {
                    .init(id: "lane-\($0)", title: model.anchor.formatted(.dateTime.weekday(.abbreviated).day()), day: model.anchor, lane: $0)
                })
            }
        case .week:
            CalendarGridView(model: model, columns: model.days.map {
                .init(id: $0.description, title: $0.formatted(.dateTime.weekday(.abbreviated).day()), day: $0, lane: nil)
            })
        case .agenda:
            AgendaView(model: model)
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            Picker("View", selection: $model.mode) {
                ForEach(TimeArchitectModel.Mode.allCases) { Label($0.title, systemImage: $0.symbol).tag($0) }
            }
            .pickerStyle(.segmented)
        }
        ToolbarItemGroup {
            Button { model.step(-1) } label: { Label("Previous", systemImage: "chevron.left") }
            Button("Today") { model.goToToday() }
            Button { model.step(1) } label: { Label("Next", systemImage: "chevron.right") }
            Picker("Lanes", selection: $model.lanes) {
                ForEach(TimeArchitectModel.Lanes.allCases) { Text($0.title).tag($0) }
            }
            .help("Group blocks into lanes by Space or project")
            Button { model.create(at: Date().addingTimeInterval(15 * 60)) } label: { Label("New Block", systemImage: "plus") }
                .help("Add a block starting soon")
            Menu {
                Button("Calendar…") { model.showCalendarSettings = true }
                Button("Focus Sessions…") { model.showFocusSettings = true }
            } label: { Label("Settings", systemImage: "gearshape") }
        }
    }
}

/// Spaces to drag onto the timeline to plan a session.
struct SpacesPalette: View {
    @ObservedObject var model: TimeArchitectModel

    var body: some View {
        List {
            Section("Drag onto the timeline") {
                ForEach(model.spaces) { space in
                    HStack {
                        Circle().fill(Color(timeHex: space.color) ?? .blue).frame(width: 10, height: 10)
                        Text(space.name)
                        Spacer()
                        Image(systemName: "line.3.horizontal").foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                    .draggable("space:\(space.id.uuidString)") {
                        Label(space.name, systemImage: "cube.transparent").padding(6).background(.regularMaterial, in: Capsule())
                    }
                    .contextMenu {
                        Button("Plan for Now") { model.create(at: Date(), minutes: Double(model.time.focus.settings.minutes(forSpace: space.id)), spaceID: space.id) }
                        Button("Focus Here Now") { model.startFocus(spaceID: space.id, title: space.name) }
                    }
                }
                if model.spaces.isEmpty { Text("Make a Space first").foregroundStyle(.secondary) }
            }
            Section("Block types") {
                ForEach(ScheduleBlock.Kind.allCases) { kind in
                    Label(kind.title, systemImage: kind.symbolName)
                }
            }
        }
        .listStyle(.sidebar)
    }
}

/// The running focus session: countdown and controls.
struct FocusBar: View {
    @ObservedObject var model: TimeArchitectModel

    var body: some View {
        HStack(spacing: 10) {
            if let session = model.focus {
                Image(systemName: "scope").foregroundStyle(.indigo)
                Text(session.title).fontWeight(.medium)
                if session.state == .running {
                    Text(timerInterval: Date()...session.endsAt(from: Date()), countsDown: true).monospacedDigit()
                } else {
                    Text("Paused · \(session.remaining(at: Date()).countdown) left").monospacedDigit().foregroundStyle(.secondary)
                }
                Spacer()
                if session.state == .running {
                    Button("Pause") { model.pauseFocus() }
                } else {
                    Button("Resume") { model.resumeFocus() }
                }
                Button("+10 min") { model.extendFocus(10) }
                Button("Stop", role: .destructive) { model.stopFocus() }
            } else {
                Image(systemName: "scope").foregroundStyle(.secondary)
                Text("No focus session").foregroundStyle(.secondary)
                Spacer()
                Menu("Start Focus") {
                    ForEach([25, 50, 90], id: \.self) { minutes in
                        Button("\(minutes) minutes") { model.startFocus(minutes: Double(minutes)) }
                    }
                }
                .fixedSize()
            }
        }
        .controlSize(.small)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(.bar)
    }
}

struct TimelineHelp: View {
    @ObservedObject var model: TimeArchitectModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Plan your time").font(.headline)
            Text("Drag a Space onto the timeline to plan a session, or double-click empty time in the Day or Week view.")
            Text("Select a block, then use ↑ and ↓ to move it 15 minutes and ⇧↑ ⇧↓ to change its length.")
            Text("A block's time and what it does are separate: the inspector shows both, so a block can be on time even if its automation failed.")
            if !model.time.calendar.isReadable {
                Button("Show My Calendar…") { model.showCalendarSettings = true }
            }
            Spacer()
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .padding(16)
    }
}

/// Edit one block, and see what happened at its scheduled time.
struct BlockInspector: View {
    @ObservedObject var model: TimeArchitectModel
    let occurrence: Occurrence
    @State private var draft: ScheduleBlock
    @State private var customRule = ""

    init(model: TimeArchitectModel, occurrence: Occurrence) {
        self.model = model
        self.occurrence = occurrence
        _draft = State(initialValue: occurrence.block)
        if case .custom(let rule) = occurrence.block.recurrence { _customRule = State(initialValue: rule) }
    }

    var body: some View {
        let status = model.status(of: occurrence)
        Form {
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text(status.scheduled).font(.callout.weight(.semibold))
                    Text("This time: \(status.state.title)").font(.caption).foregroundStyle(status.state == .missed ? .orange : .secondary)
                    ForEach(status.runs, id: \.self) { line in
                        Label(line, systemImage: "bolt.horizontal.circle").font(.caption)
                    }
                    if status.runs.isEmpty, draft.needsAutomation, status.state == .completed || status.state == .active {
                        Text("Its automation hasn't run for this time.").font(.caption).foregroundStyle(.orange)
                    }
                }
            }
            if occurrence.block.isExternal {
                Section("From your calendar") {
                    Text(occurrence.block.title).font(.headline)
                    Text("Read-only. ATLAS can link it to a Space: add a rule in Calendar settings.").font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Section("Block") {
                    TextField("Title", text: $draft.title)
                    Picker("Kind", selection: $draft.kind) {
                        ForEach(ScheduleBlock.Kind.allCases) { Label($0.title, systemImage: $0.symbolName).tag($0) }
                    }
                    DatePicker("Starts", selection: Binding(get: { draft.start }, set: { new in
                        let length = draft.duration
                        draft.start = new
                        draft.end = new.addingTimeInterval(length)
                    }))
                    DatePicker("Ends", selection: $draft.end, in: draft.start.addingTimeInterval(300)...)
                    Picker("Repeats", selection: Binding(get: { recurrenceTag }, set: { setRecurrence($0) })) {
                        Text("Doesn't repeat").tag("none")
                        Text("Every day").tag("daily")
                        Text("Every weekday").tag("weekdays")
                        Text("Every week").tag("weekly")
                        Text("Custom (RRULE)").tag("custom")
                    }
                    if recurrenceTag == "custom" {
                        TextField("FREQ=WEEKLY;BYDAY=MO,WE", text: $customRule)
                            .onSubmit { draft.recurrence = .custom(customRule) }
                        Text(Recurrence.custom(customRule).title).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Section("Links") {
                    Picker("Space", selection: $draft.spaceID) {
                        Text("None").tag(UUID?.none)
                        ForEach(model.spaces) { Text($0.name).tag(Optional($0.id)) }
                    }
                    if let space = model.space(draft.spaceID), !space.profiles.isEmpty {
                        Picker("Profile", selection: $draft.profileID) {
                            Text("Default").tag(UUID?.none)
                            ForEach(space.profiles, id: \.id) { Text($0.name).tag(Optional($0.id)) }
                        }
                    }
                    Picker("Project", selection: $draft.projectID) {
                        Text("None").tag(UUID?.none)
                        ForEach(model.projects, id: \.id) { Text($0.name).tag(Optional($0.id)) }
                    }
                    Picker("Workflow", selection: $draft.workflowID) {
                        Text("None").tag(UUID?.none)
                        ForEach(((try? model.core.store.workflows()) ?? []).filter { !$0.name.hasPrefix("Schedule: ") }, id: \.id) {
                            Text($0.name).tag(Optional($0.id))
                        }
                    }
                }
                Section {
                    Picker("Reminder", selection: $draft.reminderMinutes) {
                        Text("None").tag(Int?.none)
                        ForEach([5, 10, 15, 30, 60], id: \.self) { Text("\($0) min before").tag(Optional($0)) }
                    }
                    Picker("At the start", selection: $draft.startBehavior) {
                        ForEach(ScheduleBlock.StartBehavior.allCases) { Text($0.title).tag($0) }
                    }
                    Picker("At the end", selection: $draft.endBehavior) {
                        ForEach(ScheduleBlock.EndBehavior.allCases) { Text($0.title).tag($0) }
                    }
                    if draft.endBehavior == .activateSpace {
                        Picker("Space at the end", selection: $draft.endSpaceID) {
                            Text("Choose…").tag(UUID?.none)
                            ForEach(model.spaces) { Text($0.name).tag(Optional($0.id)) }
                        }
                    }
                    Picker("If the Mac was asleep", selection: $draft.missedPolicy) {
                        ForEach(ScheduleBlock.MissedPolicy.allCases) { Text($0.title).tag($0) }
                    }
                } header: {
                    Text("What happens")
                } footer: {
                    Text(draft.needsAutomation ? "Saved as a Flow workflow (“Schedule: \(draft.title)”) with Block Starting/Ended triggers, so it shows in Run History like any automation." : "Nothing runs automatically.")
                        .font(.caption)
                }
                Section {
                    HStack {
                        Button("Save") { model.save(draft) }.keyboardShortcut(.defaultAction).disabled(draft == occurrence.block)
                        Button("Focus Now") { model.startFocus(minutes: draft.duration / 60, spaceID: draft.spaceID, title: draft.title, blockID: draft.id) }
                    }
                    HStack {
                        if occurrence.block.recurrence.isRepeating, status.state == .upcoming {
                            Button("Skip This Time") { model.skip(occurrence) }
                        }
                        if model.time.calendar.isReadable, draft.externalEventID == nil, !model.time.calendar.settings.writableCalendarIDs.isEmpty {
                            Button("Add to Calendar") { model.writeToCalendar(draft) }
                        }
                        Spacer()
                        Button("Delete", role: .destructive) { model.delete(occurrence) }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private var recurrenceTag: String {
        switch draft.recurrence {
        case .none: return "none"
        case .daily: return "daily"
        case .weekdays: return "weekdays"
        case .weekly: return "weekly"
        case .custom: return "custom"
        }
    }

    private func setRecurrence(_ tag: String) {
        switch tag {
        case "daily": draft.recurrence = .daily
        case "weekdays": draft.recurrence = .weekdays
        case "weekly": draft.recurrence = .weekly
        case "custom":
            if customRule.isEmpty { customRule = "FREQ=WEEKLY;BYDAY=MO,WE,FR" }
            draft.recurrence = .custom(customRule)
        default: draft.recurrence = .none
        }
    }
}
