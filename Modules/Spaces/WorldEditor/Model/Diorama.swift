import AtlasCore
import Foundation

/// A prop in a hand-built room (the Creative Studio loft, the Study Library)
/// that a stored `SpaceObject` drives. The room places its props itself, so
/// an object's stored position doesn't matter there; its kind and action do.
public protocol DioramaRole: Hashable, CaseIterable, Sendable where AllCases == [Self] {
    /// The object kind that plays this role.
    var kind: SpaceObjectKind { get }
    var defaultLabel: String { get }
}

public struct DioramaAssignment<Role: DioramaRole>: Equatable, Sendable {
    /// The object behind each prop.
    public var roles: [Role: SpaceObject] = [:]
    /// Extra objects that do something: drawn as ordinary objects.
    public var loose: [SpaceObject] = []
    /// Extra objects that do nothing (e.g. a second plain poster): not drawn.
    public var hidden: [SpaceObject] = []
}

public enum Diorama {
    /// Gives each role one object of its kind, preferring objects that run
    /// something, so existing assignments always keep a visible prop.
    public static func assign<Role: DioramaRole>(_ objects: [SpaceObject], as _: Role.Type = Role.self) -> DioramaAssignment<Role> {
        var result = DioramaAssignment<Role>()
        var used = Set<UUID>()
        for role in Role.allCases {
            let candidates = objects.filter { $0.kind == role.kind && !used.contains($0.id) }
            if let chosen = candidates.first(where: \.hasAssignment) ?? candidates.first {
                result.roles[role] = chosen
                used.insert(chosen.id)
            }
        }
        for object in objects where !used.contains(object.id) {
            if object.hasAssignment { result.loose.append(object) } else { result.hidden.append(object) }
        }
        return result
    }

    /// The objects to save so each of `roles` gets its default: a missing
    /// prop is added, and a prop whose object runs nothing is given the
    /// default. An object that already runs something is never changed.
    public static func defaults<Role: DioramaRole>(
        for spaceID: UUID, existing: [SpaceObject], roles: [Role],
        position: (Role) -> SIMD3<Float>, configure: (Role, inout SpaceObject) -> Void
    ) -> [SpaceObject] {
        let assignment = assign(existing, as: Role.self)
        return roles.compactMap { role in
            let current = assignment.roles[role]
            if current?.hasAssignment == true { return nil }
            var object = current ?? SpaceObject(spaceID: spaceID, kind: role.kind, label: role.defaultLabel,
                                                transform: SpaceTransform(position: position(role)))
            configure(role, &object)
            if current != nil, !object.hasAssignment { return nil }
            if object.label?.isEmpty ?? true { object.label = role.defaultLabel }
            return object
        }
    }
}

extension SpaceLibrary {
    /// Brings Spaces made before their room's redesign up to date (once each).
    public func upgradeDioramaRooms() throws {
        try upgradeCreativeStudios()
        try upgradeStudyLibraries()
    }

    /// Runs `objects` once per Space of `templateID` (tracked by `key`) and
    /// saves what it returns in one transaction. `objects` gets the Space's
    /// stored objects and its default activation workflow.
    func upgradeDiorama(templateID: String, key: String,
                        objects: (Space, [SpaceObject], UUID?) -> [SpaceObject]) throws {
        for space in try store.spaces() where space.templateID == templateID {
            let preference = "\(key).\(space.id.uuidString)"
            guard try store.preference(preference, as: Bool.self) != true else { continue }
            let existing = try store.spaceObjects(spaceID: space.id)
            let profiles = try store.profiles(spaceID: space.id)
            let activation = (profiles.first(where: \.isDefault) ?? profiles.first)?.workflowID
            let changes = objects(space, existing, activation)
            try store.database.transaction {
                for object in changes { try store.saveSpaceObject(object) }
                try store.setPreference(true, for: preference)
            }
        }
    }

    var hasFocusAction: Bool { core.registry.descriptor(for: "timer.focus.start") != nil }
}
