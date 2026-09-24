import Foundation
import ServiceManagement

/// "Start at Login": registers the LaunchAgent bundled at
/// `Ballast.app/Contents/Library/LaunchAgents/dev.ballast.plist` with
/// `SMAppService`. launchd starts Ballast at login and restarts it after a
/// crash (non-zero exit), but not after Quit. The entry shows up in System
/// Settings → General → Login Items, where the user can also switch it off.
///
/// Only works from inside `Ballast.app`: `SMAppService` looks the plist up in
/// `Bundle.main`, which is the enclosing app bundle only when the executable
/// is run from its real path (not through a symlink, not `.build/`).
enum LoginItem {
    private static let service = SMAppService.agent(plistName: "dev.ballast.plist")

    /// Nil when this process isn't running from an app bundle.
    static var unavailableReason: String? {
        Bundle.main.bundleURL.pathExtension == "app" ? nil
            : "Start at Login needs Ballast.app (this binary runs from \(Bundle.main.bundleURL.path))"
    }

    /// `.notFound` is what `SMAppService` reports for an agent that has never
    /// been registered, so it counts as off.
    static var status: SMAppService.Status {
        let status = service.status
        return status == .notFound ? .notRegistered : status
    }

    /// Registering an already-registered agent is a no-op; so is unregistering
    /// an unregistered one.
    static func setEnabled(_ enabled: Bool) throws {
        if let reason = unavailableReason { throw LoginItemError(message: reason) }
        if enabled {
            guard status != .enabled else { return }
            try service.register()
        } else {
            guard status != .notRegistered else { return }
            try service.unregister()
        }
    }

    static func describe(_ status: SMAppService.Status) -> String {
        switch status {
        case .enabled: "on"
        case .notRegistered, .notFound: "off"
        case .requiresApproval: "waiting for approval in System Settings → General → Login Items"
        @unknown default: "unknown"
        }
    }
}

struct LoginItemError: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
}
