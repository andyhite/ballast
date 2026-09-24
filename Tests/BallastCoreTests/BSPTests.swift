import CoreGraphics
import Testing
@testable import BallastCore

@Suite("BSPNode")
struct BSPTests {

    static func context(weights: [WindowID: Double] = [:], minRatio: Double = 0.05, maxRatio: Double = 0.95,
                         gap: Double = 0, minSizes: [WindowID: CGSize] = [:]) -> BSPLayoutContext {
        BSPLayoutContext(
            weight: { weights[$0] ?? 1 },
            minRatio: minRatio, maxRatio: maxRatio, gap: gap,
            minSize: { minSizes[$0] ?? .zero })
    }

    // MARK: - Ratio derivation

    @Test("split ratio derives from subtree weight sums")
    func weightRatio() {
        let split = BSPSplit(axis: .horizontal, first: .leaf(1), second: .leaf(2))
        let ratio = BSPNode.effectiveRatio(split, weight: { $0 == 1 ? 3 : 1 }, minRatio: 0, maxRatio: 1)
        #expect(abs(ratio - 0.75) < 0.0001)
    }

    @Test("extreme weight ratio clamps to maxRatio")
    func weightRatioClamped() {
        let split = BSPSplit(axis: .horizontal, first: .leaf(1), second: .leaf(2))
        let ratio = BSPNode.effectiveRatio(split, weight: { $0 == 1 ? 10 : 1 }, minRatio: 0.25, maxRatio: 0.75)
        #expect(abs(ratio - 0.75) < 0.0001)
    }

    @Test("nested subtree weight sums combine before ratio")
    func nestedWeightSums() {
        // first = (1,1) summing to 2; second = leaf weight 2 -> 0.5
        let inner = BSPSplit(axis: .vertical, first: .leaf(1), second: .leaf(2))
        let split = BSPSplit(axis: .horizontal, first: .split(inner), second: .leaf(3))
        let ratio = BSPNode.effectiveRatio(split, weight: { $0 == 3 ? 2 : 1 }, minRatio: 0, maxRatio: 1)
        #expect(abs(ratio - 0.5) < 0.0001)
    }

    @Test("layout frame widths reflect weight ratio")
    func layoutWidthsReflectWeight() {
        let tree = BSPNode.split(BSPSplit(axis: .horizontal, first: .leaf(1), second: .leaf(2)))
        let ctx = Self.context(weights: [1: 3, 2: 1], minRatio: 0, maxRatio: 1)
        let rect = CGRect(x: 0, y: 0, width: 400, height: 200)
        let frames = tree.layout(in: rect, context: ctx)
        #expect(abs(frames[1]!.width - 300) < 0.001)
        #expect(abs(frames[2]!.width - 100) < 0.001)
    }

    @Test("manual ratio override wins over weights")
    func manualRatioOverride() {
        var split = BSPSplit(axis: .horizontal, ratio: 0.5, first: .leaf(1), second: .leaf(2))
        let ratio = BSPNode.effectiveRatio(split, weight: { $0 == 1 ? 3 : 1 }, minRatio: 0, maxRatio: 1)
        #expect(abs(ratio - 0.5) < 0.0001)
        split.ratio = nil
        let restored = BSPNode.effectiveRatio(split, weight: { $0 == 1 ? 3 : 1 }, minRatio: 0, maxRatio: 1)
        #expect(abs(restored - 0.75) < 0.0001)
    }

    @Test("clearingRatios drops manual overrides recursively")
    func clearingRatios() {
        let inner = BSPSplit(axis: .vertical, ratio: 0.9, first: .leaf(1), second: .leaf(2))
        let tree = BSPNode.split(BSPSplit(axis: .horizontal, ratio: 0.8, first: .split(inner), second: .leaf(3)))
        let cleared = tree.clearingRatios()
        guard case .split(let outer) = cleared, case .split(let innerCleared) = outer.first else {
            Issue.record("expected split structure")
            return
        }
        #expect(outer.ratio == nil)
        #expect(innerCleared.ratio == nil)
    }

