import CoreGraphics
import Foundation

/// One tracked window.
public struct WindowRecord: Equatable, Sendable {
    public let id: WindowID
    public var pid: Int32
    public var facts: WindowFacts
    public var rule: ResolvedRule
    public var space: SpaceID?
    /// Monotonic creation order (engine-assigned).
    public let creation: UInt64
    public var floatOverride: Bool?
    public var minimized = false
    /// Set via `Engine.setHidden`, tracking NSWorkspace hide/unhide notifications.
    /// Independent of `minimized`: hiding an app must not disturb minimized
    /// state, and vice versa.
    public var hidden = false
    /// Minimum size learned from AX refusals (never shrunk below this).
    public var minSize: CGSize = .zero

    /// Sticky windows cannot be pinned to every Space without SIP changes, so
    /// they are treated as floating everywhere (best effort, documented).
    public var isFloating: Bool { floatOverride ?? (rule.float || rule.sticky) }
    public var isManaged: Bool { rule.manage }
}

/// Live, per-physical-Space state. Keyed by `SpaceID` (session identity), so
/// it follows the real Space even when a sibling is deleted and ordinals
/// shift; config defaults are looked up through the Space's *current*
/// `SpaceKey`.
public struct SpaceState: Equatable, Sendable {
    public let id: SpaceID
    /// Mode chosen at runtime; transient until the platform persists it to
    /// the config file and calls `clearSettingOverrides`. Survives config
    /// reloads in the meantime. `nil` = config default.
    public var modeOverride: LayoutMode?
    public var monocle = false
    /// Transient until persisted to the config file (see `modeOverride`).
    public var masterRatioOverride: Double?
    /// Transient until persisted to the config file (see `modeOverride`).
    public var masterCountOverride: Int?
    /// Tiled windows on this Space, in join order.
    public internal(set) var members: [WindowID] = []
    /// Weight-computed ideal arrangement; recomputed on structural changes.
    public internal(set) var idealOrder: [WindowID] = []
    /// True once the user rearranged manually; the ideal is then not applied
    /// until `reset`.
    public internal(set) var manual = false
    /// Live master-stack order while `manual`.
    public internal(set) var manualOrder: [WindowID] = []
    /// Live BSP tree (always maintained, rendered in BSP mode).
    public internal(set) var tree: BSPNode?
    /// Frames adopted from windows that moved themselves (`on_self_move = adopt`).
    public internal(set) var frameOverrides: [WindowID: CGRect] = [:]
    public internal(set) var focus = FocusHistory()

    public init(id: SpaceID) { self.id = id }

    /// Live master-stack order.
    public var liveOrder: [WindowID] { manual ? manualOrder : idealOrder }
}

public struct SpaceLayout: Equatable, Sendable {
    public var mode: LayoutMode
    public var monocle: Bool
    public var frames: [WindowID: CGRect]
    /// Window to raise above its siblings (monocle).
    public var raise: WindowID?
}

/// Side effects the engine cannot perform itself.
public enum PlatformAction: Equatable, Sendable {
    case sendToDisplay(WindowID, Cycle)
    case focusDisplay(Cycle)
    case reload
    case dumpState
}

/// Per-Space settings a command changed instantly, pending persistence to
/// the config file. The platform writes these to disk, then calls
/// `Engine.clearSettingOverrides` so the config becomes the source of
/// truth again instead of the transient runtime override.
public struct SettingsChange: Equatable, Sendable {
    public var space: SpaceID
    /// `nil` = unchanged; `.some(nil)` = remove `mode` (inherit `[layout]`).
    public var mode: LayoutMode??
    public var masterRatio: Double?
    public var masterCount: Int?

    public init(space: SpaceID, mode: LayoutMode?? = nil, masterRatio: Double? = nil, masterCount: Int? = nil) {
        self.space = space
        self.mode = mode
        self.masterRatio = masterRatio
        self.masterCount = masterCount
    }
}

