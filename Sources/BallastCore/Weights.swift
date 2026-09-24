import Foundation

/// Pure, deterministic ranking of windows for placement.
///
/// Order: higher weight first → more recently focused first (never-focused
/// windows rank after all focused ones) → earlier creation first → lower
/// window id first (total-order guarantee; ids are unique).
public enum WeightResolver {
    public struct Candidate: Equatable, Sendable {
        public let id: WindowID
        public let weight: Double
        /// 0 = most recently focused; nil = never focused on this Space.
        public let focusRank: Int?
        public let creation: UInt64

        public init(id: WindowID, weight: Double, focusRank: Int?, creation: UInt64) {
            self.id = id
            self.weight = weight
            self.focusRank = focusRank
            self.creation = creation
        }
    }

    public static func rank(_ candidates: [Candidate]) -> [WindowID] {
        candidates.sorted(by: precedes).map(\.id)
    }

    static func precedes(_ a: Candidate, _ b: Candidate) -> Bool {
        let wa = a.weight.isFinite ? a.weight : 0
        let wb = b.weight.isFinite ? b.weight : 0
        if wa != wb { return wa > wb }
        switch (a.focusRank, b.focusRank) {
        case let (ra?, rb?) where ra != rb: return ra < rb
        case (.some, nil): return true
        case (nil, .some): return false
        default: break
        }
        if a.creation != b.creation { return a.creation < b.creation }
        return a.id < b.id
    }
}

/// Most-recent-first focus history for one Space. Holds each window at most once.
public struct FocusHistory: Equatable, Sendable {
    public private(set) var entries: [WindowID] = []
    /// The window that was most recently focused right before each key first
    /// took focus. Captured at `touch` time so a later, incidental re-touch
    /// (e.g. AppKit briefly redirecting focus while a close is in flight)
    /// cannot overwrite the *true* predecessor a fallback should prefer.
    private var predecessor: [WindowID: WindowID] = [:]

    public init(_ entries: [WindowID] = []) {
        for id in entries where !self.entries.contains(id) { self.entries.append(id) }
    }

    public mutating func touch(_ id: WindowID) {
        if let top = entries.first, top != id {
            predecessor[id] = top
        }
        entries.removeAll { $0 == id }
        entries.insert(id, at: 0)
    }

    public mutating func remove(_ id: WindowID) {
        entries.removeAll { $0 == id }
        predecessor[id] = nil
    }

    public var mostRecent: WindowID? { entries.first }

    /// Rank used by the weight resolver (0 = most recent).
    public func rank(of id: WindowID) -> Int? { entries.firstIndex(of: id) }

    /// The entry to focus after `id` goes away: the window that was focused
    /// immediately before `id` first took focus (its recorded predecessor),
    /// if still eligible; else the most recent eligible entry that was
    /// focused before `id` (entries after it); else any other eligible
    /// entry. Preferring the recorded predecessor keeps the right answer
    /// even when AppKit already moved focus elsewhere before the close was
    /// observed — that transient re-touch must not shadow the window that
    /// actually preceded `id` in history.
    public func fallback(excluding id: WindowID, where isEligible: (WindowID) -> Bool) -> WindowID? {
        if let pred = predecessor[id], pred != id, isEligible(pred) {
            return pred
        }
        if let index = entries.firstIndex(of: id),
           let older = entries[(index + 1)...].first(where: isEligible) {
            return older
        }
        return entries.first { $0 != id && isEligible($0) }
    }
}
