import CoreGraphics
import Testing
@testable import BallastCore

/// Engine-level behavior of the grid + optional feature area: every
/// arrangement, every feature side, decks, monocle and the commands that
/// resize, promote and balance.
@Suite("Grid and feature")
struct GridFeatureTests {
    static let area = CGRect(x: 0, y: 0, width: 1000, height: 800)
    static let areas = [EngineTests.displayA: area]

    /// A config pinning the whole layout, so no test follows the built-in
    /// screen-size defaults. Gaps default to none: frames then tile exactly.
    static func config(_ arrange: Arrangement = .fixed, columns: Int = 1, rows: Int = 0,
                       feature: FeatureSide = .left, size: Double = 0.6, featureCount: Int = 1,
                       gap: Double = 0) -> Config {
        var config = Config()
        config.layout.arrange = arrange
        config.layout.columns = columns
        config.layout.rows = rows
        config.layout.feature = feature
        config.layout.featureSize = size
        config.layout.featureCount = featureCount
        config.layout.deckPeek = 30
        config.layout.gapsInner = gap
        config.layout.gapsOuter = gap
        return config
    }

    /// `count` windows on Space 1 whose live order is `1…count` (for a BSP
    /// arrangement, the order they were opened in).
    static func engine(_ config: Config, count: Int) -> Engine {
        var engine = EngineTests.makeEngine(config: config)
        // A newcomer tops its weight tier right after the feature windows, so
        // open the feature windows first, then the grid bottom-up.
        let featured = engine.settings(for: 1).hasFeature ? min(engine.settings(for: 1).featureCount, count) : 0
        let ids = (1...max(featured, 1)).filter { $0 <= featured } + ((featured + 1)...max(count, featured + 1)).reversed().filter { $0 <= count }
        for id in ids {
            _ = engine.addWindow(WindowID(id), pid: Int32(id), facts: WindowFacts(), space: 1)
        }
        return engine
    }

    static func state(_ engine: Engine) -> SpaceState { engine.spaces[1] ?? SpaceState(id: 1) }

    @discardableResult
    static func run(_ engine: inout Engine, _ command: Command, from id: WindowID? = nil) -> CommandOutcome {
        if let id { _ = engine.focus(id) }
        return engine.perform(command, space: 1, areas: areas)
    }

    static func layout(_ engine: Engine) -> SpaceLayout { engine.layout(space: 1, area: area) }

    static func near(_ a: CGRect?, _ b: CGRect, tolerance: Double = 1) -> Bool {
        guard let a else { return false }
        return abs(a.minX - b.minX) <= tolerance && abs(a.minY - b.minY) <= tolerance
            && abs(a.width - b.width) <= tolerance && abs(a.height - b.height) <= tolerance
    }

    static func areaOf(_ rect: CGRect?) -> Double { rect.map { $0.width * $0.height } ?? 0 }

    // MARK: - Fixed grid

    @Test("fixed C×R: overflow decks in the last column and the view follows focus")
    func fixedOverflowDeckFollowsFocus() {
        // Feature 1; grid 2…6 in 2 columns of 2 rows: column 1 holds 2,3; column 2 holds 4,5,6 and decks.
        var engine = Self.engine(Self.config(columns: 2, rows: 2), count: 6)
        #expect(Self.layout(engine).scrolling == [4, 5, 6])

        _ = engine.focus(6)
        var layout = Self.layout(engine)
        #expect(layout.covered[6] == nil && layout.covered[5] == nil)
        #expect(layout.covered[4] != nil)
        #expect(layout.raise == 6)
        let steady = (layout.frames[2], layout.frames[3])

        _ = engine.focus(4)
        layout = Self.layout(engine)
        #expect(layout.covered[4] == nil && layout.covered[5] == nil)
        #expect(layout.covered[6] != nil)
        #expect(layout.raise == 4)
        // The column that doesn't deck never moves with focus.
        #expect(layout.frames[2] == steady.0 && layout.frames[3] == steady.1)
        #expect(layout.covered[2] == nil && layout.covered[3] == nil)
    }

