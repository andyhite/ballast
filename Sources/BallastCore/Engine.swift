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
    /// A native tab that another tab of its window group covers. The app keeps
    /// it alive and posts no destruction, so it stays tracked but holds no
    /// tile. Independent of `minimized` and `hidden`.
    public var backgroundTab = false
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
    public var monocle = false
    /// Runtime feature size, transient until the platform persists it to
    /// the config file and calls `clearSettingOverrides`. Survives config
    /// reloads in the meantime. `nil` = config value.
    public var featureSizeOverride: Double?
    /// Transient until persisted to the config file (see `featureSizeOverride`).
    public var featureCountOverride: Int?
    /// Tiled windows on this Space, in join order.
    public internal(set) var members: [WindowID] = []
    /// Number of tiles the layout arranges (a deck counts once).
    public var tileCount: Int { tiles.count }
    /// Decks: windows layered in one tile, keyed by the window holding that
    /// tile — the only one of them the tree and the orders list — each with
    /// all its windows. Never fewer than two windows, no window in two decks.
    public internal(set) var decks: [WindowID: [WindowID]] = [:]
    /// `members` by when each last took focus or joined the Space, most
    /// recent first. The view follows it — a scrolling deck keeps the first
    /// in view, monocle puts it in front — so a window that just opened shows
    /// before focus reaches it, or if focus never does. A window of another
    /// app than a focused tile here joins right behind that tile instead:
    /// nothing can be raised over the active app's window.
    public internal(set) var recentTiles: [WindowID] = []
    /// Weight-computed ideal arrangement; recomputed on structural changes.
    public internal(set) var idealOrder: [WindowID] = []
    /// True once the user rearranged manually; the ideal is then not applied
    /// until `reset`.
    public internal(set) var manual = false
    /// Live tile order while `manual`.
    public internal(set) var manualOrder: [WindowID] = []
    /// Live BSP tree (always maintained, rendered by dwindle and balanced).
    public internal(set) var tree: BSPNode?
    /// Frames adopted from windows that moved themselves (`on_self_move = adopt`).
    public internal(set) var frameOverrides: [WindowID: CGRect] = [:]
    public internal(set) var focus = FocusHistory()

    public init(id: SpaceID) { self.id = id }

    /// Live tile order.
    public var liveOrder: [WindowID] { manual ? manualOrder : idealOrder }
}

public struct SpaceLayout: Equatable, Sendable {
    public var arrangement: Arrangement
    public var monocle: Bool
    public var frames: [WindowID: CGRect]
    /// Window to raise above its siblings: the front window (see
    /// `SpaceState.recentTiles`) of monocle, or of a scrolling deck while
    /// it is in view. Never a window of the focused window's app but the
    /// focused window itself: raising a window makes it its app's focused
    /// window, which steals focus from an active app.
    public var raise: WindowID?
    /// Deck windows tucked behind a tile while the deck scrolls, each with
    /// the strip of it left showing (zero-length when fully hidden).
    public var covered: [WindowID: CGRect] = [:]
    /// Tiles in view that keep a scrolling deck in order, each with
    /// the scrolled-out windows that belong behind it. Leaves out `raise`,
    /// which is raised anyway, and every tile `raise`'s rules forbid.
    public var behind: [WindowID: [WindowID]] = [:]
    /// Windows of a scrolling deck, minus any at a frame of their
    /// own: moving focus through the column slides these along it.
    public var scrolling: Set<WindowID> = []
    /// Positions directional focus and swap move between: `frames`, except
    /// that a scrolling deck's windows continue past either end of the view.
    var navigation: [WindowID: CGRect] = [:]

    /// Tiles in `behind` that a window belonging behind them is in front of,
    /// given the Space's windows front to back: raising these, then `raise`,
    /// puts the deck back in order.
    public func tilesToRaise(frontToBack: [WindowID]) -> [WindowID] {
        var rank: [WindowID: Int] = [:]
        for (index, id) in frontToBack.enumerated() where rank[id] == nil { rank[id] = index }
        return behind.keys.sorted().filter { tile in
            guard let tileRank = rank[tile], let hidden = behind[tile] else { return false }
            return hidden.contains { rank[$0].map { $0 < tileRank } ?? false }
        }
    }
}

/// Side effects the engine cannot perform itself.
public enum PlatformAction: Equatable, Sendable {
    case sendToDisplay(WindowID, Cycle)
    case focusDisplay(Cycle)
    case reload
    /// Re-discover windows and re-send every tile's frame on this Space,
    /// even frames the platform already requested.
    case relayout(SpaceID)
    case dumpState
}

/// Per-Space settings a command changed instantly, pending persistence to
/// the config file. The platform writes these to disk, then calls
/// `Engine.clearSettingOverrides` so the config becomes the source of
/// truth again instead of the transient runtime override.
public struct SettingsChange: Equatable, Sendable {
    public var space: SpaceID
    public var featureSize: Double?
    public var featureCount: Int?

    public init(space: SpaceID, featureSize: Double? = nil, featureCount: Int? = nil) {
        self.space = space
        self.featureSize = featureSize
        self.featureCount = featureCount
    }
}

public struct CommandOutcome: Equatable, Sendable {
    public var dirty: Set<SpaceID> = []
    public var focus: WindowID?
    public var action: PlatformAction?
    /// User-facing note when the command could not apply.
    public var message: String?
    /// Set when the command changed a setting that should be written back
    /// to the config file (feature size, feature count).
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

    /// Effective settings for `space`: built-in defaults for its display's
    /// screen size, `[layout]`, its `[[space]]`, then the runtime feature
    /// size and count a command set but the config file does not hold yet.
    /// Stage Manager passthrough makes every Space `float`.
    public func settings(for space: SpaceID) -> LayoutSettings {
        let key = snapshot.key(for: space)
        var s = config.layoutSettings(for: key, small: key.map { snapshot.isSmall(display: $0.display) } ?? false)
        if let featureSize = spaces[space]?.featureSizeOverride { s.featureSize = featureSize }
        if let featureCount = spaces[space]?.featureCountOverride { s.featureCount = featureCount }
        if passthrough { s.arrange = .float }
        return s
    }

