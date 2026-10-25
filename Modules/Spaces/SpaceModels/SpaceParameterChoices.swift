import AtlasCore
import Foundation

/// The lists behind `ParameterSpec.choicesFrom` for Spaces, so editors can
/// offer real Space and profile names as a menu.
public enum SpaceParameterChoices {
    public static let spaces = "spaces"
    /// Profiles of the Space named in the same step's "space" parameter.
    public static let profiles = "spaceProfiles"

    /// The menu for `spec`, or nil if it has none (or it can't be known yet,
    /// e.g. profiles while the Space is a `{{placeholder}}`).
    public static func choices(for spec: ParameterSpec, parameters: ActionParameters, store: AtlasStore) -> [String]? {
        switch spec.choicesFrom {
        case spaces:
            return (try? store.spaces().worldOrdered.map(\.name)) ?? []
        case profiles:
            guard let name = parameters["space"]?.stringValue?.trimmingCharacters(in: .whitespaces), !name.isEmpty,
                  let space = try? store.spaces().first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame })
            else { return nil }
            return (try? store.profiles(spaceID: space.id).map(\.name)) ?? []
        default:
            return nil
        }
    }
}
