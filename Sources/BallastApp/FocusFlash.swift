import AppKit
import BallastCore

/// The border that marks the focused window. A Ballast command that moves
/// focus flashes it: full opacity, then a fade over the flash's last part.
/// Holding the hold modifier shows it until release; a release with no flash
/// running hides it at once. One borderless, click-through window at the
/// floating level, so the app raise that follows a focus change never covers
/// it. Created on first use and reused; shows on whichever Space is active.
final class FocusFlash {
    private var window: NSWindow?
    /// The window the border marks while it is up.
    private(set) var target: WindowID?
    private var held = false
    /// A command's flash is at full opacity: its timer, not the hold, decides when to hide.
    private var flashing = false
    /// The border is fading out; its timer hides the window.
    private var fading = false
    /// A command's flash ended while the hold modifier was down: its fade
    /// plays on release instead of the border vanishing.
    private var fadeOnRelease: TimeInterval?
    private var timer: DispatchWorkItem?

    /// Longest fade; shorter flashes fade over their last 40%.
    private static let maxFade: TimeInterval = 0.3
    private static let borderWidth: CGFloat = 4

    /// `frame` is AX/CG global (top-left origin), like every planned frame.
    /// `fade = false` (Reduce Motion) hides without animating.
    func flash(_ id: WindowID, frame: CGRect, duration: TimeInterval, fade: Bool) {
        cancelTimer()
        target = id
        flashing = true
        present(frame)
        let fadeTime = fade ? min(Self.maxFade, duration * 0.4) : 0
        schedule(after: duration - fadeTime) { [weak self] in
            guard let self else { return }
            flashing = false
            if held { fadeOnRelease = fadeTime } else { dismiss(fade: fadeTime) }
        }
    }

    /// The hold modifier went down, or focus moved while it is down.
    func hold(_ id: WindowID, frame: CGRect) {
        held = true
        target = id
        if fading { cancelTimer() }
        present(frame)
    }

    /// The hold modifier went up. A command's flash still running hides the
    /// border on its own timer; one that ended during the hold fades now;
    /// otherwise the border vanishes at once.
    func release() {
        held = false
        if flashing || fading { return }
        if let fade = fadeOnRelease { cancelTimer(); dismiss(fade: fade) } else { hide() }
    }

    /// The marked window moved (a layout pass, or its frame settled).
    func move(to frame: CGRect) {
        guard let window, window.isVisible, let primary = NSScreen.screens.first else { return }
        window.setFrame(Self.borderFrame(frame, primaryHeight: primary.frame.height), display: true)
    }

    func hide() {
        cancelTimer()
        target = nil
        window?.contentView?.layer?.removeAllAnimations()
        window?.orderOut(nil)
    }

    private func present(_ frame: CGRect) {
        guard let primary = NSScreen.screens.first else { return }
        let window = self.window ?? Self.makeWindow()
        self.window = window
        // The real frame is set before ordering in (see DropPreview).
        window.setFrame(Self.borderFrame(frame, primaryHeight: primary.frame.height), display: true)
        if let layer = window.contentView?.layer {
            layer.removeAllAnimations()
            layer.opacity = 1
            // The accent color can change between flashes.
            window.effectiveAppearance.performAsCurrentDrawingAppearance {
                layer.borderColor = NSColor.controlAccentColor.cgColor
            }
        }
        window.orderFrontRegardless()
    }

    private func dismiss(fade: TimeInterval) {
        guard fade > 0, let layer = window?.contentView?.layer else { hide(); return }
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = 1
        animation.toValue = 0
        animation.duration = fade
        animation.timingFunction = CAMediaTimingFunction(name: .easeIn)
        layer.opacity = 0
        layer.add(animation, forKey: "fade")
        // A timer, not the animation's delegate, so `cancelTimer` stops both.
        fading = true
        schedule(after: fade) { [weak self] in self?.hide() }
    }

    private func schedule(after delay: TimeInterval, _ work: @escaping () -> Void) {
        let item = DispatchWorkItem(block: work)
        timer = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    private func cancelTimer() {
        timer?.cancel()
        timer = nil
        flashing = false
        fading = false
        fadeOnRelease = nil
    }

    /// Straddles the window's edge: half the border outside, half over it.
    private static func borderFrame(_ frame: CGRect, primaryHeight: CGFloat) -> CGRect {
        frame.insetBy(dx: -borderWidth / 2, dy: -borderWidth / 2).flipped(primaryHeight: primaryHeight)
    }

    private static func makeWindow() -> NSWindow {
        let window = Overlay.makeWindow()
        window.level = .floating
        window.contentView?.layer?.borderWidth = borderWidth
        window.contentView?.layer?.cornerRadius += borderWidth / 2
        return window
    }
}
