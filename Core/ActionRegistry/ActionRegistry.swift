import Foundation

/// The catalogue of every operation ATLAS can perform (spec 7.3).
///
/// Modules never launch apps or open files themselves; they look up a
/// registered action here and hand it to the engine, so behaviour, checks
/// and logging stay identical wherever an action is triggered from.
public final class ActionRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var actions: [ActionID: any AtlasAction] = [:]

    public init() {}

    /// A registry pre-loaded with the built-in Stage 01 actions.
    public static func standard() -> ActionRegistry {
        let registry = ActionRegistry()
        for action in BuiltInActions.all {
            // Built-in identifiers are unique by construction.
            try? registry.register(action)
        }
        return registry
    }

    public func register(_ action: any AtlasAction) throws {
        let id = action.descriptor.id
        try lock.synchronized {
            guard actions[id] == nil else { throw ActionError.duplicateRegistration(id) }
            actions[id] = action
        }
    }

    public func action(for id: ActionID) -> (any AtlasAction)? {
        lock.synchronized { actions[id] }
    }

    public func descriptor(for id: ActionID) -> ActionDescriptor? {
        action(for: id)?.descriptor
    }

    /// All descriptors, grouped by category then title.
    public var descriptors: [ActionDescriptor] {
        lock.synchronized { actions.values.map { $0.descriptor } }
            .sorted { ($0.category, $0.title) < ($1.category, $1.title) }
    }

    /// Human-readable label for a step, e.g. "Launch App · com.apple.Terminal".
    public func displayLabel(for step: WorkflowStep) -> String {
        if let label = step.label, !label.trimmingCharacters(in: .whitespaces).isEmpty {
            return label
        }
        guard let descriptor = descriptor(for: step.actionID) else { return step.actionID.rawValue }
        let detail = descriptor.parameters.lazy
            .compactMap { step.parameters[$0.key] }
            .first { !$0.isEmpty }?
            .displayString
        guard let detail else { return descriptor.title }
        return "\(descriptor.title) · \(detail)"
    }

    /// Checks parameters against the descriptor and fills in defaults.
    /// Unknown keys are dropped so stale data can't leak into an action.
    public func validate(_ parameters: ActionParameters, for descriptor: ActionDescriptor) throws -> ActionParameters {
        var resolved: ActionParameters = [:]
        for spec in descriptor.parameters {
            var value = parameters[spec.key]
            if value == nil || value!.isEmpty {
                if let fallback = spec.defaultValue {
                    value = fallback
                } else if spec.isRequired {
                    throw ActionError.missingParameter(spec.label)
                } else {
                    continue
                }
            }
            resolved[spec.key] = try Self.check(value!, against: spec)
        }
        return resolved
    }

    private static func check(_ value: ActionValue, against spec: ParameterSpec) throws -> ActionValue {
        func invalid(_ reason: String) -> ActionError { .invalidParameter(spec.label, reason: reason) }

        switch spec.kind {
        case .number:
            guard let n = value.numberValue, n.isFinite else { throw invalid("expected a number") }
            if let min = spec.minimum, n < min { throw invalid("must be at least \(ActionValue.number(min).displayString)") }
            if let max = spec.maximum, n > max { throw invalid("must be at most \(ActionValue.number(max).displayString)") }
            return .number(n)

        case .boolean:
            guard let b = value.boolValue else { throw invalid("expected on or off") }
            return .bool(b)

        case .url:
            guard let s = value.stringValue?.trimmingCharacters(in: .whitespaces),
                  let url = URL(string: s), let scheme = url.scheme, !scheme.isEmpty
            else { throw invalid("expected a full link such as https://example.com") }
            return .string(s)

        case .bundleIdentifier:
            guard let s = value.stringValue?.trimmingCharacters(in: .whitespaces), s.contains("."),
                  s.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || "-._".unicodeScalars.contains($0) })
            else { throw invalid("expected a bundle identifier such as com.apple.Terminal") }
            return .string(s)

        case .filePath, .folderPath:
            guard let s = value.stringValue?.trimmingCharacters(in: .whitespaces), !s.isEmpty else {
                throw invalid("expected a path")
            }
            let expanded = (s as NSString).expandingTildeInPath
            guard expanded.hasPrefix("/") else { throw invalid("expected an absolute path or one starting with ~") }
            return .string(s)

        case .text:
            guard let s = value.stringValue else { throw invalid("expected text") }
            return .string(s)
        }
    }
}

extension NSLock {
    @discardableResult
    func synchronized<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
