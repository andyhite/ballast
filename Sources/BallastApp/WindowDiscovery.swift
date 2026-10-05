import AppKit
@preconcurrency import ApplicationServices
import BallastCore

/// Pure parts of window discovery: what counts as a trackable window, how its
/// facts are read, and which arriving tab takes over a vanished one's tile.
enum WindowDiscovery {
    /// A tab/window as the tab matcher sees it: `frame` is where the vanished
    /// window was last placed, or where the arrival is now.
    struct Tab {
        let id: WindowID
        let space: SpaceID?
        let frame: CGRect?
    }

    /// An ordinary, non-fullscreen window. Native fullscreen windows live on
    /// their own Space: ignored entirely.
    static func isTrackable(_ element: AXUIElement) -> Bool {
        AX.string(element, kAXRoleAttribute) == kAXWindowRole && AX.bool(element, "AXFullScreen") != true
    }

    /// Facts and minimized state, read from AX. `static`: called from
    /// background closures, which must not touch the manager.
    static func read(_ element: AXUIElement, observer: AppObserver) -> (facts: WindowFacts, minimized: Bool) {
        (facts(element, observer: observer), AX.bool(element, kAXMinimizedAttribute) == true)
    }

    /// Reads a window's `WindowFacts` from AX. `fullScreen` is judged only
    /// when the close button exists and is enabled: macOS drops the
    /// full-screen button while a sheet is attached, and title-bar-less
    /// windows have no buttons at all, so both cases must read as unknown
    /// rather than "no full-screen button".
    static func facts(_ element: AXUIElement, observer: AppObserver) -> WindowFacts {
        let closeButton = AX.element(element, "AXCloseButton")
        let closeEnabled = closeButton.flatMap { AX.bool($0, kAXEnabledAttribute) } == true
        let fullScreen: Bool? = closeEnabled ? AX.element(element, "AXFullScreenButton") != nil : nil
        return WindowFacts(bundleID: observer.bundleID, appName: observer.name,
                           title: AX.string(element, kAXTitleAttribute),
                           role: AX.string(element, kAXRoleAttribute),
                           subrole: AX.string(element, kAXSubroleAttribute),
                           identifier: AX.string(element, kAXIdentifierAttribute),
                           modal: AX.bool(element, "AXModal"),
                           resizable: AX.isSettable(element, kAXSizeAttribute),
                           fullScreen: fullScreen)
    }

    /// For each vanished window (lowest id first), the arrival on the same
    /// Space whose frame is closest to where it was: tabs of a group share one
    /// frame, so that arrival is the tab that came in front of it. An arrival
    /// is used once; `new` is nil when none is left (the window went to the
    /// background).
    static func successors(vanished: [Tab], appeared: [Tab]) -> [(old: WindowID, new: WindowID?)] {
        var free = appeared.sorted { $0.id < $1.id }
        return vanished.sorted { $0.id < $1.id }.map { old in
            let candidates = free.indices.filter { free[$0].space == old.space }
            guard let pick = candidates.min(by: { distance(free[$0].frame, old.frame) < distance(free[$1].frame, old.frame) }) else {
                return (old.id, nil)
            }
            return (old.id, free.remove(at: pick).id)
        }
    }

    private static func distance(_ a: CGRect?, _ b: CGRect?) -> CGFloat {
        guard let a, let b else { return .infinity }
        return abs(a.minX - b.minX) + abs(a.minY - b.minY) + abs(a.width - b.width) + abs(a.height - b.height)
    }
}

