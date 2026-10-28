import Foundation

/// Stage 07's services, started together once triggers are running.
public final class TimeServices: Sendable {
    public let schedule: ScheduleService
    public let focus: FocusService
    public let calendar: CalendarService
    public let recommendations: RecommendationEngine
    /// Lockdown focus mode, which runs its pomodoro on `focus`.
    public let lockdown: LockdownService

    init(schedule: ScheduleService, focus: FocusService, calendar: CalendarService, recommendations: RecommendationEngine,
         lockdown: LockdownService) {
        self.schedule = schedule
        self.focus = focus
        self.calendar = calendar
        self.recommendations = recommendations
        self.lockdown = lockdown
    }
}

extension AtlasCore {
    /// Starts Time Architect: the schedule clock, focus sessions, calendar
    /// integration (read-only and off until turned on) and recommendations.
    @discardableResult
    public func startScheduling(environment: TriggerEnvironment, calendarStore: CalendarStore = UnavailableCalendarStore(),
                                calendar: Calendar = .current) -> TimeServices {
        if let time { return time }
        let schedule = ScheduleService(store: store, events: events, environment: environment, registry: registry, calendar: calendar)
        schedule.saveWorkflow = { [weak self] workflow in _ = try self?.save(workflow) }
        schedule.deleteWorkflow = { [weak self] id in try self?.delete(workflowID: id) }
        let focus = FocusService(store: store, events: events, environment: environment, engine: engine)
        focus.schedule = schedule
        let calendarService = CalendarService(calendarStore: calendarStore, store: store, events: events, environment: environment)
        calendarService.schedule = schedule
        schedule.externalBlocks = { [weak calendarService] range in calendarService?.blocks(in: range) ?? [] }
        let recommendations = RecommendationEngine(store: store, events: events, now: { environment.now() })
        recommendations.perform = { [weak self] recommendation in
            await self?.carryOut(recommendation) ?? .failed("ATLAS isn't ready.")
        }
        let lockdown = LockdownService(store: store, events: events, environment: environment, engine: engine, system: system, focus: focus)
        let services = TimeServices(schedule: schedule, focus: focus, calendar: calendarService, recommendations: recommendations,
                                    lockdown: lockdown)
        setTime(services)

        let actions: [any AtlasAction] = [StartFocusAction(focus: focus, store: store), StopFocusAction(focus: focus), ShortcutRunAction(),
                                          DailySummaryAction(core: self)]
        for action in actions where registry.descriptor(for: action.descriptor.id) == nil {
            try? registry.register(action)
        }
        events.subscribe { [weak recommendations] event in recommendations?.handle(event) }
        try? seedMorningSummaryIfNeeded()
        schedule.start()
        // A lockdown from before a crash or relaunch loads first, so a pomodoro
        // phase that ended meanwhile moves on when the focus timer restores.
        lockdown.load()
        focus.restore()
        Task { await lockdown.resume() }
        calendarService.start()
        return services
    }

    /// The built-in morning summary: a normal workflow, off until you turn it on.
    func seedMorningSummaryIfNeeded() throws {
        let key = "onboarding.seededMorningSummary.v1"
        guard try store.preference(key, as: Bool.self) != true else { return }
        let trigger = WorkflowStep.trigger(TriggerCatalog.timeReached, parameters: ["repeat": "daily", "time": "08:30", "ifMissed": "runOnWake"],
                                           at: NodePosition(x: 0, y: 0))
        let summary = WorkflowStep(actionID: DailySummaryAction.id, position: NodePosition(x: 300, y: 0), label: "Today's summary")
        try store.saveWorkflow(Workflow(
            name: "Morning Summary",
            summary: "Each morning, a notification with today's blocks, focus time, automations needing attention and files to review. Turn it on and change the time if you like.",
            isEnabled: false,
            steps: [trigger, summary],
            connections: [WorkflowConnection(fromNode: trigger.id, fromPort: NodePort.controlOut, toNode: summary.id)]
        ))
        try store.setPreference(true, for: key)
    }

    /// Accepted recommendations run through the engine; ones that need a
    /// screen (fixing a workflow) go back to the app.
    func carryOut(_ recommendation: Recommendation) async -> RecommendationOutcome {
        let trigger = "recommendation"
        switch recommendation.action {
        case .activateSpace(let name, let profile, let blockID, let start):
            var parameters: ActionParameters = ["space": .string(name)]
            if let profile { parameters["profile"] = .string(profile) }
            let run = await engine.invoke("space.activate", parameters: parameters, source: trigger)
            if let blockID, let start { time?.schedule.link(runID: run.id, blockID: blockID, start: start) }
            return .ran(run)
        case .saveLayoutAndSwitch(let snapshot, let space):
            var steps = [WorkflowStep(actionID: "window.snapshot.save", parameters: ["name": .string(snapshot)], label: "Save layout")]
            if let space { steps.append(WorkflowStep(actionID: "space.activate", parameters: ["space": .string(space)], label: "Open \(space)")) }
            let workflow = Workflow(name: recommendation.title, summary: "Accepted from a recommendation", failurePolicy: .continueOnFailure, steps: steps)
            return .ran(await engine.run(workflow, trigger: trigger))
        case .setFocusDefault(let spaceID, let minutes):
            guard let focus = time?.focus else { return .failed("Focus sessions aren't available.") }
            var settings = focus.settings
            if let spaceID { settings.defaultMinutesBySpace[spaceID.uuidString] = minutes } else { settings.defaultMinutes = minutes }
            focus.settings = settings
            return .done("Focus sessions\(spaceID == nil ? "" : " here") now default to \(minutes) minutes.")
        case .scheduleWorkflow(let workflowID, let name, let hour, let minute):
            guard let schedule = time?.schedule else { return .failed("Time Architect isn't available.") }
            let calendar = Calendar.current
            let now = time.map { _ in Date() } ?? Date()
            var start = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: now) ?? now
            if start < now { start = calendar.date(byAdding: .day, value: 1, to: start) ?? start }
            let block = ScheduleBlock(title: name, start: start, end: start.addingTimeInterval(15 * 60), kind: .task, workflowID: workflowID,
                                      recurrence: .daily, startBehavior: .activate)
            do {
                try schedule.save(block)
                return .done("“\(name)” is scheduled every day at \(start.formatted(date: .omitted, time: .shortened)) on your timeline.")
            } catch {
                return .failed(error.localizedDescription)
            }
        case .disableOrFix:
            return .needsUI(recommendation.action)
        }
    }
}
