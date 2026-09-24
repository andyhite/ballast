import ApplicationServices
import BallastCore

/// The *only* seam through which the window manager learns about native
/// Spaces. The sole production implementation (`SkyLightSpaceProvider`,
/// in `PrivateAPI/SkyLight.swift`) wraps private, read-only SkyLight calls.
/// Nothing outside that file may reference a private symbol.
public protocol SpaceProvider: AnyObject {
    /// Every display's Spaces plus the active Space per display.
    /// `nil` when SkyLight returned malformed data.
    func snapshot() -> SpaceSnapshot?
    /// Window ids that live on `space` (all levels/owners, onscreen or not).
    func windowIDs(onSpace space: SpaceID) -> [WindowID]
    /// Spaces a single window belongs to (more than one only for sticky windows).
    func spaces(forWindow window: WindowID) -> [SpaceID]
    /// `CGWindowID` backing an Accessibility window element.
    func windowID(for element: AXUIElement) -> WindowID?
}
