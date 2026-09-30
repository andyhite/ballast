import CoreGraphics
import Foundation

/// Geometry of the adaptive arrangement: every window in an equal cell, no
/// weights.
public enum GridLayout {
    /// Rows and columns for `count` windows: `ceil(sqrt(count))` columns and as
    /// many rows as they need in a landscape area (width >= height), the
    /// other way round in a portrait one.
    static func dimensions(count: Int, landscape: Bool) -> (rows: Int, columns: Int) {
        guard count > 0 else { return (0, 0) }
        var root = 1
        while root * root < count { root += 1 }
        let other = (count + root - 1) / root
        return landscape ? (other, root) : (root, other)
    }

    /// `order` fills the rows left to right, top to bottom. An incomplete
    /// last row's windows split that row's full width. Rows and cells are
    /// equal, `gap` apart, each grown to the learned minimum sizes like
    /// `tileLinear` does.
    public static func plan(order: [WindowID], in rect: CGRect, gap: Double,
                            minSize: (WindowID) -> CGSize = { _ in .zero }) -> TilePlan {
        guard !order.isEmpty else { return TilePlan() }
        let (rows, columns) = dimensions(count: order.count, landscape: rect.width >= rect.height)
        let lines = (0..<rows).map { row in Array(order[min(row * columns, order.count)..<min((row + 1) * columns, order.count)]) }
        let heights = distribute(
            total: rect.height,
            mins: lines.map { $0.map { minSize($0).height }.filter(\.isFinite).max() ?? 0 },
            weights: Array(repeating: 1, count: lines.count), maxWeightRatio: .infinity, gap: gap)
        var frames: [WindowID: CGRect] = [:]
        for (line, rowRect) in zip(lines, segments(of: rect, axis: .vertical, lengths: heights, gap: gap)) {
            frames.merge(tileLinear(line, in: rowRect, axis: .horizontal, gap: gap, weight: { _ in 1 },
                                    maxWeightRatio: .infinity, minSize: minSize)) { a, _ in a }
        }
        return TilePlan(frames: frames, navigation: frames)
    }
}
