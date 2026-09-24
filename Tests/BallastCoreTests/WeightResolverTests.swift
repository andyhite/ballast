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

    @Test("ranking is deterministic regardless of input order")
    func orderIndependent() {
        let base = [
            WeightResolver.Candidate(id: 1, weight: 5, focusRank: 1, creation: 0),
            WeightResolver.Candidate(id: 2, weight: 5, focusRank: 0, creation: 1),
            WeightResolver.Candidate(id: 3, weight: 10, focusRank: nil, creation: 2),
            WeightResolver.Candidate(id: 4, weight: 1, focusRank: nil, creation: 3),
            WeightResolver.Candidate(id: 5, weight: 1, focusRank: nil, creation: 1),
        ]
        let expected = WeightResolver.rank(base)
        for _ in 0..<20 {
            #expect(WeightResolver.rank(base.shuffled()) == expected)
        }
    }

    @Test("master/stack assignment: first masterCount ranked windows are masters")
    func masterAssignment() {
        let candidates = [
            WeightResolver.Candidate(id: 1, weight: 1, focusRank: nil, creation: 0),
            WeightResolver.Candidate(id: 2, weight: 10, focusRank: nil, creation: 1),
            WeightResolver.Candidate(id: 3, weight: 5, focusRank: nil, creation: 2),
        ]
        let order = WeightResolver.rank(candidates)
        let masterCount = 2
        let masters = Array(order.prefix(masterCount))
        #expect(masters == [2, 3])
        let stack = Array(order.dropFirst(masterCount))
        #expect(stack == [1])
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
