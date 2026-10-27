import AtlasCompanionUI
import AtlasCore
import AtlasFlow
import AtlasOrbitUI
import AtlasSpacesUI
import SwiftUI

struct RootView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if let error = model.startupError {
            ContentUnavailableView {
                Label("ATLAS couldn't start", systemImage: "exclamationmark.triangle")
            } description: {
                Text(error)
            } actions: {
                if let backup = model.corruptionBackup {
                    Button("Restore Backup from \(backup.date.formatted(date: .abbreviated, time: .shortened))") { model.restoreLatestBackup() }
                        .buttonStyle(.borderedProminent)
                }
                if error.contains("damaged") {
                    Button("Start Fresh") { model.relaunch() }
                        .help("The damaged database stays in the Backups folder")
                }
                Button("Open the Data Folder") { model.openDatabaseFolder() }
            }
        } else {
            NavigationSplitView {
                List(AppModel.Section.allCases, selection: sectionSelection) { section in
                    Label(section.title, systemImage: section.symbol)
                }
                .navigationSplitViewColumnWidth(min: 180, ideal: 200)
                .safeAreaInset(edge: .bottom) { pauseToggle }
            } detail: {
                switch model.section {
                case .today:
                    if let time = model.timeArchitect {
                        TodayView(model: time,
                                  openRun: { model.focusedRunID = $0; model.section = .history },
                                  openReviews: { model.orbit?.tab = .rules; model.section = .orbit },
                                  openTimeline: { model.section = .timeline },
                                  openWorkflow: { model.selectedWorkflowID = $0; model.section = .automations })
                    } else { unavailable("Today") }
                case .timeline:
                    if let time = model.timeArchitect { TimeArchitectView(model: time) } else { unavailable("Time Architect") }
                case .spaces: SpacesView()
                case .windows:
                    WindowManagerView(
                        model: model.windowManager,
                        spaceName: { id in model.spaces.space(id: id)?.name },
                        openPermissions: { model.section = .permissions }
                    )
                case .orbit:
                    if let orbit = model.orbit { OrbitView(model: orbit) } else { unavailable("Orbit") }
                case .health:
                    if let orbit = model.orbit { HealthView(model: orbit) } else { unavailable("Mac Health") }
                case .automations: AutomationsView()
                case .history: RunHistoryView()
                case .actions: ActionLibraryView()
                case .companion:
                    if let companion = model.companion { CompanionSettingsView(controller: companion) } else { unavailable("The Companion") }
                case .permissions: PermissionsView()
                }
            }
            .alert(
                "Allow this step?",
                isPresented: Binding(
                    get: { model.pendingConfirmation != nil },
                    set: { presented in if !presented { model.resolveConfirmation(false) } }
                ),
                presenting: model.pendingConfirmation
            ) { _ in
                Button("Allow") { model.resolveConfirmation(true) }
                Button("Don't Allow", role: .cancel) { model.resolveConfirmation(false) }
            } message: { pending in
                Text("“\(pending.request.workflowName)” wants to \(pending.request.stepLabel).\n\n\(pending.request.descriptor.summary)")
            }
            .alert(
                "Something went wrong",
                isPresented: Binding(
                    get: { model.errorMessage != nil },
                    set: { if !$0 { model.errorMessage = nil } }
                )
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(model.errorMessage ?? "")
            }
            .onReceive(NotificationCenter.default.publisher(for: .orbitOpenHealth)) { _ in model.section = .health }
            .onAppear { model.openMainWindow = { openWindow(id: "main") } }
            .sheet(isPresented: $model.showEventLog) { EventLogView() }
        }
    }

    private func unavailable(_ name: String) -> some View {
        ContentUnavailableView("\(name) isn't available", systemImage: "exclamationmark.triangle",
                               description: Text("It couldn't start. Restart ATLAS to try again."))
    }

    private var sectionSelection: Binding<AppModel.Section?> {
        Binding(get: { model.section }, set: { if let section = $0 { model.section = section } })
    }

    private var pauseToggle: some View {
        Toggle(isOn: Binding(get: { !model.isPaused }, set: { model.setPaused(!$0) })) {
            Label(model.isPaused ? "Automations paused" : "Automations on",
                  systemImage: model.isPaused ? "pause.circle" : "bolt.circle")
                .font(.callout)
        }
        .toggleStyle(.switch)
        .controlSize(.small)
        .padding(12)
    }
}
