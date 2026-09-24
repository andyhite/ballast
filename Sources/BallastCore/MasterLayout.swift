import CoreGraphics
import Foundation

public enum StackSide: String, CaseIterable, Equatable, Sendable {
    case right, left, bottom, top

    /// Axis dividing master region from stack region.
    var primaryAxis: Axis { (self == .right || self == .left) ? .horizontal : .vertical }
    /// Master region comes first (left/top) along the primary axis.
    var masterFirst: Bool { self == .right || self == .bottom }
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
    /// share the master region, and stack windows the stack, in proportion to
    /// `weight`, no weight counting for more than `maxWeightRatio` times the
    /// lightest in its region; learned minimum sizes come first. An empty
    /// stack lets masters fill the whole area.
    ///
    /// A stack of more than `stackLimit` windows scrolls: `stackLimit` equal
    /// slots stay in view, and every other stack window is tucked behind the
    /// first or last slot. The window just before the view and the one just
    /// after it sit `peek` further out, so that strip of each shows; the slots
    /// give up `peek` only at an end with such a window, so a view holding
    /// the first or last stack window reaches that edge of the stack region.
    /// The view holds the most recently focused stack window (`recent`, most
    /// recent first) and, of the positions that do, the one keeping the next
    /// most recent ones in view.
    public static func plan(order: [WindowID], in rect: CGRect, masterCount: Int, ratio: Double,
                            side: StackSide, gap: Double, stackLimit: Int? = nil, peek: Double = 0,
                            recent: [WindowID] = [],
                            weight: (WindowID) -> Double = { _ in 1 }, maxWeightRatio: Double = .infinity,
                            minSize: (WindowID) -> CGSize = { _ in .zero }) -> Plan {
        guard !order.isEmpty else { return Plan() }
        let count = min(max(masterCount, 1), order.count)
        let masters = Array(order.prefix(count))
        let stack = Array(order.dropFirst(count))
        let cross = side.primaryAxis.other
        if stack.isEmpty {
            let frames = tileLinear(masters, in: rect, axis: cross, gap: gap, weight: weight,
                                    maxWeightRatio: maxWeightRatio, minSize: minSize)
            return Plan(frames: frames, navigation: frames, inView: [])
        }

        let axis = side.primaryAxis
        let available = max(0, rect.extent(axis) - gap)
        let safeRatio = ratio.isFinite ? min(max(ratio, 0.05), 0.95) : 0.5
        let masterMin = masters.map { minSize($0).extent(axis) }.filter(\.isFinite).max() ?? 0
        let stackMin = stack.map { minSize($0).extent(axis) }.filter(\.isFinite).max() ?? 0
        var masterLength = available * safeRatio
        if masterMin + stackMin <= available {
            masterLength = min(max(masterLength, masterMin), available - stackMin)
        } else if masterMin + stackMin > 0 {
            masterLength = available * masterMin / (masterMin + stackMin)
        }

        let masterRect: CGRect, stackRect: CGRect
        if side.masterFirst {
            (masterRect, stackRect) = rect.split(axis, firstLength: masterLength, gap: gap)
        } else {
            (stackRect, masterRect) = rect.split(axis, firstLength: available - masterLength, gap: gap)
        }
        let masterFrames = tileLinear(masters, in: masterRect, axis: cross, gap: gap, weight: weight,
                                      maxWeightRatio: maxWeightRatio, minSize: minSize)
        var plan = stackPlan(stack, in: stackRect, axis: cross, gap: gap, limit: stackLimit, peek: peek,
                             recent: recent, weight: weight, maxWeightRatio: maxWeightRatio, minSize: minSize)
        plan.frames.merge(masterFrames) { a, _ in a }
        plan.navigation.merge(masterFrames) { a, _ in a }
        return plan
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
