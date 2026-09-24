import AppKit
import ApplicationServices
import BallastCore

/// Orchestrator. Main thread only.
///
/// Observation (AX observers, NSWorkspace, SkyLight reads) → normalized
/// engine events → coalesced layout pass (≤ 1 per frame) → frame requests to
/// the per-app `FrameApplier` workers → results fed back as engine events.
final class WindowManager: AppObserverDelegate {
    enum Status: Equatable {
        case starting
        case needsAccessibility
        case invalidConfig(String)
        case unsupported(String)
        case blocked(String)
        case running
    }

    private(set) var status = Status.starting { didSet { statusBar?.refresh() } }
    private(set) var engine = Engine(config: Config())
    /// Latest reload error; the previous config stays live while set.
    private(set) var configError: String?
    private(set) var configNote: String?
    let configURL: URL

    private let provider: SkyLightSpaceProvider?
    private let providerError: String?
    private let applier = FrameApplier()
    private var observers: [pid_t: AppObserver] = [:]
    private var dockObserver: AppObserver?
    private var elements: [WindowID: AXUIElement] = [:]
    private(set) var displays: [DisplayInfo] = []
    private var statusBar: StatusBar?
    private var hotkeys: HotKeyCenter?
    private var watcher: ConfigWatcher?
    private var workspaceTokens: [NSObjectProtocol] = []
    private var eventMonitors: [Any] = []
    private var didPromptAccessibility = false

    // Layout-pass bookkeeping.
    private var dirty = Set<SpaceID>()
    private var passScheduled = false
    private var frameInterval = 1.0 / 60
    private var reduceMotion = false
    /// Frame each window should have (last requested, then last observed result).
    private var expected: [WindowID: CGRect] = [:]
    /// Last frame sent per window; identical requests are not re-sent (a
    /// window that refused a size is not retried every pass).
    private var lastRequested: [WindowID: CGRect] = [:]
    private var inFlight: [WindowID: Int] = [:]
    /// Windows whose moved/resized notification still needs classifying.
    private var pendingChecks = Set<WindowID>()
    /// Windows the user is dragging (mouse was down when they moved).
    private var dragCandidates = Set<WindowID>()
    private var snapBackTimes: [WindowID: [Date]] = [:]
    /// Dock "Assign To Desktop" bindings, captured when an app launches.
    private var launchBindings: [pid_t: SpaceID] = [:]
    private var lastMouseFocusCheck = Date.distantPast
    private var configLoaded = false
    /// Last focus transition, to recognise "AppKit moved focus, then the window closed".
    private var lastFocusLoss: (window: WindowID, at: Date)?
    /// Spaces already seen by a full resync (first sighting adopts the ideal BSP tree).
    private var seenSpaces = Set<SpaceID>()
    /// Window ids in each Space's last plan.
    private var laidOut: [SpaceID: Set<WindowID>] = [:]
    private let hitTestQueue = DispatchQueue(label: "dev.ballast.hit-test", qos: .userInteractive)
    private var hitTestPending = false

    init(configURL: URL) {
        self.configURL = configURL
        switch SkyLightSpaceProvider.make() {
        case .success(let p): provider = p; providerError = nil
        case .failure(let missing): provider = nil; providerError = missing.description
        }
    }

    // MARK: Lifecycle

