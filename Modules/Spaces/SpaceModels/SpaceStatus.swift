import AtlasCore
import Foundation

/// What a Space can honestly claim, derived from its latest activation run
/// rather than from the fact that someone asked for it.
public enum SpaceStatus: Hashable, Sendable {
    /// Not the active Space.
    case inactive
    case activating
    case ready
    case partiallyReady(succeeded: Int, total: Int)
    case failed(String?)

    /// Status for the active Space given its latest activation run.
    public init(run: WorkflowRun) {
        switch run.state {
        case .pending, .running:
            self = .activating
        case .succeeded:
            self = .ready
        case .partiallySucceeded:
            let succeeded = run.steps.filter { $0.state == .succeeded }.count
            self = .partiallyReady(succeeded: succeeded, total: run.steps.count)
        case .failed:
            self = .failed(run.error)
        case .canceled:
            self = .failed(run.error ?? "Activation was canceled.")
        case .skipped:
            self = .failed(run.error ?? "Nothing ran.")
        }
    }

    /// - Parameters:
    ///   - isActive: whether this is the recorded active Space.
    ///   - isActivating: whether an activation is in flight right now.
    ///   - lastRun: the latest activation run for this Space, if any.
    public static func resolve(isActive: Bool, isActivating: Bool, lastRun: WorkflowRun?) -> SpaceStatus {
        if isActivating { return .activating }
        guard isActive else { return .inactive }
        guard let lastRun else { return .inactive }
        return SpaceStatus(run: lastRun)
    }

    public var title: String {
        switch self {
        case .inactive: return "Not active"
        case .activating: return "Activating…"
        case .ready: return "Ready"
        case .partiallyReady(let succeeded, let total): return "Partially ready (\(succeeded) of \(total) steps)"
        case .failed: return "Failed"
        }
    }

    public var symbolName: String {
        switch self {
        case .inactive: return "circle"
        case .activating: return "arrow.triangle.2.circlepath"
        case .ready: return "checkmark.circle.fill"
        case .partiallyReady: return "exclamationmark.circle.fill"
        case .failed: return "xmark.octagon.fill"
        }
    }

    public var detail: String? {
        if case .failed(let reason) = self { return reason }
        return nil
    }
}
