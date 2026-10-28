import AppKit
import AtlasCore
import SwiftUI

/// UI state for lockdown: the "Lock in for how long?" prompt, the pomodoro
/// window, toasts, and the friction before removing time or ending early.
/// The rules live in `LockdownService`; this only presents them.
@MainActor
final class LockdownModel: ObservableObject {
    /// Entering a Space whose profile uses lockdown.
    struct PendingStart: Identifiable {
        let id = UUID()
        let spaceID: UUID
        let spaceName: String
        let profileID: UUID
        let settings: LockdownSettings
    }

    /// Removing time or ending early, waiting for confirmation.
    struct ExitRequest: Identifiable {
        enum Kind: Equatable {
            case end
            case remove(minutes: Double)
            case setEnd(Date)
        }
        let id = UUID()
        let kind: Kind
        let gate: LockdownExitGate
    }

    let core: AtlasCore?
    var service: LockdownService? { core?.time?.lockdown }
    /// Activates a Space once the prompt is answered: Space, profile,
    /// minutes (nil for no lockdown), mode. Set by AppModel.
    var activate: ((UUID, UUID, Double?, UUID?) -> Void)?

    @Published private(set) var session: LockdownSession?
    @Published private(set) var phaseSession: FocusSession?
    /// The last lockdown's summary, shown until the panel is closed.
    @Published private(set) var summary: LockdownSummary?
    @Published var pendingStart: PendingStart?
    @Published var exitRequest: ExitRequest?
    /// The menu-bar countdown ("🔒 1:52"), at minute resolution. A live
    /// per-second timer in a MenuBarExtra label resizes the status item on
    /// every tick, which can loop and freeze the app, so this is plain text
    /// refreshed every few seconds and published only when it changes.
    @Published private(set) var menuBar: (symbol: String, text: String)?
    private var menuBarTimer: Timer?

    private var subscription: EventBus.Subscription?
    private var terminationObserver: NSObjectProtocol?
    private var panel: NSPanel?
    private var startPanel: NSPanel?
    private let toast = ToastPresenter()