    func launch() {
        statusBar = StatusBar(manager: self)
        watcher = ConfigWatcher(url: configURL) { [weak self] in self?.reloadConfig() }
        watcher?.start()
        hotkeys = HotKeyCenter { [weak self] index in self?.runBinding(index) }
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.accessibility.api"), object: nil, queue: .main
        ) { [weak self] _ in
            // Posted before the trust database settles; check shortly after.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self?.tryStart() }
        }
        DistributedNotificationCenter.default().addObserver(
            forName: BallastCLI.commandNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let text = note.object as? String else { return }
            switch Command.parse(text) {
            case .success(let command): self?.perform(command)
            case .failure(let error): Log.wm.error("ignored command '\(text, privacy: .public)': \(error.message, privacy: .public)")
            }
        }
        tryStart()
    }

    /// Idempotent: advances from any blocked state to `.running` once every
    /// precondition holds. Called on launch, permission change and config fix.
    func tryStart() {
        guard status != .running else { return }
        guard loadInitialConfig() else { return }
        guard provider != nil else {
            status = .unsupported("Unsupported macOS version: \(providerError ?? "private SkyLight symbols missing")")
            Notifier.post(title: "Ballast can't run", body: "This macOS version is unsupported. Run `ballast doctor`.")
            return
        }
        if !SystemSettings.displaysHaveSeparateSpaces || SystemSettings.autoRearrangeSpaces {
            let reason = !SystemSettings.displaysHaveSeparateSpaces
                ? "Turn ON “Displays have separate Spaces” (Desktop & Dock), then log out and in."
                : "Turn OFF “Automatically rearrange Spaces based on most recent use” (Desktop & Dock)."
            status = .blocked(reason)
            Notifier.post(title: "Ballast is not managing windows", body: reason)
            return
        }
        guard AXIsProcessTrusted() else {
            status = .needsAccessibility
            if !didPromptAccessibility {
                didPromptAccessibility = true
                let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
                _ = AXIsProcessTrustedWithOptions(options)
            }
            return
        }
        begin()
    }

    private func loadInitialConfig() -> Bool {
        guard !configLoaded else { return true }
        guard FileManager.default.fileExists(atPath: configURL.path) else {
            configNote = "No config file; using built-in defaults"
            engine = Engine(config: Config())
            configLoaded = true
            return true
        }
        switch readConfig() {
        case .success(let config):
            engine = Engine(config: config)
            configNote = nil
            configLoaded = true
            return true
        case .failure(let error):
            status = .invalidConfig(error.message)
            Notifier.post(title: "Ballast config error", body: error.message)
            return false
        }
    }

    /// Idempotent: also re-entered after a `.blocked` state clears.
    private func begin() {
        status = .running
        frameInterval = 1.0 / Double(max(30, NSScreen.main?.maximumFramesPerSecond ?? 60))
        reduceMotion = SystemSettings.reduceMotion
        // Global default for elements we create ad hoc (system-wide hit tests).
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), AX.messagingTimeout)
        applyBindings()
        if workspaceTokens.isEmpty { observeWorkspace() }
        if eventMonitors.isEmpty { observeMouse() }
        attachDock(attempt: 0)
        for app in NSWorkspace.shared.runningApplications { observe(app) }
        fullResync()
        Log.wm.info("managing \(self.engine.windows.count) windows")
    }

    /// Dock posts the Mission Control (Exposé) notifications. Re-attached when
    /// Dock relaunches (e.g. `killall Dock` after changing Spaces settings).
    private func attachDock(attempt: Int) {
        guard status == .running, dockObserver == nil,
              let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else { return }
        let o = AppObserver(pid: dock.processIdentifier, bundleID: "com.apple.dock", name: "Dock",
                            notifications: AppObserver.dockNotifications)
        o.delegate = self
        if o.start() {
            dockObserver = o
        } else if attempt < 8 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25 * Double(attempt + 1)) { [weak self] in
                self?.attachDock(attempt: attempt + 1)
            }
        }
    }

    // MARK: Observation wiring

    private func observeWorkspace() {
        let center = NSWorkspace.shared.notificationCenter
        func on(_ name: Notification.Name, _ handler: @escaping (Notification) -> Void) {
            workspaceTokens.append(center.addObserver(forName: name, object: nil, queue: .main, using: handler))
        }
        on(NSWorkspace.didLaunchApplicationNotification) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            if app.bundleIdentifier == "com.apple.dock" { self?.attachDock(attempt: 0); return }
            self?.recordLaunchBinding(app)
            self?.observe(app)
        }
        on(NSWorkspace.didTerminateApplicationNotification) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            if let self, self.dockObserver?.pid == app.processIdentifier {
                self.dockObserver?.stop()
                self.dockObserver = nil
                return
            }
            self?.forget(pid: app.processIdentifier)
        }
        on(NSWorkspace.didActivateApplicationNotification) { [weak self] note in
            guard let self, let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  let observer = observers[app.processIdentifier] else { return }
            discoverWindows(observer)
            if let window = observer.focusedWindow { focusChanged(to: window) }
        }
        on(NSWorkspace.didHideApplicationNotification) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            self?.setHidden(pid: app.processIdentifier, true)
        }
        on(NSWorkspace.didUnhideApplicationNotification) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            self?.setHidden(pid: app.processIdentifier, false)
        }
        on(NSWorkspace.activeSpaceDidChangeNotification) { [weak self] _ in self?.fullResync() }
        on(NSWorkspace.didWakeNotification) { [weak self] _ in self?.fullResync() }
        on(NSWorkspace.accessibilityDisplayOptionsDidChangeNotification) { [weak self] _ in
            self?.reduceMotion = SystemSettings.reduceMotion
        }
        workspaceTokens.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.fullResync() })
    }

    private func observeMouse() {
        if let up = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp, handler: { [weak self] _ in
            guard let self, !dragCandidates.isEmpty else { return }
            pendingChecks.formUnion(dragCandidates)
            scheduleLayout()
        }) { eventMonitors.append(up) }
        if let moved = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved, handler: { [weak self] _ in
            self?.focusFollowsMouse()
        }) { eventMonitors.append(moved) }
    }

    private func observe(_ app: NSRunningApplication) {
        let pid = app.processIdentifier
        guard observers[pid] == nil, pid != getpid(), app.activationPolicy != .prohibited,
              app.bundleIdentifier != "com.apple.dock" else { return }
        let observer = AppObserver(pid: pid, bundleID: app.bundleIdentifier, name: app.localizedName)
        observer.delegate = self
        attach(observer, attempt: 0)
    }

    /// Launching apps are not AX-ready immediately; retry a bounded number of times.
    private func attach(_ observer: AppObserver, attempt: Int) {
        guard status == .running, observers[observer.pid] == nil else { return }
        if observer.start() {
            observers[observer.pid] = observer
            applier.perform(pid: observer.pid) {
                // Chromium/Electron honour this: much faster resizes, no competing animation.
                AX.setBool(observer.app, "AXEnhancedUserInterface", false)
            }
            discoverWindows(observer)
            return
        }
        guard attempt < 8 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25 * Double(attempt + 1)) { [weak self] in
            self?.attach(observer, attempt: attempt + 1)
        }
    }

    private func recordLaunchBinding(_ app: NSRunningApplication) {
        guard let bundle = app.bundleIdentifier?.lowercased(),
              let uuid = SystemSettings.appBindings()[bundle],
              let space = engine.snapshot.spaceID(forUUID: uuid) else { return }
        launchBindings[app.processIdentifier] = space
    }

    private func forget(pid: pid_t) {
        observers[pid]?.stop()
        observers[pid] = nil
        launchBindings[pid] = nil
        for (id, w) in engine.windows where w.pid == pid { untrack(id) }
        applier.forget(pid: pid)
        scheduleLayout()
    }

    /// NSWorkspace hide/unhide applies to every window of the app, mirroring
    /// how the system treats hidden apps as a unit. Minimized state is kept
    /// independent: a minimized window inside a hidden app stays minimized
    /// once the app is unhidden.
    private func setHidden(pid: pid_t, _ hidden: Bool) {
        for (id, w) in engine.windows where w.pid == pid { markDirty(engine.setHidden(id, hidden)) }
    }

    // MARK: AX events

    func appObserver(_ observer: AppObserver, received notification: String, element: AXUIElement) {
        guard status == .running else { return }
        if observer === dockObserver {
            // Mission Control may have moved windows, added/removed/reordered desktops.
            if notification == "AXExposeExit" { fullResync() }
            return
        }
        switch notification {
        case kAXWindowCreatedNotification:
            track(element, observer: observer)
        case kAXFocusedWindowChangedNotification, kAXMainWindowChangedNotification:
            focusChanged(to: element)
        case kAXUIElementDestroyedNotification:
            if let id = elements.first(where: { CFEqual($0.value, element) })?.key {
                let hadFocus = lastFocusLoss.map { $0.window == id && Date().timeIntervalSince($0.at) < 0.5 } ?? false
                let removal = untrack(id, hadFocus: hadFocus)
                if let fallback = removal.focusFallback, isOnActiveSpace(fallback) { focusWindow(fallback) }
            }
        case kAXWindowMiniaturizedNotification, kAXWindowDeminiaturizedNotification:
            guard let id = windowID(element) else { return }
            markDirty(engine.setMinimized(id, notification == kAXWindowMiniaturizedNotification))
        case kAXMovedNotification, kAXResizedNotification:
            // Only windows in the last plan can be displaced from their tile
            // (float-mode / passthrough Spaces are left alone).
            guard let id = windowID(element), expected[id] != nil else { return }
            pendingChecks.insert(id)
            scheduleLayout()
        case kAXTitleChangedNotification:
            guard let id = windowID(element), var facts = engine.windows[id]?.facts else { return }
            facts.title = AX.string(element, kAXTitleAttribute)
            markDirty(engine.updateFacts(id, facts))
        default:
            break
        }
    }

    private func windowID(_ element: AXUIElement) -> WindowID? {
        if let id = provider?.windowID(for: element), elements[id] != nil { return id }
        return elements.first { CFEqual($0.value, element) }?.key
    }

    private func discoverWindows(_ observer: AppObserver) {
        for window in observer.windows { track(window, observer: observer) }
    }

    private func track(_ element: AXUIElement, observer: AppObserver) {
        guard let provider, let id = provider.windowID(for: element), id != 0 else { return }
        if elements[id] != nil { return }
        guard AX.string(element, kAXRoleAttribute) == kAXWindowRole else { return }
        // Native fullscreen windows live on their own Space: ignore entirely.
        if AX.bool(element, "AXFullScreen") == true { return }
        let facts = WindowFacts(bundleID: observer.bundleID, appName: observer.name,
                                title: AX.string(element, kAXTitleAttribute),
                                role: AX.string(element, kAXRoleAttribute),
                                subrole: AX.string(element, kAXSubroleAttribute))
        guard observer.observe(window: element) else {
            Log.ax.notice("window \(id) of \(facts.appName ?? "?", privacy: .public) refused AX notifications; not tracked yet")
            return
        }
        elements[id] = element
        let space = resolveSpace(for: id, pid: observer.pid, element: element)
        markDirty(engine.addWindow(id, pid: observer.pid, facts: facts, space: space))
        if AX.bool(element, kAXMinimizedAttribute) == true { markDirty(engine.setMinimized(id, true)) }
        if NSRunningApplication(processIdentifier: observer.pid)?.isHidden == true { markDirty(engine.setHidden(id, true)) }
        placeFloating(id, element: element)
        if engine.windows[id]?.rule.sticky == true {
            Log.wm.notice("sticky rule for \(facts.appName ?? "?", privacy: .public): pinning to all Spaces needs SIP changes; treated as floating")
        }
    }

    @discardableResult
    private func untrack(_ id: WindowID, hadFocus: Bool = false) -> WindowRemoval {
        if let element = elements[id], let pid = engine.windows[id]?.pid {
            observers[pid]?.unobserve(window: element)
        }
        elements[id] = nil
        expected[id] = nil
        lastRequested[id] = nil
        inFlight[id] = nil
        pendingChecks.remove(id)
        dragCandidates.remove(id)
        snapBackTimes[id] = nil
        applier.cancel(id)
        let removal = engine.removeWindow(id, hadFocus: hadFocus)
        markDirty(removal.dirty)
        return removal
    }

    /// Space of a window: SkyLight membership, else the Dock binding of a
    /// just-launched app (so the layout is computed for where macOS will put
    /// it), else the active Space of the display it is on.
    private func resolveSpace(for id: WindowID, pid: pid_t, element: AXUIElement?) -> SpaceID? {
        let snapshot = engine.snapshot
        let candidates = provider?.spaces(forWindow: id) ?? []
        if candidates.count == 1, let only = candidates.first { return only }
        if candidates.count > 1 { return nil } // on every Space: sticky by the app itself
        if let bound = launchBindings[pid] { return bound }
        guard let element, let frame = AX.frame(element), let display = displays.best(for: frame) else { return nil }
        return snapshot.activeSpace(ofDisplay: display.uuid)
    }

    private func placeFloating(_ id: WindowID, element: AXUIElement) {
        guard let w = engine.windows[id], w.isFloating, let current = AX.frame(element),
              let display = displays.best(for: current) ?? displays.first,
              let frame = engine.initialFrame(for: id, current: current, area: display.visibleFrame,
                                              mouse: currentMouseLocation()) else { return }
        applier.apply(.init(window: id, pid: w.pid, element: element, target: frame, animation: nil)) { _, _, _ in }
    }

    private func focusChanged(to element: AXUIElement) {
        guard let id = windowID(element) else { return }
        if let previous = engine.focused, previous != id { lastFocusLoss = (previous, Date()) }
        markDirty(engine.focus(id))
        statusBar?.refresh()
    }

    // MARK: Spaces

    /// Re-reads displays + Spaces, discovers windows that became visible and
    /// reconciles every window's Space. Driven by Space-change, wake and
    /// display-reconfiguration notifications.
    private func fullResync() {
        guard status == .running, let provider else {
            if case .blocked = status { tryStart() } // settings may have been fixed
            return
        }
        // Spaces settings can change while running; ordinals are meaningless if they do.
        if !SystemSettings.displaysHaveSeparateSpaces || SystemSettings.autoRearrangeSpaces {
            status = .blocked("Spaces settings changed: need “Displays have separate Spaces” ON and “Automatically rearrange Spaces” OFF.")
            return
        }
        displays = DisplayInfo.current()
        engine.passthrough = SystemSettings.stageManagerEnabled
        if let snapshot = provider.snapshot() {
            markDirty(engine.updateSnapshot(snapshot))
        }
        for observer in observers.values { discoverWindows(observer) }
        reconcileMembership()
        // A Space seen for the first time was filled in discovery order, not
        // rank order: start its BSP tree from the weight-computed ideal.
        for space in engine.spaces.keys where !seenSpaces.contains(space) { engine.adoptIdealTree(space) }
        seenSpaces = Set(engine.spaces.keys)
        if engine.focused == nil, let front = NSWorkspace.shared.frontmostApplication,
           let window = observers[front.processIdentifier]?.focusedWindow {
            focusChanged(to: window)
        }
        for display in engine.snapshot.displays {
            if let active = display.activeSpace { dirty.insert(active) }
        }
        scheduleLayout()
        statusBar?.refresh()
    }

    /// Detects windows moved between Spaces by native tools (Mission Control
    /// drag, Dock assignment, display moves).
    private func reconcileMembership() {
        guard let provider else { return }
        var location: [WindowID: SpaceID] = [:]
        var ambiguous = Set<WindowID>()
        for display in engine.snapshot.displays {
            for space in display.spaces {
                for id in provider.windowIDs(onSpace: space.id) where elements[id] != nil {
                    if location[id] != nil, location[id] != space.id { ambiguous.insert(id) }
                    location[id] = space.id
                }
            }
        }
        for id in elements.keys {
            let pid = engine.windows[id]?.pid ?? 0
            let space = ambiguous.contains(id) ? nil
                : (location[id] ?? resolveSpace(for: id, pid: pid, element: elements[id]))
            markDirty(engine.setSpace(id, space))
        }
        launchBindings.removeAll()
    }

    // MARK: Layout pass

    private func markDirty(_ spaces: Set<SpaceID>) {
        guard !spaces.isEmpty else { return }
        dirty.formUnion(spaces)
        scheduleLayout()
    }

    /// Coalesces every event within one display frame into a single pass.
    private func scheduleLayout() {
        guard !passScheduled else { return }
        passScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + frameInterval) { [weak self] in self?.runPass() }
    }

    private func runPass() {
        passScheduled = false
        guard status == .running else { return }
        classifyExternalMoves()
        let spaces = dirty
        dirty.removeAll()
        // Spaces can vanish (Mission Control deletion) between the event that
        // dirtied them and this pass; drop their stale `laidOut` membership so
        // a reused ordinal never inherits a phantom departure set.
        laidOut = laidOut.filter { engine.spaces[$0.key] != nil }
        // A window can hop from a higher-ordinal source Space to a
        // lower-ordinal destination Space within the same pass. Both are
        // processed here (ascending), so the destination's `layout` call can
        // run first and set `expected`/`lastRequested` for the window's new
        // frame, only for the source's later `layout` call to see the window
        // missing from its own stale plan and null those slots right back
        // out. Track every id (re)assigned during this pass and never let a
        // same-pass departure cleanup erase it, regardless of processing order.
        var reassignedThisPass = Set<WindowID>()
        for space in spaces.sorted() { layout(space, reassignedThisPass: &reassignedThisPass) }
        statusBar?.refresh()
    }

    private func layout(_ space: SpaceID, reassignedThisPass: inout Set<WindowID>) {
        guard let key = engine.snapshot.key(for: space), let display = displays.with(uuid: key.display) else { return }
        let active = engine.snapshot.isActive(space)
        let plan = engine.layout(space: space, area: display.visibleFrame)
        // Windows that left this Space's plan (floated, minimized, moved away,
        // float-mode Space) must be re-sent when they come back, even to the
        // same slot, and must not be treated as displaced tiles meanwhile.
        for id in laidOut[space] ?? [] where plan.frames[id] == nil && !reassignedThisPass.contains(id) {
            lastRequested[id] = nil
            expected[id] = nil
        }
        laidOut[space] = Set(plan.frames.keys)
        let anim = engine.config.animation
        for (id, frame) in plan.frames.sorted(by: { $0.key < $1.key }) {
            guard let element = elements[id], let w = engine.windows[id] else { continue }
            reassignedThisPass.insert(id)
            if lastRequested[id] == frame { continue }
            lastRequested[id] = frame
            expected[id] = frame
            inFlight[id, default: 0] += 1
            // Strategy (a): only the focused window on an active Space interpolates.
            let animate = active && anim.enabled && !reduceMotion && anim.duration > 0 && id == engine.focused && !plan.monocle
            let request = FrameApplier.Request(
                window: id, pid: w.pid, element: element, target: frame,
                animation: animate ? (anim.duration, anim.easing, frameInterval) : nil)
            applier.apply(request) { [weak self] id, requested, outcome in
                self?.applied(id, requested: requested, outcome: outcome)
            }
        }
        if active, let raise = plan.raise, let element = elements[raise], let pid = engine.windows[raise]?.pid {
            applier.perform(pid: pid) { AX.raise(element) }
        }
    }

    private func applied(_ id: WindowID, requested: CGRect, outcome: FrameApplier.Outcome) {
        inFlight[id] = max(0, (inFlight[id] ?? 1) - 1)
        guard elements[id] != nil else { return }
        let current = lastRequested[id] == requested
        guard let actual = outcome.actual else {
            // Transient AX failure (app busy launching): let the next event retry.
            if current { lastRequested[id] = nil }
            Log.ax.debug("window \(id) did not accept a frame")
            return
        }
        if current { expected[id] = actual }
        // Refused to shrink: remember the minimum and reflow the rest around it.
        // Only a completed, still-current request says anything about constraints.
        if outcome.completed, current,
           actual.width > requested.width + 2 || actual.height > requested.height + 2 {
            markDirty(engine.learnMinSize(id, CGSize(width: max(actual.width, requested.width),
                                                     height: max(actual.height, requested.height))))
        }
        if pendingChecks.contains(id) { scheduleLayout() }
    }

    /// Classifies frame changes the WM did not make.
    private func classifyExternalMoves() {
        guard !pendingChecks.isEmpty else { return }
        let mouseDown = NSEvent.pressedMouseButtons & 1 != 0
        for id in pendingChecks {
            if (inFlight[id] ?? 0) > 0 { continue }
            pendingChecks.remove(id)
            if mouseDown {
                dragCandidates.insert(id) // resolved on mouse-up
                continue
            }
            let dragged = dragCandidates.remove(id) != nil
            guard let element = elements[id], let want = expected[id],
                  let current = AX.frame(element), !current.approximatelyEquals(want) else { continue }
            if dragged {
                userDragged(id, to: current, from: want)
            } else {
                selfMoved(id, to: current)
            }
        }
    }

    /// A user drag between tiles is always a swap intent (or a display move).
    private func userDragged(_ id: WindowID, to current: CGRect, from want: CGRect) {
        let resized = abs(current.width - want.width) > 2 || abs(current.height - want.height) > 2
        guard !resized, let space = engine.windows[id]?.space else {
            selfMoved(id, to: current)
            return
        }
        let mouse = currentMouseLocation()
        if let key = engine.snapshot.key(for: space), let target = displays.containing(mouse), target.uuid != key.display {
            // Dropped on another display: macOS reassigns the Space natively.
            let newSpace = resolveSpace(for: id, pid: engine.windows[id]?.pid ?? 0, element: elements[id])
            markDirty(engine.setSpace(id, newSpace))
            reapply(id)
            return
        }
        let members = engine.spaces[space]?.members ?? []
        if let target = members.first(where: { $0 != id && (expected[$0]?.contains(mouse) ?? false) }),
           engine.swap(id, target, on: space) {
            reapply(target)
        }
        reapply(id)
    }

    /// App (or user resize) changed a managed frame: apply the rule's `on_self_move`.
    private func selfMoved(_ id: WindowID, to current: CGRect) {
        guard let rule = engine.windows[id]?.rule else { return }
        var policy = rule.onSelfMove
        if policy == .snapBack {
            let now = Date()
            let recent = (snapBackTimes[id] ?? []).filter { now.timeIntervalSince($0) < 2 } + [now]
            snapBackTimes[id] = recent
            if recent.count > 3 {
                // The app keeps fighting (e.g. grid-snapping terminal): stop the loop.
                Log.wm.notice("window \(id) keeps moving itself; adopting its frame")
                policy = .adopt
            }
        }
        switch policy {
        case .snapBack:
            reapply(id)
        case .adopt:
            expected[id] = current
            lastRequested[id] = current
            markDirty(engine.adoptFrame(id, current))
        }
    }

    private func reapply(_ id: WindowID) {
        lastRequested[id] = nil
        if let space = engine.windows[id]?.space { markDirty([space]) }
    }

    // MARK: Focus

    private func isOnActiveSpace(_ id: WindowID) -> Bool {
        engine.windows[id]?.space.map(engine.snapshot.isActive) ?? false
    }

    private func display(of id: WindowID) -> DisplayInfo? {
        guard let space = engine.windows[id]?.space, let key = engine.snapshot.key(for: space) else { return nil }
        return displays.with(uuid: key.display)
    }

    /// WM-initiated focus. Warps the cursor when focus crosses displays.
    func focusWindow(_ id: WindowID, warp: Bool = true) {
        guard let element = elements[id], let w = engine.windows[id], !w.hidden else { return }
        let previousDisplay = engine.focused.flatMap(display(of:))
        NSRunningApplication(processIdentifier: w.pid)?.activate()
        applier.perform(pid: w.pid) {
            AX.setBool(element, kAXMainAttribute, true)
            AX.raise(element)
        }
        markDirty(engine.focus(id))
        if warp, engine.config.cursorFollowsFocus, let target = display(of: id), target.uuid != previousDisplay?.uuid,
           let frame = expected[id] ?? AX.frame(element) {
            CGWarpMouseCursorPosition(frame.center)
        }
        statusBar?.refresh()
    }

    /// Hit-tests on a background queue (a beachballing app under the cursor
    /// must not stall the main thread); at most one test in flight.
    private func focusFollowsMouse() {
        guard status == .running, engine.config.focusFollowsMouse, NSEvent.pressedMouseButtons == 0,
              !hitTestPending else { return }
        let now = Date()
        guard now.timeIntervalSince(lastMouseFocusCheck) > 0.06 else { return }
        lastMouseFocusCheck = now
        hitTestPending = true
        let point = currentMouseLocation()
        hitTestQueue.async { [weak self] in
            let hit = AX.windowAtPoint(point)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                hitTestPending = false
                guard let hit, let id = windowID(hit), id != engine.focused, engine.isTiled(id) else { return }
                focusWindow(id, warp: false)
            }
        }
    }

    // MARK: Commands

    /// The Space commands act on: the focused window's Space when it is
    /// visible, else the active Space of the display under the cursor.
    var currentSpace: SpaceID? {
        if let f = engine.focused, isOnActiveSpace(f), let space = engine.windows[f]?.space { return space }
        let display = displays.containing(currentMouseLocation()) ?? displays.first
        return display.flatMap { engine.snapshot.activeSpace(ofDisplay: $0.uuid) }
    }

    var currentDisplay: DisplayInfo? {
        if let f = engine.focused, isOnActiveSpace(f), let d = display(of: f) { return d }
        return displays.containing(currentMouseLocation()) ?? displays.first
    }

    func perform(_ command: Command) {
        if case .reload = command { reloadConfig(); return }
        guard status == .running else {
            if case .dumpState = command { dumpState() }
            return
        }
        let space = currentSpace
        let area = space.flatMap { engine.snapshot.key(for: $0) }.flatMap { displays.with(uuid: $0.display) }?.visibleFrame
        let outcome = engine.perform(command, space: space, area: area)
        markDirty(outcome.dirty)
        if let target = outcome.focus { focusWindow(target) }
        if let message = outcome.message { Log.wm.info("\(message, privacy: .public)") }
        switch outcome.action {
        case .sendToDisplay(let id, let cycle)?: send(id, toDisplay: cycle)
        case .focusDisplay(let cycle)?: focusDisplay(cycle)
        case .reload?: reloadConfig()
        case .dumpState?: dumpState()
        case nil: break
        }
        statusBar?.refresh()
    }

    private func runBinding(_ index: Int) {
        let bindings = engine.config.bindings
        guard bindings.indices.contains(index) else { return }
        perform(bindings[index].command)
    }

    private func neighborDisplay(from current: DisplayInfo?, _ cycle: Cycle) -> DisplayInfo? {
        guard displays.count > 1, let current, let i = displays.firstIndex(of: current) else { return nil }
        let step = cycle == .next ? 1 : displays.count - 1
        return displays[(i + step) % displays.count]
    }

    /// Moves a window onto the neighbouring display's active Space. A plain AX
    /// position change; macOS reassigns the Space natively. Cursor follows.
    private func send(_ id: WindowID, toDisplay cycle: Cycle) {
        guard let element = elements[id], let w = engine.windows[id],
              let frame = expected[id] ?? AX.frame(element),
              let target = neighborDisplay(from: displays.best(for: frame), cycle) else { return }
        let area = target.visibleFrame
        let size = CGSize(width: min(frame.width, area.width), height: min(frame.height, area.height))
        let destination = CGRect(x: area.midX - size.width / 2, y: area.midY - size.height / 2,
                                 width: size.width, height: size.height).integral
        applier.cancel(id)
        expected[id] = destination
        lastRequested[id] = nil
        inFlight[id, default: 0] += 1
        applier.apply(.init(window: id, pid: w.pid, element: element, target: destination, animation: nil)) { [weak self] id, requested, outcome in
            guard let self else { return }
            applied(id, requested: requested, outcome: outcome)
            markDirty(engine.setSpace(id, resolveSpace(for: id, pid: w.pid, element: elements[id])))
            CGWarpMouseCursorPosition(destination.center) // cursor follows the moved window
        }
    }

    private func focusDisplay(_ cycle: Cycle) {
        guard let target = neighborDisplay(from: currentDisplay, cycle) else { return }
        let space = engine.snapshot.activeSpace(ofDisplay: target.uuid)
        if let space, let id = engine.spaces[space]?.focus.entries.first(where: {
            guard let w = engine.windows[$0] else { return false }
            return w.space == space && !w.hidden && !w.minimized
        }) {
            focusWindow(id)
        } else {
            CGWarpMouseCursorPosition(target.visibleFrame.center)
        }
    }

    // MARK: Config

    struct ConfigLoadError: Error { let message: String }

    private func readConfig() -> Result<Config, ConfigLoadError> {
        let text: String
        do { text = try String(contentsOf: configURL, encoding: .utf8) } catch {
            return .failure(.init(message: "cannot read \(configURL.path): \(error.localizedDescription)"))
        }
        return Config.parse(text).mapError { ConfigLoadError(message: $0.description) }
    }

    /// The config file (or its directory) was just created by us: re-arm the
    /// watcher, which could not watch a missing directory, and load it.
    func configFileCreated() {
        watcher?.stop()
        watcher?.start()
        reloadConfig()
    }

    /// Hot reload. Invalid config is rejected and the previous one stays live.
    /// Live per-Space state (mode overrides, manual arrangements) is kept.
    func reloadConfig() {
        if case .invalidConfig = status { tryStart(); return }
        defer { if status != .running { tryStart() } } // e.g. `.blocked` after a settings fix
        guard FileManager.default.fileExists(atPath: configURL.path) else {
            configError = "Config file missing at \(configURL.path); keeping the current config"
            statusBar?.refresh()
            return
        }
        switch readConfig() {
        case .success(let config):
            configError = nil
            configNote = nil
            markDirty(engine.applyConfig(config))
            if status == .running { applyBindings() }
            Log.config.info("config reloaded")
        case .failure(let error):
            configError = error.message
            Log.config.error("rejected config: \(error.message, privacy: .public)")
            Notifier.post(title: "Ballast config rejected", body: error.message)
        }
        statusBar?.refresh()
    }

    private func applyBindings() {
        let failures = hotkeys?.setBindings(engine.config.bindings.map(\.hotkey)) ?? []
        for failure in failures { Log.config.error("hotkey: \(failure, privacy: .public)") }
    }

    // MARK: Diagnostics

    static var stateDumpURL: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            .map { $0.appendingPathComponent("dev.ballast/state.json") }
            ?? URL(fileURLWithPath: "/tmp/ballast-state.json")
    }

    /// Writes a JSON snapshot of live state (used by the smoke test).
    func dumpState() {
        var spaces: [[String: Any]] = []
        for (id, state) in engine.spaces.sorted(by: { $0.key < $1.key }) {
            let key = engine.snapshot.key(for: id)
            let area = key.flatMap { displays.with(uuid: $0.display) }?.visibleFrame ?? .zero
            let frames = engine.layout(space: id, area: area).frames
            spaces.append([
                "space_id": id,
                "display": key?.display ?? NSNull(),
                "ordinal": key?.ordinal ?? NSNull(),
                "active": engine.snapshot.isActive(id),
                "mode": engine.mode(for: id).rawValue,
                "mode_override": state.modeOverride?.rawValue ?? NSNull(),
                "monocle": state.monocle,
                "manual": state.manual,
                "live_order": state.liveOrder.map { describe($0) },
                "ideal_order": state.idealOrder.map { describe($0) },
                "frames": frames.map { ["window": describe($0.key), "x": $0.value.minX, "y": $0.value.minY,
                                        "w": $0.value.width, "h": $0.value.height] },
            ])
        }
        let root: [String: Any] = [
            "status": String(describing: status),
            "config": configURL.path,
            "config_error": configError ?? NSNull(),
            "focused": engine.focused.map { describe($0) } ?? NSNull(),
            "reduce_motion": reduceMotion,
            "stage_manager_passthrough": engine.passthrough,
            "displays": displays.map { ["uuid": $0.uuid, "name": $0.name] },
            "spaces": spaces,
        ]
        let url = Self.stateDumpURL
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: url, options: .atomic)
        } catch {
            Log.wm.error("state dump failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func describe(_ id: WindowID) -> [String: Any] {
        let w = engine.windows[id]
        return ["id": id, "app": w?.facts.appName ?? "?", "bundle": w?.facts.bundleID ?? "?",
                "title": w?.facts.title ?? "", "weight": w?.rule.weight ?? 1]
    }
}
