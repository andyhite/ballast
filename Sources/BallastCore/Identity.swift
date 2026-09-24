import Foundation

/// A `CGWindowID`. Stable for the lifetime of the window.
public typealias WindowID = UInt32

/// A SkyLight managed-space id. Stable for the login session only — never
/// persisted, never used for config addressing.
public typealias SpaceID = UInt64

/// Stable config address of a physical (display, macOS Space) pair:
/// the display's persistent UUID plus the 1-based ordinal of the Space among
/// that display's *user* desktops (native-fullscreen Spaces are not counted,
/// so full-screening an app never shifts ordinals).
public struct SpaceKey: Hashable, Comparable, Sendable, CustomStringConvertible {
    public let display: String
    public let ordinal: Int

    public init(display: String, ordinal: Int) {
        self.display = display
        self.ordinal = ordinal
    }

    public static func < (a: SpaceKey, b: SpaceKey) -> Bool {
        a.display == b.display ? a.ordinal < b.ordinal : a.display < b.display
    }

    public var description: String { "\(display)#\(ordinal)" }
}

/// Kind of a macOS Space as reported by `SLSCopyManagedDisplaySpaces`
/// (`type` key: 0 = user desktop, 4 = native fullscreen).
public enum SpaceKind: Equatable, Sendable {
    case user
    case fullscreen
    case other(Int)

    public init(rawType: Int) {
        switch rawType {
        case 0: self = .user
        case 4: self = .fullscreen
        default: self = .other(rawType)
        }
    }
}

public struct SpaceInfo: Equatable, Sendable {
    public let id: SpaceID
    /// Space UUID string (what `com.apple.spaces` app-bindings reference).
    public let uuid: String
    public let kind: SpaceKind

    public init(id: SpaceID, uuid: String, kind: SpaceKind) {
        self.id = id
        self.uuid = uuid
        self.kind = kind
    }
}

public struct DisplaySpaces: Equatable, Sendable {
    /// Display UUID ("Display Identifier"); `"Main"` when "Displays have
    /// separate Spaces" is off.
    public let displayUUID: String
    /// All Spaces of the display, in Mission Control order.
    public let spaces: [SpaceInfo]
    public let activeSpace: SpaceID?
    /// A built-in (laptop) display; it gets `master_stack` unless the config
    /// says otherwise.
    public let builtin: Bool

    public init(displayUUID: String, spaces: [SpaceInfo], activeSpace: SpaceID?, builtin: Bool = false) {
        self.displayUUID = displayUUID
        self.spaces = spaces
        self.activeSpace = activeSpace
        self.builtin = builtin
    }
}

/// Point-in-time view of every display's Spaces. Pure data; built by the
/// platform `SpaceProvider`, consumed by the engine and tests.
public struct SpaceSnapshot: Equatable, Sendable {
    public let displays: [DisplaySpaces]

    public init(displays: [DisplaySpaces]) {
        self.displays = displays
    }

    /// Config key for a Space; `nil` for fullscreen/unknown Spaces.
    public func key(for space: SpaceID) -> SpaceKey? {
        for display in displays {
            var ordinal = 0
            for info in display.spaces where info.kind == .user {
                ordinal += 1
                if info.id == space {
                    return SpaceKey(display: display.displayUUID, ordinal: ordinal)
                }
            }
        }
        return nil
    }

    public func spaceID(for key: SpaceKey) -> SpaceID? {
        guard let display = displays.first(where: { $0.displayUUID == key.display }) else { return nil }
        var ordinal = 0
        for info in display.spaces where info.kind == .user {
            ordinal += 1
            if ordinal == key.ordinal { return info.id }
        }
        return nil
    }

    /// Resolves a Space UUID (as used by Dock app-bindings) to its Space id.
    public func spaceID(forUUID uuid: String) -> SpaceID? {
        for display in displays {
            if let info = display.spaces.first(where: { $0.uuid == uuid }) { return info.id }
        }
        return nil
    }

    public func isFullscreen(_ space: SpaceID) -> Bool {
        displays.contains { $0.spaces.contains { $0.id == space && $0.kind == .fullscreen } }
    }

    public func isActive(_ space: SpaceID) -> Bool {
        displays.contains { $0.activeSpace == space }
    }

    public func activeSpace(ofDisplay uuid: String) -> SpaceID? {
        displays.first { $0.displayUUID == uuid }?.activeSpace
    }

    public func isBuiltin(display uuid: String) -> Bool {
        displays.first { $0.displayUUID == uuid }?.builtin ?? false
    }

    /// Every user-desktop Space id currently known.
    public var userSpaceIDs: Set<SpaceID> {
        var result = Set<SpaceID>()
        for display in displays {
            for info in display.spaces where info.kind == .user { result.insert(info.id) }
        }
        return result
    }
}