public struct CommandOutcome: Equatable, Sendable {
    public var dirty: Set<SpaceID> = []
    public var focus: WindowID?
    public var action: PlatformAction?
    /// User-facing note when the command could not apply.
    public var message: String?
    /// Set when the command changed a setting that should be written back
    /// to the config file (layout mode, master ratio, master count).
    public var settings: SettingsChange?

    public init() {}
}

public struct WindowRemoval: Equatable, Sendable {
    public var dirty: Set<SpaceID> = []
    /// Most recent remaining window in the closed window's focus history,
    /// when the closed window had focus.
    public var focusFallback: WindowID?
}

/// The whole window-manager model as a value-type state machine: events in,
/// dirty Spaces and frame plans out. No I/O, no clocks, no traps — every entry
/// point tolerates unknown ids, duplicate events and any ordering.
public struct Engine: Sendable {
    public private(set) var config: Config
    public private(set) var snapshot: SpaceSnapshot
    public private(set) var windows: [WindowID: WindowRecord] = [:]
    public private(set) var spaces: [SpaceID: SpaceState] = [:]
    public private(set) var focused: WindowID?
    /// Last focused *tracked* window regardless of `manage`; used to keep
    /// monocle from raising a tiled member over an unmanaged or all-Spaces
    /// window that currently holds keyboard focus.
    public private(set) var frontmost: WindowID?
    /// Stage Manager on: every Space is floating passthrough.
    public var passthrough = false
    private var nextCreation: UInt64 = 0

    public init(config: Config, snapshot: SpaceSnapshot = SpaceSnapshot(displays: [])) {
        self.config = config
        self.snapshot = snapshot
    }

    // MARK: Queries

    public func settings(for space: SpaceID) -> LayoutSettings {
        config.layoutSettings(for: snapshot.key(for: space))
    }

    public func mode(for space: SpaceID) -> LayoutMode {
        if passthrough { return .float }
        return spaces[space]?.modeOverride ?? settings(for: space).mode
    }

    public func isTiled(_ id: WindowID) -> Bool {
        guard let w = windows[id], let space = w.space else { return false }
        return w.isManaged && !w.isFloating && !w.minimized && !w.hidden && !snapshot.isFullscreen(space)
    }

    public func layout(space: SpaceID, area: CGRect) -> SpaceLayout {
        let mode = mode(for: space)
        guard let state = spaces[space], mode != .float else {
            return SpaceLayout(mode: mode, monocle: spaces[space]?.monocle ?? false, frames: [:], raise: nil)
        }
        let s = settings(for: space)
        let inner = area.insetClamped(by: s.gaps.outer)
        let minSize: (WindowID) -> CGSize = { windows[$0]?.minSize ?? .zero }
        var frames: [WindowID: CGRect]
        var raise: WindowID?
        if state.monocle {
            frames = Dictionary(state.members.map { ($0, inner) }, uniquingKeysWith: { a, _ in a })
            // No tiled member may be raised over a focused window that isn't
            // itself a member of this Space (floating, unmanaged, or shared
            // across every Space), even when the layout is recomputed for an
            // unrelated structural change.
            if let frontmost, let fw = windows[frontmost], !state.members.contains(frontmost), fw.space == space || fw.space == nil {
                raise = nil
            } else {
                raise = state.focus.entries.first { state.members.contains($0) } ?? state.liveOrder.first
            }
        } else if mode == .bsp {
            frames = state.tree?.layout(in: inner, context: bspContext(s)) ?? [:]
        } else {
            frames = MasterStackLayout.frames(
                order: state.liveOrder, in: inner,
                masterCount: state.masterCountOverride ?? s.masterCount,
                ratio: state.masterRatioOverride ?? s.masterRatio,
                side: s.stackSide, gap: s.gaps.inner, minSize: minSize)
        }
        if !state.monocle {
            for (id, frame) in state.frameOverrides where frames[id] != nil { frames[id] = frame }
        }
        return SpaceLayout(mode: mode, monocle: state.monocle, frames: frames, raise: raise)
    }

