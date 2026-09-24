import AppKit
import Foundation

/// Reads user-visible macOS preferences relevant to Space management.
/// Read-only: nothing in this file writes to any preference domain.
public enum SystemSettings {

    private static let spacesDomain = "com.apple.spaces" as CFString
    private static let dockDomain = "com.apple.dock" as CFString
    private static let windowManagerDomain = "com.apple.WindowManager" as CFString
    private static let currentUser = kCFPreferencesCurrentUser
    private static let anyHost = kCFPreferencesAnyHost

    /// Forces a fresh read of `domain` before copying a value out of it.
    private static func freshBool(_ key: String, domain: CFString, default defaultValue: Bool) -> Bool {
        CFPreferencesAppSynchronize(domain)
        var valid: DarwinBoolean = false
        let result = CFPreferencesGetAppBooleanValue(key as CFString, domain, &valid)
        return valid.boolValue ? result : defaultValue
    }

    /// "Displays have separate Spaces" — `com.apple.spaces` `spans-displays`
    /// is the *inverse*: absent or `false` means separate Spaces are on.
    /// (`NSScreen.screensHaveSeparateSpaces` is not used: it reports `false`
    /// in processes that have not bootstrapped AppKit, e.g. `ballast doctor`.
    /// The doctor cross-checks the live state via SkyLight display identifiers.)
    public static var displaysHaveSeparateSpaces: Bool {
        !freshBool("spans-displays", domain: spacesDomain, default: false)
    }

    /// "Automatically rearrange Spaces based on most recent use" —
    /// `com.apple.dock` `mru-spaces`, defaulting to `true` (the macOS
    /// default) when absent.
    public static var autoRearrangeSpaces: Bool {
        freshBool("mru-spaces", domain: dockDomain, default: true)
    }

    /// Stage Manager — `com.apple.WindowManager` `GloballyEnabled`,
    /// defaulting to `false` when absent.
    public static var stageManagerEnabled: Bool {
        freshBool("GloballyEnabled", domain: windowManagerDomain, default: false)
    }

    public static var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    /// Dock "Assign To" bindings from `com.apple.spaces` `app-bindings`:
    /// lowercased bundle id -> Space UUID string. Entries bound to all
    /// desktops (`"AllSpaces"` or an empty value) are omitted, since they
    /// carry no per-Space placement information.
    public static func appBindings() -> [String: String] {
        CFPreferencesAppSynchronize(spacesDomain)
        guard
            let raw = CFPreferencesCopyValue("app-bindings" as CFString, spacesDomain, currentUser, anyHost)
                as? [String: AnyObject]
        else {
            return [:]
        }

        var bindings: [String: String] = [:]
        for (bundleID, value) in raw {
            guard let uuid = value as? String else { continue }
            if uuid.isEmpty || uuid == "AllSpaces" { continue }
            bindings[bundleID.lowercased()] = uuid
        }
        return bindings
    }

    public static var macOSVersion: OperatingSystemVersion {
        ProcessInfo.processInfo.operatingSystemVersion
    }
}
