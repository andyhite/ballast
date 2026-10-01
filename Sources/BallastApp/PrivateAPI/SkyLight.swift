// SkyLight.swift
//
// ⚠️ PRIVATE API — READ ONLY — THE ONLY FILE IN THIS PROJECT ALLOWED TO
// TOUCH UNDOCUMENTED SYMBOLS.
//
// Everything below resolves and calls private SkyLight / HIServices
// symbols via dlopen/dlsym. Apple can rename, resign, or remove any of
// these symbols in any macOS release without notice — there is no ABI
// contract. Ballast never *writes* to Spaces through this API (no
// SLSMoveWindowsToManagedSpace, no space creation/destruction); it only
// reads state. SIP is never touched, no entitlements are required, no
// process injection happens.
//
// Degradation path: `SkyLightSpaceProvider.make()` resolves every symbol
// up front and returns `.failure(MissingPrivateSymbols)` if any are
// missing, instead of trapping. `Doctor` surfaces per-symbol resolution
// status so a user can diagnose a broken macOS update without a crash
// report. Every dynamic cast in this file is conditional; malformed data
// from SkyLight is treated as "unknown", never force-unwrapped.

import ApplicationServices
import BallastCore
import Foundation

/// Whether one private symbol resolved via `dlsym`.
public struct PrivateSymbolStatus: Sendable {
    public let name: String
    public let resolved: Bool
}

/// Thrown (as an `Error`, never trapped) when one or more required private
/// symbols failed to resolve at startup.
public struct MissingPrivateSymbols: Error, CustomStringConvertible {
    public let names: [String]

    public var description: String {
        "missing private symbols: \(names.joined(separator: ", "))"
    }
}

/// Space provider backed by private SkyLight calls plus one
/// private HIServices call (`_AXUIElementGetWindow`). Read-only: no symbol
/// resolved here ever mutates Space membership or window placement.
// Sendable: every stored property is an immutable let (C function pointers, connection id).
public final class SkyLightSpaceProvider: Sendable {

    // MARK: - C function signatures

    private typealias SLSMainConnectionIDFn = @convention(c) () -> Int32
    private typealias SLSCopyManagedDisplaySpacesFn = @convention(c) (Int32) -> Unmanaged<CFArray>?
    private typealias SLSCopySpacesForWindowsFn = @convention(c) (Int32, Int32, CFArray) -> Unmanaged<CFArray>?
    private typealias SLSCopyWindowsWithOptionsAndTagsFn = @convention(c) (
        Int32, UInt32, CFArray, UInt32, UnsafeMutablePointer<UInt64>, UnsafeMutablePointer<UInt64>
    ) -> Unmanaged<CFArray>?
    private typealias AXUIElementGetWindowFn = @convention(c) (AXUIElement, UnsafeMutablePointer<UInt32>) -> AXError

    // MARK: - Resolved symbols

    private let slsMainConnectionID: SLSMainConnectionIDFn
    private let slsCopyManagedDisplaySpaces: SLSCopyManagedDisplaySpacesFn
    private let slsCopySpacesForWindows: SLSCopySpacesForWindowsFn
    private let slsCopyWindowsWithOptionsAndTags: SLSCopyWindowsWithOptionsAndTagsFn
    private let axUIElementGetWindow: AXUIElementGetWindowFn

    /// Connection id, resolved once and cached for the lifetime of the process.
    private let connectionID: Int32

    private init(
        slsMainConnectionID: @escaping SLSMainConnectionIDFn,
        slsCopyManagedDisplaySpaces: @escaping SLSCopyManagedDisplaySpacesFn,
        slsCopySpacesForWindows: @escaping SLSCopySpacesForWindowsFn,
        slsCopyWindowsWithOptionsAndTags: @escaping SLSCopyWindowsWithOptionsAndTagsFn,
        axUIElementGetWindow: @escaping AXUIElementGetWindowFn
    ) {
        self.slsMainConnectionID = slsMainConnectionID
        self.slsCopyManagedDisplaySpaces = slsCopyManagedDisplaySpaces
        self.slsCopySpacesForWindows = slsCopySpacesForWindows
        self.slsCopyWindowsWithOptionsAndTags = slsCopyWindowsWithOptionsAndTags
        self.axUIElementGetWindow = axUIElementGetWindow
        self.connectionID = slsMainConnectionID()
    }

    // MARK: - Symbol table

    private static let skyLightPath = "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight"

    private static let requiredSymbolNames = [
        "SLSMainConnectionID",
        "SLSCopyManagedDisplaySpaces",
        "SLSCopySpacesForWindows",
        "SLSCopyWindowsWithOptionsAndTags",
        "_AXUIElementGetWindow",
    ]

