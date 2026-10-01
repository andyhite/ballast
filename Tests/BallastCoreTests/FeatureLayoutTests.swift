import CoreGraphics
import Testing
@testable import BallastCore

@Suite("FeatureLayout")
struct FeatureLayoutTests {

    static let rect = CGRect(x: 0, y: 0, width: 1000, height: 500)

    /// `FeatureLayout.plan` with the defaults most tests share: one feature
    /// window, a single uncapped grid column, no gap.
    static func plan(_ order: [WindowID], in rect: CGRect = rect, feature: FeatureSide = .left, count: Int = 1,
                     size: Double = 0.6, grid: GridKind = .fixed(columns: 1, limit: nil), gap: Double = 0,
                     peek: Double = 0, recent: [WindowID] = [],
                     weight: @escaping (WindowID) -> Double = { _ in 1 }, maxWeightRatio: Double = .infinity,
                     minSize: @escaping (WindowID) -> CGSize = { _ in .zero }) -> TilePlan {
        FeatureLayout.plan(order: order, in: rect, feature: feature, featureCount: count, size: size, grid: grid,
                           gap: gap, peek: peek, recent: recent, weight: weight, maxWeightRatio: maxWeightRatio,
                           minSize: minSize)
    }

    static func near(_ a: CGRect?, _ b: CGRect, tolerance: Double = 1) -> Bool {
        guard let a else { return false }
        return abs(a.minX - b.minX) <= tolerance && abs(a.minY - b.minY) <= tolerance
            && abs(a.width - b.width) <= tolerance && abs(a.height - b.height) <= tolerance
    }

    // MARK: - Feature sides

    @Test("feature left: feature on the left, grid on the right")
    func featureLeft() {
        let frames = Self.plan([1, 2], feature: .left).frames
        #expect(frames[1]!.minX == Self.rect.minX)
        #expect(frames[2]!.maxX == Self.rect.maxX)
        #expect(frames[2]!.minX >= frames[1]!.maxX)
    }

    @Test("feature right: feature on the right, grid on the left")
    func featureRight() {
        let frames = Self.plan([1, 2], feature: .right).frames
        #expect(frames[1]!.maxX == Self.rect.maxX)
        #expect(frames[2]!.minX == Self.rect.minX)
        #expect(frames[1]!.minX >= frames[2]!.maxX)
        #expect(abs(frames[1]!.width - 600) < 0.001) // feature extent = size * width
    }

    @Test("feature top: feature at the top, grid below")
    func featureTop() {
        let frames = Self.plan([1, 2], feature: .top).frames
        #expect(frames[1]!.minY == Self.rect.minY)
        #expect(frames[2]!.maxY == Self.rect.maxY)
        #expect(frames[2]!.minY >= frames[1]!.maxY)
        #expect(abs(frames[1]!.width - Self.rect.width) < 0.001) // full-width tiles
        #expect(abs(frames[2]!.width - Self.rect.width) < 0.001)
        #expect(abs(frames[1]!.height - 300) < 0.001) // feature extent = size * height
    }

    @Test("feature bottom: feature at the bottom, grid above")
    func featureBottom() {
        let frames = Self.plan([1, 2], feature: .bottom).frames
        #expect(frames[1]!.maxY == Self.rect.maxY)
        #expect(frames[2]!.minY == Self.rect.minY)
        #expect(frames[1]!.minY >= frames[2]!.maxY)
        #expect(abs(frames[1]!.width - Self.rect.width) < 0.001)
        #expect(abs(frames[2]!.width - Self.rect.width) < 0.001)
        #expect(abs(frames[1]!.height - 300) < 0.001)
    }

    @Test("size is respected for the feature region extent")
    func sizeRespected() {
        let frames = Self.plan([1, 2], size: 0.75).frames
        #expect(abs(frames[1]!.width - 750) < 0.001)
        #expect(abs(frames[2]!.width - 250) < 0.001)
    }

    @Test("equal-weight grid windows share the grid region equally")
    func gridWindowsEqual() {
        let frames = Self.plan([1, 2, 3], size: 0.5).frames
        #expect(frames[2]!.height == frames[3]!.height)
        #expect(abs(frames[2]!.height - Self.rect.height / 2) < 0.001)
    }

    @Test("feature windows and grid windows share their regions in proportion to weight")
    func regionsFollowWeight() {
        let weights: [WindowID: Double] = [1: 3, 2: 1, 3: 1, 4: 3]
        let frames = Self.plan([1, 2, 3, 4], count: 2, size: 0.5, weight: { weights[$0] ?? 1 }).frames
        #expect(frames[1]!.height == 375) // feature windows
        #expect(frames[2]!.height == 125)
        #expect(frames[3]!.height == 125) // grid
        #expect(frames[4]!.height == 375)
    }

