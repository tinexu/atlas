import AppKit
import AtlasCompanionUI
import AtlasCore
import SwiftUI

/// Menu-bar utility (spec 9.4): run automations and pause everything
/// without opening the main window.
struct MenuBarContent: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var spaces: SpacesModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if !spaces.spaces.isEmpty {
            Section("Spaces") {
                ForEach(spaces.spaces) { space in
                    // A toggle renders as a checkmark item in a menu.
                    Toggle(space.name, isOn: Binding(
                        get: { spaces.activeSpaceID == space.id },
                        set: { _ in spaces.activate(space.id) }
                    ))
                    .disabled(model.isPaused)
                }
            }
            Divider()
        }

        if model.creative.isWatching, let project = model.creative.currentProject {
            Button("Save Video to \(project.name)") { model.creative.saveTutorial() }
            Divider()
        }

        LockdownMenuItems(lockdown: model.lockdown)

        if let focus = model.core?.time?.focus {
            Section("Focus") {
                if let session = model.focusSession {
                    Text("\(session.title): \(Int(session.remaining(at: Date()) / 60)) min left")
                    if session.state == .running {
                        Button("Pause Focus") { focus.pause() }
                    } else {
                        Button("Resume Focus") { focus.resume() }
                    }
                    Button("Add 10 Minutes") { focus.extend(minutes: 10) }
                    Button("Stop Focus") { focus.stop() }
                } else {
                    Menu("Start Focus") {
                        ForEach([25, 50, 90], id: \.self) { minutes in
                            Button("\(minutes) minutes") { focus.start(minutes: Double(minutes)) }
                        }
                    }
                }
            }
            Divider()
        }

        if model.workflows.isEmpty {
            Text("No automations yet")
        } else {
            Section("Run") {
                ForEach(model.workflows) { workflow in
                    if model.isRunning(workflow.id) {
                        Button("Stop \(workflow.name)") { model.cancelRun(for: workflow.id) }
                    } else {
                        Button(workflow.name) { model.run(workflow, trigger: "menu-bar") }
                            .disabled(model.isPaused || workflow.steps.isEmpty || workflow.hasTriggers && workflow.steps.count == 1)
                    }
                }
            }
        }

        Divider()

        Toggle("Pause Automations", isOn: Binding(
            get: { model.isPaused },
            set: { model.setPaused($0) }
        ))
        if let triggers = model.core?.triggers, !model.isPaused {
            Text(triggers.activeTriggerCount == 1 ? "1 trigger listening" : "\(triggers.activeTriggerCount) triggers listening")
        }
        if let companion = model.companion {
            CompanionMenuItems(companion: companion)
        }
        Toggle("Start ATLAS at Login", isOn: Binding(
            get: { model.launchesAtLogin },
            set: { model.setLaunchesAtLogin($0) }
        ))

        Divider()

        Button("Open ATLAS") {
            model.openMainWindow = { openWindow(id: "main") }
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
        .keyboardShortcut("o")

        Button("Quit ATLAS") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}

/// "Show/Hide Companion" and the command palette, for the menu bar and the
/// app's View menu.
struct CompanionMenuItems: View {
    @ObservedObject var companion: CompanionController

    var body: some View {
        Button(companion.isVisible ? "Hide Companion" : "Show Companion") { companion.setVisible(!companion.isVisible) }
        Button("Command Palette…") { companion.showPalette() }
    }
}
