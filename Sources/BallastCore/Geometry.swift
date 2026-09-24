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
    func end(_ axis: Axis) -> Double { axis == .horizontal ? maxX : maxY }

    /// Moved `delta` along `axis`.
    func shifted(_ axis: Axis, by delta: Double) -> CGRect {
        axis == .horizontal ? offsetBy(dx: delta, dy: 0) : offsetBy(dx: 0, dy: delta)
    }

    /// The slice from `from` to `from + length` along `axis`, spanning the
    /// whole rect across it.
    func band(_ axis: Axis, from: Double, length: Double) -> CGRect {
        switch axis {
        case .horizontal: return CGRect(x: from, y: minY, width: max(0, length), height: height)
        case .vertical: return CGRect(x: minX, y: from, width: width, height: max(0, length))
        }
    }

    /// Insets `start` from the start and `end` from the end along `axis`,
    /// never producing a negative length.
    func insetClamped(_ axis: Axis, start: Double, end: Double) -> CGRect {
        let a = min(max(0, start), extent(axis) / 2), b = min(max(0, end), extent(axis) / 2)
        switch axis {
        case .horizontal: return CGRect(x: minX + a, y: minY, width: width - a - b, height: height)
        case .vertical: return CGRect(x: minX, y: minY + a, width: width, height: height - a - b)
        }
    }

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

/// Divides `total` points into one segment per entry of `mins`, separated by
/// `gap`. Each segment gets at least its minimum when feasible; the rest is
/// shared in proportion to `weights`, no weight counting for more than
/// `maxWeightRatio` times the lightest (a non-finite or non-positive weight
/// counts as 0; segments with no weight among them share equally).
/// Infeasible minimums degrade to proportional-to-minimum sizing.
/// Total function: any input yields `mins.count` finite, non-negative lengths.
func distribute(total: Double, mins: [Double], weights: [Double], maxWeightRatio: Double, gap: Double) -> [Double] {
    let count = mins.count
    guard count > 0 else { return [] }
    let available = max(0, total - gap * Double(count - 1))
    let safeMins = mins.map { $0.isFinite ? max(0, $0) : 0 }
    let minSum = safeMins.reduce(0, +)
    if minSum > available {
        guard minSum > 0 else { return Array(repeating: available / Double(count), count: count) }
        return safeMins.map { available * $0 / minSum }
    }
    var safeWeights = (0..<count).map { i -> Double in
        let w = i < weights.count ? weights[i] : 0
        return w.isFinite && w > 0 ? w : 0
    }
    // Weight Share Limit: capping at a multiple of the lightest weight keeps
    // the lighter windows' proportions and only reins in the heavy ones.
    if maxWeightRatio.isFinite, let lightest = safeWeights.filter({ $0 > 0 }).min() {
        let cap = lightest * max(1, maxWeightRatio)
        safeWeights = safeWeights.map { min($0, cap) }
    }
    // Weighted water-filling: a segment whose share falls below its minimum
    // is fixed at that minimum, and the others re-share what is left. Fixing
    // segments only lowers everyone else's share, so each round fixes every
    // segment that is short; the loop ends within `count` rounds.
    var lengths = safeMins
    var free = Array(0..<count)
    var remaining = available
    while !free.isEmpty {
        let freeWeight = free.reduce(0) { $0 + safeWeights[$1] }
        let shares = free.map { i in
            freeWeight > 0 ? remaining * (safeWeights[i] / freeWeight) : remaining / Double(free.count)
        }
        let short = zip(free, shares).filter { safeMins[$0.0] > $0.1 }.map(\.0)
        if short.isEmpty {
            for (i, share) in zip(free, shares) { lengths[i] = share }
            break
        }
        for i in short { remaining -= safeMins[i] }
        free.removeAll { short.contains($0) }
    }
    return lengths
}

/// Lays `ids` out in a row/column filling `rect`, honouring learned minimum
/// sizes and sharing the rest in proportion to weight, capped at
/// `maxWeightRatio` times the lightest.
func tileLinear(_ ids: [WindowID], in rect: CGRect, axis: Axis, gap: Double,
                weight: (WindowID) -> Double, maxWeightRatio: Double,
                minSize: (WindowID) -> CGSize) -> [WindowID: CGRect] {
    let lengths = distribute(total: rect.extent(axis), mins: ids.map { minSize($0).extent(axis) },
                             weights: ids.map(weight), maxWeightRatio: maxWeightRatio, gap: gap)
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