    @Test("grid windows short of their minimum get it before the rest is shared by weight")
    func weightedGridHonoursMinimums() {
        // Weights 2:1:1 share 500 as 250/125/125. Window 4 needs 200, leaving
        // 300 to share 2:1 as 200/100; then window 3 needs 110, leaving 190.
        let weights: [WindowID: Double] = [2: 2, 3: 1, 4: 1]
        let minSizes: [WindowID: CGSize] = [3: CGSize(width: 0, height: 110), 4: CGSize(width: 0, height: 200)]
        let frames = Self.plan([1, 2, 3, 4], size: 0.5, weight: { weights[$0] ?? 1 },
                               minSize: { minSizes[$0] ?? .zero }).frames
        #expect(frames[2]!.height == 190)
        #expect(frames[3]!.height == 110)
        #expect(frames[4]!.height == 200)
    }

    @Test("the weight share limit caps weights at maxWeightRatio times the lightest in the region")
    func weightShareLimitCapsHeavyWindows() {
        // At 3×, weights 10:2:1 count as 3:2:1: the heavy window is reined in
        // and the lighter two keep their 2:1 proportion.
        let rect = CGRect(x: 0, y: 0, width: 1000, height: 600)
        let weights: [WindowID: Double] = [2: 10, 3: 2, 4: 1]
        let frames = Self.plan([1, 2, 3, 4], in: rect, size: 0.5, weight: { weights[$0] ?? 1 }, maxWeightRatio: 3).frames
        #expect(frames[2]!.height == 300)
        #expect(frames[3]!.height == 200)
        #expect(frames[4]!.height == 100)
    }

    @Test("gaps appear between tiles and never outside rect")
    func gapsBetweenTilesOnly() {
        let gap = 10.0
        let frames = Self.plan([1, 2, 3], size: 0.5, gap: gap).frames
        for frame in frames.values {
            #expect(frame.minX >= Self.rect.minX - 0.001)
            #expect(frame.maxX <= Self.rect.maxX + 0.001)
            #expect(frame.minY >= Self.rect.minY - 0.001)
            #expect(frame.maxY <= Self.rect.maxY + 0.001)
        }
        // Gap between the feature (1, left) and the grid (2, right).
        #expect(abs((frames[2]!.minX - frames[1]!.maxX) - gap) < 0.5)
        // Gap between the two stacked grid windows (2 above 3).
        #expect(abs((frames[3]!.minY - frames[2]!.maxY) - gap) < 0.5)
    }

    @Test("with no grid tile the feature windows fill the whole area")
    func allFeaturedFillsArea() {
        for feature in [FeatureSide.left, .right, .center] {
            let frames = Self.plan([1, 2], feature: feature, count: 2).frames
            // Features tile along the cross axis (vertical), each spanning the rect's full width.
            for frame in frames.values {
                #expect(abs(frame.width - Self.rect.width) < 0.001, "\(feature)")
            }
            let totalHeight = frames.values.map(\.height).reduce(0, +)
            #expect(abs(totalHeight - Self.rect.height) < 0.001, "\(feature)")
        }
        // Top/bottom features tile side by side instead.
        let top = Self.plan([1, 2], feature: .top, count: 2).frames
        #expect(top.values.allSatisfy { abs($0.height - Self.rect.height) < 0.001 })
        #expect(abs(top.values.map(\.width).reduce(0, +) - Self.rect.width) < 0.001)
    }

    @Test("a feature count beyond the window count makes every window featured")
    func featureCountExceedsWindows() {
        let frames = Self.plan([1, 2], count: 10).frames
        #expect(frames.count == 2)
        for frame in frames.values {
            #expect(abs(frame.width - Self.rect.width) < 0.001)
        }
        let totalHeight = frames.values.map(\.height).reduce(0, +)
        #expect(abs(totalHeight - Self.rect.height) < 0.001)
    }

    @Test("empty order yields no frames")
    func emptyOrderYieldsNoFrames() {
        #expect(Self.plan([]).frames.isEmpty)
    }

    @Test("feasible minSize clamps the feature length up to the grid's minimum")
    func minSizeFeasibleClamp() {
        let minSizes: [WindowID: CGSize] = [2: CGSize(width: 500, height: 0)]
        let frames = Self.plan([1, 2], gap: 10, minSize: { minSizes[$0] ?? .zero }).frames
        #expect(abs(frames[1]!.width - 490) < 0.001)
        #expect(abs(frames[2]!.width - 500) < 0.001)
    }

