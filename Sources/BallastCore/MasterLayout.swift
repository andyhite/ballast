import CoreGraphics
import Foundation

public enum StackSide: String, CaseIterable, Equatable, Sendable {
    case right, left, bottom, top

    /// Axis dividing master region from stack region.
    var primaryAxis: Axis { (self == .right || self == .left) ? .horizontal : .vertical }
    /// Master region comes first (left/top) along the primary axis.
    var masterFirst: Bool { self == .right || self == .bottom }
    /// The side across the masters from this one.
    public var opposite: StackSide {
        switch self {
        case .right: .left
        case .left: .right
        case .bottom: .top
        case .top: .bottom
        }
    }
}

/// Geometry of the master-grid and master-stack layouts: masters in one
/// region, the stack in the other.
public enum MasterLayout {
    public struct Plan: Equatable, Sendable {
        /// The frame to apply to every window.
        public var frames: [WindowID: CGRect] = [:]
        /// Stack windows tucked behind a tile while the stack scrolls, each
        /// with the strip of it left showing (zero-length when fully hidden).
        public var covered: [WindowID: CGRect] = [:]
        /// Where each window sits on the scrolling strip: `frames`, except that
        /// windows scrolled out of view continue the stack past either end.
        /// Directional focus and swap move along these.
        public var navigation: [WindowID: CGRect] = [:]
        /// Stack windows in view, in stack order.
        public var inView: [WindowID] = []
        /// Stack windows scrolled out of view, listed under the tile in view
        /// they sit behind: the first tile's are the windows before the view,
        /// the last tile's the ones after it. That tile must stay in front.
        public var behind: [WindowID: [WindowID]] = [:]
    }

