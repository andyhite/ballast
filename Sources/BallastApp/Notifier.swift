import Foundation
import UserNotifications
import os

/// Best-effort user notifications.
///
/// `UNUserNotificationCenter` traps when the host binary has no bundle
/// identifier (a bare CLI executable, as opposed to a proper `.app`), so
/// this only uses it when `Bundle.main.bundleIdentifier` is non-nil.
/// Otherwise it shells out to `osascript` to post a Notification Center
/// banner. Never throws and never blocks the calling thread.
public enum Notifier {
    private static let logger = Logger(subsystem: "dev.ballast", category: "notifier")
    private static let authorizationLock = NSLock()
    private static var authorizationState: AuthorizationState = .notRequested
    private static var pendingRequests: [UNNotificationRequest] = []

    private enum AuthorizationState {
        case notRequested
        case pending
        case authorized
        case denied
    }

    /// Posts a best-effort notification. Safe to call from any thread.
    public static func post(title: String, body: String) {
        if Bundle.main.bundleIdentifier != nil {
            postViaUserNotifications(title: title, body: body)
        } else {
            postViaOSAScript(title: title, body: body)
        }
    }

    private static func postViaUserNotifications(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body

        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)

        authorizationLock.lock()
        switch authorizationState {
        case .authorized:
            authorizationLock.unlock()
            addRequest(request)
        case .denied:
            authorizationLock.unlock()
        case .pending:
            pendingRequests.append(request)
            authorizationLock.unlock()
        case .notRequested:
            authorizationState = .pending
            pendingRequests.append(request)
            authorizationLock.unlock()
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
                if let error {
                    logger.error("notification authorization request failed: \(error.localizedDescription, privacy: .public)")
                } else if !granted {
                    logger.notice("notification authorization was denied")
                }

                authorizationLock.lock()
                authorizationState = granted ? .authorized : .denied
                let queued = pendingRequests
                pendingRequests.removeAll()
                authorizationLock.unlock()

                if granted {
                    for queued in queued {
                        addRequest(queued)
                    }
                }
            }
        }
    }

    private static func addRequest(_ request: UNNotificationRequest) {
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                logger.error("failed to post notification: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private static func postViaOSAScript(title: String, body: String) {
        let script = "display notification \(appleScriptStringLiteral(body)) with title \(appleScriptStringLiteral(title))"

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            logger.error("failed to launch osascript: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Renders `value` as a double-quoted AppleScript string literal,
    /// escaping backslashes and double quotes.
    private static func appleScriptStringLiteral(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }
}