    @Test("infeasible minSize falls back to a proportional split")
    func minSizeInfeasibleFallback() {
        let minSizes: [WindowID: CGSize] = [1: CGSize(width: 600, height: 0), 2: CGSize(width: 500, height: 0)]
        let frames = Self.plan([1, 2], gap: 10, minSize: { minSizes[$0] ?? .zero }).frames
        #expect(abs(frames[1]!.width - 540) < 0.001)
        #expect(abs(frames[2]!.width - 450) < 0.001)
    }

    @Test("multiple feature windows tile in the feature column alongside a grid")
    func multipleFeaturesTileInColumn() {
        let frames = Self.plan([1, 2, 3], count: 2, gap: 10).frames
        #expect(abs(frames[1]!.width - 594) < 0.001)
        #expect(abs(frames[2]!.width - 594) < 0.001)
        #expect(abs(frames[1]!.height - 245) < 0.001)
        #expect(abs(frames[2]!.height - 245) < 0.001)
    }

    @Test("feature_count 2 puts the first two windows in the feature, the rest in the grid")
    func featureCountTwo() {
        let frames = Self.plan([1, 2, 3, 4], count: 2, size: 0.5).frames
        #expect(frames[1] == CGRect(x: 0, y: 0, width: 500, height: 250))
        #expect(frames[2] == CGRect(x: 0, y: 250, width: 500, height: 250))
        #expect(frames[3] == CGRect(x: 500, y: 0, width: 500, height: 250))
        #expect(frames[4] == CGRect(x: 500, y: 250, width: 500, height: 250))
    }

    @Test("non-finite size falls back to 0.5")
    func nonFiniteSizeFallsBack() {
        let frames = Self.plan([1, 2], size: .nan).frames
        #expect(abs(frames[1]!.width - 500) < 0.001)
        #expect(abs(frames[2]!.width - 500) < 0.001)
    }

    @Test("size above 0.95 is clamped")
    func sizeClampedAboveMax() {
        let frames = Self.plan([1, 2], size: 2).frames
        #expect(abs(frames[1]!.width - 950) < 0.001)
        #expect(abs(frames[2]!.width - 50) < 0.001)
    }

    @Test("a feature count of zero is treated as one")
    func featureCountZeroBecomesOne() {
        let frames = Self.plan([1, 2], count: 0).frames
        #expect(abs(frames[1]!.width - 600) < 0.001)
        #expect(abs(frames[2]!.width - 400) < 0.001)
    }

    @Test("featured count: none without a feature, else clamped to 1…total")
    func featuredCount() {
        #expect(FeatureLayout.featuredCount(feature: .off, count: 3, total: 5) == 0)
        #expect(FeatureLayout.featuredCount(feature: .left, count: 3, total: 5) == 3)
        #expect(FeatureLayout.featuredCount(feature: .left, count: 9, total: 5) == 5)
        #expect(FeatureLayout.featuredCount(feature: .center, count: 0, total: 5) == 1)
    }

    // MARK: - No feature

    @Test("no feature: one column fills the whole rect")
    func noFeatureSingleColumn() {
        let frames = Self.plan([1, 2, 3, 4], feature: .off).frames
        for id: WindowID in 1...4 {
            #expect(Self.near(frames[id], CGRect(x: 0, y: CGFloat(id - 1) * 125, width: 1000, height: 125)))
        }
    }

    @Test("no feature: columns fill the rect left to right, column-major")
    func noFeatureColumnsFillLeftToRight() {
        let frames = Self.plan(Array(1...4), feature: .off, grid: .fixed(columns: 2, limit: nil)).frames
        #expect(frames[1] == CGRect(x: 0, y: 0, width: 500, height: 250))
        #expect(frames[2] == CGRect(x: 0, y: 250, width: 500, height: 250))
        #expect(frames[3] == CGRect(x: 500, y: 0, width: 500, height: 250))
        #expect(frames[4] == CGRect(x: 500, y: 250, width: 500, height: 250))
    }

    @Test("no feature: tiles within columns × rows spread evenly over the columns")
    func noFeatureFewTilesSpread() {
        // 4 tiles in 3 columns of up to 2: 2/1/1, never an empty column.
        let plan = Self.plan(Array(1...4), feature: .off, grid: .fixed(columns: 3, limit: 2))
        #expect(Self.near(plan.frames[1], CGRect(x: 0, y: 0, width: 333.3, height: 250)))
        #expect(Self.near(plan.frames[2], CGRect(x: 0, y: 250, width: 333.3, height: 250)))
        #expect(Self.near(plan.frames[3], CGRect(x: 333.3, y: 0, width: 333.3, height: 500)))
        #expect(Self.near(plan.frames[4], CGRect(x: 666.7, y: 0, width: 333.3, height: 500)))
        #expect(plan.covered.isEmpty)
        #expect(plan.scrolling.isEmpty)

        // Fewer tiles than columns use only as many columns as tiles.
        let two = Self.plan([1, 2], feature: .off, grid: .fixed(columns: 3, limit: 2)).frames
        #expect(two[1] == CGRect(x: 0, y: 0, width: 500, height: 500))
        #expect(two[2] == CGRect(x: 500, y: 0, width: 500, height: 500))
    }

