import CoreGraphics
import Testing
@testable import BallastCore

@Suite("Engine")
struct EngineTests {

    static let displayA = "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"
    static let displayB = "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB"
    static let area = CGRect(x: 0, y: 0, width: 1000, height: 800)
    /// Every display's tiling area for `Engine.perform`: display A only.
    static let areas = [displayA: area]

    /// Two displays, each with two user Spaces and one native-fullscreen Space.
    /// Space ids: A1=1, A2=2, AFull=3, B1=4, B2=5, BFull=6.
    static func snapshot(small: Bool = false) -> SpaceSnapshot {
        let a = DisplaySpaces(displayUUID: displayA, spaces: [
            SpaceInfo(id: 1, uuid: "a1", kind: .user),
            SpaceInfo(id: 2, uuid: "a2", kind: .user),
            SpaceInfo(id: 3, uuid: "a3", kind: .fullscreen),
        ], activeSpace: 1, small: small)
        let b = DisplaySpaces(displayUUID: displayB, spaces: [
            SpaceInfo(id: 4, uuid: "b1", kind: .user),
            SpaceInfo(id: 5, uuid: "b2", kind: .user),
            SpaceInfo(id: 6, uuid: "b3", kind: .fullscreen),
        ], activeSpace: 4, small: small)
        return SpaceSnapshot(displays: [a, b])
    }

    /// The layout most tests assume: a fixed grid of one unbounded column
    /// beside a left feature. Pinned explicitly so tests do not follow the
    /// built-in screen-size defaults.
    static func baseConfig() -> Config {
        var config = Config()
        config.layout.arrange = .fixed
        config.layout.columns = 1
        config.layout.rows = 0
        config.layout.feature = .left
        config.layout.featureSize = 0.6
        config.layout.featureCount = 1
        return config
    }

    static func makeEngine(config: Config? = nil) -> Engine {
        var engine = Engine(config: config ?? baseConfig())
        _ = engine.updateSnapshot(snapshot())
        return engine
    }

    // MARK: - Continuous weight-driven feature

    @Test("higher-weight window becomes the feature without any command")
    func weightDrivenFeature() {
        var config = Self.baseConfig()
        config.rules = [AppRule(match: RuleMatch(appID: "com.ghostty.app"), actions: RuleActions(weight: 10))]
        var engine = Self.makeEngine(config: config)

        _ = engine.addWindow(1, pid: 1, facts: WindowFacts(bundleID: "com.tinyspeck.slackmacgap"), space: 1)
        _ = engine.addWindow(2, pid: 2, facts: WindowFacts(bundleID: "com.ghostty.app"), space: 1)

        #expect(engine.arrangement(for: 1) == .fixed)
        let state = engine.spacesForTesting[1]!
        #expect(state.liveOrder.first == 2)
        let layout = engine.layout(space: 1, area: Self.area)
        // Ghostty occupies the feature region: it should be the widest tile.
        let feature = layout.frames[2]!
        let grid = layout.frames[1]!
        #expect(feature.width > grid.width)
    }

    @Test("a new window joins the top of the stack; opening and closing never reorders the rest")
    func newcomerTopsStack() {
        var engine = Self.makeEngine()
        for id: WindowID in 1...3 {
            _ = engine.addWindow(id, pid: Int32(id), facts: WindowFacts(), space: 1)
            _ = engine.focus(id)
        }
        #expect(engine.spacesForTesting[1]!.liveOrder == [1, 3, 2])
        _ = engine.focus(2) // focus history never moves the main
        _ = engine.addWindow(4, pid: 4, facts: WindowFacts(), space: 1)
        #expect(engine.spacesForTesting[1]!.liveOrder == [1, 4, 3, 2])
        _ = engine.removeWindow(3)
        #expect(engine.spacesForTesting[1]!.liveOrder == [1, 4, 2])
        // The main closing hands its slot to the top of the stack.
        _ = engine.removeWindow(1)
        #expect(engine.spacesForTesting[1]!.liveOrder == [4, 2])

        // Two main windows: the newcomer lands right after both.
        _ = engine.perform(.featureCount(1), space: 1, areas: Self.areas)
        _ = engine.addWindow(5, pid: 5, facts: WindowFacts(), space: 1)
        #expect(engine.spacesForTesting[1]!.liveOrder == [4, 2, 5])
    }

    @Test("a newcomer tops the stack after heavier stack windows; on a manual Space, right after the main")
    func newcomerRespectsWeightAndManualMain() {
        var config = Self.baseConfig()
        config.rules = [AppRule(match: RuleMatch(appID: "heavy"), actions: RuleActions(weight: 5))]
        var engine = Self.makeEngine(config: config)
        _ = engine.addWindow(1, pid: 1, facts: WindowFacts(bundleID: "heavy"), space: 1)
        _ = engine.addWindow(2, pid: 2, facts: WindowFacts(bundleID: "heavy"), space: 1)
        _ = engine.addWindow(3, pid: 3, facts: WindowFacts(), space: 1)
        _ = engine.addWindow(4, pid: 4, facts: WindowFacts(), space: 1)
        #expect(engine.spacesForTesting[1]!.liveOrder == [1, 2, 4, 3])

        // Manual: window 3 is main; the newcomer goes right under it.
        let swapped = engine.swap(1, 3, on: 1)
        #expect(swapped)
        let manual = engine.spacesForTesting[1]!.liveOrder
        #expect(manual.first == 3)
        _ = engine.addWindow(5, pid: 5, facts: WindowFacts(), space: 1)
        let order = engine.spacesForTesting[1]!.liveOrder
        #expect(order.first == 3)
        #expect(order[1] == 5)
    }

    // MARK: - Manual override persistence

    @Test("manual main survives a newcomer with higher weight")
    func manualOverridePersistsAgainstNewcomer() {
        var engine = Self.makeEngine()
        _ = engine.addWindow(1, pid: 1, facts: WindowFacts(), space: 1)
        _ = engine.addWindow(2, pid: 2, facts: WindowFacts(), space: 1)
        // Manually promote window 2 to main via swap.
        let swapped1 = engine.swap(1, 2, on: 1)
        #expect(swapped1)
        #expect(engine.spacesForTesting[1]!.liveOrder.first == 2)

        // Newcomer with a much higher weight joins; manual main must stick.
        var config = Self.baseConfig()
        config.rules = [AppRule(match: RuleMatch(appID: "heavy"), actions: RuleActions(weight: 100))]
        _ = engine.applyConfig(config)
        _ = engine.addWindow(3, pid: 3, facts: WindowFacts(bundleID: "heavy"), space: 1)

        #expect(engine.spacesForTesting[1]!.liveOrder.first == 2)
    }

    @Test("manual arrangement survives applyConfig with changed weights/mode")
    func manualSurvivesConfigReload() {
        var engine = Self.makeEngine()
        _ = engine.addWindow(1, pid: 1, facts: WindowFacts(bundleID: "x"), space: 1)
        _ = engine.addWindow(2, pid: 2, facts: WindowFacts(), space: 1)
        let swapped2 = engine.swap(1, 2, on: 1)
        #expect(swapped2)
        #expect(engine.spacesForTesting[1]!.manual)

        var newConfig = Self.baseConfig()
        newConfig.layout.arrange = .dwindle
        newConfig.rules = [AppRule(match: RuleMatch(appID: "x"), actions: RuleActions(weight: 50))]
        _ = engine.applyConfig(newConfig)

        #expect(engine.spacesForTesting[1]!.manual)
        // Weights changed: the ideal order now puts the heavy window 1 first...
        #expect(engine.spacesForTesting[1]!.idealOrder.first == 1)
        // ...but manual arrangement still wins for the live order.
        #expect(engine.spacesForTesting[1]!.liveOrder.first == 2)
    }

    @Test("perform(.reset) restores pure weight order and ideal BSP tree, keeps the arrangement")
    func resetRestoresWeightOrder() {
        var config = Self.baseConfig()
        config.layout.arrange = .dwindle
        config.layout.feature = .off
        config.rules = [AppRule(match: RuleMatch(appID: "heavy"), actions: RuleActions(weight: 100))]
        var engine = Self.makeEngine(config: config)
        _ = engine.addWindow(1, pid: 1, facts: WindowFacts(), space: 1)
        _ = engine.addWindow(2, pid: 2, facts: WindowFacts(bundleID: "heavy"), space: 1)
        let swapped3 = engine.swap(1, 2, on: 1) // manual: window 1 now first despite lower weight
        #expect(swapped3)
        #expect(engine.spacesForTesting[1]!.liveOrder.first == 1)

        _ = engine.focus(1)
        _ = engine.perform(.resize(0.1), space: 1, areas: Self.areas) // pin a manual split ratio
        #expect(engine.spacesForTesting[1]!.tree != BSPNode.ideal(engine.spacesForTesting[1]!.idealOrder, axis: nil))
        let outcome = engine.perform(.reset, space: 1, areas: Self.areas)
        #expect(outcome.dirty.contains(1))

        let state = engine.spacesForTesting[1]!
        #expect(!state.manual)
        #expect(state.liveOrder.first == 2) // heavy weight wins again
        #expect(state.tree == BSPNode.ideal(state.idealOrder, axis: nil))
        #expect(engine.arrangement(for: 1) == .dwindle)
    }

