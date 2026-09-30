import CoreGraphics
import Foundation

/// A deck is several tiled windows layered in one tile: `SpaceState.decks`
/// keys it by the window that holds the tile (the one the tree, the orders
/// and every layout see) and lists all its windows.
extension SpaceState {
    /// The window holding the tile `id` sits in: `id` itself unless it is a
    /// deck's non-representative member.
    public func tile(of id: WindowID) -> WindowID {
        decks.first { $0.value.contains(id) }?.key ?? id
    }

    /// Windows of the tile `tile`: the deck's, or the window alone.
    public func windows(ofTile tile: WindowID) -> [WindowID] { decks[tile] ?? [tile] }

    public func isDecked(_ id: WindowID) -> Bool { decks.values.contains { $0.contains(id) } }

    /// The tile's window to show or focus: its most recently focused one.
    public func frontWindow(ofTile tile: WindowID) -> WindowID {
        let all = windows(ofTile: tile)
        return recentTiles.first { all.contains($0) } ?? tile
    }

    /// Members that hold a tile: every member but a deck's others.
    public var tiles: [WindowID] {
        guard !decks.isEmpty else { return members }
        let others = Set(decks.flatMap { key, value in value.filter { $0 != key } })
        return members.filter { !others.contains($0) }
    }

    /// `recentTiles` by tile: each tile where its most recently focused window is.
    var recentTileHolders: [WindowID] {
        guard !decks.isEmpty else { return recentTiles }
        var seen = Set<WindowID>()
        return recentTiles.map(tile(of:)).filter { seen.insert($0).inserted }
    }

    /// `order` with every tile followed by the rest of its deck.
    func expanding(_ order: [WindowID]) -> [WindowID] {
        order.flatMap { windows(ofTile: $0) }
    }

    /// Decks pruned to what still holds: members that exist, the holder
    /// among them, two windows at least, no window in two decks.
    func healedDecks(existing: (WindowID) -> Bool) -> [WindowID: [WindowID]] {
        var claimed = Set<WindowID>()
        var healed: [WindowID: [WindowID]] = [:]
        let memberSet = Set(members)
        for key in decks.keys.sorted() {
            let list = (decks[key] ?? []).filter { memberSet.contains($0) && existing($0) && claimed.insert($0).inserted }
            guard list.count >= 2 else { list.forEach { claimed.remove($0) }; continue }
            healed[list.contains(key) ? key : list[0]] = list
        }
        return healed
    }
}

/// Renders decks: a column of windows layered in its rect, with `limit` in
/// view, the rest tucked behind the ends. One renderer serves manual decks
/// (one tile), the fixed grid's overflow column, and monocle.
enum DeckLayout {
    /// `plan` laid out one tile per deck (keyed by the window holding it),
    /// with every deck expanded into its windows. `inView` then lists the
    /// deck windows showing as well as the grid windows in view.
    static func expand(_ plan: TilePlan, decks: [WindowID: [WindowID]], recent: [WindowID], gap: Double,
                       peek: Double, weight: (WindowID) -> Double, minSize: (WindowID) -> CGSize) -> TilePlan {
        guard !decks.isEmpty else { return plan }
        var out = plan
        let holders = Set(decks.keys)
        out.inView = plan.inView.filter { !holders.contains($0) }
        // The window showing for each deck tile in view.
        var showing: [WindowID: WindowID] = [:]
        var inside: [WindowID: [WindowID]] = [:]
        for tile in decks.keys.sorted() {
            guard let members = decks[tile], let frame = plan.frames[tile] else { continue }
            let tucked = plan.covered[tile]
            if let strip = tucked {
                for member in members {
                    out.frames[member] = frame
                    out.covered[member] = strip
                    out.navigation[member] = plan.navigation[tile] ?? frame
                }
                if plan.scrolling.contains(tile) { out.scrolling.formUnion(members) }
                continue
            }
            let deck = column(members, in: frame, axis: .vertical, gap: gap, limit: 1, peek: peek,
                              recent: recent, weight: weight, maxWeightRatio: .infinity, minSize: minSize)
            out.frames.merge(deck.frames) { _, new in new }
            out.covered.merge(deck.covered) { _, new in new }
            out.navigation.merge(deck.navigation) { _, new in new }
            out.scrolling.formUnion(deck.scrolling)
            if let view = deck.inView.first {
                showing[tile] = view
                out.inView += deck.inView
                inside[view] = deck.behind[view] ?? []
            }
        }
        // Windows hidden behind a tile keep the tile's deck order; a deck
        // tile in view is kept in front by the window showing for it.
        out.behind = [:]
        for (key, hidden) in plan.behind {
            let front = showing[key] ?? key
            out.behind[front, default: []] += hidden.flatMap { decks[$0] ?? [$0] }
        }
        for (view, hidden) in inside where !hidden.isEmpty { out.behind[view, default: []] += hidden }
        return out
    }

