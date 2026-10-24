import os

/// Unified-logging categories. View them in Console.app by filtering on the
/// subsystem `app.atlas`, or with:
///   log stream --predicate 'subsystem == "app.atlas"'
public enum AtlasLog {
    public static let subsystem = "app.atlas"
    public static let engine = Logger(subsystem: subsystem, category: "engine")
    public static let actions = Logger(subsystem: subsystem, category: "actions")
    public static let persistence = Logger(subsystem: subsystem, category: "persistence")
    public static let permissions = Logger(subsystem: subsystem, category: "permissions")
}