    /// One-shot frame for a newly floating window with a `placement`/`size` rule.
    public func initialFrame(for id: WindowID, current: CGRect, area: CGRect, mouse: CGPoint) -> CGRect? {
        guard let w = windows[id], w.isManaged, w.isFloating else { return nil }
        let size = w.rule.size.map { CGSize(width: area.width * $0.width, height: area.height * $0.height) } ?? current.size
        func clamped(_ r: CGRect) -> CGRect {
            let x = min(max(r.minX, area.minX), max(area.minX, area.maxX - r.width))
            let y = min(max(r.minY, area.minY), max(area.minY, area.maxY - r.height))
            return CGRect(x: x, y: y, width: r.width, height: r.height).integral
        }
        switch w.rule.placement {
        case .center?:
            return clamped(CGRect(x: area.midX - size.width / 2, y: area.midY - size.height / 2, width: size.width, height: size.height))
        case .mouse?:
            return clamped(CGRect(x: mouse.x - size.width / 2, y: mouse.y - size.height / 2, width: size.width, height: size.height))
        case .rect(let x, let y, let fw, let fh)?:
            return CGRect(x: area.minX + area.width * x, y: area.minY + area.height * y,
                          width: area.width * fw, height: area.height * fh).integral
        case nil:
            return w.rule.size == nil ? nil : clamped(CGRect(origin: current.origin, size: size))
        }
    }

    // MARK: Structural events

    /// Adopts a new SkyLight snapshot: drops state for Spaces that no longer
    /// exist and returns Spaces whose config key changed (ordinal shift).
    public mutating func updateSnapshot(_ new: SpaceSnapshot) -> Set<SpaceID> {
        let old = snapshot
        snapshot = new
        let alive = new.userSpaceIDs
        var dirty = Set<SpaceID>()
        for id in Array(spaces.keys) where !alive.contains(id) {
            if let members = spaces[id]?.members {
                for w in members { windows[w]?.space = nil }
            }
            spaces[id] = nil
        }
        for (id, w) in windows where w.space.map({ !alive.contains($0) && !new.isFullscreen($0) }) ?? false {
            windows[id]?.space = nil
        }
        for id in spaces.keys where old.key(for: id) != new.key(for: id) { dirty.insert(id) }
        // Windows now on a fullscreen Space stop tiling.
        for (id, w) in windows {
            if let space = w.space, new.isFullscreen(space) { dirty.formUnion(detach(id, from: space)) }
        }
        return dirty
    }

    public mutating func applyConfig(_ new: Config) -> Set<SpaceID> {
        let oldSplit = Dictionary(uniqueKeysWithValues: spaces.keys.map { ($0, settings(for: $0).split) })
        config = new
        // A changed `split` takes effect on Spaces still in their weight-default
        // arrangement; manually arranged Spaces keep theirs until `reset`.
        for (id, old) in oldSplit where settings(for: id).split != old {
            guard var s = spaces[id], !s.manual else { continue }
            s.tree = s.tree?.withAxis(settings(for: id).split)
            spaces[id] = s
        }
        for id in windows.keys.sorted() {
            guard var w = windows[id] else { continue }
            w.rule = RuleResolver.resolve(w.facts, rules: new.rules)
            windows[id] = w
            syncMembership(id)
        }
        for id in Array(spaces.keys) { recomputeIdeal(id) }
        return Set(spaces.keys)
    }

    public mutating func addWindow(_ id: WindowID, pid: Int32, facts: WindowFacts, space: SpaceID?) -> Set<SpaceID> {
        if windows[id] != nil {
            var dirty = updateFacts(id, facts)
            dirty.formUnion(setSpace(id, space))
            return dirty
        }
        let rule = RuleResolver.resolve(facts, rules: config.rules)
        windows[id] = WindowRecord(id: id, pid: pid, facts: facts, rule: rule, space: space, creation: nextCreation)
        nextCreation &+= 1
        return syncMembership(id)
    }

