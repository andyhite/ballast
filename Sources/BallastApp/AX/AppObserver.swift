import ApplicationServices
import BallastCore

protocol AppObserverDelegate: AnyObject {
    /// Main thread. `element` is the element the notification is about.
    func appObserver(_ observer: AppObserver, received notification: String, element: AXUIElement)
}

/// Subscribes to Accessibility notifications of one process. Callbacks arrive
/// on the main run loop. No polling: everything is push-based.
final class AppObserver {
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
    weak var delegate: AppObserverDelegate?

    init(pid: pid_t, bundleID: String?, name: String?, notifications: [String] = AppObserver.appNotifications) {
        self.pid = pid
        self.app = AXUIElementCreateApplication(pid)
        self.bundleID = bundleID
        self.name = name
        self.notifications = notifications
        AXUIElementSetMessagingTimeout(app, AX.messagingTimeout)
    }

    deinit { stop() }

    /// Creates the observer and subscribes app-level notifications. Returns
    /// false when the process is not accessible yet (still launching) so the
    /// caller can retry a bounded number of times.
    func start() -> Bool {
        guard observer == nil else { return true }
        var created: AXObserver?
        guard AXObserverCreate(pid, axObserverCallback, &created) == .success, let created else { return false }
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        var subscribed = 0
        for name in notifications {
            let result = AXObserverAddNotification(created, app, name as CFString, refcon)
            if result == .success || result == .notificationAlreadyRegistered { subscribed += 1 }
        }
        guard subscribed > 0 else { return false }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(created), .commonModes)
        observer = created
        return true
    }

    /// Subscribes per-window notifications. Returns false when the essential
    /// destroyed notification could not be registered (the window would
    /// otherwise become a phantom tile).
    func observe(window: AXUIElement) -> Bool {
        guard let observer else { return false }
        AXUIElementSetMessagingTimeout(window, AX.messagingTimeout)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        var destroyedRegistered = false
        for name in Self.windowNotifications {
            let result = AXObserverAddNotification(observer, window, name as CFString, refcon)
            if name == kAXUIElementDestroyedNotification {
                destroyedRegistered = result == .success || result == .notificationAlreadyRegistered
            }
        }
        return destroyedRegistered
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
        delegate?.appObserver(self, received: notification, element: element)
    }
}

private func axObserverCallback(_ observer: AXObserver, _ element: AXUIElement, _ notification: CFString,
                                _ refcon: UnsafeMutableRawPointer?) {
    guard let refcon else { return }
    let target = Unmanaged<AppObserver>.fromOpaque(refcon).takeUnretainedValue()
    target.deliver(notification as String, element: element)
}