    init(core: AtlasCore?) {
        self.core = core
        refresh()
        subscription = core?.events.subscribe { [weak self] event in
            guard event.name.hasPrefix("lockdown.") || event.name.hasPrefix("focus.") else { return }
            Task { @MainActor in self?.handle(event) }
        }
        // The emergency exit: quitting ATLAS always ends lockdown.
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.service?.endBecauseATLASIsQuitting() }
        }
        if session != nil { showPanel() }
        updateMenuBar()
        menuBarTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateMenuBar() }
        }
    }

    private func updateMenuBar() {
        let now = Date()
        func clock(_ seconds: TimeInterval) -> String {
            let minutes = Int((seconds / 60).rounded(.up))
            return minutes >= 60 ? String(format: "%d:%02d", minutes / 60, minutes % 60) : "\(minutes)m"
        }
        var next: (symbol: String, text: String)?
        if let session {
            next = ("lock.fill", clock(session.remaining(at: now)))
        } else if let focus = core?.time?.focus.session, focus.state == .running {
            next = ("scope", clock(focus.remaining(at: now)))
        }
        if next?.symbol != menuBar?.symbol || next?.text != menuBar?.text { menuBar = next }
    }

    var hasHiddenApps: Bool { !(service?.lastSummary?.hiddenAtStart.isEmpty ?? true) }

    private func refresh() {
        session = service?.session
        phaseSession = core?.time?.focus.session
    }

    private func handle(_ event: AtlasEvent) {
        refresh()
        updateMenuBar()
        switch event.name {
        case AtlasEvent.Name.lockdownStarted:
            summary = nil
            showPanel()
        case AtlasEvent.Name.lockdownBlocked:
            if let message = event.payload["toast"]?.stringValue, !message.isEmpty { toast.show(message) }
        case AtlasEvent.Name.lockdownNotice:
            if let message = event.payload["message"]?.stringValue { toast.show(message) }
        case AtlasEvent.Name.lockdownPhase:
            if event.payload["announce"]?.boolValue == true, session?.settings.pomodoro.playsSounds ?? true {
                NSSound(named: "Glass")?.play()
            }
        case AtlasEvent.Name.lockdownEnded:
            exitRequest = nil
            summary = service?.lastSummary
            if event.payload["reason"]?.stringValue != LockdownSummary.Reason.quit.rawValue {
                NSSound(named: "Hero")?.play()
                showPanel()
            }
        default:
            break
        }
    }

    // MARK: - Starting

    /// Asks "Lock in for how long?" before entering the Space.
    func prompt(_ pending: PendingStart) {
        pendingStart = pending
        // A fresh view each time, so the prompt starts from this profile's last choice.
        startPanel?.orderOut(nil)
        let panel = makePanel(title: "", content: LockdownStartView(pending: pending).environmentObject(self))
        startPanel = panel
        panel.center()
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    /// The answer: minutes (nil for "No lockdown") and the mode. Both are
    /// remembered per profile.
    func choose(minutes: Double?, modeID: UUID? = nil) {
        guard let pending = pendingStart else { return }
        var settings = pending.settings
        settings.lastChoiceMinutes = minutes.map { Int($0) } ?? 0
        if let modeID { settings.lastModeID = modeID }
        service?.setSettings(settings, forProfile: pending.profileID)
        pendingStart = nil
        startPanel?.orderOut(nil)
        activate?(pending.spaceID, pending.profileID, minutes, modeID)
    }

    func cancelStart() {
        pendingStart = nil
        startPanel?.orderOut(nil)
    }

    // MARK: - Changing and ending

    func addTime(minutes: Double) {
        service?.addTime(minutes: minutes)
    }

    /// Removing time, ending early or an earlier end time need confirming.
    func request(_ kind: ExitRequest.Kind) {
        guard let session else { return }
        if case .setEnd(let date) = kind, date >= session.endsAt {
            service?.setEnd(date)
            return
        }
        exitRequest = ExitRequest(kind: kind, gate: LockdownExitGate(openedAt: Date(), settings: session.settings))
        showPanel()
    }

    func confirmExit(typed: String) {
        guard let request = exitRequest, request.gate.canConfirm(at: Date(), typed: typed) else { return }
        exitRequest = nil
        switch request.kind {
        case .end: service?.end(early: true)
        case .remove(let minutes): service?.removeTime(minutes: minutes)
        case .setEnd(let date): service?.setEnd(date)
        }
    }

    func cancelExit() {
        exitRequest = nil
    }

    func bringBackApps() {
        guard let service else { return }
        Task {
            await service.bringBackHiddenApps()
            summary = service.lastSummary
        }
    }

    // MARK: - Pomodoro

    func togglePhase() {
        if let phaseSession, phaseSession.state == .running, phaseSession.id == session?.phase.sessionID {
            service?.pausePhase()
        } else {
            service?.resumePhase()
        }
        refresh()
    }

    func skipPhase() {
        service?.skipPhase()
        refresh()
    }

    // MARK: - Windows

    func showPanel() {
        let panel = self.panel ?? makePanel(title: "Lockdown", content: LockdownPanelView().environmentObject(self))
        self.panel = panel
        if !panel.isVisible {
            if let screen = NSScreen.main?.visibleFrame {
                panel.setFrameTopLeftPoint(NSPoint(x: screen.maxX - panel.frame.width - 24, y: screen.maxY - 24))
            }
        }
        panel.orderFrontRegardless()
    }

    func closePanel() {
        summary = nil
        panel?.orderOut(nil)
    }

    private func makePanel(title: String, content: some View) -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 320, height: 300),
                            styleMask: [.titled, .closable, .utilityWindow], backing: .buffered, defer: false)
        panel.title = title
        panel.titlebarAppearsTransparent = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        let host = NSHostingView(rootView: content)
        // The window follows the content's size, so nothing is clipped
        // (it grows when the pomodoro panel shows a confirmation).
        host.sizingOptions = [.intrinsicContentSize]
        panel.contentView = host
        panel.setContentSize(host.fittingSize)
        return panel
    }
}

/// A small calm message at the top of the screen that never takes focus.
@MainActor
final class ToastPresenter {
    private var panel: NSPanel?
    private var hide: Task<Void, Never>?

    func show(_ message: String, seconds: Double = 4) {
        let panel = self.panel ?? {
            let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.level = .statusBar
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = true
            panel.ignoresMouseEvents = true
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
            return panel
        }()
        self.panel = panel
        let host = NSHostingView(rootView: ToastView(message: message))
        panel.contentView = host
        let size = host.fittingSize
        if let screen = NSScreen.main?.visibleFrame {
            panel.setFrame(NSRect(x: screen.midX - size.width / 2, y: screen.maxY - size.height - 12, width: size.width, height: size.height),
                           display: true)
        }
        panel.alphaValue = 1
        panel.orderFrontRegardless()
        hide?.cancel()
        hide = Task { [weak panel] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled, let panel else { return }
            await NSAnimationContext.runAnimationGroup { $0.duration = 0.4; panel.animator().alphaValue = 0 }
            panel.orderOut(nil)
        }
    }
}

private struct ToastView: View {
    let message: String

    var body: some View {
        Label(message, systemImage: "lock.fill")
            .font(.callout.weight(.medium))
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.regularMaterial, in: Capsule())
            .padding(8)
            .fixedSize()
    }
}
