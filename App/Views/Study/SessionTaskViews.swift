import AppKit
import AtlasCore
import AtlasStudy
import SwiftUI

// MARK: - The session window

/// The study session's window: before the timer, "What do you want to get
/// done?"; during it, the countdown with the task list underneath. A fixed
/// (resizable) size, so the list scrolls and a new task is always in view.
struct StudySessionPanel: View {
    @EnvironmentObject private var model: StudyTasksModel

    var body: some View {
        VStack(spacing: 14) {
            if model.plan != nil {
                PlanningHeader()
                LockInRow()
            } else if model.isRunning {
                SessionTimerCard()
                if let gate = model.exitGate { ExitGateBanner(gate: gate) }
                LockInRow()
                if model.allDone { AllDoneBanner() }
                if let checkIn = model.checkIn { CheckInBanner(checkIn: checkIn) }
            }
            if model.plan != nil || model.isRunning {
                TaskListView(planning: model.plan != nil)
                PanelFooter()
            } else {
                Spacer()
                Text("No study session running.").foregroundStyle(.secondary)
                Button("Plan a session") { model.begin() }
                Spacer()
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 30)
        .padding(.bottom, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
        .animation(.easeInOut(duration: 0.2), value: model.checkIn)
        .animation(.easeInOut(duration: 0.2), value: model.allDone)
        .animation(.easeInOut(duration: 0.2), value: model.exitGate)
    }
}

// MARK: - Lock in

/// "Lock me in": the windows picked for this session, or the lock running.
private struct LockInRow: View {
    @EnvironmentObject private var model: StudyTasksModel
    @State private var picking = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: model.locked != nil ? "lock.fill" : "lock.open")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(model.locked != nil ? Color.white : Color.secondary)
                .frame(width: 28, height: 28)
                .background(Circle().fill(model.locked != nil ? AnyShapeStyle(Color.orange.gradient) : AnyShapeStyle(.quaternary)))
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.callout.weight(.semibold))
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 4)
            if model.locked == nil {
                Button(model.lockPicked.isEmpty ? "Choose…" : "Change…") {
                    picking = true
                    Task { await model.refreshLockChoices() }
                }
                .controlSize(.small)
                .popover(isPresented: $picking, arrowEdge: .bottom) {
                    WindowPicker(planning: model.plan != nil) { picking = false }.environmentObject(model)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(model.locked != nil ? AnyShapeStyle(Color.orange.opacity(0.12)) : AnyShapeStyle(.quaternary.opacity(0.5)))
        )
    }

    private var title: String {
        if model.locked != nil { return "Locked in" }
        return model.lockPicked.isEmpty ? "Lock me in" : "Lock in when the timer starts"
    }

    private var subtitle: String {
        if let locked = model.locked { return "Only \(locked.summary) until the session ends" }
        let picked = model.pickedWindows
        if picked.isEmpty { return "Pick the windows you'll use; everything else hides" }
        return picked.map(\.label).joined(separator: ", ")
    }
}

/// The open windows to pick from, last time's first.
private struct WindowPicker: View {
    @EnvironmentObject private var model: StudyTasksModel
    let planning: Bool
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Lock me in to…").font(.headline)
                Spacer()
                Button { Task { await model.refreshLockChoices() } } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless).help("Refresh the list of windows")
            }
            if !model.canLockWindows {
                VStack(alignment: .leading, spacing: 6) {
                    Label("ATLAS doesn't have Accessibility permission, so it can only lock whole apps, not single windows.",
                          systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                    Button("Open Accessibility Settings…") { model.openAccessibilitySettings() }.controlSize(.small)
                }
            }
            let last = model.lastLockWindowsOpen
            if !last.isEmpty, model.lockPicked.isEmpty {
                Button("Same as last time (\(last.count))") { model.pick(last) }.controlSize(.small)
            }
            if model.lockChoices.isEmpty {
                Text("No windows open. Open what you need, then refresh.")
                    .font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 80)
            } else {
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(model.lockChoices) { window in WindowChoiceRow(window: window) }
                    }
                }
                .frame(maxHeight: 280)
            }
            Text("Everything else hides until the session ends. Other windows of these apps are minimized. Quitting ATLAS always unlocks.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                if !model.lockPicked.isEmpty {
                    Button("Clear") { model.pick([]) }
                }
                Spacer()
                if planning {
                    Button("Done", action: close).buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                } else {
                    Button("Cancel", action: close)
                    Button {
                        model.lockIn()
                        close()
                    } label: { Label("Lock in", systemImage: "lock.fill") }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.lockPicked.isEmpty)
                    .keyboardShortcut(.defaultAction)
                }
            }
            .controlSize(.small)
        }
        .padding(14)
        .frame(width: 340)
    }
}

