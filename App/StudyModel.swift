import AppKit
import AtlasCore
import AtlasOrbit
import AtlasSpaces
import AtlasStudy
import SwiftUI

/// UI state for the Study Library: courses, the room's study state, and
/// the "here are the classes I found" prompt. The rules live in
/// `StudyService`; this only presents them.
@MainActor
final class StudyModel: ObservableObject {
    /// Classes found and waiting for confirmation.
    struct SetupRequest: Identifiable {
        let id = UUID()
        var suggestions: [CourseSuggestion]
        /// The first open (everything found) rather than a new class showing up later.
        let isFirstRun: Bool
    }

    let core: AtlasCore?
    let module: StudyModule?
    var service: StudyService? { module?.service }
    /// Told when the room's study state changes, so the 3D view refreshes.
    weak var spaces: SpacesModel?
    /// The Companion as the reader on the window seat (nil: not reading).
    var readerInfo: (() -> StudyRoomState.Reader?)?
    /// The reader was clicked: show what's waiting.
    var onReaderClicked: (() -> Void)?

    @Published private(set) var courses: [Course] = []
    @Published private(set) var roomState = StudyRoomState()
    @Published var setup: SetupRequest?
    /// The end-of-session card's contents.
    @Published private(set) var summary: StudySummary?

    private var subscription: EventBus.Subscription?
    private var panel: NSPanel?
    private var cardPanel: NSPanel?
    private var books: [StudyRoomState.Book] = []
    private var ticker: Timer?
    private var tickInterval: TimeInterval = 0
    private var syncTimer: Timer?
    private var weatherTimer: Timer?
    /// Earned books by term; changes only when a session ends.
    private var shelf: [StudyRoomState.ShelfSection] = []
    private var boardPanel: NSPanel?
    /// Rows checked off in the room, struck through until they're saved.
    private var struck: Set<UUID> = []
    /// Course codes and folders the PDF rules were last made for.
    private var ruleSignature: [String] = []

