import AppKit
import BallastCore

/// The drop zone shown while the user drags a tile: the window it would swap
/// with, or its landing tile on another display. One borderless, click-through
/// window ordered directly below the dragged window, so it covers the tiles
/// underneath but never the window in hand. Created on first use and reused
/// for every drag; it never becomes key, shows on whichever Space is active,
/// and Mission Control hides it.
final class DropPreview {
    private var window: NSWindow?

    /// `frame` is AX/CG global (top-left origin), like every planned frame.
    func show(_ frame: CGRect, below dragged: WindowID) {
        guard let primary = NSScreen.screens.first else { return }
        let window = self.window ?? Self.makeWindow()
        self.window = window
        // The real frame is set before ordering in: a window first shown at a
        // zero frame on a display edge can join the neighbouring display's Space.
        window.setFrame(frame.flipped(primaryHeight: primary.frame.height), display: true)
        if !window.isVisible { Self.applyColors(to: window) } // the accent color can change between drags
        window.order(.below, relativeTo: Int(dragged))
    }

    func hide() {
        window?.orderOut(nil)
    }

    private static func makeWindow() -> NSWindow {
        let window = Overlay.makeWindow()
        // The tiles' level: a window can be ordered relative to another only
        // within the same level.
        window.level = .normal
        window.contentView?.layer?.borderWidth = 2
        return window
    }

    private static func applyColors(to window: NSWindow) {
        window.effectiveAppearance.performAsCurrentDrawingAppearance {
            let accent = NSColor.controlAccentColor
            window.contentView?.layer?.backgroundColor = accent.withAlphaComponent(0.2).cgColor
            window.contentView?.layer?.borderColor = accent.withAlphaComponent(0.8).cgColor
        }
    }
}

/// Borderless, click-through overlay windows drawn over other apps' windows.
enum Overlay {
    /// Never becomes key, shows on whichever Space is active, and Mission
    /// Control hides it. Its layer-backed content view has the system window
    /// corner radius; callers set the level, border, and colors.
    static func makeWindow() -> NSWindow {
        let window = NSWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: true)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none
        window.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle]
        let view = NSView()
        view.wantsLayer = true
        if #available(macOS 26, *) { view.layer?.cornerRadius = 16 } else { view.layer?.cornerRadius = 10 }
        window.contentView = view
        return window
    }
}
