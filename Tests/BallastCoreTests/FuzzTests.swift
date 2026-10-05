import CoreGraphics
import Testing
@testable import BallastCore

/// Deterministic, seedable PRNG (SplitMix64) — no system randomness.
struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { self.state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

@Suite("Fuzz: Engine invariants")
struct EngineFuzzTests {

    static let displayA = "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"
    static let displayB = "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB"
    static let displayAreas = [
        displayA: CGRect(x: 0, y: 0, width: 1600, height: 1000),
        displayB: CGRect(x: 1600, y: 0, width: 1600, height: 1000),
    ]

    static func snapshotFull(smallA: Bool = false, smallB: Bool = false) -> SpaceSnapshot {
        let a = DisplaySpaces(displayUUID: displayA, spaces: [
            SpaceInfo(id: 1, uuid: "a1", kind: .user),
            SpaceInfo(id: 2, uuid: "a2", kind: .user),
            SpaceInfo(id: 3, uuid: "a3", kind: .fullscreen),
        ], activeSpace: 1, small: smallA)
        let b = DisplaySpaces(displayUUID: displayB, spaces: [
            SpaceInfo(id: 4, uuid: "b1", kind: .user),
            SpaceInfo(id: 5, uuid: "b2", kind: .user),
            SpaceInfo(id: 6, uuid: "b3", kind: .fullscreen),
        ], activeSpace: 4, small: smallB)
        return SpaceSnapshot(displays: [a, b])
    }

    /// A Space is deleted (space 2 dropped) relative to `snapshotFull`.
    static func snapshotSpaceDeleted(smallA: Bool = false, smallB: Bool = false) -> SpaceSnapshot {
        let a = DisplaySpaces(displayUUID: displayA, spaces: [
            SpaceInfo(id: 1, uuid: "a1", kind: .user),
            SpaceInfo(id: 3, uuid: "a3", kind: .fullscreen),
        ], activeSpace: 1, small: smallA)
        let b = DisplaySpaces(displayUUID: displayB, spaces: [
            SpaceInfo(id: 4, uuid: "b1", kind: .user),
            SpaceInfo(id: 5, uuid: "b2", kind: .user),
            SpaceInfo(id: 6, uuid: "b3", kind: .fullscreen),
        ], activeSpace: 4, small: smallB)
        return SpaceSnapshot(displays: [a, b])
    }

    /// Display B unplugged relative to `snapshotFull`.
    static func snapshotDisplayUnplugged(smallA: Bool = false) -> SpaceSnapshot {
        let a = DisplaySpaces(displayUUID: displayA, spaces: [
            SpaceInfo(id: 1, uuid: "a1", kind: .user),
            SpaceInfo(id: 2, uuid: "a2", kind: .user),
            SpaceInfo(id: 3, uuid: "a3", kind: .fullscreen),
        ], activeSpace: 1, small: smallA)
        return SpaceSnapshot(displays: [a])
    }

    /// Both surviving ids swap ordinals relative to `snapshotFull`: display A lists 2, 1, then the fullscreen Space.
    static func snapshotReordered(smallA: Bool = false, smallB: Bool = false) -> SpaceSnapshot {
        let a = DisplaySpaces(displayUUID: displayA, spaces: [
            SpaceInfo(id: 2, uuid: "a2", kind: .user),
            SpaceInfo(id: 1, uuid: "a1", kind: .user),
            SpaceInfo(id: 3, uuid: "a3", kind: .fullscreen),
        ], activeSpace: 1, small: smallA)
        let b = snapshotFull(smallA: smallA, smallB: smallB).displays[1]
        return SpaceSnapshot(displays: [a, b])
    }

    static let allSpaceIDs: [SpaceID] = [1, 2, 3, 4, 5, 6]
    static let knownAppIDs = ["com.a.app", "com.b.app", "com.ghostty.app", "com.tinyspeck.slackmacgap"]

    /// Two-column fixed grid scrolling past two windows per column with a
    /// left feature by default, a centered-feature 1×1 deck desktop, an
    /// unlimited three-column centered-feature desktop, an adaptive desktop,
    /// and a dwindle desktop, so every arrangement shape runs.
    static func configA() -> Config {
        var config = Config()
        config.layout.arrange = .fixed
        config.layout.rows = 2
        config.layout.deckPeek = 24
        config.layout.columns = 2
        config.layout.feature = .left
        var deck = LayoutOverrides()
        deck.feature = .center
        deck.rows = 1
        deck.columns = 1
        config.spaces[.position(display: displayA, ordinal: 2)] = deck
        var unlimited = LayoutOverrides()
        unlimited.feature = .center
        unlimited.rows = 0
        unlimited.columns = 3
        unlimited.featureCount = 2
        config.spaces[.position(display: displayB, ordinal: 1)] = unlimited
        var adaptive = LayoutOverrides()
        adaptive.arrange = .adaptive
        adaptive.feature = .off
        config.spaces[.position(display: displayB, ordinal: 2)] = adaptive
        config.rules = [
            AppRule(match: RuleMatch(appID: "com.ghostty.app"), actions: RuleActions(weight: 8)),
            AppRule(match: RuleMatch(appID: "com.tinyspeck.slackmacgap"), actions: RuleActions(weight: 0.5)),
        ]
        return config
    }

    static let arrangements: [Arrangement] = [.fixed, .adaptive, .dwindle, .balanced, .float]
    static let featureSides: [FeatureSide] = [.off, .left, .right, .top, .bottom, .center]

    /// Random overrides: every key is set or left to the cascade, always
    /// inside its config range.
    static func randomOverrides(_ rng: inout SplitMix64) -> LayoutOverrides {
        var o = LayoutOverrides()
        if rng.next() % 3 != 0 { o.arrange = arrangements.randomElement(using: &rng) }
        if rng.next() % 3 != 0 { o.feature = featureSides.randomElement(using: &rng) }
        if rng.next() % 3 != 0 { o.columns = Int(rng.next() % 8) + 1 }
        if rng.next() % 3 != 0 { o.rows = Int(rng.next() % 17) }
        if rng.next() % 3 != 0 { o.featureCount = Int(rng.next() % 16) + 1 }
        if rng.next() % 3 != 0 { o.featureSize = 0.06 + Double(rng.next() % 89) / 100 }
        if rng.next() % 3 != 0 { o.deckPeek = Double(rng.next() % 201) }
        if rng.next() % 3 != 0 { o.split = .some([Axis.horizontal, .vertical, nil].randomElement(using: &rng)!) }
        if rng.next() % 3 != 0 {
            o.weightShareMin = 0.05 + Double(rng.next() % 41) / 100
            o.weightShareMax = 0.55 + Double(rng.next() % 41) / 100
        }
        if rng.next() % 3 != 0 { o.gapsInner = Double(rng.next() % 40) }
        if rng.next() % 3 != 0 { o.gapsOuter = Double(rng.next() % 120) }
        return o
    }

    /// A config with random `[layout]` and `[[space]]` overrides.
    static func randomConfig(_ rng: inout SplitMix64) -> Config {
        var config = Config()
        config.layout = randomOverrides(&rng)
        for display in [displayA, displayB] {
            for ordinal in 1...2 where rng.next() % 2 == 0 {
                config.spaces[.position(display: display, ordinal: ordinal)] = randomOverrides(&rng)
            }
        }
        config.rules = [
            AppRule(match: RuleMatch(appID: "com.a.app"), actions: RuleActions(weight: 3)),
        ]
        if rng.next() % 3 == 0 {
            config.rules.append(AppRule(match: RuleMatch(appID: knownAppIDs.randomElement(using: &rng)),
                                        actions: RuleActions(manage: false)))
        }
        return config
    }

    static func randomFacts(_ rng: inout SplitMix64) -> WindowFacts {
        let bundle = knownAppIDs.randomElement(using: &rng)
        let isDialog = Bool.random(using: &rng) && Double.random(in: 0...1, using: &rng) < 0.15
        // Mostly the tiling answer; now and then a floating one or unknown.
        func fact(_ rng: inout SplitMix64) -> Bool? {
            switch rng.next() % 20 {
            case 0: return nil
            case 1: return false
            default: return true
            }
        }
        return WindowFacts(
            bundleID: bundle,
            appName: bundle,
            title: "Window \(rng.next() % 5)",
            role: "AXWindow",
            subrole: isDialog ? "AXDialog" : "AXStandardWindow",
            modal: rng.next() % 20 == 0,
            resizable: fact(&rng),
            fullScreen: fact(&rng))
    }

    static func randomSpace(_ rng: inout SplitMix64) -> SpaceID? {
        switch rng.next() % 8 {
        case 0: return nil
        case 1: return 999 // unknown
        case 2: return 3 // fullscreen A
        case 3: return 6 // fullscreen B
        default: return allSpaceIDs.randomElement(using: &rng)
        }
    }

    static func randomArea(_ rng: inout SplitMix64) -> CGRect? {
        switch rng.next() % 6 {
        case 0: return nil
        case 1: return .zero
        default:
            let w = Double(rng.next() % 2000)
            let h = Double(rng.next() % 1500)
            return CGRect(x: 0, y: 0, width: w, height: h)
        }
    }

    static func randomCommand(_ rng: inout SplitMix64) -> Command {
        let direction = [Direction.left, .right, .up, .down].randomElement(using: &rng) ?? .left
        let cycle: Cycle = Bool.random(using: &rng) ? .next : .prev
        switch rng.next() % 22 {
        case 0: return .focus(direction)
        case 1: return .swap(direction)
        case 2: return .focusLast
        case 3: return .promote
        case 4: return .reset
        case 5: return .monocle
        case 6: return .toggleFloat
        case 7: return .resize(Double(Int(rng.next() % 21) - 10) / 20)
        case 8: return .featureSize(Double(Int(rng.next() % 41) - 20) / 10)
        case 9: return .featureCount(Int(rng.next() % 41) - 20)
        case 10: return .balance
        case 11: return .sendToDisplay(cycle)
        case 12: return .focusFeature
        case 13: return .relayout
        case 14, 15: return .deck(direction)
        case 16: return .undeck
        case 17: return .monocle
        case 18: return .focus(direction)
        case 19: return .swap(direction)
        case 20: return .focusCycle(cycle)
        default: return .focusDisplay(cycle)
        }
    }

    /// Verifies every documented Engine invariant after a mutation.
    static func assertInvariants(_ engine: Engine, seed: UInt64, step: Int) {
        // Effective settings stay inside the config ranges on every Space.
        for spaceID in allSpaceIDs + [999] {
            let s = engine.settings(for: spaceID)
            #expect((1...8).contains(s.columns) && (0...16).contains(s.rows) && (1...16).contains(s.featureCount)
                        && s.featureSize > 0.05 && s.featureSize < 0.95 && (0...200).contains(s.deckPeek),
                    "seed \(seed) step \(step): settings out of range on space \(spaceID): \(s)")
        }
        if let focused = engine.focused {
            #expect(engine.windows[focused]?.isManaged == true, "seed \(seed) step \(step): focused \(focused) is gone or unmanaged")
        }
        if let front = engine.frontmost {
            #expect(engine.windows[front] != nil, "seed \(seed) step \(step): frontmost \(front) is gone")
        }

        for (spaceID, state) in engine.spaces {
            // Members unique.
            #expect(Set(state.members).count == state.members.count, "seed \(seed) step \(step): duplicate members on space \(spaceID)")

            // Decks: two windows at least, the holder among them, only members, none in two decks.
            var decked = Set<WindowID>()
            for (holder, list) in state.decks {
                #expect(list.count >= 2 && list.contains(holder) && Set(list).count == list.count,
                        "seed \(seed) step \(step): malformed deck \(list) held by \(holder) on space \(spaceID)")
                #expect(list.allSatisfy { state.members.contains($0) && decked.insert($0).inserted },
                        "seed \(seed) step \(step): deck \(list) has a non-member or shares a window on space \(spaceID)")
            }
            #expect(state.tiles.count == state.members.count - decked.count + state.decks.count,
                    "seed \(seed) step \(step): tile count off on space \(spaceID)")
            #expect(state.tileCount == state.tiles.count)

            // Tree leaves == tiles (a deck's holder stands for it), leaves unique.
            if let tree = state.tree {
                let leaves = tree.leaves
                #expect(Set(leaves).count == leaves.count, "seed \(seed) step \(step): duplicate tree leaves on space \(spaceID)")
                #expect(Set(leaves) == Set(state.tiles), "seed \(seed) step \(step): tree leaves != tiles on space \(spaceID)")
            } else {
                #expect(state.members.isEmpty, "seed \(seed) step \(step): nil tree but non-empty members on space \(spaceID)")
            }

            // idealOrder set == tiles.
            #expect(Set(state.idealOrder) == Set(state.tiles) && state.idealOrder.count == state.tiles.count,
                    "seed \(seed) step \(step): idealOrder != tiles on space \(spaceID)")

            // recentTiles ranks exactly the members; only windows of the
            // focused tile's app, joined since it took focus, rank ahead of it.
            #expect(state.recentTiles.count == state.members.count && Set(state.recentTiles) == Set(state.members),
                    "seed \(seed) step \(step): recentTiles \(state.recentTiles) != members \(state.members) on space \(spaceID)")
            if let focused = engine.focused, let index = state.recentTiles.firstIndex(of: focused) {
                let pid = engine.windows[focused]?.pid
                #expect(state.recentTiles[..<index].allSatisfy { engine.windows[$0]?.pid == pid },
                        "seed \(seed) step \(step): another app's window ranks ahead of focused \(focused) on space \(spaceID)")
            }

            // manualOrder set == members, no dups, when manual.
            if state.manual {
                #expect(Set(state.manualOrder).count == state.manualOrder.count, "seed \(seed) step \(step): duplicate manualOrder on space \(spaceID)")
                #expect(Set(state.manualOrder) == Set(state.tiles), "seed \(seed) step \(step): manualOrder != tiles on space \(spaceID)")
            }

            // Every member's WindowRecord exists, space matches, isTiled true.
            for member in state.members {
                guard let record = engine.windows[member] else {
                    Issue.record("seed \(seed) step \(step): member \(member) has no WindowRecord")
                    continue
                }
                #expect(record.space == spaceID, "seed \(seed) step \(step): member \(member) record.space mismatch")
                #expect(engine.isTiled(member), "seed \(seed) step \(step): member \(member) not tiled")
            }

            // layout frames: coverage (non-float modes tile every member),
            // finiteness, non-negative sizes, and non-overlap (when no window
            // has adopted its own frame), checked over several areas including
            // degenerate ones.
            let areas: [CGRect] = [
                CGRect(x: 0, y: 0, width: 1600, height: 1000),
                .zero,
                CGRect(x: 0, y: 0, width: 10, height: 10),
                CGRect(x: 0, y: 0, width: 2, height: 2),
            ]
            for area in areas {
                let layout = engine.layout(space: spaceID, area: area)
                let frames = layout.frames
                if layout.arrangement != .float {
                    #expect(Set(frames.keys) == Set(state.members),
                            "seed \(seed) step \(step): layout \(layout.arrangement) frames \(Set(frames.keys)) != members \(Set(state.members)) on space \(spaceID) area \(area)")
                }
                for (id, frame) in frames {
                    #expect(state.members.contains(id), "seed \(seed) step \(step): layout frame for non-member \(id) on space \(spaceID)")
                    #expect(frame.width.isFinite && frame.height.isFinite && frame.minX.isFinite && frame.minY.isFinite,
                            "seed \(seed) step \(step): non-finite frame for \(id)")
                    #expect(frame.size.width >= 0 && frame.size.height >= 0, "seed \(seed) step \(step): negative frame size for \(id)")
                }
                // Monocle keeps every tiled window framed (above) and inside
                // the area, unless a window refuses to shrink or adopted its
                // own frame.
                if layout.monocle && layout.arrangement != .float && state.frameOverrides.isEmpty
                    && state.members.allSatisfy({ engine.windows[$0]?.minSize == .zero }) {
                    let eps = 1e-6
                    for (id, frame) in frames {
                        #expect(frame.minX >= area.minX - eps && frame.minY >= area.minY - eps
                                    && frame.maxX <= area.maxX + eps && frame.maxY <= area.maxY + eps,
                                "seed \(seed) step \(step): monocle frame \(frame) for \(id) outside \(area) on space \(spaceID)")
                    }
                }
                // The feature never shares room with the grid: no window of a
                // featured tile in view overlaps one of another tile in view.
                let settings = engine.settings(for: spaceID)
                if !layout.monocle && settings.hasFeature && state.frameOverrides.isEmpty {
                    let order = settings.arrange.isTree ? (state.tree?.leaves ?? []) : state.liveOrder
                    let count = FeatureLayout.featuredCount(feature: settings.effectiveFeature, count: settings.featureCount, total: order.count)
                    let featured = Set(order.prefix(count))
                    let visible = frames.filter { layout.covered[$0.key] == nil && $0.value.width > 0 && $0.value.height > 0 }
                    let inFeature = visible.filter { featured.contains(state.tile(of: $0.key)) }
                    let inGrid = visible.filter { !featured.contains(state.tile(of: $0.key)) }
                    for (f, featureFrame) in inFeature {
                        for (g, gridFrame) in inGrid {
                            #expect(!Self.overlaps(featureFrame, gridFrame),
                                    "seed \(seed) step \(step): feature \(f) overlaps grid tile \(g) on space \(spaceID) area \(area)")
                        }
                    }
                }
                if !layout.monocle && state.frameOverrides.isEmpty {
                    // Tiles never overlap; a scrolling stack's tucked windows
                    // sit behind them, showing strips that overlap neither a
                    // tile nor each other.
                    let tiles = Array(frames.filter { layout.covered[$0.key] == nil && $0.value.width > 0 && $0.value.height > 0 })
                    for i in 0..<tiles.count {
                        for j in (i + 1)..<tiles.count {
                            #expect(!tiles[i].value.intersects(tiles[j].value),
                                    "seed \(seed) step \(step): frames for \(tiles[i].key) and \(tiles[j].key) intersect on space \(spaceID) area \(area)")
                        }
                    }
                    let strips = Array(layout.covered)
                    for (i, strip) in strips.enumerated() {
                        for tile in tiles {
                            #expect(!Self.overlaps(strip.value, tile.value),
                                    "seed \(seed) step \(step): strip of \(strip.key) overlaps tile \(tile.key) on space \(spaceID) area \(area)")
                        }
                        for other in strips[(i + 1)...] {
                            #expect(!Self.overlaps(strip.value, other.value),
                                    "seed \(seed) step \(step): strips of \(strip.key) and \(other.key) overlap on space \(spaceID) area \(area)")
                        }
                    }
                }
                #expect(Set(layout.covered.keys).isSubset(of: Set(frames.keys)),
                        "seed \(seed) step \(step): covered windows without a frame on space \(spaceID)")
                if layout.arrangement != .float && !layout.monocle {
                    #expect(Set(layout.navigation.keys) == Set(frames.keys),
                            "seed \(seed) step \(step): navigation keys != frame keys on space \(spaceID)")
                }
                if let raise = layout.raise {
                    #expect(state.members.contains(raise) && layout.covered[raise] == nil,
                            "seed \(seed) step \(step): raising \(raise), not a tile in view, on space \(spaceID)")
                }
                // Deck tiles are tiles in view, never `raise`; what belongs
                // behind them is tucked or peeking.
                for (tile, hidden) in layout.behind {
                    #expect(state.members.contains(tile) && layout.covered[tile] == nil && tile != layout.raise
                                && !hidden.isEmpty && hidden.allSatisfy { layout.covered[$0] != nil },
                            "seed \(seed) step \(step): deck tile \(tile) over \(hidden) on space \(spaceID)")
                }
                // Raising a window of the focused window's app but the focused
                // one hands it focus.
                if let front = engine.frontmost, let pid = engine.windows[front]?.pid {
                    for tile in Array(layout.behind.keys) + [layout.raise].compactMap({ $0 }) where tile != front {
                        #expect(engine.windows[tile]?.pid != pid,
                                "seed \(seed) step \(step): raising \(tile) of focused \(front)'s app on space \(spaceID)")
                    }
                }
                // The view always holds the front window: the tile that last
                // took focus or joined.
                if let front = state.recentTiles.first {
                    #expect(layout.covered[front] == nil,
                            "seed \(seed) step \(step): front \(front) tucked behind the view on space \(spaceID)")
                }
                // In the full-size area, nothing in view spills out of it, and with room to spare no tile is below its minimum.
                if area == areas[0] && !layout.monocle && layout.arrangement != .float && state.frameOverrides.isEmpty {
                    let eps = 1.0
                    for (id, frame) in frames where layout.covered[id] == nil {
                        #expect(frame.minX >= area.minX - eps && frame.minY >= area.minY - eps
                                    && frame.maxX <= area.maxX + eps && frame.maxY <= area.maxY + eps,
                                "seed \(seed) step \(step): frame \(frame) for \(id) outside \(area) on space \(spaceID)")
                    }
                    let finite = { (v: Double) in v.isFinite ? max(v, 0) : 0 }
                    let gap = settings.gaps.inner, inner = area.insetClamped(by: settings.gaps.outer)
                    let mins = state.members.map { id -> CGSize in
                        let m = engine.windows[id]?.minSize ?? .zero
                        return CGSize(width: finite(m.width), height: finite(m.height))
                    }
                    let slack = gap * Double(max(mins.count - 1, 0))
                    if layout.covered.isEmpty && state.decks.isEmpty
                        && mins.reduce(0, { $0 + $1.width }) + slack <= inner.width
                        && mins.reduce(0, { $0 + $1.height }) + slack <= inner.height {
                        for (id, frame) in frames {
                            let m = engine.windows[id]?.minSize ?? .zero
                            #expect(frame.width >= finite(m.width) - eps && frame.height >= finite(m.height) - eps,
                                    "seed \(seed) step \(step): frame \(frame) for \(id) below minimum \(m) on space \(spaceID)")
                        }
                    }
                }
            }
        }

        // Every tiled window is a member of exactly one space.
        var membership: [WindowID: Int] = [:]
        for (_, state) in engine.spaces {
            for member in state.members { membership[member, default: 0] += 1 }
        }
        for (id, _) in engine.windows where engine.isTiled(id) {
            #expect(membership[id] == 1, "seed \(seed) step \(step): tiled window \(id) is a member of \(membership[id] ?? 0) spaces")
        }
    }

    /// Whether two rects share positive area (touching edges don't count).
    static func overlaps(_ a: CGRect, _ b: CGRect) -> Bool {
        let common = a.intersection(b)
        return !common.isNull && common.width > 0 && common.height > 0
    }

    @Test("random operation sequences preserve Engine invariants", arguments: (1...12).map { UInt64($0) })
    func randomOperations(seed: UInt64) {
        var rng = SplitMix64(seed: seed)
        var engine = Engine(config: seed % 2 == 1 ? Self.configA() : Self.randomConfig(&rng))
        _ = engine.updateSnapshot(Self.snapshotFull(smallA: rng.next() % 2 == 0, smallB: rng.next() % 2 == 0))
        var knownIDs: [WindowID] = []

        for step in 0..<3000 {
            switch rng.next() % 15 {
            case 0, 1:
                // addWindow: random id incl. duplicates.
                let id: WindowID
                if !knownIDs.isEmpty, rng.next() % 3 == 0 {
                    id = knownIDs.randomElement(using: &rng)!
                } else {
                    id = WindowID(rng.next() % 40)
                    if !knownIDs.contains(id) { knownIDs.append(id) }
                }
                // Few pids: windows share apps, which the raise rules care about.
                _ = engine.addWindow(id, pid: Int32(id % 6), facts: Self.randomFacts(&rng), space: Self.randomSpace(&rng))
            case 2:
                // removeWindow, sometimes unknown id.
                let id = (rng.next() % 5 == 0) ? WindowID(rng.next() % 100 + 1000) : (knownIDs.randomElement(using: &rng) ?? WindowID(rng.next() % 40))
                _ = engine.removeWindow(id, hadFocus: Bool.random(using: &rng))
                knownIDs.removeAll { $0 == id }
            case 3:
                guard let id = knownIDs.randomElement(using: &rng) else { break }
                _ = engine.setSpace(id, Self.randomSpace(&rng))
            case 4:
                guard let id = knownIDs.randomElement(using: &rng) else { break }
                _ = engine.setMinimized(id, Bool.random(using: &rng))
            case 5:
                let id: WindowID? = (rng.next() % 5 == 0) ? nil
                    : ((rng.next() % 6 == 0) ? WindowID(rng.next() % 100 + 1000) : knownIDs.randomElement(using: &rng))
                _ = engine.focus(id)
            case 6:
                guard let id = knownIDs.randomElement(using: &rng) else { break }
                _ = engine.updateFacts(id, Self.randomFacts(&rng))
            case 7:
                guard let id = knownIDs.randomElement(using: &rng) else { break }
                let big = rng.next() % 4 == 0
                let size = big ? CGSize(width: 1e7, height: 1e7) : (rng.next() % 4 == 0 ? .zero : CGSize(width: Double(rng.next() % 500), height: Double(rng.next() % 500)))
                _ = engine.learnMinSize(id, size)
            case 8:
                guard let id = knownIDs.randomElement(using: &rng) else { break }
                let frame = CGRect(x: Double(rng.next() % 500), y: Double(rng.next() % 500),
                                    width: Double(rng.next() % 800), height: Double(rng.next() % 800))
                if Bool.random(using: &rng) {
                    _ = engine.adoptFrame(id, frame)
                } else {
                    // A user drag of the tile's edges, from its planned frame or an arbitrary one.
                    let area = engine.windows[id]?.space.flatMap { engine.snapshot.key(for: $0) }
                        .flatMap { Self.displayAreas[$0.display] } ?? .zero
                    let planned = engine.windows[id]?.space.flatMap { engine.layout(space: $0, area: area).frames[id] } ?? frame
                    let dragged = planned.insetBy(dx: Double(Int(rng.next() % 401) - 200) / 2,
                                                  dy: Double(Int(rng.next() % 401) - 200) / 2)
                        .offsetBy(dx: Double(Int(rng.next() % 101) - 50), dy: Double(Int(rng.next() % 101) - 50))
                    let outcome = engine.resizeTile(id, from: planned, to: dragged, area: area)
                    if let size = outcome.settings?.featureSize {
                        #expect(size > 0.05 && size < 0.95, "seed \(seed) step \(step): drag featureSize \(size) out of range")
                    }
                }
            case 9:
                let before = Dictionary(uniqueKeysWithValues: engine.spaces.keys.map { ($0, engine.settings(for: $0)) })
                switch rng.next() % 5 {
                case 0: _ = engine.applyConfig(Self.configA())
                case 1, 2: _ = engine.applyConfig(Self.randomConfig(&rng))
                case 3: _ = engine.setPassthrough(Bool.random(using: &rng))
                default:
                    let smallA = rng.next() % 2 == 0, smallB = rng.next() % 2 == 0
                    _ = engine.updateSnapshot([
                        Self.snapshotFull(smallA: smallA, smallB: smallB),
                        Self.snapshotSpaceDeleted(smallA: smallA, smallB: smallB),
                        Self.snapshotDisplayUnplugged(smallA: smallA),
                        Self.snapshotReordered(smallA: smallA, smallB: smallB),
                    ].randomElement(using: &rng)!)
                }
                // A settings change leaves non-manual balanced Spaces on their ideal tree.
                for (id, state) in engine.spaces where !state.manual {
                    guard let old = before[id], engine.settings(for: id) != old, engine.settings(for: id).arrange == .balanced else { continue }
                    #expect(state.tree == engine.idealTree(state.idealOrder, on: id, decks: state.decks),
                            "seed \(seed) step \(step): balanced space \(id) kept a stale tree after a settings change")
                }
            case 10:
                // Draw the command's Space from the focused window's Space
                // most of the time, so focus-dependent commands (swap,
                // promote, resize, toggleFloat, ...) actually land on a
                // tiled member instead of missing on an unrelated Space.
                let focusedSpace = engine.focused.flatMap { engine.windows[$0]?.space }
                let space: SpaceID? = (focusedSpace != nil && rng.next() % 5 != 0) ? focusedSpace : Self.randomSpace(&rng)
                let command = Self.randomCommand(&rng)
                let before = Self.focusedExtent(engine, space: space)
                let outcome = engine.perform(command, space: space, areas: Self.displayAreas)
                if case .resize(let d) = command, d != 0, outcome.message == nil, let before,
                   let after = Self.focusedExtent(engine, space: space) {
                    // Rounding may cost a point or two; a wrong-direction resize costs far more.
                    #expect((after - before) * (d > 0 ? 1 : -1) >= -2.01,
                            "seed \(seed) step \(step): resize(\(d)) moved the focused tile \(before) -> \(after)")
                }
                if let change = outcome.settings {
                    if let size = change.featureSize {
                        #expect(size > 0.05 && size < 0.95, "seed \(seed) step \(step): SettingsChange featureSize \(size) out of range")
                    }
                    if let count = change.featureCount {
                        #expect((1...16).contains(count), "seed \(seed) step \(step): SettingsChange featureCount \(count) out of range")
                    }
                }
            case 11:
                // Native tab switch between arbitrary windows (incl. unknown ids and decked ones).
                let ids = knownIDs + [WindowID(rng.next() % 40)]
                _ = engine.swapTab(hiding: ids.randomElement(using: &rng) ?? 0, showing: ids.randomElement(using: &rng) ?? 1)
            case 12:
                guard let id = knownIDs.randomElement(using: &rng) else { break }
                if Bool.random(using: &rng) { _ = engine.setHidden(id, Bool.random(using: &rng)) }
                else { _ = engine.setBackgroundTab(id, Bool.random(using: &rng)) }
            case 13:
                let space = Self.randomSpace(&rng) ?? 1
                if Bool.random(using: &rng) {
                    // Read back from the Space's own layout, or from arbitrary (overlapping, partial) frames.
                    let area = engine.snapshot.key(for: space).flatMap { Self.displayAreas[$0.display] } ?? .zero
                    var frames = engine.layout(space: space, area: area).frames
                    if Bool.random(using: &rng) {
                        for id in knownIDs where rng.next() % 4 != 0 {
                            frames[id] = CGRect(x: Double(rng.next() % 1000), y: Double(rng.next() % 800),
                                                width: Double(rng.next() % 800), height: Double(rng.next() % 800))
                        }
                    }
                    _ = engine.adoptArrangement(space, area: area, frames: frames)
                }
                else { engine.clearSettingOverrides(space, featureSize: Bool.random(using: &rng), featureCount: Bool.random(using: &rng)) }
            case 14:
                let ids = knownIDs + [WindowID(rng.next() % 40)]
                _ = engine.swap(ids.randomElement(using: &rng) ?? 0, ids.randomElement(using: &rng) ?? 1,
                                on: Self.randomSpace(&rng) ?? 1)
            default: break
            }
            Self.assertInvariants(engine, seed: seed, step: step)
        }
    }

    /// The focused tile's width + height on `space`, nil when it isn't a plainly drawn tile there.
    static func focusedExtent(_ engine: Engine, space: SpaceID?) -> Double? {
        guard let space, let f = engine.focused, engine.windows[f]?.space == space,
              let state = engine.spaces[space], state.members.contains(f), !state.monocle, !state.isDecked(f),
              let display = engine.snapshot.key(for: space)?.display, let area = displayAreas[display],
              let frame = engine.layout(space: space, area: area).frames[f] else { return nil }
        return Double(frame.width + frame.height)
    }
}

