import CoreGraphics
import Testing
@testable import BallastCore

@Suite("MasterStackLayout")
struct MasterStackTests {

    static let rect = CGRect(x: 0, y: 0, width: 1000, height: 500)

    // `side` names the STACK's side (StackSide / LayoutSettings.stackSide);
    // the master region occupies the opposite side.

    @Test("side right: stack on the right, master on the left")
    func sideRight() {
        let frames = MasterStackLayout.frames(order: [1, 2], in: Self.rect, masterCount: 1, ratio: 0.6, side: .right, gap: 0)
        #expect(frames[1]!.minX == Self.rect.minX) // master on the left
        #expect(frames[2]!.maxX == Self.rect.maxX) // stack on the right
        #expect(frames[2]!.minX >= frames[1]!.maxX)
    }

    @Test("side left: stack on the left, master on the right")
    func sideLeft() {
        let frames = MasterStackLayout.frames(order: [1, 2], in: Self.rect, masterCount: 1, ratio: 0.6, side: .left, gap: 0)
        #expect(frames[1]!.maxX == Self.rect.maxX) // master on the right
        #expect(frames[2]!.minX == Self.rect.minX) // stack on the left
        #expect(frames[1]!.minX >= frames[2]!.maxX)
        #expect(abs(frames[1]!.width - 600) < 0.001) // master extent = ratio * width
    }

    @Test("side bottom: stack at the bottom, master at the top")
    func sideBottom() {
        let frames = MasterStackLayout.frames(order: [1, 2], in: Self.rect, masterCount: 1, ratio: 0.6, side: .bottom, gap: 0)
        #expect(frames[1]!.minY == Self.rect.minY) // master on top
        #expect(frames[2]!.maxY == Self.rect.maxY) // stack on bottom
        #expect(frames[2]!.minY >= frames[1]!.maxY)
        #expect(abs(frames[1]!.width - Self.rect.width) < 0.001) // full-width tiles
        #expect(abs(frames[2]!.width - Self.rect.width) < 0.001)
        #expect(abs(frames[1]!.height - 300) < 0.001) // master extent = ratio * height
    }

    @Test("side top: stack at the top, master at the bottom")
    func sideTop() {
        let frames = MasterStackLayout.frames(order: [1, 2], in: Self.rect, masterCount: 1, ratio: 0.6, side: .top, gap: 0)
        #expect(frames[1]!.maxY == Self.rect.maxY) // master on bottom
        #expect(frames[2]!.minY == Self.rect.minY) // stack on top
        #expect(frames[1]!.minY >= frames[2]!.maxY)
        #expect(abs(frames[1]!.width - Self.rect.width) < 0.001) // full-width tiles
        #expect(abs(frames[2]!.width - Self.rect.width) < 0.001)
        #expect(abs(frames[1]!.height - 300) < 0.001) // master extent = ratio * height
    }

    @Test("ratio is respected for master region extent")
    func ratioRespected() {
        let frames = MasterStackLayout.frames(order: [1, 2], in: Self.rect, masterCount: 1, ratio: 0.75, side: .right, gap: 0)
        #expect(abs(frames[1]!.width - 750) < 0.001)
        #expect(abs(frames[2]!.width - 250) < 0.001)
    }

    @Test("equal-weight stack windows share the stack region equally")
    func stackWindowsEqual() {
        let frames = MasterStackLayout.frames(order: [1, 2, 3], in: Self.rect, masterCount: 1, ratio: 0.5, side: .right, gap: 0)
        #expect(frames[2]!.height == frames[3]!.height)
        #expect(abs(frames[2]!.height - Self.rect.height / 2) < 0.001)
    }

    @Test("masters and stack windows share their regions in proportion to weight")
    func regionsFollowWeight() {
        let weights: [WindowID: Double] = [1: 3, 2: 1, 3: 1, 4: 3]
        let frames = MasterStackLayout.frames(order: [1, 2, 3, 4], in: Self.rect, masterCount: 2, ratio: 0.5, side: .right, gap: 0,
                                              weight: { weights[$0] ?? 1 })
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
        let frames = MasterStackLayout.frames(order: [1, 2, 3, 4], in: Self.rect, masterCount: 1, ratio: 0.5, side: .right, gap: 0,
                                              weight: { weights[$0] ?? 1 }, minSize: { minSizes[$0] ?? .zero })
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
        let frames = MasterStackLayout.frames(order: [1, 2, 3, 4], in: rect, masterCount: 1, ratio: 0.5, side: .right, gap: 0,
                                              weight: { weights[$0] ?? 1 }, maxWeightRatio: 3)
        #expect(frames[2]!.height == 300)
        #expect(frames[3]!.height == 200)
        #expect(frames[4]!.height == 100)
    }

