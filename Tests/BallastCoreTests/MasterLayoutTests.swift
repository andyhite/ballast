import CoreGraphics
import Testing
@testable import BallastCore

@Suite("MasterLayout")
struct MasterLayoutTests {

    static let rect = CGRect(x: 0, y: 0, width: 1000, height: 500)

    // `side` names the STACK's side (StackSide / LayoutSettings.stackSide);
    // the master region occupies the opposite side.

    @Test("side right: stack on the right, master on the left")
    func sideRight() {
        let frames = MasterLayout.plan(order: [1, 2], in: Self.rect, masterCount: 1, ratio: 0.6, side: .right, gap: 0).frames
        #expect(frames[1]!.minX == Self.rect.minX) // master on the left
        #expect(frames[2]!.maxX == Self.rect.maxX) // stack on the right
        #expect(frames[2]!.minX >= frames[1]!.maxX)
    }

    @Test("side left: stack on the left, master on the right")
    func sideLeft() {
        let frames = MasterLayout.plan(order: [1, 2], in: Self.rect, masterCount: 1, ratio: 0.6, side: .left, gap: 0).frames
        #expect(frames[1]!.maxX == Self.rect.maxX) // master on the right
        #expect(frames[2]!.minX == Self.rect.minX) // stack on the left
        #expect(frames[1]!.minX >= frames[2]!.maxX)
        #expect(abs(frames[1]!.width - 600) < 0.001) // master extent = ratio * width
    }

    @Test("side bottom: stack at the bottom, master at the top")
    func sideBottom() {
        let frames = MasterLayout.plan(order: [1, 2], in: Self.rect, masterCount: 1, ratio: 0.6, side: .bottom, gap: 0).frames
        #expect(frames[1]!.minY == Self.rect.minY) // master on top
        #expect(frames[2]!.maxY == Self.rect.maxY) // stack on bottom
        #expect(frames[2]!.minY >= frames[1]!.maxY)
        #expect(abs(frames[1]!.width - Self.rect.width) < 0.001) // full-width tiles
        #expect(abs(frames[2]!.width - Self.rect.width) < 0.001)
        #expect(abs(frames[1]!.height - 300) < 0.001) // master extent = ratio * height
    }

    @Test("side top: stack at the top, master at the bottom")
    func sideTop() {
        let frames = MasterLayout.plan(order: [1, 2], in: Self.rect, masterCount: 1, ratio: 0.6, side: .top, gap: 0).frames
        #expect(frames[1]!.maxY == Self.rect.maxY) // master on bottom
        #expect(frames[2]!.minY == Self.rect.minY) // stack on top
        #expect(frames[1]!.minY >= frames[2]!.maxY)
        #expect(abs(frames[1]!.width - Self.rect.width) < 0.001) // full-width tiles
        #expect(abs(frames[2]!.width - Self.rect.width) < 0.001)
        #expect(abs(frames[1]!.height - 300) < 0.001) // master extent = ratio * height
    }

    @Test("ratio is respected for master region extent")
    func ratioRespected() {
        let frames = MasterLayout.plan(order: [1, 2], in: Self.rect, masterCount: 1, ratio: 0.75, side: .right, gap: 0).frames
        #expect(abs(frames[1]!.width - 750) < 0.001)
        #expect(abs(frames[2]!.width - 250) < 0.001)
    }

    @Test("equal-weight stack windows share the stack region equally")
    func stackWindowsEqual() {
        let frames = MasterLayout.plan(order: [1, 2, 3], in: Self.rect, masterCount: 1, ratio: 0.5, side: .right, gap: 0).frames
        #expect(frames[2]!.height == frames[3]!.height)
        #expect(abs(frames[2]!.height - Self.rect.height / 2) < 0.001)
    }

    @Test("masters and stack windows share their regions in proportion to weight")
    func regionsFollowWeight() {
        let weights: [WindowID: Double] = [1: 3, 2: 1, 3: 1, 4: 3]
        let frames = MasterLayout.plan(order: [1, 2, 3, 4], in: Self.rect, masterCount: 2, ratio: 0.5, side: .right, gap: 0,
                                       weight: { weights[$0] ?? 1 }).frames
        #expect(frames[1]!.height == 375) // masters
        #expect(frames[2]!.height == 125)
        #expect(frames[3]!.height == 125) // stack
        #expect(frames[4]!.height == 375)
    }

    @Test("stack windows short of their minimum get it before the rest is shared by weight")
    func weightedStackHonoursMinimums() {
        // Weights 2:1:1 share 500 as 250/125/125. Window 4 needs 200, leaving
        // 300 to share 2:1 as 200/100; then window 3 needs 110, leaving 190.
        let weights: [WindowID: Double] = [2: 2, 3: 1, 4: 1]
        let minSizes: [WindowID: CGSize] = [3: CGSize(width: 0, height: 110), 4: CGSize(width: 0, height: 200)]
        let frames = MasterLayout.plan(order: [1, 2, 3, 4], in: Self.rect, masterCount: 1, ratio: 0.5, side: .right, gap: 0,
                                       weight: { weights[$0] ?? 1 }, minSize: { minSizes[$0] ?? .zero }).frames
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
        let frames = MasterLayout.plan(order: [1, 2, 3, 4], in: rect, masterCount: 1, ratio: 0.5, side: .right, gap: 0,
                                       weight: { weights[$0] ?? 1 }, maxWeightRatio: 3).frames
        #expect(frames[2]!.height == 300)
        #expect(frames[3]!.height == 200)
        #expect(frames[4]!.height == 100)
    }

