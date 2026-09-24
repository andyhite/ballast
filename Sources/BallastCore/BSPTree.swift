import CoreGraphics
import Foundation

/// Binary space partition as an immutable value tree.
///
/// Every mutation builds a new tree and either returns it whole or returns an
/// error — there is no half-attached intermediate state for anything to
/// observe, which is the structural fix for the "handler sees a node that is
/// not yet re-parented" crash class. No operation traps; bad input (unknown or
/// duplicate ids, self-swaps) surfaces as `BSPError`.
public indirect enum BSPNode: Equatable, Sendable {
    case leaf(WindowID)
    case split(BSPSplit)
}

public struct BSPSplit: Equatable, Sendable {
    /// `nil` = automatic: split across the longer side of the region at layout time.
    public var axis: Axis?
    /// Manual override of the first child's share; `nil` = weight-derived.
    public var ratio: Double?
    public var first: BSPNode
    public var second: BSPNode

    public init(axis: Axis?, ratio: Double? = nil, first: BSPNode, second: BSPNode) {
        self.axis = axis
        self.ratio = ratio
        self.first = first
        self.second = second
    }
}

public enum BSPError: Error, Equatable, Sendable {
    case notFound(WindowID)
    case duplicate(WindowID)
    case sameWindow(WindowID)
    case isRoot(WindowID)
}

/// Shape of a Space's weight-default BSP tree.
public enum BSPShape: String, CaseIterable, Equatable, Sendable {
    /// Spiral: each window splits the previous one, and a new window splits
    /// the focused tile.
    case dwindle
    /// Rank order halved recursively at its weight midpoint: an equal-area
    /// grid (four equal-weight windows = quarters). Rebuilt whenever windows
    /// come and go, until the Space is arranged manually.
    case balanced
}

/// Inputs to BSP layout besides the tree itself.
public struct BSPLayoutContext {
    public var weight: (WindowID) -> Double
    public var minRatio: Double
    public var maxRatio: Double
    public var gap: Double
    public var minSize: (WindowID) -> CGSize

    public init(weight: @escaping (WindowID) -> Double, minRatio: Double, maxRatio: Double, gap: Double,
                minSize: @escaping (WindowID) -> CGSize = { _ in .zero }) {
        self.weight = weight
        self.minRatio = minRatio
        self.maxRatio = maxRatio
        self.gap = gap
        self.minSize = minSize
    }
}

extension BSPNode {
    // MARK: Queries

    public var leaves: [WindowID] {
        switch self {
        case .leaf(let id): return [id]
        case .split(let s): return s.first.leaves + s.second.leaves
        }
    }

    public func contains(_ id: WindowID) -> Bool {
        switch self {
        case .leaf(let leaf): return leaf == id
        case .split(let s): return s.first.contains(id) || s.second.contains(id)
        }
    }

    public func weightSum(_ weight: (WindowID) -> Double) -> Double {
        switch self {
        case .leaf(let id):
            let w = weight(id)
            return w.isFinite && w > 0 ? w : 0
        case .split(let s): return s.first.weightSum(weight) + s.second.weightSum(weight)
        }
    }

    /// First child's share of a split: the manual ratio if set, else the ratio
    /// of subtree weight sums, clamped to `[minRatio, maxRatio]`.
    public static func effectiveRatio(_ split: BSPSplit, weight: (WindowID) -> Double,
                                      minRatio: Double, maxRatio: Double) -> Double {
        let lo = min(minRatio, maxRatio), hi = max(minRatio, maxRatio)
        if let manual = split.ratio, manual.isFinite { return min(max(manual, lo), hi) }
        let a = split.first.weightSum(weight)
        let b = split.second.weightSum(weight)
        let raw = (a + b) > 0 ? a / (a + b) : 0.5
        return min(max(raw, lo), hi)
    }

    // MARK: Construction

    /// The weight-computed default tree: windows in rank order, each new one
    /// splitting the previously inserted leaf (dwindle). The heaviest window
    /// ends up as the largest, top-left-most tile.
    public static func ideal(_ order: [WindowID], axis: Axis?) -> BSPNode? {
        guard let head = order.first else { return nil }
        var tree = BSPNode.leaf(head)
        var previous = head
        for id in order.dropFirst() {
            if case .success(let next) = tree.inserting(id, nextTo: previous, axis: axis) {
                tree = next
                previous = id
            }
        }
        return tree
    }