    @Test("no feature, 1×1: every tile sits in one full-area deck")
    func noFeatureOneByOneIsOneDeck() {
        let plan = Self.plan(Array(1...4), feature: .off, grid: .fixed(columns: 1, limit: 1), peek: 30, recent: [3])
        #expect(plan.inView == [3])
        #expect(plan.frames[3] == CGRect(x: 0, y: 30, width: 1000, height: 440))
        #expect(plan.scrolling == [1, 2, 3, 4])
        #expect(Set(plan.covered.keys) == [1, 2, 4])
        #expect(plan.behind == [3: [1, 2, 4]])
    }

    @Test("no feature: rows cap every column but the last, which decks the overflow")
    func noFeatureRowsCapWithOverflowDeck() {
        // 5 tiles, 2 columns of 2 rows: column 1 holds 1,2; column 2 holds 3,4,5 and scrolls.
        let plan = Self.plan(Array(1...5), feature: .off, grid: .fixed(columns: 2, limit: 2), peek: 30, recent: [3])
        #expect(plan.frames[1] == CGRect(x: 0, y: 0, width: 500, height: 250))
        #expect(plan.frames[2] == CGRect(x: 0, y: 250, width: 500, height: 250))
        #expect(plan.scrolling == [3, 4, 5])
        #expect(plan.inView == [1, 2, 3, 4])
        #expect(Set(plan.covered.keys) == [5])
        #expect(plan.frames[3]!.minX == 500 && plan.frames[4]!.minX == 500)
    }

    // MARK: - Scrolling deck column

    /// Feature 1 on the left half; grid column 2…n on the right half (x 500…1000).
    static func scrolling(_ count: WindowID, limit: Int, peek: Double = 30, recent: [WindowID] = [],
                          feature: FeatureSide = .left, gap: Double = 0,
                          weight: @escaping (WindowID) -> Double = { _ in 1 }) -> TilePlan {
        plan(Array(1...count), feature: feature, size: 0.5, grid: .fixed(columns: 1, limit: limit), gap: gap,
             peek: peek, recent: recent, weight: weight)
    }

    @Test("a grid column within its limit tiles every window and covers none")
    func columnWithinLimitTiles() {
        let limited = Self.scrolling(3, limit: 2)
        let plain = Self.plan([1, 2, 3], size: 0.5)
        #expect(limited.frames == plain.frames)
        #expect(limited.covered.isEmpty)
        #expect(limited.inView == [2, 3])
    }

    @Test("one window in view, inset by the peek; its neighbours peek out above and below")
    func oneInViewWithPeekingNeighbours() {
        let plan = Self.scrolling(4, limit: 1, recent: [3])
        #expect(plan.inView == [3])
        #expect(plan.frames[3] == CGRect(x: 500, y: 30, width: 500, height: 440))
        // The previous window sits one peek higher: its top strip shows.
        #expect(plan.frames[2] == CGRect(x: 500, y: 0, width: 500, height: 440))
        #expect(plan.covered[2] == CGRect(x: 500, y: 0, width: 500, height: 30))
        // The next window sits one peek lower: its bottom strip shows.
        #expect(plan.frames[4] == CGRect(x: 500, y: 60, width: 500, height: 440))
        #expect(plan.covered[4] == CGRect(x: 500, y: 470, width: 500, height: 30))
        #expect(plan.covered[3] == nil)
        #expect(plan.covered[1] == nil)
    }

    @Test("windows further away hide exactly behind the slot at their end of the view")
    func distantWindowsHideBehindTheView() {
        let plan = Self.scrolling(6, limit: 1, recent: [4])
        let view = plan.frames[4]!
        #expect(plan.frames[2] == view)
        #expect(plan.frames[6] == view)
        #expect(plan.covered[2]?.height == 0)
        #expect(plan.covered[6]?.height == 0)
        #expect(plan.covered[3]?.height == 30)
        #expect(plan.covered[5]?.height == 30)
    }