    /// `hadFocus`: the platform saw focus leave this window moments before it
    /// closed (AppKit picked a successor first); the fallback still applies.
    public mutating func removeWindow(_ id: WindowID, hadFocus: Bool = false) -> WindowRemoval {
        var removal = WindowRemoval()
        guard let w = windows[id] else { return removal }
        if let space = w.space {
            removal.dirty = detach(id, from: space)
            if focused == id || hadFocus {
                removal.focusFallback = spaces[space]?.focus.fallback(excluding: id) { eligibleForFocus($0, on: space) }
            }
            spaces[space]?.focus.remove(id)
        }
        windows[id] = nil
        if focused == id { focused = nil }
        return removal
    }

    public mutating func updateFacts(_ id: WindowID, _ facts: WindowFacts) -> Set<SpaceID> {
        guard var w = windows[id], w.facts != facts else { return [] }
        let before = w.rule
        w.facts = facts
        w.rule = RuleResolver.resolve(facts, rules: config.rules)
        windows[id] = w
        var dirty = syncMembership(id)
        if before.weight != w.rule.weight, let space = w.space, spaces[space]?.members.contains(id) == true {
            recomputeIdeal(space)
            dirty.insert(space)
        }
        return dirty
    }

    /// The window now lives on `space` (nil = unknown / not on a user Space).
    public mutating func setSpace(_ id: WindowID, _ space: SpaceID?) -> Set<SpaceID> {
        guard let w = windows[id], w.space != space else { return [] }
        var dirty = Set<SpaceID>()
        if let old = w.space {
            dirty.formUnion(detach(id, from: old))
            spaces[old]?.focus.remove(id)
        }
        windows[id]?.space = space
        windows[id]?.minSize = .zero
        dirty.formUnion(syncMembership(id))
        if focused == id, let space { spaces[space, default: SpaceState(id: space)].focus.touch(id) }
        return dirty
    }

    public mutating func setMinimized(_ id: WindowID, _ minimized: Bool) -> Set<SpaceID> {
        guard windows[id] != nil, windows[id]?.minimized != minimized else { return [] }
        windows[id]?.minimized = minimized
        return syncMembership(id)
    }

    /// Tracks NSWorkspace app hide/unhide: hidden windows are excluded from
    /// tiling and focus eligibility, independent of `minimized`.
    public mutating func setHidden(_ id: WindowID, _ hidden: Bool) -> Set<SpaceID> {
        guard windows[id] != nil, windows[id]?.hidden != hidden else { return [] }
        windows[id]?.hidden = hidden
        return syncMembership(id)
    }

    /// Records focus. Only dirties a Space whose rendering depends on focus (monocle).
    @discardableResult
    public mutating func focus(_ id: WindowID?) -> Set<SpaceID> {
        guard let id, let w = windows[id] else {
            focused = nil
            frontmost = nil
            return []
        }
        frontmost = id
        guard w.isManaged else {
            focused = nil
            return []
        }
        focused = id
        guard let space = w.space else { return [] }
        spaces[space, default: SpaceState(id: space)].focus.touch(id)
        return spaces[space]?.monocle == true ? [space] : []
    }

    /// A window refused a size: never lay it out smaller than `size` again.
    public mutating func learnMinSize(_ id: WindowID, _ size: CGSize) -> Set<SpaceID> {
        guard var w = windows[id], size.width.isFinite, size.height.isFinite else { return [] }
        let merged = CGSize(width: max(w.minSize.width, size.width), height: max(w.minSize.height, size.height))
        guard merged != w.minSize else { return [] }
        w.minSize = merged
        windows[id] = w
        return w.space.map { [$0] } ?? []
    }

    /// `on_self_move = adopt`: pin the window's own frame as a manual override.
    public mutating func adoptFrame(_ id: WindowID, _ frame: CGRect) -> Set<SpaceID> {
        guard let space = windows[id]?.space, let state = spaces[space], state.members.contains(id), !state.monocle,
              frame.width.isFinite, frame.height.isFinite, frame.minX.isFinite, frame.minY.isFinite else { return [] }
        beginManual(space)
        spaces[space]?.frameOverrides[id] = frame
        return [space]
    }