    @Test("perform(.relayout) forgets this Space's learned minimum sizes, keeps the arrangement and other Spaces")
    func relayoutForgetsLearnedMinSizes() {
        var engine = Self.makeEngine()
        for id: WindowID in 1...3 { _ = engine.addWindow(id, pid: Int32(id), facts: WindowFacts(), space: 1) }
        _ = engine.addWindow(4, pid: 4, facts: WindowFacts(), space: 2)
        _ = engine.swap(1, 3, on: 1)
        let clean = engine.layout(space: 1, area: Self.area)

        // A stale refusal: one stack window "needs" nearly the whole height,
        // squeezing its sibling.
        _ = engine.learnMinSize(2, CGSize(width: 100, height: 700))
        _ = engine.learnMinSize(4, CGSize(width: 300, height: 300))
        #expect(engine.layout(space: 1, area: Self.area) != clean)

        let outcome = engine.perform(.relayout, space: 1, areas: Self.areas)
        #expect(outcome.dirty == [1])
        #expect(outcome.action == .relayout(1))
        #expect(engine.layout(space: 1, area: Self.area) == clean)
        #expect(engine.spacesForTesting[1]!.manual)
        #expect(engine.windows[4]?.minSize == CGSize(width: 300, height: 300))
    }
    // MARK: - Config reload does not reset manual/monocle/mode (Rift bug)

    @Test("config reload preserves monocle, manual arrangement and a runtime feature size, but updates config defaults")
    func configReloadPreservesRuntimeState() {
        var engine = Self.makeEngine()
        _ = engine.addWindow(1, pid: 1, facts: WindowFacts(), space: 1)
        _ = engine.addWindow(2, pid: 2, facts: WindowFacts(), space: 1)
        _ = engine.perform(.featureSize(0.1), space: 1, areas: Self.areas)
        _ = engine.perform(.monocle, space: 1, areas: Self.areas)
        let swapped4 = engine.swap(1, 2, on: 1)
        #expect(swapped4)

        var newConfig = Self.baseConfig()
        newConfig.layout.arrange = .adaptive // config default changes
        _ = engine.applyConfig(newConfig)

        #expect(engine.spacesForTesting[1]!.monocle)
        #expect(engine.spacesForTesting[1]!.manual)
        #expect(abs(engine.settings(for: 1).featureSize - 0.7) < 1e-9)
        #expect(engine.arrangement(for: 1) == .adaptive)

        // A Space with no runtime state picks up the new config default too.
        _ = engine.addWindow(3, pid: 3, facts: WindowFacts(), space: 4)
        #expect(engine.arrangement(for: 4) == .adaptive)
    }