    @Test("the view and its peek strips span the whole grid region: an end with no window beyond it keeps no strip")
    func viewSpansTheGridRegion() {
        let sides: [(FeatureSide, Axis, Double)] = [(.left, .vertical, 500), (.top, .horizontal, 1000)]
        for (feature, axis, length) in sides {
            for limit in 1...2 {
                for recent: WindowID in 2...6 {
                    let plan = Self.scrolling(6, limit: limit, recent: [recent], feature: feature)
                    let showing = plan.inView.compactMap { plan.frames[$0] } + plan.covered.values.filter { $0.extent(axis) > 0 }
                    #expect(showing.map { $0.start(axis) }.min() == 0, "\(feature), limit \(limit), focus \(recent)")
                    #expect(showing.map { $0.end(axis) }.max() == length, "\(feature), limit \(limit), focus \(recent)")
                }
            }
        }
    }

    @Test("scrolling slots are equal whatever the weights")
    func scrollingSlotsIgnoreWeights() {
        let weights: [WindowID: Double] = [2: 5, 3: 1, 4: 2, 5: 1]
        let plan = Self.scrolling(5, limit: 2, recent: [3], weight: { weights[$0] ?? 1 })
        #expect(plan.inView == [2, 3])
        #expect(plan.frames[2]!.height == plan.frames[3]!.height)
        #expect(plan.frames[2]!.minY == 0)
        #expect(plan.frames[3]!.maxY == 470)
    }

    @Test("with nothing focused in the grid, the view starts at its top")
    func viewStartsAtTop() {
        let plan = Self.scrolling(5, limit: 1, recent: [1])
        #expect(plan.inView == [2])
        #expect(plan.covered[3]?.height == 30) // next peeks
        #expect(plan.frames[2] == CGRect(x: 500, y: 0, width: 500, height: 470)) // nothing above peeks: no top strip
    }

    @Test("the view holds the most recent deck window and scrolls as little as focus history allows")
    func viewFollowsFocusHistory() {
        let ids: [WindowID] = [10, 11, 12, 13, 14, 15]
        // Walking down one window at a time scrolls by one.
        #expect(DeckLayout.viewStart(ids, shown: 3, recent: [13, 12, 11, 10]) == 1)
        #expect(DeckLayout.viewStart(ids, shown: 3, recent: [14, 13, 12, 11, 10]) == 2)
        // Walking back up keeps the view until the focused window would leave it.
        #expect(DeckLayout.viewStart(ids, shown: 3, recent: [12, 13, 14, 11, 10]) == 2)
        #expect(DeckLayout.viewStart(ids, shown: 3, recent: [11, 12, 13, 14, 10]) == 1)
        // Features, floating windows and unknown ids in the history don't count.
        #expect(DeckLayout.viewStart(ids, shown: 3, recent: [99, 15]) == 3)
        #expect(DeckLayout.viewStart(ids, shown: 3, recent: []) == 0)
    }

    @Test("windows out of view continue the strip past both ends, beyond the peeking strips")
    func navigationStripContinuesPastTheView() {
        let plan = Self.scrolling(6, limit: 1, recent: [4], gap: 8)
        let region = CGRect(x: 504, y: 0, width: 496, height: 500)
        let nav = plan.navigation
        #expect(nav[3]!.maxY <= region.minY)
        #expect(nav[2]!.maxY <= nav[3]!.minY)
        #expect(nav[5]!.minY >= region.maxY)
        #expect(nav[6]!.minY >= nav[5]!.maxY)
        #expect(nav[4] == plan.frames[4])
        #expect(nav[1] == plan.frames[1])
    }

    @Test("a grid below a top feature decks vertically, like every column")
    func topFeatureGridScrollsVertically() {
        let plan = Self.scrolling(4, limit: 1, recent: [3], feature: .top)
        let view = plan.frames[3]!
        #expect(view.minX == 0 && view.maxX == 1000)
        #expect(plan.covered[2] == CGRect(x: 0, y: view.minY - 30, width: 1000, height: 30))
        #expect(plan.covered[4] == CGRect(x: 0, y: view.maxY, width: 1000, height: 30))
    }

    @Test("columns are vertical lines and rows stack top to bottom whatever side the feature is on")
    func columnsAndRowsAreLiteralForEveryFeatureSide() {
        for side in [FeatureSide.top, .bottom] {
            // One column, two rows: the two grid tiles stack, each full width.
            let stacked = Self.plan([1, 2, 3], feature: side, grid: .fixed(columns: 1, limit: 2)).frames
            #expect(stacked[2]!.width == 1000 && stacked[3]!.width == 1000)
            #expect(stacked[2]!.minY < stacked[3]!.minY && stacked[2]!.maxY <= stacked[3]!.minY)
            // Two columns, one row: side by side, filled left to right.
            let beside = Self.plan([1, 2, 3], feature: side, grid: .fixed(columns: 2, limit: 1)).frames
            #expect(beside[2]!.minX == 0 && beside[3]!.maxX == 1000)
            #expect(beside[2]!.maxX <= beside[3]!.minX)
            #expect(beside[2]!.minY == beside[3]!.minY && beside[2]!.height == beside[3]!.height)
        }
        // A side feature keeps filling from the column nearest it.
        let right = Self.plan([1, 2, 3], feature: .right, grid: .fixed(columns: 2, limit: 1)).frames
        #expect(right[2]!.minX > right[3]!.minX)
    }

