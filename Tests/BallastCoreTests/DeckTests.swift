import CoreGraphics
import Testing
@testable import BallastCore

@Suite("Decks")
struct DeckTests {
    static let area = EngineTests.area
    static let areas = EngineTests.areas

    static func state(_ engine: Engine) -> SpaceState { engine.spaces[1] ?? SpaceState(id: 1) }

    /// A config pinning the layout under test, with no gaps.
    static func config(_ arrange: Arrangement = .fixed, columns: Int = 1, rows: Int = 0,
                       feature: FeatureSide = .left) -> Config {
        var config = Config()
        config.layout.arrange = arrange
        config.layout.columns = columns
        config.layout.rows = rows
        config.layout.feature = feature
        config.layout.featureSize = 0.6
        config.layout.featureCount = 1
        config.layout.gapsInner = 0
        config.layout.gapsOuter = 0
        return config
    }

    /// `count` windows on Space 1: feature 1, then 2…count in order.
    static func engine(_ config: Config, count: Int) -> Engine {
        var engine = EngineTests.makeEngine(config: config)
        // Each newcomer tops the grid, so the grid joins bottom-up.
        for id in [1] + (1...count).dropFirst().reversed() {
            _ = engine.addWindow(WindowID(id), pid: Int32(id), facts: WindowFacts(), space: 1)
        }
        return engine
    }

    /// A fixed grid of one unbounded column beside a left feature.
    static func tileEngine(count: Int) -> Engine { engine(config(), count: count) }

    /// Focuses `id` and runs `command` on Space 1.
    @discardableResult
    static func run(_ engine: inout Engine, _ command: Command, from id: WindowID? = nil) -> CommandOutcome {
        if let id { _ = engine.focus(id) }
        return engine.perform(command, space: 1, areas: areas)
    }

    @Test("deck joins the neighbor's tile; the window's old tile closes up and the joiner shows")
    func deckInFeatureTile() {
        var engine = Self.tileEngine(count: 3)
        // 1 is the feature; 2 and 3 share the grid column.
        let out = Self.run(&engine, .deck(.left), from: 2)
        #expect(out.dirty == [1])
        let state = Self.state(engine)
        #expect(state.decks == [1: [1, 2]])
        #expect(state.tileCount == 2 && state.tiles == [1, 3])
        #expect(state.manual)

        let layout = engine.layout(space: 1, area: Self.area)
        #expect(layout.frames[1] != nil && layout.covered[1] != nil && layout.covered[2] == nil)
        #expect(layout.raise == 2)
        // The deck tile is the feature region, grid tile 3 keeps its column.
        let view = layout.frames[2]!
        #expect(view.maxX <= layout.frames[3]!.minX && view.height > 0)
        #expect(layout.scrolling == [1, 2])
    }

    @Test("a tile weighs its heaviest window and needs its largest learned minimum")
    func tileAggregates() {
        var engine = Self.tileEngine(count: 3)
        Self.run(&engine, .deck(.down), from: 2)
        #expect(Self.state(engine).decks == [3: [3, 2]] || Self.state(engine).decks == [2: [2, 3]])
        // Window 3 alone refuses to be narrower than 700: the shared tile
        // (the whole grid column) can't be either.
        _ = engine.learnMinSize(3, CGSize(width: 700, height: 100))
        let layout = engine.layout(space: 1, area: Self.area)
        #expect(layout.frames[2]!.width >= 700 && layout.frames[3]!.width >= 700)
    }

    @Test("deck and undeck in dwindle: the leaf is shared, then split again after the undeck")
    func deckInBSP() {
        var engine = Self.engine(Self.config(.dwindle, feature: .off), count: 3)
        let before = Set(Self.state(engine).tree?.leaves ?? [])
        #expect(before == [1, 2, 3])

        let target = Self.state(engine).tree?.leaves.first { $0 != 3 } ?? 1
        let neighbor = engine.layout(space: 1, area: Self.area).frames[3].flatMap { frame in
            [Direction.left, .right, .up, .down].first { direction in
                Engine.nearest(from: frame, direction, among: engine.layout(space: 1, area: Self.area).frames.filter { $0.key != 3 }) == target
            }
        }
        #expect(neighbor != nil)
        Self.run(&engine, .deck(neighbor ?? .left), from: 3)
        var state = Self.state(engine)
        #expect(state.tileCount == 2 && state.decks.count == 1 && Set(state.tree?.leaves ?? []) == Set(state.tiles))
        #expect(state.decks.values.first?.contains(3) == true)
        #expect(engine.layout(space: 1, area: Self.area).frames.count == 3)

        Self.run(&engine, .undeck, from: 3)
        state = Self.state(engine)
        #expect(state.decks.isEmpty && Set(state.tree?.leaves ?? []) == [1, 2, 3])
        // Undecked, every window tiles again: no strips.
        #expect(engine.layout(space: 1, area: Self.area).covered.isEmpty)
    }

