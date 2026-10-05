import CoreGraphics
import Foundation

/// Frames for every window of a laid-out Space, plus what a deck needs.
public struct TilePlan: Equatable, Sendable {
    /// The frame to apply to every window.
    public var frames: [WindowID: CGRect] = [:]
    /// Deck windows tucked behind a tile while the deck scrolls, each
    /// with the strip of it left showing (zero-length when fully hidden).
    public var covered: [WindowID: CGRect] = [:]
    /// Where each window sits on the scrolling strip: `frames`, except that
    /// windows scrolled out of view continue the deck past either end.
    /// Directional focus and swap move along these.
    public var navigation: [WindowID: CGRect] = [:]
    /// Deck windows in view, in deck order.
    public var inView: [WindowID] = []
    /// Deck windows scrolled out of view, listed under the tile in view
    /// they sit behind: the first tile's are the windows before the view,
    /// the last tile's the ones after it. That tile must stay in front.
    public var behind: [WindowID: [WindowID]] = [:]
    /// Every window of a deck that scrolls, in view or not.
    public var scrolling: Set<WindowID> = []

    public init(frames: [WindowID: CGRect] = [:], covered: [WindowID: CGRect] = [:],
                navigation: [WindowID: CGRect] = [:], inView: [WindowID] = [],
                behind: [WindowID: [WindowID]] = [:], scrolling: Set<WindowID> = []) {
        self.frames = frames
        self.covered = covered
        self.navigation = navigation
        self.inView = inView
        self.behind = behind
        self.scrolling = scrolling
    }
}

/// How the tiles outside the feature fill their region.
enum GridKind {
    /// `columns` columns per side, at most `limit` tiles per column (`nil` =
    /// no cap), the last column decking what overflows.
    case fixed(columns: Int, limit: Int?)
    /// Equal cells, row-major.
    case adaptive
    /// Something else (the BSP tree) renders the region; the tile list is ignored.
    case custom(minExtent: (Axis) -> Double, render: (CGRect) -> TilePlan)
}

/// Geometry of the feature and the grid around it.
public enum FeatureLayout {
    /// How many tiles of `total` the feature takes: `count` (at least 1), or
    /// none without a feature.
    public static func featuredCount(feature: FeatureSide, count: Int, total: Int) -> Int {
        feature == .off ? 0 : min(max(count, 1), total)
    }