    @Test("a changed `split` applies on reload to weight-default Spaces, not manually arranged ones")
    func splitChangeAppliesOnReload() {
        func config(split: Axis?) -> Config {
            var config = Config()
            config.rules = [AppRule(match: RuleMatch(appID: "heavy"), actions: RuleActions(weight: 10))]
            var bsp = LayoutOverrides()
            bsp.arrange = .dwindle
            bsp.feature = .off
            bsp.split = .some(split)
            config.spaces[.position(display: Self.displayA, ordinal: 1)] = bsp
            return config
        }
        /// Frames of the two light windows sitting next to the heavy one.
        func lights(_ engine: Engine) -> (CGRect, CGRect) {
            let frames = engine.layout(space: 1, area: Self.area).frames
            return (frames[2]!, frames[3]!)
        }
        for manual in [false, true] {
            var engine = Self.makeEngine(config: config(split: .horizontal))
            _ = engine.addWindow(1, pid: 1, facts: WindowFacts(bundleID: "heavy"), space: 1)
            _ = engine.addWindow(2, pid: 2, facts: WindowFacts(), space: 1)
            _ = engine.addWindow(3, pid: 3, facts: WindowFacts(), space: 1)
            if manual { _ = engine.swap(2, 3, on: 1) }
            let (a, b) = lights(engine)
            #expect(a.minY == b.minY && a.height == b.height, "pinned horizontal: light windows are columns")

            _ = engine.applyConfig(config(split: nil))
            let (c, d) = lights(engine)
            if manual {
                #expect(c.minY == d.minY, "manual arrangement keeps its columns until reset")
            } else {
                #expect(c.minX == d.minX && c.width == d.width && c.minY != d.minY,
                        "auto: light windows stack in the heavy window's leftover region")
            }
        }
    }

    @Test("balanced BSP Space stays a grid as windows open/close, whatever has focus, until arranged manually")
    func balancedSpaceFollowsGrid() {
        var config = Config()
        var bsp = LayoutOverrides()
        bsp.arrange = .balanced
        bsp.feature = .off
        config.spaces[.position(display: Self.displayA, ordinal: 1)] = bsp
        var engine = Self.makeEngine(config: config)
        func quarters() -> Bool {
            let frames = engine.layout(space: 1, area: Self.area).frames
            let sizes = Set(frames.values.map { "\(Int($0.width))x\(Int($0.height))" })
            return frames.count == 4 && sizes.count == 1
        }
        // Focus always sits on window 1, so dwindle would keep splitting its tile.
        for id in 1...4 as ClosedRange<WindowID> {
            _ = engine.addWindow(id, pid: Int32(id), facts: WindowFacts(), space: 1)
            _ = engine.focus(1)
        }
        #expect(quarters())

        _ = engine.addWindow(5, pid: 5, facts: WindowFacts(), space: 1)
        _ = engine.removeWindow(5)
        #expect(quarters(), "a window coming and going leaves the grid intact")

        _ = engine.perform(.resize(0.1), space: 1, areas: Self.areas)
        #expect(!quarters(), "manual resize sticks")
        _ = engine.addWindow(5, pid: 5, facts: WindowFacts(), space: 1)
        _ = engine.removeWindow(5)
        #expect(!quarters(), "a manual Space does not snap back to the grid")
        _ = engine.perform(.reset, space: 1, areas: Self.areas)
        #expect(quarters())
    }

    // MARK: - Per-(display,space) config

    @Test("arrangement(for:) differs per SpaceID according to Config.spaces")
    func perSpaceConfig() {
        var config = Config()
        var dwindleOverride = LayoutOverrides()
        dwindleOverride.arrange = .dwindle
        config.spaces[.position(display: Self.displayA, ordinal: 1)] = dwindleOverride
        var floatOverride = LayoutOverrides()
        floatOverride.arrange = .float
        config.spaces[.position(display: Self.displayA, ordinal: 2)] = floatOverride

        let engine = Self.makeEngine(config: config)
        #expect(engine.arrangement(for: 1) == .dwindle) // A ordinal 1
        #expect(engine.arrangement(for: 2) == .float) // A ordinal 2
        #expect(engine.arrangement(for: 4) == .fixed) // B ordinal 1: default
    }

    @Test("SpaceID state follows the physical Space when a sibling Space is deleted")
    func spaceIDFollowsPhysicalSpaceOnSiblingDeletion() {
        var config = Config()
        var ordinal2Override = LayoutOverrides()
        ordinal2Override.arrange = .dwindle
        config.spaces[.position(display: Self.displayA, ordinal: 2)] = ordinal2Override
        var engine = Self.makeEngine(config: config)

        // Space 2 is ordinal 2 (bsp by config). Add a window and manually promote.
        _ = engine.addWindow(1, pid: 1, facts: WindowFacts(), space: 2)
        _ = engine.addWindow(2, pid: 2, facts: WindowFacts(), space: 2)
        // A window on the doomed Space 1, to prove its state and window ties are dropped.
        _ = engine.addWindow(3, pid: 3, facts: WindowFacts(), space: 1)
        let swapped5 = engine.swap(1, 2, on: 2)
        #expect(swapped5)
        #expect(engine.arrangement(for: 2) == .dwindle)

        // Delete Space 1 (sibling with lower ordinal): Space 2 becomes ordinal 1.
        let a = DisplaySpaces(displayUUID: Self.displayA, spaces: [
            SpaceInfo(id: 2, uuid: "a2", kind: .user),
            SpaceInfo(id: 3, uuid: "a3", kind: .fullscreen),
        ], activeSpace: 2)
        let b = DisplaySpaces(displayUUID: Self.displayB, spaces: [
            SpaceInfo(id: 4, uuid: "b1", kind: .user),
            SpaceInfo(id: 5, uuid: "b2", kind: .user),
            SpaceInfo(id: 6, uuid: "b3", kind: .fullscreen),
        ], activeSpace: 4)
        let dirty = engine.updateSnapshot(SpaceSnapshot(displays: [a, b]))

        // Space 2 kept its live (manual) state but now resolves config via its
        // new ordinal (1), which has no override -> default arrangement.
        #expect(dirty.contains(2))
        #expect(engine.arrangement(for: 2) == .fixed)
        #expect(engine.spacesForTesting[2]!.manual)
        #expect(engine.spacesForTesting[2]!.liveOrder.first == 2)

        // The deleted Space's (id 1) state is dropped, and its window no longer points at it.
        #expect(engine.spacesForTesting[1] == nil)
        #expect(engine.windowsForTesting[3]?.space == nil)
    }

    @Test("a uuid-addressed override stays with its Space when a sibling is deleted; a positional one does not")
    func uuidOverrideFollowsSpaceAcrossOrdinalShift() {
        var config = Config()
        var bsp = LayoutOverrides()
        bsp.arrange = .dwindle
        config.spaces[.uuid("a2")] = bsp
        config.spaces[.position(display: Self.displayB, ordinal: 2)] = bsp
        var engine = Self.makeEngine(config: config)
        #expect(engine.arrangement(for: 2) == .dwindle) // A ordinal 2, by uuid
        #expect(engine.arrangement(for: 5) == .dwindle) // B ordinal 2, by position

        // Delete A1 and B1: A2 becomes ordinal 1, B2 becomes ordinal 1.
        let a = DisplaySpaces(displayUUID: Self.displayA, spaces: [SpaceInfo(id: 2, uuid: "a2", kind: .user)], activeSpace: 2)
        let b = DisplaySpaces(displayUUID: Self.displayB, spaces: [SpaceInfo(id: 5, uuid: "b2", kind: .user)], activeSpace: 5)
        _ = engine.updateSnapshot(SpaceSnapshot(displays: [a, b]))

        #expect(engine.arrangement(for: 2) == .dwindle) // still matched by uuid
        #expect(engine.arrangement(for: 5) == .fixed) // positional entry now points at nothing
    }

    // MARK: - Focus-history fallback

    @Test("removing the focused window falls back to the most recently focused other window")
    func focusFallbackToMostRecent() {
        var engine = Self.makeEngine()
        _ = engine.addWindow(1, pid: 1, facts: WindowFacts(), space: 1)
        _ = engine.addWindow(2, pid: 2, facts: WindowFacts(), space: 1)
        _ = engine.addWindow(3, pid: 3, facts: WindowFacts(), space: 1)
        _ = engine.focus(1)
        _ = engine.focus(2)
        _ = engine.focus(3)

        let removal = engine.removeWindow(3)
        #expect(removal.focusFallback == 2)
    }

    @Test("fallback skips windows on other spaces and minimized windows")
    func focusFallbackSkipsIneligible() {
        var engine = Self.makeEngine()
        _ = engine.addWindow(1, pid: 1, facts: WindowFacts(), space: 1)
        _ = engine.addWindow(2, pid: 2, facts: WindowFacts(), space: 1)
        _ = engine.addWindow(3, pid: 3, facts: WindowFacts(), space: 4) // other space
        _ = engine.addWindow(4, pid: 4, facts: WindowFacts(), space: 1)
        _ = engine.focus(1)
        _ = engine.focus(4)
        _ = engine.setMinimized(4, true)
        _ = engine.focus(2)

        // Focus history on space 1 (most-recent-first): 2, 4, 1. 4 is minimized, 3 is elsewhere.
        let removal = engine.removeWindow(2)
        #expect(removal.focusFallback == 1)
    }

    @Test("removing an unfocused window yields no fallback")
    func removingUnfocusedYieldsNoFallback() {
        var engine = Self.makeEngine()
        _ = engine.addWindow(1, pid: 1, facts: WindowFacts(), space: 1)
        _ = engine.addWindow(2, pid: 2, facts: WindowFacts(), space: 1)
        _ = engine.focus(1)

        let removal = engine.removeWindow(2)
        #expect(removal.focusFallback == nil)
    }

    @Test(".focusLast toggles between the two most recent windows")
    func focusLastToggles() {
        var engine = Self.makeEngine()
        _ = engine.addWindow(1, pid: 1, facts: WindowFacts(), space: 1)
        _ = engine.addWindow(2, pid: 2, facts: WindowFacts(), space: 1)
        _ = engine.focus(1)
        _ = engine.focus(2)

        let outcome1 = engine.perform(.focusLast, space: 1, areas: Self.areas)
        #expect(outcome1.focus == 1)
        _ = engine.focus(1)

        let outcome2 = engine.perform(.focusLast, space: 1, areas: Self.areas)
        #expect(outcome2.focus == 2)
    }

    @Test(".focusFeature jumps to the feature from the grid, then back to the window it came from")
    func focusFeatureToggles() {
        var engine = Self.makeEngine()
        for id in 1...3 as ClosedRange<WindowID> {
            _ = engine.addWindow(id, pid: Int32(id), facts: WindowFacts(), space: 1)
        }
        let order = engine.spacesForTesting[1]!.liveOrder
        let feature = order[0], older = order[1], previous = order[2]
        _ = engine.focus(older)
        _ = engine.focus(previous)

        #expect(engine.perform(.focusFeature, space: 1, areas: Self.areas).focus == feature)
        _ = engine.focus(feature)

        // Back to the grid window that had focus, not merely any other tile.
        #expect(engine.perform(.focusFeature, space: 1, areas: Self.areas).focus == previous)
    }

    @Test("hadFocus: fallback is computed even when focus already moved elsewhere, preferring the entry older than the closed window")
    func hadFocusFallbackPrefersOlderEntry() {
        var engine = Self.makeEngine()
        _ = engine.addWindow(1, pid: 1, facts: WindowFacts(), space: 1)
        _ = engine.addWindow(2, pid: 2, facts: WindowFacts(), space: 1)
        _ = engine.addWindow(3, pid: 3, facts: WindowFacts(), space: 1)
        _ = engine.focus(1)
        _ = engine.focus(2)
        _ = engine.focus(3)
        // AppKit already moved focus to A before the close of C was observed.
        _ = engine.focus(1)

        let removal = engine.removeWindow(3, hadFocus: true)
        #expect(removal.focusFallback == 2)
    }

    @Test("hadFocus: fallback still prefers the window that actually preceded the closed one, even when the interim refocus lands on it")
    func hadFocusFallbackPrefersRecordedPredecessorOverInterimRetouch() {
        var engine = Self.makeEngine()
        _ = engine.addWindow(1, pid: 1, facts: WindowFacts(), space: 1) // A
        _ = engine.addWindow(2, pid: 2, facts: WindowFacts(), space: 1) // B
        _ = engine.addWindow(3, pid: 3, facts: WindowFacts(), space: 1) // C
        _ = engine.focus(1) // A
        _ = engine.focus(2) // B
        _ = engine.focus(3) // C — history is now C, B, A
        // AppKit already moved focus back to B (C's immediate predecessor)
        // before the close of C was observed.
        _ = engine.focus(2) // B

        let removal = engine.removeWindow(3, hadFocus: true)
        #expect(removal.focusFallback == 2)
    }

    // MARK: - Fullscreen / manage / floating

    @Test("windows on the fullscreen space are never tiled")
    func fullscreenWindowsNeverTiled() {
        var engine = Self.makeEngine()
        _ = engine.addWindow(1, pid: 1, facts: WindowFacts(), space: 3) // fullscreen space on display A
        #expect(!engine.isTiled(1))
        #expect(engine.spacesForTesting[3] == nil || engine.spacesForTesting[3]!.members.isEmpty)
    }

    @Test("manage = false windows are never tiled nor focus-tracked")
    func unmanagedWindowsNeverTiledOrTracked() {
        var config = Config()
        config.rules = [AppRule(match: RuleMatch(appID: "unmanaged"), actions: RuleActions(manage: false))]
        var engine = Self.makeEngine(config: config)
        _ = engine.addWindow(1, pid: 1, facts: WindowFacts(bundleID: "unmanaged"), space: 1)
        #expect(!engine.isTiled(1))
        _ = engine.focus(1)
        #expect(engine.spacesForTesting[1] == nil || !engine.spacesForTesting[1]!.focus.entries.contains(1))
    }

    @Test("non-standard subrole floats by default unless a rule says float = false")
    func nonStandardSubroleFloatsByDefault() {
        var engine = Self.makeEngine()
        _ = engine.addWindow(1, pid: 1, facts: WindowFacts(role: "AXWindow", subrole: "AXDialog"), space: 1)
        #expect(!engine.isTiled(1))

        var config = Config()
        config.rules = [AppRule(match: RuleMatch(axSubrole: "AXDialog"), actions: RuleActions(float: false))]
        engine = Self.makeEngine(config: config)
        _ = engine.addWindow(1, pid: 1, facts: WindowFacts(role: "AXWindow", subrole: "AXDialog"), space: 1)
        #expect(engine.isTiled(1))
    }

    @Test("dialog-like windows float by default; document windows and unknown facts tile", arguments: [
        (WindowFacts(role: "AXWindow", subrole: "AXStandardWindow", modal: false, resizable: true, fullScreen: true), true),
        (WindowFacts(), true),
        (WindowFacts(role: "AXWindow", subrole: "AXStandardWindow", modal: true), false),
        (WindowFacts(role: "AXWindow", subrole: "AXStandardWindow", resizable: false), false),
        (WindowFacts(role: "AXWindow", subrole: "AXStandardWindow", fullScreen: false), false),
        // Open/Save panels shown with `begin`, as read on macOS 26: standard,
        // non-modal, resizable, and no close button, so full screen is unknown.
        (WindowFacts(role: "AXWindow", subrole: "AXStandardWindow", identifier: "open-panel", modal: false, resizable: true), false),
        (WindowFacts(role: "AXWindow", subrole: "AXStandardWindow", identifier: "save-panel", modal: false, resizable: true), false),
    ])
    func dialogHeuristics(facts: WindowFacts, tiles: Bool) {
        var engine = Self.makeEngine()
        _ = engine.addWindow(1, pid: 1, facts: facts, space: 1)
        #expect(engine.isTiled(1) == tiles)
    }

    @Test("a float = false rule tiles a window the heuristics would float")
    func floatFalseRuleOverridesHeuristics() {
        var config = Config()
        config.rules = [AppRule(match: RuleMatch(appID: "com.example.fixed"), actions: RuleActions(float: false))]
        var engine = Self.makeEngine(config: config)
        _ = engine.addWindow(1, pid: 1, facts: WindowFacts(bundleID: "com.example.fixed", resizable: false, fullScreen: false), space: 1)
        #expect(engine.isTiled(1))
    }

    @Test("a window whose facts change (e.g. re-read on unhide) re-tiles or floats")
    func factsChangeRetiles() {
        var engine = Self.makeEngine()
        _ = engine.addWindow(1, pid: 1, facts: WindowFacts(subrole: "AXDialog"), space: 1)
        #expect(!engine.isTiled(1))
        let dirty = engine.updateFacts(1, WindowFacts(subrole: "AXStandardWindow", resizable: true, fullScreen: true))
        #expect(dirty == [1])
        #expect(engine.isTiled(1))
    }

    @Test(".toggleFloat command flips tiling")
    func toggleFloatCommand() {
        var engine = Self.makeEngine()
        _ = engine.addWindow(1, pid: 1, facts: WindowFacts(), space: 1)
        _ = engine.focus(1)
        #expect(engine.isTiled(1))

        _ = engine.perform(.toggleFloat, space: 1, areas: Self.areas)
        #expect(!engine.isTiled(1))

        _ = engine.perform(.toggleFloat, space: 1, areas: Self.areas)
        #expect(engine.isTiled(1))
    }

    // MARK: - Monocle

    @Test("monocle lays every tiled window out as one full-area deck: most recent in view and raised, the rest tucked behind it")
    func monocleIsOneFullAreaDeck() {
        var config = Self.baseConfig()
        config.layout.gapsInner = 0
        config.layout.gapsOuter = 0
        var engine = Self.makeEngine(config: config)
        _ = engine.addWindow(1, pid: 1, facts: WindowFacts(), space: 1)
        _ = engine.addWindow(2, pid: 2, facts: WindowFacts(), space: 1)
        _ = engine.focus(2)

        let before = engine.layout(space: 1, area: Self.area).frames
        #expect(before[1] != before[2])
        #expect(!engine.isMonocle(1))

        _ = engine.perform(.monocle, space: 1, areas: Self.areas)
        #expect(engine.isMonocle(1))
        #expect(engine.arrangement(for: 1) == .fixed, "monocle keeps the arrangement")
        let monocle = engine.layout(space: 1, area: Self.area)
        #expect(monocle.frames.count == 2)
        #expect(monocle.raise == 2)
        #expect(Set(monocle.covered.keys) == [1])
        let view = monocle.frames[2]!
        #expect(view.minX == Self.area.minX && view.width == Self.area.width, "the window in view spans the whole width")
        #expect(view.union(monocle.covered[1]!) == Self.area, "the view and the peeking strip fill the area")

        _ = engine.perform(.monocle, space: 1, areas: Self.areas)
        #expect(!engine.isMonocle(1))
        #expect(engine.layout(space: 1, area: Self.area).frames == before)
    }

    @Test("monocle never raises a tiled member over a focused floating window")
    func monocleDoesNotRaiseOverFocusedFloat() {
        var engine = Self.makeEngine()
        _ = engine.addWindow(1, pid: 1, facts: WindowFacts(), space: 1)
        _ = engine.addWindow(2, pid: 2, facts: WindowFacts(), space: 1)
        _ = engine.addWindow(3, pid: 3, facts: WindowFacts(), space: 1)
        _ = engine.focus(1)
        _ = engine.focus(2)
        _ = engine.perform(.monocle, space: 1, areas: Self.areas)
        #expect(engine.layout(space: 1, area: Self.area).raise == 2)

        // Window 3 floats above the tiled Space and takes focus.
        _ = engine.focus(3)
        _ = engine.perform(.toggleFloat, space: 1, areas: Self.areas)
        #expect(engine.windowsForTesting[3]?.isFloating == true)

        #expect(engine.layout(space: 1, area: Self.area).raise == nil)

        // Any other layout-affecting change (e.g. a resize elsewhere) must
        // not resurrect a raised member while the float holds focus.
        _ = engine.setMinimized(1, true)
        _ = engine.setMinimized(1, false)
        #expect(engine.layout(space: 1, area: Self.area).raise == nil)
    }

    @Test("adoptFrame is refused while the Space is in monocle")
    func adoptFrameRefusedInMonocle() {
        var engine = Self.makeEngine()
        _ = engine.addWindow(1, pid: 1, facts: WindowFacts(), space: 1)
        _ = engine.addWindow(2, pid: 2, facts: WindowFacts(), space: 1)
        _ = engine.perform(.monocle, space: 1, areas: Self.areas)

        let dirty = engine.adoptFrame(1, CGRect(x: 10, y: 10, width: 20, height: 20))
        #expect(dirty.isEmpty)
        #expect(engine.spacesForTesting[1]?.frameOverrides[1] == nil)
    }

    @Test("monocle never raises a tiled member over a focused unmanaged window on the same Space")
    func monocleDoesNotRaiseOverFocusedUnmanaged() {
        var config = Self.baseConfig()
        config.rules = [AppRule(match: RuleMatch(appID: "unmanaged"), actions: RuleActions(manage: false))]
        var engine = Self.makeEngine(config: config)
        _ = engine.addWindow(1, pid: 1, facts: WindowFacts(), space: 1)
        _ = engine.addWindow(2, pid: 2, facts: WindowFacts(), space: 1)
        _ = engine.addWindow(3, pid: 3, facts: WindowFacts(bundleID: "unmanaged"), space: 1)
        _ = engine.focus(1)
        _ = engine.focus(2)
        _ = engine.perform(.monocle, space: 1, areas: Self.areas)
        #expect(engine.layout(space: 1, area: Self.area).raise == 2)

        // An unmanaged window on the same Space takes keyboard focus.
        _ = engine.focus(3)
        #expect(engine.layout(space: 1, area: Self.area).raise == nil)
    }

    // MARK: - Defaults by screen size

    @Test("small screens default to one full-screen deck, large ones to a fixed 1×2 grid beside a left feature; set keys win per key")
    func screenSizeDefaults() {
        let laptop = DisplaySpaces(displayUUID: Self.displayA, spaces: [
            SpaceInfo(id: 1, uuid: "a1", kind: .user),
            SpaceInfo(id: 2, uuid: "a2", kind: .user),
        ], activeSpace: 1, builtin: true, small: true)
        let external = DisplaySpaces(displayUUID: Self.displayB, spaces: [SpaceInfo(id: 4, uuid: "b1", kind: .user)], activeSpace: 4)
        func engine(_ config: Config) -> Engine {
            var engine = Engine(config: config)
            _ = engine.updateSnapshot(SpaceSnapshot(displays: [laptop, external]))
            return engine
        }

        var config = Config()
        let automatic = engine(config)
        let small = automatic.settings(for: 1)
        #expect(small.arrange == .fixed && small.columns == 1 && small.rows == 1)
        #expect(!small.hasFeature)
        #expect(automatic.glyph(for: 1) == "1×1")
        let large = automatic.settings(for: 4)
        #expect(large.arrange == .fixed && large.columns == 1 && large.rows == 2)
        #expect(large.feature == .left && large.featureSize == 0.6 && large.featureCount == 1)
        #expect(automatic.glyph(for: 4) == "F·1×2")

        // A key set in [layout] applies to every screen; the others keep their screen default.
        config.layout.feature = .right
        let shared = engine(config)
        #expect(shared.settings(for: 1).feature == .right && shared.settings(for: 1).rows == 1)
        #expect(shared.settings(for: 4).feature == .right && shared.settings(for: 4).rows == 2)

        // A desktop's own keys beat [layout].
        var desktop = LayoutOverrides()
        desktop.feature = FeatureSide.off
        desktop.columns = 2
        config.spaces[.position(display: Self.displayA, ordinal: 2)] = desktop
        let overridden = engine(config).settings(for: 2)
        #expect(!overridden.hasFeature && overridden.columns == 2 && overridden.rows == 1)
    }

    // MARK: - Scrolling decks

    /// `count` windows on Space 1 with no gaps: feature 1, grid 2...count.
    static func gridEngine(arrange: Arrangement = .fixed, rows: Int = 1, columns: Int = 1, feature: FeatureSide = .left,
                           count: Int) -> Engine {
        var config = Config()
        config.layout.arrange = arrange
        config.layout.rows = rows
        config.layout.columns = columns
        config.layout.feature = feature
        config.layout.featureSize = 0.6
        config.layout.featureCount = 1
        config.layout.gapsInner = 0
        config.layout.gapsOuter = 0
        var engine = Self.makeEngine(config: config)
        // Each newcomer tops the grid, so the grid joins bottom-up.
        for id in [1] + (1...count).dropFirst().reversed() {
            _ = engine.addWindow(WindowID(id), pid: Int32(id), facts: WindowFacts(), space: 1)
        }
        return engine
    }

    @Test("a 1-row column shows the focused grid window; the others tuck behind it, peeking at its ends")
    func singleRowDeckShowsOneWindow() {
        var engine = Self.gridEngine(count: 4)
        _ = engine.focus(3)
        let layout = engine.layout(space: 1, area: Self.area)
        let view = layout.frames[3]!
        #expect(Set(layout.covered.keys) == [2, 4])
        #expect(layout.raise == 3)
        #expect(layout.covered[2]!.height == 30 && layout.covered[2]!.maxY == view.minY)
        #expect(layout.covered[4]!.height == 30 && layout.covered[4]!.minY == view.maxY)

        // A focused floating window on the Space stays on top.
        _ = engine.addWindow(9, pid: 9, facts: WindowFacts(modal: true), space: 1)
        _ = engine.focus(9)
        let behindFloat = engine.layout(space: 1, area: Self.area)
        #expect(behindFloat.raise == nil)
        #expect(behindFloat.covered[3] == nil)
    }

    @Test("focus only dirties a Space whose deck scrolls")
    func focusDirtiesScrollingDecks() {
        var uncapped = Self.gridEngine(rows: 0, count: 4)
        #expect(uncapped.focus(3).isEmpty)
        var capped = Self.gridEngine(rows: 2, count: 4)
        #expect(capped.focus(3) == [1])
        var single = Self.gridEngine(count: 2)
        #expect(single.focus(2).isEmpty)
        var deck = Self.gridEngine(count: 3)
        #expect(deck.focus(2) == [1])
    }

    @Test("directional focus walks the deck past the view and in and out of the feature")
    func focusWalksTheStrip() {
        var engine = Self.gridEngine(count: 4)
        _ = engine.focus(2)
        #expect(engine.perform(.focus(.down), space: 1, areas: Self.areas).focus == 3)
        _ = engine.focus(3)
        #expect(engine.layout(space: 1, area: Self.area).covered[3] == nil)
        #expect(engine.perform(.focus(.down), space: 1, areas: Self.areas).focus == 4)
        #expect(engine.perform(.focus(.up), space: 1, areas: Self.areas).focus == 2)
        #expect(engine.perform(.focus(.left), space: 1, areas: Self.areas).focus == 1)
        // Back from the feature lands on the window in view, not a tucked one.
        _ = engine.focus(1)
        #expect(engine.perform(.focus(.right), space: 1, areas: Self.areas).focus == 3)
    }

    @Test("directional focus crosses between side-by-side displays at the edge")
    func directionalFocusCrossesDisplays() {
        var config = Config()
        config.layout.arrange = .dwindle
        config.layout.feature = FeatureSide.off
        config.layout.gapsInner = 0
        config.layout.gapsOuter = 0
        var engine = Self.makeEngine(config: config)
        for id: WindowID in [1, 2] {
            _ = engine.addWindow(id, pid: Int32(id), facts: WindowFacts(), space: 1)
        }
        for id: WindowID in [4, 5] {
            _ = engine.addWindow(id, pid: Int32(id), facts: WindowFacts(), space: 4)
        }
        let areas = [
            Self.displayA: CGRect(x: 0, y: 0, width: 1000, height: 800),
            Self.displayB: CGRect(x: 1000, y: 0, width: 1000, height: 800),
        ]

        _ = engine.focus(1)
        #expect(engine.perform(.focus(.right), space: 1, areas: areas).focus == 2,
                "a local tile wins before focus crosses the display edge")
        _ = engine.focus(2)
        #expect(engine.perform(.focus(.right), space: 1, areas: areas).focus == 4,
                "focus enters the next display through its facing edge")
        _ = engine.focus(4)
        #expect(engine.perform(.focus(.left), space: 4, areas: areas).focus == 2)
        _ = engine.focus(1)
        #expect(engine.perform(.focus(.left), space: 1, areas: areas).focus == nil,
                "focus stops when no display lies in that direction")
    }

    @Test("swap moves the focused window along the deck and the view follows it")
    func swapMovesAlongTheDeck() {
        var engine = Self.gridEngine(count: 4)
        _ = engine.focus(2)
        #expect(engine.perform(.swap(.down), space: 1, areas: Self.areas).dirty == [1])
        #expect(engine.spacesForTesting[1]!.liveOrder == [1, 3, 2, 4])
        let layout = engine.layout(space: 1, area: Self.area)
        #expect(layout.covered[2] == nil)
        #expect(layout.raise == 2)
    }

    @Test("a column shows `rows` grid windows, then scrolls")
    func columnScrollsPastRows() {
        var engine = Self.gridEngine(rows: 2, count: 5)
        _ = engine.focus(4)
        let layout = engine.layout(space: 1, area: Self.area)
        #expect(Set(layout.covered.keys) == [2, 5])
        #expect(layout.frames[3]!.height == layout.frames[4]!.height)
        #expect(layout.frames[3]!.maxY <= layout.frames[4]!.minY)
    }

    @Test("columns: overflow scrolls in the outermost column only, and focusing it scrolls")
    func columnsScrollOutermost() {
        var engine = Self.gridEngine(rows: 1, columns: 2, count: 4)
        #expect(engine.focus(4).contains(1))
        let layout = engine.layout(space: 1, area: Self.area)
        #expect(Set(layout.covered.keys) == [3])
        #expect(layout.frames[2]!.height == Self.area.height)
        #expect(layout.frames[2]!.maxX <= layout.frames[4]!.minX)
    }

    @Test("a center feature with rows 1 scrolls each side's deck on its own")
    func centeredFeatureScrollsEachSide() {
        var both = Self.gridEngine(rows: 1, feature: .center, count: 5)
        _ = both.focus(2)
        _ = both.focus(5)
        let layout = both.layout(space: 1, area: Self.area)
        #expect(Set(layout.covered.keys) == [3, 4])
        #expect(layout.frames[5]!.maxX <= layout.frames[1]!.minX)
        #expect(layout.frames[1]!.maxX <= layout.frames[2]!.minX)
    }

    @Test("adaptive without a feature: resize, balance and focus-feature say so and change nothing; every window still tiles")
    func adaptiveWithoutFeature() {
        var engine = Self.gridEngine(arrange: .adaptive, feature: .off, count: 4)
        _ = engine.focus(4)
        for command in [Command.resize(0.1), .balance, .focusFeature] {
            let out = engine.perform(command, space: 1, areas: Self.areas)
            #expect(out.message != nil && out.dirty.isEmpty && out.settings == nil && out.focus == nil)
        }
        #expect(engine.layout(space: 1, area: Self.area).frames.count == 4)
    }

    @Test("a tile in view is raised only while a window belonging behind it is in front of it")
    func tilesToRaiseRestoreTheDeck() {
        var engine = Self.gridEngine(rows: 2, count: 5)
        _ = engine.focus(4)
        let layout = engine.layout(space: 1, area: Self.area)
        // View [3, 4]: window 2 peeks above tile 3; tile 4 is `raise` anyway.
        #expect(layout.raise == 4)
        #expect(layout.behind == [3: [2]])
        #expect(layout.tilesToRaise(frontToBack: [4, 2, 3, 5, 1]) == [3])
        #expect(layout.tilesToRaise(frontToBack: [4, 3, 2, 5, 1]).isEmpty)

        // Nothing is raised over a focused floating window.
        _ = engine.addWindow(9, pid: 9, facts: WindowFacts(modal: true), space: 1)
        _ = engine.focus(9)
        #expect(engine.layout(space: 1, area: Self.area).behind.isEmpty)
    }

    @Test("never raises a window of the focused window's app but the focused one: raising hands it that app's focus")
    func neverRaisesTheFocusedAppsOtherWindows() {
        var config = Self.baseConfig()
        config.layout.rows = 2
        var engine = Self.makeEngine(config: config)
        // Windows 3 and 4 belong to one app.
        for id: WindowID in 1...5 { _ = engine.addWindow(id, pid: id == 3 ? 4 : Int32(id), facts: WindowFacts(), space: 1) }
        _ = engine.focus(4)
        let layout = engine.layout(space: 1, area: Self.area)
        #expect(layout.raise == 4)
        #expect(layout.behind.isEmpty)

        // Focus moves to a window of that app on another Space: tile 4 stays put.
        _ = engine.addWindow(9, pid: 4, facts: WindowFacts(), space: 4)
        _ = engine.focus(9)
        #expect(engine.layout(space: 1, area: Self.area).raise == nil)
    }

    @Test("a window that opens tops a scrolling deck in view before focus reaches it; only a deck window taking focus scrolls it away")
    func newcomerShowsBeforeFocus() {
        // Window 3 has focus when its app opens window 5; focus hasn't followed yet.
        var engine = Self.gridEngine(count: 4)
        _ = engine.focus(3)
        _ = engine.addWindow(5, pid: 3, facts: WindowFacts(), space: 1)
        #expect(engine.spacesForTesting[1]!.liveOrder == [1, 5, 2, 3, 4])
        var layout = engine.layout(space: 1, area: Self.area)
        #expect(layout.covered[5] == nil && layout.covered[3] != nil)
        // Raising window 3 would hand it its app's focus back, over the new window.
        #expect(layout.raise == nil && layout.behind.isEmpty)

        // The feature taking focus leaves the deck where it is; a grid window taking it scrolls.
        _ = engine.focus(1)
        #expect(engine.layout(space: 1, area: Self.area).covered[5] == nil)
        _ = engine.focus(3)
        layout = engine.layout(space: 1, area: Self.area)
        #expect(layout.covered[3] == nil && layout.covered[5] != nil)

        // Past `rows`: the view scrolls up to the new window.
        var grid = Self.gridEngine(rows: 2, count: 5)
        _ = grid.focus(5)
        _ = grid.addWindow(6, pid: 5, facts: WindowFacts(), space: 1)
        #expect(Set(grid.layout(space: 1, area: Self.area).covered.keys) == [3, 4, 5])
    }

    @Test("a window of another app never scrolls the focused tile out of view; with focus elsewhere it shows, raised")
    func newcomerOfAnotherApp() {
        var engine = Self.gridEngine(count: 4)
        _ = engine.focus(3)
        // Nothing can be raised over the active app's window: window 7 waits behind window 3.
        _ = engine.addWindow(7, pid: 7, facts: WindowFacts(), space: 1)
        var layout = engine.layout(space: 1, area: Self.area)
        #expect(layout.covered[3] == nil && layout.covered[7] != nil)
        #expect(layout.raise == 3)

        // Focus is on the other display: window 8 shows, raised over the windows tucked behind it.
        _ = engine.addWindow(9, pid: 9, facts: WindowFacts(), space: 4)
        _ = engine.focus(9)
        _ = engine.addWindow(8, pid: 8, facts: WindowFacts(), space: 1)
        layout = engine.layout(space: 1, area: Self.area)
        #expect(layout.covered[8] == nil)
        #expect(layout.raise == 8)
    }

    @Test("monocle fronts a window that opens, never raising the window focus hasn't left yet over it")
    func monocleFrontsNewcomer() {
        var engine = Self.makeEngine()
        _ = engine.addWindow(1, pid: 1, facts: WindowFacts(), space: 1)
        _ = engine.addWindow(2, pid: 2, facts: WindowFacts(), space: 1)
        _ = engine.focus(2)
        _ = engine.perform(.monocle, space: 1, areas: Self.areas)
        _ = engine.addWindow(3, pid: 2, facts: WindowFacts(), space: 1)
        #expect(engine.layout(space: 1, area: Self.area).raise == nil)
        _ = engine.focus(3)
        #expect(engine.layout(space: 1, area: Self.area).raise == 3)
    }

    // MARK: - Stage Manager passthrough

    @Test("passthrough forces the float arrangement with no frames")
    func passthroughForcesFloat() {
        var engine = Self.makeEngine()
        _ = engine.addWindow(1, pid: 1, facts: WindowFacts(), space: 1)
        engine.passthrough = true
        #expect(engine.arrangement(for: 1) == .float)
        let layout = engine.layout(space: 1, area: Self.area)
        #expect(layout.frames.isEmpty)
    }

    // MARK: - Feature size clamp

    @Test("growing an already-high but valid feature size never shrinks it")
    func featureSizeGrowNeverShrinksValidHighSize() {
        var config = Self.baseConfig()
        config.layout.featureSize = 0.93
        var engine = Self.makeEngine(config: config)
        _ = engine.addWindow(1, pid: 1, facts: WindowFacts(), space: 1)

        _ = engine.perform(.featureSize(0.05), space: 1, areas: Self.areas)
        #expect(engine.settings(for: 1).featureSize >= 0.93)
    }

    @Test("growing a size already within an epsilon of 0.95 never reverses direction")
    func featureSizeGrowNearUpperBoundNeverReverses() {
        var config = Self.baseConfig()
        config.layout.featureSize = 0.95.nextDown.nextDown.nextDown
        var engine = Self.makeEngine(config: config)
        _ = engine.addWindow(1, pid: 1, facts: WindowFacts(), space: 1)

        let before = engine.settings(for: 1).featureSize
        _ = engine.perform(.featureSize(0.1), space: 1, areas: Self.areas)
        let after = engine.settings(for: 1).featureSize
        #expect(after >= before)
        #expect(after < 0.95)
    }

    @Test("shrinking a size already within an epsilon of 0.05 never reverses direction")
    func featureSizeShrinkNearLowerBoundNeverReverses() {
        var config = Self.baseConfig()
        config.layout.featureSize = 0.05.nextUp.nextUp.nextUp
        var engine = Self.makeEngine(config: config)
        _ = engine.addWindow(1, pid: 1, facts: WindowFacts(), space: 1)

        let before = engine.settings(for: 1).featureSize
        _ = engine.perform(.featureSize(-0.1), space: 1, areas: Self.areas)
        let after = engine.settings(for: 1).featureSize
        #expect(after <= before)
        #expect(after > 0.05)
    }

    @Test("zero-delta feature-size adjustment leaves the size unchanged")
    func featureSizeZeroDeltaLeavesSizeUnchanged() {
        var config = Self.baseConfig()
        config.layout.featureSize = 0.6
        var engine = Self.makeEngine(config: config)
        _ = engine.addWindow(1, pid: 1, facts: WindowFacts(), space: 1)

        _ = engine.perform(.featureSize(0), space: 1, areas: Self.areas)
        #expect(engine.spacesForTesting[1]?.featureSizeOverride == 0.6)
    }

    @Test("shrinking an already-low but valid feature size never grows it")
    func featureSizeShrinkNeverGrowsValidLowSize() {
        var config = Self.baseConfig()
        config.layout.featureSize = 0.07
        var engine = Self.makeEngine(config: config)
        _ = engine.addWindow(1, pid: 1, facts: WindowFacts(), space: 1)

        _ = engine.perform(.featureSize(-0.05), space: 1, areas: Self.areas)
        #expect(engine.settings(for: 1).featureSize <= 0.07)
    }

    @Test("extreme feature-size grow/shrink survives ConfigEditor persistence and Config.validated")
    func featureSizeExtremeCommandsRoundTripThroughConfigEditor() {
        for delta in [1.0, -1.0] {
            var engine = Self.makeEngine()
            _ = engine.addWindow(1, pid: 1, facts: WindowFacts(), space: 1)

            let outcome = engine.perform(.featureSize(delta), space: 1, areas: Self.areas)
            let applied = outcome.settings?.featureSize
            #expect(applied != nil)
            guard let size = applied else { continue }

            var editor = ConfigEditor(text: "[layout]\nfeature_size = 0.6\n")
            let setResult = editor.set("feature_size", .float(size), in: .layout)
            guard case .success = setResult else {
                Issue.record("expected ConfigEditor.set to succeed for size \(size)")
                continue
            }
            switch editor.validated() {
            case .success(let config): #expect(config.layout.featureSize == size)
            case .failure(let e): Issue.record("expected \(size) to validate, got \(e)")
            }
        }
    }

    @Test("repeated boundary feature-size commands are stable")
    func featureSizeRepeatedBoundaryCommandsStable() {
        var engine = Self.makeEngine()
        _ = engine.addWindow(1, pid: 1, facts: WindowFacts(), space: 1)

        _ = engine.perform(.featureSize(-1.0), space: 1, areas: Self.areas)
        let first = engine.spacesForTesting[1]?.featureSizeOverride
        _ = engine.perform(.featureSize(-1.0), space: 1, areas: Self.areas)
        let second = engine.spacesForTesting[1]?.featureSizeOverride
        #expect(first == second)
    }

    // MARK: - Hidden windows

    @Test("hidden windows are excluded from tiling and focus eligibility without disturbing minimized state")
    func hiddenWindowsExcludedFromTilingAndFocus() {
        var engine = Self.makeEngine()
        _ = engine.addWindow(1, pid: 1, facts: WindowFacts(), space: 1)
        _ = engine.addWindow(2, pid: 2, facts: WindowFacts(), space: 1)
        _ = engine.focus(1)
        _ = engine.focus(2)
        #expect(engine.isTiled(2))

        let dirty = engine.setHidden(1, true)
        #expect(dirty.contains(1))
        #expect(!engine.isTiled(1))
        #expect(engine.spacesForTesting[1]?.members.contains(1) == false)
        #expect(engine.windowsForTesting[1]?.minimized == false)

        // Removing the focused window must not fall back to the hidden one.
        let removal = engine.removeWindow(2)
        #expect(removal.focusFallback == nil)

        // Unhiding restores tiling and does not touch minimized state.
        _ = engine.setMinimized(1, true)
        _ = engine.setHidden(1, false)
        #expect(engine.windowsForTesting[1]?.minimized == true)
        #expect(!engine.isTiled(1)) // still minimized
        _ = engine.setMinimized(1, false)
        #expect(engine.isTiled(1))
    }

    // MARK: - Feature count clamp

    @Test(".featureCount(Int.max) does not trap and clamps to 16")
    func featureCountClampsUnboundedDelta() {
        var engine = Self.makeEngine()
        _ = engine.addWindow(1, pid: 1, facts: WindowFacts(), space: 1)

        _ = engine.perform(.featureCount(Int.max), space: 1, areas: Self.areas)
        #expect(engine.spacesForTesting[1]?.featureCountOverride == 16)

        _ = engine.perform(.featureCount(Int.min), space: 1, areas: Self.areas)
        #expect(engine.spacesForTesting[1]?.featureCountOverride == 1)
    }

    // MARK: - SettingsChange (config write-back)

    @Test(".featureSize and feature-area resize/balance emit a featureSize SettingsChange")
    func featureSizeCommandsEmitSettingsChange() {
        var engine = Self.makeEngine()
        _ = engine.addWindow(1, pid: 1, facts: WindowFacts(), space: 1)
        _ = engine.focus(1)

        let sizeOutcome = engine.perform(.featureSize(0.1), space: 1, areas: Self.areas)
        #expect(sizeOutcome.settings?.space == 1)
        #expect(sizeOutcome.settings?.featureSize == engine.spacesForTesting[1]?.featureSizeOverride)
        #expect(sizeOutcome.settings?.featureCount == nil)

        let resizeOutcome = engine.perform(.resize(0.05), space: 1, areas: Self.areas)
        #expect(resizeOutcome.settings?.space == 1)
        #expect(resizeOutcome.settings?.featureSize == engine.spacesForTesting[1]?.featureSizeOverride)

        let balanceOutcome = engine.perform(.balance, space: 1, areas: Self.areas)
        #expect(balanceOutcome.settings == SettingsChange(space: 1, featureSize: 0.5))
    }

    @Test("growing from a grid window shrinks the feature; from the feature it grows it")
    func resizeSignFollowsTheFocusedRegion() {
        var engine = Self.gridEngine(rows: 0, count: 3)
        let start = engine.settings(for: 1).featureSize

        _ = engine.focus(1)
        let grown = engine.perform(.resize(0.1), space: 1, areas: Self.areas)
        #expect(grown.settings?.featureSize.map { $0 > start } == true)

        _ = engine.focus(2)
        let shrunk = engine.perform(.resize(0.1), space: 1, areas: Self.areas)
        #expect(shrunk.settings?.featureSize.map { $0 < grown.settings!.featureSize! } == true)
    }

    @Test(".featureCount emits a featureCount SettingsChange")
    func featureCountCommandEmitsSettingsChange() {
        var engine = Self.makeEngine()
        _ = engine.addWindow(1, pid: 1, facts: WindowFacts(), space: 1)

        let outcome = engine.perform(.featureCount(1), space: 1, areas: Self.areas)
        #expect(outcome.settings?.space == 1)
        #expect(outcome.settings?.featureCount == engine.spacesForTesting[1]?.featureCountOverride)
        #expect(outcome.settings?.featureSize == nil)
    }

    @Test("BSP resize/balance/swap/monocle/reset of non-featured tiles never emit a SettingsChange")
    func bspCommandsNeverEmitSettingsChange() {
        var config = Self.baseConfig()
        config.layout.arrange = .dwindle
        config.layout.feature = .off
        var engine = Self.makeEngine(config: config)
        _ = engine.addWindow(1, pid: 1, facts: WindowFacts(), space: 1)
        _ = engine.addWindow(2, pid: 2, facts: WindowFacts(), space: 1)
        _ = engine.focus(1)

        #expect(engine.perform(.resize(0.1), space: 1, areas: Self.areas).settings == nil)
        #expect(engine.perform(.balance, space: 1, areas: Self.areas).settings == nil)
        #expect(engine.perform(.swap(.right), space: 1, areas: Self.areas).settings == nil)
        #expect(engine.perform(.monocle, space: 1, areas: Self.areas).settings == nil)
        #expect(engine.perform(.reset, space: 1, areas: Self.areas).settings == nil)
    }

    @Test("dwindle with a feature: resizing the featured tile sets the feature size, resizing another tile pins a split")
    func dwindleResizeSplitsBetweenFeatureAndTree() {
        var config = Self.baseConfig()
        config.layout.arrange = .dwindle
        var engine = Self.makeEngine(config: config)
        for id: WindowID in 1...3 { _ = engine.addWindow(id, pid: Int32(id), facts: WindowFacts(), space: 1) }
        let feature = engine.spacesForTesting[1]!.liveOrder[0]
        let other = engine.spacesForTesting[1]!.liveOrder[1]

        _ = engine.focus(feature)
        #expect(engine.perform(.resize(0.05), space: 1, areas: Self.areas).settings?.featureSize != nil)
        _ = engine.focus(other)
        let outcome = engine.perform(.resize(0.05), space: 1, areas: Self.areas)
        #expect(outcome.settings == nil)
        #expect(outcome.message == nil)
        #expect(engine.spacesForTesting[1]!.manual)
    }

    @Test("clearSettingOverrides clears only the requested fields")
    func clearSettingOverridesClearsOnlyRequestedFields() {
        var engine = Self.makeEngine()
        _ = engine.addWindow(1, pid: 1, facts: WindowFacts(), space: 1)
        _ = engine.perform(.featureSize(0.1), space: 1, areas: Self.areas)
        _ = engine.perform(.featureCount(1), space: 1, areas: Self.areas)
        #expect(engine.spacesForTesting[1]?.featureSizeOverride != nil)
        #expect(engine.spacesForTesting[1]?.featureCountOverride != nil)

        engine.clearSettingOverrides(1, featureSize: true, featureCount: false)
        #expect(engine.spacesForTesting[1]?.featureSizeOverride == nil)
        #expect(engine.spacesForTesting[1]?.featureCountOverride != nil)

        engine.clearSettingOverrides(1, featureSize: false, featureCount: true)
        #expect(engine.spacesForTesting[1]?.featureCountOverride == nil)

        // Unknown Space: no-op, does not trap.
        engine.clearSettingOverrides(999, featureSize: true, featureCount: true)
    }

    // MARK: - Native tabs

    @Test("a tab switch hands the tile to the tab that comes forward; switching back returns it")
    func tabSwitchKeepsArrangement() {
        var config = Self.baseConfig()
        config.rules = [AppRule(match: RuleMatch(appID: "term"), actions: RuleActions(weight: 10))]
        var engine = Self.makeEngine(config: config)
        _ = engine.addWindow(1, pid: 1, facts: WindowFacts(bundleID: "slack"), space: 1)
        _ = engine.addWindow(2, pid: 2, facts: WindowFacts(bundleID: "term"), space: 1)
        _ = engine.addWindow(3, pid: 3, facts: WindowFacts(bundleID: "mail"), space: 1)
        let before = engine.layout(space: 1, area: Self.area).frames[2]!
        #expect(engine.spacesForTesting[1]!.liveOrder.first == 2)

        // A new tab of window 2's group is tracked, then window 2 drops out of the app's window list.
        _ = engine.addWindow(4, pid: 2, facts: WindowFacts(bundleID: "term"), space: 1)
        _ = engine.swapTab(hiding: 2, showing: 4)
        var order = engine.spacesForTesting[1]!.liveOrder
        #expect(order.first == 4)
        #expect(Set(order) == [1, 3, 4])
        #expect(engine.layout(space: 1, area: Self.area).frames[4] == before)
        #expect(engine.layout(space: 1, area: Self.area).frames[2] == nil)

        // Back to the first tab: no window is added or dropped, only the tile changes hands.
        _ = engine.swapTab(hiding: 4, showing: 2)
        order = engine.spacesForTesting[1]!.liveOrder
        #expect(order.first == 2)
        #expect(Set(order) == [1, 2, 3])
        #expect(engine.layout(space: 1, area: Self.area).frames[2] == before)
    }

    @Test("a tab keeps its slot in a manually arranged Space")
    func tabSwitchKeepsManualSlot() {
        var engine = Self.makeEngine()
        for id: WindowID in 1...4 { _ = engine.addWindow(id, pid: Int32(id), facts: WindowFacts(), space: 1) }
        _ = engine.swap(1, 3, on: 1) // manual: order now starts 3, ...
        let order = engine.spacesForTesting[1]!.liveOrder
        let slot = order.firstIndex(of: 2)!
        let frame = engine.layout(space: 1, area: Self.area).frames[2]!

        _ = engine.addWindow(5, pid: 2, facts: WindowFacts(), space: 1)
        _ = engine.swapTab(hiding: 2, showing: 5)

        let after = engine.spacesForTesting[1]!.liveOrder
        #expect(after.firstIndex(of: 5) == slot)
        #expect(!after.contains(2))
        #expect(after.filter { $0 != 5 } == order.filter { $0 != 2 })
        #expect(engine.layout(space: 1, area: Self.area).frames[5] == frame)
    }

    @Test("a background tab holds no tile and is never a focus target; a lone tab change of an unpaired window still works")
    func backgroundTabIsOutOfLayout() {
        var engine = Self.makeEngine()
        _ = engine.addWindow(1, pid: 1, facts: WindowFacts(), space: 1)
        _ = engine.addWindow(2, pid: 2, facts: WindowFacts(), space: 1)
        _ = engine.focus(2)

        _ = engine.setBackgroundTab(2, true)
        #expect(engine.spacesForTesting[1]!.liveOrder == [1])
        #expect(engine.layout(space: 1, area: Self.area).frames[2] == nil)

        _ = engine.setBackgroundTab(2, false)
        #expect(Set(engine.spacesForTesting[1]!.liveOrder) == [1, 2])
    }

    // MARK: - Effective settings

    @Test("settings(for:) layers screen defaults, [layout], the desktop's own keys, then runtime feature size and count")
    func settingsPrecedence() {
        var config = Config()
        config.layout.columns = 2
        var desktop = LayoutOverrides()
        desktop.columns = 3
        desktop.feature = FeatureSide.off
        config.spaces[.position(display: Self.displayA, ordinal: 2)] = desktop
        var engine = Self.makeEngine(config: config)

        let first = engine.settings(for: 1)
        #expect(first.columns == 2, "[layout] beats the screen default")
        #expect(first.rows == 2 && first.feature == .left, "unset keys keep the large-screen default")
        let second = engine.settings(for: 2)
        #expect(second.columns == 3 && !second.hasFeature, "the desktop's own keys beat [layout]")

        _ = engine.perform(.featureSize(0.1), space: 1, areas: Self.areas)
        _ = engine.perform(.featureCount(1), space: 1, areas: Self.areas)
        #expect(abs(engine.settings(for: 1).featureSize - 0.7) < 1e-9)
        #expect(engine.settings(for: 1).featureCount == 2)
        #expect(engine.settings(for: 1).columns == 2, "runtime overrides touch only their own fields")
        #expect(engine.settings(for: 2).featureSize == 0.6, "and only their own Space")

        engine.passthrough = true
        #expect(engine.settings(for: 1).arrange == .float)
        #expect(engine.arrangement(for: 2) == .float)
        engine.passthrough = false
        #expect(engine.arrangement(for: 1) == .fixed)

        engine.clearSettingOverrides(1, featureSize: true, featureCount: true)
        #expect(engine.settings(for: 1).featureSize == 0.6 && engine.settings(for: 1).featureCount == 1)
    }

    @Test("glyph(for:) and layoutDescription(for:) describe the desktop's layout; monocle leaves them alone")
    func glyphAndDescription() {
        var config = Config()
        func desk(_ ordinal: Int, display: String = Self.displayA, _ edit: (inout LayoutOverrides) -> Void) {
            var o = LayoutOverrides()
            edit(&o)
            config.spaces[.position(display: display, ordinal: ordinal)] = o
        }
        desk(1) { $0.arrange = .adaptive; $0.feature = FeatureSide.off }
        desk(2) { $0.arrange = .dwindle; $0.feature = .left }
        desk(1, display: Self.displayB) { $0.arrange = .fixed; $0.columns = 2; $0.rows = 0; $0.feature = FeatureSide.off }
        desk(2, display: Self.displayB) { $0.arrange = .float }
        var engine = Self.makeEngine(config: config)

        #expect(engine.glyph(for: 1) == "A")
        #expect(engine.layoutDescription(for: 1) == "Adaptive grid")
        #expect(engine.glyph(for: 2) == "F·D")
        #expect(engine.glyph(for: 4) == "2×∞")
        #expect(engine.glyph(for: 5) == "⋯")
        #expect(engine.layoutDescription(for: 5) == "Float")

        _ = engine.addWindow(1, pid: 1, facts: WindowFacts(), space: 1)
        _ = engine.perform(.monocle, space: 1, areas: Self.areas)
        #expect(engine.isMonocle(1) && !engine.isMonocle(2))
        #expect(engine.glyph(for: 1) == "A")

        engine.passthrough = true
        #expect(engine.glyph(for: 1) == "⋯")
    }

    @Test("the large-screen default reads as a fixed 1×2 grid with a left feature")
    func largeDefaultDescription() {
        let engine = Self.makeEngine(config: Config())
        #expect(engine.glyph(for: 1) == "F·1×2")
        #expect(engine.layoutDescription(for: 1) == "Fixed grid 1×2 with left feature")
    }

    @Test("a snapshot update that flips a display's small flag dirties its Spaces and swaps their defaults")
    func smallFlagChangeDirtiesSpaces() {
        var engine = Engine(config: Config())
        _ = engine.updateSnapshot(Self.snapshot(small: false))
        _ = engine.addWindow(1, pid: 1, facts: WindowFacts(), space: 1)
        _ = engine.addWindow(4, pid: 4, facts: WindowFacts(), space: 4)
        #expect(engine.settings(for: 1).hasFeature)

        #expect(engine.updateSnapshot(Self.snapshot(small: false)).isEmpty)

        // Only display A shrinks (e.g. its resolution changed).
        let shrunk = DisplaySpaces(displayUUID: Self.displayA, spaces: [
            SpaceInfo(id: 1, uuid: "a1", kind: .user),
            SpaceInfo(id: 2, uuid: "a2", kind: .user),
            SpaceInfo(id: 3, uuid: "a3", kind: .fullscreen),
        ], activeSpace: 1, small: true)
        let dirty = engine.updateSnapshot(SpaceSnapshot(displays: [shrunk, Self.snapshot().displays[1]]))
        #expect(dirty == [1])
        #expect(!engine.settings(for: 1).hasFeature && engine.settings(for: 1).rows == 1)
        #expect(engine.settings(for: 4).hasFeature)
    }
}

extension Engine {
    /// Test-only accessor for the private(set) `spaces` dictionary (already public API).
    var spacesForTesting: [SpaceID: SpaceState] { spaces }
    /// Test-only accessor for the private(set) `windows` dictionary (already public API).
    var windowsForTesting: [WindowID: WindowRecord] { windows }
}