    @Test("undeck puts the window in a tile right after the deck in order-based layouts")
    func undeckOrder() {
        var engine = Self.tileEngine(count: 4)
        Self.run(&engine, .deck(.left), from: 2)
        #expect(Self.state(engine).liveOrder == [1, 3, 4])
        Self.run(&engine, .undeck, from: 2)
        let state = Self.state(engine)
        #expect(state.decks.isEmpty)
        #expect(state.liveOrder == [1, 2, 3, 4])
    }

    @Test("a deck left with one window dissolves")
    func dissolveOnClose() {
        var engine = Self.tileEngine(count: 3)
        Self.run(&engine, .deck(.left), from: 2)
        _ = engine.removeWindow(2)
        let state = Self.state(engine)
        #expect(state.decks.isEmpty && state.tiles == [1, 3])
        #expect(Set(state.tree?.leaves ?? []) == [1, 3])
        #expect(engine.layout(space: 1, area: Self.area).covered.isEmpty)
    }

    @Test("the tile of a closing deck representative passes to the next member")
    func representativeLeaves() {
        var engine = Self.tileEngine(count: 4)
        Self.run(&engine, .deck(.left), from: 2)
        Self.run(&engine, .deck(.left), from: 3)
        #expect(Self.state(engine).decks == [1: [1, 2, 3]])
        _ = engine.removeWindow(1)
        var state = Self.state(engine)
        #expect(state.decks == [2: [2, 3]])
        #expect(Set(state.tiles) == [2, 4] && Set(state.liveOrder) == [2, 4])
        #expect(Set(state.tree?.leaves ?? []) == [2, 4])
        _ = engine.removeWindow(3)
        state = Self.state(engine)
        #expect(state.decks.isEmpty && Set(state.tiles) == [2, 4])
    }

    @Test("a deck member leaving the Space (float) keeps the rest decked")
    func memberFloats() {
        var engine = Self.tileEngine(count: 4)
        Self.run(&engine, .deck(.left), from: 2)
        Self.run(&engine, .deck(.left), from: 3)
        _ = engine.focus(2)
        Self.run(&engine, .toggleFloat)
        #expect(Self.state(engine).decks == [1: [1, 3]])
    }

    @Test("arrangement changes keep decks; monocle covers every window; reset dissolves every deck")
    func resetAndArrangements() {
        var engine = Self.tileEngine(count: 4)
        Self.run(&engine, .deck(.left), from: 2)
        let arrangements: [Config] = [
            Self.config(rows: 1), Self.config(feature: .center), Self.config(.adaptive, feature: .off),
            Self.config(.dwindle, feature: .off), Self.config(.balanced), Self.config(),
        ]
        for (index, config) in arrangements.enumerated() {
            _ = engine.applyConfig(config)
            #expect(Self.state(engine).decks == [1: [1, 2]], "config \(index)")
            let layout = engine.layout(space: 1, area: Self.area)
            #expect(Set(layout.frames.keys) == [1, 2, 3, 4], "config \(index)")
            #expect(layout.covered[1] != nil || layout.covered[2] != nil, "config \(index)")
        }
        Self.run(&engine, .monocle)
        let monocle = engine.layout(space: 1, area: Self.area)
        // One full-area deck of every window: one shows, the other three are tucked behind it.
        #expect(Set(monocle.frames.keys) == [1, 2, 3, 4] && monocle.covered.count == 3)
        #expect(monocle.monocle)
        Self.run(&engine, .monocle)

        Self.run(&engine, .reset)
        let state = Self.state(engine)
        #expect(state.decks.isEmpty && !state.manual)
        #expect(Set(state.tiles) == [1, 2, 3, 4] && Set(state.tree?.leaves ?? []) == [1, 2, 3, 4])
        #expect(Set(state.idealOrder) == [1, 2, 3, 4])
    }