    // MARK: - Construction

    @Test("ideal builds dwindle tree in rank order")
    func idealDwindle() {
        let tree = BSPNode.ideal([1, 2, 3], axis: .horizontal)
        #expect(tree?.leaves == [1, 2, 3])
        // Each new window splits the previously-inserted leaf: leaf(1) then
        // {leaf(2), leaf(3)} nested inside the second child of the root.
        guard case .split(let outer) = tree else {
            Issue.record("expected split")
            return
        }
        #expect(outer.first == .leaf(1))
        guard case .split(let innerSplit) = outer.second else {
            Issue.record("expected inner split")
            return
        }
        #expect(innerSplit.first == .leaf(2))
        #expect(innerSplit.second == .leaf(3))
    }

    @Test("ideal of single element is a leaf; empty is nil")
    func idealEdgeCases() {
        #expect(BSPNode.ideal([1], axis: nil) == .leaf(1))
        #expect(BSPNode.ideal([], axis: nil) == nil)
    }

    // MARK: - Mutation: inserting

    @Test("inserting next to target splits that leaf")
    func insertingSplitsTarget() {
        let tree = BSPNode.leaf(1)
        let result = tree.inserting(2, nextTo: 1, axis: .horizontal)
        guard case .success(let next) = result, case .split(let s) = next else {
            Issue.record("expected success split")
            return
        }
        #expect(s.first == .leaf(1))
        #expect(s.second == .leaf(2))
    }

    @Test("inserting duplicate id fails")
    func insertingDuplicateFails() {
        let tree = BSPNode.leaf(1)
        let result = tree.inserting(1, nextTo: nil, axis: nil)
        #expect(result == .failure(.duplicate(1)))
    }

    @Test("inserting with missing target falls back to last leaf")
    func insertingMissingTargetFallsBack() {
        let tree = BSPNode.ideal([1, 2], axis: .horizontal)!
        let result = tree.inserting(3, nextTo: 99, axis: .horizontal)
        guard case .success(let next) = result else {
            Issue.record("expected success")
            return
        }
        #expect(next.leaves.last == 3)
        #expect(next.contains(2))
    }

    // MARK: - Mutation: removing

    @Test("removing collapses parent, sibling takes its place")
    func removingCollapsesParent() {
        let tree = BSPNode.split(BSPSplit(axis: .horizontal, first: .leaf(1), second: .leaf(2)))
        let result = tree.removing(1)
        #expect(result == .success(.leaf(2)))
    }

    @Test("removing unknown id fails")
    func removingUnknownFails() {
        let tree = BSPNode.leaf(1)
        #expect(tree.removing(99) == .failure(.notFound(99)))
    }

    @Test("removing last leaf empties the tree")
    func removingLastLeaf() {
        let tree = BSPNode.leaf(1)
        #expect(tree.removing(1) == .success(nil))
    }

    // MARK: - Mutation: swapping

    @Test("swapping exchanges two leaves")
    func swappingExchanges() {
        let tree = BSPNode.split(BSPSplit(axis: .horizontal, first: .leaf(1), second: .leaf(2)))
        let result = tree.swapping(1, 2)
        #expect(result == .success(.split(BSPSplit(axis: .horizontal, first: .leaf(2), second: .leaf(1)))))
    }

    @Test("swapping errors on same window")
    func swappingSameWindowErrors() {
        let tree = BSPNode.leaf(1)
        #expect(tree.swapping(1, 1) == .failure(.sameWindow(1)))
    }

    @Test("swapping errors on missing id")
    func swappingMissingErrors() {
        let tree = BSPNode.split(BSPSplit(axis: .horizontal, first: .leaf(1), second: .leaf(2)))
        #expect(tree.swapping(1, 99) == .failure(.notFound(99)))
        #expect(tree.swapping(99, 1) == .failure(.notFound(99)))
    }

    // MARK: - Min-size honouring

