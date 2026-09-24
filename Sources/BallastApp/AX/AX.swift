import AppKit
import ApplicationServices
import BallastCore
import os

enum Log {
    static let wm = Logger(subsystem: "dev.ballast", category: "wm")
    static let ax = Logger(subsystem: "dev.ballast", category: "ax")
    static let config = Logger(subsystem: "dev.ballast", category: "config")
}

/// Thin, total wrappers over the Accessibility C API. Every read is optional;
/// every write reports success. Coordinates are AX/CG global (top-left origin).
enum AX {
    static let messagingTimeout: Float = 1.0

    static func copy(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value
    }

    static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        copy(element, attribute) as? String
    }

    static func bool(_ element: AXUIElement, _ attribute: String) -> Bool? {
        (copy(element, attribute) as? NSNumber)?.boolValue
    }

    static func element(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        guard let value = copy(element, attribute), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement) // safe: type id checked above
    }

    static func elements(_ element: AXUIElement, _ attribute: String) -> [AXUIElement] {
        guard let array = copy(element, attribute) as? [AnyObject] else { return [] }
        return array.compactMap { item in
            CFGetTypeID(item) == AXUIElementGetTypeID() ? (item as! AXUIElement) : nil // safe: type id checked
        }
    }

    static func frame(_ element: AXUIElement) -> CGRect? {
        guard let posValue = copy(element, kAXPositionAttribute), let sizeValue = copy(element, kAXSizeAttribute),
              CFGetTypeID(posValue) == AXValueGetTypeID(), CFGetTypeID(sizeValue) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero, size = CGSize.zero
        // Force casts are safe: CF type ids were checked above.
        guard AXValueGetValue(posValue as! AXValue, .cgPoint, &point),
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &size) else { return nil }
        return CGRect(origin: point, size: size)
    }

    @discardableResult
    static func setPosition(_ element: AXUIElement, _ point: CGPoint) -> Bool {
        var p = point
        guard let value = AXValueCreate(.cgPoint, &p) else { return false }
        return AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, value) == .success
    }

    @discardableResult
    static func setSize(_ element: AXUIElement, _ size: CGSize) -> Bool {
        var s = size
        guard let value = AXValueCreate(.cgSize, &s) else { return false }
        return AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, value) == .success
    }

    @discardableResult
    static func setBool(_ element: AXUIElement, _ attribute: String, _ value: Bool) -> Bool {
        AXUIElementSetAttributeValue(element, attribute as CFString, value ? kCFBooleanTrue : kCFBooleanFalse) == .success
    }

    static func raise(_ element: AXUIElement) {
        AXUIElementPerformAction(element, kAXRaiseAction as CFString)
    }

    static func windowAtPoint(_ point: CGPoint) -> AXUIElement? {
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(point.x), Float(point.y), &hit) == .success,
              let hit else { return nil }
        if string(hit, kAXRoleAttribute) == kAXWindowRole { return hit }
        return element(hit, kAXWindowAttribute)
    }
}

/// A physical display in AX/CG global coordinates.
struct DisplayInfo: Equatable {
    let id: CGDirectDisplayID
    /// Persistent display UUID (uppercase), matching SkyLight's "Display Identifier".
    let uuid: String
    let name: String
    let frame: CGRect
    /// Frame minus menu bar and Dock.
    let visibleFrame: CGRect

    static func current() -> [DisplayInfo] {
        guard let primary = NSScreen.screens.first else { return [] }
        let primaryHeight = primary.frame.height
        func flip(_ r: NSRect) -> CGRect {
            CGRect(x: r.minX, y: primaryHeight - r.maxY, width: r.width, height: r.height)
        }
        return NSScreen.screens.compactMap { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
            let id = CGDirectDisplayID(number.uint32Value)
            guard let cfUUID = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue(),
                  let uuid = CFUUIDCreateString(nil, cfUUID) as String? else { return nil }
            return DisplayInfo(id: id, uuid: uuid.uppercased(), name: screen.localizedName,
                               frame: flip(screen.frame), visibleFrame: flip(screen.visibleFrame))
        }
        .sorted { ($0.frame.minX, $0.frame.minY) < ($1.frame.minX, $1.frame.minY) }
    }
}

extension Array where Element == DisplayInfo {
    func containing(_ point: CGPoint) -> DisplayInfo? {
        first { $0.frame.contains(point) }
    }

    /// Display holding most of `rect`.
    func best(for rect: CGRect) -> DisplayInfo? {
        self.max { a, b in
            let ia = a.frame.intersection(rect), ib = b.frame.intersection(rect)
            return (ia.isNull ? 0 : ia.width * ia.height) < (ib.isNull ? 0 : ib.width * ib.height)
        }
    }

    func with(uuid: String) -> DisplayInfo? { first { $0.uuid == uuid.uppercased() } }
}

func currentMouseLocation() -> CGPoint {
    CGEvent(source: nil)?.location ?? .zero
}
