import AppKit
import AtlasCore
import AtlasSpaces
import AtlasSpacesUI
import SwiftUI

/// UI-facing state for Spaces. Like `AppModel`, it owns no logic: Spaces
/// are edited through `SpaceLibrary`, activated through `SpaceActivator`
/// or the `space.activate` action, and room objects run through the engine.
@MainActor
final class SpacesModel: ObservableObject {
    enum ViewMode: String, CaseIterable, Identifiable {
        case world, list
        var id: Self { self }
        var title: String { self == .world ? "3D" : "List" }
        var symbol: String { self == .world ? "cube" : "list.bullet" }
    }

    /// An app a Space's activation opens, and whether it's running now.
    struct AppPresence: Identifiable, Hashable {
        let bundleID: String
        let name: String
        let isRunning: Bool
        var id: String { bundleID }
    }

    /// In world order.
    @Published private(set) var spaces: [Space] = []
    @Published private(set) var profiles: [UUID: [ActivationProfile]] = [:]
    @Published private(set) var objects: [UUID: [SpaceObject]] = [:]
    @Published private(set) var workflows: [UUID: Workflow] = [:]
    @Published private(set) var activeSpaceID: UUID?
    @Published private(set) var activating: Set<UUID> = []
    /// spaceID → its latest activation run.
    @Published private(set) var lastRuns: [UUID: WorkflowRun] = [:]
    @Published private(set) var runningBundleIDs: Set<String> = []
    /// Window layouts by ID, for profile pickers and app lists.
    @Published private(set) var layouts: [UUID: WindowLayout] = [:]
    /// spaceID → the snapshot saved when it was last left.
    @Published private(set) var leaveSnapshots: [UUID: SessionSnapshot] = [:]
    /// Shown after returning to a Space that was left with windows open.
    @Published var restoreOffer: RestoreOffer?

    struct RestoreOffer: Equatable {
        let spaceID: UUID
        let snapshot: SessionSnapshot
    }

    @Published var selectedSpaceID: UUID?
    /// The profile picked in the UI per Space; falls back to the default.
    @Published var chosenProfileIDs: [UUID: UUID] = [:]
    @Published var viewMode: ViewMode = .world {
        didSet { persistViewMode() }
    }
    @Published var editingSpaceID: UUID?
    @Published var editingObject: SpaceObject?
    @Published var pendingDeletion: Space?

    let module: SpacesModule?
    private let core: AtlasCore?
    var onError: ((String) -> Void)?
    /// Asks "Lock in for how long?" for a profile that uses lockdown.
    var onLockdownPrompt: ((LockdownModel.PendingStart) -> Void)?
    /// What the Study Library room shows (courses and more).
    var studyState: (() -> StudyRoomState?)?
    /// Handles a Study Library object click; returns whether it did.
    var studyObjectClicked: ((SpaceObject) -> Bool)?
    private var eventTask: Task<Void, Never>?
    private var workspaceObservers: [NSObjectProtocol] = []

    private static let viewModeKey = "spaces.viewMode"

    init(core: AtlasCore?) {
        self.core = core
        guard let core else {
            module = nil
            return
        }
        var startupError: Error?
        do {
            let module = try SpacesModule(core: core)
            try module.library.seedStarterSpacesIfNeeded()
            // Gives redesigned rooms made before the redesign their new props (once).
            try module.library.upgradeDioramaRooms()
            self.module = module
        } catch {
            module = nil
            startupError = error
        }
        if let mode = (try? core.store.preference(Self.viewModeKey, as: String.self)).flatMap({ $0 }).flatMap(ViewMode.init) {
            viewMode = mode
        }
        reload()
        refreshRunningApps()
        selectedSpaceID = activeSpaceID ?? spaces.first?.id
        listenForEvents()
        observeWorkspace()
        if let startupError {
            DispatchQueue.main.async { [weak self] in self?.onError?(startupError.localizedDescription) }
        }
    }

    var isAvailable: Bool { module != nil }

    // MARK: - Lookups

    func space(id: UUID?) -> Space? {
        guard let id else { return nil }
        return spaces.first { $0.id == id }
    }

    var groupedSpaces: [(group: SpaceGroup, spaces: [Space])] {
        var result: [(SpaceGroup, [Space])] = []
        for space in spaces {
            if let index = result.firstIndex(where: { $0.0 == space.group }) {
                result[index].1.append(space)
            } else {
                result.append((space.group, [space]))
            }
        }
        return result.map { (group: $0.0, spaces: $0.1) }
    }

