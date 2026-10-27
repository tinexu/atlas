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
            CommandGroup(after: .newItem) {
                Button("Describe an Automation…") { model.describeAutomation() }
                    .keyboardShortcut("n", modifiers: [.command, .option])
                    .disabled(model.core == nil)
                Divider()
                Button("Export Data…") { model.exportData() }
                    .keyboardShortcut("e", modifiers: [.command, .shift])
                    .disabled(model.core == nil)
                Button("Import Data…") { model.importData() }
                    .disabled(model.core == nil)
            }
            GoCommands(model: model)
            CommandMenu("Focus") {
                if let focus = model.core?.time?.focus {
                    if let session = model.focusSession {
                        Button(session.state == .running ? "Pause Focus" : "Resume Focus") {
                            session.state == .running ? focus.pause() : focus.resume()
                        }
                        .keyboardShortcut("p", modifiers: [.command, .control])
                        Button("Add 10 Minutes") { focus.extend(minutes: 10) }
                            .keyboardShortcut("=", modifiers: [.command, .control])
                        Button("Stop Focus") { focus.stop() }
                            .keyboardShortcut(".", modifiers: [.command, .control])
                    } else {
                        Button("Start Focus Session") { focus.start() }
                            .keyboardShortcut("f", modifiers: [.command, .control])
                    }
                }
            }
            if model.showsDebugMenu {
                CommandMenu("Debug") {
                    Button("Open Database Folder") { model.openDatabaseFolder() }
                    Button("Back Up Database Now") { model.backUpNow() }
                    Button("Show Recent Events") { model.showEventLog = true }
                        .keyboardShortcut("e", modifiers: [.command, .option])
                    Button("Copy Logs (Last 2 Hours)") { model.copyLogs() }
                    Divider()
                    Button("Reset Onboarding") { model.resetOnboarding() }
                }
            }
            CommandMenu("Automations") {
                Button(model.isPaused ? "Resume Automations" : "Pause Automations") {
                    model.setPaused(!model.isPaused)
                }
                .keyboardShortcut("p", modifiers: [.command, .shift])
            }
            SpacesCommands(spaces: model.spaces)
            CommandGroup(after: .toolbar) {
                if let companion = model.companion {
                    CompanionMenuItems(companion: companion)
                    Divider()
                }
            }
        }

        // Low-resource control surface (spec 9.4): run automations and pause
        // everything without opening the main window.
        MenuBarExtra {
            MenuBarContent()
                .environmentObject(model)
                .environmentObject(model.spaces)
        } label: {
            // A live focus countdown when a session is running (Stage 07).
            if let session = model.focusSession, session.state == .running {
                Image(systemName: "scope")
                Text(timerInterval: Date()...session.endsAt(from: Date()), countsDown: true)
            } else {
                Image(systemName: model.isPaused ? "pause.circle" : "globe.americas.fill")
            }
        }
    }
}

/// Go: jump to a screen. ⌥⌘1…⌥⌘9 in sidebar order (⌘1…⌘9 activate Spaces).
struct GoCommands: Commands {
    @ObservedObject var model: AppModel

    var body: some Commands {
        CommandMenu("Go") {
            ForEach(Array(AppModel.Section.allCases.prefix(9).enumerated()), id: \.element) { index, section in
                Button(section.title) {
                    model.section = section
                    model.bringForward()
                }
                .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: [.command, .option])
            }
            Divider()
            Button("Companion Settings") { model.section = .companion; model.bringForward() }
            Button("Permissions") { model.section = .permissions; model.bringForward() }
            Divider()
            Button("Command Palette") { model.companion?.showPalette() }
                .keyboardShortcut("k", modifiers: [.command])
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