    @Test("the peek never takes more than a quarter of the grid region")
    func peekIsCapped() {
        let plan = Self.plan([1, 2, 3, 4], in: CGRect(x: 0, y: 0, width: 100, height: 40), size: 0.5,
                             grid: .fixed(columns: 1, limit: 1), peek: 200, recent: [3])
        #expect(plan.frames[3]!.minY == 10)
        #expect(plan.frames[3]!.height == 20)
    }

    @Test("a zero peek tucks every other deck window fully behind the view")
    func zeroPeekHidesNeighbours() {
        let plan = Self.scrolling(4, limit: 1, peek: 0, recent: [3])
        #expect(plan.frames[2] == plan.frames[3])
        #expect(plan.frames[4] == plan.frames[3])
        #expect(plan.covered.values.allSatisfy { $0.height == 0 })
    }

    @Test("each end tile in view lists the scrolled-out windows behind it")
    func behindListsScrolledOutWindows() {
        #expect(Self.scrolling(6, limit: 1, recent: [4]).behind == [4: [2, 3, 5, 6]])
        #expect(Self.scrolling(6, limit: 2, recent: [4, 3]).behind == [3: [2], 4: [5, 6]])
        #expect(Self.scrolling(6, limit: 1, recent: [2]).behind == [2: [3, 4, 5, 6]])
        #expect(Self.scrolling(3, limit: 2).behind.isEmpty)
    }

    // MARK: - Columns and the centered feature

    @Test("column sizes: even with the extra up front, never empty, overflow into the outermost", arguments: [
        (5, 3, nil, [2, 2, 1]), (2, 3, nil, [1, 1]), (4, 2, 2, [2, 2]), (7, 2, 2, [2, 5]),
        (3, 1, 1, [3]), (0, 3, 2, []),
    ] as [(Int, Int, Int?, [Int])])
    func columnSizes(count: Int, columns: Int, limit: Int?, expected: [Int]) {
        #expect(FeatureLayout.columnSizes(count, columns: columns, limit: limit) == expected)
    }

    @Test("grid groups: a centered feature splits two or more tiles, the first half taking the extra one")
    func gridGroups() {
        #expect(FeatureLayout.gridGroups(5, columns: 2, limit: nil, center: true) == [[2, 1], [1, 1]])
        #expect(FeatureLayout.gridGroups(1, columns: 2, limit: nil, center: true) == [[1]])
        #expect(FeatureLayout.gridGroups(5, columns: 2, limit: nil, center: false) == [[3, 2]])
        #expect(FeatureLayout.gridGroups(0, columns: 2, limit: nil, center: true) == [[]])
    }

    @Test("a grid scrolls only once a half's outermost column passes the limit")
    func scrollsPerHalfAndColumn() {
        #expect(!FeatureLayout.scrolls(gridCount: 4, columns: 2, limit: 2, center: false))
        #expect(FeatureLayout.scrolls(gridCount: 5, columns: 2, limit: 2, center: false))
        #expect(!FeatureLayout.scrolls(gridCount: 2, columns: 1, limit: 1, center: true))
        #expect(FeatureLayout.scrolls(gridCount: 3, columns: 1, limit: 1, center: true))
        #expect(!FeatureLayout.scrolls(gridCount: 9, columns: 3, limit: nil, center: true))
    }

    @Test("slot: the half, and the column counted from the feature outward")
    func slotOfGridIndex() {
        // 5 tiles centered, 2 columns: right half [2,1] (tiles 0,1,2), left half [1,1] (tiles 3,4).
        let slots = (0..<5).map { FeatureLayout.slot(ofGridIndex: $0, gridCount: 5, columns: 2, limit: nil, center: true) }
        #expect(slots.map(\.half) == [0, 0, 0, 1, 1])
        #expect(slots.map(\.column) == [0, 0, 1, 0, 1])
        #expect(slots.allSatisfy { $0.halves == 2 && $0.columns == 2 })
        let one = FeatureLayout.slot(ofGridIndex: 0, gridCount: 1, columns: 2, limit: nil, center: true)
        #expect(one.halves == 1 && one.columns == 1)
    }