extension WindowManager {
    /// Reads every window of `observer`'s app and tracks the ones not
    /// already known. The AX reads (`observer.windows`, then each
    /// candidate window's role/fullscreen/facts/minimized state) run on
    /// that app's own serial queue, not the main thread — the same
    /// isolation `FrameApplier` already gives frame writes — so one
    /// unresponsive app's AX round-trips during a bulk resync
    /// (`fullResync`, called on every Space change, wake, display change,
    /// and Mission Control exit) never block discovery, or anything else
    /// on the main thread, for every other observed app. `completion`
    /// (main thread) runs after every discovered window has been
    /// committed; callers that need to act on a specific window right
    /// after activation (e.g. following focus) must wait for it rather
    /// than assuming discovery finished synchronously.
    /// `completion` receives the app's focused window as read on the worker
    /// (only read when `completion` is given). `restoring`: the windows found
    /// were already open, not just opened (see `restoreArrangement`).
    func discoverWindows(_ observer: AppObserver, restoring: Bool = false,
                         completion: (@MainActor @Sendable (AXUIElement?) -> Void)? = nil) {
        guard let provider, let axObserver = observer.installed else { completion?(nil); return }
        // Snapshot, not a live reference: read on the worker queue below
        // without touching `self.slots` off the main thread. A window
        // that starts being tracked concurrently (a live `AXWindowCreated`
        // notification racing this discovery) is still caught safely by
        // `commitTracked`'s own `slots[id] == nil` check on main.
        let known = Set(slots.keys)
        applier.perform(pid: observer.pid) {
            var found: [(id: WindowID, element: AXUIElement, facts: WindowFacts, minimized: Bool)] = []
            var visible = Set<WindowID>()
            // `AXWindows` lists only windows on the active Spaces, so it can
            // only be judged against the Spaces that were active while it
            // was read. A switch mid-read leaves nothing to judge it by.
            let activeBefore = provider.activeSpaceIDs()
            for element in observer.windows {
                guard let id = provider.windowID(for: element), id != 0 else { continue }
                visible.insert(id)
                guard !known.contains(id), WindowDiscovery.isTrackable(element) else { continue }
                let (facts, minimized) = WindowDiscovery.read(element, observer: observer)
                guard observer.register(window: element, in: axObserver) else {
                    Log.ax.notice("window \(id) of \(facts.appName ?? "?", privacy: .public) refused AX notifications; not tracked yet")
                    continue
                }
                found.append((id, element, facts, minimized))
            }
            let activeAfter = provider.activeSpaceIDs()
            let activeDuringRead = activeBefore == activeAfter ? activeBefore : nil
            let focused = completion == nil ? nil : observer.focusedWindow
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { completion?(focused); return }
                    for w in found {
                        self.commitTracked(w.id, element: w.element, observer: observer, facts: w.facts, minimized: w.minimized,
                                           registered: true, restoring: restoring)
                    }
                    self.reconcileTabs(pid: observer.pid, visible: visible, readAfter: known, activeDuringRead: activeDuringRead)
                    completion?(focused)
                }
            }
        }
    }

    /// Native tabs of one window group are separate windows, and the app
    /// lists only the selected one in `AXWindows` without ever announcing
    /// the others' departure. Given the ids the app lists now, this hides
    /// tracked windows that dropped out and restores those that came back.
    /// A window that came in front takes over the tile of the window that
    /// dropped out with it, so a tab switch never rearranges the Space.
    /// `tracked`: the windows known when `visible` was read; one tracked
    /// since cannot have dropped out of a list that predates it.
    /// `activeDuringRead`: the live active Spaces while `visible` was read.
    private func reconcileTabs(pid: pid_t, visible: Set<WindowID>, readAfter tracked: Set<WindowID>,
                               activeDuringRead: Set<SpaceID>?) {
        // A Space switch posts app activation and focus notifications before
        // (or with) `activeSpaceDidChange`, so `visible` can already list the
        // new Space's windows while `engine.snapshot` still names the old one
        // active. Judged against it, every window on the old Space would
        // "vanish" into a background tab, lose its tile, and come back in a
        // new one. Skip until they agree: the resync that updates the
        // snapshot rediscovers every app.
        guard let activeDuringRead,
              activeDuringRead == Set(engine.snapshot.displays.compactMap(\.activeSpace)) else { return }
        // Windows tracked since their app's tabs were last reconciled: one of
        // them may be the tab that just came in front of a tab that vanished.
        let fresh = Set(slots.filter { $0.value.arrived && visible.contains($0.key) && engine.windows[$0.key]?.pid == pid }.keys)
        for id in fresh { slots[id]?.arrived = false }
        // An empty list is a failed read, not an app with no windows; a
        // hidden app's windows are already out of the layout.
        guard !visible.isEmpty, NSRunningApplication(processIdentifier: pid)?.isHidden != true else { return }
        var vanished: [WindowID] = []
        var appeared: [WindowID] = []
        for (id, w) in engine.windows where w.pid == pid && !w.minimized {
            // Only windows on a visible Space are expected in `AXWindows`.
            guard let space = w.space, engine.snapshot.isActive(space) else { continue }
            if !visible.contains(id) {
                if !w.backgroundTab, tracked.contains(id) { vanished.append(id) }
            } else if w.backgroundTab || fresh.contains(id) {
                appeared.append(id)
            }
        }
        appeared.sort()
        if !vanished.isEmpty {
            let bounds = Self.windowBounds()
            let pairs = WindowDiscovery.successors(
                vanished: vanished.map { .init(id: $0, space: engine.windows[$0]?.space, frame: slots[$0]?.expected) },
                appeared: appeared.map { .init(id: $0, space: engine.windows[$0]?.space, frame: bounds[$0]) })
            for (old, successor) in pairs {
                if let successor {
                    appeared.removeAll { $0 == successor }
                    markDirty(engine.swapTab(hiding: old, showing: successor))
                } else {
                    markDirty(engine.setBackgroundTab(old, true))
                }
            }
        }
        for id in appeared where engine.windows[id]?.backgroundTab == true {
            markDirty(engine.setBackgroundTab(id, false))
        }
    }

    /// Live path: a single window from an `AXWindowCreated` notification,
    /// already on the main thread with the element in hand. Small enough
    /// (one window, not a whole app's inventory) that reading its facts
    /// inline is not worth the round trip through `discoverWindows`.
    func track(_ element: AXUIElement, observer: AppObserver) {
        guard let provider, let id = provider.windowID(for: element), id != 0 else { return }
        guard slots[id] == nil, WindowDiscovery.isTrackable(element) else { return }
        let (facts, minimized) = WindowDiscovery.read(element, observer: observer)
        commitTracked(id, element: element, observer: observer, facts: facts, minimized: minimized, opened: true)
    }

    /// Registers AX notifications for a window and adds it to the engine,
    /// using facts already read from AX by either caller above. Always
    /// runs on the main thread.
    private func commitTracked(_ id: WindowID, element: AXUIElement, observer: AppObserver, facts: WindowFacts, minimized: Bool,
                               opened: Bool = false, registered: Bool = false, restoring: Bool = false) {
        guard slots[id] == nil else { return } // raced with a live notification for the same window
        guard registered || observer.observe(window: element) else {
            Log.ax.notice("window \(id) of \(facts.appName ?? "?", privacy: .public) refused AX notifications; not tracked yet")
            return
        }
        slots[id] = WindowSlot(element: element, arrived: true, seed: restoring ? Self.windowBounds(of: id) : nil)
        let space = resolveSpace(for: id, pid: observer.pid)
        markDirty(engine.addWindow(id, pid: observer.pid, facts: facts, space: space))
        if minimized { markDirty(engine.setMinimized(id, true)) }
        if NSRunningApplication(processIdentifier: observer.pid)?.isHidden == true { markDirty(engine.setHidden(id, true)) }
        if restoring, let space { restoreArrangement(on: space) }
        if space.map({ engine.arrangement(for: $0) }) != .float { placeFloating(id, element: element) }
        else if opened, !minimized, let space { cascade(id, element: element, on: space) }
        if engine.windows[id]?.rule.sticky == true {
            Log.wm.notice("sticky rule for \(facts.appName ?? "?", privacy: .public): pinning to all Spaces needs SIP changes; treated as floating")
        }
    }

    /// Discovery finds already-open windows (after a restart, or on a Space
    /// first visited since) in arbitrary order, each joining as a newcomer;
    /// their seed frames are where the last run left them. While every tile
    /// on `space` was found that way, its arrangement is read back from the
    /// seeds, so a restart leaves windows where they were. A window opened
    /// since, or a manual arrangement, ends this for the Space.
    // ponytail: seeds never expire; a late discovery on an untouched Space re-reads the startup frames.
    private func restoreArrangement(on space: SpaceID) {
        guard let key = engine.snapshot.key(for: space), let area = displays.with(uuid: key.display)?.visibleFrame,
              let members = engine.spaces[space]?.members else { return }
        let seeds = members.reduce(into: [WindowID: CGRect]()) { $0[$1] = slots[$1]?.seed }
        markDirty(engine.adoptArrangement(space, area: area, frames: seeds))
    }
}
