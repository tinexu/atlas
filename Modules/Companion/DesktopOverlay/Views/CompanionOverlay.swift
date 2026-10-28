import AppKit
import AtlasCompanion
import Combine
import SwiftUI

/// A transparent, borderless panel that never takes focus or activates ATLAS.
final class OverlayPanel: NSPanel {
    var acceptsKey = false
    override var canBecomeKey: Bool { acceptsKey }
    override var canBecomeMain: Bool { false }

    init(size: CGSize, acceptsKey: Bool = false) {
        self.acceptsKey = acceptsKey
        super.init(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isFloatingPanel = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        // On every macOS Space and over full-screen apps; not in ⌘` cycling.
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
    }
}

/// The character on the desktop and its speech bubble.
@MainActor
final class CompanionOverlay {
    private weak var controller: CompanionController?
    private var panel: OverlayPanel?
    private var bubblePanel: OverlayPanel?
    private var cancellables: Set<AnyCancellable> = []
    private var screenObserver: NSObjectProtocol?
    private var dragStart: (mouse: CGPoint, origin: CGPoint)?

    init(controller: CompanionController) {
        self.controller = controller
        controller.$bubble
            .receive(on: DispatchQueue.main)
            .sink { [weak self] bubble in self?.updateBubble(bubble) }
            .store(in: &cancellables)
        // Displays changed (the same moment Stage 03 publishes display.changed):
        // snap back on-screen, at this arrangement's remembered spot.
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                                                object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reposition() }
        }
    }

    var characterFrame: CGRect { panel?.isVisible == true ? panel!.frame : .zero }

    func apply(_ settings: CompanionSettings) {
        guard let controller else { return }
        guard settings.overlayMode != .hidden else {
            panel?.orderOut(nil)
            bubblePanel?.orderOut(nil)
            return
        }
        let side = settings.size.points
        let size = CGSize(width: side, height: side)
        if panel == nil {
            let panel = OverlayPanel(size: size)
            panel.contentView = NSHostingView(rootView: CompanionOverlayView(controller: controller, overlay: self))
            self.panel = panel
        }
        guard let panel else { return }
        panel.level = settings.overlayMode == .onTop ? .floating : .normal
        if panel.frame.size != size {
            panel.setContentSize(size)
        }
        reposition()
        panel.orderFrontRegardless()
        updateMouseHandling()
    }

    func updateMouseHandling() {
        guard let controller, let panel else { return }
        panel.ignoresMouseEvents = controller.settings.clickThrough && !controller.isInteractive
    }

    // MARK: - Position

    static func screens() -> [OverlayGeometry.Screen] {
        NSScreen.screens.map { OverlayGeometry.Screen(frame: $0.frame, visibleFrame: $0.visibleFrame, isMain: $0 == NSScreen.screens.first) }
    }

    func reposition() {
        guard let controller, let panel else { return }
        let saved = controller.settings.positions.mapValues { CGPoint(x: $0.x, y: $0.y) }
        let origin = OverlayGeometry.restore(saved: saved, size: panel.frame.size, screens: Self.screens())
        panel.setFrameOrigin(origin)
        updateBubble(controller.bubble)
    }

    func dragChanged() {
        guard let panel else { return }
        let mouse = NSEvent.mouseLocation
        if dragStart == nil { dragStart = (mouse, panel.frame.origin) }
        guard let start = dragStart else { return }
        panel.setFrameOrigin(CGPoint(x: start.origin.x + mouse.x - start.mouse.x, y: start.origin.y + mouse.y - start.mouse.y))
        if let bubble = controller?.bubble { updateBubble(bubble) }
    }

    /// Returns true when it was a drag, false for a click.
    func dragEnded() -> Bool {
        defer { dragStart = nil }
        guard let panel, let controller, let start = dragStart else { return false }
        let moved = hypot(panel.frame.origin.x - start.origin.x, panel.frame.origin.y - start.origin.y)
        guard moved > 3 else {
            panel.setFrameOrigin(start.origin)
            return false
        }
        let screens = Self.screens()
        let origin = OverlayGeometry.clamp(origin: panel.frame.origin, size: panel.frame.size, screens: screens)
        panel.setFrameOrigin(origin)
        controller.savePosition(origin, arrangement: OverlayGeometry.arrangementKey(screens))
        return true
    }

    // MARK: - Quick controls

    func showMenu() {
        guard let controller, let panel else { return }
        let menu = QuickMenu(controller: controller).build()
        let point = CGPoint(x: panel.frame.width / 2, y: panel.frame.height * 0.2)
        menu.popUp(positioning: nil, at: point, in: panel.contentView)
    }

    // MARK: - Bubble

    private func updateBubble(_ bubble: StatusBubble?) {
        guard let controller, let bubble, let panel, panel.isVisible else {
            bubblePanel?.orderOut(nil)
            return
        }
        if bubblePanel == nil {
            let bubblePanel = OverlayPanel(size: CGSize(width: 280, height: 90))
            bubblePanel.level = .floating
            bubblePanel.contentView = NSHostingView(rootView: BubbleView(controller: controller))
            self.bubblePanel = bubblePanel
        }
        guard let bubblePanel, let content = bubblePanel.contentView else { return }
        let fitting = content.fittingSize
        let size = CGSize(width: min(max(fitting.width, 160), 300), height: max(fitting.height, 40))
        bubblePanel.setContentSize(size)
        bubblePanel.setFrameOrigin(OverlayGeometry.bubbleOrigin(character: panel.frame, bubble: size, screens: Self.screens()))
        bubblePanel.level = panel.level
        bubblePanel.orderFrontRegardless()
        _ = bubble
    }
}

