import AtlasCore
import AppKit
import SwiftUI

/// Reports whether the hosting window is actually on screen. macOS marks a
/// window occluded when it's minimized, fully covered, on another desktop
/// or the app is hidden, which is exactly when rendering should stop.
struct WindowVisibilityReader: NSViewRepresentable {
    @Binding var isVisible: Bool

    func makeNSView(context: Context) -> ObservingView {
        let view = ObservingView()
        view.onChange = { visible in
            if isVisible != visible { isVisible = visible }
        }
        return view
    }

    func updateNSView(_ nsView: ObservingView, context: Context) {
        nsView.onChange = { visible in
            if isVisible != visible { isVisible = visible }
        }
    }

    final class ObservingView: NSView {
        var onChange: ((Bool) -> Void)?
        private var observer: NSObjectProtocol?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
            guard let window else { return }
            observer = NotificationCenter.default.addObserver(
                forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.report() }
            }
            report()
        }

        /// Low Power Mode and switching apps change whether 3D draws.
        private lazy var powerObserver: [NSObjectProtocol] = [
            NSNotification.Name.NSProcessInfoPowerStateDidChange, NSApplication.didBecomeActiveNotification,
            NSApplication.didResignActiveNotification,
        ].map { name in
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.report() }
            }
        }

        private func report() {
            _ = powerObserver
            // A RealityKit view redraws every frame, so 3D only draws while
            // it's on screen, ATLAS is the app in front, and Low Power Mode is off.
            let visible = RenderPolicy.shouldDraw(windowVisible: window?.occlusionState.contains(.visible) ?? false,
                                                  appActive: NSApp.isActive, lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled)
            // Defer: this can fire during a SwiftUI update.
            DispatchQueue.main.async { [onChange] in onChange?(visible) }
        }

        deinit {
            if let observer { NotificationCenter.default.removeObserver(observer) }
            powerObserver.forEach(NotificationCenter.default.removeObserver)
        }
    }
}