    /// `order[0..<masterCount]` are masters, the rest is the stack. Masters
    /// share the master region, and stack windows their column, in proportion
    /// to `weight`, no weight counting for more than `maxWeightRatio` times
    /// the lightest in its region; learned minimum sizes come first. An empty
    /// stack lets masters fill the whole area.
    ///
    /// The stack sits on `side`, or with `bothSides` on both sides of the
    /// masters along `side`'s axis: `side`'s side takes the first half of the
    /// stack (rounded up), the opposite side the rest, and the masters keep
    /// `ratio` of the length between them. A one-window stack uses `side`
    /// only. Each side is split into up to `columns` equal columns, filled in
    /// stack order from the column nearest the masters (see `columnSizes`).
    ///
    /// A column of more than `stackLimit` windows scrolls: `stackLimit` equal
    /// slots stay in view, and every other window of the column is tucked
    /// behind the first or last slot. The window just before the view and
    /// the one just after it sit `peek` further out, so that strip of each
    /// shows; the slots give up `peek` only at an end with such a window, so
    /// a view holding the column's first or last window reaches that edge of
    /// the column. The view holds the most recently focused window of the
    /// column (`recent`, most recent first) and, of the positions that do,
    /// the one keeping the next most recent ones in view.
    public static func plan(order: [WindowID], in rect: CGRect, masterCount: Int, ratio: Double,
                            side: StackSide, gap: Double, stackLimit: Int? = nil, columns: Int = 1,
                            bothSides: Bool = false, peek: Double = 0, recent: [WindowID] = [],
                            weight: (WindowID) -> Double = { _ in 1 }, maxWeightRatio: Double = .infinity,
                            minSize: (WindowID) -> CGSize = { _ in .zero }) -> Plan {
        guard !order.isEmpty else { return Plan() }
        let count = min(max(masterCount, 1), order.count)
        let masters = Array(order.prefix(count))
        let stack = Array(order.dropFirst(count))
        let axis = side.primaryAxis, cross = axis.other
        if stack.isEmpty {
            let frames = tileLinear(masters, in: rect, axis: cross, gap: gap, weight: weight,
                                    maxWeightRatio: maxWeightRatio, minSize: minSize)
            return Plan(frames: frames, navigation: frames, inView: [])
        }

        // Each side's columns (nearest the masters first), `side`'s side first.
        var next = 0
        let sides: [[[WindowID]]] = stackGroups(stack.count, columns: columns, limit: stackLimit,
                                                bothSides: bothSides).map { sizes in
            sizes.map { size in
                defer { next += size }
                return Array(stack[next..<(next + size)])
            }
        }
        let extents = Dictionary(order.map { ($0, minSize($0).extent(axis)) }) { a, _ in a }
        let extentMin = { (ids: [WindowID]) in ids.compactMap { extents[$0] }.filter(\.isFinite).max() ?? 0 }
        let columnMins = sides.map { $0.map(extentMin) }

        // Regions along `axis` from its start: `side`'s side sits after the
        // masters for right/bottom and before them for left/top; the
        // opposite side, if any, on the other end.
        let safeRatio = ratio.isFinite ? min(max(ratio, 0.05), 0.95) : 0.5
        let sideWeight = (1 - safeRatio) / Double(sides.count)
        let sideMins = columnMins.map { $0.reduce(0, +) + gap * Double(max($0.count - 1, 0)) }
        var regions: [(side: Int?, min: Double, weight: Double)] = [(nil, extentMin(masters), safeRatio)]
        for (index, sideMin) in sideMins.enumerated() {
            let region = (side: Optional(index), min: sideMin, weight: sideWeight)
            if side.masterFirst == (index == 0) { regions.append(region) } else { regions.insert(region, at: 0) }
        }
        let lengths = distribute(total: rect.extent(axis), mins: regions.map(\.min), weights: regions.map(\.weight),
                                 maxWeightRatio: .infinity, gap: gap)
        let regionRects = segments(of: rect, axis: axis, lengths: lengths, gap: gap)
        let masterIndex = regions.firstIndex { $0.side == nil } ?? 0

        var plan = Plan()
        // In stack order, so `inView` lists windows the way the stack does.
        for (sideIndex, columnIDs) in sides.enumerated() {
            guard let index = regions.firstIndex(where: { $0.side == sideIndex }) else { continue }
            let mins = columnMins[sideIndex]
            let widths = distribute(total: regionRects[index].extent(axis), mins: mins,
                                    weights: Array(repeating: 1, count: mins.count), maxWeightRatio: .infinity, gap: gap)
            var columnRects = segments(of: regionRects[index], axis: axis, lengths: widths, gap: gap)
            if index < masterIndex { columnRects.reverse() }
            for (ids, columnRect) in zip(columnIDs, columnRects) {
                let column = stackPlan(ids, in: columnRect, axis: cross, gap: gap, limit: stackLimit, peek: peek,
                                       recent: recent, weight: weight, maxWeightRatio: maxWeightRatio, minSize: minSize)
                plan.frames.merge(column.frames) { a, _ in a }
                plan.covered.merge(column.covered) { a, _ in a }
                plan.navigation.merge(column.navigation) { a, _ in a }
                plan.behind.merge(column.behind) { a, _ in a }
                plan.inView += column.inView
            }
        }
        let masterFrames = tileLinear(masters, in: regionRects[masterIndex], axis: cross, gap: gap, weight: weight,
                                      maxWeightRatio: maxWeightRatio, minSize: minSize)
        plan.frames.merge(masterFrames) { a, _ in a }
        plan.navigation.merge(masterFrames) { a, _ in a }
        return plan
    }

    /// How many stack windows each column holds: one list per stack side
    /// (`bothSides` splits a stack of 2+ windows, the first side taking the
    /// extra one), each from the column nearest the masters outward.
    static func stackGroups(_ count: Int, columns: Int, limit: Int?, bothSides: Bool) -> [[Int]] {
        let perSide = bothSides && count > 1 ? [(count + 1) / 2, count / 2] : [count]
        return perSide.map { columnSizes($0, columns: columns, limit: limit) }
    }

    /// Windows per column for `count` windows on one side: never an empty
    /// column, spread evenly (nearer columns take the extra ones) while every
    /// column stays within `limit`; past `columns * limit`, every column but
    /// the outermost holds `limit` and the outermost takes the rest and scrolls.
    static func columnSizes(_ count: Int, columns: Int, limit: Int?) -> [Int] {
        let used = min(max(columns, 1), max(count, 0))
        guard used > 0 else { return [] }
        if let limit, count > used * max(limit, 1) {
            let full = max(limit, 1)
            return Array(repeating: full, count: used - 1) + [count - full * (used - 1)]
        }
        return (0..<used).map { count / used + ($0 < count % used ? 1 : 0) }
    }

    /// Whether a stack of `stackCount` windows has a column that scrolls.
    public static func scrolls(stackCount: Int, columns: Int, limit: Int?, bothSides: Bool) -> Bool {
        guard let limit else { return false }
        return stackGroups(stackCount, columns: columns, limit: limit, bothSides: bothSides)
            .contains { ($0.last ?? 0) > max(limit, 1) }
    }

