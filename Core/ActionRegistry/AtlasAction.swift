import Foundation

/// Errors produced while validating or performing an action. Messages are
/// written for the run-history screen, so they say what to do next.
public enum ActionError: Error, LocalizedError, Equatable, Sendable {
    case unknownAction(ActionID)
    case duplicateRegistration(ActionID)
    case missingParameter(String)
    case invalidParameter(String, reason: String)
    case disabledByUser(ActionID)
    case permissionDenied(Permission, PermissionStatus)
    case confirmationDeclined
    case timedOut(TimeInterval)
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .unknownAction(let id):
            return "No action named “\(id)” is registered. It may come from a newer version of ATLAS."
        case .duplicateRegistration(let id):
            return "An action named “\(id)” is already registered."
        case .missingParameter(let key):
            return "Missing required value “\(key)”."
        case .invalidParameter(let key, let reason):
            return "“\(key)” is invalid: \(reason)"
        case .disabledByUser(let id):
            return "“\(id)” is turned off in the Action Library."
        case .permissionDenied(let permission, let status):
            return "\(permission.title) permission is \(status.title.lowercased()). Grant it on the Permissions screen."
        case .confirmationDeclined:
            return "You declined this step."
        case .timedOut(let seconds):
            return "Didn't finish within \(ActionValue.number(seconds).displayString) seconds."
        case .failed(let message):
            return message
        }
    }
}

/// What a successful action reports back.
public struct ActionOutput: Sendable, Equatable {
    public var message: String
    public var values: ActionParameters

    public init(_ message: String, values: ActionParameters = [:]) {
        self.message = message
        self.values = values
    }
}

/// Services available to an action while it runs.
public struct ActionContext: Sendable {
    public let system: SystemAdapter
    public let events: EventBus
    public let runID: UUID?

    public init(system: SystemAdapter, events: EventBus, runID: UUID?) {
        self.system = system
        self.events = events
        self.runID = runID
    }
}

/// An operation ATLAS can perform. Implementations receive parameters that
/// the registry has already validated and filled with defaults.
public protocol AtlasAction: Sendable {
    var descriptor: ActionDescriptor { get }
    func perform(_ parameters: ActionParameters, context: ActionContext) async throws -> ActionOutput
}

extension ActionParameters {
    /// Validated string parameter; registry validation guarantees presence
    /// for required keys, so a miss here is a programming error surfaced as
    /// a normal failure rather than a crash.
    public func requiredString(_ key: String) throws -> String {
        guard let value = self[key]?.stringValue, !value.isEmpty else {
            throw ActionError.missingParameter(key)
        }
        return value
    }

    public func optionalString(_ key: String) -> String? {
        guard let value = self[key], !value.isEmpty else { return nil }
        return value.stringValue
    }

    public func path(_ key: String) throws -> String {
        (try requiredString(key) as NSString).expandingTildeInPath
    }
}