    /// Opens SkyLight (and the default image for `_AXUIElementGetWindow`,
    /// which lives in HIServices) and resolves each address. Never opens a
    /// handle it does not also close on failure; leaves the process state
    /// untouched otherwise.
    private static func resolveSymbol(_ name: String, handle: UnsafeMutableRawPointer?) -> UnsafeMutableRawPointer? {
        guard let handle else { return nil }
        return dlsym(handle, name)
    }

    /// Resolution status of every required symbol, independent of whether
    /// `make()` would succeed as a whole. Used by `Doctor`.
    public static func symbolStatus() -> [PrivateSymbolStatus] {
        let skyLightHandle = dlopen(skyLightPath, RTLD_LAZY)
        defer { if let skyLightHandle { dlclose(skyLightHandle) } }
        // RTLD_DEFAULT searches every already-loaded image (HIServices among
        // them) without opening a new handle.
        let defaultHandle = dlopen(nil, RTLD_LAZY)
        defer { if let defaultHandle { dlclose(defaultHandle) } }

        return requiredSymbolNames.map { name in
            let handle = name.hasPrefix("_AX") ? defaultHandle : skyLightHandle
            let resolved = resolveSymbol(name, handle: handle) != nil
            return PrivateSymbolStatus(name: name, resolved: resolved)
        }
    }

    /// Resolves every required symbol and constructs a provider, or returns
    /// the list of symbols that failed to resolve. Never traps.
    public static func make() -> Result<SkyLightSpaceProvider, MissingPrivateSymbols> {
        guard let skyLightHandle = dlopen(skyLightPath, RTLD_LAZY) else {
            // `_AXUIElementGetWindow` comes from HIServices, not SkyLight; it
            // never fails to resolve merely because SkyLight failed to open.
            return .failure(MissingPrivateSymbols(names: requiredSymbolNames.filter { !$0.hasPrefix("_AX") }))
        }
        // Kept open for the provider's lifetime: symbol addresses resolved
        // from this handle must remain valid for as long as the provider is
        // used. `Doctor` may call `make()` again in-process (for example when
        // rerunning diagnostics); each call opens, and on failure closes,
        // its own handle.
        guard let defaultHandle = dlopen(nil, RTLD_LAZY) else {
            dlclose(skyLightHandle)
            return .failure(MissingPrivateSymbols(names: requiredSymbolNames))
        }

        var missing: [String] = []

        func resolve<T>(_ name: String, in handle: UnsafeMutableRawPointer?, as type: T.Type) -> T? {
            guard let address = resolveSymbol(name, handle: handle) else {
                missing.append(name)
                return nil
            }
            return unsafeBitCast(address, to: T.self)
        }

        let mainConnectionID = resolve("SLSMainConnectionID", in: skyLightHandle, as: SLSMainConnectionIDFn.self)
        let copyManagedDisplaySpaces = resolve(
            "SLSCopyManagedDisplaySpaces", in: skyLightHandle, as: SLSCopyManagedDisplaySpacesFn.self)
        let copySpacesForWindows = resolve(
            "SLSCopySpacesForWindows", in: skyLightHandle, as: SLSCopySpacesForWindowsFn.self)
        let copyWindowsWithOptionsAndTags = resolve(
            "SLSCopyWindowsWithOptionsAndTags", in: skyLightHandle, as: SLSCopyWindowsWithOptionsAndTagsFn.self)
        let axGetWindow = resolve("_AXUIElementGetWindow", in: defaultHandle, as: AXUIElementGetWindowFn.self)

        guard !missing.isEmpty else {
            guard let mainConnectionID, let copyManagedDisplaySpaces,
                let copySpacesForWindows, let copyWindowsWithOptionsAndTags, let axGetWindow
            else {
                // Defensive: should be unreachable given `missing.isEmpty`, but
                // never force-unwrap.
                dlclose(skyLightHandle)
                return .failure(MissingPrivateSymbols(names: requiredSymbolNames))
            }
            let provider = SkyLightSpaceProvider(
                slsMainConnectionID: mainConnectionID,
                slsCopyManagedDisplaySpaces: copyManagedDisplaySpaces,
                slsCopySpacesForWindows: copySpacesForWindows,
                slsCopyWindowsWithOptionsAndTags: copyWindowsWithOptionsAndTags,
                axUIElementGetWindow: axGetWindow
            )
            return .success(provider)
        }

        dlclose(skyLightHandle)
        return .failure(MissingPrivateSymbols(names: missing))
    }

    // MARK: - Queries