    init(core: AtlasCore?) {
        self.core = core
        module = core.flatMap { try? StudyModule(core: $0) }
        reload()
        subscription = core?.events.subscribe { [weak self] event in
            guard event.name == AtlasEvent.Name.studyChanged || event.name.hasPrefix("calendar.") || event.name.hasPrefix("study.")
                || event.name == AtlasEvent.Name.spaceActivated else { return }
            Task { @MainActor in self?.handle(event) }
        }
        schedule()
        syncAssignments()
        do {
            try module?.automations.install()
        } catch {
            AtlasLog.persistence.error("Couldn't set up Study Library automations: \(error.localizedDescription, privacy: .public)")
        }
        ruleSignature = courseSignature
        syncTimer = Timer.scheduledTimer(withTimeInterval: 15 * 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.syncAssignments() }
        }
        syncTimer?.tolerance = 60
        refreshWeather()
        weatherTimer = Timer.scheduledTimer(withTimeInterval: WeatherService.refreshInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshWeather() }
        }
        weatherTimer?.tolerance = 120
    }

    /// Fetches the weather when it's due (every 30 min), then redraws the window.
    func refreshWeather(force: Bool = false) {
        guard let module, !module.service.settings.weatherCity.isEmpty else { return }
        Task {
            if await module.refreshWeather(force: force) { refreshLive() }
        }
    }

    /// The window's current text, and the place the city was found as.
    var weatherDetail: String { module?.window().detail ?? "" }
    func weatherPlace(for city: String) -> WeatherPlace? { module?.weather.place(for: city) }

    /// The reader's look or mood changed (Companion settings, held offers).
    func refreshRoom() { refreshLive() }

    var sessions: StudySessions? { module?.sessions }

    /// Whether the Course PDFs rules are on (all of them).
    var coursePDFRulesOn: Bool {
        let rules = (try? core?.store.rules()) ?? []
        let mine = rules.filter { $0.starterID?.hasPrefix("study.coursePDF.") == true }
        return mine.isEmpty || mine.contains(where: \.isEnabled)
    }

    func setCoursePDFRules(_ on: Bool) {
        guard let core else { return }
        let organizer = FileOrganizer(core: core)
        for rule in organizer.rules() where rule.starterID?.hasPrefix("study.coursePDF.") == true {
            try? organizer.setEnabled(on, for: rule)
        }
    }
    var automations: StudyAutomations? { module?.automations }

    private var courseSignature: [String] {
        courses.filter { !$0.isArchived }.map { "\($0.id)|\($0.code)|\($0.aliases)|\($0.folderPath ?? "")" }
    }
    var assignments: AssignmentService? { module?.assignments }

    /// Pulls assignments from the calendar feed and Reminders.
    func syncAssignments() {
        guard let assignments else { return }
        Task { await assignments.sync() }
    }

    var activeCourses: [Course] { courses.filter { !$0.isArchived } }
    var archivedCourses: [Course] { courses.filter(\.isArchived) }
    var isCalendarConnected: Bool { core?.time?.calendar.settings.enabled ?? false }

    func reload() {
        guard let service else { return }
        courses = service.courses(includingArchived: true)
        books = module?.books() ?? service.roomState().books
        shelf = module?.shelf() ?? []
        // Course PDFs rules follow course codes and folders.
        if courseSignature != ruleSignature {
            ruleSignature = courseSignature
            try? module?.automations.syncCourseRules()
        }
        refreshLive()
    }

    /// The hourglass and candle: refreshed every 20 s while studying,
    /// every 2 min otherwise (for the 4 AM rollover), never per frame.
    private func refreshLive() {
        guard let module else { return }
        let live = module.liveState()
        var board = module.board()
        for index in board.rows.indices where struck.contains(board.rows[index].id) { board.rows[index].isStruck = true }
        let state = StudyRoomState(books: books, hourglass: live.hourglass, candle: live.candle, board: board,
                                   deskCalendar: module.deskCalendar(), window: module.window(), shelf: shelf,
                                   streak: module.streak(), reader: readerInfo?())
        if state != roomState {
            roomState = state
            spaces?.objectWillChange.send()
        }
        schedule()
    }

    private func schedule() {
        let interval: TimeInterval = sessions?.current != nil ? 20 : 120
        guard interval != tickInterval else { return }
        tickInterval = interval
        ticker?.invalidate()
        ticker = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshLive() }
        }
        ticker?.tolerance = interval / 4
    }

    private func handle(_ event: AtlasEvent) {
        switch event.name {
        case AtlasEvent.Name.studySessionEnded:
            NSSound(named: "Glass")?.play()
            summary = sessions?.lastSummary
            showCard()
        case AtlasEvent.Name.studySessionChanged where event.payload["announce"]?.boolValue == true:
            NSSound(named: "Tink")?.play()
        default:
            break
        }
        if event.name == AtlasEvent.Name.spaceActivated,
           let id = event.payload["spaceId"]?.stringValue.flatMap(UUID.init(uuidString:)),
           spaces?.space(id: id)?.templateID == StudyLibrary.templateID {
            enteredStudyLibrary()
            syncAssignments()
        }
        if event.name.hasPrefix("calendar.") { syncAssignments() }
        reload()
    }

    // MARK: - Finding courses

    /// First open: propose what was found. Later: offer any new class.
    func enteredStudyLibrary() {
        guard let service else { return }
        let suggestions = service.suggestions()
        if !service.hasFinishedSetup {
            present(SetupRequest(suggestions: suggestions, isFirstRun: true))
        } else if !suggestions.isEmpty {
            present(SetupRequest(suggestions: suggestions, isFirstRun: false))
        }
    }

    /// "Find Courses…" from settings, optionally also scanning a folder.
    func findCourses(scanning folder: String? = nil) {
        guard let service else { return }
        present(SetupRequest(suggestions: service.suggestions(extraFolders: folder.map { [$0] } ?? []), isFirstRun: true))
    }

    func connectCalendar() async {
        _ = await core?.time?.calendar.enable()
        if var setup, let service {
            setup.suggestions = service.suggestions()
            self.setup = setup
        }
    }

    func add(_ suggestions: [CourseSuggestion]) {
        guard let service else { return }
        do {
            try service.add(suggestions)
        } catch {
            NSSound.beep()
        }
        closeSetup()
    }

    /// "Not a class": never suggested again.
    func ignore(_ suggestion: CourseSuggestion) {
        service?.ignoredCodes.insert(suggestion.code.canonical)
        setup?.suggestions.removeAll { $0.id == suggestion.id }
        if setup?.suggestions.isEmpty == true, setup?.isFirstRun == false { closeSetup() }
    }

    func skipSetup() {
        service?.hasFinishedSetup = true
        closeSetup()
    }

    func closeSetup() {
        setup = nil
        panel?.orderOut(nil)
        reload()
    }

    private func present(_ request: SetupRequest) {
        setup = request
        panel?.orderOut(nil)
        let panel = FloatingPanel.make(title: "", content: CourseSetupView().environmentObject(self))
        self.panel = panel
        panel.center()
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    // MARK: - Courses

    // MARK: - Assignments

    /// A chalk row checked off in the room: struck through at once, saved
    /// (and its reminder completed) a moment later.
    func checkOff(_ id: UUID) {
        guard !struck.contains(id) else { return }
        struck.insert(id)
        refreshLive()
        Task {
            try? await Task.sleep(for: .milliseconds(1200))
            setDone(true, id)
            struck.remove(id)
            reload()
        }
    }

    func setDone(_ done: Bool, _ id: UUID) {
        do {
            try assignments?.setDone(done, assignmentID: id)
        } catch {
            core?.events.publish(AtlasEvent(AtlasEvent.Name.lockdownNotice, payload: [
                "message": .string("Couldn't update Reminders: \(error.localizedDescription)"),
            ]))
        }
    }

    /// The chalkboard and desk calendar in the Study Library.
    func objectClicked(_ object: SpaceObject) -> Bool {
        switch object.kind {
        case .chalkboard:
            showBoard()
            return true
        case .clock:
            openDeskCalendar()
            return true
        default:
            return false
        }
    }

    func showBoard() {
        boardPanel?.orderOut(nil)
        let panel = FloatingPanel.make(title: "Assignments", content: AssignmentsPanel().environmentObject(self))
        boardPanel = panel
        panel.center()
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    func closeBoard() {
        boardPanel?.orderOut(nil)
    }

    /// Calendar, on the day of the next deadline (or today).
    func openDeskCalendar() {
        guard let core else { return }
        let date = module?.deskCalendar().date ?? Date()
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate]
        Task {
            _ = await core.engine.invoke(OpenCalendarDayAction.id, parameters: ["date": .string(formatter.string(from: date))],
                                         source: "study.calendar")
        }
    }

    var calendars: [CalendarInfo] { core?.time?.calendar.calendars() ?? [] }

    /// The Study Library Space, if there is one.
    var studySpaceID: UUID? { spaces?.spaces.first { $0.templateID == StudyLibrary.templateID }?.id }

    /// Asks for Reminders access (only when a list is being chosen).
    func requestRemindersAccess() async -> Bool {
        guard let assignments else { return false }
        return await assignments.reminders.requestAccess() == .granted
    }

    var remindersAccess: CalendarAccess { assignments?.reminders.access() ?? .denied }
    var reminderLists: [ReminderList] { assignments?.reminders.lists() ?? [] }

    // MARK: - Hourglass and candle

    /// The hourglass: click starts a session (or pauses / resumes it);
    /// `options` (long-press, right-click) shows lengths and controls.
    /// The candle shows the stats.
    func itemClicked(_ item: StudyRoomState.Item, options: Bool) {
        switch item {
        case .hourglass:
            if options {
                showCard(HourglassOptionsView())
            } else if let sessions, sessions.current != nil {
                sessions.isPaused ? sessions.resume() : sessions.pause()
            } else {
                startSession()
            }
        case .candle:
            showCard(StudyStatsView())
        case .boardRow(let id):
            checkOff(id)
        case .shelf, .stars:
            showCard(StudyStatsView())
        case .window:
            showCard(WeatherCard())
        case .reader:
            onReaderClicked?()
        }
        refreshLive()
    }

    func startSession(minutes: Double? = nil, pomodoro: Bool? = nil) {
        do {
            try sessions?.start(minutes: minutes, pomodoro: pomodoro)
            closeCard()
        } catch {
            core?.events.publish(AtlasEvent(AtlasEvent.Name.lockdownNotice, payload: ["message": .string(error.localizedDescription)]))
        }
        refreshLive()
    }

    func endSession() {
        sessions?.end(early: true)
    }

    /// "Change": the session was about another course.
    func setSummaryCourse(_ courseID: UUID?) {
        guard let summary else { return }
        try? sessions?.setCourse(courseID, forSession: summary.sessionID)
        self.summary = sessions?.lastSummary
    }

    var settings: StudySettings {
        get { service?.settings ?? StudySettings() }
        set { service?.settings = newValue }
    }

    private func showCard(_ content: some View = StudySummaryCard()) {
        cardPanel?.orderOut(nil)
        let panel = FloatingPanel.make(title: "", content: content.environmentObject(self))
        cardPanel = panel
        // On the display you clicked on (the mouse's), top right.
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        if let frame = screen?.visibleFrame {
            panel.setFrameTopLeftPoint(NSPoint(x: frame.maxX - panel.frame.width - 24, y: frame.maxY - 24))
        }
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    func closeCard() {
        cardPanel?.orderOut(nil)
    }

    func open(courseID: UUID) {
        guard let core else { return }
        Task { _ = await core.engine.invoke(OpenCourseAction.id, parameters: ["course": .string(courseID.uuidString)], source: "study.book") }
    }

    func save(_ course: Course) {
        _ = try? service?.save(course)
    }

    func setArchived(_ archived: Bool, _ course: Course) {
        try? service?.setArchived(archived, courseID: course.id)
    }

    func move(from source: IndexSet, to destination: Int) {
        var ids = activeCourses.map(\.id)
        ids.move(fromOffsets: source, toOffset: destination)
        try? service?.reorder(ids)
    }

    func delete(_ course: Course) {
        try? service?.delete(courseID: course.id)
    }

    var notesRemark: String {
        get { service?.settings.notesRemark ?? "" }
        set { service?.settings.notesRemark = newValue.isEmpty ? nil : newValue }
    }
}

/// A small floating window that sizes itself to its SwiftUI content.
enum FloatingPanel {
    @MainActor
    static func make(title: String, content: some View) -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                            styleMask: [.titled, .closable, .utilityWindow], backing: .buffered, defer: false)
        panel.title = title
        panel.titlebarAppearsTransparent = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        let host = NSHostingView(rootView: content)
        host.sizingOptions = [.intrinsicContentSize]
        panel.contentView = host
        panel.setContentSize(host.fittingSize)
        return panel
    }
}