    @Test("columns fill column-major from the one next to the feature")
    func columnsFillFromTheFeature() {
        let left = Self.plan(Array(1...6), size: 0.5, grid: .fixed(columns: 3, limit: nil)).frames
        #expect(left[1] == CGRect(x: 0, y: 0, width: 500, height: 500))
        #expect(left[2] == CGRect(x: 500, y: 0, width: 167, height: 250))
        #expect(left[3] == CGRect(x: 500, y: 250, width: 167, height: 250))
        #expect(left[4]!.minX == 667 && left[5]!.minX == 667)
        #expect(left[6] == CGRect(x: 833, y: 0, width: 167, height: 500))

        let right = Self.plan([1, 2, 3], feature: .right, size: 0.5, grid: .fixed(columns: 2, limit: nil)).frames
        #expect(right[2] == CGRect(x: 250, y: 0, width: 250, height: 500))
        #expect(right[3] == CGRect(x: 0, y: 0, width: 250, height: 500))
    }

    @Test("past columns × limit only the outermost column scrolls")
    func overflowScrollsOutermostColumn() {
        let plan = Self.plan(Array(1...5), size: 0.5, grid: .fixed(columns: 2, limit: 1), peek: 30, recent: [4])
        #expect(plan.frames[2] == CGRect(x: 500, y: 0, width: 250, height: 500))
        #expect(plan.inView == [2, 4])
        #expect(Set(plan.covered.keys) == [3, 5])
        #expect(plan.behind == [4: [3, 5]])
        // Only the scrolling column's windows slide as focus moves through it.
        #expect(plan.scrolling == [3, 4, 5])
        #expect(plan.frames[4]!.minX == 750 && plan.frames[4]!.minY == 30 && plan.frames[4]!.maxY == 470)
    }

    @Test("center: the feature keeps its size in the middle, the right half takes the first half of the tiles")
    func centerPutsTheFeatureInTheMiddle() {
        let plan = Self.plan([1, 2, 3, 4], feature: .center, size: 0.5, gap: 10)
        #expect(plan.frames[4] == CGRect(x: 0, y: 0, width: 245, height: 500))
        #expect(plan.frames[1] == CGRect(x: 255, y: 0, width: 490, height: 500))
        #expect(plan.frames[2] == CGRect(x: 755, y: 0, width: 245, height: 245))
        #expect(plan.frames[3] == CGRect(x: 755, y: 255, width: 245, height: 245))
        #expect(plan.inView == [2, 3, 4])
    }

    @Test("center: the right half gets ceil(n/2) tiles, the left half the rest")
    func centerHalvesSplit() {
        let five = Self.plan(Array(1...6), feature: .center, size: 0.5).frames // 5 grid tiles
        let right = (2...6).filter { five[WindowID($0)]!.minX >= 750 }
        let left = (2...6).filter { five[WindowID($0)]!.maxX <= 250 }
        #expect(right == [2, 3, 4])
        #expect(left == [5, 6])

        let four = Self.plan(Array(1...5), feature: .center, size: 0.5).frames // 4 grid tiles
        #expect((2...5).filter { four[WindowID($0)]!.minX >= 750 } == [2, 3])
        #expect((2...5).filter { four[WindowID($0)]!.maxX <= 250 } == [4, 5])
    }

    @Test("center: one grid tile sits on the right only, exactly like a left feature")
    func centerWithOneGridTile() {
        let center = Self.plan([1, 2], feature: .center, size: 0.6, gap: 8)
        let left = Self.plan([1, 2], feature: .left, size: 0.6, gap: 8)
        #expect(center == left)
        #expect(center.frames[1]!.minX == 0 && center.frames[2]!.maxX == 1000)
    }

    @Test("center: each half fills its columns from the one nearest the feature")
    func centerColumns() {
        let frames = Self.plan(Array(1...5), feature: .center, size: 0.5, grid: .fixed(columns: 2, limit: nil)).frames
        #expect(frames[1] == CGRect(x: 250, y: 0, width: 500, height: 500))
        #expect(frames[2] == CGRect(x: 750, y: 0, width: 125, height: 500)) // right half, nearest column
        #expect(frames[3] == CGRect(x: 875, y: 0, width: 125, height: 500))
        #expect(frames[4] == CGRect(x: 125, y: 0, width: 125, height: 500)) // left half, nearest column
        #expect(frames[5] == CGRect(x: 0, y: 0, width: 125, height: 500))
    }

    @Test("center honours learned minimum widths before the size")
    func centerMinimumWidths() {
        let frames = Self.plan([1, 2, 3], feature: .center, size: 0.8,
                               minSize: { $0 == 3 ? CGSize(width: 300, height: 0) : .zero }).frames
        #expect(frames[3]!.width == 300)
        #expect(frames[1]!.width >= 0 && frames[2]!.width >= 0)
        #expect(frames[3]!.maxX <= frames[1]!.minX && frames[1]!.maxX <= frames[2]!.minX)
        #expect(frames[2]!.maxX == 1000)
    }

