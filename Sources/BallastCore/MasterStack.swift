import CoreGraphics
import Foundation

public enum StackSide: String, CaseIterable, Equatable, Sendable {
    case right, left, bottom, top

    /// Axis dividing master region from stack region.
    var primaryAxis: Axis { (self == .right || self == .left) ? .horizontal : .vertical }
    /// Master region comes first (left/top) along the primary axis.
    var masterFirst: Bool { self == .right || self == .bottom }
}

public enum MasterStackLayout {
    /// `order[0..<masterCount]` are masters, the rest is the stack. Masters
    /// share the master region, and stack windows the stack, in proportion to
    /// `weight`, no weight counting for more than `maxWeightRatio` times the
    /// lightest in its region; learned minimum sizes come first. An empty
    /// stack lets masters fill the whole area.
    public static func frames(order: [WindowID], in rect: CGRect, masterCount: Int, ratio: Double,
                              side: StackSide, gap: Double,
                              weight: (WindowID) -> Double = { _ in 1 }, maxWeightRatio: Double = .infinity,
                              minSize: (WindowID) -> CGSize = { _ in .zero }) -> [WindowID: CGRect] {
        guard !order.isEmpty else { return [:] }
        let count = min(max(masterCount, 1), order.count)
        let masters = Array(order.prefix(count))
        let stack = Array(order.dropFirst(count))
        let cross = side.primaryAxis.other
        if stack.isEmpty {
            return tileLinear(masters, in: rect, axis: cross, gap: gap, weight: weight, maxWeightRatio: maxWeightRatio, minSize: minSize)
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
        var frames = tileLinear(masters, in: masterRect, axis: cross, gap: gap, weight: weight,
                                maxWeightRatio: maxWeightRatio, minSize: minSize)
        frames.merge(tileLinear(stack, in: stackRect, axis: cross, gap: gap, weight: weight,
                                maxWeightRatio: maxWeightRatio, minSize: minSize)) { a, _ in a }
        return frames
    }
}
