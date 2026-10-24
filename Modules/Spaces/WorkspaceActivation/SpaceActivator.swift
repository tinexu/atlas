import AtlasCore
import Foundation

public enum SpaceActivationError: Error, LocalizedError, Equatable {
    case spaceNotFound(String)
    case profileNotFound(String)
    case noProfiles(String)
    case workflowMissing(String)

    public var errorDescription: String? {
        switch self {
        case .spaceNotFound(let reference):
            return "No Space called “\(reference)” exists."
        case .profileNotFound(let reference):
            return "This Space has no profile called “\(reference)”."
        case .noProfiles(let space):
            return "“\(space)” has no activation profile. Add one in the Space editor."
        case .workflowMissing(let profile):
            return "The automation behind “\(profile)” was deleted. Pick another one in the Space editor."
        }
    }
}

/// The outcome of activating a Space.
public struct SpaceActivation: Sendable {
    public let spaceID: UUID
    public let profileID: UUID
    /// The profile workflow's run (trigger `space.activated`).
    public let run: WorkflowRun
    /// Hiding or minimizing the previous Space's apps, if anything needed it.
    public let transitionRun: WorkflowRun?
    /// The snapshot saved of the previous Space's windows on the way out.
    public let leaveSnapshotID: UUID?
    /// Where this Space was left last time, for "Restore where you left off".
    public let restorableSnapshot: SessionSnapshot?

    public var status: SpaceStatus { SpaceStatus(run: run) }
}