    /// `order[0..<featureCount]` fill the feature area, the rest the grid.
    /// Featured tiles share the feature area, and fixed-grid tiles their
    /// column, in proportion to `weight`, no weight counting for more than
    /// `maxWeightRatio` times the lightest in its region; learned minimum
    /// sizes come first. With no grid tile the feature fills the whole rect;
    /// with no feature the grid does.
    ///
    /// The feature sits on `feature`'s side and keeps `size` of the length
    /// between it and the grid. `.center` puts the feature between two grid
    /// halves: the right one takes the first half of the tiles (rounded up),
    /// the left the rest; one tile uses the right only. Each half is split
    /// by `grid` (see `GridKind`). A fixed grid's columns are always vertical
    /// lines side by side and its rows stack top to bottom, whatever side the
    /// feature is on; tiles fill the columns in order, starting from the
    /// column nearest the feature (the leftmost for a top or bottom feature).
    ///
    /// A column of more than `limit` tiles decks: `limit` equal slots stay in
    /// view, and every other window of the column is tucked behind the
    /// first or last slot. The window just before the view and the one just
    /// after it sit `peek` further out, so that strip of each shows; the slots
    /// give up `peek` only at an end with such a window, so a view holding
    /// the column's first or last window reaches that edge of the column.
    /// The view holds the most recently focused window of the column
    /// (`recent`, most recent first) and, of the positions that do, the one
    /// keeping the next most recent ones in view.
    static func plan(order: [WindowID], in rect: CGRect, feature: FeatureSide, featureCount: Int, size: Double,
                     grid: GridKind, gap: Double, peek: Double = 0, recent: [WindowID] = [],
                     weight: (WindowID) -> Double = { _ in 1 }, maxWeightRatio: Double = .infinity,
                     minSize: (WindowID) -> CGSize = { _ in .zero }) -> TilePlan {
        guard !order.isEmpty else { return TilePlan() }
        let count = featuredCount(feature: feature, count: featureCount, total: order.count)
        let featured = Array(order.prefix(count))
        let tiles = Array(order.dropFirst(count))
        let axis = feature.primaryAxis, cross = axis.other
        var limit: Int?
        var columns = 1
        if case .fixed(let c, let l) = grid { columns = c; limit = l }
        if tiles.isEmpty {
            let frames = tileLinear(featured, in: rect, axis: cross, gap: gap, weight: weight,
                                    maxWeightRatio: maxWeightRatio, minSize: minSize)
            return TilePlan(frames: frames, navigation: frames)
        }

        // Each half's tiles, and for a fixed grid its columns (nearest the feature first).
        var halves: [[WindowID]] = [tiles]
        var splitsHalves = feature == .center && tiles.count > 1
        if case .custom = grid { splitsHalves = false }
        if splitsHalves {
            halves = [Array(tiles.prefix((tiles.count + 1) / 2)), Array(tiles.dropFirst((tiles.count + 1) / 2))]
        }
        let halfColumns: [[[WindowID]]] = halves.map { half in
            guard case .fixed = grid else { return [half] }
            var next = 0
            return columnSizes(half.count, columns: columns, limit: limit).map { size in
                defer { next += size }
                return Array(half[next..<(next + size)])
            }
        }

        // Regions along `axis` from its start. Without a feature there is one.
        let extents = Dictionary(order.map { ($0, minSize($0).extent(axis)) }) { a, _ in a }
        let extentMin = { (ids: [WindowID]) in ids.compactMap { extents[$0] }.filter(\.isFinite).max() ?? 0 }
        // A fixed grid's columns need their widest member's width, and their
        // rows their members' heights (a deck, `limit` slots of its tallest).
        let finite = { (v: Double) in v.isFinite ? max(v, 0) : 0 }
        let columnWidthMins = halfColumns.map { $0.map { ids in ids.map { finite(minSize($0).width) }.max() ?? 0 } }
        let columnHeightMins = halfColumns.map { $0.map { ids -> Double in
            let heights = ids.map { finite(minSize($0).height) }
            let shown = limit.map { max($0, 1) } ?? ids.count
            let strips = 2 * (peek.isFinite ? max(peek, 0).rounded() : 0)
            if ids.count > shown { return (heights.max() ?? 0) * Double(shown) + gap * Double(shown - 1) + strips }
            return heights.reduce(0, +) + gap * Double(max(heights.count - 1, 0))
        } }
        var regions: [(half: Int?, min: Double, weight: Double)] = []
        let safeSize = size.isFinite ? min(max(size, 0.05), 0.95) : 0.5
        let halfWeight = (feature == .off ? 1 : 1 - safeSize) / Double(halves.count)
        if feature != .off { regions.append((nil, extentMin(featured), safeSize)) }
        for index in halves.indices {
            var regionMin = 0.0
            if case .fixed = grid {
                regionMin = axis == .horizontal
                    ? columnWidthMins[index].reduce(0, +) + gap * Double(max(columnWidthMins[index].count - 1, 0))
                    : columnHeightMins[index].max() ?? 0
            } else {
                switch grid {
                case .custom(let minExtent, _): regionMin = minExtent(axis)
                default: regionMin = GridLayout.minExtent(halves[index], axis: axis, gap: gap, minSize: minSize)
                }
            }
            let region = (half: Optional(index), min: regionMin, weight: halfWeight)
            if feature.gridFollows == (index == 0) || feature == .off { regions.append(region) } else { regions.insert(region, at: 0) }
        }
        // One region (no feature) is the whole rect.
        let regionRects: [CGRect]
        if regions.count == 1 {
            regionRects = [rect]
        } else {
            let lengths = distribute(total: rect.extent(axis), mins: regions.map(\.min), weights: regions.map(\.weight),
                                     maxWeightRatio: .infinity, gap: gap)
            regionRects = segments(of: rect, axis: axis, lengths: lengths, gap: gap)
        }
        let featureIndex = regions.firstIndex { $0.half == nil } ?? -1

        var plan = TilePlan()
        // In tile order, so `inView` lists windows the way the grid does.
        for (halfIndex, half) in halves.enumerated() {
            guard let index = regions.firstIndex(where: { $0.half == halfIndex }) else { continue }
            let region = regionRects[index]
            switch grid {
            case .fixed:
                // Grids left of a horizontal feature fill right to left, so the minimums reverse with them.
                let flip = axis == .horizontal && index < featureIndex
                let mins = flip ? Array(columnWidthMins[halfIndex].reversed()) : columnWidthMins[halfIndex]
                let widths = distribute(total: region.width, mins: mins,
                                        weights: Array(repeating: 1, count: mins.count), maxWeightRatio: .infinity, gap: gap)
                var columnRects = segments(of: region, axis: .horizontal, lengths: widths, gap: gap)
                if flip { columnRects.reverse() }
                for (ids, columnRect) in zip(halfColumns[halfIndex], columnRects) {
                    let column = DeckLayout.column(ids, in: columnRect, axis: .vertical, gap: gap, limit: limit, peek: peek,
                                                   recent: recent, weight: weight, maxWeightRatio: maxWeightRatio,
                                                   minSize: minSize)
                    plan.merge(column)
                }
            case .adaptive:
                plan.merge(GridLayout.plan(order: half, in: region, gap: gap, minSize: minSize))
            case .custom(_, let render):
                plan.merge(render(region))
            }
        }
        if featureIndex >= 0 {
            let frames = tileLinear(featured, in: regionRects[featureIndex], axis: cross, gap: gap, weight: weight,
                                    maxWeightRatio: maxWeightRatio, minSize: minSize)
            plan.frames.merge(frames) { a, _ in a }
            plan.navigation.merge(frames) { a, _ in a }
        }
        return plan
    }