    @Test("leaf with minSize wider than weighted share still gets its min width")
    func minSizeHonoured() {
        let tree = BSPNode.split(BSPSplit(axis: .horizontal, first: .leaf(1), second: .leaf(2)))
        // Weight would give leaf 1 only 10% of 400 = 40pt, but its min is 150.
        let ctx = Self.context(weights: [1: 1, 2: 9], minRatio: 0, maxRatio: 1, minSizes: [1: CGSize(width: 150, height: 0)])
        let rect = CGRect(x: 0, y: 0, width: 400, height: 200)
        let frames = tree.layout(in: rect, context: ctx)
        #expect(frames[1]!.width >= 149.99)
        #expect(frames[1]!.width + frames[2]!.width <= 400.0001)
    }

    @Test("nested automatic-axis split reserves feasible subtree minima instead of splitting evenly")
    func nestedAutoAxisMinimumFits() {
        // ideal([1,2,3], axis: nil) dwindles into split(leaf(1), split(leaf(2), leaf(3))).
        let tree = BSPNode.ideal([1, 2, 3], axis: nil)!
        let ctx = Self.context(
            weights: [1: 1, 2: 1, 3: 1], minRatio: 0.25, maxRatio: 0.75, gap: 8,
            minSizes: [2: CGSize(width: 800, height: 1039), 3: CGSize(width: 800, height: 1039)])
        let rect = CGRect(x: 0, y: 0, width: 1904, height: 1039)
        let frames = tree.layout(in: rect, context: ctx)
        // 288 | 800 | 800 (with 8pt gaps) fits the rect; an even three-way
        // split (~628 each) would starve windows 2 and 3 below their minimum.
        #expect(abs(frames[1]!.width - 288) < 0.001)
        #expect(abs(frames[2]!.width - 800) < 0.001)
        #expect(abs(frames[3]!.width - 800) < 0.001)
        #expect(frames[2]!.width >= 799.999)
        #expect(frames[3]!.width >= 799.999)
    }

    @Test("nested automatic-axis split fits minima even when the naive pre-adjustment rect misleads aspect")
    func nestedAutoAxisMinimumFitsDespiteSkewedWeights() {
        // Same geometry and mins as nestedAutoAxisMinimumFits, but leaf 1's
        // weight (10 vs 1s) drives a much larger naive ratio (.75, clamped
        // from the raw weight ratio). The naive pre-adjustment width handed
        // to the inner split is then only ~474pt (portrait against the
        // 1039pt height), which would wrongly resolve the inner split to a
        // vertical stack that cannot fit either window's 1039pt minimum
        // height. The feasible layout is still 288 | 800 | 800, horizontal
        // throughout, because splitting height (an exactly known dimension,
        // never estimated by an ancestor) provably cannot fit two 1039pt
        // minimums into 1039pt available.
        let tree = BSPNode.ideal([1, 2, 3], axis: nil)!
        let ctx = Self.context(
            weights: [1: 10, 2: 1, 3: 1], minRatio: 0.25, maxRatio: 0.75, gap: 8,
            minSizes: [2: CGSize(width: 800, height: 1039), 3: CGSize(width: 800, height: 1039)])
        let rect = CGRect(x: 0, y: 0, width: 1904, height: 1039)
        let frames = tree.layout(in: rect, context: ctx)
        #expect(abs(frames[1]!.width - 288) < 0.001)
        #expect(abs(frames[2]!.width - 800) < 0.001)
        #expect(abs(frames[3]!.width - 800) < 0.001)
        #expect(frames[2]!.height >= 1038.999)
        #expect(frames[3]!.height >= 1038.999)
    }



    // MARK: - Balance