/// Prepares the Mac for a Space. Has no UI dependency: everything it does
/// is a workflow run through `AutomationEngine`, so activation works with
/// the 3D world closed and gets the same checks and history as any run.
public actor SpaceActivator {
    private let store: AtlasStore
    private let engine: AutomationEngine
    private let events: EventBus
    private let system: SystemAdapter
    private let windows: WindowService
    /// spaceID → runID for activations in progress.
    private var inFlight: [UUID: UUID] = [:]

    public init(core: AtlasCore) {
        self.store = core.store
        self.engine = core.engine
        self.events = core.events
        self.system = core.system
        self.windows = core.windows
    }

    public var activatingSpaces: [UUID: UUID] { inFlight }

    /// Activates a Space by ID or name (as typed in a shortcut), and a
    /// profile by ID or name. A nil or empty profile means the default.
    public func activate(reference: String, profile profileReference: String? = nil) async throws -> SpaceActivation {
        let spaces = try store.spaces().worldOrdered
        guard let space = Self.find(reference, in: spaces, id: \.id, name: \.name) else {
            throw SpaceActivationError.spaceNotFound(reference)
        }
        var profileID: UUID?
        if let profileReference, !profileReference.trimmingCharacters(in: .whitespaces).isEmpty {
            guard let profile = Self.find(profileReference, in: try store.profiles(spaceID: space.id), id: \.id, name: \.name) else {
                throw SpaceActivationError.profileNotFound(profileReference)
            }
            profileID = profile.id
        }
        return try await activate(spaceID: space.id, profileID: profileID)
    }

    /// Runs the profile's workflow (trigger `space.activated`) with the
    /// profile's window layout as its last step, applies the Space's
    /// transition behaviour to the previous Space's apps, records the active
    /// Space and publishes `space.activating`, `space.deactivated` (for the
    /// previous Space) and `space.activated`, in that order.
    ///
    /// When switching away from a Space that keeps snapshots, its windows
    /// are recorded first, so coming back can restore them.
    ///
    /// Returns once both runs have finished. The activation run starts as
    /// soon as possible, so callers can animate in parallel without delaying it.
    public func activate(spaceID: UUID, profileID: UUID? = nil) async throws -> SpaceActivation {
        guard let space = try store.space(id: spaceID) else {
            throw SpaceActivationError.spaceNotFound(spaceID.uuidString)
        }
        let profile = try chooseProfile(for: space, requested: profileID)
        guard var workflow = try store.workflow(id: profile.workflowID) else {
            throw SpaceActivationError.workflowMissing(profile.name)
        }
        let layout = try profile.windowLayoutID.flatMap { try store.windowLayout(id: $0) }
        if let layout {
            // Last, so the workflow's apps are open by the time windows move.
            workflow.steps.append(WorkflowStep(
                actionID: ApplyWindowLayoutAction.id,
                parameters: ["layout": .string(layout.id.uuidString)],
                label: "Arrange windows: \(layout.name)"
            ))
        }
        let previousSpaceID = try store.activeSpaceID()
        let previousProfileID = try store.activeProfileID()
        let restorable = try store.snapshots(spaceID: space.id, limit: 10).first(where: \.isAutomatic)

        // Record where the previous Space's windows were before anything moves.
        var leaveSnapshotID: UUID?
        if let previousSpaceID, previousSpaceID != space.id,
           let previous = try store.space(id: previousSpaceID), previous.snapshotOnLeave {
            leaveSnapshotID = await saveLeaveSnapshot(of: previous)
        }

        let runID = await engine.start(workflow, trigger: SpaceTrigger.activated)
        inFlight[space.id] = runID
        var payload: ActionParameters = [
            "spaceId": .string(space.id.uuidString),
            "spaceName": .string(space.name),
            "profileId": .string(profile.id.uuidString),
            "runId": .string(runID.uuidString),
        ]
        if let layout { payload["layoutId"] = .string(layout.id.uuidString) }
        events.publish(AtlasEvent(AtlasEvent.Name.spaceActivating, payload: payload))
        record { try store.setActiveSpace(space.id, profileID: profile.id) }
        record { try store.setLastActivationRunID(runID, spaceID: space.id) }

        var transitionRunID: UUID?
        if let previousSpaceID, previousSpaceID != space.id {
            var deactivated: ActionParameters = [
                "spaceId": .string(previousSpaceID.uuidString),
                "nextSpaceId": .string(space.id.uuidString),
            ]
            if let leaveSnapshotID { deactivated["snapshotId"] = .string(leaveSnapshotID.uuidString) }
            events.publish(AtlasEvent(AtlasEvent.Name.spaceDeactivated, payload: deactivated))
            if let transition = try transitionWorkflow(
                into: space, keeping: SpaceApps.bundleIDs(in: workflow, layout: layout),
                previousSpaceID: previousSpaceID, previousProfileID: previousProfileID
            ) {
                transitionRunID = await engine.start(transition, trigger: SpaceTrigger.transition)
            }
        }

        let run = await engine.result(of: runID)
            ?? WorkflowRun(id: runID, workflowID: workflow.id, workflowName: workflow.name,
                           trigger: SpaceTrigger.activated, state: .failed, error: "The run's record was lost.")
        var transitionRun: WorkflowRun?
        if let transitionRunID {
            transitionRun = await engine.result(of: transitionRunID)
        }
        if inFlight[space.id] == runID { inFlight[space.id] = nil }

        payload["state"] = .string(run.state.rawValue)
        if let transitionRunID { payload["transitionRunId"] = .string(transitionRunID.uuidString) }
        if let restorable, previousSpaceID != space.id { payload["restorableSnapshotId"] = .string(restorable.id.uuidString) }
        events.publish(AtlasEvent(AtlasEvent.Name.spaceActivated, payload: payload))

        return SpaceActivation(
            spaceID: space.id, profileID: profile.id, run: run, transitionRun: transitionRun,
            leaveSnapshotID: leaveSnapshotID,
            restorableSnapshot: previousSpaceID == space.id ? nil : restorable
        )
    }

    /// Restores where a Space was left, through the engine so it's in history.
    public func restoreWhereLeftOff(snapshotID: UUID) async -> WorkflowRun {
        await engine.invoke(RestoreSnapshotAction.id, parameters: ["snapshot": .string(snapshotID.uuidString)],
                            source: SpaceTrigger.restore)
    }

    /// Never blocks a switch: without Accessibility, or if it fails, the
    /// snapshot is skipped. Each Accessibility call is time-limited by
    /// `WindowService`, so an unresponsive app can't hold this up for long.
    private func saveLeaveSnapshot(of space: Space) async -> UUID? {
        guard windows.adapter.isTrusted else { return nil }
        do {
            return try await windows.saveSnapshot(name: "Where you left \(space.name)", spaceID: space.id, automatic: true).id
        } catch {
            AtlasLog.persistence.error("Couldn't snapshot \(space.name, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    // MARK: - Helpers

    private func chooseProfile(for space: Space, requested: UUID?) throws -> ActivationProfile {
        let profiles = try store.profiles(spaceID: space.id)
        if let requested {
            guard let match = profiles.first(where: { $0.id == requested }) else {
                throw SpaceActivationError.profileNotFound(requested.uuidString)
            }
            return match
        }
        guard let profile = profiles.first(where: \.isDefault) ?? profiles.first else {
            throw SpaceActivationError.noProfiles(space.name)
        }
        return profile
    }

    /// Hide or minimize steps for the previous Space's apps that are running
    /// and that the new Space doesn't use. Never quits anything. Nil when
    /// there's nothing to do.
    private func transitionWorkflow(
        into space: Space,
        keeping incomingApps: [String],
        previousSpaceID: UUID,
        previousProfileID: UUID?
    ) throws -> Workflow? {
        let actionID: ActionID
        switch space.transitionBehavior {
        case .leaveRunning: return nil
        case .hidePrevious: actionID = HideApplicationAction.id
        case .minimizePrevious: actionID = MinimizeApplicationAction.id
        }

        let previousProfiles = try store.profiles(spaceID: previousSpaceID)
        guard let previousProfile = previousProfiles.first(where: { $0.id == previousProfileID })
            ?? previousProfiles.first(where: \.isDefault)
            ?? previousProfiles.first,
            let previousWorkflow = try store.workflow(id: previousProfile.workflowID)
        else { return nil }

        let keep = Set(incomingApps).union([Bundle.main.bundleIdentifier].compactMap { $0 })
        let running = Set(system.runningApplications().map(\.bundleID))
        let previousLayout = try previousProfile.windowLayoutID.flatMap { try store.windowLayout(id: $0) }
        let toHide = SpaceApps.bundleIDs(in: previousWorkflow, layout: previousLayout)
            .filter { !keep.contains($0) && running.contains($0) }
        guard !toHide.isEmpty else { return nil }

        let previousName = try store.space(id: previousSpaceID)?.name ?? "previous Space"
        return Workflow(
            name: "Leave \(previousName)",
            summary: "Tidies away \(previousName)'s apps for \(space.name).",
            failurePolicy: .continueOnFailure,
            steps: toHide.map { WorkflowStep(actionID: actionID, parameters: ["bundleId": .string($0)]) }
        )
    }

    /// Bookkeeping must never stop an activation that is already under way.
    private func record(_ body: () throws -> Void) {
        do {
            try body()
        } catch {
            AtlasLog.persistence.error("Couldn't record Space state: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Matches a UUID string exactly, otherwise a name case-insensitively.
    static func find<T>(_ reference: String, in items: [T], id: KeyPath<T, UUID>, name: KeyPath<T, String>) -> T? {
        let trimmed = reference.trimmingCharacters(in: .whitespacesAndNewlines)
        if let uuid = UUID(uuidString: trimmed), let match = items.first(where: { $0[keyPath: id] == uuid }) {
            return match
        }
        return items.first { $0[keyPath: name].caseInsensitiveCompare(trimmed) == .orderedSame }
    }
}