    /// One column of `ids`: all in view when `limit` is nil or covers them,
    /// else a deck with `limit` equal slots in view, every other window tucked
    /// behind the first or last slot with `peek` points of its neighbours showing.
    static func column(_ ids: [WindowID], in rect: CGRect, axis: Axis, gap: Double, limit: Int?,
                       peek: Double, recent: [WindowID], weight: (WindowID) -> Double,
                       maxWeightRatio: Double, minSize: (WindowID) -> CGSize) -> TilePlan {
        let shown = limit.map { max(1, $0) } ?? ids.count
        guard ids.count > shown else {
            let frames = tileLinear(ids, in: rect, axis: axis, gap: gap, weight: weight,
                                    maxWeightRatio: maxWeightRatio, minSize: minSize)
            return TilePlan(frames: frames, navigation: frames, inView: ids)
        }
        let start = viewStart(ids, shown: shown, recent: recent)
        let visible = Array(ids[start..<(start + shown)])
        let inset = (peek.isFinite ? min(max(peek, 0), rect.extent(axis) / 4) : 0).rounded()
        // Only an end with a window beyond it keeps a strip for that window
        // to peek into. Slots stay equal whatever the weights, so which
        // windows share the view never changes a window's size.
        let before = start > 0 ? inset : 0
        let after = start + shown < ids.count ? inset : 0
        let slots = tileLinear(visible, in: rect.insetClamped(axis, start: before, end: after), axis: axis, gap: gap,
                               weight: { _ in 1 }, maxWeightRatio: .infinity, minSize: minSize)
        var plan = TilePlan(frames: slots, navigation: slots, inView: visible, scrolling: Set(ids))
        guard let first = visible.first.flatMap({ slots[$0] }), let last = visible.last.flatMap({ slots[$0] }) else {
            return plan
        }
        if let head = visible.first, start > 0 { plan.behind[head] = Array(ids[..<start]) }
        if let tail = visible.last, start + shown < ids.count { plan.behind[tail, default: []] += ids[(start + shown)...] }
        // Scrolled-out windows continue the strip beyond the peeking strips,
        // so only windows in view line up beside the feature.
        for (distance, id) in zip(1..., ids[..<start].reversed()) {
            let peeking = distance == 1
            plan.frames[id] = peeking ? first.shifted(axis, by: -inset) : first
            plan.covered[id] = first.band(axis, from: first.start(axis) - (peeking ? inset : 0), length: peeking ? inset : 0)
            plan.navigation[id] = first.shifted(axis, by: -inset - Double(distance) * (first.extent(axis) + gap))
        }
        for (distance, id) in zip(1..., ids[(start + shown)...]) {
            let peeking = distance == 1
            plan.frames[id] = peeking ? last.shifted(axis, by: inset) : last
            plan.covered[id] = last.band(axis, from: last.end(axis), length: peeking ? inset : 0)
            plan.navigation[id] = last.shifted(axis, by: inset + Double(distance) * (last.extent(axis) + gap))
        }
        return plan
    }

    /// Index of the first deck window in view. The view holds `recent`'s
    /// first window of the deck; of the positions that do, those also holding
    /// the next most recent one win, and so on; any tie left goes to the
    /// position nearest the start of the deck.
    static func viewStart(_ ids: [WindowID], shown: Int, recent: [WindowID]) -> Int {
        var starts = Array(0...max(0, ids.count - max(shown, 1)))
        for id in recent where starts.count > 1 {
            guard let index = ids.firstIndex(of: id) else { continue }
            let holding = starts.filter { $0 <= index && index < $0 + shown }
            if !holding.isEmpty { starts = holding }
        }
        return starts.first ?? 0
    }
}