/// The character, with click (quick controls) and drag (move) handling.
struct CompanionOverlayView: View {
    @ObservedObject var controller: CompanionController
    let overlay: CompanionOverlay

    var body: some View {
        CharacterView(settings: controller.settings, presentation: controller.presentation, paused: controller.isRenderingPaused,
                      live: controller.isAnimating)
            .overlay {
                // Gestures on a clear layer so the 3D view never swallows them.
                Color.clear
                    .contentShape(Circle().inset(by: 6))
                    .gesture(
                        DragGesture(minimumDistance: 0, coordinateSpace: .global)
                            .onChanged { _ in overlay.dragChanged() }
                            .onEnded { _ in if !overlay.dragEnded() { overlay.showMenu() } }
                    )
                    .contextMenu { QuickMenuSwiftUI(controller: controller) }
            }
            .overlay(alignment: .bottom) {
                VStack(spacing: 2) {
                    if let session = controller.focusSession {
                        Group {
                            if session.state == .running {
                                Text(timerInterval: Date()...session.endsAt(from: Date()), countsDown: true)
                            } else {
                                Text("Paused")
                            }
                        }
                        .font(.caption2.monospacedDigit().weight(.semibold))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(.regularMaterial, in: Capsule())
                    }
                    // Lockdown's total time left, under the pomodoro countdown.
                    if let ends = controller.lockdownEndsAt {
                        HStack(spacing: 2) {
                            Image(systemName: "lock.fill")
                            Text(timerInterval: Date()...max(Date(), ends), countsDown: true)
                        }
                        .font(.caption2.monospacedDigit())
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(.regularMaterial, in: Capsule())
                    }
                }
                .allowsHitTesting(false)
            }
            .help("\(controller.state.title). Click for quick controls; drag to move.")
            .accessibilityElement()
            .accessibilityLabel("ATLAS Companion, \(controller.state.title)")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { overlay.showMenu() }
    }
}

/// Right-click shows the same quick controls as a click.
struct QuickMenuSwiftUI: View {
    let controller: CompanionController
    var body: some View {
        Button("Command Palette…") { controller.showPalette() }
        Button("Companion Settings…") { controller.host.openSection("companion") }
        Button("Hide Companion") { controller.setVisible(false) }
    }
}

/// The speech bubble: latest result or a suggestion. Click for details.
struct BubbleView: View {
    @ObservedObject var controller: CompanionController
    @State private var showWhy = false

    var body: some View {
        if let bubble = controller.bubble {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: bubble.isFailure ? "exclamationmark.triangle.fill" : bubble.suggestion != nil || bubble.recommendation != nil ? "lightbulb.fill" : "checkmark.circle.fill")
                        .foregroundStyle(bubble.isFailure ? .orange : bubble.suggestion != nil || bubble.recommendation != nil ? .yellow : .green)
                    Text(bubble.text).font(.callout.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button { controller.dismissBubble() } label: { Image(systemName: "xmark").font(.caption2) }
                        .buttonStyle(.borderless)
                        .help("Dismiss")
                }
                if let detail = bubble.detail, !detail.isEmpty {
                    Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                if let recommendation = bubble.recommendation {
                    if showWhy {
                        Text(recommendation.reason).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    HStack(spacing: 8) {
                        Button(recommendation.action.title) { controller.accept(recommendation) }
                            .controlSize(.small).buttonStyle(.borderedProminent)
                        Button("Not Now") { controller.dismiss(recommendation, forever: false) }.controlSize(.small)
                        Menu("More") {
                            Button("Why am I seeing this?") { showWhy.toggle() }
                            Button("Don't suggest this") { controller.dismiss(recommendation, forever: true) }
                        }
                        .menuStyle(.borderlessButton).controlSize(.small).fixedSize()
                    }
                }
                HStack(spacing: 8) {
                    if bubble.recommendation == nil, let fixTitle = bubble.fixTitle, let fix = bubble.fix {
                        Button(fixTitle) {
                            if let suggestion = bubble.suggestion { controller.accept(suggestion) } else { controller.perform(fix); controller.dismissBubble() }
                        }
                        .controlSize(.small)
                        .buttonStyle(.borderedProminent)
                    }
                    if let suggestion = bubble.suggestion {
                        Button("Not Now") { controller.dismiss(suggestion, forever: false) }.controlSize(.small)
                        Button("Don't Suggest This") { controller.dismiss(suggestion, forever: true) }
                            .controlSize(.small).buttonStyle(.borderless)
                    } else if bubble.runID != nil {
                        Button("Details") { controller.openBubble() }.controlSize(.small).buttonStyle(.borderless)
                    }
                }
            }
            .padding(10)
            .frame(width: 280, alignment: .leading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator))
            .contentShape(RoundedRectangle(cornerRadius: 12))
            .onTapGesture { if bubble.recommendation == nil { controller.openBubble() } }
            .onChange(of: bubble.id) { _, _ in showWhy = false }
            .padding(4)
        }
    }
}
