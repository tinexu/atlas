import AtlasCore
import Foundation

public enum SpaceLibraryError: Error, LocalizedError, Equatable {
    case spaceNotFound
    case lastProfile

    public var errorDescription: String? {
        switch self {
        case .spaceNotFound: return "That Space no longer exists."
        case .lastProfile: return "A Space needs at least one activation profile."
        }
    }
}

extension Array where Element == Space {
    /// The order Spaces appear everywhere: by group, pinned first within a
    /// group, then by slot. ⌘1…⌘9 and Next/Previous Space follow it.
    public var worldOrdered: [Space] {
        sorted { a, b in
            if a.group != b.group { return a.group < b.group }
            if a.isPinned != b.isPinned { return a.isPinned }
            if a.slot != b.slot { return a.slot < b.slot }
            return a.createdAt < b.createdAt
        }
    }
}

/// Creates, edits and removes Spaces. Workflows are saved through
/// `AtlasCore.save(_:)` so they show up under Automations like any other.
public final class SpaceLibrary: @unchecked Sendable {
    private let core: AtlasCore
    private var store: AtlasStore { core.store }

    public init(core: AtlasCore) {
        self.core = core
    }

    // MARK: - Spaces

    /// Builds a Space from a template, with fresh workflows for its profiles.
    @discardableResult
    public func createSpace(from template: SpaceTemplate, name: String? = nil, group: SpaceGroup? = nil) throws -> Space {
        let spaceName = Self.cleaned(name) ?? template.name
        let space = Space(
            name: spaceName,
            group: group ?? template.group,
            templateID: template.id,
            accentColor: template.room.accentColor,
            slot: try nextSlot(),
            transitionBehavior: template.transitionBehavior
        )
        try store.database.transaction {
            try store.saveSpace(space)
            for (position, blueprint) in template.profiles.enumerated() {
                let workflow = try core.save(blueprint.makeWorkflow(spaceName: spaceName))
                try store.saveProfile(ActivationProfile(
                    spaceID: space.id,
                    name: blueprint.name,
                    workflowID: workflow.id,
                    isDefault: blueprint.isDefault || (position == 0 && !template.profiles.contains { $0.isDefault }),
                    position: position
                ))
            }
            for blueprint in template.objects {
                try store.saveSpaceObject(SpaceObject(
                    spaceID: space.id,
                    kind: blueprint.kind,
                    label: blueprint.label,
                    transform: blueprint.transform,
                    actionID: blueprint.actionID,
                    parameters: blueprint.parameters
                ))
            }
        }
        announce(AtlasEvent.Name.spaceSaved, space.id)
        return space
    }

    /// Saves edits to a Space, stamping `updatedAt`.
    @discardableResult
    public func save(_ space: Space) throws -> Space {
        var saved = space
        saved.name = Self.cleaned(space.name) ?? "Untitled Space"
        saved.updatedAt = Date()
        try store.saveSpace(saved)
        announce(AtlasEvent.Name.spaceSaved, saved.id)
        return saved
    }

    public func rename(spaceID: UUID, to name: String) throws {
        guard var space = try store.space(id: spaceID) else { throw SpaceLibraryError.spaceNotFound }
        space.name = name
        try save(space)
    }

    /// Copies a Space with its objects and profiles. Each profile gets its own
    /// copy of the workflow, so editing the copy never changes the original.
    @discardableResult
    public func duplicate(spaceID: UUID) throws -> Space {
        guard let original = try store.space(id: spaceID) else { throw SpaceLibraryError.spaceNotFound }
        var copy = original
        copy.id = UUID()
        copy.name = original.name + " Copy"
        copy.slot = try nextSlot()
        copy.isPinned = false
        copy.createdAt = Date()
        copy.updatedAt = Date()

        try store.database.transaction {
            try store.saveSpace(copy)
            for profile in try store.profiles(spaceID: original.id) {
                var workflowID = profile.workflowID
                if var workflow = try store.workflow(id: profile.workflowID) {
                    workflow.id = UUID()
                    workflow.name = "\(copy.name) · \(profile.name)"
                    workflow.createdAt = Date()
                    workflow.steps = workflow.steps.map { step in
                        var step = step
                        step.id = UUID()
                        return step
                    }
                    workflowID = try core.save(workflow).id
                }
                var newProfile = profile
                newProfile.id = UUID()
                newProfile.spaceID = copy.id
                newProfile.workflowID = workflowID
                try store.saveProfile(newProfile)
            }
            for object in try store.spaceObjects(spaceID: original.id) {
                var newObject = object
                newObject.id = UUID()
                newObject.spaceID = copy.id
                try store.saveSpaceObject(newObject)
            }
        }
        announce(AtlasEvent.Name.spaceSaved, copy.id)
        return copy
    }