private struct WindowChoiceRow: View {
    @EnvironmentObject private var model: StudyTasksModel
    let window: WindowInfo

    var body: some View {
        let picked = model.lockPicked.contains(window.id.rawValue)
        Button { model.togglePick(window) } label: {
            HStack(spacing: 10) {
                Image(systemName: picked ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 16))
                    .foregroundStyle(picked ? Color.orange : Color.secondary.opacity(0.7))
                AppIcon(bundleID: window.bundleID).frame(width: 20, height: 20)
                VStack(alignment: .leading, spacing: 0) {
                    Text(window.title.isEmpty ? window.appName : window.title).font(.callout).lineLimit(1).truncationMode(.middle)
                    Text(window.isMinimized ? "\(window.appName) · minimized" : window.appName)
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(picked ? Color.orange.opacity(0.12) : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct AppIcon: View {
    let bundleID: String

    var body: some View {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable()
        } else {
            Image(systemName: "macwindow").foregroundStyle(.secondary)
        }
    }
}

/// "End the session and unlock?": the button works after a short countdown.
private struct ExitGateBanner: View {
    @EnvironmentObject private var model: StudyTasksModel
    let gate: LockdownExitGate

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let left = gate.secondsLeft(at: context.date)
            VStack(alignment: .leading, spacing: 8) {
                Label("You're locked in. End the session and unlock?", systemImage: "lock.fill")
                    .font(.callout.weight(.semibold))
                HStack {
                    Button(left > 0 ? "End in \(left)…" : "End and unlock") { model.confirmEnd() }
                        .buttonStyle(.borderedProminent).tint(.red)
                        .disabled(left > 0)
                    Button("Keep going") { model.cancelEnd() }.keyboardShortcut(.cancelAction)
                }
                .controlSize(.small)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.red.opacity(0.1)))
        }
        .transition(.opacity.combined(with: .move(edge: .top)))
    }
}

private struct PlanningHeader: View {
    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "hourglass")
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(Circle().fill(Color(nsColor: NSColor(atlasHex: "#6F8A6E")).gradient))
            Text("What do you want to get done?")
                .font(.title3.weight(.semibold))
            Text("Return adds a task · Tab starts the timer")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

/// Phase, a big countdown, progress towards the session's goal, controls.
private struct SessionTimerCard: View {
    @EnvironmentObject private var model: StudyTasksModel

    var body: some View {
        let sessions = model.study?.sessions
        let phase = sessions?.phase
        let running = model.core?.time?.focus.session.flatMap { $0.id == phase?.sessionID ? $0 : nil }
        let isBreak = phase?.isBreak ?? false
        let tint = isBreak ? Color.teal : Color(nsColor: NSColor(atlasHex: "#6F8A6E"))
        VStack(spacing: 6) {
            Text((phase.map { $0.isBreak ? $0.title : "Focus \($0.completedFocus + 1)" } ?? "Study").uppercased())
                .font(.caption.weight(.semibold))
                .tracking(1.2)
                .foregroundStyle(tint)
            Group {
                if let running, running.state == .running {
                    Text(timerInterval: Date()...running.endsAt(from: Date()), countsDown: true)
                } else if let running {
                    Text(Duration.seconds(running.remaining(at: Date())).formatted(.time(pattern: .minuteSecond)))
                        .foregroundStyle(.secondary)
                } else {
                    Text("Ready").foregroundStyle(.secondary)
                }
            }
            .font(.system(size: 40, weight: .light, design: .rounded).monospacedDigit())
            TimelineView(.periodic(from: .now, by: 15)) { _ in
                if let goal = sessions?.goalSeconds, goal > 0 {
                    ProgressView(value: min(1, (sessions?.focusedSeconds() ?? 0) / goal))
                        .progressViewStyle(.linear)
                        .tint(tint)
                        .frame(width: 180)
                }
            }
            HStack(spacing: 18) {
                let paused = sessions?.isPaused == true
                RoundIconButton(symbol: paused ? "play.fill" : "pause.fill", help: paused ? "Resume" : "Pause", prominent: true) {
                    if paused { sessions?.resume() } else { sessions?.pause() }
                }
                RoundIconButton(symbol: "forward.end.fill", help: "Skip to the next phase") { sessions?.skipPhase() }
                RoundIconButton(symbol: "stop.fill", help: "End the session") { model.study?.endSession() }
            }
            .padding(.top, 2)
        }
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(tint.opacity(0.09)))
    }
}

