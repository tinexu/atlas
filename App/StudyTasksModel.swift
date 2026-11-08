import AppKit
import AtlasCore
import AtlasStudy
import SwiftUI

/// The study session's task list on screen: the session window (planning
/// before the timer starts, then the countdown and tasks), the quick-add
/// field (⌥⇧T from any app), the break check-in and "All done!". The rules
/// live in `StudyTasks`; this only presents them.
@MainActor
final class StudyTasksModel: ObservableObject {
    /// A soft "Did you finish …?" at a break.
    struct CheckIn: Equatable {
        let taskID: UUID
        let title: String
    }

    /// Before the timer starts: what "Start" will begin.
    struct Plan: Equatable {
        var minutes: Double?
        var pomodoro: Bool?
    }

    weak var study: StudyModel?
    let core: AtlasCore?
    var tasks: StudyTasks? { study?.module?.tasks }

    @Published private(set) var list = SessionTaskList([])
    @Published private(set) var links: [SessionTask.Link] = []
    /// Set while the window asks "What do you want to get done?" before the timer starts.
    @Published private(set) var plan: Plan?
    @Published private(set) var checkIn: CheckIn?
    /// The last task was checked off: "All done! End early or keep going?"
    @Published var allDone = false
    /// Rows striking through before they slide to "Done".
    @Published private(set) var striking: Set<UUID> = []
    @Published private(set) var hotKeyProblem: String?
    /// The task whose title is being edited in place (one at a time).
    @Published var editingID: UUID?

    private var panel: NSPanel?
    private var quickAdd: QuickAddPanel?
    private var hotKey: TriggerToken?
    private var registeredHotKey = ""
    private var subscription: EventBus.Subscription?
    /// The session the window was last shown for.
    private var shownFor: UUID?
    private let environment = MacTriggerEnvironment()

    init(core: AtlasCore?) {
        self.core = core
        subscription = core?.events.subscribe { [weak self] event in
            guard event.name.hasPrefix("session.task") || event.name == AtlasEvent.Name.studySessionChanged
                || event.name == AtlasEvent.Name.studySessionEnded || event.name == AtlasEvent.Name.studyChanged else { return }
            Task { @MainActor in self?.handle(event) }
        }
    }

    var settings: SessionTaskSettings { study?.settings.tasks ?? SessionTaskSettings() }
    var isRunning: Bool { study?.sessions?.current != nil }
    var current: SessionTask? { list.current }

    /// The current task, short, for the menu bar.
    var menuBarTitle: String? {
        guard isRunning, let title = current?.title else { return nil }
        return title.count > 22 ? String(title.prefix(21)) + "…" : title
    }

    func reload() {
        guard let tasks else { return }
        list = tasks.list()
        links = tasks.links()
        registerHotKey()
    }

    private func handle(_ event: AtlasEvent) {
        switch event.name {
        case AtlasEvent.Name.sessionTaskCheckIn:
            if let id = event.payload["taskId"]?.stringValue.flatMap(UUID.init(uuidString:)) {
                checkIn = CheckIn(taskID: id, title: event.payload["title"]?.stringValue ?? "")
                // Shown softly: in front, never taking focus.
                panel?.orderFrontRegardless()
            }
        case AtlasEvent.Name.sessionTaskCompleted:
            if event.payload["last"]?.boolValue == true { allDone = true }
            if let id = event.payload["taskId"]?.stringValue.flatMap(UUID.init(uuidString:)), checkIn?.taskID == id { checkIn = nil }
        case AtlasEvent.Name.studySessionChanged:
            // A session started some other way (an automation, the Companion): show its window once.
            if let id = study?.sessions?.current?.id, id != shownFor {
                shownFor = id
                plan = nil
                showPanel(activate: false)
            }
        case AtlasEvent.Name.studySessionEnded:
            plan = nil
            checkIn = nil
            allDone = false
            shownFor = nil
            panel?.orderOut(nil)
        default:
            break
        }
        reload()
    }

    // MARK: - Starting

