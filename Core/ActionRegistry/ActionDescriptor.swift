import Foundation

/// Stable identifier for a registered action, e.g. `application.launch`.
public struct ActionID: RawRepresentable, Hashable, Codable, Sendable,
    ExpressibleByStringLiteral, CustomStringConvertible, Comparable
{
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { self.rawValue = value }
    public var description: String { rawValue }
    public static func < (lhs: ActionID, rhs: ActionID) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// Describes one parameter an action accepts. The app generates its
/// editing UI from these, and the registry validates against them.
public struct ParameterSpec: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case text
        case bundleIdentifier
        case url
        case filePath
        case folderPath
        case number
        case boolean
    }

    public let key: String
    public let label: String
    public let kind: Kind
    public let isRequired: Bool
    public let help: String?
    public let defaultValue: ActionValue?
    public let minimum: Double?
    public let maximum: Double?

    public init(
        key: String,
        label: String,
        kind: Kind,
        isRequired: Bool = true,
        help: String? = nil,
        defaultValue: ActionValue? = nil,
        minimum: Double? = nil,
        maximum: Double? = nil
    ) {
        self.key = key
        self.label = label
        self.kind = kind
        self.isRequired = isRequired
        self.help = help
        self.defaultValue = defaultValue
        self.minimum = minimum
        self.maximum = maximum
    }
}

/// Observable consequences of running an action (spec 5.5).
public enum SideEffect: String, Codable, CaseIterable, Sendable {
    case launchesApplication
    case terminatesApplication
    case hidesApplication
    case opensURL
    case opensDocument
    case showsUI
    case showsNotification
    case modifiesFiles
    case destructive

    public var title: String {
        switch self {
        case .launchesApplication: return "Launches apps"
        case .terminatesApplication: return "Quits apps"
        case .hidesApplication: return "Hides apps"
        case .opensURL: return "Opens links"
        case .opensDocument: return "Opens documents"
        case .showsUI: return "Shows Finder windows"
        case .showsNotification: return "Posts notifications"
        case .modifiesFiles: return "Changes files"
        case .destructive: return "Destructive"
        }
    }
}

/// The standardised description of an operation ATLAS can perform
/// (spec 7.3). The same descriptor backs a 3D room object, a workflow
/// node, a keyboard shortcut and a Companion command.
public struct ActionDescriptor: Codable, Hashable, Sendable, Identifiable {
    public let id: ActionID
    public let title: String
    public let summary: String
    public let category: String
    public let symbolName: String
    public let parameters: [ParameterSpec]
    public let permissions: Set<Permission>
    public let sideEffects: Set<SideEffect>
    /// The user must approve each run of this action.
    public let confirmationRequired: Bool
    /// Safe to retry automatically: repeating it can't duplicate work or
    /// cause irreversible changes (spec 5.7).
    public let isIdempotent: Bool
    public let defaultTimeout: TimeInterval

    public init(
        id: ActionID,
        title: String,
        summary: String,
        category: String,
        symbolName: String,
        parameters: [ParameterSpec] = [],
        permissions: Set<Permission> = [],
        sideEffects: Set<SideEffect> = [],
        confirmationRequired: Bool = false,
        isIdempotent: Bool = false,
        defaultTimeout: TimeInterval = 30
    ) {
        self.id = id
        self.title = title
        self.summary = summary
        self.category = category
        self.symbolName = symbolName
        self.parameters = parameters
        self.permissions = permissions
        self.sideEffects = sideEffects
        self.confirmationRequired = confirmationRequired
        self.isIdempotent = isIdempotent
        self.defaultTimeout = defaultTimeout
    }
}
