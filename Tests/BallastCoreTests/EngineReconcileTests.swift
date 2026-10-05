import CoreGraphics
import Testing
@testable import BallastCore

/// Regression tests for the engine state-machine review fixes.
@Suite("Engine reconciliation")
struct EngineReconcileTests {
    typealias E = EngineTests

    @Test("a Space re-keyed by a snapshot change rebuilds its balanced tree")
    func rekeyedSpaceFollowsItsNewSettings() {
        var config = E.baseConfig()
        var balanced = LayoutOverrides()
        balanced.arrange = .balanced
        config.spaces[.position(display: E.displayA, ordinal: 1)] = balanced
        var engine = E.makeEngine(config: config)
        for id: WindowID in 1...4 { _ = engine.addWindow(id, pid: Int32(id), facts: WindowFacts(), space: 2) }

        // Desktop 1 goes away: Space 2 becomes ordinal 1 and picks up the override.
        let a = DisplaySpaces(displayUUID: E.displayA, spaces: [
            SpaceInfo(id: 2, uuid: "a2", kind: .user),
            SpaceInfo(id: 3, uuid: "a3", kind: .fullscreen),
        ], activeSpace: 2, small: false)
        let b = E.snapshot().displays[1]
        _ = engine.updateSnapshot(SpaceSnapshot(displays: [a, b]))

        #expect(engine.settings(for: 2).arrange == .balanced)
        let state = engine.spaces[2]!
        #expect(state.tree == engine.idealTree(state.idealOrder, on: 2, decks: state.decks))
    }

    @Test("leaving Stage Manager passthrough rebuilds the balanced tree for windows added meanwhile")
    func passthroughRebuildsBalancedTree() {
        var config = E.baseConfig()
        config.layout.arrange = .balanced
        var engine = E.makeEngine(config: config)
        for id: WindowID in 1...2 { _ = engine.addWindow(id, pid: Int32(id), facts: WindowFacts(), space: 1) }
        _ = engine.setPassthrough(true)
        for id: WindowID in 3...4 { _ = engine.addWindow(id, pid: Int32(id), facts: WindowFacts(), space: 1) }
        _ = engine.setPassthrough(false)
        let state = engine.spaces[1]!
        #expect(state.tree == engine.idealTree(state.idealOrder, on: 1, decks: state.decks))
    }

    @Test("a restored arrangement survives the next window event")
    func adoptedArrangementSurvivesNewWindow() {
        var config = E.baseConfig()
        config.rules = [AppRule(match: RuleMatch(appID: "heavy"), actions: RuleActions(weight: 8))]
        let heavy = WindowFacts(bundleID: "heavy")

        var last = E.makeEngine(config: config)
        _ = last.addWindow(1, pid: 1, facts: heavy, space: 1)
        _ = last.addWindow(2, pid: 2, facts: WindowFacts(), space: 1)
        _ = last.addWindow(3, pid: 3, facts: WindowFacts(), space: 1)
        _ = last.focus(2)
        _ = last.perform(.promote, space: 1, areas: E.areas)
        let seeds = last.layout(space: 1, area: E.area).frames

        var engine = E.makeEngine(config: config)
        _ = engine.addWindow(3, pid: 3, facts: WindowFacts(), space: 1)
        _ = engine.addWindow(1, pid: 1, facts: heavy, space: 1)
        _ = engine.addWindow(2, pid: 2, facts: WindowFacts(), space: 1)
        _ = engine.adoptArrangement(1, area: E.area, frames: seeds)
        #expect(engine.spaces[1]!.manual)
        #expect(engine.spaces[1]!.liveOrder.first == 2)

        _ = engine.addWindow(4, pid: 4, facts: WindowFacts(), space: 1)
        #expect(engine.spaces[1]!.liveOrder.first == 2)
    }

    @Test("a tree newcomer never lands inside a multi-tile feature", arguments: [Arrangement.dwindle, .balanced])
    func newcomerStaysOutOfFeature(arrange: Arrangement) {
        var config = E.baseConfig()
        config.layout.arrange = arrange
        config.layout.featureCount = 2
        var engine = E.makeEngine(config: config)
        for id: WindowID in 1...3 { _ = engine.addWindow(id, pid: Int32(id), facts: WindowFacts(), space: 1) }
        if arrange == .balanced {
            _ = engine.focus(1)
            _ = engine.perform(.swap(.right), space: 1, areas: E.areas)
            #expect(engine.spaces[1]!.manual)
        }
        let head = Array(engine.spaces[1]!.tree!.leaves.prefix(2))
        _ = engine.focus(head[0])
        _ = engine.addWindow(4, pid: 4, facts: WindowFacts(), space: 1)
        #expect(Array(engine.spaces[1]!.tree!.leaves.prefix(2)) == head)
    }

    @Test("removing the frontmost window clears the pointer")
    func frontmostClearedOnRemoval() {
        var engine = E.makeEngine()
        _ = engine.addWindow(1, pid: 1, facts: WindowFacts(), space: 1)
        _ = engine.focus(1)
        _ = engine.removeWindow(1)
        #expect(engine.frontmost == nil)
    }

    @Test("a window a new rule stops managing loses focus")
    func focusClearedWhenUnmanaged() {
        var engine = E.makeEngine()
        _ = engine.addWindow(1, pid: 1, facts: WindowFacts(bundleID: "x"), space: 1)
        _ = engine.addWindow(2, pid: 2, facts: WindowFacts(), space: 1)
        _ = engine.focus(1)
        var config = E.baseConfig()
        config.rules = [AppRule(match: RuleMatch(appID: "x"), actions: RuleActions(manage: false))]
        _ = engine.applyConfig(config)
        #expect(engine.focused == nil)
        #expect(engine.perform(.sendToDisplay(.next), space: 1, areas: E.areas).action == nil)
    }
}