    @Test("gaps appear between tiles and never outside rect")
    func gapsBetweenTilesOnly() {
        let gap = 10.0
        let frames = MasterLayout.plan(order: [1, 2, 3], in: Self.rect, masterCount: 1, ratio: 0.5, side: .right, gap: gap).frames
        // No frame extends outside rect.
        for frame in frames.values {
            #expect(frame.minX >= Self.rect.minX - 0.001)
            #expect(frame.maxX <= Self.rect.maxX + 0.001)
            #expect(frame.minY >= Self.rect.minY - 0.001)
            #expect(frame.maxY <= Self.rect.maxY + 0.001)
        }
        // Gap between master (1, left) and stack (2, right).
        #expect(abs((frames[2]!.minX - frames[1]!.maxX) - gap) < 0.5)
        // Gap between the two stacked windows (2 above 3).
        #expect(abs((frames[3]!.minY - frames[2]!.maxY) - gap) < 0.5)
    }
    @Test("empty stack lets masters fill the whole area")
    func emptyStackFillsArea() {
        let frames = MasterLayout.plan(order: [1, 2], in: Self.rect, masterCount: 2, ratio: 0.6, side: .right, gap: 0).frames
        // Masters tile along the cross axis (vertical for side .right/.left),
        // each spanning the rect's full width; heights sum to the rect's height.
        for frame in frames.values {
            #expect(abs(frame.width - Self.rect.width) < 0.001)
        }
        let totalHeight = frames.values.map(\.height).reduce(0, +)
        #expect(abs(totalHeight - Self.rect.height) < 0.001)
    }

    @Test("masterCount greater than window count is handled")
    func masterCountExceedsWindows() {
        let frames = MasterLayout.plan(order: [1, 2], in: Self.rect, masterCount: 10, ratio: 0.6, side: .right, gap: 0).frames
        #expect(frames.count == 2)
        // All windows become masters, filling the rect (tiled along the cross axis).
        for frame in frames.values {
            #expect(abs(frame.width - Self.rect.width) < 0.001)
        }
        let totalHeight = frames.values.map(\.height).reduce(0, +)
        #expect(abs(totalHeight - Self.rect.height) < 0.001)
    }
    @Test("empty order yields no frames")
    func emptyOrderYieldsNoFrames() {
        let frames = MasterLayout.plan(order: [], in: Self.rect, masterCount: 1, ratio: 0.6, side: .right, gap: 0).frames
        #expect(frames.isEmpty)
    }

    @Test("feasible minSize clamps master length up to the stack's minimum")
    func minSizeFeasibleClamp() {
        let rect = CGRect(x: 0, y: 0, width: 1000, height: 500)
        let minSizes: [WindowID: CGSize] = [2: CGSize(width: 500, height: 0)]
        let frames = MasterLayout.plan(order: [1, 2], in: rect, masterCount: 1, ratio: 0.6, side: .right, gap: 10,
                                       minSize: { minSizes[$0] ?? .zero }).frames
        #expect(abs(frames[1]!.width - 490) < 0.001)
        #expect(abs(frames[2]!.width - 500) < 0.001)
    }

    @Test("infeasible minSize falls back to a proportional split")
    func minSizeInfeasibleFallback() {
        let rect = CGRect(x: 0, y: 0, width: 1000, height: 500)
        let minSizes: [WindowID: CGSize] = [1: CGSize(width: 600, height: 0), 2: CGSize(width: 500, height: 0)]
        let frames = MasterLayout.plan(order: [1, 2], in: rect, masterCount: 1, ratio: 0.6, side: .right, gap: 10,
                                       minSize: { minSizes[$0] ?? .zero }).frames
        #expect(abs(frames[1]!.width - 540) < 0.001)
        #expect(abs(frames[2]!.width - 450) < 0.001)
    }

    @Test("multiple masters tile in the master column alongside a stack")
    func multipleMastersTileInColumn() {
        let frames = MasterLayout.plan(order: [1, 2, 3], in: Self.rect, masterCount: 2, ratio: 0.6, side: .right, gap: 10).frames
        #expect(abs(frames[1]!.width - 594) < 0.001)
        #expect(abs(frames[2]!.width - 594) < 0.001)
        #expect(abs(frames[1]!.height - 245) < 0.001)
        #expect(abs(frames[2]!.height - 245) < 0.001)
    }

    @Test("non-finite ratio falls back to 0.5")
    func nonFiniteRatioFallsBack() {
        let frames = MasterLayout.plan(order: [1, 2], in: Self.rect, masterCount: 1, ratio: .nan, side: .right, gap: 0).frames
        #expect(abs(frames[1]!.width - 500) < 0.001)
        #expect(abs(frames[2]!.width - 500) < 0.001)
    }