    /// How many grid tiles each column holds: one list per half (a centered
    /// feature splits 2+ tiles, the first half taking the extra one), each
    /// from the column nearest the feature outward.
    static func gridGroups(_ count: Int, columns: Int, limit: Int?, center: Bool) -> [[Int]] {
        let perHalf = center && count > 1 ? [(count + 1) / 2, count / 2] : [count]
        return perHalf.map { columnSizes($0, columns: columns, limit: limit) }
    }

    /// Windows per column for `count` windows in one half: never an empty
    /// column, spread evenly (nearer columns take the extra ones) while every
    /// column stays within `limit`; past `columns * limit`, every column but
    /// the outermost holds `limit` and the outermost takes the rest and decks.
    static func columnSizes(_ count: Int, columns: Int, limit: Int?) -> [Int] {
        let used = min(max(columns, 1), max(count, 0))
        guard used > 0 else { return [] }
        if let limit, count > used * max(limit, 1) {
            let full = max(limit, 1)
            return Array(repeating: full, count: used - 1) + [count - full * (used - 1)]
        }
        return (0..<used).map { count / used + ($0 < count % used ? 1 : 0) }
    }

    /// Whether `gridCount` grid tiles have a column that decks.
    public static func scrolls(gridCount: Int, columns: Int, limit: Int?, center: Bool) -> Bool {
        guard let limit else { return false }
        return gridGroups(gridCount, columns: columns, limit: limit, center: center)
            .contains { ($0.last ?? 0) > max(limit, 1) }
    }

    /// Where the grid tile at `index` sits: its half (0 = the right or first)
    /// and its column (0 = nearest the feature) out of that half's.
    public static func slot(ofGridIndex index: Int, gridCount: Int, columns: Int, limit: Int?,
                            center: Bool) -> (half: Int, halves: Int, column: Int, columns: Int) {
        let groups = gridGroups(gridCount, columns: columns, limit: limit, center: center)
        var start = 0
        for (half, sizes) in groups.enumerated() {
            for (column, size) in sizes.enumerated() {
                if index < start + size { return (half, groups.count, column, sizes.count) }
                start += size
            }
        }
        return (0, groups.count, 0, groups.first?.count ?? 0)
    }
}

extension TilePlan {
    mutating func merge(_ other: TilePlan) {
        frames.merge(other.frames) { a, _ in a }
        covered.merge(other.covered) { a, _ in a }
        navigation.merge(other.navigation) { a, _ in a }
        behind.merge(other.behind) { a, _ in a }
        scrolling.formUnion(other.scrolling)
        inView += other.inView
    }
}
