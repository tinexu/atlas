import AtlasCore
import Foundation

/// Wires Spaces into an `AtlasCore`: registers the `space.activate` action
/// and exposes the library and activator to the app.
public final class SpacesModule: Sendable {
    public let library: SpaceLibrary
    public let activator: SpaceActivator

    public init(core: AtlasCore) throws {
        library = SpaceLibrary(core: core)
        activator = SpaceActivator(core: core)
        try core.registry.register(SpaceActivateAction(activator: activator))
    }
}