    @Test("ratio above 0.95 is clamped")
    func ratioClampedAboveMax() {
        let frames = MasterLayout.plan(order: [1, 2], in: Self.rect, masterCount: 1, ratio: 2, side: .right, gap: 0).frames
        #expect(abs(frames[1]!.width - 950) < 0.001)
        #expect(abs(frames[2]!.width - 50) < 0.001)
    }

    @Test("masterCount of zero is treated as one master")
    func masterCountZeroBecomesOne() {
        let frames = MasterLayout.plan(order: [1, 2], in: Self.rect, masterCount: 0, ratio: 0.6, side: .right, gap: 0).frames
        #expect(abs(frames[1]!.width - 600) < 0.001)
        #expect(abs(frames[2]!.width - 400) < 0.001)
    }

    // MARK: - Scrolling stack

    /// Master 1 on the left half; stack 2…n on the right half (x 500…1000).
    static func scrolling(_ count: WindowID, limit: Int, peek: Double = 30, recent: [WindowID] = [],
                          side: StackSide = .right, gap: Double = 0,
                          weight: @escaping (WindowID) -> Double = { _ in 1 }) -> MasterLayout.Plan {
        MasterLayout.plan(order: Array(1...count), in: rect, masterCount: 1, ratio: 0.5, side: side, gap: gap,
                          stackLimit: limit, peek: peek, recent: recent, weight: weight)
    }

    @Test("a stack within its limit tiles every window and covers none")
    func stackWithinLimitTiles() {
        let limited = Self.scrolling(3, limit: 2)
        let plain = MasterLayout.plan(order: [1, 2, 3], in: Self.rect, masterCount: 1, ratio: 0.5, side: .right, gap: 0)
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

    @Test("the view and its peek strips span the whole stack region: an end with no window beyond it keeps no strip")
    func viewSpansTheStackRegion() {
        let sides: [(StackSide, Axis, Double)] = [(.right, .vertical, 500), (.bottom, .horizontal, 1000)]
        for (side, axis, length) in sides {
            for limit in 1...2 {
                for recent: WindowID in 2...6 {
                    let plan = Self.scrolling(6, limit: limit, recent: [recent], side: side)
                    let showing = plan.inView.compactMap { plan.frames[$0] } + plan.covered.values.filter { $0.extent(axis) > 0 }
                    #expect(showing.map { $0.start(axis) }.min() == 0, "\(side), limit \(limit), focus \(recent)")
                    #expect(showing.map { $0.end(axis) }.max() == length, "\(side), limit \(limit), focus \(recent)")
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

    @Test("with nothing focused in the stack, the view starts at its top")
    func viewStartsAtTop() {
        let plan = Self.scrolling(5, limit: 1, recent: [1])
        #expect(plan.inView == [2])
        #expect(plan.covered[3]?.height == 30) // next peeks
        #expect(plan.frames[2] == CGRect(x: 500, y: 0, width: 500, height: 470)) // nothing above peeks: no top strip
    }

    @Test("the view holds the most recent stack window and scrolls as little as focus history allows")
    func viewFollowsFocusHistory() {
        let ids: [WindowID] = [10, 11, 12, 13, 14, 15]
        // Walking down one window at a time scrolls by one.
        #expect(MasterLayout.viewStart(ids, shown: 3, recent: [13, 12, 11, 10]) == 1)
        #expect(MasterLayout.viewStart(ids, shown: 3, recent: [14, 13, 12, 11, 10]) == 2)
        // Walking back up keeps the view until the focused window would leave it.
        #expect(MasterLayout.viewStart(ids, shown: 3, recent: [12, 13, 14, 11, 10]) == 2)
        #expect(MasterLayout.viewStart(ids, shown: 3, recent: [11, 12, 13, 14, 10]) == 1)
        // Masters, floating windows and unknown ids in the history don't count.
        #expect(MasterLayout.viewStart(ids, shown: 3, recent: [99, 15]) == 3)
        #expect(MasterLayout.viewStart(ids, shown: 3, recent: []) == 0)
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

    @Test("a bottom stack scrolls sideways")
    func bottomStackScrollsHorizontally() {
        let plan = Self.scrolling(4, limit: 1, recent: [3], side: .bottom)
        let view = plan.frames[3]!
        #expect(view.minX == 30 && view.maxX == 970)
        #expect(plan.covered[2] == CGRect(x: 0, y: view.minY, width: 30, height: view.height))
        #expect(plan.covered[4] == CGRect(x: 970, y: view.minY, width: 30, height: view.height))
    }

    @Test("the peek never takes more than a quarter of the stack region")
    func peekIsCapped() {
        let plan = MasterLayout.plan(order: [1, 2, 3, 4], in: CGRect(x: 0, y: 0, width: 100, height: 40), masterCount: 1,
                                     ratio: 0.5, side: .right, gap: 0, stackLimit: 1, peek: 200, recent: [3])
        #expect(plan.frames[3]!.minY == 10)
        #expect(plan.frames[3]!.height == 20)
    }

    @Test("a zero peek tucks every other stack window fully behind the view")
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
}