    /// Weight-balanced tree: `order` is cut where the running weight sum is
    /// closest to half the total (ties keep the first side smaller, so the
    /// heaviest window gets a half to itself), and each side is built the
    /// same way. Rank order reads first-to-second.
    public static func balanced(_ order: [WindowID], axis: Axis?, weight: (WindowID) -> Double) -> BSPNode? {
        guard let head = order.first else { return nil }
        guard order.count > 1 else { return .leaf(head) }
        let weights = order.map { id -> Double in
            let w = weight(id)
            return w.isFinite ? max(w, 0) : 0
        }
        let half = weights.reduce(0, +) / 2
        var cut = 1, bestGap = Double.infinity, running = 0.0
        for k in 1..<order.count {
            running += weights[k - 1]
            if abs(running - half) < bestGap { cut = k; bestGap = abs(running - half) }
        }
        guard let first = balanced(Array(order[..<cut]), axis: axis, weight: weight),
              let second = balanced(Array(order[cut...]), axis: axis, weight: weight) else { return .leaf(head) }
        return .split(BSPSplit(axis: axis, first: first, second: second))
    }

    // MARK: Mutations (pure)

    /// Splits `target`'s leaf, placing `id` second. Missing/nil target →
    /// splits the last leaf.
    public func inserting(_ id: WindowID, nextTo target: WindowID?, axis: Axis?) -> Result<BSPNode, BSPError> {
        if contains(id) { return .failure(.duplicate(id)) }
        let anchor = target.flatMap { contains($0) ? $0 : nil } ?? leaves.last
        guard let anchor else { return .success(.leaf(id)) }
        return .success(replacingLeaf(anchor) { .split(BSPSplit(axis: axis, first: $0, second: .leaf(id))) })
    }

    /// Removes a leaf; its sibling takes the parent's place. `nil` = tree emptied.
    public func removing(_ id: WindowID) -> Result<BSPNode?, BSPError> {
        guard contains(id) else { return .failure(.notFound(id)) }
        return .success(pruned(id))
    }

    public func swapping(_ a: WindowID, _ b: WindowID) -> Result<BSPNode, BSPError> {
        if a == b { return .failure(.sameWindow(a)) }
        guard contains(a) else { return .failure(.notFound(a)) }
        guard contains(b) else { return .failure(.notFound(b)) }
        return .success(mapLeaves { $0 == a ? b : ($0 == b ? a : $0) })
    }

    /// Adjusts the split directly containing `id` so `id`'s side changes share
    /// by `delta` (positive = grow). Pins that split's ratio as a manual override.
    public func resizing(_ id: WindowID, by delta: Double, context: BSPLayoutContext) -> Result<BSPNode, BSPError> {
        guard contains(id) else { return .failure(.notFound(id)) }
        if case .leaf = self { return .failure(.isRoot(id)) }
        return .success(resized(id, delta: delta, context: context))
    }

    /// Drops every manual ratio (back to weight-derived sizing).
    public func clearingRatios() -> BSPNode {
        switch self {
        case .leaf: return self
        case .split(var s):
            s.ratio = nil
            s.first = s.first.clearingRatios()
            s.second = s.second.clearingRatios()
            return .split(s)
        }
    }

    /// Sets every split's axis (`nil` = automatic), keeping shape and ratios.
    public func withAxis(_ axis: Axis?) -> BSPNode {
        switch self {
        case .leaf: return self
        case .split(var s):
            s.axis = axis
            s.first = s.first.withAxis(axis)
            s.second = s.second.withAxis(axis)
            return .split(s)
        }
    }

    /// Pins every split's ratio to each side's leaf-count share, so the
    /// resulting tiles have equal area regardless of window weights.
    public func balanced() -> BSPNode {
        switch self {
        case .leaf: return self
        case .split(var s):
            s.first = s.first.balanced()
            s.second = s.second.balanced()
            let firstCount = s.first.leaves.count
            let secondCount = s.second.leaves.count
            s.ratio = Double(firstCount) / Double(firstCount + secondCount)
            return .split(s)
        }
    }

    // MARK: Layout

    public func layout(in rect: CGRect, context: BSPLayoutContext) -> [WindowID: CGRect] {
        var frames: [WindowID: CGRect] = [:]
        // At the root both of `rect`'s dimensions are exactly the caller's
        // rect (no ancestor has estimated either one yet).
        place(in: rect, exact: ExactDims(horizontal: true, vertical: true), context: context, into: &frames)
        return frames
    }