    @Test("fixed C×R: focus dirties the Space only while a column decks")
    func deckFocusDirties() {
        var engine = Self.engine(Self.config(columns: 2, rows: 2), count: 6)
        #expect(engine.focus(5) == [1])
        // With nothing to scroll (tiles fit in the grid), focus never dirties.
        var fits = Self.engine(Self.config(columns: 2, rows: 2), count: 5)
        #expect(fits.focus(3).isEmpty)
    }

    @Test("fixed 1×1 without a feature: one full-area deck, the focused window in view")
    func fixedOneByOne() {
        var engine = Self.engine(Self.config(rows: 1, feature: .off), count: 3)
        #expect(Self.state(engine).liveOrder == [1, 2, 3])
        _ = engine.focus(2)
        var layout = Self.layout(engine)
        #expect(layout.frames[2] == CGRect(x: 0, y: 30, width: 1000, height: 740)) // both neighbours peek
        #expect(Set(layout.covered.keys) == [1, 3])
        #expect(layout.covered[1]?.height == 30 && layout.covered[3]?.height == 30)
        #expect(layout.raise == 2)
        #expect(layout.scrolling == [1, 2, 3])

        _ = engine.focus(1)
        layout = Self.layout(engine)
        #expect(layout.frames[1]?.minY == 0) // nothing above, so no strip
        #expect(layout.covered[1] == nil && layout.raise == 1)
    }

    @Test("fixed C×R without a feature spreads tiles evenly; a cap only matters past columns × rows")
    func fixedWithoutFeatureSpreads() {
        let engine = Self.engine(Self.config(columns: 3, rows: 2, feature: .off), count: 4)
        let layout = Self.layout(engine)
        #expect(layout.covered.isEmpty && layout.scrolling.isEmpty)
        // 2/1/1 over three columns, left to right.
        #expect(Self.near(layout.frames[1], CGRect(x: 0, y: 0, width: 333, height: 400)))
        #expect(Self.near(layout.frames[2], CGRect(x: 0, y: 400, width: 333, height: 400)))
        #expect(Self.near(layout.frames[3], CGRect(x: 333, y: 0, width: 333, height: 800)))
        #expect(Self.near(layout.frames[4], CGRect(x: 667, y: 0, width: 333, height: 800)))

        let overflow = Self.engine(Self.config(columns: 2, rows: 2, feature: .off), count: 6)
        #expect(Self.layout(overflow).scrolling.count == 4) // the second column holds 4 > 2 rows
    }

    // MARK: - Feature sides

    @Test("each feature side puts the first window where it belongs, with the grid on the other side",
          arguments: [FeatureSide.left, .right, .top, .bottom])
    func featureSides(side: FeatureSide) {
        let engine = Self.engine(Self.config(feature: side), count: 3)
        let frames = Self.layout(engine).frames
        let expected: CGRect
        switch side {
        case .left: expected = CGRect(x: 0, y: 0, width: 600, height: 800)
        case .right: expected = CGRect(x: 400, y: 0, width: 600, height: 800)
        case .top: expected = CGRect(x: 0, y: 0, width: 1000, height: 480)
        default: expected = CGRect(x: 0, y: 320, width: 1000, height: 480)
        }
        #expect(Self.near(frames[1], expected))
        for id: WindowID in 2...3 {
            #expect(!frames[id]!.intersects(frames[1]!.insetBy(dx: 1, dy: 1)), "\(side) window \(id)")
        }
    }