    /// Display and Space layout. Nil when SkyLight returned malformed data.
    /// MAIN THREAD ONLY: reads `DisplayInfo.current()`, which uses `NSScreen.screens`.
    public func snapshot() -> SpaceSnapshot? {
        guard let managed = slsCopyManagedDisplaySpaces(connectionID)?.takeRetainedValue() as? [AnyObject] else {
            return nil
        }
        let builtin = DisplayInfo.builtinUUIDs()
        let small = Set(DisplayInfo.current().filter { $0.visibleFrame.width < LayoutSettings.smallWidth }.map(\.uuid))
        return Self.parse(managed, builtin: builtin, small: small)
    }

    /// Pure parse of `SLSCopyManagedDisplaySpaces`'s array. Entries without a
    /// display identifier or Space id are skipped, never trapped on.
    static func parse(_ managed: [AnyObject], builtin: Set<String>, small: Set<String>) -> SpaceSnapshot {
        var displays: [DisplaySpaces] = []
        displays.reserveCapacity(managed.count)

        for entry in managed {
            guard let dict = entry as? [String: AnyObject] else { continue }
            // Uppercased so it matches CGDisplayCreateUUIDFromDisplayID strings and config keys.
            guard let displayUUID = (dict["Display Identifier"] as? String)?.uppercased() else { continue }

            let activeSpaceID: SpaceID? = {
                guard let current = dict["Current Space"] as? [String: AnyObject] else { return nil }
                return spaceID(fromEntry: current)
            }()

            var spaces: [SpaceInfo] = []
            for rawSpace in (dict["Spaces"] as? [AnyObject]) ?? [] {
                guard let spaceDict = rawSpace as? [String: AnyObject], let id = spaceID(fromEntry: spaceDict) else { continue }
                let uuid = (spaceDict["uuid"] as? String) ?? ""
                let rawType = (spaceDict["type"] as? NSNumber)?.intValue ?? 0
                spaces.append(SpaceInfo(id: id, uuid: uuid, kind: SpaceKind(rawType: rawType)))
            }

            displays.append(DisplaySpaces(displayUUID: displayUUID, spaces: spaces, activeSpace: activeSpaceID,
                                          builtin: builtin.contains(displayUUID), small: small.contains(displayUUID)))
        }

        return SpaceSnapshot(displays: displays)
    }

    /// The Space currently shown on each display. Read live with no display
    /// metadata, so safe off the main thread (`discoverWindows` calls it from
    /// per-app worker queues). Nil when SkyLight returned malformed data.
    public func activeSpaceIDs() -> Set<SpaceID>? {
        guard let managed = slsCopyManagedDisplaySpaces(connectionID)?.takeRetainedValue() as? [AnyObject] else {
            return nil
        }
        var active = Set<SpaceID>()
        for entry in managed {
            guard let dict = entry as? [String: AnyObject],
                  let current = dict["Current Space"] as? [String: AnyObject],
                  let id = Self.spaceID(fromEntry: current) else { continue }
            active.insert(id)
        }
        return active
    }

    /// Extracts a Space id from a SkyLight dictionary, trying both known keys.
    private static func spaceID(fromEntry dict: [String: AnyObject]) -> SpaceID? {
        if let number = dict["ManagedSpaceID"] as? NSNumber {
            return number.uint64Value
        }
        if let number = dict["id64"] as? NSNumber {
            return number.uint64Value
        }
        return nil
    }

    /// Ids of every window on `space`: all levels and owners, on screen or
    /// not. Empty when SkyLight returned malformed data. Any thread.
    public func windowIDs(onSpace space: SpaceID) -> [WindowID] {
        let spaceArray = [NSNumber(value: space)] as CFArray
        var setTags: UInt64 = 0
        var clearTags: UInt64 = 0
        guard
            let result = slsCopyWindowsWithOptionsAndTags(
                connectionID, 0, spaceArray, 0x2, &setTags, &clearTags
            )?.takeRetainedValue() as? [AnyObject]
        else {
            return []
        }
        return result.compactMap { ($0 as? NSNumber)?.uint32Value }
    }

    /// Spaces `window` is on: more than one only for a sticky window (shown
    /// on every Space); empty when unknown. Any thread.
    public func spaces(forWindow window: WindowID) -> [SpaceID] {
        let windowArray = [NSNumber(value: window)] as CFArray
        guard
            let result = slsCopySpacesForWindows(connectionID, 0x7, windowArray)?.takeRetainedValue() as? [AnyObject]
        else {
            return []
        }
        return result.compactMap { ($0 as? NSNumber)?.uint64Value }
    }

    /// The window id behind an AX window element; nil when it has none. Any thread.
    public func windowID(for element: AXUIElement) -> WindowID? {
        var windowID: UInt32 = 0
        let error = axUIElementGetWindow(element, &windowID)
        guard error == .success, windowID != 0 else { return nil }
        return windowID
    }
}