    func profiles(for spaceID: UUID) -> [ActivationProfile] { profiles[spaceID] ?? [] }

    func objects(for spaceID: UUID) -> [SpaceObject] { objects[spaceID] ?? [] }

    /// The profile the UI would activate: the chosen one, else the default.
    func selectedProfile(for spaceID: UUID) -> ActivationProfile? {
        let all = profiles(for: spaceID)
        if let chosen = chosenProfileIDs[spaceID], let match = all.first(where: { $0.id == chosen }) { return match }
        return all.first(where: \.isDefault) ?? all.first
    }

    func status(for spaceID: UUID) -> SpaceStatus {
        SpaceStatus.resolve(
            isActive: activeSpaceID == spaceID,
            isActivating: activating.contains(spaceID),
            lastRun: lastRuns[spaceID]
        )
    }

    var sortedLayouts: [WindowLayout] {
        layouts.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func layout(for profile: ActivationProfile?) -> WindowLayout? {
        profile?.windowLayoutID.flatMap { layouts[$0] }
    }

    func template(for space: Space) -> SpaceTemplate {
        SpaceTemplates.template(id: space.templateID) ?? SpaceTemplates.fallback
    }

    /// Apps the given profile's workflow opens, with live running state.
    func apps(for spaceID: UUID, profile: ActivationProfile? = nil) -> [AppPresence] {
        guard let profile = profile ?? selectedProfile(for: spaceID),
              let workflow = workflows[profile.workflowID]
        else { return [] }
        return SpaceApps.bundleIDs(in: workflow, layout: layout(for: profile)).map { bundleID in
            AppPresence(
                bundleID: bundleID,
                name: core?.system.applicationName(for: bundleID) ?? bundleID,
                isRunning: runningBundleIDs.contains(bundleID)
            )
        }
    }

    func describeAssignment(of object: SpaceObject) -> String {
        if let workflowID = object.workflowID {
            return workflows[workflowID].map { "Runs “\($0.name)”" } ?? "Its automation was deleted"
        }
        if let actionID = object.actionID {
            let step = WorkflowStep(actionID: actionID, parameters: object.parameters)
            return core?.registry.displayLabel(for: step) ?? actionID.rawValue
        }
        return "Nothing assigned"
    }

    var roomSnapshots: [RoomSnapshot] {
        spaces.map { space in
            RoomSnapshot(
                space: space,
                room: template(for: space).room,
                objects: objects(for: space.id),
                status: status(for: space.id),
                isActive: activeSpaceID == space.id,
                study: space.templateID == StudyLibrary.templateID ? studyState?() : nil
            )
        }
    }

    // MARK: - Activation

    /// Activates through `SpaceActivator`. Returns at once: the workflow
    /// starts immediately and any camera move runs alongside it.
    func activate(_ spaceID: UUID, profileID: UUID? = nil) {
        let profileID = profileID ?? selectedProfile(for: spaceID)?.id
        if promptForLockdown(spaceID, profileID: profileID) { return }
        activate(spaceID, profileID: profileID, lockdownMinutes: nil)
    }

    /// Activates, starting lockdown for `lockdownMinutes` (in the mode
    /// `lockdownModeID`) if given.
    func activate(_ spaceID: UUID, profileID: UUID?, lockdownMinutes: Double?, lockdownModeID: UUID? = nil) {
        guard let activator = module?.activator else { return }
        activating.insert(spaceID)
        Task {
            do {
                _ = try await activator.activate(spaceID: spaceID, profileID: profileID, lockdownMinutes: lockdownMinutes,
                                                 lockdownModeID: lockdownModeID)
            } catch SpaceActivationError.lockedDown {
                // Lockdown already said so with a toast.
                activating.remove(spaceID)
            } catch {
                activating.remove(spaceID)
                onError?(error.localizedDescription)
            }
        }
    }

    /// Shows the lockdown prompt instead of activating when the profile
    /// uses lockdown and none is running yet. Returns whether it did.
    private func promptForLockdown(_ spaceID: UUID, profileID: UUID?) -> Bool {
        guard let profileID, let lockdown = core?.time?.lockdown, lockdown.session == nil,
              let settings = lockdown.settings(forProfile: profileID), settings.isEnabled,
              let space = space(id: spaceID), let onLockdownPrompt
        else { return false }
        onLockdownPrompt(.init(spaceID: spaceID, spaceName: space.name, profileID: profileID, settings: settings))
        return true
    }

    /// Keyboard shortcuts go through the registered `space.activate` action,
    /// like any other surface that triggers an action.
    func activateFromShortcut(_ spaceID: UUID) {
        guard let core else { return }
        if promptForLockdown(spaceID, profileID: selectedProfile(for: spaceID)?.id) { return }
        activating.insert(spaceID)
        Task {
            let run = await core.engine.invoke(
                SpaceActivateAction.id, parameters: ["space": .string(spaceID.uuidString)], source: "shortcut"
            )
            // A run that never reached the activator (e.g. paused) leaves no
            // space.activated event behind to clear the flag.
            if run.state == .skipped { activating.remove(spaceID) }
        }
    }

    /// Puts the Space's windows back where they were when it was left.
    /// Runs through the engine, so it shows in Run History.
    func restoreWhereLeftOff(_ snapshot: SessionSnapshot) {
        guard let activator = module?.activator else { return }
        if restoreOffer?.snapshot.id == snapshot.id { restoreOffer = nil }
        Task {
            let run = await activator.restoreWhereLeftOff(snapshotID: snapshot.id)
            if run.state == .failed || run.state == .skipped {
                onError?(run.error ?? "Couldn't restore “\(snapshot.name)”.")
            }
        }
    }

    func activateNeighbor(_ offset: Int) {
        guard !spaces.isEmpty else { return }
        let current = spaces.firstIndex { $0.id == activeSpaceID }
        let next: Int
        if let current {
            next = (current + offset + spaces.count) % spaces.count
        } else {
            next = offset >= 0 ? 0 : spaces.count - 1
        }
        selectedSpaceID = spaces[next].id
        activateFromShortcut(spaces[next].id)
    }

    /// Runs a room object's assignment through the engine.
    func run(_ object: SpaceObject) {
        guard let core else { return }
        if let workflowID = object.workflowID {
            guard let workflow = workflows[workflowID] else {
                onError?("The automation assigned to “\(object.displayName)” was deleted.")
                return
            }
            Task { await core.engine.start(workflow, trigger: SpaceTrigger.object) }
        } else if let actionID = object.actionID {
            Task { _ = await core.engine.invoke(actionID, parameters: object.parameters, source: SpaceTrigger.object) }
        }
    }

    /// A click on an object in the 3D room: run it if it does something,
    /// otherwise offer to assign something.
    func objectClicked(_ object: SpaceObject) {
        // The Study Library's chalkboard and desk calendar have their own clicks.
        if space(id: object.spaceID)?.templateID == StudyLibrary.templateID, studyObjectClicked?(object) == true { return }
        if object.hasAssignment {
            run(object)
        } else {
            editingObject = object
        }
    }

    // MARK: - Editing

    func createSpace(from template: SpaceTemplate) {
        perform {
            guard let space = try module?.library.createSpace(from: template) else { return }
            reload()
            selectedSpaceID = space.id
            editingSpaceID = space.id
        }
    }

    func duplicate(_ spaceID: UUID) {
        perform {
            guard let copy = try module?.library.duplicate(spaceID: spaceID) else { return }
            reload()
            selectedSpaceID = copy.id
        }
    }

    func delete(_ spaceID: UUID, deleteWorkflows: Bool) {
        perform {
            try module?.library.delete(spaceID: spaceID, deleteWorkflows: deleteWorkflows)
            reload()
            if selectedSpaceID == spaceID { selectedSpaceID = spaces.first?.id }
        }
    }

    func move(_ spaceID: UUID, by offset: Int) {
        perform { try module?.library.move(spaceID: spaceID, by: offset) }
    }

    func canMove(_ spaceID: UUID, by offset: Int) -> Bool {
        guard let space = space(id: spaceID) else { return false }
        let row = spaces.filter { $0.group == space.group && $0.isPinned == space.isPinned }
        guard let index = row.firstIndex(where: { $0.id == spaceID }) else { return false }
        return row.indices.contains(index + offset)
    }

    func save(_ space: Space) {
        perform { try module?.library.save(space) }
    }

    func togglePinned(_ spaceID: UUID) {
        guard var space = space(id: spaceID) else { return }
        space.isPinned.toggle()
        save(space)
    }

    /// Saves a Space's edited profiles: removed ones first, then the rest.
    func saveProfiles(_ drafts: [ActivationProfile], removing removed: [UUID]) {
        perform {
            guard let library = module?.library else { return }
            for (position, var profile) in drafts.enumerated() {
                profile.position = position
                try library.saveProfile(profile)
            }
            for id in removed {
                try library.deleteProfile(id: id)
            }
        }
    }

    func save(_ object: SpaceObject) {
        perform { try module?.library.saveObject(object) }
    }

    func delete(_ object: SpaceObject) {
        perform { try module?.library.deleteObject(object) }
    }

    func addObject(_ kind: SpaceObjectKind, to spaceID: UUID) {
        // Start near the middle of the floor; the editor places it precisely.
        let height: Float = (kind == .clock || kind == .poster) ? 0.6 : 0
        let z: Float = (kind == .clock || kind == .poster) ? -0.96 : 0.2
        let object = SpaceObject(spaceID: spaceID, kind: kind, transform: SpaceTransform(position: [0, height, z]))
        save(object)
        editingObject = object
    }

    private func perform(_ body: () throws -> Void) {
        do {
            try body()
        } catch {
            onError?(error.localizedDescription)
        }
        reload()
    }

    private func persistViewMode() {
        try? core?.store.setPreference(viewMode.rawValue, for: Self.viewModeKey)
    }

    // MARK: - Loading

    func reload() {
        guard let store = core?.store else { return }
        do {
            spaces = try store.spaces().worldOrdered
            profiles = Dictionary(grouping: try store.profiles(), by: \.spaceID)
            objects = Dictionary(grouping: try store.spaceObjects(), by: \.spaceID)
            workflows = Dictionary(uniqueKeysWithValues: try store.workflows().map { ($0.id, $0) })
            layouts = Dictionary(uniqueKeysWithValues: try store.windowLayouts().map { ($0.id, $0) })
            var leaves: [UUID: SessionSnapshot] = [:]
            for snapshot in try store.snapshots(limit: 200) where snapshot.isAutomatic {
                if let spaceID = snapshot.spaceID, leaves[spaceID] == nil { leaves[spaceID] = snapshot }
            }
            leaveSnapshots = leaves
            activeSpaceID = try store.activeSpaceID()
            var runs: [UUID: WorkflowRun] = [:]
            for space in spaces {
                if let runID = try store.lastActivationRunID(spaceID: space.id), let run = try store.run(id: runID) {
                    runs[space.id] = run
                }
            }
            lastRuns = runs
            chosenProfileIDs = chosenProfileIDs.filter { spaceID, profileID in
                profiles[spaceID]?.contains { $0.id == profileID } == true
            }
        } catch {
            onError?(error.localizedDescription)
        }
    }

    func refreshRunningApps() {
        guard let core else { return }
        runningBundleIDs = Set(core.system.runningApplications().map(\.bundleID))
    }

    private func listenForEvents() {
        guard let core else { return }
        let stream = core.events.stream()
        eventTask = Task { [weak self] in
            for await event in stream {
                guard let self else { return }
                self.handle(event)
            }
        }
    }

    private func handle(_ event: AtlasEvent) {
        let spaceID = event.payload["spaceId"]?.stringValue.flatMap(UUID.init(uuidString:))
        switch event.name {
        case AtlasEvent.Name.spaceActivating:
            if let spaceID { activating.insert(spaceID) }
            if restoreOffer?.spaceID != spaceID { restoreOffer = nil }
            activeSpaceID = spaceID
        case AtlasEvent.Name.spaceActivated:
            if let spaceID { activating.remove(spaceID) }
            reload()
            refreshRunningApps()
            if let spaceID,
               let snapshotID = event.payload["restorableSnapshotId"]?.stringValue.flatMap(UUID.init(uuidString:)),
               let snapshot = try? core?.store.snapshot(id: snapshotID) {
                restoreOffer = RestoreOffer(spaceID: spaceID, snapshot: snapshot)
            }
        case AtlasEvent.Name.spaceSaved, AtlasEvent.Name.spaceDeleted,
             AtlasEvent.Name.workflowSaved, AtlasEvent.Name.workflowDeleted,
             AtlasEvent.Name.windowLayoutSaved, AtlasEvent.Name.windowLayoutDeleted,
             AtlasEvent.Name.snapshotSaved:
            reload()
        case AtlasEvent.Name.workflowFinished:
            refreshRunningApps()
        default:
            break
        }
    }

    private func observeWorkspace() {
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            workspaceObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshRunningApps() }
            })
        }
    }
}
