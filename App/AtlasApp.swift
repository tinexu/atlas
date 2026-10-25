import AppKit
import AtlasCore
import SwiftUI

@main
struct AtlasApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup("ATLAS", id: "main") {
            RootView()
                .environmentObject(model)
                .environmentObject(model.spaces)
                .frame(minWidth: 940, minHeight: 600)
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Automation") { model.createWorkflow() }
                    .keyboardShortcut("n")
                    .disabled(model.core == nil)
            }
            CommandMenu("Automations") {
                Button(model.isPaused ? "Resume Automations" : "Pause Automations") {
                    model.setPaused(!model.isPaused)
                }
                .keyboardShortcut("p", modifiers: [.command, .shift])
            }
            SpacesCommands(spaces: model.spaces)
        }

        // Low-resource control surface (spec 9.4): run automations and pause
        // everything without opening the main window.
        MenuBarExtra {
            MenuBarContent()
                .environmentObject(model)
                .environmentObject(model.spaces)
        } label: {
            Image(systemName: model.isPaused ? "pause.circle" : "globe.americas.fill")
        }
    }
}

/// The Spaces menu: Next/Previous Space and ⌘1…⌘9 for the first nine.
/// These work from anywhere in the app, with or without the 3D view.
struct SpacesCommands: Commands {
    @ObservedObject var spaces: SpacesModel

    var body: some Commands {
        CommandMenu("Spaces") {
            Button("Next Space") { spaces.activateNeighbor(1) }
                .keyboardShortcut(.rightArrow, modifiers: [.command, .control])
                .disabled(spaces.spaces.isEmpty)
            Button("Previous Space") { spaces.activateNeighbor(-1) }
                .keyboardShortcut(.leftArrow, modifiers: [.command, .control])
                .disabled(spaces.spaces.isEmpty)
            Divider()
            ForEach(Array(spaces.spaces.prefix(9).enumerated()), id: \.element.id) { index, space in
                Toggle(space.name, isOn: Binding(
                    get: { spaces.activeSpaceID == space.id },
                    set: { _ in
                        spaces.selectedSpaceID = space.id
                        spaces.activateFromShortcut(space.id)
                    }
                ))
                .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: .command)
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Needed when launched with `swift run`, which starts as a
        // background process with no Dock icon or focus.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        ConfirmationNotifications.shared.install()
    }

    /// Closing the window leaves ATLAS running in the menu bar, so
    /// triggers and runs keep working.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