    /// The hourglass was clicked: ask what to get done first (if that's
    /// on), otherwise start right away.
    func begin(minutes: Double? = nil, pomodoro: Bool? = nil) {
        if settings.promptAtStart {
            plan = Plan(minutes: minutes, pomodoro: pomodoro)
            reload()
            showPanel(activate: true)
        } else {
            study?.beginSession(minutes: minutes, pomodoro: pomodoro)
        }
    }

    /// "Start" (or Tab) in the planning window.
    func startTimer() {
        let plan = self.plan ?? Plan()
        self.plan = nil
        study?.beginSession(minutes: plan.minutes, pomodoro: plan.pomodoro)
        if let id = study?.sessions?.current?.id { shownFor = id }
        reload()
    }

    func cancelPlan() {
        plan = nil
        panel?.orderOut(nil)
    }

    // MARK: - Changing

    /// Adds what was typed; true if a task was added.
    @discardableResult
    func add(_ text: String) -> Bool {
        guard tasks?.add(text) != nil else { return false }
        reload()
        return true
    }

    func addAssignments(_ ids: [UUID]) {
        tasks?.addAssignments(ids)
        reload()
    }

    var chalkboard: [MergedAssignment] { tasks?.chalkboard() ?? [] }

    /// Checks a task off: a quick strikethrough, then it slides to "Done".
    func check(_ id: UUID) {
        guard !striking.contains(id) else { return }
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            tasks?.check(id)
            reload()
            return
        }
        withAnimation(.easeOut(duration: 0.3)) { _ = striking.insert(id) }
        Task {
            try? await Task.sleep(for: .milliseconds(450))
            tasks?.check(id)
            withAnimation(.spring(duration: 0.4)) {
                striking.remove(id)
                reload()
            }
        }
    }

    func uncheck(_ id: UUID) { tasks?.uncheck(id); reload() }
    func pin(_ id: UUID) { tasks?.pin(id); reload() }
    func delete(_ id: UUID) { tasks?.delete(id); reload() }
    /// Saves an edited title ("x3" and "#course" work here too). An empty
    /// title leaves the task as it was.
    func edit(_ id: UUID, title: String) {
        if editingID == id { editingID = nil }
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        tasks?.edit(id, title: title)
        reload()
    }
    func setEstimate(_ id: UUID, _ estimate: Int?) { tasks?.setEstimate(id, estimate); reload() }
    func setLink(_ id: UUID, _ link: SessionTask.Link?) { tasks?.setLink(id, link); reload() }

    func move(from source: IndexSet, to destination: Int) {
        var ids = list.open.map(\.id)
        ids.move(fromOffsets: source, toOffset: destination)
        tasks?.reorder(ids)
        reload()
    }

    /// "Done" on the break check-in.
    func answerCheckIn(done: Bool) {
        if done, let checkIn { check(checkIn.taskID) }
        checkIn = nil
    }

    func endEarly() {
        allDone = false
        study?.endSession()
    }

    // MARK: - Summary

    func carryOver(_ sessionID: UUID) {
        tasks?.carryOver(sessionID: sessionID)
        study?.markTasksDecided()
        reload()
    }

    func clear(_ sessionID: UUID) {
        tasks?.clear(sessionID: sessionID)
        study?.markTasksDecided()
        reload()
    }

    // MARK: - Windows

    /// Shows the running session's window, or asks what to get done first.
    func openSessionWindow() {
        if isRunning {
            reload()
            showPanel(activate: true)
        } else {
            begin()
        }
    }

    /// A fixed-size (resizable) window: the task list scrolls inside it, so
    /// new tasks are always in view.
    func showPanel(activate: Bool) {
        let panel = self.panel ?? {
            let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 540),
                                styleMask: [.titled, .closable, .resizable, .fullSizeContentView, .utilityWindow],
                                backing: .buffered, defer: false)
            panel.title = "Study session"
            panel.titleVisibility = .hidden
            panel.titlebarAppearsTransparent = true
            panel.isMovableByWindowBackground = true
            panel.level = .floating
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.isReleasedWhenClosed = false
            panel.hidesOnDeactivate = false
            panel.minSize = NSSize(width: 320, height: 420)
            panel.contentView = NSHostingView(rootView: StudySessionPanel().environmentObject(self))
            panel.setFrameAutosaveName("StudySessionWindow")
            if !panel.setFrameUsingName("StudySessionWindow"), let frame = NSScreen.main?.visibleFrame {
                panel.setFrameTopLeftPoint(NSPoint(x: frame.maxX - panel.frame.width - 24, y: frame.maxY - 24))
            }
            return panel
        }()
        self.panel = panel
        if activate {
            NSApp.activate(ignoringOtherApps: true)
            panel.makeKeyAndOrderFront(nil)
        } else {
            panel.orderFrontRegardless()
        }
    }

    func closePanel() {
        panel?.orderOut(nil)
    }

    /// ⌥⇧T: a tiny field under the menu bar. Return adds the task and puts
    /// you back in the app you were using.
    func showQuickAdd() {
        let previous = NSWorkspace.shared.frontmostApplication
        let quickAdd = self.quickAdd ?? QuickAddPanel()
        self.quickAdd = quickAdd
        quickAdd.show(isRunning: isRunning) { [weak self] text in
            guard let self else { return }
            if let text, !text.trimmingCharacters(in: .whitespaces).isEmpty { self.add(text) }
            if let previous, previous.bundleIdentifier != Bundle.main.bundleIdentifier { previous.activate() }
        }
    }

    private func registerHotKey() {
        let text = settings.quickAddHotKey
        guard text != registeredHotKey else { return }
        registeredHotKey = text
        hotKey?.cancel()
        hotKey = nil
        hotKeyProblem = nil
        guard !text.isEmpty else { return }
        switch HotKey.parse(text) {
        case .success(let key):
            do {
                hotKey = try environment.registerHotKey(key) { [weak self] in
                    DispatchQueue.main.async { MainActor.assumeIsolated { self?.showQuickAdd() } }
                }
            } catch {
                hotKeyProblem = "Quick add \(key.display): \(error.localizedDescription)"
            }
        case .failure(let error):
            hotKeyProblem = "Quick add shortcut: \(error.message)"
        }
    }
}

