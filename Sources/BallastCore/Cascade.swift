import CoreGraphics

/// Where a window that newly opens on a float Space goes: slot k sits at the
/// area's origin plus the outer gap plus k steps down and right.
public enum Cascade {
    public static let step: CGFloat = 28
    /// Origins closer than this count as the same slot (windows round to whole points).
    static let tolerance: CGFloat = 1.5

    /// The frame for a window of `size`: the first slot no rect in `occupied`
    /// has its origin at, wrapping to slot 0 when the window would no longer
    /// fit in `area` (inset by `outerGap`) — also when every slot that fits is taken.
    /// `size` is clamped to the inset area.
    public static func frame(size: CGSize, in area: CGRect, outerGap: CGFloat, occupied: [CGPoint]) -> CGRect {
        let inner = area.insetBy(dx: max(outerGap, 0), dy: max(outerGap, 0))
        let size = CGSize(width: min(size.width, max(inner.width, 0)), height: min(size.height, max(inner.height, 0)))
        func origin(_ k: Int) -> CGPoint {
            CGPoint(x: inner.minX + CGFloat(k) * step, y: inner.minY + CGFloat(k) * step)
        }
        func fits(_ p: CGPoint) -> Bool {
            p.x + size.width <= inner.maxX + tolerance && p.y + size.height <= inner.maxY + tolerance
        }
        func taken(_ p: CGPoint) -> Bool {
            occupied.contains { abs($0.x - p.x) <= tolerance && abs($0.y - p.y) <= tolerance }
        }
        var k = 0
        while fits(origin(k)), taken(origin(k)) { k += 1 }
        let chosen = fits(origin(k)) ? origin(k) : origin(0)
        return CGRect(origin: chosen, size: size)
    }
}