    // MARK: Commands

    /// Runs a command against `space` (the Space the user is looking at) and
    /// its tiling `area`. Commands that need a window use the focused one.
    public mutating func perform(_ command: Command, space: SpaceID?, area: CGRect?) -> CommandOutcome {
        var out = CommandOutcome()
        let focusedHere = focused.flatMap { windows[$0]?.space == space ? $0 : nil }

        switch command {
        case .reload: out.action = .reload; return out
        case .dumpState: out.action = .dumpState; return out
        case .focusDisplay(let c): out.action = .focusDisplay(c); return out
        case .sendToDisplay(let c):
            guard let f = focused else { out.message = "no focused window"; return out }
            out.action = .sendToDisplay(f, c)
            return out
        default: break
        }

        guard let space else { out.message = "no active Space"; return out }

        switch command {
        case .focus(let direction):
            guard let target = neighbor(of: focusedHere, direction, space: space, area: area) else { return out }
            out.focus = target
        case .swap(let direction):
            guard let f = focusedHere, let target = neighbor(of: f, direction, space: space, area: area) else { return out }
            if swap(f, target, on: space) { out.dirty = [space] }
        case .focusLast:
            guard let current = focusedHere ?? spaces[space]?.focus.mostRecent else { return out }
            out.focus = spaces[space]?.focus.fallback(excluding: current) { eligibleForFocus($0, on: space) }
        case .promote:
            guard let f = focusedHere, let state = spaces[space], state.members.contains(f) else {
                out.message = "focused window is not tiled"
                return out
            }
            let head = mode(for: space) == .bsp ? state.tree?.leaves.first : state.liveOrder.first
            let target = head == f ? (mode(for: space) == .bsp ? state.tree?.leaves.dropFirst().first : state.liveOrder.dropFirst().first) : head
            if let target, swap(f, target, on: space) { out.dirty = [space] }
        case .reset:
            reset(space)
            out.dirty = [space]
        case .layout(let change):
            let current = mode(for: space)
            let all = LayoutMode.allCases
            let index = all.firstIndex(of: current) ?? 0
            switch change {
            case .set(let m):
                spaces[space, default: SpaceState(id: space)].modeOverride = m
                out.settings = SettingsChange(space: space, mode: .some(m))
            case .next:
                let next = all[(index + 1) % all.count]
                spaces[space, default: SpaceState(id: space)].modeOverride = next
                out.settings = SettingsChange(space: space, mode: .some(next))
            case .previous:
                let previous = all[(index + all.count - 1) % all.count]
                spaces[space, default: SpaceState(id: space)].modeOverride = previous
                out.settings = SettingsChange(space: space, mode: .some(previous))
            case .configDefault:
                spaces[space]?.modeOverride = nil
                out.settings = SettingsChange(space: space, mode: .some(nil))
            }
            out.dirty = [space]
        case .monocle:
            spaces[space, default: SpaceState(id: space)].monocle.toggle()
            out.dirty = [space]
        case .toggleFloat:
            guard let f = focusedHere, let w = windows[f], w.isManaged else { out.message = "no focused window"; return out }
            windows[f]?.floatOverride = !w.isFloating
            out.dirty = syncMembership(f).union([space])
        case .resize(let delta):
            guard let f = focusedHere, let state = spaces[space], state.members.contains(f) else { return out }
            if mode(for: space) == .bsp {
                guard case .success(let tree)? = state.tree?.resizing(f, by: delta, context: bspContext(settings(for: space))) else { return out }
                beginManual(space)
                spaces[space]?.tree = tree
            } else {
                let masters = max(state.masterCountOverride ?? settings(for: space).masterCount, 1)
                let isMaster = state.liveOrder.prefix(masters).contains(f)
                let applied = adjustMasterRatio(space, by: isMaster ? delta : -delta)
                out.settings = SettingsChange(space: space, masterRatio: applied)
            }
            out.dirty = [space]
        case .masterRatio(let delta):
            let applied = adjustMasterRatio(space, by: delta)
            out.settings = SettingsChange(space: space, masterRatio: applied)
            out.dirty = [space]
        case .masterCount(let delta):
            let current = min(max(spaces[space]?.masterCountOverride ?? settings(for: space).masterCount, 1), 16)
            let clampedDelta = min(max(delta, -16), 16)
            let applied = min(max(current + clampedDelta, 1), 16)
            spaces[space, default: SpaceState(id: space)].masterCountOverride = applied
            out.settings = SettingsChange(space: space, masterCount: applied)
            out.dirty = [space]
        case .balance:
            if mode(for: space) == .bsp {
                beginManual(space)
                let balanced = spaces[space]?.tree?.balanced()
                spaces[space]?.tree = balanced
            } else {
                spaces[space, default: SpaceState(id: space)].masterRatioOverride = 0.5
                out.settings = SettingsChange(space: space, masterRatio: 0.5)
            }
            out.dirty = [space]
        case .reload, .dumpState, .focusDisplay, .sendToDisplay:
            break
        }
        return out
    }

