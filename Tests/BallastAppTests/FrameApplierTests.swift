import Testing
import CoreGraphics
@testable import BallastApp

struct FrameApplierTests {
    @Test func removedWindowNeverResurrectsAStaleGeneration() {
        let generations = Generations()
        let stale = generations.next(1)
        let other = generations.next(2)
        generations.remove(1)
        #expect(!generations.isCurrent(1, stale))

        // A reused id starts above every old generation, so the old request stays stale.
        let fresh = generations.next(1)
        #expect(fresh > stale)
        #expect(!generations.isCurrent(1, stale))
        #expect(generations.isCurrent(1, fresh))
        #expect(generations.isCurrent(2, other))
    }

    @Test func newerRequestSupersedesOlder() {
        let generations = Generations()
        let first = generations.next(1)
        let second = generations.next(1)
        #expect(!generations.isCurrent(1, first))
        #expect(generations.isCurrent(1, second))
    }

    @Test func writesShrinkBeforeMoveBeforeGrow() {
        // Wider but shorter: shrink height, move, then grow width.
        let writes = FrameApplier.writes(from: CGRect(x: 0, y: 0, width: 100, height: 100),
                                         to: CGRect(x: 10, y: 10, width: 200, height: 50))
        #expect(writes == [.size(CGSize(width: 100, height: 50)), .position(CGPoint(x: 10, y: 10)),
                           .size(CGSize(width: 200, height: 50))])
    }

    @Test func pureShrinkAndPureGrowCollapse() {
        let shrink = FrameApplier.writes(from: CGRect(x: 0, y: 0, width: 100, height: 100),
                                         to: CGRect(x: 10, y: 10, width: 50, height: 50))
        #expect(shrink == [.size(CGSize(width: 50, height: 50)), .position(CGPoint(x: 10, y: 10))])

        let grow = FrameApplier.writes(from: CGRect(x: 0, y: 0, width: 50, height: 50),
                                       to: CGRect(x: 10, y: 10, width: 100, height: 100))
        #expect(grow == [.position(CGPoint(x: 10, y: 10)), .size(CGSize(width: 100, height: 100))])
    }

    @Test func identicalFrameWritesNothing() {
        let frame = CGRect(x: 5, y: 5, width: 40, height: 30)
        #expect(FrameApplier.writes(from: frame, to: frame).isEmpty)
    }
}
