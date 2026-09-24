import Carbon.HIToolbox
import BallastCore
import os

/// Registers global hotkeys via Carbon's `RegisterEventHotKey` and dispatches
/// presses back to a caller-supplied handler on the main thread.
///
/// Carbon hotkey registration has no AppKit/Cocoa replacement as of macOS 14
/// and remains the supported mechanism for system-wide hotkeys that work
/// even when the app isn't frontmost.
public final class HotKeyCenter {
    private static let logger = Logger(subsystem: "dev.ballast", category: "hotkeys")
    private static let signature: OSType = 0x626C_7374 // 'blst'

    /// Invoked on the main thread with the index into the array last passed
    /// to `setBindings`.
    private let handler: (Int) -> Void

    private var eventHandlerRef: EventHandlerRef?
    private var hotKeyRefs: [EventHotKeyRef] = []

    public init(handler: @escaping (Int) -> Void) {
        self.handler = handler
        installEventHandler()
    }

    deinit {
        removeAll()
        if let eventHandlerRef {
            RemoveEventHandler(eventHandlerRef)
        }
    }

    /// Replaces all registrations, unregistering any previous ones first.
    /// Returns human-readable failures, one per binding that could not be
    /// registered (e.g. "alt+h: already registered by another app").
    @discardableResult
    public func setBindings(_ hotkeys: [Hotkey]) -> [String] {
        removeAll()

        var failures: [String] = []
        for (index, hotkey) in hotkeys.enumerated() {
            let hotKeyID = EventHotKeyID(signature: Self.signature, id: UInt32(index))
            var hotKeyRef: EventHotKeyRef?
            let status = RegisterEventHotKey(
                hotkey.keyCode,
                Self.carbonModifiers(for: hotkey.modifiers),
                hotKeyID,
                GetApplicationEventTarget(),
                0,
                &hotKeyRef
            )

            if status == noErr, let hotKeyRef {
                hotKeyRefs.append(hotKeyRef)
            } else {
                let reason = status == eventHotKeyExistsErr
                    ? "already registered by another app"
                    : "registration failed (status \(status))"
                failures.append("\(hotkey.description): \(reason)")
                Self.logger.error("failed to register \(hotkey.description, privacy: .public): \(reason, privacy: .public)")
            }
        }
        return failures
    }

    /// Unregisters every currently registered hotkey.
    public func removeAll() {
        for ref in hotKeyRefs {
            UnregisterEventHotKey(ref)
        }
        hotKeyRefs.removeAll()
    }

    private func installEventHandler() {
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let selfPointer = Unmanaged.passUnretained(self).toOpaque()

        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, eventRef, userData in
                guard let eventRef, let userData else { return noErr }
                let center = Unmanaged<HotKeyCenter>.fromOpaque(userData).takeUnretainedValue()
                center.handleHotKeyEvent(eventRef)
                return noErr
            },
            1,
            &eventType,
            selfPointer,
            &eventHandlerRef
        )

        if status != noErr {
            Self.logger.error("InstallEventHandler failed with status \(status)")
        }
    }

    private func handleHotKeyEvent(_ eventRef: EventRef) {
        var hotKeyID = EventHotKeyID()
        let status = GetEventParameter(
            eventRef,
            EventParamName(kEventParamDirectObject),
            EventParamType(typeEventHotKeyID),
            nil,
            MemoryLayout<EventHotKeyID>.size,
            nil,
            &hotKeyID
        )

        guard status == noErr, hotKeyID.signature == Self.signature else { return }
        let index = Int(hotKeyID.id)

        DispatchQueue.main.async { [handler] in
            handler(index)
        }
    }

    private static func carbonModifiers(for modifiers: HotkeyModifiers) -> UInt32 {
        var result: UInt32 = 0
        if modifiers.contains(.command) { result |= UInt32(cmdKey) }
        if modifiers.contains(.option) { result |= UInt32(optionKey) }
        if modifiers.contains(.control) { result |= UInt32(controlKey) }
        if modifiers.contains(.shift) { result |= UInt32(shiftKey) }
        return result
    }
}