    /// Deletes a Space, its profiles and objects. Workflows are kept unless
    /// `deleteWorkflows` is set, and even then a workflow another Space still
    /// uses is kept.
    public func delete(spaceID: UUID, deleteWorkflows: Bool) throws {
        let workflowIDs = Set(try store.profiles(spaceID: spaceID).map(\.workflowID))
        try store.deleteSpace(id: spaceID)
        if deleteWorkflows {
            let stillUsed = Set(try store.profiles().map(\.workflowID))
                .union(try store.spaceObjects().compactMap(\.workflowID))
            for workflowID in workflowIDs.subtracting(stillUsed) {
                try core.delete(workflowID: workflowID)
            }
        }
        announce(AtlasEvent.Name.spaceDeleted, spaceID)
    }

    /// Moves a Space earlier (negative offset) or later within its group.
    public func move(spaceID: UUID, by offset: Int) throws {
        let all = try store.spaces()
        guard let space = all.first(where: { $0.id == spaceID }) else { throw SpaceLibraryError.spaceNotFound }
        // Pinned Spaces always lead their group, so reorder within the same
        // pinned state only.
        let row = all.filter { $0.group == space.group && $0.isPinned == space.isPinned }.worldOrdered
        guard let index = row.firstIndex(where: { $0.id == spaceID }), row.indices.contains(index + offset) else { return }
        var reordered = row
        reordered.remove(at: index)
        reordered.insert(space, at: index + offset)
        let slots = row.map(\.slot).sorted()
        try store.database.transaction {
            for (space, slot) in zip(reordered, slots) where space.slot != slot {
                var updated = space
                updated.slot = slot
                try store.saveSpace(updated)
            }
        }
        announce(AtlasEvent.Name.spaceSaved, spaceID)
    }

    private func nextSlot() throws -> Int {
        (try store.spaces().map(\.slot).max() ?? -1) + 1
    }

    // MARK: - Profiles

    /// Saves a profile. Making it the default clears the flag on its siblings.
    public func saveProfile(_ profile: ActivationProfile) throws {
        try store.database.transaction {
            var profile = profile
            profile.name = Self.cleaned(profile.name) ?? "Default"
            if profile.isDefault {
                for sibling in try store.profiles(spaceID: profile.spaceID) where sibling.id != profile.id && sibling.isDefault {
                    var updated = sibling
                    updated.isDefault = false
                    try store.saveProfile(updated)
                }
            }
            try store.saveProfile(profile)
        }
        announce(AtlasEvent.Name.spaceSaved, profile.spaceID)
    }

    @discardableResult
    public func addProfile(to spaceID: UUID, name: String, workflowID: UUID) throws -> ActivationProfile {
        let existing = try store.profiles(spaceID: spaceID)
        let profile = ActivationProfile(
            spaceID: spaceID,
            name: name,
            workflowID: workflowID,
            isDefault: existing.isEmpty,
            position: (existing.map(\.position).max() ?? -1) + 1
        )
        try saveProfile(profile)
        return profile
    }

    /// Removes a profile (never the last one). If it was the default, the
    /// first remaining profile takes over. Its workflow is kept.
    public func deleteProfile(id: UUID) throws {
        guard let profile = try store.profile(id: id) else { return }
        let siblings = try store.profiles(spaceID: profile.spaceID).filter { $0.id != id }
        guard let successor = siblings.first else { throw SpaceLibraryError.lastProfile }
        try store.database.transaction {
            try store.deleteProfile(id: id)
            if profile.isDefault && !siblings.contains(where: \.isDefault) {
                var promoted = successor
                promoted.isDefault = true
                try store.saveProfile(promoted)
            }
        }
        announce(AtlasEvent.Name.spaceSaved, profile.spaceID)
    }

    // MARK: - Objects

    public func saveObject(_ object: SpaceObject) throws {
        try store.saveSpaceObject(object)
        announce(AtlasEvent.Name.spaceSaved, object.spaceID)
    }

    public func deleteObject(_ object: SpaceObject) throws {
        try store.deleteSpaceObject(id: object.id)
        announce(AtlasEvent.Name.spaceSaved, object.spaceID)
    }

    // MARK: - Onboarding

    /// Creates the starter Spaces once, on first launch only, so deleting
    /// them is permanent.
    public func seedStarterSpacesIfNeeded() throws {
        let key = "onboarding.seededSpaces.v1"
        guard try store.preference(key, as: Bool.self) != true else { return }
        if try store.spaces().isEmpty {
            for template in SpaceTemplates.starters {
                try createSpace(from: template)
            }
        }
        try store.setPreference(true, for: key)
    }

    // MARK: - Helpers

    private func announce(_ name: String, _ spaceID: UUID) {
        core.events.publish(AtlasEvent(name, payload: ["spaceId": .string(spaceID.uuidString)]))
    }

    private static func cleaned(_ name: String?) -> String? {
        guard let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }
}