    @Test("a centered feature sits in the middle: the right half takes the first grid tiles, the left the rest")
    func centerFeature() {
        var engine = Self.engine(Self.config(feature: .center), count: 5)
        var frames = Self.layout(engine).frames
        #expect(Self.near(frames[1], CGRect(x: 200, y: 0, width: 600, height: 800)))
        // 4 grid tiles: 2, 3 on the right (x 800…1000), 4, 5 on the left.
        #expect(Self.near(frames[2], CGRect(x: 800, y: 0, width: 200, height: 400)))
        #expect(Self.near(frames[3], CGRect(x: 800, y: 400, width: 200, height: 400)))
        #expect(Self.near(frames[4], CGRect(x: 0, y: 0, width: 200, height: 400)))
        #expect(Self.near(frames[5], CGRect(x: 0, y: 400, width: 200, height: 400)))

        // One grid tile: right only, and the feature is not left with an empty half.
        engine = Self.engine(Self.config(feature: .center), count: 2)
        frames = Self.layout(engine).frames
        #expect(Self.near(frames[1], CGRect(x: 0, y: 0, width: 600, height: 800)))
        #expect(Self.near(frames[2], CGRect(x: 600, y: 0, width: 400, height: 800)))
    }

    @Test("feature_count 2 shares the feature area between the first two windows")
    func featureCountTwo() {
        let engine = Self.engine(Self.config(featureCount: 2), count: 4)
        let frames = Self.layout(engine).frames
        #expect(Self.near(frames[1], CGRect(x: 0, y: 0, width: 600, height: 400)))
        #expect(Self.near(frames[2], CGRect(x: 0, y: 400, width: 600, height: 400)))
        #expect(Self.near(frames[3], CGRect(x: 600, y: 0, width: 400, height: 400)))
        #expect(Self.near(frames[4], CGRect(x: 600, y: 400, width: 400, height: 400)))
    }

    @Test("when every window is featured the feature fills the area")
    func allFeatured() {
        let engine = Self.engine(Self.config(featureCount: 3), count: 2)
        let frames = Self.layout(engine).frames
        #expect(Self.near(frames[1], CGRect(x: 0, y: 0, width: 1000, height: 400)))
        #expect(Self.near(frames[2], CGRect(x: 0, y: 400, width: 1000, height: 400)))
    }

    // MARK: - Adaptive

    @Test("adaptive with a feature: the grid region holds an adaptive grid of the other tiles")
    func adaptiveWithFeature() {
        let engine = Self.engine(Self.config(.adaptive, feature: .left), count: 5)
        let frames = Self.layout(engine).frames
        #expect(Self.near(frames[1], CGRect(x: 0, y: 0, width: 600, height: 800)))
        // Four tiles in the 400×800 grid region: 2×2 cells.
        #expect(Self.near(frames[2], CGRect(x: 600, y: 0, width: 200, height: 400)))
        #expect(Self.near(frames[3], CGRect(x: 800, y: 0, width: 200, height: 400)))
        #expect(Self.near(frames[4], CGRect(x: 600, y: 400, width: 200, height: 400)))
        #expect(Self.near(frames[5], CGRect(x: 800, y: 400, width: 200, height: 400)))
    }

    @Test("adaptive without a feature tiles the whole area; centered, each half is its own adaptive grid")
    func adaptiveOffAndCenter() {
        let off = Self.engine(Self.config(.adaptive, feature: .off), count: 4)
        let frames = Self.layout(off).frames
        #expect(Self.near(frames[1], CGRect(x: 0, y: 0, width: 500, height: 400)))
        #expect(Self.near(frames[4], CGRect(x: 500, y: 400, width: 500, height: 400)))

        let center = Self.engine(Self.config(.adaptive, feature: .center), count: 6)
        let c = Self.layout(center).frames
        #expect(Self.near(c[1], CGRect(x: 200, y: 0, width: 600, height: 800)))
        // Right half (x 800…1000): 2, 3, 4 — two on top, the last across the bottom. Left half: 5, 6 stacked.
        #expect(Self.near(c[4], CGRect(x: 800, y: 400, width: 200, height: 400)))
        #expect(Self.near(c[5], CGRect(x: 0, y: 0, width: 200, height: 400)))
        #expect(Self.near(c[6], CGRect(x: 0, y: 400, width: 200, height: 400)))
    }

