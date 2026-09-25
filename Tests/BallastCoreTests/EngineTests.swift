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
    static func snapshot() -> SpaceSnapshot {
        let a = DisplaySpaces(displayUUID: displayA, spaces: [
            SpaceInfo(id: 1, uuid: "a1", kind: .user),
            SpaceInfo(id: 2, uuid: "a2", kind: .user),
            SpaceInfo(id: 3, uuid: "a3", kind: .fullscreen),
        ], activeSpace: 1)
        let b = DisplaySpaces(displayUUID: displayB, spaces: [
            SpaceInfo(id: 4, uuid: "b1", kind: .user),
            SpaceInfo(id: 5, uuid: "b2", kind: .user),
            SpaceInfo(id: 6, uuid: "b3", kind: .fullscreen),
        ], activeSpace: 4)
        return SpaceSnapshot(displays: [a, b])
    }

    static func makeEngine(config: Config = Config()) -> Engine {
        var engine = Engine(config: config)
        _ = engine.updateSnapshot(snapshot())
        return engine
    }

    // MARK: - Continuous weight-driven master

    @Test("higher-weight window becomes master without any command")
    func weightDrivenMaster() {
        var config = Config()
        config.rules = [AppRule(match: RuleMatch(appID: "com.ghostty.app"), actions: RuleActions(weight: 10))]
        var engine = Self.makeEngine(config: config)

        _ = engine.addWindow(1, pid: 1, facts: WindowFacts(bundleID: "com.tinyspeck.slackmacgap"), space: 1)
        _ = engine.addWindow(2, pid: 2, facts: WindowFacts(bundleID: "com.ghostty.app"), space: 1)

        #expect(engine.mode(for: 1) == .masterGrid)
        let state = engine.spacesForTesting[1]!
        #expect(state.liveOrder.first == 2)
        let layout = engine.layout(space: 1, area: Self.area)
        // Ghostty occupies the master (right) region: it should be the widest tile.
        let master = layout.frames[2]!
        let stack = layout.frames[1]!
        #expect(master.width > stack.width)
    }

    @Test("a new window joins the top of the stack; opening and closing never reorders the rest")
    func newcomerTopsStack() {
        var engine = Self.makeEngine()
        for id: WindowID in 1...3 {
            _ = engine.addWindow(id, pid: Int32(id), facts: WindowFacts(), space: 1)
            _ = engine.focus(id)
        }
        #expect(engine.spacesForTesting[1]!.liveOrder == [1, 3, 2])
        _ = engine.focus(2) // focus history never moves the master
        _ = engine.addWindow(4, pid: 4, facts: WindowFacts(), space: 1)
        #expect(engine.spacesForTesting[1]!.liveOrder == [1, 4, 3, 2])
        _ = engine.removeWindow(3)
        #expect(engine.spacesForTesting[1]!.liveOrder == [1, 4, 2])
        // The master closing hands its slot to the top of the stack.
        _ = engine.removeWindow(1)
        #expect(engine.spacesForTesting[1]!.liveOrder == [4, 2])

        // Two masters: the newcomer lands right after both.
        _ = engine.perform(.masterCount(1), space: 1, areas: Self.areas)
        _ = engine.addWindow(5, pid: 5, facts: WindowFacts(), space: 1)
        #expect(engine.spacesForTesting[1]!.liveOrder == [4, 2, 5])
    }

    @Test("a newcomer tops the stack after heavier stack windows; on a manual Space, right after the master")
    func newcomerRespectsWeightAndManualMaster() {
        var config = Config()
        config.rules = [AppRule(match: RuleMatch(appID: "heavy"), actions: RuleActions(weight: 5))]
        var engine = Self.makeEngine(config: config)
        _ = engine.addWindow(1, pid: 1, facts: WindowFacts(bundleID: "heavy"), space: 1)
        _ = engine.addWindow(2, pid: 2, facts: WindowFacts(bundleID: "heavy"), space: 1)
        _ = engine.addWindow(3, pid: 3, facts: WindowFacts(), space: 1)
        _ = engine.addWindow(4, pid: 4, facts: WindowFacts(), space: 1)
        #expect(engine.spacesForTesting[1]!.liveOrder == [1, 2, 4, 3])

        // Manual: window 3 is master; the newcomer goes right under it.
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

    @Test("manual master survives a newcomer with higher weight")
    func manualOverridePersistsAgainstNewcomer() {
        var engine = Self.makeEngine()
        _ = engine.addWindow(1, pid: 1, facts: WindowFacts(), space: 1)
        _ = engine.addWindow(2, pid: 2, facts: WindowFacts(), space: 1)
        // Manually promote window 2 to master via swap.
        let swapped1 = engine.swap(1, 2, on: 1)
        #expect(swapped1)
        #expect(engine.spacesForTesting[1]!.liveOrder.first == 2)

        // Newcomer with a much higher weight joins; manual master must stick.
        var config = Config()
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

        var newConfig = Config()
        newConfig.layout.mode = .bsp
        newConfig.rules = [AppRule(match: RuleMatch(appID: "x"), actions: RuleActions(weight: 50))]
        _ = engine.applyConfig(newConfig)

        #expect(engine.spacesForTesting[1]!.manual)
        // Weights changed: the ideal order now puts the heavy window 1 first...
        #expect(engine.spacesForTesting[1]!.idealOrder.first == 1)
        // ...but manual arrangement still wins for the live order.
        #expect(engine.spacesForTesting[1]!.liveOrder.first == 2)
    }

    @Test("perform(.reset) restores pure weight order and ideal BSP tree, keeps modeOverride")
    func resetRestoresWeightOrder() {
        var config = Config()
        config.rules = [AppRule(match: RuleMatch(appID: "heavy"), actions: RuleActions(weight: 100))]
        var engine = Self.makeEngine(config: config)
        _ = engine.addWindow(1, pid: 1, facts: WindowFacts(), space: 1)
        _ = engine.addWindow(2, pid: 2, facts: WindowFacts(bundleID: "heavy"), space: 1)
        let swapped3 = engine.swap(1, 2, on: 1) // manual: window 1 now master despite lower weight
        #expect(swapped3)
        #expect(engine.spacesForTesting[1]!.liveOrder.first == 1)

        _ = engine.perform(.layout(.set(.bsp)), space: 1, areas: Self.areas)
        _ = engine.focus(1)
        _ = engine.perform(.resize(0.1), space: 1, areas: Self.areas) // pin a manual split ratio
        #expect(engine.spacesForTesting[1]!.tree != BSPNode.ideal(engine.spacesForTesting[1]!.idealOrder, axis: nil))
        let outcome = engine.perform(.reset, space: 1, areas: Self.areas)
        #expect(outcome.dirty.contains(1))

        let state = engine.spacesForTesting[1]!
        #expect(!state.manual)
        #expect(state.liveOrder.first == 2) // heavy weight wins again
        #expect(state.tree == BSPNode.ideal(state.idealOrder, axis: nil))
        // modeOverride (bsp) must survive reset.
        #expect(engine.mode(for: 1) == .bsp)
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

    @Test("config reload preserves modeOverride, monocle and manual arrangement, but updates config defaults elsewhere")
    func configReloadPreservesRuntimeState() {
        var engine = Self.makeEngine()
        _ = engine.addWindow(1, pid: 1, facts: WindowFacts(), space: 1)
        _ = engine.addWindow(2, pid: 2, facts: WindowFacts(), space: 1)
        _ = engine.perform(.layout(.set(.bsp)), space: 1, areas: Self.areas)
        _ = engine.perform(.monocle, space: 1, areas: Self.areas)
        let swapped4 = engine.swap(1, 2, on: 1)
        #expect(swapped4)

        var newConfig = Config()
        newConfig.layout.mode = .float // config default changes; space 1 has an override so unaffected
        _ = engine.applyConfig(newConfig)

        #expect(engine.mode(for: 1) == .bsp)
        #expect(engine.spacesForTesting[1]!.monocle)
        #expect(engine.spacesForTesting[1]!.manual)

        // A space without an override picks up the new config default.
        _ = engine.addWindow(3, pid: 3, facts: WindowFacts(), space: 4)
        #expect(engine.mode(for: 4) == .float)
    }

    @Test("a changed `split` applies on reload to weight-default Spaces, not manually arranged ones")
    func splitChangeAppliesOnReload() {
        func config(split: Axis?) -> Config {
            var config = Config()
            config.rules = [AppRule(match: RuleMatch(appID: "heavy"), actions: RuleActions(weight: 10))]
            var bsp = LayoutOverrides()
            bsp.mode = .bsp
            bsp.split = .some(split)
            config.spaces[SpaceKey(display: Self.displayA, ordinal: 1)] = bsp
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
        bsp.mode = .bsp
        bsp.bspShape = .balanced
        config.spaces[SpaceKey(display: Self.displayA, ordinal: 1)] = bsp
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

    @Test("mode(for:) differs per SpaceID according to Config.spaces")
    func perSpaceConfig() {
        var config = Config()
        var bspOverride = LayoutOverrides()
        bspOverride.mode = .bsp
        config.spaces[SpaceKey(display: Self.displayA, ordinal: 1)] = bspOverride
        var floatOverride = LayoutOverrides()
        floatOverride.mode = .float
        config.spaces[SpaceKey(display: Self.displayA, ordinal: 2)] = floatOverride

        let engine = Self.makeEngine(config: config)
        #expect(engine.mode(for: 1) == .bsp) // A ordinal 1
        #expect(engine.mode(for: 2) == .float) // A ordinal 2
    }

    @Test("SpaceID state follows the physical Space when a sibling Space is deleted")
    func spaceIDFollowsPhysicalSpaceOnSiblingDeletion() {
        var config = Config()
        var ordinal2Override = LayoutOverrides()
        ordinal2Override.mode = .bsp
        config.spaces[SpaceKey(display: Self.displayA, ordinal: 2)] = ordinal2Override
        var engine = Self.makeEngine(config: config)

        // Space 2 is ordinal 2 (bsp by config). Add a window and manually promote.
        _ = engine.addWindow(1, pid: 1, facts: WindowFacts(), space: 2)
        _ = engine.addWindow(2, pid: 2, facts: WindowFacts(), space: 2)
        // A window on the doomed Space 1, to prove its state and window ties are dropped.
        _ = engine.addWindow(3, pid: 3, facts: WindowFacts(), space: 1)
        let swapped5 = engine.swap(1, 2, on: 2)
        #expect(swapped5)
        #expect(engine.mode(for: 2) == .bsp)

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
        // new ordinal (1), which has no override -> default mode.
        #expect(dirty.contains(2))
        #expect(engine.mode(for: 2) == .masterGrid)
        #expect(engine.spacesForTesting[2]!.manual)
        #expect(engine.spacesForTesting[2]!.liveOrder.first == 2)

        // The deleted Space's (id 1) state is dropped, and its window no longer points at it.
        #expect(engine.spacesForTesting[1] == nil)
        #expect(engine.windowsForTesting[3]?.space == nil)
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

    @Test(".focusMaster jumps to the master from the stack, then back to the window it came from")
    func focusMasterToggles() {
        var engine = Self.makeEngine()
        for id in 1...3 as ClosedRange<WindowID> {
            _ = engine.addWindow(id, pid: Int32(id), facts: WindowFacts(), space: 1)
        }
        let order = engine.spacesForTesting[1]!.liveOrder
        let master = order[0], older = order[1], previous = order[2]
        _ = engine.focus(older)
        _ = engine.focus(previous)

        #expect(engine.perform(.focusMaster, space: 1, areas: Self.areas).focus == master)
        _ = engine.focus(master)

        // Back to the stack window that had focus, not merely any other tile.
        #expect(engine.perform(.focusMaster, space: 1, areas: Self.areas).focus == previous)
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

    @Test("monocle gives every tiled window the same full frame, focused one raised")
    func monocleFullFrames() {
        var engine = Self.makeEngine()
        _ = engine.addWindow(1, pid: 1, facts: WindowFacts(), space: 1)
        _ = engine.addWindow(2, pid: 2, facts: WindowFacts(), space: 1)
        _ = engine.focus(2)

        let before = engine.layout(space: 1, area: Self.area).frames
        #expect(before[1] != before[2])

        _ = engine.perform(.monocle, space: 1, areas: Self.areas)
        let monocleLayout = engine.layout(space: 1, area: Self.area)
        #expect(monocleLayout.frames[1] == monocleLayout.frames[2])
        #expect(monocleLayout.raise == 2)

        _ = engine.perform(.monocle, space: 1, areas: Self.areas)
        let after = engine.layout(space: 1, area: Self.area)
        #expect(after.frames == before)
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
        var config = Config()
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

    // MARK: - Mode by display

    @Test("with no mode configured, built-in displays get master-stack and external ones master-grid; any configured mode wins")
    func modeFollowsDisplayUnlessConfigured() {
        let laptop = DisplaySpaces(displayUUID: Self.displayA, spaces: [
            SpaceInfo(id: 1, uuid: "a1", kind: .user),
            SpaceInfo(id: 2, uuid: "a2", kind: .user),
        ], activeSpace: 1, builtin: true)
        let external = DisplaySpaces(displayUUID: Self.displayB, spaces: [SpaceInfo(id: 4, uuid: "b1", kind: .user)], activeSpace: 4)
        func engine(_ config: Config) -> Engine {
            var engine = Engine(config: config)
            _ = engine.updateSnapshot(SpaceSnapshot(displays: [laptop, external]))
            return engine
        }

        var config = Config()
        var automatic = engine(config)
        #expect(automatic.mode(for: 1) == .masterStack)
        #expect(automatic.mode(for: 4) == .masterGrid)
        // A runtime override beats the display.
        _ = automatic.perform(.layout(.set(.bsp)), space: 1, areas: Self.areas)
        #expect(automatic.mode(for: 1) == .bsp)

        // A desktop's own mode beats the display.
        var desktop = LayoutOverrides()
        desktop.mode = .masterGrid
        config.spaces[SpaceKey(display: Self.displayA, ordinal: 2)] = desktop
        #expect(engine(config).mode(for: 2) == .masterGrid)

        // An explicit [layout] mode applies to every display.
        config.layout.mode = .bsp
        #expect(engine(config).mode(for: 1) == .bsp)
        #expect(engine(config).mode(for: 4) == .bsp)
    }

    // MARK: - Scrolling stack

    /// `count` windows on Space 1 with no gaps: master 1, stack 2...count.
    static func stackEngine(_ mode: LayoutMode = .masterStack, gridMax: Int = 0, columns: Int = 1,
                            bothSides: Bool = false, count: Int) -> Engine {
        var config = Config()
        config.layout.mode = mode
        config.layout.gridMax = gridMax
        config.layout.gridColumns = columns
        config.layout.stackBothSides = bothSides
        config.layout.gaps = Gaps(inner: 0, outer: 0)
        var engine = Self.makeEngine(config: config)
        // Each newcomer tops the stack, so the stack joins bottom-up.
        for id in [1] + (1...count).dropFirst().reversed() {
            _ = engine.addWindow(WindowID(id), pid: Int32(id), facts: WindowFacts(), space: 1)
        }
        return engine
    }

    @Test("master-stack shows the focused stack window; the others tuck behind it, peeking at its ends")
    func masterStackShowsOneWindow() {
        var engine = Self.stackEngine(count: 4)
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

    @Test("focus only dirties a Space whose stack scrolls")
    func focusDirtiesScrollingStacks() {
        var grid = Self.stackEngine(.masterGrid, count: 4)
        #expect(grid.focus(3).isEmpty)
        var capped = Self.stackEngine(.masterGrid, gridMax: 2, count: 4)
        #expect(capped.focus(3) == [1])
        var single = Self.stackEngine(count: 2)
        #expect(single.focus(2).isEmpty)
        var stack = Self.stackEngine(count: 3)
        #expect(stack.focus(2) == [1])
    }

    @Test("directional focus walks the stack past the view and in and out of the master")
    func focusWalksTheStrip() {
        var engine = Self.stackEngine(count: 4)
        _ = engine.focus(2)
        #expect(engine.perform(.focus(.down), space: 1, areas: Self.areas).focus == 3)
        _ = engine.focus(3)
        #expect(engine.layout(space: 1, area: Self.area).covered[3] == nil)
        #expect(engine.perform(.focus(.down), space: 1, areas: Self.areas).focus == 4)
        #expect(engine.perform(.focus(.up), space: 1, areas: Self.areas).focus == 2)
        #expect(engine.perform(.focus(.left), space: 1, areas: Self.areas).focus == 1)
        // Back from the master lands on the window in view, not a tucked one.
        _ = engine.focus(1)
        #expect(engine.perform(.focus(.right), space: 1, areas: Self.areas).focus == 3)
    }

    @Test("directional focus crosses between side-by-side displays at the edge")
    func directionalFocusCrossesDisplays() {
        var config = Config()
        config.layout.mode = .bsp
        config.layout.gaps = Gaps(inner: 0, outer: 0)
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

    @Test("swap moves the focused window along the stack and the view follows it")
    func swapMovesAlongTheStack() {
        var engine = Self.stackEngine(count: 4)
        _ = engine.focus(2)
        #expect(engine.perform(.swap(.down), space: 1, areas: Self.areas).dirty == [1])
        #expect(engine.spacesForTesting[1]!.liveOrder == [1, 3, 2, 4])
        let layout = engine.layout(space: 1, area: Self.area)
        #expect(layout.covered[2] == nil)
        #expect(layout.raise == 2)
    }

    @Test("master-grid tiles grid_max stack windows, then scrolls")
    func masterGridScrollsPastGridMax() {
        var engine = Self.stackEngine(.masterGrid, gridMax: 2, count: 5)
        _ = engine.focus(4)
        let layout = engine.layout(space: 1, area: Self.area)
        #expect(Set(layout.covered.keys) == [2, 5])
        #expect(layout.frames[3]!.height == layout.frames[4]!.height)
        #expect(layout.frames[3]!.maxY <= layout.frames[4]!.minY)
    }

    @Test("master-grid columns: overflow scrolls in the outermost column only, and focusing it scrolls")
    func masterGridColumnsScrollOutermost() {
        var engine = Self.stackEngine(.masterGrid, gridMax: 1, columns: 2, count: 4)
        #expect(engine.focus(4).contains(1))
        let layout = engine.layout(space: 1, area: Self.area)
        #expect(Set(layout.covered.keys) == [3])
        #expect(layout.frames[2]!.height == Self.area.height)
        #expect(layout.frames[2]!.maxX <= layout.frames[4]!.minX)
    }

    @Test("master-stack ignores grid_columns; with both sides each side scrolls on its own")
    func masterStackColumnsAndBothSides() {
        var single = Self.stackEngine(columns: 3, count: 4)
        _ = single.focus(3)
        #expect(Set(single.layout(space: 1, area: Self.area).covered.keys) == [2, 4])

        var both = Self.stackEngine(bothSides: true, count: 5)
        _ = both.focus(2)
        _ = both.focus(5)
        let layout = both.layout(space: 1, area: Self.area)
        #expect(Set(layout.covered.keys) == [3, 4])
        #expect(layout.frames[5]!.maxX <= layout.frames[1]!.minX)
        #expect(layout.frames[1]!.maxX <= layout.frames[2]!.minX)
    }

    @Test("a tile in view is raised only while a window belonging behind it is in front of it")
    func tilesToRaiseRestoreTheDeck() {
        var engine = Self.stackEngine(.masterGrid, gridMax: 2, count: 5)
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
        var config = Config()
        config.layout.mode = .masterGrid
        config.layout.gridMax = 2
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

    // MARK: - Stage Manager passthrough

    @Test("passthrough forces float mode with no frames")
    func passthroughForcesFloat() {
        var engine = Self.makeEngine()
        _ = engine.addWindow(1, pid: 1, facts: WindowFacts(), space: 1)
        engine.passthrough = true
        #expect(engine.mode(for: 1) == .float)
        let layout = engine.layout(space: 1, area: Self.area)
        #expect(layout.frames.isEmpty)
    }

    // MARK: - Master ratio clamp

    @Test("growing an already-high but valid master ratio never shrinks it")
    func masterRatioGrowNeverShrinksValidHighRatio() {
        var config = Config()
        config.layout.masterRatio = 0.93
        var engine = Self.makeEngine(config: config)
        _ = engine.addWindow(1, pid: 1, facts: WindowFacts(), space: 1)

        _ = engine.perform(.masterRatio(0.05), space: 1, areas: Self.areas)
        let ratio = engine.spacesForTesting[1]?.masterRatioOverride ?? config.layout.masterRatio
        #expect(ratio >= 0.93)
    }

    @Test("growing a ratio already within an epsilon of 0.95 never reverses direction")
    func masterRatioGrowNearUpperBoundNeverReverses() {
        var config = Config()
        config.layout.masterRatio = 0.95.nextDown.nextDown.nextDown
        var engine = Self.makeEngine(config: config)
        _ = engine.addWindow(1, pid: 1, facts: WindowFacts(), space: 1)

        let before = engine.spacesForTesting[1]?.masterRatioOverride ?? config.layout.masterRatio
        _ = engine.perform(.masterRatio(0.1), space: 1, areas: Self.areas)
        let after = engine.spacesForTesting[1]?.masterRatioOverride ?? config.layout.masterRatio
        #expect(after >= before)
        #expect(after < 0.95)
    }

    @Test("shrinking a ratio already within an epsilon of 0.05 never reverses direction")
    func masterRatioShrinkNearLowerBoundNeverReverses() {
        var config = Config()
        config.layout.masterRatio = 0.05.nextUp.nextUp.nextUp
        var engine = Self.makeEngine(config: config)
        _ = engine.addWindow(1, pid: 1, facts: WindowFacts(), space: 1)

        let before = engine.spacesForTesting[1]?.masterRatioOverride ?? config.layout.masterRatio
        _ = engine.perform(.masterRatio(-0.1), space: 1, areas: Self.areas)
        let after = engine.spacesForTesting[1]?.masterRatioOverride ?? config.layout.masterRatio
        #expect(after <= before)
        #expect(after > 0.05)
    }

    @Test("zero-delta master-ratio adjustment leaves the ratio unchanged")
    func masterRatioZeroDeltaLeavesRatioUnchanged() {
        var config = Config()
        config.layout.masterRatio = 0.6
        var engine = Self.makeEngine(config: config)
        _ = engine.addWindow(1, pid: 1, facts: WindowFacts(), space: 1)

        _ = engine.perform(.masterRatio(0), space: 1, areas: Self.areas)
        #expect(engine.spacesForTesting[1]?.masterRatioOverride == 0.6)
    }

    @Test("shrinking an already-low but valid master ratio never grows it")
    func masterRatioShrinkNeverGrowsValidLowRatio() {
        var config = Config()
        config.layout.masterRatio = 0.07
        var engine = Self.makeEngine(config: config)
        _ = engine.addWindow(1, pid: 1, facts: WindowFacts(), space: 1)

        _ = engine.perform(.masterRatio(-0.05), space: 1, areas: Self.areas)
        let ratio = engine.spacesForTesting[1]?.masterRatioOverride ?? config.layout.masterRatio
        #expect(ratio <= 0.07)
    }

    @Test("extreme master-ratio grow/shrink survives ConfigEditor persistence and Config.validated")
    func masterRatioExtremeCommandsRoundTripThroughConfigEditor() {
        for delta in [1.0, -1.0] {
            var engine = Self.makeEngine()
            _ = engine.addWindow(1, pid: 1, facts: WindowFacts(), space: 1)

            let outcome = engine.perform(.masterRatio(delta), space: 1, areas: Self.areas)
            let applied = outcome.settings?.masterRatio
            #expect(applied != nil)
            guard let ratio = applied else { continue }

            var editor = ConfigEditor(text: "[layout]\nmaster_ratio = 0.6\n")
            let setResult = editor.set("master_ratio", .float(ratio), in: .layout)
            guard case .success = setResult else {
                Issue.record("expected ConfigEditor.set to succeed for ratio \(ratio)")
                continue
            }
            switch editor.validated() {
            case .success(let config): #expect(config.layout.masterRatio == ratio)
            case .failure(let e): Issue.record("expected \(ratio) to validate, got \(e)")
            }
        }
    }

    @Test("repeated boundary master-ratio commands are stable")
    func masterRatioRepeatedBoundaryCommandsStable() {
        var engine = Self.makeEngine()
        _ = engine.addWindow(1, pid: 1, facts: WindowFacts(), space: 1)

        _ = engine.perform(.masterRatio(-1.0), space: 1, areas: Self.areas)
        let first = engine.spacesForTesting[1]?.masterRatioOverride
        _ = engine.perform(.masterRatio(-1.0), space: 1, areas: Self.areas)
        let second = engine.spacesForTesting[1]?.masterRatioOverride
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

    // MARK: - Master count clamp

    @Test(".masterCount(Int.max) does not trap and clamps to 16")
    func masterCountClampsUnboundedDelta() {
        var engine = Self.makeEngine()
        _ = engine.addWindow(1, pid: 1, facts: WindowFacts(), space: 1)

        _ = engine.perform(.masterCount(Int.max), space: 1, areas: Self.areas)
        #expect(engine.spacesForTesting[1]?.masterCountOverride == 16)

        _ = engine.perform(.masterCount(Int.min), space: 1, areas: Self.areas)
        #expect(engine.spacesForTesting[1]?.masterCountOverride == 1)
    }

    // MARK: - SettingsChange (config write-back)

    @Test("layout mode commands emit a SettingsChange; config-default removes the override")
    func layoutCommandsEmitSettingsChange() {
        var engine = Self.makeEngine()
        _ = engine.addWindow(1, pid: 1, facts: WindowFacts(), space: 1)

        let setOutcome = engine.perform(.layout(.set(.bsp)), space: 1, areas: Self.areas)
        #expect(setOutcome.settings == SettingsChange(space: 1, mode: .some(.bsp)))

        let nextOutcome = engine.perform(.layout(.next), space: 1, areas: Self.areas)
        #expect(nextOutcome.settings?.space == 1)
        #expect(nextOutcome.settings?.mode != nil)

        let previousOutcome = engine.perform(.layout(.previous), space: 1, areas: Self.areas)
        #expect(previousOutcome.settings?.space == 1)
        #expect(previousOutcome.settings?.mode != nil)

        let defaultOutcome = engine.perform(.layout(.configDefault), space: 1, areas: Self.areas)
        #expect(defaultOutcome.settings == SettingsChange(space: 1, mode: .some(nil)))
    }

    @Test(".masterRatio and master-layout resize/balance emit a masterRatio SettingsChange")
    func masterRatioCommandsEmitSettingsChange() {
        var engine = Self.makeEngine()
        _ = engine.addWindow(1, pid: 1, facts: WindowFacts(), space: 1)
        _ = engine.focus(1)

        let ratioOutcome = engine.perform(.masterRatio(0.1), space: 1, areas: Self.areas)
        #expect(ratioOutcome.settings?.space == 1)
        #expect(ratioOutcome.settings?.masterRatio == engine.spacesForTesting[1]?.masterRatioOverride)
        #expect(ratioOutcome.settings?.mode == nil)
        #expect(ratioOutcome.settings?.masterCount == nil)

        let resizeOutcome = engine.perform(.resize(0.05), space: 1, areas: Self.areas)
        #expect(resizeOutcome.settings?.space == 1)
        #expect(resizeOutcome.settings?.masterRatio == engine.spacesForTesting[1]?.masterRatioOverride)

        let balanceOutcome = engine.perform(.balance, space: 1, areas: Self.areas)
        #expect(balanceOutcome.settings == SettingsChange(space: 1, masterRatio: 0.5))
    }

    @Test(".masterCount emits a masterCount SettingsChange")
    func masterCountCommandEmitsSettingsChange() {
        var engine = Self.makeEngine()
        _ = engine.addWindow(1, pid: 1, facts: WindowFacts(), space: 1)

        let outcome = engine.perform(.masterCount(1), space: 1, areas: Self.areas)
        #expect(outcome.settings?.space == 1)
        #expect(outcome.settings?.masterCount == engine.spacesForTesting[1]?.masterCountOverride)
        #expect(outcome.settings?.mode == nil)
        #expect(outcome.settings?.masterRatio == nil)
    }

    @Test("BSP resize/balance/swap/monocle/reset never emit a SettingsChange")
    func bspCommandsNeverEmitSettingsChange() {
        var engine = Self.makeEngine()
        _ = engine.addWindow(1, pid: 1, facts: WindowFacts(), space: 1)
        _ = engine.addWindow(2, pid: 2, facts: WindowFacts(), space: 1)
        _ = engine.perform(.layout(.set(.bsp)), space: 1, areas: Self.areas)
        _ = engine.focus(1)

        #expect(engine.perform(.resize(0.1), space: 1, areas: Self.areas).settings == nil)
        #expect(engine.perform(.balance, space: 1, areas: Self.areas).settings == nil)
        #expect(engine.perform(.swap(.right), space: 1, areas: Self.areas).settings == nil)
        #expect(engine.perform(.monocle, space: 1, areas: Self.areas).settings == nil)
        #expect(engine.perform(.reset, space: 1, areas: Self.areas).settings == nil)
    }

    @Test("clearSettingOverrides clears only the requested fields")
    func clearSettingOverridesClearsOnlyRequestedFields() {
        var engine = Self.makeEngine()
        _ = engine.addWindow(1, pid: 1, facts: WindowFacts(), space: 1)
        _ = engine.perform(.layout(.set(.bsp)), space: 1, areas: Self.areas)
        _ = engine.perform(.masterRatio(0.1), space: 1, areas: Self.areas)
        _ = engine.perform(.masterCount(1), space: 1, areas: Self.areas)
        #expect(engine.spacesForTesting[1]?.modeOverride == .bsp)
        #expect(engine.spacesForTesting[1]?.masterRatioOverride != nil)
        #expect(engine.spacesForTesting[1]?.masterCountOverride != nil)

        engine.clearSettingOverrides(1, mode: true, masterRatio: false, masterCount: false)
        #expect(engine.spacesForTesting[1]?.modeOverride == nil)
        #expect(engine.spacesForTesting[1]?.masterRatioOverride != nil)
        #expect(engine.spacesForTesting[1]?.masterCountOverride != nil)

        engine.clearSettingOverrides(1, mode: false, masterRatio: true, masterCount: true)
        #expect(engine.spacesForTesting[1]?.masterRatioOverride == nil)
        #expect(engine.spacesForTesting[1]?.masterCountOverride == nil)

        // Unknown Space: no-op, does not trap.
        engine.clearSettingOverrides(999, mode: true, masterRatio: true, masterCount: true)
    }
}

extension Engine {
    /// Test-only accessor for the private(set) `spaces` dictionary (already public API).
    var spacesForTesting: [SpaceID: SpaceState] { spaces }
    /// Test-only accessor for the private(set) `windows` dictionary (already public API).
    var windowsForTesting: [WindowID: WindowRecord] { windows }
}