private struct RoundIconButton: View {
    let symbol: String
    let help: String
    var prominent = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: prominent ? 15 : 12, weight: .semibold))
                .frame(width: prominent ? 38 : 30, height: prominent ? 38 : 30)
                .foregroundStyle(prominent ? Color.white : Color.primary)
                .background(Circle().fill(prominent ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.quaternary)))
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }
}

private struct CheckInBanner: View {
    @EnvironmentObject private var model: StudyTasksModel
    let checkIn: StudyTasksModel.CheckIn

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                Text("Did you finish “\(checkIn.title)”?").font(.callout).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                Button { model.answerCheckIn(done: false) } label: { Image(systemName: "xmark").font(.caption2) }
                    .buttonStyle(.plain).foregroundStyle(.secondary).help("Dismiss")
            }
            HStack {
                Button("Done") { model.answerCheckIn(done: true) }.buttonStyle(.borderedProminent)
                Button("Still working") { model.answerCheckIn(done: false) }
            }
            .controlSize(.small)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.accentColor.opacity(0.1)))
        .transition(.opacity.combined(with: .move(edge: .top)))
    }
}

private struct AllDoneBanner: View {
    @EnvironmentObject private var model: StudyTasksModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("All done! End early or keep going?", systemImage: "sparkles").font(.callout.weight(.semibold))
            HStack {
                Button("End early") { model.endEarly() }.buttonStyle(.borderedProminent)
                Button("Keep going") { model.allDone = false }
            }
            .controlSize(.small)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.green.opacity(0.12)))
        .transition(.opacity.combined(with: .move(edge: .top)))
    }
}

private struct PanelFooter: View {
    @EnvironmentObject private var model: StudyTasksModel

    var body: some View {
        HStack {
            let total = model.list.tasks.count
            Text(total == 0 ? "No tasks yet" : "\(model.list.finished.count) of \(total) done")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            if model.plan != nil {
                Button("Cancel") { model.cancelPlan() }
                    .keyboardShortcut(.cancelAction)
                Button {
                    model.startTimer()
                } label: {
                    Label("Start", systemImage: "play.fill").padding(.horizontal, 6)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: .command)
                .help("Start the timer (Tab, or ⌘Return)")
            }
        }
        .controlSize(.large)
    }
}

// MARK: - The task list

/// The add field on top, open tasks (the current one marked), then Done.
struct TaskListView: View {
    @EnvironmentObject private var model: StudyTasksModel
    let planning: Bool
    @State private var draft = ""
    @State private var selection: UUID?
    @State private var showsChalkboard = false
    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(Color.accentColor)
                TextField(planning ? "Outline essay x2 #ENG110" : "Add a task", text: $draft)
                    .textFieldStyle(.plain)
                    .font(.body)
                    .focused($fieldFocused)
                    .onSubmit {
                        if model.add(draft) { draft = "" }
                        fieldFocused = true
                    }
                    .onKeyPress(.tab) {
                        guard planning else { return .ignored }
                        if !draft.trimmingCharacters(in: .whitespaces).isEmpty { model.add(draft) }
                        model.startTimer()
                        return .handled
                    }
                Button {
                    showsChalkboard = true
                } label: {
                    Image(systemName: "list.bullet.clipboard")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("From chalkboard: add this week's assignments")
                .popover(isPresented: $showsChalkboard) { ChalkboardPicker { showsChalkboard = false } }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.quaternary.opacity(0.6)))

            let open = model.list.open, finished = model.list.finished
            if open.isEmpty && finished.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "checklist").font(.title2).foregroundStyle(.tertiary)
                    Text(planning ? "Optional: you can start with no tasks." : "No tasks yet. Type one above and press Return.")
                        .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    Text("“x2” or “🍅2” for an estimate · “#CHEM101” for a course")
                        .font(.caption).foregroundStyle(.tertiary).multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    List(selection: $selection) {
                        ForEach(open) { task in
                            TaskRow(task: task, isCurrent: task.id == model.current?.id)
                                .tag(task.id)
                                .id(task.id)
                                .listRowSeparator(.hidden)
                                .listRowInsets(EdgeInsets(top: 2, leading: 0, bottom: 2, trailing: 0))
                        }
                        .onMove { model.move(from: $0, to: $1) }
                        if !finished.isEmpty {
                            Section {
                                ForEach(finished) { task in
                                    TaskRow(task: task, isCurrent: false)
                                        .tag(task.id)
                                        .listRowSeparator(.hidden)
                                        .listRowInsets(EdgeInsets(top: 2, leading: 0, bottom: 2, trailing: 0))
                                }
                            } header: {
                                Text("Done · \(finished.count)").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                    .frame(maxHeight: .infinity)
                    .onKeyPress(.space) {
                        guard let selection, !fieldFocused, model.editingID == nil else { return .ignored }
                        toggle(selection)
                        return .handled
                    }
                    .onKeyPress(.return) {
                        guard let selection, !fieldFocused, model.editingID == nil,
                              model.list.open.contains(where: { $0.id == selection }) else { return .ignored }
                        model.editingID = selection
                        return .handled
                    }
                    .onDeleteCommand {
                        if let selection, model.editingID == nil { model.delete(selection) }
                    }
                    // A new task scrolls into view.
                    .onChange(of: open.last?.id) { _, id in
                        if let id { withAnimation { proxy.scrollTo(id, anchor: .bottom) } }
                    }
                }
            }
        }
        .frame(maxHeight: .infinity)
        .onAppear { fieldFocused = true }
    }

    private func toggle(_ id: UUID) {
        guard let task = model.list.tasks.first(where: { $0.id == id }) else { return }
        task.done ? model.uncheck(id) : model.check(id)
    }
}