    // MARK: - BSP with a feature

    @Test("dwindle and balanced with a feature: the first leaf is the feature, the rest of the tree fills the grid region",
          arguments: [Arrangement.dwindle, .balanced])
    func bspWithFeature(arrange: Arrangement) {
        let engine = Self.engine(Self.config(arrange, feature: .left), count: 4)
        let featured = Self.state(engine).tree?.leaves.first ?? 0
        let layout = Self.layout(engine)
        #expect(Self.near(layout.frames[featured], CGRect(x: 0, y: 0, width: 600, height: 800)))
        let rest = layout.frames.filter { $0.key != featured }
        #expect(rest.count == 3)
        for frame in rest.values {
            #expect(frame.minX >= 600 - 0.5 && frame.maxX <= 1000 + 0.5)
        }
        // The pruned tree tiles the whole grid region.
        #expect(abs(rest.values.map { $0.width * $0.height }.reduce(0, +) - 400 * 800) < 1)
    }

    @Test("a centered feature on dwindle sits on the left")
    func bspCenterIsLeft() {
        let engine = Self.engine(Self.config(.dwindle, feature: .center), count: 3)
        let featured = Self.state(engine).tree?.leaves.first ?? 0
        #expect(Self.near(Self.layout(engine).frames[featured], CGRect(x: 0, y: 0, width: 600, height: 800)))
    }

    @Test("promote swaps a grid tile into the feature slot")
    func promoteGridTile() {
        var engine = Self.engine(Self.config(.dwindle, feature: .left), count: 4)
        let leaves = Self.state(engine).tree?.leaves ?? []
        let grid = leaves[2]
        let out = Self.run(&engine, .promote, from: grid)
        #expect(out.dirty == [1])
        #expect(Self.state(engine).tree?.leaves.first == grid)
        #expect(Self.near(Self.layout(engine).frames[grid], CGRect(x: 0, y: 0, width: 600, height: 800)))
        #expect(Set(Self.layout(engine).frames.keys) == [1, 2, 3, 4])
    }

    @Test("swap keeps every window laid out, in the feature and in the grid of a BSP")
    func bspSwapKeepsTotals() {
        var engine = Self.engine(Self.config(.balanced, feature: .left), count: 5)
        let leaves = Self.state(engine).tree?.leaves ?? []
        let first = engine.swap(leaves[0], leaves[3], on: 1)
        let second = engine.swap(leaves[1], leaves[2], on: 1)
        #expect(first && second)
        let after = Self.state(engine).tree?.leaves ?? []
        #expect(Set(after) == Set(leaves) && after.count == leaves.count)
        let layout = Self.layout(engine)
        #expect(Set(layout.frames.keys) == [1, 2, 3, 4, 5])
        #expect(Self.near(layout.frames[after[0]], CGRect(x: 0, y: 0, width: 600, height: 800)))
    }

    @Test("grow on a BSP grid tile changes a split ratio; on the featured tile it changes the feature size")
    func bspResize() {
        var engine = Self.engine(Self.config(.dwindle, feature: .left), count: 4)
        let leaves = Self.state(engine).tree?.leaves ?? []
        let grid = leaves[1], featured = leaves[0]
        let before = Self.layout(engine).frames

        let out = Self.run(&engine, .resize(0.05), from: grid)
        #expect(out.settings == nil && out.dirty == [1])
        let after = Self.layout(engine).frames
        #expect(Self.areaOf(after[grid]) > Self.areaOf(before[grid]))
        #expect(after[featured] == before[featured]) // the feature is not part of the tree's ratios
        #expect(engine.settings(for: 1).featureSize == 0.6)

        let shrink = Self.run(&engine, .resize(-0.05), from: grid)
        #expect(shrink.settings == nil)
        #expect(Self.areaOf(Self.layout(engine).frames[grid]) < Self.areaOf(after[grid]))

        let grown = Self.run(&engine, .resize(0.1), from: featured)
        #expect(grown.dirty == [1])
        let size = grown.settings?.featureSize
        #expect(size != nil && size! > 0.6)
        #expect(Self.layout(engine).frames[featured]!.width > 600)
    }