    /// Swaps two tiled windows on `space` (drag-swap, directional swap, promote).
    /// Pins the Space's arrangement as manual.
    @discardableResult
    public mutating func swap(_ a: WindowID, _ b: WindowID, on space: SpaceID) -> Bool {
        guard a != b, let state = spaces[space], state.members.contains(a), state.members.contains(b) else { return false }
        beginManual(space)
        guard var s = spaces[space] else { return false }
        if let i = s.manualOrder.firstIndex(of: a), let j = s.manualOrder.firstIndex(of: b) {
            s.manualOrder.swapAt(i, j)
        }
        if case .success(let tree)? = s.tree?.swapping(a, b) { s.tree = tree }
        // Adopted frames are position-bound; a swap discards them.
        s.frameOverrides[a] = nil
        s.frameOverrides[b] = nil
        spaces[space] = s
        return true
    }

    /// Rebuilds the BSP tree of a non-manual Space from its weight-ranked
    /// ideal (used when a Space's windows were discovered in arbitrary order).
    /// Touches nothing else; manual Spaces are left alone.
    public mutating func adoptIdealTree(_ space: SpaceID) {
        guard var s = spaces[space], !s.manual else { return }
        s.tree = idealTree(s.idealOrder, on: space)
        spaces[space] = s
    }

    /// Discards every manual override on `space`: order, tree shape, ratios,
    /// adopted frames. Mode and monocle are kept (they are not arrangement).
    public mutating func reset(_ space: SpaceID) {
        guard var s = spaces[space] else { return }
        s.manual = false
        s.manualOrder = []
        s.frameOverrides = [:]
        s.masterRatioOverride = nil
        s.masterCountOverride = nil
        s.tree = idealTree(s.idealOrder, on: space)
        spaces[space] = s
    }

    /// Clears the requested runtime overrides once the platform has
    /// persisted them to the config file, so the config becomes the source
    /// of truth again instead of the transient in-memory override. Safe to
    /// call for an unknown or since-removed Space (no-op).
    public mutating func clearSettingOverrides(_ space: SpaceID, mode: Bool, masterRatio: Bool, masterCount: Bool) {
        guard var s = spaces[space] else { return }
        if mode { s.modeOverride = nil }
        if masterRatio { s.masterRatioOverride = nil }
        if masterCount { s.masterCountOverride = nil }
        spaces[space] = s
    }

    // MARK: Internals

    private func bspContext(_ s: LayoutSettings) -> BSPLayoutContext {
        let windows = self.windows
        return BSPLayoutContext(
            weight: { windows[$0]?.rule.weight ?? 1 },
            minRatio: s.bspMinRatio, maxRatio: s.bspMaxRatio, gap: s.gaps.inner,
            minSize: { windows[$0]?.minSize ?? .zero })
    }

