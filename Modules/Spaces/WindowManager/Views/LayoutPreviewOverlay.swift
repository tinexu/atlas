import AppKit
import AtlasCore
import SwiftUI

/// "Preview": briefly outlines on the real displays where each window will
/// go, without moving anything. Click-through panels that fade out on
/// their own.
@MainActor
final class LayoutPreviewOverlay {
    struct Target {
        /// Accessibility coordinates.
        let frame: CGRect
        let title: String
        let bundleID: String
    }

    private var panels: [NSPanel] = []
    private var dismissal: Task<Void, Never>?

    func show(_ targets: [Target], displays: [DisplayInfo], duration: TimeInterval = 1.8) {
        hide()
        guard let primaryHeight = NSScreen.screens.first?.frame.height else { return }
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        for target in targets {
            let frame = ScreenCoordinates.appKitRect(fromAX: target.frame, primaryHeight: primaryHeight)
            let panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.level = .floating
            panel.ignoresMouseEvents = true
            panel.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle]
            panel.contentView = NSHostingView(rootView: PreviewTile(title: target.title, bundleID: target.bundleID))
            panel.alphaValue = reduceMotion ? 1 : 0
            panel.orderFrontRegardless()
            panels.append(panel)
        }
        if !reduceMotion {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.18
                panels.forEach { $0.animator().alphaValue = 1 }
            }
        }
        dismissal = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.fadeOut(reduceMotion: reduceMotion)
        }
    }

    func hide() {
        dismissal?.cancel()
        panels.forEach { $0.orderOut(nil) }
        panels = []
    }

    private func fadeOut(reduceMotion: Bool) {
        let closing = panels
        panels = []
        guard !reduceMotion else {
            closing.forEach { $0.orderOut(nil) }
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.3
            closing.forEach { $0.animator().alphaValue = 0 }
        } completionHandler: {
            closing.forEach { $0.orderOut(nil) }
        }
    }
}

private struct PreviewTile: View {
    let title: String
    let bundleID: String

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.accentColor.opacity(0.18))
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.accentColor, lineWidth: 4)
            VStack(spacing: 8) {
                if let icon = AppIcons.icon(for: bundleID) {
                    Image(nsImage: icon).resizable().frame(width: 64, height: 64)
                }
                Text(title)
                    .font(.title2.weight(.semibold))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
                    .background(.regularMaterial, in: Capsule())
            }
        }
        .padding(6)
    }
}

/// App names, icons and the app chooser for the window manager's views.
enum AppIcons {
    /// Lets the user pick an app; returns its bundle identifier and name.
    @MainActor
    static func chooseApplication() -> (bundleID: String, name: String)? {
        let panel = NSOpenPanel()
        panel.title = "Choose an App"
        panel.prompt = "Choose"
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        guard panel.runModal() == .OK, let url = panel.url, let id = Bundle(url: url)?.bundleIdentifier else { return nil }
        return (id, url.deletingPathExtension().lastPathComponent)
    }

    static func icon(for bundleID: String) -> NSImage? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        return NSWorkspace.shared.icon(forFile: url.path)
    }

    static func name(for bundleID: String) -> String? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        return url.deletingPathExtension().lastPathComponent
    }
}
