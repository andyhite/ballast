import Testing
import CoreGraphics
@testable import BallastApp
import BallastCore

struct WindowDiscoveryTests {
    private typealias Tab = WindowDiscovery.Tab

    private let frame = CGRect(x: 0, y: 0, width: 800, height: 600)
    private let other = CGRect(x: 800, y: 0, width: 800, height: 600)

    private typealias State = WindowDiscovery.TabState

    private func changes(_ w: State, visible: Set<WindowID> = [], tracked: Set<WindowID> = [1],
                         fresh: Set<WindowID> = []) -> (vanished: [WindowID], appeared: [WindowID]) {
        WindowDiscovery.tabChanges([w], visible: visible, tracked: tracked, fresh: fresh)
    }

    @Test func tabChangeRules() {
        func s(active: Bool = true, minimized: Bool = false, background: Bool = false) -> State {
            State(id: 1, onActiveSpace: active, minimized: minimized, backgroundTab: background)
        }
        #expect(changes(s()).vanished == [1])
        #expect(changes(s(), tracked: []).vanished.isEmpty)
        #expect(changes(s(background: true), visible: [1]).appeared == [1])
        #expect(changes(s(), visible: [1], fresh: [1]).appeared == [1])
        #expect(changes(s(minimized: true)).vanished.isEmpty)
        #expect(changes(s(active: false)).vanished.isEmpty)
    }

    @Test
    func tabThatCameInFrontTakesOverTheVanishedTile() {
        let pairs = WindowDiscovery.successors(
            vanished: [Tab(id: 1, space: 7, frame: frame)],
            appeared: [Tab(id: 2, space: 7, frame: frame)])
        #expect(pairs.count == 1)
        #expect(pairs[0].old == 1)
        #expect(pairs[0].new == 2)
    }

    @Test
    func closestArrivalOnTheSameSpaceWins() {
        let pairs = WindowDiscovery.successors(
            vanished: [Tab(id: 1, space: 7, frame: frame)],
            appeared: [Tab(id: 2, space: 7, frame: other),
                       Tab(id: 3, space: 8, frame: frame), // other Space: never a successor
                       Tab(id: 4, space: 7, frame: frame)])
        #expect(pairs[0].new == 4)
    }

    @Test
    func eachArrivalSucceedsOnlyOneVanishedWindow() {
        let pairs = WindowDiscovery.successors(
            vanished: [Tab(id: 5, space: 7, frame: other), Tab(id: 1, space: 7, frame: frame)],
            appeared: [Tab(id: 2, space: 7, frame: frame)])
        // Lowest id goes first and claims the only arrival; the other has none left.
        #expect(pairs.map(\.old) == [1, 5])
        #expect(pairs[0].new == 2)
        #expect(pairs[1].new == nil)
    }

    @Test
    func multipleVanishedPairWithTheirOwnArrivals() {
        let pairs = WindowDiscovery.successors(
            vanished: [Tab(id: 1, space: 7, frame: frame), Tab(id: 2, space: 7, frame: other)],
            appeared: [Tab(id: 3, space: 7, frame: other), Tab(id: 4, space: 7, frame: frame)])
        #expect(pairs[0].new == 4)
        #expect(pairs[1].new == 3)
    }

    @Test
    func nothingVanishedMeansNoPairs() {
        #expect(WindowDiscovery.successors(vanished: [], appeared: [Tab(id: 2, space: 7, frame: frame)]).isEmpty)
    }

    @Test
    func unknownFramesNeverBeatAKnownOneButStillMatch() {
        let pairs = WindowDiscovery.successors(
            vanished: [Tab(id: 1, space: 7, frame: frame)],
            appeared: [Tab(id: 2, space: 7, frame: nil), Tab(id: 3, space: 7, frame: other)])
        #expect(pairs[0].new == 3)
    }
}