    public func arrangement(for space: SpaceID) -> Arrangement { settings(for: space).arrange }

    /// The menu-bar glyph of `space`'s layout (without the monocle mark).
    public func glyph(for space: SpaceID) -> String { settings(for: space).glyph }

    /// Human description of `space`'s layout, e.g. "Fixed 1×2 with left feature".
    public func layoutDescription(for space: SpaceID) -> String { settings(for: space).summary }

    public func isMonocle(_ space: SpaceID) -> Bool { spaces[space]?.monocle ?? false }

    public func isTiled(_ id: WindowID) -> Bool {
        guard let w = windows[id], let space = w.space else { return false }
        return w.isManaged && !w.isFloating && !w.minimized && !w.hidden && !w.backgroundTab && !snapshot.isFullscreen(space)
    }

    public func layout(space: SpaceID, area: CGRect) -> SpaceLayout {
        let s = settings(for: space)
        guard let state = spaces[space], s.arrange != .float else {
            return SpaceLayout(arrangement: s.arrange, monocle: spaces[space]?.monocle ?? false, frames: [:], raise: nil)
        }
        let inner = area.insetClamped(by: s.gaps.outer)
        let windowMinSize: (WindowID) -> CGSize = { windows[$0]?.minSize ?? .zero }
        let windowWeight: (WindowID) -> Double = { windows[$0]?.rule.weight ?? 1 }
        // No tiled member may be raised over a focused window that isn't
        // itself a member of this Space (floating, unmanaged, or shared
        // across every Space), even when the layout is recomputed for an
        // unrelated structural change.
        let mayRaise = frontmost.map { id in
            state.members.contains(id) || windows[id].map { $0.space != space && $0.space != nil } ?? true
        } ?? true
        // Raising a window makes it its app's focused window: of the focused
        // window's app, only the focused window itself may be raised.
        let raisable: (WindowID) -> Bool = { id in
            guard mayRaise else { return false }
            guard let focused = frontmost, id != focused, let pid = windows[focused]?.pid else { return true }
            return windows[id]?.pid != pid
        }
        let front = state.recentTiles.first
        var result = SpaceLayout(arrangement: s.arrange, monocle: state.monocle, frames: [:], raise: nil)
        var plan: TilePlan
        if state.monocle {
            // One full-area deck of every tiled window.
            plan = DeckLayout.column(state.expanding(tileOrder(state)), in: inner, axis: .vertical, gap: s.gaps.inner,
                                     limit: 1, peek: s.deckPeek, recent: state.recentTiles, weight: windowWeight,
                                     maxWeightRatio: .infinity, minSize: windowMinSize)
        } else {
            plan = tilePlan(state, s, in: inner)
            plan = DeckLayout.expand(plan, decks: state.decks, recent: state.recentTiles, gap: s.gaps.inner,
                                     peek: s.deckPeek, weight: windowWeight, minSize: windowMinSize)
        }
        result.frames = plan.frames
        result.covered = plan.covered
        result.navigation = plan.navigation
        let tucked = plan.behind
        result.scrolling = plan.scrolling
        // Keep the front window in view on top of the ones tucked behind it.
        if !plan.covered.isEmpty, let front, plan.inView.contains(front), raisable(front) {
            result.raise = front
        }
        var pinned = Set<WindowID>()
        if !state.monocle {
            for (id, frame) in state.frameOverrides where result.frames[id] != nil {
                result.frames[id] = frame
                result.navigation[id] = frame
                result.covered[id] = nil
                result.scrolling.remove(id)
                pinned.insert(id)
            }
        }
        // A window at a frame of its own is no part of the deck.
        for (tile, hidden) in tucked where tile != result.raise && !pinned.contains(tile) && raisable(tile) {
            let kept = hidden.filter { !pinned.contains($0) }
            if !kept.isEmpty { result.behind[tile] = kept }
        }
        return result
    }

    /// The feature and grid of a non-monocle Space, one tile per deck (the
    /// layouts see the heaviest and biggest-minimum window of each deck).
    private func tilePlan(_ state: SpaceState, _ s: LayoutSettings, in inner: CGRect) -> TilePlan {
        let order = tileOrder(state)
        let feature = s.effectiveFeature
        let grid: GridKind
        switch s.arrange {
        case .fixed, .float: grid = .fixed(columns: s.gridColumns, limit: s.deckLimit)
        case .adaptive: grid = .adaptive
        case .dwindle, .balanced:
            // The tree lays out the tiles the feature does not take.
            let featured = Set(order.prefix(FeatureLayout.featuredCount(feature: feature, count: s.featureCount, total: order.count)))
            let tree = state.tree?.without(featured)
            let context = bspContext(s, decks: state.decks)
            grid = .custom { rect in
                let frames = tree?.layout(in: rect, context: context) ?? [:]
                return TilePlan(frames: frames, navigation: frames)
            }
        }
        return FeatureLayout.plan(
            order: order, in: inner, feature: feature, featureCount: s.featureCount, size: s.featureSize,
            grid: grid, gap: s.gaps.inner, peek: s.deckPeek, recent: state.recentTileHolders,
            weight: tileWeight(decks: state.decks), maxWeightRatio: s.maxWeightRatio,
            minSize: tileMinSize(decks: state.decks))
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
        let small = { (snapshot: SpaceSnapshot, id: SpaceID) in snapshot.key(for: id).map { snapshot.isSmall(display: $0.display) } }
        for id in spaces.keys where old.key(for: id) != new.key(for: id) || small(old, id) != small(new, id) { dirty.insert(id) }
        // Windows now on a fullscreen Space stop tiling.
        for (id, w) in windows {
            if let space = w.space, new.isFullscreen(space) { dirty.formUnion(detach(id, from: space)) }
        }
        return dirty
    }

