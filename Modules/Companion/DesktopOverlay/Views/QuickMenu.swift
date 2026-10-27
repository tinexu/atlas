import AppKit
import AtlasCompanion
import AtlasCore
import AtlasSpaces

/// A menu item that runs a closure.
final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, symbol: String? = nil, checked: Bool = false, enabled: Bool = true, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
        state = checked ? .on : .off
        isEnabled = enabled
        if let symbol { image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError() }

    @objc private func fire() { handler() }
}

/// Click the character → compact quick controls. Every item goes through
/// the same engine path as the rest of ATLAS (trigger "companion"); nothing
/// here needs AI.
@MainActor
struct QuickMenu {
    let controller: CompanionController

    func build() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let vocabulary = controller.vocabulary()
        let parser = DeterministicParser(vocabulary: vocabulary)
        let store = controller.core.store
        let paused = controller.host.isPaused()

        // Status line.
        let activeID = (try? store.activeSpaceID()).flatMap { $0 }
        let activeName = vocabulary.spaces.first { $0.id == activeID }?.name
        let header = NSMenuItem(title: [activeName.map { "\($0) active" }, paused ? "Automations paused" : nil,
                                        vocabulary.runningWorkflows.isEmpty ? nil : "\(vocabulary.runningWorkflows.count) running"]
                                    .compactMap { $0 }.joined(separator: " · ").nilIfEmpty ?? "ATLAS Companion",
                                action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())

        // Spaces, with the active one checked.
        let spaces = NSMenu()
        for space in vocabulary.spaces {
            spaces.addItem(ClosureMenuItem(space.name, checked: space.id == activeID, enabled: !paused) {
                run(parser.spacePlan(space, profile: nil))
            })
        }
        if vocabulary.spaces.isEmpty { spaces.addItem(disabled("No Spaces yet")) }
        menu.addItem(submenu("Spaces", symbol: "cube.transparent", spaces))

