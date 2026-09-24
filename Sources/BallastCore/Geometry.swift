import CoreGraphics
import Foundation

/// Axis along which a region is divided.
/// `.horizontal`: children side by side (first = left). `.vertical`: stacked (first = top).
public enum Axis: String, Equatable, Sendable {
    case horizontal
    case vertical

    public var other: Axis { self == .horizontal ? .vertical : .horizontal }
}

public enum Direction: String, CaseIterable, Equatable, Sendable {
    case left, right, up, down

    public var axis: Axis { (self == .left || self == .right) ? .horizontal : .vertical }
    /// Whether moving this way increases the coordinate along `axis`
    /// (screen coordinates are top-left origin, y grows downward).
    public var isForward: Bool { self == .right || self == .down }
}

/// Gap sizes in points.
public struct Gaps: Equatable, Sendable {
    public var inner: Double
    public var outer: Double

    public init(inner: Double, outer: Double) {
        self.inner = inner
        self.outer = outer
    }
}

extension CGRect {
    func extent(_ axis: Axis) -> Double { axis == .horizontal ? width : height }
    func start(_ axis: Axis) -> Double { axis == .horizontal ? minX : minY }

    /// Splits along `axis`: first child gets `firstLength`, then `gap`, then the rest.
    func split(_ axis: Axis, firstLength: Double, gap: Double) -> (CGRect, CGRect) {
        let total = extent(axis)
        let first = max(0, min(firstLength, total - gap)).rounded()
        let secondLength = max(0, total - first - gap)
        switch axis {
        case .horizontal:
            return (CGRect(x: minX, y: minY, width: first, height: height),
                    CGRect(x: minX + first + gap, y: minY, width: secondLength, height: height))
        case .vertical:
            return (CGRect(x: minX, y: minY, width: width, height: first),
                    CGRect(x: minX, y: minY + first + gap, width: width, height: secondLength))
        }
    }

    /// Insets uniformly, never producing a negative size.
    public func insetClamped(by amount: Double) -> CGRect {
        let dx = min(amount, width / 2), dy = min(amount, height / 2)
        return CGRect(x: minX + dx, y: minY + dy, width: width - 2 * dx, height: height - 2 * dy)
    }

    /// Frame equality tolerant of AX rounding.
    public func approximatelyEquals(_ other: CGRect, tolerance: Double = 2) -> Bool {
        abs(minX - other.minX) <= tolerance && abs(minY - other.minY) <= tolerance
            && abs(width - other.width) <= tolerance && abs(height - other.height) <= tolerance
    }

    public var center: CGPoint { CGPoint(x: midX, y: midY) }
}

/// Divides `total` points into `count` segments separated by `gap`, each at
/// least its minimum when feasible. Segments beyond the minimums are shared
/// equally. Infeasible minimums degrade to proportional-to-minimum sizing.
/// Total function: any input yields `count` finite, non-negative lengths.
func distribute(total: Double, mins: [Double], gap: Double) -> [Double] {
    let count = mins.count
    guard count > 0 else { return [] }
    let available = max(0, total - gap * Double(count - 1))
    let safeMins = mins.map { $0.isFinite ? max(0, $0) : 0 }
    let minSum = safeMins.reduce(0, +)
    if minSum > available {
        guard minSum > 0 else { return Array(repeating: available / Double(count), count: count) }
        return safeMins.map { available * $0 / minSum }
    }
    // Water-filling: equal shares, raising any segment below its minimum.
    var sizes = Array(repeating: 0.0, count: count)
    var fixed = Array(repeating: false, count: count)
    var remaining = available
    var free = count
    var changed = true
    while changed && free > 0 {
        changed = false
        let share = remaining / Double(free)
        for i in 0..<count where !fixed[i] && safeMins[i] > share {
            fixed[i] = true
            sizes[i] = safeMins[i]
            remaining -= safeMins[i]
            free -= 1
            changed = true
        }
    }
    let share = free > 0 ? max(0, remaining) / Double(free) : 0
    for i in 0..<count where !fixed[i] { sizes[i] = share }
    return sizes
}

/// Lays `ids` out in a row/column filling `rect`, honouring learned minimum sizes.
func tileLinear(_ ids: [WindowID], in rect: CGRect, axis: Axis, gap: Double,
                minSize: (WindowID) -> CGSize) -> [WindowID: CGRect] {
    let lengths = distribute(total: rect.extent(axis), mins: ids.map { minSize($0).extent(axis) }, gap: gap)
    var frames: [WindowID: CGRect] = [:]
    var cursor = rect.start(axis)
    for (id, length) in zip(ids, lengths) {
        let start = cursor.rounded()
        let end = (cursor + length).rounded()
        switch axis {
        case .horizontal: frames[id] = CGRect(x: start, y: rect.minY, width: end - start, height: rect.height)
        case .vertical: frames[id] = CGRect(x: rect.minX, y: start, width: rect.width, height: end - start)
        }
        cursor += length + gap
    }
    return frames
}

extension CGSize {
    func extent(_ axis: Axis) -> Double { axis == .horizontal ? width : height }
}