    /// The weight-default BSP tree for `order` in `space`'s configured shape.
    private func idealTree(_ order: [WindowID], on space: SpaceID) -> BSPNode? {
        let s = settings(for: space)
        switch s.bspShape {
        case .dwindle: return BSPNode.ideal(order, axis: s.split)
        case .balanced:
            let windows = self.windows
            return BSPNode.balanced(order, axis: s.split) { windows[$0]?.rule.weight ?? 1 }
        }
    }

    private func eligibleForFocus(_ id: WindowID, on space: SpaceID) -> Bool {
        guard let w = windows[id] else { return false }
        return w.space == space && w.isManaged && !w.minimized && !w.hidden
    }

    @discardableResult
    private mutating func adjustMasterRatio(_ space: SpaceID, by delta: Double) -> Double {
        guard delta.isFinite else { return spaces[space]?.masterRatioOverride ?? settings(for: space).masterRatio }
        let current = spaces[space]?.masterRatioOverride ?? settings(for: space).masterRatio
        // Bounds must match Config's master_ratio validation (0.05…0.95,
        // exclusive); narrower bounds here would clamp an already-valid
        // ratio back into range and silently reverse the requested
        // grow/shrink direction.
        let clamped = min(max(current + delta, 0.05), 0.95)
        spaces[space, default: SpaceState(id: space)].masterRatioOverride = clamped
        return clamped
    }

    private mutating func beginManual(_ space: SpaceID) {
        guard var s = spaces[space], !s.manual else { return }
        s.manual = true
        s.manualOrder = s.idealOrder
        spaces[space] = s
    }

    /// Brings `id`'s Space membership in line with its record. Idempotent.
    @discardableResult
    private mutating func syncMembership(_ id: WindowID) -> Set<SpaceID> {
        var dirty = Set<SpaceID>()
        let target = isTiled(id) ? windows[id]?.space : nil
        for (sid, state) in spaces where sid != target && state.members.contains(id) {
            dirty.formUnion(detach(id, from: sid))
        }
        if let target, spaces[target]?.members.contains(id) != true {
            attach(id, to: target)
            dirty.insert(target)
        }
        return dirty
    }

    private mutating func attach(_ id: WindowID, to space: SpaceID) {
        var s = spaces[space] ?? SpaceState(id: space)
        guard !s.members.contains(id) else { return }
        s.members.append(id)
        let anchor = focused.flatMap { s.tree?.contains($0) == true ? $0 : nil }
            ?? s.focus.entries.first { s.tree?.contains($0) == true }
        let axis = settings(for: space).split
        if let tree = s.tree {
            if case .success(let next) = tree.inserting(id, nextTo: anchor, axis: axis) { s.tree = next }
        } else {
            s.tree = .leaf(id)
        }
        spaces[space] = s
        recomputeIdeal(space)
        guard var m = spaces[space], m.manual else { return }
        // Manual Space: the newcomer joins the stack at its weight rank but
        // never displaces a manually placed master.
        m.manualOrder.removeAll { $0 == id }
        let masters = max(m.masterCountOverride ?? settings(for: space).masterCount, 1)
        let ideal = m.idealOrder
        let rank = ideal.firstIndex(of: id) ?? ideal.count
        let predecessors = Set(ideal.prefix(rank))
        var insertAt = min(masters, m.manualOrder.count)
        for (i, other) in m.manualOrder.enumerated() where predecessors.contains(other) {
            insertAt = max(insertAt, i + 1)
        }
        m.manualOrder.insert(id, at: min(insertAt, m.manualOrder.count))
        spaces[space] = m
    }

    @discardableResult
    private mutating func detach(_ id: WindowID, from space: SpaceID) -> Set<SpaceID> {
        guard var s = spaces[space], s.members.contains(id) else { return [] }
        s.members.removeAll { $0 == id }
        s.manualOrder.removeAll { $0 == id }
        s.frameOverrides[id] = nil
        if let tree = s.tree {
            switch tree.removing(id) {
            case .success(let next): s.tree = next
            case .failure: s.tree = idealTree(s.members, on: space)
            }
        }
        spaces[space] = s
        recomputeIdeal(space)
        return [space]
    }