/// Checkbox, title with its course and "Now", estimate as tomato dots.
struct TaskRow: View {
    @EnvironmentObject private var model: StudyTasksModel
    let task: SessionTask
    let isCurrent: Bool
    @State private var text = ""
    @State private var hovering = false
    @FocusState private var titleFocused: Bool

    private var editing: Bool { model.editingID == task.id }

    private func startEditing() {
        guard !task.done else { return }
        model.editingID = task.id
    }

    private func commit() {
        guard editing else { return }
        if text != task.title { model.edit(task.id, title: text) } else { model.editingID = nil }
    }

    var body: some View {
        let striking = model.striking.contains(task.id)
        let checked = task.done || striking
        HStack(spacing: 10) {
            Button {
                task.done ? model.uncheck(task.id) : model.check(task.id)
            } label: {
                Image(systemName: checked ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 18))
                    .foregroundStyle(checked ? Color.green : Color.secondary.opacity(0.7))
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(checked ? "Uncheck \(task.title)" : "Check off \(task.title)")

            VStack(alignment: .leading, spacing: 2) {
                if editing {
                    TextField("Task", text: $text)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13, weight: isCurrent ? .semibold : .regular))
                        .focused($titleFocused)
                        .onSubmit { commit() }
                        .onExitCommand { model.editingID = nil }
                        .onChange(of: titleFocused) { _, focused in if !focused && editing { commit() } }
                        .onAppear {
                            text = task.title
                            DispatchQueue.main.async { titleFocused = true }
                        }
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(.background))
                        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(Color.accentColor.opacity(0.6), lineWidth: 1))
                } else {
                    Text(task.title)
                        .font(.system(size: 13, weight: isCurrent ? .semibold : .regular))
                        .strikethrough(checked, color: .secondary)
                        .foregroundStyle(checked ? .secondary : .primary)
                        .lineLimit(2)
                }
                let meta = metaParts
                if isCurrent || !meta.isEmpty {
                    HStack(spacing: 6) {
                        if isCurrent {
                            Text("NOW").font(.system(size: 9, weight: .bold)).tracking(0.6)
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(Capsule().fill(Color.accentColor.opacity(0.18)))
                                .foregroundStyle(Color.accentColor)
                        }
                        if let link = task.link {
                            HStack(spacing: 3) {
                                Circle().fill(Color(nsColor: NSColor(atlasHex: link.color ?? "#B8BCCB"))).frame(width: 6, height: 6)
                                Text(link.label)
                            }
                        }
                        if let carried = task.carriedLabel(now: Date()), !task.done { Text(carried) }
                        if task.pinned { Image(systemName: "pin.fill") }
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 4)
            if hovering && !editing && !task.done {
                Button(action: startEditing) {
                    Image(systemName: "pencil").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                        .frame(width: 22, height: 22).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Edit task (or double-click, or press Return)")
                .accessibilityLabel("Edit \(task.title)")
            }
            TomatoDots(estimate: task.estimatedPomodoros, actual: task.actualPomodoros)
        }
        .padding(.vertical, 7)
        .padding(.horizontal, 10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isCurrent ? Color.accentColor.opacity(0.1) : Color.clear)
        )
        .overlay(alignment: .leading) {
            if isCurrent {
                Capsule().fill(Color.accentColor).frame(width: 3).padding(.vertical, 8)
            }
        }
        .opacity(task.done ? 0.7 : 1)
        .animation(.easeOut(duration: 0.3), value: checked)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .simultaneousGesture(TapGesture(count: 2).onEnded { startEditing() })
        .contextMenu {
            Menu("Estimate") {
                Button("None") { model.setEstimate(task.id, nil) }
                ForEach(1...8, id: \.self) { n in Button("\(n) 🍅") { model.setEstimate(task.id, n) } }
            }
            Menu("Course") {
                Button("None") { model.setLink(task.id, nil) }
                ForEach(model.links, id: \.id) { link in Button(link.label) { model.setLink(task.id, link) } }
            }
            if !task.done {
                Button(task.pinned ? "Unpin" : "Make Current") { model.pin(task.id) }
            }
            if !task.done { Button("Edit") { startEditing() } }
            Divider()
            Button("Delete", role: .destructive) { model.delete(task.id) }
        }
    }

    private var metaParts: [String] {
        [task.link?.label, task.carriedLabel(now: Date()), task.pinned ? "pinned" : nil].compactMap { $0 }
    }
}

