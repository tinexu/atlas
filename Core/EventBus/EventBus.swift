import Foundation

/// Something that happened inside ATLAS. Names are dot-separated
/// (`workflow.started`, `space.activated`, `file.created`) so subscribers
/// can listen to a whole family with a `workflow.*` pattern.
public struct AtlasEvent: Sendable, Hashable, Identifiable {
    public let id: UUID
    public let name: String
    public let payload: ActionParameters
    public let timestamp: Date

    public init(_ name: String, payload: ActionParameters = [:], timestamp: Date = Date()) {
        self.id = UUID()
        self.name = name
        self.payload = payload
        self.timestamp = timestamp
    }

    public enum Name {
        public static let workflowStarted = "workflow.started"
        public static let workflowFinished = "workflow.finished"
        public static let stepStarted = "step.started"
        public static let stepFinished = "step.finished"
        public static let automationPaused = "automation.paused"
        public static let automationResumed = "automation.resumed"
        public static let workflowSaved = "workflow.saved"
        public static let workflowDeleted = "workflow.deleted"
        public static let log = "atlas.log"
    }
}

/// Distributes events between modules without coupling them (spec 7.2).
/// Handlers run synchronously on the publishing thread; use `stream(_:)`
/// to consume events from async code or another actor.
public final class EventBus: @unchecked Sendable {
    public struct Subscription: Hashable, Sendable {
        fileprivate let id: UUID
        public let pattern: String
    }

    private typealias Handler = @Sendable (AtlasEvent) -> Void

    private let lock = NSLock()
    private var handlers: [UUID: (pattern: String, handler: Handler)] = [:]
    private var history: [AtlasEvent] = []
    private let historyLimit: Int

    public init(historyLimit: Int = 200) {
        self.historyLimit = historyLimit
    }

    @discardableResult
    public func subscribe(_ pattern: String = "*", handler: @escaping @Sendable (AtlasEvent) -> Void) -> Subscription {
        let id = UUID()
        lock.synchronized { handlers[id] = (pattern, handler) }
        return Subscription(id: id, pattern: pattern)
    }

    public func unsubscribe(_ subscription: Subscription) {
        lock.synchronized { _ = handlers.removeValue(forKey: subscription.id) }
    }

    public func publish(_ event: AtlasEvent) {
        // Snapshot under the lock, call handlers outside it so a handler may
        // publish or subscribe without deadlocking.
        let matching: [Handler] = lock.synchronized {
            history.append(event)
            if history.count > historyLimit { history.removeFirst(history.count - historyLimit) }
            return handlers.values
                .filter { Self.matches(pattern: $0.pattern, name: event.name) }
                .map { $0.handler }
        }
        matching.forEach { $0(event) }
    }

    /// Events as an async sequence. The subscription ends when the
    /// consuming task is cancelled or stops iterating.
    public func stream(_ pattern: String = "*") -> AsyncStream<AtlasEvent> {
        AsyncStream { continuation in
            let subscription = self.subscribe(pattern) { continuation.yield($0) }
            continuation.onTermination = { [weak self] _ in
                self?.unsubscribe(subscription)
            }
        }
    }

    /// The most recent events, oldest first. Useful for debugging views.
    public var recentEvents: [AtlasEvent] {
        lock.synchronized { history }
    }

    /// `*` matches everything, `workflow.*` matches `workflow.` + anything,
    /// anything else must match exactly.
    public static func matches(pattern: String, name: String) -> Bool {
        if pattern == "*" { return true }
        if pattern.hasSuffix(".*") {
            return name.hasPrefix(String(pattern.dropLast()))
        }
        return pattern == name
    }
}

extension AtlasEvent.Name {
    /// Something for the Companion to offer, from any module. Payload:
    /// message, button, actionId, and the action's parameters as `param.<key>`.
    public static let companionOffer = "companion.offer"
    /// A study session started, paused, resumed or moved to a new pomodoro
    /// phase. Payload: sessionId (empty when none), phase ("focus",
    /// "shortBreak", "longBreak"), announce. The Companion reads quietly
    /// through focus phases.
    public static let studySessionChanged = "study.session.changed"
    /// Payload: sessionId, headline, early.
    public static let studySessionEnded = "study.session.ended"
}