    @Test("balanced pins splits to leaf-count share, equalizing leaf areas")
    func balancedPinsRatios() {
        let tree = BSPNode.split(BSPSplit(axis: .horizontal, first: .leaf(1), second: .leaf(2)))
        let balanced = tree.balanced()
        let rect = CGRect(x: 0, y: 0, width: 400, height: 200)
        // Despite drastically unequal weights, balanced() forces an even split
        // for a two-leaf tree (1 leaf vs 1 leaf).
        let ctx = Self.context(weights: [1: 100, 2: 1], minRatio: 0, maxRatio: 1)
        let frames = balanced.layout(in: rect, context: ctx)
        #expect(abs(frames[1]!.width - frames[2]!.width) < 0.001)

        // Recursively: a 3-leaf dwindle tree balances to equal leaf areas,
        // not a fixed 0.5 at every level. `split` rounds the first length to
        // whole points, so allow one point of rounding along the longer side.
        let slack = max(rect.width, rect.height)
        let deeper = BSPNode.ideal([1, 2, 3], axis: .horizontal)!.balanced()
        let deeperFrames = deeper.layout(in: rect, context: Self.context(minRatio: 0, maxRatio: 1))
        let area1 = deeperFrames[1]!.width * deeperFrames[1]!.height
        let area2 = deeperFrames[2]!.width * deeperFrames[2]!.height
        let area3 = deeperFrames[3]!.width * deeperFrames[3]!.height
        #expect(abs(area1 - area2) <= slack)
        #expect(abs(area2 - area3) <= slack)

        // 4-leaf dwindle: still equal areas across all leaves.
        let quad = BSPNode.ideal([1, 2, 3, 4], axis: .horizontal)!.balanced()
        let quadFrames = quad.layout(in: rect, context: Self.context(minRatio: 0, maxRatio: 1))
        let quadAreas = [1, 2, 3, 4].map { quadFrames[$0]!.width * quadFrames[$0]!.height }
        for area in quadAreas.dropFirst() {
            #expect(abs(area - quadAreas[0]) <= slack)
        }
    }

    // MARK: - Resizing

    @Test("resizing pins manual ratio adjusted by delta")
    func resizingPinsRatio() {
        let tree = BSPNode.split(BSPSplit(axis: .horizontal, first: .leaf(1), second: .leaf(2)))
        let ctx = Self.context(minRatio: 0, maxRatio: 1)
        let result = tree.resizing(1, by: 0.1, context: ctx)
        guard case .success(let next) = result, case .split(let s) = next else {
            Issue.record("expected split")
            return
        }
        #expect(abs((s.ratio ?? 0) - 0.6) < 0.0001)
    }

    @Test("growing at the configured max ratio never reverses direction")
    func resizingGrowNeverReversesAtBoundary() {
        // Weights 40:1 derive a raw ratio of ~0.9756, clamped to maxRatio 0.97.
        // A subsequent grow must stay at (or above) that clamped ratio, never
        // fall back to a hardcoded 0.95 bound below it.
        let tree = BSPNode.split(BSPSplit(axis: .horizontal, first: .leaf(1), second: .leaf(2)))
        let ctx = Self.context(weights: [1: 40, 2: 1], minRatio: 0.02, maxRatio: 0.97)
        let before = BSPNode.effectiveRatio(
            { if case .split(let s) = tree { return s }; fatalError() }(),
            weight: ctx.weight, minRatio: ctx.minRatio, maxRatio: ctx.maxRatio)
        #expect(abs(before - 0.97) < 0.0001)
        let result = tree.resizing(1, by: 0.1, context: ctx)
        guard case .success(let next) = result, case .split(let s) = next else {
            Issue.record("expected split")
            return
        }
        #expect((s.ratio ?? 0) >= before - 0.0001)
        #expect(abs((s.ratio ?? 0) - 0.97) < 0.0001)
    }

    @Test("shrinking at the configured min ratio mirrors the max-ratio boundary")
    func resizingShrinkNeverReversesAtBoundary() {
        let tree = BSPNode.split(BSPSplit(axis: .horizontal, first: .leaf(1), second: .leaf(2)))
        let ctx = Self.context(weights: [1: 1, 2: 80], minRatio: 0.02, maxRatio: 0.97)
        let before = BSPNode.effectiveRatio(
            { if case .split(let s) = tree { return s }; fatalError() }(),
            weight: ctx.weight, minRatio: ctx.minRatio, maxRatio: ctx.maxRatio)
        #expect(abs(before - 0.02) < 0.0001)
        let result = tree.resizing(1, by: -0.1, context: ctx)
        guard case .success(let next) = result, case .split(let s) = next else {
            Issue.record("expected split")
            return
        }
        #expect((s.ratio ?? 1) <= before + 0.0001)
        #expect(abs((s.ratio ?? 1) - 0.02) < 0.0001)
    }