/// A one-line floating field near the menu bar. It takes the keyboard only
/// while it's open, and closes on Return or Escape.
@MainActor
final class QuickAddPanel {
    private final class Panel: NSPanel {
        override var canBecomeKey: Bool { true }
    }

    private var panel: Panel?
    private var done: ((String?) -> Void)?

    func show(isRunning: Bool, done: @escaping (String?) -> Void) {
        self.done = done
        let panel = Panel(contentRect: NSRect(x: 0, y: 0, width: 380, height: 52), styleMask: [.borderless, .nonactivatingPanel],
                          backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.contentView = NSHostingView(rootView: QuickAddField(isRunning: isRunning) { [weak self] text in self?.finish(text) })
        if let frame = NSScreen.main?.visibleFrame {
            panel.setFrameTopLeftPoint(NSPoint(x: frame.maxX - 380 - 16, y: frame.maxY - 6))
        }
        self.panel?.orderOut(nil)
        self.panel = panel
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    private func finish(_ text: String?) {
        panel?.orderOut(nil)
        panel = nil
        let done = self.done
        self.done = nil
        done?(text)
    }
}

private struct QuickAddField: View {
    let isRunning: Bool
    let done: (String?) -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "checklist").foregroundStyle(.secondary)
            TextField(isRunning ? "Add a task to this session" : "Add a task for your next study session", text: $text)
                .textFieldStyle(.plain)
                .font(.title3)
                .focused($focused)
                .onSubmit { done(text) }
                .onExitCommand { done(nil) }
        }
        .padding(.horizontal, 14)
        .frame(width: 372, height: 44)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .padding(4)
        .onAppear { focused = true }
    }
}