        // Workflows: favourites, then recently run.
        let workflows = NSMenu()
        let byID = Dictionary(vocabulary.workflows.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let favorites = controller.settings.favoriteWorkflowIDs.compactMap { byID[$0.uuidString] }
        if !favorites.isEmpty {
            workflows.addItem(sectionHeader("Favourites"))
            favorites.forEach { workflows.addItem(workflowItem($0, parser: parser, paused: paused)) }
        }
        let recentIDs = ((try? store.runs(limit: 60)) ?? [])
            .filter { [RunTrigger.manual, RunTrigger.companion, "menu-bar", "shortcut"].contains($0.trigger) }
            .map(\.workflowID.uuidString)
        var seen = Set(favorites.map(\.id))
        let recent = recentIDs.compactMap { id -> CommandVocabulary.Named? in
            guard seen.insert(id).inserted else { return nil }
            return byID[id]
        }.prefix(5)
        if !recent.isEmpty {
            workflows.addItem(sectionHeader("Recent"))
            recent.forEach { workflows.addItem(workflowItem($0, parser: parser, paused: paused)) }
        }
        let others = vocabulary.workflows.filter { !seen.contains($0.id) }
        if !others.isEmpty {
            let all = NSMenu()
            others.forEach { all.addItem(workflowItem($0, parser: parser, paused: paused)) }
            workflows.addItem(.separator())
            workflows.addItem(submenu("All Workflows", symbol: nil, all))
        }
        if vocabulary.workflows.isEmpty { workflows.addItem(disabled("No workflows yet")) }
        menu.addItem(submenu("Run Workflow", symbol: "bolt.horizontal.circle", workflows))

        // Layouts and snapshots.
        let windows = NSMenu()
        if !vocabulary.layouts.isEmpty {
            windows.addItem(sectionHeader("Layouts"))
            vocabulary.layouts.forEach { layout in
                windows.addItem(ClosureMenuItem(layout.name, enabled: !paused) { run(parser.layoutApplyPlan(layout.name)) })
            }
        }
        if !vocabulary.snapshots.isEmpty {
            windows.addItem(sectionHeader("Snapshots"))
            vocabulary.snapshots.prefix(5).forEach { snapshot in
                windows.addItem(ClosureMenuItem(snapshot.name, enabled: !paused) { run(parser.snapshotRestorePlan(snapshot.name)) })
            }
        }
        windows.addItem(.separator())
        windows.addItem(ClosureMenuItem("Save Snapshot Now", symbol: "square.and.arrow.down.on.square", enabled: !paused) {
            run(parser.snapshotSavePlan(""))
        })
        menu.addItem(submenu("Restore Layout", symbol: "macwindow.on.rectangle", windows))

        // Focus and today (Stage 07).
        if let time = controller.core.time {
            let focus = NSMenu()
            if let session = time.focus.session {
                focus.addItem(disabled("\(session.title): \(Int(session.remaining(at: Date()) / 60)) min left"))
                if session.state == .running {
                    focus.addItem(ClosureMenuItem("Pause") { time.focus.pause() })
                } else {
                    focus.addItem(ClosureMenuItem("Resume") { time.focus.resume() })
                }
                focus.addItem(ClosureMenuItem("Add 10 Minutes") { time.focus.extend(minutes: 10) })
                focus.addItem(ClosureMenuItem("Stop") { time.focus.stop() })
            } else {
                for minutes in [25, 50, 90] {
                    focus.addItem(ClosureMenuItem("\(minutes) Minutes") {
                        run(CommandPlan(kind: .actions([.init(StartFocusAction.id, ["minutes": .number(Double(minutes))])]),
                                        summary: "Start a \(minutes) min focus session", hasSideEffects: true))
                    })
                }
            }
            menu.addItem(submenu("Focus", symbol: "scope", focus))
            let overview = DailyOverview.make(store: store, schedule: time.schedule, events: controller.core.events)
            let today = NSMenu()
            today.addItem(disabled(overview.upcoming.first.map { "Next: \($0.block.title) at \($0.start.formatted(date: .omitted, time: .shortened))" } ?? "Nothing else planned today"))
            today.addItem(disabled("Focus: \(Int(overview.completedFocus / 60)) of \(Int(overview.plannedFocus / 60)) min"))
            if !overview.failures.isEmpty { today.addItem(disabled("\(overview.failures.count) automation\(overview.failures.count == 1 ? "" : "s") need attention")) }
            if overview.reviewCount > 0 { today.addItem(disabled("\(overview.reviewCount) file\(overview.reviewCount == 1 ? "" : "s") to review")) }
            today.addItem(.separator())
            today.addItem(ClosureMenuItem("Open Today") { [controller] in controller.host.openSection("today") })
            today.addItem(ClosureMenuItem("Open Time Architect") { [controller] in controller.host.openSection("timeline") })
            menu.addItem(submenu("Today", symbol: "sun.max", today))
        }

        menu.addItem(ClosureMenuItem("Search Files…", symbol: "magnifyingglass") { [controller] in
            controller.palette.show(near: controller.overlay.characterFrame, text: "find ")
        })
        menu.addItem(ClosureMenuItem("Command Palette…", symbol: "command") { [controller] in controller.summon() })

        // What's running, with Stop.
        let timers = TimerCenter.shared.active
        if !vocabulary.runningWorkflows.isEmpty || !timers.isEmpty {
            menu.addItem(.separator())
            menu.addItem(sectionHeader("Running"))
            for running in vocabulary.runningWorkflows {
                guard let runID = UUID(uuidString: running.id) else { continue }
                menu.addItem(ClosureMenuItem("Stop \(running.name)", symbol: "stop.circle") {
                    run(CommandPlan(kind: .stopRun(runID), summary: "Stop \(running.name)", hasSideEffects: true))
                })
            }
            for timer in timers {
                let ends = timer.endsAt.formatted(date: .omitted, time: .shortened)
                menu.addItem(ClosureMenuItem("Stop “\(timer.name)” timer (ends \(ends))", symbol: "timer") {
                    run(CommandPlan(kind: .actions([.init(StopTimerAction.id, ["name": .string(timer.name)])]),
                                    summary: "Stop the “\(timer.name)” timer", hasSideEffects: true))
                })
            }
        }

        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(paused ? "Resume Automations" : "Pause Automations", symbol: paused ? "play.circle" : "pause.circle") {
            run(parser.pausePlan(!paused))
        })
        menu.addItem(ClosureMenuItem("Open ATLAS", symbol: "globe.americas") { [controller] in controller.host.openSection("") })
        menu.addItem(ClosureMenuItem("Companion Settings…", symbol: "gearshape") { [controller] in controller.host.openSection("companion") })
        menu.addItem(ClosureMenuItem("Hide Companion", symbol: "eye.slash") { [controller] in controller.setVisible(false) })
        return menu
    }

    private func run(_ plan: CommandPlan) {
        let controller = controller
        Task { await controller.runner.start(plan, text: "", source: .click) }
    }

    private func workflowItem(_ workflow: CommandVocabulary.Named, parser: DeterministicParser, paused: Bool) -> NSMenuItem {
        ClosureMenuItem(workflow.name, enabled: !paused) {
            guard let id = UUID(uuidString: workflow.id) else { return }
            run(parser.workflowPlan(id: id, name: workflow.name))
        }
    }

    private func submenu(_ title: String, symbol: String?, _ submenu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        if let symbol { item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
        submenu.autoenablesItems = false
        item.submenu = submenu
        return item
    }

    private func sectionHeader(_ title: String) -> NSMenuItem {
        NSMenuItem.sectionHeader(title: title)
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