    public mutating func applyConfig(_ new: Config) -> Set<SpaceID> {
        let oldSettings = Dictionary(uniqueKeysWithValues: spaces.keys.map { ($0, settings(for: $0)) })
        config = new
        // A changed `split` takes effect on Spaces still in their weight-default
        // arrangement; manually arranged Spaces keep theirs until `reset`.
        var reshaped = Set<SpaceID>()
        for (id, old) in oldSettings {
            let now = settings(for: id)
            guard var s = spaces[id], !s.manual else { continue }
            if now.split != old.split { s.tree = s.tree?.withAxis(now.split) }
            if now.arrange.isTree, old.arrange != now.arrange { reshaped.insert(id) }
            spaces[id] = s
        }
        for id in windows.keys.sorted() {
            guard var w = windows[id] else { continue }
            w.rule = RuleResolver.resolve(w.facts, rules: new.rules)
            windows[id] = w
            syncMembership(id)
        }
        for id in Array(spaces.keys) { recomputeIdeal(id) }
        // Dwindle and balanced differ in their weight-default tree.
        for id in reshaped.sorted() {
            guard var s = spaces[id], !s.manual else { continue }
            s.tree = idealTree(s.idealOrder, on: id, decks: s.decks)
            spaces[id] = s
        }
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

    /// Tracks a native tab going behind (or coming in front of) its group.
    public mutating func setBackgroundTab(_ id: WindowID, _ background: Bool) -> Set<SpaceID> {
        guard windows[id] != nil, windows[id]?.backgroundTab != background else { return [] }
        windows[id]?.backgroundTab = background
        return syncMembership(id)
    }

    /// A tab switch: `shown` comes in front in `hidden`'s place and inherits
    /// its tile, order, and adopted frame, so the arrangement stays put.
    /// `shown` may already be a member (a tab window the platform tracked
    /// before it noticed the switch).
    public mutating func swapTab(hiding hidden: WindowID, showing shown: WindowID) -> Set<SpaceID> {
        guard hidden != shown, windows[hidden] != nil, windows[shown] != nil else { return [] }
        windows[hidden]?.backgroundTab = true
        windows[shown]?.backgroundTab = false
        guard let space = windows[hidden]?.space, windows[shown]?.space == space, isTiled(shown),
              var s = spaces[space], s.members.contains(hidden) else {
            return syncMembership(hidden).union(syncMembership(shown))
        }
        // A tab already in a deck leaves it: it takes `hidden`'s place.
        if s.isDecked(shown) { leaveTile(shown, in: &s, space: space) }
        func inherit(_ ids: inout [WindowID]) {
            ids.removeAll { $0 == shown }
            if let i = ids.firstIndex(of: hidden) { ids[i] = shown }
        }
        inherit(&s.members)
        inherit(&s.recentTiles)
        inherit(&s.idealOrder)
        inherit(&s.manualOrder)
        for (key, list) in s.decks {
            var list = list
            inherit(&list)
            s.decks[key] = nil
            s.decks[key == hidden ? shown : key] = list
        }
        if let tree = s.tree {
            if tree.contains(hidden) {
                if case .success(let next) = tree.substituting(shown, for: hidden) { s.tree = next }
            } else if tree.contains(shown), case .success(.some(let next)) = tree.removing(shown) {
                s.tree = next
            }
        }
        if let frame = s.frameOverrides.removeValue(forKey: hidden) { s.frameOverrides[shown] = frame }
        spaces[space] = s
        recomputeIdeal(space)
        return [space]
    }

    /// Records focus. Only dirties a Space whose rendering depends on focus:
    /// monocle, or a deck that scrolls to keep the focused window in view.
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
        guard var state = spaces[space] else { return [] }
        if let index = state.recentTiles.firstIndex(of: id) {
            state.recentTiles.remove(at: index)
            state.recentTiles.insert(id, at: 0)
            spaces[space] = state
        }
        return state.monocle || deckScrolls(state) || state.isDecked(id) ? [space] : []
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

    /// Runs a command against `space` (the Space the user is looking at).
    /// `areas` holds every display's tiling area (visible frame) by display
    /// UUID: commands lay `space` out in its own display's, and directional
    /// focus with no tile further that way on `space` continues onto the
    /// displays beyond. Commands that need a window use the focused one.
    public mutating func perform(_ command: Command, space: SpaceID?, areas: [String: CGRect]) -> CommandOutcome {
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
        let area = snapshot.key(for: space).flatMap { areas[$0.display] }

        let s = settings(for: space)
        switch command {
        case .focus(let direction):
            let step = neighbor(of: focusedHere, direction, space: space, area: area)
            // No tile further that way on this Space: carry on past its display's edge.
            out.focus = step.target ?? area.flatMap { neighborBeyond(from: step.origin ?? $0, direction, area: $0, areas: areas) }
        case .swap(let direction):
            guard let f = focusedHere, let target = neighbor(of: f, direction, space: space, area: area).target else { return out }
            if swap(f, target, on: space) { out.dirty = [space] }
        case .focusLast:
            guard let current = focusedHere ?? spaces[space]?.focus.mostRecent else { return out }
            out.focus = spaces[space]?.focus.fallback(excluding: current) { eligibleForFocus($0, on: space) }
        case .focusFeature:
            guard s.hasFeature else { out.message = "no feature area in this layout"; return out }
            guard let state = spaces[space], let feature = tileOrder(state).first else { return out }
            // Toggle: from the feature, go back to the window that had focus
            // right before it (recorded predecessor in the focus history).
            let onFeature = focusedHere.map { state.tile(of: $0) == feature } ?? false
            out.focus = onFeature
                ? state.focus.fallback(excluding: focusedHere ?? feature) { state.tile(of: $0) != feature && eligibleForFocus($0, on: space) }
                : state.frontWindow(ofTile: feature)
        case .promote:
            guard let f = focusedHere, let state = spaces[space], state.members.contains(f) else {
                out.message = "focused window is not tiled"
                return out
            }
            let order = tileOrder(state)
            let fTile = state.tile(of: f)
            let target = order.first == fTile ? order.dropFirst().first : order.first
            if let target, swap(f, target, on: space) { out.dirty = [space] }
        case .deck(let direction):
            guard let f = focusedHere, let state = spaces[space], state.members.contains(f) else {
                out.message = "focused window is not tiled"
                return out
            }
            guard s.arrange != .float, !state.monocle else { out.message = "no tiles to deck in this layout"; return out }
            guard let area else { return out }
            let plan = layout(space: space, area: area)
            let frames = plan.navigation
            let own = state.windows(ofTile: state.tile(of: f))
            // Where the focused tile sits: its window showing.
            let showing = own.first { plan.covered[$0] == nil } ?? f
            let origin = frames[showing]
            let others = frames.filter { !own.contains($0.key) }
            guard let origin, let target = Self.nearest(from: origin, direction, among: others) else {
                out.message = "no tile to deck with that way"
                return out
            }
            if joinDeck(f, withTileOf: target, on: space) { out.dirty = [space] }
        case .undeck:
            guard let f = focusedHere, spaces[space]?.isDecked(f) == true else {
                out.message = "focused window is not in a deck"
                return out
            }
            if leaveDeck(f, on: space) { out.dirty = [space] }
        case .reset:
            reset(space)
            out.dirty = [space]
        case .relayout:
            forgetMinSizes(on: space)
            out.dirty = [space]
            out.action = .relayout(space)
        case .monocle:
            spaces[space, default: SpaceState(id: space)].monocle.toggle()
            out.dirty = [space]
        case .toggleFloat:
            guard let f = focusedHere, let w = windows[f], w.isManaged else { out.message = "no focused window"; return out }
            windows[f]?.floatOverride = !w.isFloating
            out.dirty = syncMembership(f).union([space])
        case .resize(let delta):
            guard let f = focusedHere, let state = spaces[space], state.members.contains(f) else { return out }
            let tile = state.tile(of: f)
            let featured = featuredTiles(state, s)
            switch s.arrange {
            case .float:
                out.message = "nothing to resize in float layout"
                return out
            case .dwindle, .balanced:
                if featured.contains(tile) {
                    out.settings = SettingsChange(space: space, featureSize: adjustFeatureSize(space, by: delta))
                } else {
                    let context = bspContext(s, decks: state.decks)
                    guard case .success(let tree)? = state.tree?.resizing(tile, by: delta, context: context,
                                                                          hidden: Set(featured)),
                          tree != state.tree else {
                        out.message = "nothing to resize"
                        return out
                    }
                    beginManual(space)
                    spaces[space]?.tree = tree
                }
            case .fixed, .adaptive:
                guard s.hasFeature else {
                    out.message = "no feature area to resize in this layout"
                    return out
                }
                let applied = adjustFeatureSize(space, by: featured.contains(tile) ? delta : -delta)
                out.settings = SettingsChange(space: space, featureSize: applied)
            }
            out.dirty = [space]
        case .featureSize(let delta):
            let applied = adjustFeatureSize(space, by: delta)
            out.settings = SettingsChange(space: space, featureSize: applied)
            out.dirty = [space]
        case .featureCount(let delta):
            let current = min(max(s.featureCount, 1), 16)
            let clampedDelta = min(max(delta, -16), 16)
            let applied = min(max(current + clampedDelta, 1), 16)
            spaces[space, default: SpaceState(id: space)].featureCountOverride = applied
            out.settings = SettingsChange(space: space, featureCount: applied)
            out.dirty = [space]
        case .balance:
            switch s.arrange {
            case .float:
                out.message = "nothing to balance in float layout"
                return out
            case .dwindle, .balanced:
                beginManual(space)
                let hidden = spaces[space].map { Set(featuredTiles($0, s)) } ?? []
                let balanced = spaces[space]?.tree?.balanced(hiding: hidden)
                spaces[space]?.tree = balanced
            case .fixed, .adaptive:
                guard s.hasFeature else {
                    out.message = "nothing to balance: no feature area in this layout"
                    return out
                }
                spaces[space, default: SpaceState(id: space)].featureSizeOverride = 0.5
                out.settings = SettingsChange(space: space, featureSize: 0.5)
            }
            out.dirty = [space]
        case .reload, .dumpState, .focusDisplay, .sendToDisplay:
            break
        }
        return out
    }

    /// Swaps the tiles of two tiled windows on `space` (drag-swap, directional
    /// swap, promote); two windows of one deck trade places inside it.
    /// Pins the Space's arrangement as manual.
    @discardableResult
    public mutating func swap(_ a: WindowID, _ b: WindowID, on space: SpaceID) -> Bool {
        guard a != b, let state = spaces[space], state.members.contains(a), state.members.contains(b) else { return false }
        beginManual(space)
        guard var s = spaces[space] else { return false }
        let (tileA, tileB) = (s.tile(of: a), s.tile(of: b))
        if tileA == tileB {
            if var list = s.decks[tileA], let i = list.firstIndex(of: a), let j = list.firstIndex(of: b) {
                list.swapAt(i, j)
                s.decks[tileA] = list
            }
            spaces[space] = s
            return true
        }
        if let i = s.manualOrder.firstIndex(of: tileA), let j = s.manualOrder.firstIndex(of: tileB) {
            s.manualOrder.swapAt(i, j)
        }
        if case .success(let tree)? = s.tree?.swapping(tileA, tileB) { s.tree = tree }
        // Adopted frames are position-bound; a swap discards them.
        for id in [a, b, tileA, tileB] { s.frameOverrides[id] = nil }
        spaces[space] = s
        return true
    }

    /// `id` joins the deck of the tile `target` sits in (which becomes a
    /// deck if it was none), leaving its own tile, which closes up. The
    /// joiner shows first. Pins the Space's arrangement as manual.
    private mutating func joinDeck(_ id: WindowID, withTileOf target: WindowID, on space: SpaceID) -> Bool {
        guard let state = spaces[space], state.members.contains(id), state.members.contains(target),
              state.tile(of: id) != state.tile(of: target) else { return false }
        beginManual(space)
        guard var s = spaces[space] else { return false }
        let holder = s.tile(of: target)
        leaveTile(id, in: &s, space: space)
        s.decks[holder] = (s.decks[holder] ?? [holder]) + [id]
        s.frameOverrides[id] = nil
        s.frameOverrides[holder] = nil
        s.recentTiles.removeAll { $0 == id }
        s.recentTiles.insert(id, at: 0)
        spaces[space] = s
        recomputeIdeal(space)
        return true
    }

    /// `id` leaves its deck for a tile of its own right after the deck's:
    /// BSP splits the deck's leaf, order-based layouts insert it after the
    /// deck. Pins the Space's arrangement as manual.
    private mutating func leaveDeck(_ id: WindowID, on space: SpaceID) -> Bool {
        guard spaces[space]?.isDecked(id) == true else { return false }
        beginManual(space)
        guard var s = spaces[space], let anchor = leaveTile(id, in: &s, space: space) else { return false }
        if let tree = s.tree {
            if case .success(let next) = tree.inserting(id, nextTo: anchor, axis: settings(for: space).split) { s.tree = next }
        } else {
            s.tree = .leaf(id)
        }
        func insertAfterDeck(_ ids: inout [WindowID]) {
            ids.removeAll { $0 == id }
            ids.insert(id, at: ids.firstIndex(of: anchor).map { $0 + 1 } ?? ids.count)
        }
        insertAfterDeck(&s.manualOrder)
        insertAfterDeck(&s.idealOrder)
        s.frameOverrides[id] = nil
        s.frameOverrides[anchor] = nil
        spaces[space] = s
        recomputeIdeal(space)
        return true
    }

    /// Rebuilds a non-manual Space's arrangement from where its tiles sit
    /// now (`frames`). After a restart, windows are still where the last run
    /// put them, while discovery finds them in arbitrary order: this
    /// restores the last run's arrangement. Each tile takes the layout slot
    /// nearest its frame; a tree arrangement also reads its BSP shape back
    /// from the frames (`BSPNode.fromFrames`), falling back to the ideal
    /// tree when they fit none. A no-op unless every tile has a frame, and
    /// on manual, monocle and float Spaces.
    public mutating func adoptArrangement(_ space: SpaceID, area: CGRect, frames: [WindowID: CGRect]) -> Set<SpaceID> {
        let s = settings(for: space)
        guard var state = spaces[space], !state.manual, !state.monocle, s.arrange != .float, !state.tiles.isEmpty,
              state.tiles.allSatisfy({ frames[$0] != nil }) else { return [] }
        func distance(_ id: WindowID, _ slot: CGRect) -> Double {
            let f = frames[id] ?? .null
            return abs(f.minX - slot.minX) + abs(f.minY - slot.minY) + abs(f.maxX - slot.maxX) + abs(f.maxY - slot.maxY)
        }
        // ponytail: greedy nearest-slot matching, exact when each window still sits in a slot; optimal assignment if partial overlaps matter.
        let plan = layout(space: space, area: area).frames
        var unplaced = state.tiles
        var order: [WindowID] = []
        for slot in tileOrder(state).compactMap({ plan[$0] }) {
            guard let nearest = unplaced.min(by: { distance($0, slot) < distance($1, slot) }) else { break }
            order.append(nearest)
            unplaced.removeAll { $0 == nearest }
        }
        order += unplaced
        if s.arrange.isTree {
            // Feature tiles sit outside the tree's region: the tree's head, laid out apart from the rest.
            let featured = Array(order.prefix(FeatureLayout.featuredCount(feature: s.effectiveFeature, count: s.featureCount,
                                                                         total: order.count)))
            let rest = order.filter { !featured.contains($0) }
            let grid = BSPNode.fromFrames(rest.map { ($0, frames[$0] ?? .null) }, axis: s.split, context: bspContext(s, decks: state.decks))
                ?? BSPNode.ideal(rest, axis: s.split)
            switch (BSPNode.ideal(featured, axis: s.split), grid) {
            case let (head?, grid?): state.tree = .split(BSPSplit(axis: s.split, first: head, second: grid))
            case let (head, grid): state.tree = head ?? grid
            }
            state.idealOrder = state.tree?.leaves ?? order
        } else {
            state.idealOrder = order
            state.tree = idealTree(order, on: space, decks: state.decks)
        }
        spaces[space] = state
        return [space]
    }

    /// Discards every manual override on `space`: order, tree shape, ratios,
    /// adopted frames. Arrangement settings and monocle are kept.
    public mutating func reset(_ space: SpaceID) {
        guard var s = spaces[space] else { return }
        s.manual = false
        s.manualOrder = []
        s.frameOverrides = [:]
        // Decks are arrangement: every window is a tile of its own again.
        s.decks = [:]
        spaces[space] = s
        recomputeIdeal(space)
        guard var s = spaces[space] else { return }
        s.tree = idealTree(s.idealOrder, on: space, decks: s.decks)
        spaces[space] = s
    }

    /// Forgets the minimum sizes learned on `space`. A refusal can come from
    /// a transient state (an app mid-resize, a frame read before it settled),
    /// and a learned minimum only ever grows, so a stale one squeezes its
    /// siblings until cleared. Windows that really refuse relearn on the next
    /// frame they reject.
    private mutating func forgetMinSizes(on space: SpaceID) {
        for (id, w) in windows where w.space == space && w.minSize != .zero { windows[id]?.minSize = .zero }
    }

    /// Clears the requested runtime overrides once the platform has
    /// persisted them to the config file, so the config becomes the source
    /// of truth again instead of the transient in-memory override. Safe to
    /// call for an unknown or since-removed Space (no-op).
    public mutating func clearSettingOverrides(_ space: SpaceID, featureSize: Bool, featureCount: Bool) {
        guard var s = spaces[space] else { return }
        if featureSize { s.featureSizeOverride = nil }
        if featureCount { s.featureCountOverride = nil }
        spaces[space] = s
    }

    // MARK: Internals

    /// Layout context for the BSP tree, whose leaves are tiles.
    private func bspContext(_ s: LayoutSettings, decks: [WindowID: [WindowID]]) -> BSPLayoutContext {
        BSPLayoutContext(
            weight: tileWeight(decks: decks),
            minRatio: s.weightShareMin, maxRatio: s.weightShareMax, gap: s.gaps.inner,
            minSize: tileMinSize(decks: decks))
    }

    /// A tile's weight: its heaviest window's.
    private func tileWeight(decks: [WindowID: [WindowID]]) -> (WindowID) -> Double {
        let windows = self.windows
        return { id in (decks[id] ?? [id]).map { windows[$0]?.rule.weight ?? 1 }.max() ?? 1 }
    }

    /// A tile's minimum size: the largest of its windows'.
    private func tileMinSize(decks: [WindowID: [WindowID]]) -> (WindowID) -> CGSize {
        let windows = self.windows
        return { id in
            (decks[id] ?? [id]).reduce(CGSize.zero) { size, member in
                let own = windows[member]?.minSize ?? .zero
                return CGSize(width: max(size.width, own.width), height: max(size.height, own.height))
            }
        }
    }

    /// The weight-default BSP tree for the tiles `order` in `space`'s arrangement.
    private func idealTree(_ order: [WindowID], on space: SpaceID, decks: [WindowID: [WindowID]]) -> BSPNode? {
        let s = settings(for: space)
        switch s.arrange {
        case .balanced: return BSPNode.balanced(order, axis: s.split, weight: tileWeight(decks: decks))
        case .dwindle, .fixed, .adaptive, .float: return BSPNode.ideal(order, axis: s.split)
        }
    }

    /// Tiles on a Space in layout order; the head is the feature.
    private func tileOrder(_ state: SpaceState) -> [WindowID] {
        arrangement(for: state.id).isTree ? (state.tree?.leaves ?? []) : state.liveOrder
    }

    /// The tiles the feature area holds: the first `feature_count` in layout order.
    private func featuredTiles(_ state: SpaceState, _ s: LayoutSettings) -> [WindowID] {
        let order = tileOrder(state)
        return Array(order.prefix(FeatureLayout.featuredCount(feature: s.effectiveFeature, count: s.featureCount,
                                                              total: order.count)))
    }

    /// Whether a column of `state`'s grid holds more tiles than it shows at
    /// once, so that moving focus scrolls its deck.
    private func deckScrolls(_ state: SpaceState) -> Bool {
        let s = settings(for: state.id)
        guard s.arrange == .fixed else { return false }
        let featured = FeatureLayout.featuredCount(feature: s.effectiveFeature, count: s.featureCount, total: state.tileCount)
        return FeatureLayout.scrolls(gridCount: state.tileCount - featured, columns: s.gridColumns,
                                     limit: s.deckLimit, center: s.effectiveFeature == .center)
    }

    private func eligibleForFocus(_ id: WindowID, on space: SpaceID) -> Bool {
        guard let w = windows[id] else { return false }
        return w.space == space && w.isManaged && !w.minimized && !w.hidden && !w.backgroundTab
    }

    /// Bounds must stay strictly inside Config's `feature_size` validation
    /// (0.05…0.95, exclusive): landing exactly on 0.05 or 0.95 renders as a
    /// value the config parser then rejects, so the persisted override fails
    /// `Config.validated` and the caller surfaces that error instead of
    /// silently applying it. `ConfigEditor`'s float rendering is a shortest
    /// round-trip representation, so any in-bounds `Double` survives
    /// persistence exactly — only the strict-interior requirement matters.
    /// Only a delta that would actually cross a bound gets clamped, to the
    /// nearest representable value still strictly inside it
    /// (`nextUp`/`nextDown`); an already-valid near-bound ratio is moved by
    /// the full requested delta, so growing near 0.95 or shrinking near 0.05
    /// is never reversed into the opposite direction.
    @discardableResult
    private mutating func adjustFeatureSize(_ space: SpaceID, by delta: Double) -> Double {
        let current = settings(for: space).featureSize
        guard delta.isFinite else { return current }
        let lowerBound = 0.05, upperBound = 0.95
        // Snap to 4 decimals so persisted values read 0.7, not 0.7000000000000001.
        let target = ((current + delta) * 10_000).rounded() / 10_000
        let clamped: Double
        if target <= lowerBound {
            clamped = lowerBound.nextUp
        } else if target >= upperBound {
            clamped = upperBound.nextDown
        } else {
            clamped = target
        }
        spaces[space, default: SpaceState(id: space)].featureSizeOverride = clamped
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
        // Shown first, as though focused, unless a tile here of another app
        // has focus: nothing can be raised over the active app's window.
        var rank = 0
        if let f = focused, let index = s.recentTiles.firstIndex(of: f), windows[f]?.pid != windows[id]?.pid {
            rank = index + 1
        }
        s.recentTiles.insert(id, at: rank)
        let inTree = { (id: WindowID) in s.tree?.contains(id) == true }
        let anchor = focused.map { s.tile(of: $0) }.flatMap { inTree($0) ? $0 : nil }
            ?? s.focus.entries.map { s.tile(of: $0) }.first(where: inTree)
        let axis = settings(for: space).split
        if let tree = s.tree {
            if case .success(let next) = tree.inserting(id, nextTo: anchor, axis: axis) { s.tree = next }
        } else {
            s.tree = .leaf(id)
        }
        spaces[space] = s
        recomputeIdeal(space, newcomer: id)
    }

    @discardableResult
    private mutating func detach(_ id: WindowID, from space: SpaceID) -> Set<SpaceID> {
        guard var s = spaces[space], s.members.contains(id) else { return [] }
        leaveTile(id, in: &s, space: space)
        s.members.removeAll { $0 == id }
        s.recentTiles.removeAll { $0 == id }
        s.frameOverrides[id] = nil
        spaces[space] = s
        recomputeIdeal(space)
        return [space]
    }

    /// Takes `id` out of the tile arrangement (tree, orders, decks) but not
    /// out of the Space's membership. A deck's window just leaves its
    /// deck, and the deck's tile goes to the next member when `id` held
    /// it; a deck left with one window dissolves. A tile of its own closes
    /// up. Returns the tile of the deck `id` left, if it was in one.
    @discardableResult
    private func leaveTile(_ id: WindowID, in s: inout SpaceState, space: SpaceID) -> WindowID? {
        guard let holder = s.decks.first(where: { $0.value.contains(id) })?.key else {
            s.idealOrder.removeAll { $0 == id }
            s.manualOrder.removeAll { $0 == id }
            if let tree = s.tree {
                switch tree.removing(id) {
                case .success(let next): s.tree = next
                case .failure: s.tree = idealTree(s.tiles.filter { $0 != id }, on: space, decks: s.decks)
                }
            }
            return nil
        }
        let list = s.decks[holder] ?? []
        let index = list.firstIndex(of: id) ?? 0
        let rest = list.filter { $0 != id }
        var tile = holder
        if id == holder, !rest.isEmpty {
            // The tile passes to the member that followed.
            tile = rest[min(index, rest.count - 1)]
            func pass(_ ids: inout [WindowID]) { if let i = ids.firstIndex(of: id) { ids[i] = tile } }
            pass(&s.idealOrder)
            pass(&s.manualOrder)
            if let frame = s.frameOverrides.removeValue(forKey: id), s.frameOverrides[tile] == nil { s.frameOverrides[tile] = frame }
            if let tree = s.tree {
                switch tree.substituting(tile, for: id) {
                case .success(let next): s.tree = next
                case .failure: s.tree = idealTree(s.tiles.map { $0 == id ? tile : $0 }, on: space, decks: s.decks)
                }
            }
        }
        s.decks[holder] = nil
        if rest.count >= 2 { s.decks[tile] = rest }
        return tile
    }

    /// Keeps the ideal order stable: windows keep their places, a window
    /// that left is dropped, and the order is re-sorted by weight only (so a
    /// weight change moves just that window). `newcomer`, a window just
    /// attached, goes to the top of the grid.
    private mutating func recomputeIdeal(_ space: SpaceID, newcomer: WindowID? = nil) {
        guard var s = spaces[space] else { return }
        // Heal any drift between members and the tree (defensive; should not happen).
        let members = s.members.filter { windows[$0] != nil }
        if members != s.members {
            s.members = members
            s.recentTiles.removeAll { windows[$0] == nil }
        }
        s.decks = s.healedDecks { windows[$0] != nil }
        let tiles = s.tiles
        if Set(s.tree?.leaves ?? []) != Set(tiles) || (s.tree?.leaves.count ?? 0) != tiles.count {
            s.tree = idealTree(tiles, on: space, decks: s.decks)
        }
        let tileWeight = self.tileWeight(decks: s.decks)
        func weight(_ id: WindowID) -> Double {
            let w = tileWeight(id)
            return w.isFinite ? w : 0
        }
        let tileSet = Set(tiles)
        var seen = Set<WindowID>()
        let kept = s.idealOrder.filter { tileSet.contains($0) && $0 != newcomer && seen.insert($0).inserted }
        let keptSet = Set(kept)
        // Only after drift or a first sighting: members with no place yet join by rank.
        let unplaced = tiles.filter { !keptSet.contains($0) && $0 != newcomer }.map { id in
            WeightResolver.Candidate(id: id, weight: weight(id),
                                     focusRank: s.focus.rank(of: id), creation: windows[id]?.creation ?? 0)
        }
        let base = kept + WeightResolver.rank(unplaced)
        var position: [WindowID: Int] = [:]
        for (i, id) in base.enumerated() where position[id] == nil { position[id] = i }
        s.idealOrder = base.sorted { a, b in
            weight(a) != weight(b) ? weight(a) > weight(b) : (position[a] ?? 0) < (position[b] ?? 0)
        }
        let featureSettings = settings(for: space)
        let featureWindows = featureSettings.hasFeature ? max(featureSettings.featureCount, 1) : 0
        if let newcomer {
            s.idealOrder = placingAtGridTop(newcomer, in: s.idealOrder, featureWindows: featureWindows)
        }
        // A balanced Space follows its ideal grid until arranged manually.
        if !s.manual, featureSettings.arrange == .balanced {
            s.tree = idealTree(s.idealOrder, on: space, decks: s.decks)
        }
        if s.manual {
            let kept = s.manualOrder.filter { tileSet.contains($0) }
            let missing = tiles.filter { !kept.contains($0) }
            s.manualOrder = kept + missing
            // Right after the feature windows: a manually placed feature is never displaced.
            if let newcomer {
                s.manualOrder.removeAll { $0 == newcomer }
                s.manualOrder.insert(newcomer, at: min(featureWindows, s.manualOrder.count))
            }
        }
        spaces[space] = s
    }

    /// Weight-ranked `order` with `id` moved to the top of its weight tier in
    /// the grid: right after the feature windows and every heavier window. A window
    /// heavier than a feature window still takes that window's slot.
    private func placingAtGridTop(_ id: WindowID, in order: [WindowID], featureWindows: Int) -> [WindowID] {
        var order = order
        order.removeAll { $0 == id }
        func weight(_ w: WindowID) -> Double { windows[w]?.rule.weight ?? 1 }
        let own = weight(id)
        let heavier = order.prefix { weight($0) > own }.count
        let takesFeature = heavier < min(featureWindows, order.count) && weight(order[heavier]) < own
        order.insert(id, at: min(takesFeature ? heavier : max(featureWindows, heavier), order.count))
        return order
    }

    /// Nearest tiled window from `from` in `direction` on `space`, along the
    /// scrolling strip when the deck scrolls. Monocle Spaces cycle through
    /// the live order instead. `origin` is the tile the step starts at, when
    /// `from` has one to step from.
    private func neighbor(of from: WindowID?, _ direction: Direction, space: SpaceID,
                          area: CGRect?) -> (target: WindowID?, origin: CGRect?) {
        guard let state = spaces[space] else { return (nil, nil) }
        let order = state.monocle ? state.expanding(tileOrder(state)) : tileOrder(state)
        guard let from, state.members.contains(from) else { return (order.first.map { state.frontWindow(ofTile: $0) }, nil) }
        if state.monocle {
            guard let i = order.firstIndex(of: from), !order.isEmpty else { return (nil, nil) }
            let step = direction.isForward ? 1 : order.count - 1
            let next = order[(i + step) % order.count]
            return (next == from ? nil : next, nil)
        }
        guard let area else { return (nil, nil) }
        let frames = layout(space: space, area: area).navigation
        guard let origin = frames[from] else { return (nil, nil) }
        return (Self.nearest(from: origin, direction, among: frames.filter { $0.key != from }), origin)
    }

    /// Directional focus past the edge of the display whose tiling area is
    /// `area`, leaving from `origin` (the focused tile, else the whole area):
    /// the tile nearest `origin` on the nearest display beyond that edge with
    /// one showing. Displays with nothing to focus are skipped.
    private func neighborBeyond(from origin: CGRect, _ direction: Direction, area: CGRect,
                                areas: [String: CGRect]) -> WindowID? {
        let onDisplay = origin.intersection(area)
        let origin = onDisplay.isEmpty ? area : onDisplay
        let center = CGPoint(x: origin.midX, y: origin.midY)
        // Squared distance from `center` to the nearest point of `r`.
        func reach(_ r: CGRect) -> CGFloat {
            let dx = max(r.minX - center.x, 0, center.x - r.maxX)
            let dy = max(r.minY - center.y, 0, center.y - r.maxY)
            return dx * dx + dy * dy
        }
        let beyond = snapshot.displays.compactMap { display -> (reach: CGFloat, uuid: String, space: SpaceID, area: CGRect)? in
            guard let space = display.activeSpace, let rect = areas[display.displayUUID],
                  Self.gap(from: area, direction, to: rect) != nil else { return nil }
            return (reach(rect), display.displayUUID, space, rect)
        }
        for display in beyond.sorted(by: { ($0.reach, $0.uuid) < ($1.reach, $1.uuid) }) {
            if let id = Self.nearest(from: origin, direction, among: showing(on: display.space, area: display.area)) {
                return id
            }
        }
        return nil
    }

    /// Where focus arriving from another display can land on `space`: its
    /// tiles in full view, or monocle's front window.
    private func showing(on space: SpaceID, area: CGRect) -> [WindowID: CGRect] {
        guard let state = spaces[space] else { return [:] }
        let plan = layout(space: space, area: area)
        guard state.monocle else { return plan.frames.filter { plan.covered[$0.key] == nil } }
        // The window `layout` raises in monocle.
        guard let front = state.recentTiles.first, let frame = plan.frames[front] else { return [:] }
        return [front: frame]
    }

    /// Geometric neighbour: candidates entirely beyond `origin`'s edge in the
    /// direction, preferring perpendicular overlap, then edge distance, then
    /// center distance, then id (deterministic).
    static func nearest(from origin: CGRect, _ direction: Direction, among frames: [WindowID: CGRect]) -> WindowID? {
        func overlap(_ r: CGRect) -> Double {
            direction.axis == .horizontal
                ? min(r.maxY, origin.maxY) - max(r.minY, origin.minY)
                : min(r.maxX, origin.maxX) - max(r.minX, origin.minX)
        }
        let scored = frames.compactMap { id, r -> (WindowID, Bool, Double, Double)? in
            guard let d = gap(from: origin, direction, to: r) else { return nil }
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

    /// Overlap allowed between two windows' facing edges before they still
    /// count as "touching" for directional focus — unrelated to
    /// `CGRect.approximatelyEquals`'s AX-rounding tolerance (Geometry.swift),
    /// which answers a different question (did an AX write land where
    /// requested) at a different scale (sub-point rounding vs. deliberate
    /// gap slack between tiles).
    private static let directionalTouchTolerance = 4.0

    /// How far `r` lies past `origin`'s edge in `direction`, allowing a few
    /// points of overlap for touching edges; `nil` unless it lies beyond.
    private static func gap(from origin: CGRect, _ direction: Direction, to r: CGRect) -> Double? {
        let tolerance = directionalTouchTolerance
        switch direction {
        case .left: return r.maxX <= origin.minX + tolerance ? origin.minX - r.maxX : nil
        case .right: return r.minX >= origin.maxX - tolerance ? r.minX - origin.maxX : nil
        case .up: return r.maxY <= origin.minY + tolerance ? origin.minY - r.maxY : nil
        case .down: return r.minY >= origin.maxY - tolerance ? r.minY - origin.maxY : nil
        }
    }
}
