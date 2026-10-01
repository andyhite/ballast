@preconcurrency import ApplicationServices
import BallastCore

/// Subscribes to Accessibility notifications of one process. Callbacks arrive
/// on the main run loop. No polling: everything is push-based.
// @unchecked Sendable: lets are immutable; `observer`/`onNotification` are only touched on the main thread.
final class AppObserver: @unchecked Sendable {
    static let appNotifications = [
        kAXWindowCreatedNotification, kAXFocusedWindowChangedNotification, kAXMainWindowChangedNotification,
    ]
    static let windowNotifications = [
        kAXUIElementDestroyedNotification, kAXMovedNotification, kAXResizedNotification,
        kAXWindowMiniaturizedNotification, kAXWindowDeminiaturizedNotification, kAXTitleChangedNotification,
    ]
    /// Mission Control enter/exit, posted by Dock.app.
    static let dockNotifications = ["AXExposeShowAllWindows", "AXExposeShowFrontWindows", "AXExposeShowDesktop", "AXExposeExit"]

    let pid: pid_t
    let app: AXUIElement
    let bundleID: String?
    let name: String?
    private let notifications: [String]
    private var observer: AXObserver?
    /// Main thread. `element` is the element the notification is about.
    /// Capture the owner weakly: the owner holds this observer.
    var onNotification: (@MainActor (AppObserver, String, AXUIElement) -> Void)?

    init(pid: pid_t, bundleID: String?, name: String?, notifications: [String] = AppObserver.appNotifications) {
        self.pid = pid
        self.app = AXUIElementCreateApplication(pid)
        self.bundleID = bundleID
        self.name = name
        self.notifications = notifications
        AXUIElementSetMessagingTimeout(app, AX.messagingTimeout)
    }

    deinit { stop() }

    /// Creates the observer and subscribes app-level notifications, then
    /// installs it. Main thread; blocks on AX, so only for the Dock. Apps
    /// use `subscribe()` on their worker plus `install(_:)`.
    func start() -> Bool {
        guard observer == nil else { return true }
        guard let created = subscribe() else { return false }
        install(created)
        return true
    }

    /// Creates an observer and subscribes app-level notifications. Any
    /// thread (AX round trips, up to the messaging timeout each). Returns nil
    /// when the process is not accessible yet (still launching), so the
    /// caller can retry a bounded number of times. Stops at the first
    /// `.cannotComplete`: an unresponsive process would time out on every
    /// remaining call too.
    func subscribe() -> AXObserver? {
        var created: AXObserver?
        guard AXObserverCreate(pid, axObserverCallback, &created) == .success, let created else { return nil }
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        var subscribed = 0
        for name in notifications {
            let result = AXObserverAddNotification(created, app, name as CFString, refcon)
            if result == .cannotComplete { return nil }
            if result == .success || result == .notificationAlreadyRegistered { subscribed += 1 }
        }
        return subscribed > 0 ? created : nil
    }

    /// Main thread: starts delivering `created`'s notifications on the main run loop.
    func install(_ created: AXObserver) {
        guard observer == nil else { return }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(created), .commonModes)
        observer = created
    }

    /// The installed observer; read on main, hand to workers for `register(window:in:)`.
    var installed: AXObserver? { observer }

    /// Subscribes per-window notifications. Returns false when the essential
    /// destroyed notification could not be registered (the window would
    /// otherwise become a phantom tile).
    func observe(window: AXUIElement) -> Bool {
        guard let observer else { return false }
        return register(window: window, in: observer)
    }

    /// Any thread. The destroyed notification goes first and a failure
    /// there returns immediately; a process that cannot complete it would
    /// time out on each of the other five too.
    func register(window: AXUIElement, in observer: AXObserver) -> Bool {
        AXUIElementSetMessagingTimeout(window, AX.messagingTimeout)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        for name in Self.windowNotifications {
            let result = AXObserverAddNotification(observer, window, name as CFString, refcon)
            let ok = result == .success || result == .notificationAlreadyRegistered
            if name == kAXUIElementDestroyedNotification, !ok { return false }
            if result == .cannotComplete { break }
        }
        return true
    }

    func unobserve(window: AXUIElement) {
        guard let observer else { return }
        for name in Self.windowNotifications {
            AXObserverRemoveNotification(observer, window, name as CFString)
        }
    }

    func stop() {
        guard let observer else { return }
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        self.observer = nil
    }

    var windows: [AXUIElement] { AX.elements(app, kAXWindowsAttribute) }
    var focusedWindow: AXUIElement? { AX.element(app, kAXFocusedWindowAttribute) }

    fileprivate func deliver(_ notification: String, element: AXUIElement) {
        // Callback runs on the main run loop (see `install`).
        MainActor.assumeIsolated { onNotification?(self, notification, element) }
    }
}

private func axObserverCallback(_ observer: AXObserver, _ element: AXUIElement, _ notification: CFString,
                                _ refcon: UnsafeMutableRawPointer?) {
    guard let refcon else { return }
    let target = Unmanaged<AppObserver>.fromOpaque(refcon).takeUnretainedValue()
    target.deliver(notification as String, element: element)
}