    /// Tracks which of a projected rect's two dimensions are exact values
    /// inherited unchanged from an ancestor split versus provisional
    /// estimates still pending that ancestor's min-size resolution. A
    /// dimension stays exact until some split along that same axis divides
    /// it; the cross dimension of any split is always passed to both
    /// children untouched, so its exactness is preserved.
    struct ExactDims {
        var horizontal: Bool
        var vertical: Bool
        func contains(_ axis: Axis) -> Bool { axis == .horizontal ? horizontal : vertical }
        func removing(_ axis: Axis) -> ExactDims {
            axis == .horizontal ? ExactDims(horizontal: false, vertical: vertical)
                                 : ExactDims(horizontal: horizontal, vertical: false)
        }
    }

    /// Smallest extent along `axis` this subtree can occupy given learned
    /// minimum sizes, resolving each nested automatic split's own axis via
    /// `resolvedAxis` rather than a fixed parent-orientation heuristic.
    func minExtent(in rect: CGRect, axis: Axis, exact: ExactDims, context: BSPLayoutContext) -> Double {
        switch self {
        case .leaf(let id):
            let v = context.minSize(id).extent(axis)
            return v.isFinite ? max(0, v) : 0
        case .split(let s):
            let splitAxis = Self.resolvedAxis(s, rect: rect, exact: exact, context: context)
            let ratio = Self.effectiveRatio(s, weight: context.weight, minRatio: context.minRatio, maxRatio: context.maxRatio)
            let available = max(0, rect.extent(splitAxis) - context.gap)
            let (a, b) = rect.split(splitAxis, firstLength: available * ratio, gap: context.gap)
            let childExact = exact.removing(splitAxis)
            let firstM = s.first.minExtent(in: a, axis: axis, exact: childExact, context: context)
            let secondM = s.second.minExtent(in: b, axis: axis, exact: childExact, context: context)
            return splitAxis == axis ? firstM + secondM + context.gap : max(firstM, secondM)
        }
    }

    /// A genuine, rect-independent lower bound on `minExtent(axis)`: for a
    /// fixed-axis split, only the matching axis truly sums (the other takes
    /// the larger child); for an automatic split the eventual axis is not
    /// yet known, so the bound must hold for *either* choice — the smallest
    /// value achievable under any resolution is `max(first, second)` (the
    /// perpendicular case never needs the gap-inclusive sum). Because this
    /// never overestimates, `sum(children) > available` genuinely proves no
    /// resolution of the automatic axes below can fit — a sound one-sided
    /// veto, not an exhaustive feasibility search. It needs no rect/ratio,
    /// so it is O(subtree) with no branching and trivially cheap.
    private func lowerBoundExtent(_ axis: Axis, context: BSPLayoutContext) -> Double {
        switch self {
        case .leaf(let id):
            let v = context.minSize(id).extent(axis)
            return v.isFinite ? max(0, v) : 0
        case .split(let s):
            let firstB = s.first.lowerBoundExtent(axis, context: context)
            let secondB = s.second.lowerBoundExtent(axis, context: context)
            if let fixedAxis = s.axis, fixedAxis == axis {
                return firstB + secondB + context.gap
            }
            return max(firstB, secondB)
        }
    }

    /// Resolves an automatic split's own axis. The aspect ratio of the
    /// projected rect (longer side wins) is the default, but when that rect's
    /// dimension along a candidate axis is exactly known (never estimated by
    /// an ancestor still pending its own min-size resolution), and the sound
    /// structural `lowerBoundExtent` alone already exceeds that exact extent,
    /// the candidate is provably infeasible and rejected in favor of the
    /// other — a single deterministic veto per candidate, not an iterative
    /// search. This only proves a candidate CANNOT fit; it does not attempt
    /// to prove the chosen candidate WILL fit an exhaustive packing — actual
    /// fitting is still whatever `minExtent`/`place` resolve for the winning
    /// axis, degrading proportionally when genuinely infeasible.
    static func resolvedAxis(_ s: BSPSplit, rect: CGRect, exact: ExactDims, context: BSPLayoutContext) -> Axis {
        if let manual = s.axis { return manual }
        let natural: Axis = rect.width >= rect.height ? .horizontal : .vertical
        let flipped = natural.other
        func provablyInfeasible(_ candidate: Axis) -> Bool {
            guard exact.contains(candidate) else { return false }
            let available = max(0, rect.extent(candidate) - context.gap)
            let bound = s.first.lowerBoundExtent(candidate, context: context)
                      + s.second.lowerBoundExtent(candidate, context: context)
            return bound > available
        }
        if provablyInfeasible(natural) && !provablyInfeasible(flipped) { return flipped }
        return natural
    }

