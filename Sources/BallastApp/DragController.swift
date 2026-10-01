@preconcurrency import ApplicationServices
import AppKit
import BallastCore

/// Tracks a tile the user is dragging: which windows moved while the button
/// was down, the live drop preview, and where releasing would drop. Reads the
/// manager's engine and window slots; never mutates them. Main thread only.
@MainActor
final class DragController {
    /// What releasing a dragged tile does. The drop and its live preview both
    /// come from `dropTarget(for:at:)`, so they cannot disagree.
    enum Target: Equatable {
        case swap(WindowID)
        case display(DisplayInfo)
    }

    /// The tile being dragged (confirmed by `probe`) and its current target.
    private struct Session {
        let window: WindowID
        var target: Target?
    }

    private unowned let wm: WindowManager
    /// Windows the user is dragging (mouse was down when they moved).
    private var candidates = Set<WindowID>()
    /// Where the button was released for each candidate awaiting its AX read:
    /// the drop resolves there, not wherever the cursor has moved since.
    private var dropPoints: [WindowID: CGPoint] = [:]
    /// Candidates with a `probe` read in flight.
    private var probes = Set<WindowID>()
    /// The confirmed drag while the button is down; drives `preview`.
    private var session: Session?
    private let preview = DropPreview()

    init(manager: WindowManager) {
        wm = manager
    }

    /// Global mouse-up and drag monitors. `onRelease` receives the candidates
    /// whose drop now needs resolving.
    func monitors(onRelease: @escaping (Set<WindowID>) -> Void) -> [Any] {
        var monitors: [Any] = []
        if let up = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp, handler: { [weak self] _ in
            guard let self else { return }
            endDrag()
            guard !candidates.isEmpty else { return }
            let point = currentMouseLocation()
            for id in candidates { dropPoints[id] = point }
            onRelease(candidates)
        }) { monitors.append(up) }
        if let dragged = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDragged, handler: { [weak self] _ in
            self?.updateDropPreview()
        }) { monitors.append(dragged) }
        return monitors
    }

    /// `id` moved while the button was down: resolved on mouse-up.
    func moved(_ id: WindowID) {
        candidates.insert(id)
        dropPoints[id] = nil // a new press supersedes an unresolved release
        probe(id)
    }

    /// Takes `id` out of the candidates once its release is being classified.
    func release(_ id: WindowID) -> (dragged: Bool, point: CGPoint?) {
        (candidates.remove(id) != nil, dropPoints.removeValue(forKey: id))
    }

    func forget(_ id: WindowID) {
        candidates.remove(id)
        dropPoints[id] = nil
        if session?.window == id { endDrag() }
    }

    /// The frame changed size, not just position: a resize, never a drag between tiles.
    static func isResize(_ current: CGRect, from want: CGRect) -> Bool {
        abs(current.width - want.width) > 2 || abs(current.height - want.height) > 2
    }

    /// Where releasing dragged window `id` at `point` sends it; nil snaps it back.
    ///
    /// Hit-tests against a fresh layout plan rather than `expected`: in a
    /// scrolling deck, tucked windows' frames overlap the tile in view, so a
    /// tile in view must win before a covered window's exposed strip.
    func dropTarget(for id: WindowID, at point: CGPoint) -> Target? {
        let engine = wm.engine, displays = wm.displays
        guard let space = engine.windows[id]?.space else { return nil }
        if let key = engine.snapshot.key(for: space), let display = displays.containing(point), display.uuid != key.display {
            return .display(display)
        }
        guard let key = engine.snapshot.key(for: space), let area = displays.with(uuid: key.display)?.visibleFrame else { return nil }
        let plan = engine.layout(space: space, area: area)
        if let member = plan.frames.first(where: { $0.key != id && !plan.covered.keys.contains($0.key) && $0.value.contains(point) }) {
            return .swap(member.key)
        }
        if let member = plan.covered.first(where: { $0.key != id && $0.value.contains(point) }) {
            return .swap(member.key)
        }
        return nil
    }

    /// A tile moved while the button was down. One AX read tells a drag
    /// (moved, same size) from a resize or a frame Ballast just applied; only
    /// a drag starts the preview. At most one read per window is in flight.
    private func probe(_ id: WindowID) {
        guard session == nil, !probes.contains(id), let element = wm.slots[id]?.element,
              let pid = wm.engine.windows[id]?.pid else { return }
        probes.insert(id)
        wm.applier.perform(pid: pid) { [weak self] in
            let current = AX.frame(element)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                probes.remove(id)
                guard session == nil, candidates.contains(id), NSEvent.pressedMouseButtons & 1 != 0,
                      let current, let want = wm.slots[id]?.expected, !current.approximatelyEquals(want),
                      !Self.isResize(current, from: want) else { return }
                session = Session(window: id)
                updateDropPreview()
            }
        }
    }

    /// Highlights what releasing now would hit. Runs on every mouse-dragged
    /// event, so the zone is recomputed only when the target changes, or on
    /// `force` after a pass that may have moved the tiles.
    func updateDropPreview(force: Bool = false) {
        guard let current = session else { return }
        guard NSEvent.pressedMouseButtons & 1 != 0 else { endDrag(); return } // mouse-up missed
        let target = dropTarget(for: current.window, at: currentMouseLocation())
        guard force || target != current.target else { return }
        session?.target = target
        if let target, let frame = dropZone(of: current.window, on: target) {
            preview.show(frame, below: current.window)
        } else {
            preview.hide()
        }
    }

    private func endDrag() {
        guard session != nil else { return }
        session = nil
        preview.hide()
    }

    /// The zone for dropping `id` on `target`. A swap highlights the window it
    /// would trade places with: exactly the area that selects it. (The dragged
    /// window can land a different size, since minimum sizes and weights
    /// travel with it.) Another display has no such window, so the zone is the
    /// tile `id` gets there, from running the move on a copy of the engine.
    private func dropZone(of id: WindowID, on target: Target) -> CGRect? {
        let engine = wm.engine, displays = wm.displays
        switch target {
        case .swap(let other):
            guard let space = engine.windows[id]?.space, let key = engine.snapshot.key(for: space),
                  let area = displays.with(uuid: key.display)?.visibleFrame else { return wm.slots[other]?.expected }
            let plan = engine.layout(space: space, area: area)
            return plan.covered[other] ?? plan.frames[other]
        case .display(let display):
            var sim = engine
            guard let space = sim.snapshot.activeSpace(ofDisplay: display.uuid) else { return nil }
            _ = sim.setSpace(id, space)
            guard let key = sim.snapshot.key(for: space), let area = displays.with(uuid: key.display)?.visibleFrame else { return nil }
            return sim.layout(space: space, area: area).frames[id]
        }
    }
}
