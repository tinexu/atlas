#if os(macOS)
import ApplicationServices
import Foundation
import UserNotifications

/// Reads real authorisation state from macOS.
public struct MacPermissionProvider: PermissionProvider {
    public init() {}

    public func status(of permission: Permission) async -> PermissionStatus {
        switch permission {
        case .accessibility:
            // macOS doesn't distinguish "never asked" from "denied" here.
            return AXIsProcessTrusted() ? .granted : .notDetermined

        case .notifications:
            guard Bundle.main.bundleIdentifier != nil else { return .unavailable }
            let settings = await UNUserNotificationCenter.current().notificationSettings()
            switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral: return .granted
            case .denied: return .denied
            case .notDetermined: return .notDetermined
            @unknown default: return .notDetermined
            }

        case .automation:
            // Apple Events consent is granted per target app, at first use.
            return .managedBySystem

        case .fileAccess:
            // ATLAS isn't sandboxed in Stage 01; macOS prompts the first
            // time it reaches into Desktop, Documents, Downloads, etc.
            return .managedBySystem
        }
    }

    public func request(_ permission: Permission) async -> PermissionStatus {
        switch permission {
        case .accessibility:
            // Shows the system prompt that links to Privacy & Security.
            let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
            return AXIsProcessTrustedWithOptions(options) ? .granted : .notDetermined

        case .notifications:
            guard Bundle.main.bundleIdentifier != nil else { return .unavailable }
            let granted = (try? await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound])) ?? false
            return granted ? .granted : .denied

        case .automation, .fileAccess:
            return .managedBySystem
        }
    }
}
#endif