    private mutating func recomputeIdeal(_ space: SpaceID) {
        guard var s = spaces[space] else { return }
        // Heal any drift between members and the tree (defensive; should not happen).
        let members = s.members.filter { windows[$0] != nil }
        if members != s.members { s.members = members }
        if Set(s.tree?.leaves ?? []) != Set(members) || (s.tree?.leaves.count ?? 0) != members.count {
            s.tree = idealTree(members, on: space)
        }
        let candidates = members.map { id in
            WeightResolver.Candidate(id: id, weight: windows[id]?.rule.weight ?? 1,
                                     focusRank: s.focus.rank(of: id), creation: windows[id]?.creation ?? 0)
        }
        s.idealOrder = WeightResolver.rank(candidates)
        // A balanced Space follows its ideal grid until arranged manually.
        if !s.manual, settings(for: space).bspShape == .balanced {
            s.tree = idealTree(s.idealOrder, on: space)
        }
        if s.manual {
            let kept = s.manualOrder.filter { members.contains($0) }
            let missing = members.filter { !kept.contains($0) }
            s.manualOrder = kept + missing
        }
        spaces[space] = s
    }

    /// Nearest tiled window from `from` in `direction` on `space`. Monocle
    /// Spaces cycle through the live order instead.
    private func neighbor(of from: WindowID?, _ direction: Direction, space: SpaceID, area: CGRect?) -> WindowID? {
        guard let state = spaces[space] else { return nil }
        let order = mode(for: space) == .bsp ? (state.tree?.leaves ?? []) : state.liveOrder
        guard let from, state.members.contains(from) else { return order.first }
        if state.monocle {
            guard let i = order.firstIndex(of: from), !order.isEmpty else { return nil }
            let step = direction.isForward ? 1 : order.count - 1
            let next = order[(i + step) % order.count]
            return next == from ? nil : next
        }
        guard let area else { return nil }
        let frames = layout(space: space, area: area).frames
        guard let origin = frames[from] else { return nil }
        return Self.nearest(from: origin, direction, among: frames.filter { $0.key != from })
    }

    /// Geometric neighbour: candidates entirely beyond `origin`'s edge in the
    /// direction, preferring perpendicular overlap, then edge distance, then
    /// center distance, then id (deterministic).
    static func nearest(from origin: CGRect, _ direction: Direction, among frames: [WindowID: CGRect]) -> WindowID? {
        let tolerance = 4.0
        func beyond(_ r: CGRect) -> Double? {
            switch direction {
            case .left: return r.maxX <= origin.minX + tolerance ? origin.minX - r.maxX : nil
            case .right: return r.minX >= origin.maxX - tolerance ? r.minX - origin.maxX : nil
            case .up: return r.maxY <= origin.minY + tolerance ? origin.minY - r.maxY : nil
            case .down: return r.minY >= origin.maxY - tolerance ? r.minY - origin.maxY : nil
            }
        }
        func overlap(_ r: CGRect) -> Double {
            direction.axis == .horizontal
                ? min(r.maxY, origin.maxY) - max(r.minY, origin.minY)
                : min(r.maxX, origin.maxX) - max(r.minX, origin.minX)
        }
        let scored = frames.compactMap { id, r -> (WindowID, Bool, Double, Double)? in
            guard let d = beyond(r) else { return nil }
            let c = hypot(r.midX - origin.midX, r.midY - origin.midY)
            return (id, overlap(r) > 0, max(0, d), Double(c))
        }
        return scored.min { a, b in
            if a.1 != b.1 { return a.1 }
            if a.2 != b.2 { return a.2 < b.2 }
            if a.3 != b.3 { return a.3 < b.3 }
            return a.0 < b.0
        }?.0
    }
}
