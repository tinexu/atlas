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
        }

        // Low-resource control surface (spec 9.4): run automations and pause
        // everything without opening the main window.
        MenuBarExtra {
            MenuBarContent()
                .environmentObject(model)
        } label: {
            Image(systemName: model.isPaused ? "pause.circle" : "globe.americas.fill")
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Needed when launched with `swift run`, which starts as a
        // background process with no Dock icon or focus.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
}
