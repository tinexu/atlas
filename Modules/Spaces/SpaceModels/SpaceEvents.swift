import AtlasCore

extension AtlasEvent.Name {
    /// Payload: spaceId, profileId, runId.
    public static let spaceActivating = "space.activating"
    /// Payload: spaceId, profileId, runId, state.
    public static let spaceActivated = "space.activated"
    /// Payload: spaceId. Sent for the previous Space when another one takes over.
    public static let spaceDeactivated = "space.deactivated"
    /// A Space, profile or object was created, changed or deleted. Payload: spaceId.
    public static let spaceSaved = "space.saved"
    public static let spaceDeleted = "space.deleted"
}

/// Run triggers recorded in history for Spaces work.
public enum SpaceTrigger {
    /// A Space's activation workflow.
    public static let activated = "space.activated"
    /// Hiding or minimizing the previous Space's apps.
    public static let transition = "space.transition"
    /// A clicked room object.
    public static let object = "space.object"
    /// "Restore where you left off" after returning to a Space.
    public static let restore = "space.restore"
}
