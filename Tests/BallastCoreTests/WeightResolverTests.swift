import CoreGraphics
import Testing
@testable import BallastCore

@Suite("WeightResolver ranking")
struct WeightResolverTests {

    @Test("higher weight ranks first")
    func higherWeightFirst() {
        let candidates = [
            WeightResolver.Candidate(id: 1, weight: 1, focusRank: nil, creation: 0),
            WeightResolver.Candidate(id: 2, weight: 10, focusRank: nil, creation: 1),
        ]
        #expect(WeightResolver.rank(candidates) == [2, 1])
    }

    @Test("equal weight: more recently focused wins")
    func focusRankTiebreak() {
        let candidates = [
            WeightResolver.Candidate(id: 1, weight: 1, focusRank: 2, creation: 0),
            WeightResolver.Candidate(id: 2, weight: 1, focusRank: 0, creation: 1),
            WeightResolver.Candidate(id: 3, weight: 1, focusRank: 1, creation: 2),
        ]
        #expect(WeightResolver.rank(candidates) == [2, 3, 1])
    }

    @Test("never-focused windows rank after all focused ones, weight equal")
    func neverFocusedRanksLast() {
        let candidates = [
            WeightResolver.Candidate(id: 1, weight: 1, focusRank: nil, creation: 0),
            WeightResolver.Candidate(id: 2, weight: 1, focusRank: 0, creation: 1),
        ]
        #expect(WeightResolver.rank(candidates) == [2, 1])
    }

    @Test("equal weight and focus: earlier creation wins")
    func creationTiebreak() {
        let candidates = [
            WeightResolver.Candidate(id: 1, weight: 1, focusRank: nil, creation: 5),
            WeightResolver.Candidate(id: 2, weight: 1, focusRank: nil, creation: 2),
        ]
        #expect(WeightResolver.rank(candidates) == [2, 1])
    }

    @Test("equal weight, focus and creation: lower id wins")
    func idTiebreak() {
        let candidates = [
            WeightResolver.Candidate(id: 9, weight: 1, focusRank: nil, creation: 0),
            WeightResolver.Candidate(id: 3, weight: 1, focusRank: nil, creation: 0),
        ]
        #expect(WeightResolver.rank(candidates) == [3, 9])
    }

    @Test("ranking is deterministic and applies tiebreaks correctly across every permutation")
    func orderIndependent() {
        // Includes an equal-weight focused/unfocused pair (1 vs 2) and two
        // candidates identical except for id (3 vs 9), so every comparator
        // branch (focused-vs-unfocused, creation, id) is actually exercised.
        let base = [
            WeightResolver.Candidate(id: 1, weight: 5, focusRank: 0, creation: 0),
            WeightResolver.Candidate(id: 2, weight: 5, focusRank: nil, creation: 1),
            WeightResolver.Candidate(id: 9, weight: 1, focusRank: nil, creation: 2),
            WeightResolver.Candidate(id: 3, weight: 1, focusRank: nil, creation: 2),
        ]
        let expected: [WindowID] = [1, 2, 3, 9]
        #expect(WeightResolver.rank(base) == expected)

        for perm in Self.permutations(of: base) {
            #expect(WeightResolver.rank(perm) == expected, "permutation \(perm.map(\.id)) produced order \(WeightResolver.rank(perm)), expected \(expected)")
        }
    }

    /// Deterministic (non-random) enumeration of every permutation, via
    /// Heap's algorithm, so a failure is reproducible.
    static func permutations<T>(of array: [T]) -> [[T]] {
        var result: [[T]] = []
        var a = array
        func heap(_ k: Int) {
            if k == 1 {
                result.append(a)
                return
            }
            for i in 0..<k {
                heap(k - 1)
                if k % 2 == 0 {
                    a.swapAt(i, k - 1)
                } else {
                    a.swapAt(0, k - 1)
                }
            }
        }
        heap(a.count)
        return result
    }

    @Test("master/stack assignment: first masterCount ranked windows land in the master region")
    func masterAssignment() {
        let candidates = [
            WeightResolver.Candidate(id: 1, weight: 1, focusRank: nil, creation: 0),
            WeightResolver.Candidate(id: 2, weight: 10, focusRank: nil, creation: 1),
            WeightResolver.Candidate(id: 3, weight: 5, focusRank: nil, creation: 2),
        ]
        let order = WeightResolver.rank(candidates)
        #expect(order == [2, 3, 1])

        let rect = CGRect(x: 0, y: 0, width: 1200, height: 800)
        let frames = MasterLayout.plan(order: order, in: rect, masterCount: 2, ratio: 0.5, side: .right, gap: 0).frames
        guard let masterFrame2 = frames[2], let masterFrame3 = frames[3], let stackFrame1 = frames[1] else {
            Issue.record("expected frames for windows 1, 2, 3")
            return
        }
        #expect(masterFrame2.maxX <= stackFrame1.minX, "window 2 (master) should be left of the stack region")
        #expect(masterFrame3.maxX <= stackFrame1.minX, "window 3 (master) should be left of the stack region")
    }

    // MARK: - FocusHistory

    @Test("FocusHistory.touch moves to front and dedupes")
    func focusHistoryTouch() {
        var history = FocusHistory()
        history.touch(1)
        history.touch(2)
        history.touch(3)
        history.touch(1)
        #expect(history.entries == [1, 3, 2])
        #expect(history.mostRecent == 1)
    }

    @Test("FocusHistory.rank returns 0 for most recent, nil for unknown")
    func focusHistoryRank() {
        var history = FocusHistory()
        history.touch(1)
        history.touch(2)
        #expect(history.rank(of: 2) == 0)
        #expect(history.rank(of: 1) == 1)
        #expect(history.rank(of: 99) == nil)
    }

    @Test("FocusHistory.fallback skips ineligible and excluded entries")
    func focusHistoryFallback() {
        var history = FocusHistory()
        history.touch(1)
        history.touch(2)
        history.touch(3)
        // most recent is 3; excluding 3 with all eligible -> 2
        #expect(history.fallback(excluding: 3, where: { _ in true }) == 2)
        // excluding 3, and 2 is ineligible -> 1
        #expect(history.fallback(excluding: 3, where: { $0 != 2 }) == 1)
        // nothing eligible -> nil
        #expect(history.fallback(excluding: 3, where: { _ in false }) == nil)
    }

    @Test("init dedupes preserving first occurrence order")
    func focusHistoryInitDedupes() {
        let history = FocusHistory([1, 2, 1, 3, 2])
        #expect(history.entries == [1, 2, 3])
    }

    @Test("remove drops entry without disturbing others")
    func focusHistoryRemove() {
        var history = FocusHistory([1, 2, 3])
        history.remove(2)
        #expect(history.entries == [1, 3])
    }
}