    @Test("focus inside a deck scrolls its view and dirties the Space; directional focus walks its windows")
    func focusWithinDeck() {
        var engine = Self.tileEngine(count: 4)
        Self.run(&engine, .deck(.down), from: 3)
        let state = Self.state(engine)
        let members = state.decks.values.first ?? []
        #expect(Set(members) == [3, 4])
        let first = members[0], second = members[1]

        #expect(engine.focus(WindowID(first)) == [1])
        var layout = engine.layout(space: 1, area: Self.area)
        #expect(layout.covered[WindowID(first)] == nil && layout.covered[WindowID(second)] != nil)

        // Down (or up) from the shown window reaches the other, then it shows.
        let step = [Direction.down, .up].compactMap { direction in
            Self.run(&engine, .focus(direction), from: first).focus.flatMap { $0 == WindowID(second) ? direction : nil }
        }
        #expect(step.count == 1)
        #expect(engine.focus(WindowID(second)) == [1])
        layout = engine.layout(space: 1, area: Self.area)
        #expect(layout.covered[WindowID(second)] == nil && layout.covered[WindowID(first)] != nil)
        #expect(layout.raise == WindowID(second))

        // Focus on an undecked window in a grid that doesn't scroll does not dirty.
        #expect(engine.focus(1).isEmpty)
    }

    @Test("swap trades tiles between tiles and window order inside a deck")
    func swapDecks() {
        var engine = Self.tileEngine(count: 4)
        Self.run(&engine, .deck(.down), from: 3)
        let deck = Self.state(engine).decks.values.first ?? []
        #expect(Set(deck) == [3, 4])
        // Trading a deck with the feature moves the whole tile.
        let swapped = engine.swap(1, deck[0], on: 1)
        #expect(swapped)
        var state = Self.state(engine)
        #expect(state.decks.count == 1 && Set(state.liveOrder.prefix(1)) == Set(state.decks.keys))
        // Inside a deck only the order changes.
        let holder = state.decks.keys.first ?? 0
        let before = state.liveOrder
        let reordered = engine.swap(deck[0], deck[1], on: 1)
        #expect(reordered)
        state = Self.state(engine)
        #expect(state.liveOrder == before)
        #expect(state.decks[holder] == deck.reversed().map { $0 })
    }

    @Test("a deck inside a one-row grid column tucks all its windows when out of view")
    func deckInOneRowColumn() {
        var engine = Self.engine(Self.config(rows: 1), count: 4)
        // Grid 2, 3, 4: deck 4 with 3.
        Self.run(&engine, .deck(.up), from: 4)
        let state = Self.state(engine)
        #expect(state.tileCount == 3)
        let members = state.decks.values.first ?? []
        #expect(Set(members) == [3, 4])

        _ = engine.focus(2)
        var layout = engine.layout(space: 1, area: Self.area)
        #expect(layout.covered[2] == nil)
        #expect(layout.covered[3] != nil && layout.covered[3] == layout.covered[4])
        #expect(layout.frames[3] == layout.frames[4])
        #expect(layout.raise == 2 && layout.behind[2] == nil)

        _ = engine.focus(WindowID(members[0]))
        layout = engine.layout(space: 1, area: Self.area)
        #expect(layout.covered[WindowID(members[0])] == nil)
        #expect(layout.covered[2] != nil && layout.covered[WindowID(members[1])] != nil)
        let shown = layout.frames[WindowID(members[0])]!
        #expect(layout.frames[1]!.maxX <= shown.minX)
    }

    @Test("decks need a tile to join: no neighbor, no focus and float layouts are refused")
    func refusals() {
        var engine = Self.tileEngine(count: 3)
        #expect(Self.run(&engine, .deck(.left), from: 1).message != nil)
        #expect(Self.run(&engine, .undeck, from: 1).message != nil)
        #expect(Self.state(engine).decks.isEmpty && !Self.state(engine).manual)
        _ = engine.applyConfig(Self.config(.float))
        #expect(Self.run(&engine, .deck(.right), from: 1).message != nil)
        #expect(Self.state(engine).decks.isEmpty)
    }

    @Test("deck commands parse a direction; undeck takes none")
    func parsing() {
        #expect(Command.parse("deck left") == .success(.deck(.left)))
        #expect(Command.parse("undeck") == .success(.undeck))
        if case .success = Command.parse("deck") { Issue.record("deck needs a direction") }
        if case .success = Command.parse("undeck left") { Issue.record("undeck takes no argument") }
    }
}