/// The estimate as small tomato dots, filled as pomodoros are spent.
struct TomatoDots: View {
    let estimate: Int?
    let actual: Int

    var body: some View {
        let total = max(estimate ?? 0, actual)
        if total > 0 {
            HStack(spacing: 2) {
                ForEach(0..<min(total, 8), id: \.self) { index in
                    Circle()
                        .fill(index < actual ? (index < (estimate ?? 0) ? Color.red : Color.orange) : Color.clear)
                        .overlay(Circle().stroke(Color.red.opacity(0.6), lineWidth: 1))
                        .frame(width: 7, height: 7)
                }
            }
            .help(estimate.map { "Planned \($0) 🍅 · \(actual) so far" } ?? "\(actual) 🍅 so far")
        }
    }
}

/// "From chalkboard": this week's assignments, pick some to add as tasks.
private struct ChalkboardPicker: View {
    @EnvironmentObject private var model: StudyTasksModel
    let close: () -> Void
    @State private var picked: Set<UUID> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("From chalkboard").font(.headline)
            let items = model.chalkboard
            if items.isEmpty {
                Text("Nothing due this week that isn't already a task.").font(.callout).foregroundStyle(.secondary)
            } else {
                ForEach(items) { item in
                    Toggle(isOn: Binding(get: { picked.contains(item.id) }, set: { on in
                        if on { picked.insert(item.id) } else { picked.remove(item.id) }
                    })) {
                        HStack(spacing: 6) {
                            if let link = model.links.first(where: { $0.id == item.courseID }) {
                                Circle().fill(Color(nsColor: NSColor(atlasHex: link.color ?? "#B8BCCB"))).frame(width: 7, height: 7)
                                Text(link.label).font(.caption).foregroundStyle(.secondary)
                            }
                            Text(item.title).lineLimit(1)
                        }
                    }
                }
            }
            HStack {
                Spacer()
                Button("Cancel", action: close)
                Button("Add \(picked.count)") {
                    model.addAssignments(items.map(\.id).filter(picked.contains))
                    close()
                }
                .disabled(picked.isEmpty)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(14)
        .frame(width: 320)
    }
}

// MARK: - On the summary card

/// "4 of 5 tasks done", the finished ones with planned vs. actual, and
/// "Carry 1 unfinished task to next time?".
struct SummaryTasksSection: View {
    @EnvironmentObject private var study: StudyModel
    let tally: SessionTaskTally
    let sessionID: UUID

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(tally.headline, systemImage: "checklist").font(.callout.weight(.semibold))
            ForEach(Array(tally.finished.prefix(6).enumerated()), id: \.offset) { _, line in
                Label(line.text, systemImage: "checkmark").font(.caption).foregroundStyle(.secondary)
            }
            if tally.unfinished > 0 {
                HStack {
                    Text("Carry \(tally.unfinished) unfinished task\(tally.unfinished == 1 ? "" : "s") to next time?").font(.callout)
                    Spacer(minLength: 4)
                    Button("Carry over") { study.tasksUI.carryOver(sessionID) }
                    Button("Clear") { study.tasksUI.clear(sessionID) }
                }
                .controlSize(.small)
            }
        }
    }
}