    // MARK: - Adaptive grid

    @Test("adaptive: the grid region is laid out as an adaptive grid beside the feature")
    func adaptiveBesideFeature() {
        let frames = Self.plan(Array(1...5), size: 0.5, grid: .adaptive).frames
        #expect(frames[1] == CGRect(x: 0, y: 0, width: 500, height: 500))
        #expect(frames[2] == CGRect(x: 500, y: 0, width: 250, height: 250))
        #expect(frames[3] == CGRect(x: 750, y: 0, width: 250, height: 250))
        #expect(frames[4] == CGRect(x: 500, y: 250, width: 250, height: 250))
        #expect(frames[5] == CGRect(x: 750, y: 250, width: 250, height: 250))
    }

    @Test("adaptive without a feature fills the whole rect like a plain adaptive grid")
    func adaptiveWithoutFeature() {
        let plan = Self.plan([1, 2, 3, 4], feature: .off, grid: .adaptive)
        let plain = GridLayout.plan(order: [1, 2, 3, 4], in: Self.rect, gap: 0, minSize: { _ in .zero })
        #expect(plan.frames == plain.frames)
    }

    @Test("adaptive with a centered feature: each half is its own adaptive grid")
    func adaptiveCenterHalves() {
        let frames = Self.plan(Array(1...6), feature: .center, size: 0.5, grid: .adaptive).frames
        #expect(frames[1] == CGRect(x: 250, y: 0, width: 500, height: 500))
        // Right half (x 750…1000): 2, 3, 4 — a 250×500 portrait grid, two on top, the last spanning the width.
        #expect(frames[2] == CGRect(x: 750, y: 0, width: 125, height: 250))
        #expect(frames[3] == CGRect(x: 875, y: 0, width: 125, height: 250))
        #expect(frames[4] == CGRect(x: 750, y: 250, width: 250, height: 250))
        // Left half (x 0…250): 5, 6 stacked.
        #expect(frames[5] == CGRect(x: 0, y: 0, width: 250, height: 250))
        #expect(frames[6] == CGRect(x: 0, y: 250, width: 250, height: 250))
    }

    @Test("adaptive and custom grids push the feature boundary to their windows' minimum width")
    func nonFixedGridsReserveMinSize() {
        let minSize: (WindowID) -> CGSize = { $0 == 2 ? CGSize(width: 650, height: 0) : .zero }
        let adaptive = Self.plan([1, 2], size: 0.6, grid: .adaptive, minSize: minSize).frames
        #expect(abs(adaptive[2]!.width - 650) < 0.001)
        var region: CGRect?
        _ = Self.plan([1, 2], size: 0.6, grid: .custom({ r in region = r; return TilePlan() }), minSize: minSize)
        #expect(abs((region?.width ?? 0) - 650) < 0.001)
    }

    // MARK: - Custom grid renderer

    @Test("a custom grid renderer is called once with the grid region's rect and its plan is merged in")
    func customRendererGetsTheRegion() {
        var received: [CGRect] = []
        let plan = Self.plan([1, 2, 3], size: 0.5, grid: .custom({ region in
            received.append(region)
            return TilePlan(frames: [9: region], navigation: [9: region])
        }), gap: 10)
        let region = CGRect(x: 505, y: 0, width: 495, height: 500)
        #expect(received == [region])
        #expect(plan.frames[9] == region)
        #expect(plan.frames[1] == CGRect(x: 0, y: 0, width: 495, height: 500)) // feature still laid out
        #expect(plan.frames[2] == nil && plan.frames[3] == nil) // the renderer owns the grid's windows
    }

    @Test("a custom renderer with no feature gets the whole rect; with a centered feature the region is not split")
    func customRendererRegions() {
        var received: [CGRect] = []
        let render: (CGRect) -> TilePlan = { received.append($0); return TilePlan() }
        _ = Self.plan([1, 2, 3], feature: .off, grid: .custom(render))
        #expect(received == [Self.rect])
        received = []
        _ = Self.plan([1, 2, 3, 4], feature: .center, size: 0.5, grid: .custom(render))
        #expect(received == [CGRect(x: 500, y: 0, width: 500, height: 500)]) // one region right of the feature
    }

    @Test("a custom renderer is not called when every window is featured")
    func customRendererSkippedWhenAllFeatured() {
        var calls = 0
        _ = Self.plan([1, 2], count: 2, grid: .custom({ _ in calls += 1; return TilePlan() }))
        #expect(calls == 0)
    }
}