    @Test("balance on a BSP evens the grid's split ratios and leaves the feature size alone")
    func bspBalance() {
        var engine = Self.engine(Self.config(.dwindle, feature: .left), count: 4)
        let leaves = Self.state(engine).tree?.leaves ?? []
        for _ in 0..<3 { Self.run(&engine, .resize(0.1), from: leaves[1]) }
        let skewed = Self.layout(engine).frames
        let out = Self.run(&engine, .balance)
        #expect(out.settings == nil && out.dirty == [1] && out.message == nil)
        let balanced = Self.layout(engine).frames
        #expect(balanced[leaves[1]] != skewed[leaves[1]])
        // Three grid tiles in a balanced tree end up the same size.
        let heights = leaves.dropFirst().compactMap { balanced[$0]?.height }
        #expect(heights.count == 3 && heights.allSatisfy { abs($0 - 800.0 / 3) <= 1 })
        #expect(engine.settings(for: 1).featureSize == 0.6)
    }

    // MARK: - Resize, balance, feature-size, feature-count

    @Test("grow and shrink on a fixed or adaptive grid resize the feature, with the sign flipped for grid tiles",
          arguments: [Arrangement.fixed, .adaptive])
    func resizeFeature(arrange: Arrangement) {
        var engine = Self.engine(Self.config(arrange), count: 3)
        let onFeature = Self.run(&engine, .resize(0.1), from: 1)
        #expect(onFeature.dirty == [1])
        #expect(abs((onFeature.settings?.featureSize ?? 0) - 0.7) < 1e-9)
        #expect(onFeature.settings?.space == 1 && onFeature.settings?.featureCount == nil)
        #expect(abs(engine.settings(for: 1).featureSize - 0.7) < 1e-9)
        #expect(Self.near(Self.layout(engine).frames[1], CGRect(x: 0, y: 0, width: 700, height: 800)))

        // Growing a grid tile gives the grid more room: the feature shrinks.
        let onGrid = Self.run(&engine, .resize(0.1), from: 2)
        #expect(abs((onGrid.settings?.featureSize ?? 0) - 0.6) < 1e-9)
        let shrinkGrid = Self.run(&engine, .resize(-0.1), from: 3)
        #expect(abs((shrinkGrid.settings?.featureSize ?? 0) - 0.7) < 1e-9)
    }

    @Test("grow and balance say why when there is nothing to resize")
    func nothingToResize() {
        var noFeature = Self.engine(Self.config(feature: .off), count: 3)
        let grow = Self.run(&noFeature, .resize(0.1), from: 2)
        #expect(grow.message != nil && grow.settings == nil && grow.dirty.isEmpty)
        let balance = Self.run(&noFeature, .balance)
        #expect(balance.message != nil && balance.settings == nil && balance.dirty.isEmpty)

        var adaptive = Self.engine(Self.config(.adaptive, feature: .off), count: 3)
        #expect(Self.run(&adaptive, .resize(0.1), from: 2).message != nil)

        var float = Self.engine(Self.config(.float, feature: .left), count: 3)
        #expect(Self.run(&float, .resize(0.1), from: 2).message != nil)
        #expect(Self.run(&float, .balance).message != nil)
        #expect(Self.layout(float).frames.isEmpty)
    }

