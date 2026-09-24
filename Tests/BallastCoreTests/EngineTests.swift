import CoreGraphics
import Testing
@testable import BallastCore

@Suite("Engine")
struct EngineTests {

    static let displayA = "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"
    static let displayB = "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB"
    static let area = CGRect(x: 0, y: 0, width: 1000, height: 800)

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

        #expect(engine.mode(for: 1) == .masterStack)
        let state = engine.spacesForTesting[1]!
        #expect(state.liveOrder.first == 2)
        let layout = engine.layout(space: 1, area: Self.area)
        // Ghostty occupies the master (right) region: it should be the widest tile.
        let master = layout.frames[2]!
        let stack = layout.frames[1]!
        #expect(master.width > stack.width)
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
        _ = engine.addWindow(1, pid: 1, facts: WindowFacts(), space: 1)
        _ = engine.addWindow(2, pid: 2, facts: WindowFacts(), space: 1)
        let swapped2 = engine.swap(1, 2, on: 1)
        #expect(swapped2)
        #expect(engine.spacesForTesting[1]!.manual)

        var newConfig = Config()
        newConfig.layout.mode = .bsp
        newConfig.rules = [AppRule(match: RuleMatch(appID: "x"), actions: RuleActions(weight: 50))]
        _ = engine.applyConfig(newConfig)

        #expect(engine.spacesForTesting[1]!.manual)
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

        _ = engine.perform(.layout(.set(.bsp)), space: 1, area: Self.area)
        let outcome = engine.perform(.reset, space: 1, area: Self.area)
        #expect(outcome.dirty.contains(1))

        let state = engine.spacesForTesting[1]!
        #expect(!state.manual)
        #expect(state.liveOrder.first == 2) // heavy weight wins again
        #expect(state.tree?.leaves.contains(1) == true)
        #expect(state.tree?.leaves.contains(2) == true)
        // modeOverride (bsp) must survive reset.
        #expect(engine.mode(for: 1) == .bsp)
    }

    // MARK: - Config reload does not reset manual/monocle/mode (Rift bug)

    @Test("config reload preserves modeOverride, monocle and manual arrangement, but updates config defaults elsewhere")
    func configReloadPreservesRuntimeState() {
        var engine = Self.makeEngine()
        _ = engine.addWindow(1, pid: 1, facts: WindowFacts(), space: 1)
        _ = engine.addWindow(2, pid: 2, facts: WindowFacts(), space: 1)
        _ = engine.perform(.layout(.set(.bsp)), space: 1, area: Self.area)
        _ = engine.perform(.monocle, space: 1, area: Self.area)
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
        #expect(engine.mode(for: 2) == .masterStack)
        #expect(engine.spacesForTesting[2]!.manual)
        #expect(engine.spacesForTesting[2]!.liveOrder.first == 2)

        // The deleted Space's (id 1) state is dropped.
        #expect(engine.spacesForTesting[1] == nil)
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

        let outcome1 = engine.perform(.focusLast, space: 1, area: Self.area)
        #expect(outcome1.focus == 1)
        _ = engine.focus(1)

        let outcome2 = engine.perform(.focusLast, space: 1, area: Self.area)
        #expect(outcome2.focus == 2)
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

    @Test(".toggleFloat command flips tiling")
    func toggleFloatCommand() {
        var engine = Self.makeEngine()
        _ = engine.addWindow(1, pid: 1, facts: WindowFacts(), space: 1)
        _ = engine.focus(1)
        #expect(engine.isTiled(1))

        _ = engine.perform(.toggleFloat, space: 1, area: Self.area)
        #expect(!engine.isTiled(1))

        _ = engine.perform(.toggleFloat, space: 1, area: Self.area)
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

        _ = engine.perform(.monocle, space: 1, area: Self.area)
        let monocleLayout = engine.layout(space: 1, area: Self.area)
        #expect(monocleLayout.frames[1] == monocleLayout.frames[2])
        #expect(monocleLayout.raise == 2)

        _ = engine.perform(.monocle, space: 1, area: Self.area)
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
        _ = engine.perform(.monocle, space: 1, area: Self.area)
        #expect(engine.layout(space: 1, area: Self.area).raise == 2)

        // Window 3 floats above the tiled Space and takes focus.
        _ = engine.focus(3)
        _ = engine.perform(.toggleFloat, space: 1, area: Self.area)
        #expect(engine.windowsForTesting[3]?.isFloating == true)

        #expect(engine.layout(space: 1, area: Self.area).raise == nil)

        // Any other layout-affecting change (e.g. a resize elsewhere) must
        // not resurrect a raised member while the float holds focus.
        _ = engine.setMinimized(1, true)
        _ = engine.setMinimized(1, false)
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

        _ = engine.perform(.masterRatio(0.05), space: 1, area: Self.area)
        let ratio = engine.spacesForTesting[1]?.masterRatioOverride ?? config.layout.masterRatio
        #expect(ratio >= 0.93)
    }

    @Test("shrinking an already-low but valid master ratio never grows it")
    func masterRatioShrinkNeverGrowsValidLowRatio() {
        var config = Config()
        config.layout.masterRatio = 0.07
        var engine = Self.makeEngine(config: config)
        _ = engine.addWindow(1, pid: 1, facts: WindowFacts(), space: 1)

        _ = engine.perform(.masterRatio(-0.05), space: 1, area: Self.area)
        let ratio = engine.spacesForTesting[1]?.masterRatioOverride ?? config.layout.masterRatio
        #expect(ratio <= 0.07)
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
}

extension Engine {
    /// Test-only accessor for the private(set) `spaces` dictionary (already public API).
    var spacesForTesting: [SpaceID: SpaceState] { spaces }
    /// Test-only accessor for the private(set) `windows` dictionary (already public API).
    var windowsForTesting: [WindowID: WindowRecord] { windows }
}