@Suite("Fuzz: BSPNode invariants")
struct BSPFuzzTests {

    static func minSize(_ id: WindowID) -> CGSize { .zero }
    static func weight(_ id: WindowID) -> Double { 1 }

    /// All manual (user-pinned) split ratios anywhere in the tree.
    static func manualRatios(_ node: BSPNode) -> [Double] {
        switch node {
        case .leaf: return []
        case .split(let s):
            var ratios = s.ratio.map { [$0] } ?? []
            ratios += manualRatios(s.first)
            ratios += manualRatios(s.second)
            return ratios
        }
    }

    @Test("random insert/remove/reparent/resize/swap sequences preserve tree invariants", arguments: [UInt64(11), 22, 33])
    func randomTreeOperations(seed: UInt64) {
        var rng = SplitMix64(seed: seed)
        var tree: BSPNode? = .leaf(0)
        // Ordered, not a Set: `randomElement(using:)` on a Set walks
        // hash-seeded storage order, which differs across process runs even
        // for the same seed, defeating replay of a reported failure.
        var shadow: [WindowID] = [0]
        var nextID: WindowID = 1
        let ctx = BSPLayoutContext(weight: Self.weight, minRatio: 0.1, maxRatio: 0.9, gap: 4, minSize: Self.minSize)
        let layoutRect = CGRect(x: 0, y: 0, width: 1600, height: 1000)

        for step in 0..<3000 {
            let before = tree
            switch rng.next() % 6 {
            case 0:
                // Insert a brand-new id next to a random existing (or unknown) target.
                let id = nextID
                nextID += 1
                let target: WindowID? = shadow.isEmpty ? nil : (rng.next() % 5 == 0 ? WindowID(9999) : shadow.randomElement(using: &rng))
                let axis: Axis? = Bool.random(using: &rng) ? .horizontal : nil
                if let t = tree {
                    let result = t.inserting(id, nextTo: target, axis: axis)
                    switch result {
                    case .success(let next):
                        tree = next
                        shadow.append(id)
                    case .failure(let error):
                        #expect(tree == before, "seed \(seed) step \(step): failed insert mutated tree")
                        Issue.record("seed \(seed) step \(step): insert of fresh id \(id) unexpectedly failed: \(error)")
                    }
                } else {
                    tree = .leaf(id)
                    shadow.append(id)
                }
            case 1:
                // Duplicate insert attempt (should fail, tree unchanged).
                guard let existing = shadow.randomElement(using: &rng), let t = tree else { break }
                let result = t.inserting(existing, nextTo: shadow.randomElement(using: &rng), axis: nil)
                #expect(result == .failure(.duplicate(existing)))
                #expect(tree == before)
            case 2:
                // Remove, valid or invalid id.
                let id = (rng.next() % 4 == 0) ? WindowID(9999) : (shadow.randomElement(using: &rng) ?? WindowID(9999))
                guard let t = tree else { break }
                switch t.removing(id) {
                case .success(let next):
                    tree = next
                    shadow.removeAll { $0 == id }
                case .failure(let error):
                    #expect(tree == before, "seed \(seed) step \(step): failed remove mutated tree")
                    #expect(!shadow.contains(id))
                    #expect(error == .notFound(id), "seed \(seed) step \(step): unexpected remove error \(error)")
                }
            case 3:
                // Swap, valid or invalid ids.
                guard let t = tree else { break }
                let a = shadow.randomElement(using: &rng) ?? WindowID(9999)
                let b = (rng.next() % 4 == 0) ? WindowID(9999) : (shadow.randomElement(using: &rng) ?? WindowID(9998))
                switch t.swapping(a, b) {
                case .success(let next):
                    tree = next
                    #expect(next.leaves.contains(a) && next.leaves.contains(b), "seed \(seed) step \(step): swap dropped a or b")
                case .failure(let error):
                    #expect(tree == before, "seed \(seed) step \(step): failed swap mutated tree")
                    if a == b {
                        #expect(error == .sameWindow(a), "seed \(seed) step \(step): unexpected swap error \(error)")
                    } else {
                        #expect(error == .notFound(a) || error == .notFound(b), "seed \(seed) step \(step): unexpected swap error \(error)")
                    }
                }
            case 4:
                // Resize a random (possibly unknown) id.
                guard let t = tree else { break }
                let id = (rng.next() % 4 == 0) ? WindowID(9999) : (shadow.randomElement(using: &rng) ?? WindowID(9999))
                let delta = Double(Int(rng.next() % 21) - 10) / 50
                switch t.resizing(id, by: delta, context: ctx) {
                case .success(let next):
                    tree = next
                case .failure(let error):
                    #expect(tree == before, "seed \(seed) step \(step): failed resize mutated tree")
                    #expect(error == .notFound(id) || error == .isRoot(id), "seed \(seed) step \(step): unexpected resize error \(error)")
                }
            default:
                // Move (reparent): remove then insert elsewhere.
                guard let t = tree, let id = shadow.randomElement(using: &rng) else { break }
                guard case .success(let removed) = t.removing(id) else {
                    Issue.record("seed \(seed) step \(step): reparent remove of known id \(id) failed")
                    break
                }
                shadow.removeAll { $0 == id }
                let target = shadow.randomElement(using: &rng)
                if let removed {
                    switch removed.inserting(id, nextTo: target, axis: nil) {
                    case .success(let next):
                        tree = next
                        shadow.append(id)
                    case .failure(let error):
                        Issue.record("seed \(seed) step \(step): reparent reinsert of \(id) failed: \(error)")
                        tree = removed
                    }
                } else {
                    tree = .leaf(id)
                    shadow.append(id)
                }
            }

            // Invariants: leaves unique and equal to the shadow set.
            if let tree {
                let leaves = tree.leaves
                #expect(Set(leaves).count == leaves.count, "seed \(seed) step \(step): duplicate leaves")
                #expect(Set(leaves) == Set(shadow), "seed \(seed) step \(step): leaves \(Set(leaves)) != shadow \(Set(shadow))")

                // Layout: exactly one finite frame per leaf, no two non-empty
                // frames intersect (minSize is zero here), manual ratios stay
                // inside the configured bounds.
                let frames = tree.layout(in: layoutRect, context: ctx)
                #expect(Set(frames.keys) == Set(leaves), "seed \(seed) step \(step): layout frames \(Set(frames.keys)) != leaves \(Set(leaves))")
                for (id, frame) in frames {
                    #expect(frame.width.isFinite && frame.height.isFinite && frame.minX.isFinite && frame.minY.isFinite,
                            "seed \(seed) step \(step): non-finite frame for \(id)")
                }
                let entries = Array(frames.filter { $0.value.width > 0 && $0.value.height > 0 })
                for i in 0..<entries.count {
                    for j in (i + 1)..<entries.count {
                        #expect(!entries[i].value.intersects(entries[j].value),
                                "seed \(seed) step \(step): frames for \(entries[i].key) and \(entries[j].key) intersect")
                    }
                }
                for ratio in Self.manualRatios(tree) {
                    #expect(ratio >= 0.1 && ratio <= 0.9, "seed \(seed) step \(step): manual ratio \(ratio) out of bounds")
                }
            } else {
                #expect(shadow.isEmpty, "seed \(seed) step \(step): nil tree but non-empty shadow")
            }
        }
    }
}