    @Test("balance on a fixed or adaptive grid with a feature sets the feature size to half")
    func balanceFeature() {
        for arrange in [Arrangement.fixed, .adaptive] {
            var engine = Self.engine(Self.config(arrange, size: 0.8), count: 3)
            let out = Self.run(&engine, .balance)
            #expect(out.settings == SettingsChange(space: 1, featureSize: 0.5, featureCount: nil), "\(arrange)")
            #expect(engine.settings(for: 1).featureSize == 0.5, "\(arrange)")
            #expect(Self.near(Self.layout(engine).frames[1], CGRect(x: 0, y: 0, width: 500, height: 800)), "\(arrange)")
        }
    }

    @Test("feature-size moves the feature by a delta, clamps inside (0.05, 0.95) and always reports the change")
    func featureSizeCommand() {
        var engine = Self.engine(Self.config(), count: 3)
        let out = Self.run(&engine, .featureSize(0.1))
        #expect(out.dirty == [1])
        #expect(abs((out.settings?.featureSize ?? 0) - 0.7) < 1e-9)

        let huge = Self.run(&engine, .featureSize(5))
        #expect(huge.settings?.featureSize ?? 1 < 0.95 && huge.settings?.featureSize ?? 0 > 0.94)
        let tiny = Self.run(&engine, .featureSize(-5))
        #expect(tiny.settings?.featureSize ?? 0 > 0.05 && tiny.settings?.featureSize ?? 1 < 0.06)
        #expect(engine.settings(for: 1).featureSize == tiny.settings?.featureSize)

        // It applies even where the feature is off or the layout is a tree.
        var off = Self.engine(Self.config(feature: .off), count: 2)
        #expect(Self.run(&off, .featureSize(0.1)).settings?.featureSize != nil)
        var tree = Self.engine(Self.config(.dwindle), count: 3)
        #expect(Self.run(&tree, .featureSize(0.1)).settings?.featureSize != nil)
    }

    @Test("feature-count adds and removes feature windows within 1…16 and reports the change")
    func featureCountCommand() {
        var engine = Self.engine(Self.config(), count: 4)
        let out = Self.run(&engine, .featureCount(1))
        #expect(out.dirty == [1] && out.settings == SettingsChange(space: 1, featureSize: nil, featureCount: 2))
        #expect(engine.settings(for: 1).featureCount == 2)
        // Windows 1 and 2 now share the feature area.
        let frames = Self.layout(engine).frames
        #expect(Self.near(frames[1], CGRect(x: 0, y: 0, width: 600, height: 400)))
        #expect(Self.near(frames[2], CGRect(x: 0, y: 400, width: 600, height: 400)))

        #expect(Self.run(&engine, .featureCount(-9)).settings?.featureCount == 1)
        #expect(Self.run(&engine, .featureCount(99)).settings?.featureCount == 16)
    }

    @Test("clearing the runtime overrides returns to the configured feature size and count")
    func clearOverrides() {
        var engine = Self.engine(Self.config(size: 0.6), count: 3)
        Self.run(&engine, .featureSize(0.2))
        Self.run(&engine, .featureCount(1))
        #expect(engine.settings(for: 1).featureCount == 2)
        engine.clearSettingOverrides(1, featureSize: true, featureCount: false)
        #expect(engine.settings(for: 1).featureSize == 0.6 && engine.settings(for: 1).featureCount == 2)
        engine.clearSettingOverrides(1, featureSize: false, featureCount: true)
        #expect(engine.settings(for: 1).featureCount == 1)
    }

    // MARK: - Promote and focus-feature

    @Test("promote moves the focused tile into the first slot; on the feature it swaps with the next tile")
    func promote() {
        var engine = Self.engine(Self.config(), count: 3)
        let out = Self.run(&engine, .promote, from: 3)
        #expect(out.dirty == [1])
        #expect(Self.state(engine).liveOrder.first == 3)
        #expect(Self.near(Self.layout(engine).frames[3], CGRect(x: 0, y: 0, width: 600, height: 800)))

        // Already the feature: the window after it takes the slot instead.
        let next = Self.state(engine).liveOrder[1]
        Self.run(&engine, .promote, from: 3)
        #expect(Self.state(engine).liveOrder.first == next)
    }