    /// Where the stack window at `index` sits: its side (0 = `stack_side`'s)
    /// and its column (0 = nearest the masters) out of that side's.
    public static func slot(ofStackIndex index: Int, stackCount: Int, columns: Int, limit: Int?,
                            bothSides: Bool) -> (side: Int, sides: Int, column: Int, columns: Int) {
        let groups = stackGroups(stackCount, columns: columns, limit: limit, bothSides: bothSides)
        var start = 0
        for (side, sizes) in groups.enumerated() {
            for (column, size) in sizes.enumerated() {
                if index < start + size { return (side, groups.count, column, sizes.count) }
                start += size
            }
        }
        return (0, groups.count, 0, groups.first?.count ?? 0)
    }

    private static func stackPlan(_ ids: [WindowID], in rect: CGRect, axis: Axis, gap: Double, limit: Int?,
                                  peek: Double, recent: [WindowID], weight: (WindowID) -> Double,
                                  maxWeightRatio: Double, minSize: (WindowID) -> CGSize) -> Plan {
        let shown = limit.map { max(1, $0) } ?? ids.count
        guard ids.count > shown else {
            let frames = tileLinear(ids, in: rect, axis: axis, gap: gap, weight: weight,
                                    maxWeightRatio: maxWeightRatio, minSize: minSize)
            return Plan(frames: frames, navigation: frames, inView: ids)
        }
        let start = viewStart(ids, shown: shown, recent: recent)
        let visible = Array(ids[start..<(start + shown)])
        let inset = (peek.isFinite ? min(max(peek, 0), rect.extent(axis) / 4) : 0).rounded()
        // Only an end with a window beyond it keeps a strip for that window
        // to peek into. Slots stay equal whatever the weights, so which
        // windows share the view never changes a window's size.
        let before = start > 0 ? inset : 0
        let after = start + shown < ids.count ? inset : 0
        let slots = tileLinear(visible, in: rect.insetClamped(axis, start: before, end: after), axis: axis, gap: gap,
                               weight: { _ in 1 }, maxWeightRatio: .infinity, minSize: minSize)
        var plan = Plan(frames: slots, navigation: slots, inView: visible)
        guard let first = visible.first.flatMap({ slots[$0] }), let last = visible.last.flatMap({ slots[$0] }) else {
            return plan
        }
        if let head = visible.first, start > 0 { plan.behind[head] = Array(ids[..<start]) }
        if let tail = visible.last, start + shown < ids.count { plan.behind[tail, default: []] += ids[(start + shown)...] }
        // Scrolled-out windows continue the strip beyond the peeking strips,
        // so only windows in view line up beside the masters.
        for (distance, id) in zip(1..., ids[..<start].reversed()) {
            let peeking = distance == 1
            plan.frames[id] = peeking ? first.shifted(axis, by: -inset) : first
            plan.covered[id] = first.band(axis, from: first.start(axis) - (peeking ? inset : 0), length: peeking ? inset : 0)
            plan.navigation[id] = first.shifted(axis, by: -inset - Double(distance) * (first.extent(axis) + gap))
        }
        for (distance, id) in zip(1..., ids[(start + shown)...]) {
            let peeking = distance == 1
            plan.frames[id] = peeking ? last.shifted(axis, by: inset) : last
            plan.covered[id] = last.band(axis, from: last.end(axis), length: peeking ? inset : 0)
            plan.navigation[id] = last.shifted(axis, by: inset + Double(distance) * (last.extent(axis) + gap))
        }
        return plan
    }

    /// Index of the first stack window in view. The view holds `recent`'s
    /// first stack window; of the positions that do, those also holding the
    /// next most recent one win, and so on; any tie left goes to the position
    /// nearest the start of the stack.
    static func viewStart(_ ids: [WindowID], shown: Int, recent: [WindowID]) -> Int {
        var starts = Array(0...max(0, ids.count - max(shown, 1)))
        for id in recent where starts.count > 1 {
            guard let index = ids.firstIndex(of: id) else { continue }
            let holding = starts.filter { $0 <= index && index < $0 + shown }
            if !holding.isEmpty { starts = holding }
        }
        return starts.first ?? 0
    }
}
