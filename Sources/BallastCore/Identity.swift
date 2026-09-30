import Foundation

/// A `CGWindowID`. Stable for the lifetime of the window.
public typealias WindowID = UInt32

/// A SkyLight managed-space id (`id64` / `ManagedSpaceID`). Stable for the
/// login session only and cheap to compare, so it is the runtime key for all
/// live state. Never persisted: use `SpaceAddress` for anything on disk.
public typealias SpaceID = UInt64

/// Runtime identity of a user desktop: which display it is on, where it sits
/// in Mission Control order, and its Space UUID (from `com.apple.spaces`).
///
/// The ordinal is the 1-based position among that display's *user* desktops
/// (native-fullscreen Spaces are not counted, so full-screening an app never
/// shifts ordinals). `uuid` is empty when SkyLight reports none. Equality
/// covers all three fields; config lookups go through `addresses`.
public struct SpaceKey: Hashable, Comparable, Sendable, CustomStringConvertible {
    public let display: String
    public let ordinal: Int
    public let uuid: String

    public init(display: String, ordinal: Int, uuid: String = "") {
        self.display = display
        self.ordinal = ordinal
        self.uuid = uuid
    }

    public static func < (a: SpaceKey, b: SpaceKey) -> Bool {
        a.display == b.display ? a.ordinal < b.ordinal : a.display < b.display
    }

    public var description: String { "\(display)#\(ordinal)" }

    /// Config addresses that can refer to this desktop, most stable first:
    /// its Space UUID (follows the desktop when Mission Control reorders),
    /// then its display + ordinal.
    public var addresses: [SpaceAddress] {
        let position = SpaceAddress.position(display: display, ordinal: ordinal)
        return uuid.isEmpty ? [position] : [.uuid(uuid), position]
    }

    /// The address new config entries are written under.
    public var preferredAddress: SpaceAddress { addresses[0] }
}

/// How a `[[space]]` config entry names a desktop. Persisted, so it must not
/// use a `SpaceID`.
public enum SpaceAddress: Hashable, Comparable, Sendable, CustomStringConvertible {
    /// The desktop's Space UUID; survives reordering and reboots.
    case uuid(String)
    /// The display's persistent UUID plus the desktop's 1-based ordinal.
    case position(display: String, ordinal: Int)

    public static func < (a: SpaceAddress, b: SpaceAddress) -> Bool { a.description < b.description }

    public var description: String {
        switch self {
        case .uuid(let uuid): return uuid
        case .position(let display, let ordinal): return "\(display)#\(ordinal)"
        }
    }
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
    /// A built-in (laptop) display.
    public let builtin: Bool
    /// Visible frame narrower than `LayoutSettings.smallWidth` points; picks
    /// the built-in layout defaults. The platform computes it; false (a large
    /// screen) when not given.
    public let small: Bool

    public init(displayUUID: String, spaces: [SpaceInfo], activeSpace: SpaceID?, builtin: Bool = false, small: Bool = false) {
        self.displayUUID = displayUUID
        self.spaces = spaces
        self.activeSpace = activeSpace
        self.builtin = builtin
        self.small = small
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
                    return SpaceKey(display: display.displayUUID, ordinal: ordinal, uuid: info.uuid)
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

    public func isSmall(display uuid: String) -> Bool {
        displays.first { $0.displayUUID == uuid }?.small ?? false
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