    @Test("resizing root leaf errors")
    func resizingRootErrors() {
        let tree = BSPNode.leaf(1)
        let ctx = Self.context()
        #expect(tree.resizing(1, by: 0.1, context: ctx) == .failure(.isRoot(1)))
    }

    @Test("resizing unknown id errors")
    func resizingUnknownErrors() {
        let tree = BSPNode.split(BSPSplit(axis: .horizontal, first: .leaf(1), second: .leaf(2)))
        let ctx = Self.context()
        #expect(tree.resizing(99, by: 0.1, context: ctx) == .failure(.notFound(99)))
    }

    @Test("resizing the second child shrinks its share, not the first's")
    func resizingSecondChildDirection() {
        let tree = BSPNode.split(BSPSplit(axis: .horizontal, first: .leaf(1), second: .leaf(2)))
        let ctx = Self.context(minRatio: 0, maxRatio: 1)
        let result = tree.resizing(2, by: 0.1, context: ctx)
        guard case .success(let next) = result, case .split(let s) = next else {
            Issue.record("expected split")
            return
        }
        // Growing leaf 2 (the second child) by 0.1 shrinks the first's share
        // by 0.1: from 0.5 to 0.4.
        #expect(abs((s.ratio ?? 0) - 0.4) < 0.0001)
    }

    @Test("resizing a nested leaf pins only its own parent split, not the root")
    func resizingNestedLeafPinsOwnParentOnly() {
        // ideal([1,2,3], axis: .horizontal) dwindles into
        // split(leaf(1), split(leaf(2), leaf(3))).
        let tree = BSPNode.ideal([1, 2, 3], axis: .horizontal)!
        let ctx = Self.context(minRatio: 0, maxRatio: 1)
        let result = tree.resizing(3, by: 0.1, context: ctx)
        guard case .success(let next) = result, case .split(let root) = next,
              case .split(let inner) = root.second else {
            Issue.record("expected nested split")
            return
        }
        #expect(root.ratio == nil)
        #expect(abs((inner.ratio ?? 0) - 0.4) < 0.0001)
    }

    @Test("infeasible minimums degrade to proportional sizing")
    func infeasibleMinimumsDegradeProportionally() {
        let tree = BSPNode.split(BSPSplit(axis: .horizontal, first: .leaf(1), second: .leaf(2)))
        let ctx = Self.context(
            minRatio: 0, maxRatio: 1, gap: 0,
            minSizes: [1: CGSize(width: 300, height: 0), 2: CGSize(width: 300, height: 0)])
        let rect = CGRect(x: 0, y: 0, width: 400, height: 200)
        let frames = tree.layout(in: rect, context: ctx)
        #expect(abs(frames[1]!.width - 200) < 0.001)
        #expect(abs(frames[2]!.width - 200) < 0.001)
    }

    @Test("manual ratio outside bounds clamps to maxRatio")
    func manualRatioClampsToMaxRatio() {
        let tree = BSPNode.split(BSPSplit(axis: .horizontal, ratio: 0.99, first: .leaf(1), second: .leaf(2)))
        let ctx = Self.context(minRatio: 0.25, maxRatio: 0.75)
        let rect = CGRect(x: 0, y: 0, width: 400, height: 200)
        let frames = tree.layout(in: rect, context: ctx)
        #expect(abs(frames[1]!.width - 300) < 0.001)
        #expect(abs(frames[2]!.width - 100) < 0.001)
    }

