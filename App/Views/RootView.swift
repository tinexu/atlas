import AtlasCore
import SwiftUI

struct RootView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        if let error = model.startupError {
            ContentUnavailableView {
                Label("ATLAS couldn't start", systemImage: "exclamationmark.triangle")
            } description: {
                Text(error)
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
                case .automations: AutomationsView()
                case .history: RunHistoryView()
                case .actions: ActionLibraryView()
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
        }
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
