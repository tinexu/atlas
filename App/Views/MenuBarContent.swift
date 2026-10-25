import AppKit
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
        Toggle("Start ATLAS at Login", isOn: Binding(
            get: { model.launchesAtLogin },
            set: { model.setLaunchesAtLogin($0) }
        ))

        Divider()

        Button("Open ATLAS") {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
        .keyboardShortcut("o")

        Button("Quit ATLAS") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}
