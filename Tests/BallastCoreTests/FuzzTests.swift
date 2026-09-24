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

    static func snapshotFull() -> SpaceSnapshot {
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

    /// A Space is deleted (space 2 dropped) relative to `snapshotFull`.
    static func snapshotSpaceDeleted() -> SpaceSnapshot {
        let a = DisplaySpaces(displayUUID: displayA, spaces: [
            SpaceInfo(id: 1, uuid: "a1", kind: .user),
            SpaceInfo(id: 3, uuid: "a3", kind: .fullscreen),
        ], activeSpace: 1)
        let b = DisplaySpaces(displayUUID: displayB, spaces: [
            SpaceInfo(id: 4, uuid: "b1", kind: .user),
            SpaceInfo(id: 5, uuid: "b2", kind: .user),
            SpaceInfo(id: 6, uuid: "b3", kind: .fullscreen),
        ], activeSpace: 4)
        return SpaceSnapshot(displays: [a, b])
    }

    /// Display B unplugged relative to `snapshotFull`.
    static func snapshotDisplayUnplugged() -> SpaceSnapshot {
        let a = DisplaySpaces(displayUUID: displayA, spaces: [
            SpaceInfo(id: 1, uuid: "a1", kind: .user),
            SpaceInfo(id: 2, uuid: "a2", kind: .user),
            SpaceInfo(id: 3, uuid: "a3", kind: .fullscreen),
        ], activeSpace: 1)
        return SpaceSnapshot(displays: [a])
    }

    static let allSpaceIDs: [SpaceID] = [1, 2, 3, 4, 5, 6]
    static let knownAppIDs = ["com.a.app", "com.b.app", "com.ghostty.app", "com.tinyspeck.slackmacgap"]

    static func configA() -> Config {
        var config = Config()
        config.rules = [
            AppRule(match: RuleMatch(appID: "com.ghostty.app"), actions: RuleActions(weight: 8)),
            AppRule(match: RuleMatch(appID: "com.tinyspeck.slackmacgap"), actions: RuleActions(weight: 0.5)),
        ]
        return config
    }

    static func configB() -> Config {
        var config = Config()
        config.layout.mode = .bsp
        config.rules = [
            AppRule(match: RuleMatch(appID: "com.a.app"), actions: RuleActions(weight: 3)),
        ]
        return config
    }

    static func randomFacts(_ rng: inout SplitMix64) -> WindowFacts {
        let bundle = knownAppIDs.randomElement(using: &rng)
        let isDialog = Bool.random(using: &rng) && Double.random(in: 0...1, using: &rng) < 0.15
        return WindowFacts(
            bundleID: bundle,
            appName: bundle,
            title: "Window \(rng.next() % 5)",
            role: "AXWindow",
            subrole: isDialog ? "AXDialog" : "AXStandardWindow")
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
        let direction = [Direction.left, .right, .up, .down].randomElement(using: &rng)!
        let cycle: Cycle = Bool.random(using: &rng) ? .next : .prev
        switch rng.next() % 15 {
        case 0: return .focus(direction)
        case 1: return .swap(direction)
        case 2: return .focusLast
        case 3: return .promote
        case 4: return .reset
        case 5: return .layout([.set(.masterStack), .set(.bsp), .set(.float), .next, .previous, .configDefault].randomElement(using: &rng)!)
        case 6: return .monocle
        case 7: return .toggleFloat
        case 8: return .resize(Double(Int(rng.next() % 21) - 10) / 20)
        case 9: return .masterRatio(Double(Int(rng.next() % 21) - 10) / 20)
        case 10: return .masterCount(Int(rng.next() % 7) - 3)
        case 11: return .balance
        case 12: return .sendToDisplay(cycle)
        case 13: return .focusMaster
        default: return .focusDisplay(cycle)
        }
    }

    /// Verifies every documented Engine invariant after a mutation.
    static func assertInvariants(_ engine: Engine, seed: UInt64, step: Int) {
        for (spaceID, state) in engine.spaces {
            // Members unique.
            #expect(Set(state.members).count == state.members.count, "seed \(seed) step \(step): duplicate members on space \(spaceID)")

            // Tree leaves == members, leaves unique.
            if let tree = state.tree {
                let leaves = tree.leaves
                #expect(Set(leaves).count == leaves.count, "seed \(seed) step \(step): duplicate tree leaves on space \(spaceID)")
                #expect(Set(leaves) == Set(state.members), "seed \(seed) step \(step): tree leaves != members on space \(spaceID)")
            } else {
                #expect(state.members.isEmpty, "seed \(seed) step \(step): nil tree but non-empty members on space \(spaceID)")
            }

            // idealOrder set == members.
            #expect(Set(state.idealOrder) == Set(state.members), "seed \(seed) step \(step): idealOrder != members on space \(spaceID)")

            // manualOrder set == members, no dups, when manual.
            if state.manual {
                #expect(Set(state.manualOrder).count == state.manualOrder.count, "seed \(seed) step \(step): duplicate manualOrder on space \(spaceID)")
                #expect(Set(state.manualOrder) == Set(state.members), "seed \(seed) step \(step): manualOrder != members on space \(spaceID)")
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
                if layout.mode != .float {
                    #expect(Set(frames.keys) == Set(state.members),
                            "seed \(seed) step \(step): layout \(layout.mode) frames \(Set(frames.keys)) != members \(Set(state.members)) on space \(spaceID) area \(area)")
                }
                for (id, frame) in frames {
                    #expect(state.members.contains(id), "seed \(seed) step \(step): layout frame for non-member \(id) on space \(spaceID)")
                    #expect(frame.width.isFinite && frame.height.isFinite && frame.minX.isFinite && frame.minY.isFinite,
                            "seed \(seed) step \(step): non-finite frame for \(id)")
                    #expect(frame.size.width >= 0 && frame.size.height >= 0, "seed \(seed) step \(step): negative frame size for \(id)")
                }
                if !layout.monocle && state.frameOverrides.isEmpty {
                    let entries = Array(frames.filter { $0.value.width > 0 && $0.value.height > 0 })
                    for i in 0..<entries.count {
                        for j in (i + 1)..<entries.count {
                            #expect(!entries[i].value.intersects(entries[j].value),
                                    "seed \(seed) step \(step): frames for \(entries[i].key) and \(entries[j].key) intersect on space \(spaceID) area \(area)")
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

    @Test("random operation sequences preserve Engine invariants", arguments: [UInt64(1), 2, 3, 4, 5])
    func randomOperations(seed: UInt64) {
        var rng = SplitMix64(seed: seed)
        var engine = Engine(config: Self.configA())
        _ = engine.updateSnapshot(Self.snapshotFull())
        var knownIDs: [WindowID] = []

        for step in 0..<3000 {
            switch rng.next() % 11 {
            case 0, 1:
                // addWindow: random id incl. duplicates.
                let id: WindowID
                if !knownIDs.isEmpty, rng.next() % 3 == 0 {
                    id = knownIDs.randomElement(using: &rng)!
                } else {
                    id = WindowID(rng.next() % 40)
                    if !knownIDs.contains(id) { knownIDs.append(id) }
                }
                _ = engine.addWindow(id, pid: Int32(id), facts: Self.randomFacts(&rng), space: Self.randomSpace(&rng))
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
                _ = engine.adoptFrame(id, frame)
            case 9:
                switch rng.next() % 3 {
                case 0: _ = engine.applyConfig(Self.configA())
                case 1: _ = engine.applyConfig(Self.configB())
                default: _ = engine.updateSnapshot([Self.snapshotFull(), Self.snapshotSpaceDeleted(), Self.snapshotDisplayUnplugged()].randomElement(using: &rng)!)
                }
            case 10:
                // Draw the command's Space from the focused window's Space
                // most of the time, so focus-dependent commands (swap,
                // promote, resize, toggleFloat, ...) actually land on a
                // tiled member instead of missing on an unrelated Space.
                let focusedSpace = engine.focused.flatMap { engine.windows[$0]?.space }
                let space: SpaceID? = (focusedSpace != nil && rng.next() % 5 != 0) ? focusedSpace : Self.randomSpace(&rng)
                let area = CGRect(x: 0, y: 0, width: 1600, height: 1000)
                _ = engine.perform(Self.randomCommand(&rng), space: space, area: area)
            default: break
            }
            Self.assertInvariants(engine, seed: seed, step: step)
        }
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