    @Test("focus-feature goes to the feature and back; without a feature it only explains")
    func focusFeatureToggles() {
        var engine = Self.engine(Self.config(), count: 3)
        _ = engine.focus(3)
        #expect(Self.run(&engine, .focusFeature).focus == 1)
        _ = engine.focus(1)
        #expect(Self.run(&engine, .focusFeature).focus == 3)

        var none = Self.engine(Self.config(feature: .off), count: 3)
        let out = Self.run(&none, .focusFeature, from: 2)
        #expect(out.message != nil && out.focus == nil)
    }

    // MARK: - Monocle

    @Test("monocle is a full-area deck of every tiled window, decks included; toggling off restores the grid")
    func monocleIsOneDeck() {
        var engine = Self.engine(Self.config(), count: 4)
        Self.run(&engine, .deck(.down), from: 3) // 3 and 4 share a tile
        _ = engine.focus(2)
        let before = Self.layout(engine)

        let on = Self.run(&engine, .monocle)
        #expect(on.dirty == [1] && engine.isMonocle(1))
        let monocle = Self.layout(engine)
        #expect(monocle.monocle && monocle.arrangement == .fixed) // the arrangement is kept
        #expect(Set(monocle.frames.keys) == [1, 2, 3, 4])
        #expect(monocle.raise == 2)
        #expect(Set(monocle.covered.keys) == [1, 3, 4])
        // The focused window fills the area (inset by the peeks); the others sit behind it.
        #expect(monocle.frames[2]!.minX == 0 && monocle.frames[2]!.width == 1000)
        #expect(monocle.frames.values.allSatisfy { $0.minX == 0 && $0.width == 1000 })
        #expect(monocle.scrolling == [1, 2, 3, 4])

        Self.run(&engine, .monocle)
        #expect(!engine.isMonocle(1))
        #expect(Self.layout(engine) == before)
    }

    @Test("in monocle the view follows focus and directional focus cycles every window")
    func monocleFocusAndCycle() {
        var engine = Self.engine(Self.config(), count: 4)
        Self.run(&engine, .monocle)
        #expect(engine.focus(3) == [1])
        let layout = Self.layout(engine)
        #expect(layout.covered[3] == nil && layout.raise == 3)
        #expect(Set(layout.covered.keys) == [1, 2, 4])

        let order = Self.state(engine).liveOrder
        _ = engine.focus(order[0])
        var forward = Set<WindowID?>(), backward = Set<WindowID?>()
        for direction in [Direction.right, .down] { forward.insert(Self.run(&engine, .focus(direction), from: order[0]).focus) }
        for direction in [Direction.left, .up] { backward.insert(Self.run(&engine, .focus(direction), from: order[0]).focus) }
        #expect(forward == [order[1]])
        #expect(backward == [order[3]])
    }

    @Test("monocle keeps the arrangement, in float it does nothing, and it ignores the feature")
    func monocleAcrossArrangements() {
        for config in [Self.config(.adaptive), Self.config(.dwindle, feature: .off), Self.config(feature: .center),
                       Self.config(rows: 1, feature: .off)] {
            var engine = Self.engine(config, count: 3)
            Self.run(&engine, .monocle)
            let layout = Self.layout(engine)
            #expect(layout.arrangement == config.layout.arrange)
            #expect(Set(layout.frames.keys) == [1, 2, 3])
            #expect(layout.frames.values.allSatisfy { $0.minX == 0 && $0.width == 1000 })
            #expect(layout.covered.count == 2)
        }
        var float = Self.engine(Self.config(.float), count: 3)
        Self.run(&float, .monocle)
        #expect(Self.layout(float).frames.isEmpty)
    }

    // MARK: - Invariants

