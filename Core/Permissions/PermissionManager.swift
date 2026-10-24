import Foundation

/// Central gatekeeper for everything ATLAS is allowed to do (spec 7.6).
///
/// Every action, whether a person configured it or an AI proposed it,
/// passes through `authorize(_:)` before it runs. The manager also keeps the
/// user's list of actions they've switched off entirely.
public final class PermissionManager: @unchecked Sendable {
    private static let disabledActionsKey = "permissions.disabledActions"

    private let provider: PermissionProvider
    private let store: AtlasStore?
    private let lock = NSLock()
    private var disabled: Set<ActionID>

    public init(provider: PermissionProvider, store: AtlasStore?) {
        self.provider = provider
        self.store = store
        let saved = (try? store?.preference(Self.disabledActionsKey, as: [ActionID].self)) ?? nil
        self.disabled = Set(saved ?? [])
    }

    // MARK: Per-action switches

    public func isEnabled(_ action: ActionID) -> Bool {
        lock.synchronized { !disabled.contains(action) }
    }

    public func setEnabled(_ enabled: Bool, for action: ActionID) throws {
        let snapshot: [ActionID] = lock.synchronized {
            if enabled { disabled.remove(action) } else { disabled.insert(action) }
            return disabled.sorted()
        }
        try store?.setPreference(snapshot, for: Self.disabledActionsKey)
    }

    public var disabledActions: Set<ActionID> {
        lock.synchronized { disabled }
    }

    // MARK: System permissions

    public func status(of permission: Permission) async -> PermissionStatus {
        await provider.status(of: permission)
    }

    public func request(_ permission: Permission) async -> PermissionStatus {
        let status = await provider.request(permission)
        AtlasLog.permissions.info("Requested \(permission.rawValue, privacy: .public): \(status.rawValue, privacy: .public)")
        return status
    }

    public func allStatuses() async -> [Permission: PermissionStatus] {
        var result: [Permission: PermissionStatus] = [:]
        for permission in Permission.allCases {
            result[permission] = await provider.status(of: permission)
        }
        return result
    }

    /// Throws unless the action is switched on and every permission it
    /// declares is usable. Undetermined permissions are requested once,
    /// except ones that can only be granted in System Settings.
    public func authorize(_ descriptor: ActionDescriptor) async throws {
        guard isEnabled(descriptor.id) else { throw ActionError.disabledByUser(descriptor.id) }
        for permission in descriptor.permissions.sorted(by: { $0.rawValue < $1.rawValue }) {
            var status = await provider.status(of: permission)
            if status == .notDetermined, permission.isRequestedDuringRuns {
                status = await request(permission)
            }
            guard status.allowsUse else { throw ActionError.permissionDenied(permission, status) }
        }
    }
}