    @Test("NaN manual ratio falls back to weight-derived split")
    func nanManualRatioFallsBackToWeights() {
        let tree = BSPNode.split(BSPSplit(axis: .horizontal, ratio: .nan, first: .leaf(1), second: .leaf(2)))
        let ctx = Self.context(weights: [1: 3, 2: 1], minRatio: 0, maxRatio: 1)
        let rect = CGRect(x: 0, y: 0, width: 400, height: 200)
        let frames = tree.layout(in: rect, context: ctx)
        #expect(abs(frames[1]!.width - 300) < 0.001)
        #expect(abs(frames[2]!.width - 100) < 0.001)
    }

    @Test("automatic axis on a portrait rect resolves to vertical and stacks full-width frames")
    func automaticAxisResolvesVerticalOnPortraitRect() {
        let tree = BSPNode.ideal([1, 2, 3], axis: nil)!
        let ctx = Self.context(gap: 8)
        let rect = CGRect(x: 0, y: 0, width: 400, height: 800)
        let frames = tree.layout(in: rect, context: ctx)
        for id in [1, 2, 3] as [WindowID] {
            #expect(abs(frames[id]!.width - 400) < 0.001)
        }
        #expect(abs(frames[2]!.minY - (frames[1]!.maxY + 8)) < 0.001)
    }

    @Test("removing a leaf whose sibling is a split promotes the sibling with its axis and ratio intact")
    func removingPromotesSplitSiblingIntact() {
        let inner = BSPSplit(axis: .vertical, ratio: 0.7, first: .leaf(2), second: .leaf(3))
        let tree = BSPNode.split(BSPSplit(axis: .horizontal, first: .leaf(1), second: .split(inner)))
        let result = tree.removing(1)
        #expect(result == .success(.split(inner)))
    }

    @Test("balanced tree: four equal-weight windows on a wide rect are quarters in rank order")
    func balancedFourEqualIsQuarters() {
        let tree = BSPNode.balanced([1, 2, 3, 4], axis: nil) { _ in 1 }!
        let frames = tree.layout(in: CGRect(x: 0, y: 0, width: 1600, height: 1000), context: Self.context())
        let expected: [WindowID: CGRect] = [
            1: CGRect(x: 0, y: 0, width: 800, height: 500), 2: CGRect(x: 0, y: 500, width: 800, height: 500),
            3: CGRect(x: 800, y: 0, width: 800, height: 500), 4: CGRect(x: 800, y: 500, width: 800, height: 500),
        ]
        for (id, rect) in expected {
            #expect(frames[id].map { $0.equalTo(rect) } == true, "window \(id): \(String(describing: frames[id]))")
        }
    }

    @Test("balanced tree cuts at the weight midpoint; ties give the heaviest-ranked side fewer windows")
    func balancedCutsAtWeightMidpoint() {
        let leaves = { (tree: BSPNode?) -> [[WindowID]] in
            guard case .split(let s)? = tree else { return [] }
            return [s.first.leaves, s.second.leaves]
        }
        // Heavy window alone on one side; the two light ones share the other.
        #expect(leaves(BSPNode.balanced([1, 2, 3], axis: nil) { $0 == 1 ? 10 : 1 }) == [[1], [2, 3]])
        // Equal weights, odd count: 1.5 is equally far from 1 and 2 → smaller first side.
        #expect(leaves(BSPNode.balanced([1, 2, 3], axis: nil) { _ in 1 }) == [[1], [2, 3]])
        #expect(leaves(BSPNode.balanced([1, 2, 3, 4, 5], axis: nil) { _ in 1 }) == [[1, 2], [3, 4, 5]])
        // Weights 3,1,1,1: running sums 3,4,5 vs half 3 → cut after the first.
        #expect(leaves(BSPNode.balanced([1, 2, 3, 4], axis: nil) { $0 == 1 ? 3 : 1 }) == [[1], [2, 3, 4]])
        #expect(BSPNode.balanced([], axis: nil) { _ in 1 } == nil)
        #expect(BSPNode.balanced([7], axis: nil) { _ in 1 } == .leaf(7))
    }
}