    // MARK: Private

    private func place(in rect: CGRect, exact: ExactDims, context: BSPLayoutContext, into frames: inout [WindowID: CGRect]) {
        switch self {
        case .leaf(let id):
            frames[id] = rect
        case .split(let s):
            let axis = Self.resolvedAxis(s, rect: rect, exact: exact, context: context)
            let ratio = Self.effectiveRatio(s, weight: context.weight, minRatio: context.minRatio, maxRatio: context.maxRatio)
            let available = max(0, rect.extent(axis) - context.gap)
            var firstLength = available * ratio
            // Nested auto splits resolve their own axis against the estimated
            // (not-yet-finalized) projected region below via `minExtent`'s
            // `exact` tracking; reserve their feasible minima before settling
            // this split's own final lengths.
            let (naiveA, naiveB) = rect.split(axis, firstLength: firstLength, gap: context.gap)
            let probeExact = exact.removing(axis)
            let firstMin = s.first.minExtent(in: naiveA, axis: axis, exact: probeExact, context: context)
            let secondMin = s.second.minExtent(in: naiveB, axis: axis, exact: probeExact, context: context)
            if firstMin + secondMin <= available {
                firstLength = min(max(firstLength, firstMin), available - secondMin)
            } else if firstMin + secondMin > 0 {
                firstLength = available * firstMin / (firstMin + secondMin)
            }
            let (a, b) = rect.split(axis, firstLength: firstLength, gap: context.gap)
            // `a`/`b` are this split's real, final child rects (not a probe):
            // both dimensions are now exactly known for the recursive place.
            let placedExact = ExactDims(horizontal: true, vertical: true)
            s.first.place(in: a, exact: placedExact, context: context, into: &frames)
            s.second.place(in: b, exact: placedExact, context: context, into: &frames)
        }
    }


    private func replacingLeaf(_ target: WindowID, with make: (BSPNode) -> BSPNode) -> BSPNode {
        switch self {
        case .leaf(let id): return id == target ? make(self) : self
        case .split(var s):
            if s.first.contains(target) { s.first = s.first.replacingLeaf(target, with: make) }
            else { s.second = s.second.replacingLeaf(target, with: make) }
            return .split(s)
        }
    }

    private func pruned(_ id: WindowID) -> BSPNode? {
        switch self {
        case .leaf(let leaf): return leaf == id ? nil : self
        case .split(var s):
            let first = s.first.pruned(id)
            let second = s.second.pruned(id)
            switch (first, second) {
            case (nil, nil): return nil
            case (let only?, nil), (nil, let only?): return only
            case (let a?, let b?):
                s.first = a
                s.second = b
                return .split(s)
            }
        }
    }

    private func mapLeaves(_ transform: (WindowID) -> WindowID) -> BSPNode {
        switch self {
        case .leaf(let id): return .leaf(transform(id))
        case .split(var s):
            s.first = s.first.mapLeaves(transform)
            s.second = s.second.mapLeaves(transform)
            return .split(s)
        }
    }

    private func resized(_ id: WindowID, delta: Double, context: BSPLayoutContext) -> BSPNode {
        guard case .split(var s) = self else { return self }
        let current = Self.effectiveRatio(s, weight: context.weight, minRatio: context.minRatio, maxRatio: context.maxRatio)
        let lo = min(context.minRatio, context.maxRatio), hi = max(context.minRatio, context.maxRatio)
        if s.first == .leaf(id) {
            s.ratio = min(max(current + delta, lo), hi)
        } else if s.second == .leaf(id) {
            s.ratio = min(max(current - delta, lo), hi)
        } else if s.first.contains(id) {
            s.first = s.first.resized(id, delta: delta, context: context)
        } else {
            s.second = s.second.resized(id, delta: delta, context: context)
        }
        return .split(s)
    }
}