    @Test("gaps appear between tiles and never outside rect")
    func gapsBetweenTilesOnly() {
        let gap = 10.0
        let frames = MasterStackLayout.frames(order: [1, 2, 3], in: Self.rect, masterCount: 1, ratio: 0.5, side: .right, gap: gap)
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
        let frames = MasterStackLayout.frames(order: [1, 2], in: Self.rect, masterCount: 2, ratio: 0.6, side: .right, gap: 0)
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
        let frames = MasterStackLayout.frames(order: [1, 2], in: Self.rect, masterCount: 10, ratio: 0.6, side: .right, gap: 0)
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
        let frames = MasterStackLayout.frames(order: [], in: Self.rect, masterCount: 1, ratio: 0.6, side: .right, gap: 0)
        #expect(frames.isEmpty)
    }

    @Test("feasible minSize clamps master length up to the stack's minimum")
    func minSizeFeasibleClamp() {
        let rect = CGRect(x: 0, y: 0, width: 1000, height: 500)
        let minSizes: [WindowID: CGSize] = [2: CGSize(width: 500, height: 0)]
        let frames = MasterStackLayout.frames(order: [1, 2], in: rect, masterCount: 1, ratio: 0.6, side: .right, gap: 10, minSize: { minSizes[$0] ?? .zero })
        #expect(abs(frames[1]!.width - 490) < 0.001)
        #expect(abs(frames[2]!.width - 500) < 0.001)
    }

    @Test("infeasible minSize falls back to a proportional split")
    func minSizeInfeasibleFallback() {
        let rect = CGRect(x: 0, y: 0, width: 1000, height: 500)
        let minSizes: [WindowID: CGSize] = [1: CGSize(width: 600, height: 0), 2: CGSize(width: 500, height: 0)]
        let frames = MasterStackLayout.frames(order: [1, 2], in: rect, masterCount: 1, ratio: 0.6, side: .right, gap: 10, minSize: { minSizes[$0] ?? .zero })
        #expect(abs(frames[1]!.width - 540) < 0.001)
        #expect(abs(frames[2]!.width - 450) < 0.001)
    }

    @Test("multiple masters tile in the master column alongside a stack")
    func multipleMastersTileInColumn() {
        let frames = MasterStackLayout.frames(order: [1, 2, 3], in: Self.rect, masterCount: 2, ratio: 0.6, side: .right, gap: 10)
        #expect(abs(frames[1]!.width - 594) < 0.001)
        #expect(abs(frames[2]!.width - 594) < 0.001)
        #expect(abs(frames[1]!.height - 245) < 0.001)
        #expect(abs(frames[2]!.height - 245) < 0.001)
    }

    @Test("non-finite ratio falls back to 0.5")
    func nonFiniteRatioFallsBack() {
        let frames = MasterStackLayout.frames(order: [1, 2], in: Self.rect, masterCount: 1, ratio: .nan, side: .right, gap: 0)
        #expect(abs(frames[1]!.width - 500) < 0.001)
        #expect(abs(frames[2]!.width - 500) < 0.001)
    }

    @Test("ratio above 0.95 is clamped")
    func ratioClampedAboveMax() {
        let frames = MasterStackLayout.frames(order: [1, 2], in: Self.rect, masterCount: 1, ratio: 2, side: .right, gap: 0)
        #expect(abs(frames[1]!.width - 950) < 0.001)
        #expect(abs(frames[2]!.width - 50) < 0.001)
    }

    @Test("masterCount of zero is treated as one master")
    func masterCountZeroBecomesOne() {
        let frames = MasterStackLayout.frames(order: [1, 2], in: Self.rect, masterCount: 0, ratio: 0.6, side: .right, gap: 0)
        #expect(abs(frames[1]!.width - 600) < 0.001)
        #expect(abs(frames[2]!.width - 400) < 0.001)
    }
}