    static let invariantConfigs: [(String, Config)] = {
        func cfg(_ arrange: Arrangement, columns: Int = 1, rows: Int = 0, feature: FeatureSide = .left,
                 count: Int = 1) -> Config {
            config(arrange, columns: columns, rows: rows, feature: feature, featureCount: count, gap: 8)
        }
        return [
            ("fixed 1xinf off", cfg(.fixed, feature: .off)), ("fixed 2xinf off", cfg(.fixed, columns: 2, feature: .off)),
            ("fixed 3x2 off", cfg(.fixed, columns: 3, rows: 2, feature: .off)),
            ("fixed 1x2 left", cfg(.fixed, rows: 2)), ("fixed 2x2 right", cfg(.fixed, columns: 2, rows: 2, feature: .right)),
            ("fixed 2xinf top", cfg(.fixed, columns: 2, feature: .top)),
            ("fixed 1x1 bottom", cfg(.fixed, rows: 1, feature: .bottom)),
            ("fixed 2x1 center", cfg(.fixed, columns: 2, rows: 1, feature: .center)),
            ("fixed 1xinf center count 2", cfg(.fixed, feature: .center, count: 2)),
            ("adaptive off", cfg(.adaptive, feature: .off)), ("adaptive left", cfg(.adaptive)),
            ("adaptive center", cfg(.adaptive, feature: .center)), ("adaptive top count 2", cfg(.adaptive, feature: .top, count: 2)),
            ("dwindle off", cfg(.dwindle, feature: .off)), ("dwindle left", cfg(.dwindle)),
            ("dwindle top", cfg(.dwindle, feature: .top)), ("balanced right count 2", cfg(.balanced, feature: .right, count: 2)),
            ("balanced center", cfg(.balanced, feature: .center)),
        ]
    }()

    @Test("frames stay inside the area and never overlap, except windows of a deck", arguments: invariantConfigs.map(\.0))
    func framesStayInsideAndDisjoint(name: String) throws {
        let config = try #require(Self.invariantConfigs.first { $0.0 == name }?.1)
        for count in 1...8 {
            let engine = Self.engine(config, count: count)
            let layout = Self.layout(engine)
            #expect(Set(layout.frames.keys) == Set((1...count).map { WindowID($0) }), "\(name) × \(count)")
            for (id, frame) in layout.frames {
                #expect(frame.width >= 0 && frame.height >= 0, "\(name) × \(count) window \(id)")
                #expect(Self.area.insetBy(dx: -0.5, dy: -0.5).contains(frame), "\(name) × \(count) window \(id): \(frame)")
            }
            // Windows of a scrolling deck legitimately share space; every other pair is disjoint.
            let flat = layout.frames.filter { !layout.scrolling.contains($0.key) }
            for (a, frameA) in flat {
                for (b, frameB) in flat where a < b {
                    let overlap = frameA.intersection(frameB)
                    #expect(overlap.isNull || overlap.width < 0.5 || overlap.height < 0.5,
                            "\(name) × \(count): \(a) \(frameA) overlaps \(b) \(frameB)")
                }
            }
            // A scrolling deck's windows stay out of the flat windows' way, too.
            for (id, frame) in layout.frames where layout.scrolling.contains(id) {
                for (other, otherFrame) in flat {
                    let overlap = frame.intersection(otherFrame)
                    #expect(overlap.isNull || overlap.width < 0.5 || overlap.height < 0.5,
                            "\(name) × \(count): deck window \(id) overlaps \(other)")
                }
            }
        }
    }

    @Test("a non-scrolling layout with a feature leaves no gap-free hole: frames plus gaps cover the area", arguments: [
        Arrangement.fixed, .adaptive,
    ])
    func framesCoverTheArea(arrange: Arrangement) {
        let engine = Self.engine(Self.config(arrange, feature: .left), count: 5)
        let total = Self.layout(engine).frames.values.map { $0.width * $0.height }.reduce(0, +)
        #expect(abs(total - 1000 * 800) < 1)
    }
}
