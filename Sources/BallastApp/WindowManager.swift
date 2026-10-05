import AppKit
@preconcurrency import ApplicationServices
import BallastCore

/// Orchestrator. Main thread only.
///
/// Observation (AX observers, NSWorkspace, SkyLight reads) → normalized
/// engine events → coalesced layout pass (≤ 1 per frame) → frame requests to
/// the per-app `FrameApplier` workers → results fed back as engine events.
@MainActor
final class WindowManager {
    enum Status: Equatable {
        case starting
        case needsAccessibility
        case invalidConfig(String)
        case unsupported(String)
        case blocked(String)
        case running
    }

    private(set) var status = Status.starting {
        didSet {
            // Carbon registrations are exclusive and system-wide: while not
            // running they would swallow the user's keys and do nothing.
            // `begin()` re-applies them.
            if oldValue == .running, status != .running { releaseHotkeys() }
            refreshSurfaces()
        }
    }
    var engine = Engine(config: Config())
    let configStore: ConfigStore

    let provider: SkyLightSpaceProvider?
    private let providerError: String?
    let applier = FrameApplier()
    private(set) var observers: [pid_t: AppObserver] = [:]
    /// Apps whose observer attach chain (see `attach`) is in flight.
    private var attaching = Set<pid_t>()
    private var dockObserver: AppObserver?
    var slots: [WindowID: WindowSlot] = [:]
    private(set) var displays: [DisplayInfo] = []
    private var statusBar: StatusBar?
    private var hotkeys: HotKeyCenter?
    /// Readable reasons the last `setBindings` could not register some hotkeys.
    private(set) var hotkeyFailures: [String] = []
    private var workspaceTokens: [NSObjectProtocol] = []
    private var eventMonitors: [Any] = []
    private var didPromptAccessibility = false

    // Layout-pass bookkeeping.
    private var dirty = Set<SpaceID>()
    private var passScheduled = false
    private var frameInterval = 1.0 / 60
    private(set) var reduceMotion = false
    private lazy var drag = DragController(manager: self)
    private let focusFlash = FocusFlash()
    /// The focus flash's hold modifier is down (alone, or with shift).
    private var holdDown = false
    /// Dock "Assign To Desktop" bindings, captured when an app launches.
    private var launchBindings: [pid_t: SpaceID] = [:]
    private var lastMouseFocusCheck = Date.distantPast
    /// Last focus transition, to recognise "AppKit moved focus, then the window closed".
    private var lastFocusLoss: (window: WindowID, at: Date)?
    /// Window ids in each Space's last plan.
    private var laidOut: [SpaceID: Set<WindowID>] = [:]
    private let hitTestQueue = DispatchQueue(label: "dev.ballast.hit-test", qos: .userInteractive)
    private var hitTestPending = false
    private var resyncPending = false
    /// A WM-initiated focus waiting for the pass it dirtied (see `focusWindow`).
    private var pendingFocus: (id: WindowID, covering: WindowID?, generation: UInt64)?
    /// Bumped by every WM-initiated focus, so a superseded deferred raise never runs.
    private var focusGeneration: UInt64 = 0
    private var axTrustObserverTarget: AXTrustObserverTarget?
    /// Other window managers running (see `SystemSettings.runningWindowManagers`).
    private(set) var otherWindowManagers: [String] = []

    init(configURL: URL) {
        configStore = ConfigStore(url: configURL)
        switch SkyLightSpaceProvider.make() {
        case .success(let p): provider = p; providerError = nil
        case .failure(let missing): provider = nil; providerError = missing.description
        }
        configStore.onChange = { [unowned self] in reloadConfig() }
        configStore.address = { [unowned self] space in
            engine.snapshot.key(for: space).map { engine.config.writeAddress(for: $0) }
        }
        configStore.clearOverrides = { [unowned self] space, size, count in
            engine.clearSettingOverrides(space, featureSize: size, featureCount: count)
        }
    }

    // MARK: Lifecycle

    func launch() {
        statusBar = StatusBar(manager: self)
        configStore.startWatching()
        hotkeys = HotKeyCenter { [weak self] index in self?.runBinding(index) }
        let axTrustTarget = AXTrustObserverTarget { [weak self] in
            // Posted before the trust database settles; check shortly after.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self?.tryStart() }
        }
        self.axTrustObserverTarget = axTrustTarget
        DistributedNotificationCenter.default().addObserver(
            axTrustTarget, selector: #selector(AXTrustObserverTarget.handle),
            name: Notification.Name("com.apple.accessibility.api"), object: nil,
            suspensionBehavior: .deliverImmediately
        )
        DistributedNotificationCenter.default().addObserver(
            forName: BallastCLI.commandNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let text = note.object as? String else { return }
            MainActor.assumeIsolated {
                switch Command.parse(text) {
                case .success(let command): self?.perform(command)
                case .failure(let error): Log.wm.error("ignored command '\(text, privacy: .public)': \(error.message, privacy: .public)")
                }
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
            if status != .blocked(reason) { Notifier.post(title: "Ballast is not managing windows", body: reason) }
            status = .blocked(reason)
            return
        }
        guard AXIsProcessTrusted() else {
            status = .needsAccessibility
            if !didPromptAccessibility {
                didPromptAccessibility = true
                let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
                _ = AXIsProcessTrustedWithOptions(options)
            }
            return
        }
        begin()
    }

    /// Not `private`: `@testable` test seam so tests can exercise the
    /// startup config load without going through `tryStart`'s AX/SkyLight
    /// gates (which would need real permissions and a live WM).
    func loadInitialConfig() -> Bool {
        guard !configStore.loaded else { return true }
        switch configStore.loadInitial() {
        case .success(let config):
            engine = Engine(config: config)
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
        if eventMonitors.isEmpty {
            observeMouse()
            observeModifiers()
        }
        attachDock(attempt: 0)
        checkWindowManagers()
        for app in NSWorkspace.shared.runningApplications { observe(app, restoring: true) }
        fullResync()
        Log.wm.info("managing \(self.engine.windows.count) windows")
    }

    /// Re-scans for other window managers; notifies when one newly appears.
    /// Runs at start, on app launch/quit, and when the menu opens: no polling.
    func checkWindowManagers() {
        let running = SystemSettings.runningWindowManagers
        guard running != otherWindowManagers else { return }
        let added = running.filter { !otherWindowManagers.contains($0) }
        otherWindowManagers = running
        if !added.isEmpty {
            Notifier.post(title: "\(added.joined(separator: ", ")) is also running",
                          body: "Two window managers fight over every window. Quit one of them.")
        }
        refreshSurfaces()
    }

    /// Dock posts the Mission Control (Exposé) notifications. Re-attached when
    /// Dock relaunches (e.g. `killall Dock` after changing Spaces settings).
    private func attachDock(attempt: Int) {
        guard status == .running, dockObserver == nil,
              let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else { return }
        let o = AppObserver(pid: dock.processIdentifier, bundleID: "com.apple.dock", name: "Dock",
                            notifications: AppObserver.dockNotifications)
        o.onNotification = { [weak self] in self?.appObserver($0, received: $1, element: $2) }
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
        func on(_ name: Notification.Name, _ handler: @escaping @MainActor (Notification) -> Void) {
            // `queue: .main` delivers on the main thread.
            workspaceTokens.append(center.addObserver(forName: name, object: nil, queue: .main) { note in
                // Notification is not Sendable but is delivered here on the main queue and never leaves it.
                nonisolated(unsafe) let note = note
                MainActor.assumeIsolated { handler(note) }
            })
        }
        on(NSWorkspace.didLaunchApplicationNotification) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            if app.bundleIdentifier == "com.apple.dock" { self?.attachDock(attempt: 0); return }
            self?.recordLaunchBinding(app)
            self?.observe(app)
            self?.checkWindowManagers()
        }
        on(NSWorkspace.didTerminateApplicationNotification) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            if let self, self.dockObserver?.pid == app.processIdentifier {
                self.dockObserver?.stop()
                self.dockObserver = nil
                return
            }
            self?.forget(pid: app.processIdentifier)
            self?.checkWindowManagers()
        }
        on(NSWorkspace.didActivateApplicationNotification) { [weak self] note in
            guard let self, let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            guard let observer = observers[app.processIdentifier] else { observe(app); return }
            discoverWindows(observer) { [weak self] focused in
                if let focused { self?.focusChanged(to: focused) }
            }
        }
        on(NSWorkspace.didHideApplicationNotification) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            self?.setHidden(pid: app.processIdentifier, true)
        }
        on(NSWorkspace.didUnhideApplicationNotification) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            self?.setHidden(pid: app.processIdentifier, false)
        }
        on(NSWorkspace.activeSpaceDidChangeNotification) { [weak self] _ in
            self?.focusFlash.hide()
            self?.requestResync()
        }
        on(NSWorkspace.didWakeNotification) { [weak self] _ in self?.requestResync() }
        on(NSWorkspace.accessibilityDisplayOptionsDidChangeNotification) { [weak self] _ in
            self?.reduceMotion = SystemSettings.reduceMotion
        }
        workspaceTokens.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.requestResync() } })
    }

    private func observeMouse() {
        eventMonitors += drag.monitors { [weak self] ids in
            guard let self else { return }
            for id in ids { slots[id]?.pendingCheck = true }
            scheduleLayout()
        }
        if let moved = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved, handler: { [weak self] _ in
            self?.focusFollowsMouse()
        }) { eventMonitors.append(moved) }
    }

    /// Global for other apps, local for Ballast's own windows (Settings).
    private func observeModifiers() {
        if let global = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged, handler: { [weak self] event in
            self?.modifiersChanged(event.modifierFlags)
        }) { eventMonitors.append(global) }
        if let local = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged, handler: { [weak self] event in
            self?.modifiersChanged(event.modifierFlags)
            return event
        }) { eventMonitors.append(local) }
    }

    /// `restoring`: the app was already running, so its windows sit where
    /// they were left (see `restoreArrangement`).
    private func observe(_ app: NSRunningApplication, restoring: Bool = false) {
        let pid = app.processIdentifier
        guard observers[pid] == nil, !attaching.contains(pid), pid != getpid(), app.activationPolicy != .prohibited,
              app.bundleIdentifier != "com.apple.dock" else { return }
        let observer = AppObserver(pid: pid, bundleID: app.bundleIdentifier, name: app.localizedName)
        observer.onNotification = { [weak self] in self?.appObserver($0, received: $1, element: $2) }
        attaching.insert(pid)
        attach(observer, attempt: 0, restoring: restoring)
    }

    /// Launching apps are not AX-ready immediately; retry a bounded number
    /// of times. The AX subscription runs on the app's own worker, so a hung
    /// app stalls only its own queue. `attaching` keeps a second activation
    /// from starting a second chain while one is in flight.
    private func attach(_ observer: AppObserver, attempt: Int, restoring: Bool) {
        let pid = observer.pid
        guard status == .running, observers[pid] == nil, attaching.contains(pid) else { attaching.remove(pid); return }
        applier.perform(pid: pid) {
            let created = observer.subscribe()
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                guard status == .running, observers[pid] == nil, attaching.contains(pid) else { attaching.remove(pid); return }
                if let created {
                    attaching.remove(pid)
                    observer.install(created)
                    observers[pid] = observer
                    applier.perform(pid: pid) {
                        // Chromium/Electron honour this: much faster resizes, no competing animation.
                        AX.setBool(observer.app, "AXEnhancedUserInterface", false)
                    }
                    discoverWindows(observer, restoring: restoring)
                } else if attempt < 8 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25 * Double(attempt + 1)) { [weak self] in
                        self?.attach(observer, attempt: attempt + 1, restoring: restoring)
                    }
                } else {
                    attaching.remove(pid)
                }
            }
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
        attaching.remove(pid)
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
        // AppKit reports subrole AXDialog for windows of hidden apps; re-read
        // once the app is unhidden so the resolved facts are correct again.
        guard !hidden else { return }
        for id in slots.keys where engine.windows[id]?.pid == pid { refreshFacts(id) }
    }

    // MARK: AX events

    func appObserver(_ observer: AppObserver, received notification: String, element: AXUIElement) {
        guard status == .running else { return }
        if observer === dockObserver {
            // Mission Control may have moved windows, added/removed/reordered desktops.
            if notification == "AXExposeExit" { requestResync() }
            return
        }
        switch notification {
        case kAXWindowCreatedNotification:
            track(element, observer: observer)
            discoverWindows(observer) // reconciles native tabs
        case kAXFocusedWindowChangedNotification, kAXMainWindowChangedNotification:
            // Only the active app's focused window is the user's focus. A
            // background app's changes when a window of it closes, or when
            // Ballast raises one; an app coming forward is picked up by its
            // activation instead.
            guard observer.pid == NSWorkspace.shared.frontmostApplication?.processIdentifier else { return }
            // A native tab switch posts no destruction: it shows up only as a
            // new main window and a changed `AXWindows`. A tab not tracked
            // yet can only be focused once discovery has committed it.
            let tracked = windowID(element) != nil
            if tracked { focusChanged(to: element) }
            discoverWindows(observer) { [weak self] focused in
                if !tracked { self?.focusChanged(to: focused ?? element) }
            }
        case kAXUIElementDestroyedNotification:
            if let id = slots.first(where: { CFEqual($0.value.element, element) })?.key {
                let hadFocus = lastFocusLoss.map { $0.window == id && Date().timeIntervalSince($0.at) < 0.5 } ?? false
                let removal = untrack(id, hadFocus: hadFocus)
                if let fallback = removal.focusFallback, isOnActiveSpace(fallback) { focusWindow(fallback) }
            }
        case kAXWindowMiniaturizedNotification, kAXWindowDeminiaturizedNotification:
            guard let id = windowID(element) else { return }
            let deminiaturized = notification == kAXWindowDeminiaturizedNotification
            markDirty(engine.setMinimized(id, !deminiaturized))
            // AppKit reports subrole AXDialog while minimized; re-read on restore.
            if deminiaturized { refreshFacts(id) }
        case kAXMovedNotification, kAXResizedNotification:
            // Only windows in the last plan can be displaced from their tile
            // (float-mode / passthrough Spaces are left alone). Our own
            // animation steps land here too: `applied` reschedules once the
            // request completes, so no pass is needed while one is in flight.
            guard let id = windowID(element), slots[id]?.expected != nil else { return }
            slots[id]?.pendingCheck = true
            if (slots[id]?.inFlight ?? 0) == 0 { scheduleLayout() }
        case kAXTitleChangedNotification:
            guard let id = windowID(element), engine.windows[id] != nil else { return }
            applier.perform(pid: observer.pid) {
                let title = AX.string(element, kAXTitleAttribute)
                DispatchQueue.main.async { [weak self] in
                    guard let self, var facts = engine.windows[id]?.facts else { return }
                    facts.title = title
                    markDirty(engine.updateFacts(id, facts))
                    if id == engine.frontmost { refreshSurfaces() }
                }
            }
        default:
            break
        }
    }

    private func windowID(_ element: AXUIElement) -> WindowID? {
        if let id = provider?.windowID(for: element), slots[id] != nil { return id }
        return slots.first { CFEqual($0.value.element, element) }?.key
    }

    @discardableResult
    private func untrack(_ id: WindowID, hadFocus: Bool = false) -> WindowRemoval {
        if let element = slots[id]?.element, let pid = engine.windows[id]?.pid {
            observers[pid]?.unobserve(window: element)
        }
        slots[id] = nil
        if focusFlash.target == id { focusFlash.hide() }
        drag.forget(id)
        applier.forget(window: id)
        let removal = engine.removeWindow(id, hadFocus: hadFocus)
        markDirty(removal.dirty)
        return removal
    }

    /// Space of a window: SkyLight membership, else the Dock binding of a
    /// just-launched app (so the layout is computed for where macOS will put
    /// it), else the active Space of the display it is on.
    func resolveSpace(for id: WindowID, pid: pid_t) -> SpaceID? {
        let snapshot = engine.snapshot
        let candidates = provider?.spaces(forWindow: id) ?? []
        if candidates.count == 1, let only = candidates.first { return only }
        if candidates.count > 1 { return nil } // on every Space: sticky by the app itself
        if let bound = launchBindings[pid] { return bound }
        guard let frame = Self.windowBounds(of: id), let display = displays.best(for: frame) else { return nil }
        return snapshot.activeSpace(ofDisplay: display.uuid)
    }

    /// Moves a window that just opened on a float Space to the next cascade
    /// slot (`float_placement = "cascade"`); never under Stage Manager, and
    /// never again afterwards. Frames come from the WindowServer's list, not AX.
    func cascade(_ id: WindowID, element: AXUIElement, on space: SpaceID) {
        let bounds = Self.windowBounds()
        guard !engine.passthrough, let w = engine.windows[id], w.isManaged, !w.isFloating,
              engine.settings(for: space).floatPlacement == .cascade,
              let current = bounds[id],
              let display = displays.best(for: current) ?? displays.first else { return }
        let occupied = engine.windows.compactMap { other -> CGPoint? in
            guard other.key != id, other.value.space == space else { return nil }
            return bounds[other.key]?.origin
        }
        let frame = Cascade.frame(size: current.size, in: display.visibleFrame,
                                  outerGap: engine.settings(for: space).gaps.outer, occupied: occupied)
        applier.apply(.init(window: id, pid: w.pid, element: element, target: frame, animation: nil)) { _, _, _ in }
    }

    func placeFloating(_ id: WindowID, element: AXUIElement) {
        guard let w = engine.windows[id], w.isFloating, let current = Self.windowBounds(of: id),
              let display = displays.best(for: current) ?? displays.first,
              let frame = engine.initialFrame(for: id, current: current, area: display.visibleFrame,
                                              mouse: currentMouseLocation()) else { return }
        applier.apply(.init(window: id, pid: w.pid, element: element, target: frame, animation: nil)) { _, _, _ in }
    }

    private func focusChanged(to element: AXUIElement) {
        guard let id = windowID(element) else { return }
        if let previous = engine.focused, previous != id { lastFocusLoss = (previous, Date()) }
        markDirty(engine.focus(id))
        if holdDown { holdFocusFlash() }
        refreshSurfaces()
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
        let front = engine.focused == nil ? NSWorkspace.shared.frontmostApplication?.processIdentifier : nil
        for observer in observers.values {
            if observer.pid == front {
                // Focus is read on the worker and applied once discovery has committed.
                discoverWindows(observer, restoring: true) { [weak self] focused in
                    guard let self, engine.focused == nil, let focused else { return }
                    focusChanged(to: focused)
                }
            } else {
                discoverWindows(observer, restoring: true)
            }
        }
        reconcileMembership()
        for display in engine.snapshot.displays {
            if let active = display.activeSpace { dirty.insert(active) }
        }
        scheduleLayout()
        refreshSurfaces()
    }

    /// Detects windows moved between Spaces by native tools (Mission Control
    /// drag, Dock assignment, display moves).
    private func reconcileMembership() {
        guard let provider else { return }
        var location: [WindowID: SpaceID] = [:]
        var ambiguous = Set<WindowID>()
        for display in engine.snapshot.displays {
            for space in display.spaces {
                for id in provider.windowIDs(onSpace: space.id) where slots[id] != nil {
                    if location[id] != nil, location[id] != space.id { ambiguous.insert(id) }
                    location[id] = space.id
                }
            }
        }
        for id in slots.keys {
            let pid = engine.windows[id]?.pid ?? 0
            let space = ambiguous.contains(id) ? nil
                : (location[id] ?? resolveSpace(for: id, pid: pid))
            markDirty(engine.setSpace(id, space))
        }
        launchBindings.removeAll()
    }

    // MARK: Layout pass

    func markDirty(_ spaces: Set<SpaceID>) {
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

    /// Coalesces `fullResync()` calls that can arrive several at once (e.g.
    /// Mission Control exit plus the Space-change notification it triggers).
    private func requestResync() {
        resyncPending = true
        scheduleLayout()
    }

    private func runPass() {
        passScheduled = false
        guard status == .running else {
            // A resync was requested (Space change, wake, display change,
            // Mission Control exit, `relayout`) while not running. If that's
            // because Spaces settings were wrong and have since been fixed,
            // this is the only place left to notice: none of those triggers
            // reach `fullResync()`'s own `.blocked` recovery branch, because
            // they all end at this guard first.
            if resyncPending, case .blocked = status {
                resyncPending = false
                tryStart()
            }
            return
        }
        if resyncPending {
            resyncPending = false
            fullResync()
            // `fullResync` can itself set `.blocked` (Spaces settings changed
            // while running) or transition away from `.running` some other
            // way. Laying out dirty Spaces from a snapshot that's already
            // known stale, or bringing a window forward on it, would fight
            // whatever state Ballast is settling into next.
            guard status == .running else {
                pendingFocus = nil
                return
            }
        }
        classifyExternalMoves()
        let spaces = dirty
        dirty.removeAll()
        // Spaces can vanish (Mission Control deletion) between the event that
        // dirtied them and this pass; drop their stale `laidOut` membership so
        // a reused ordinal never inherits a phantom departure set.
        laidOut = laidOut.filter { engine.spaces[$0.key] != nil }
        var departed = Set<WindowID>()
        var placed = Set<WindowID>()
        for space in spaces.sorted() {
            let result = layout(space)
            departed.formUnion(result.departed)
            placed.formUnion(result.placed)
        }
        // Left a plan and entered none this pass: re-sent when it comes back, not a displaced tile meanwhile.
        for id in departed.subtracting(placed) {
            slots[id]?.lastRequested = nil
            slots[id]?.expected = nil
        }
        // No pass slid a window off the newly focused one: bring it forward now.
        var worked = !spaces.isEmpty
        if let pending = pendingFocus {
            pendingFocus = nil
            worked = true
            bringForward(pending.id)
        }
        // A layout change mid-drag (a window opened or closed) moves the landing frame.
        if !spaces.isEmpty { drag.updateDropPreview(force: true) }
        // Focus can scroll a deck: the flash follows its window to the new slot.
        if let id = focusFlash.target, let frame = slots[id]?.expected { focusFlash.move(to: frame) }
        if worked { refreshSurfaces() }
    }

    private func layout(_ space: SpaceID) -> (departed: Set<WindowID>, placed: Set<WindowID>) {
        guard let key = engine.snapshot.key(for: space), let display = displays.with(uuid: key.display) else { return ([], []) }
        let active = engine.snapshot.isActive(space)
        let plan = engine.layout(space: space, area: display.visibleFrame)
        let previous = laidOut[space] ?? []
        let planned = Set(plan.frames.keys)
        laidOut[space] = planned
        // Same windows as last pass: a scrolling column's windows moved
        // because focus (or a swap) scrolled the view, so they slide too.
        let scroll = previous == planned ? plan.scrolling : []
        let anim = engine.config.animation
        let animates = active && anim.enabled && !reduceMotion && anim.duration > 0 && !plan.monocle
        // The previously focused window sliding off the newly focused one
        // stays in front until its slide ends, uncovering the new window.
        var revealing: (focus: WindowID, generation: UInt64)?
        for (id, frame) in plan.frames.sorted(by: { $0.key < $1.key }) {
            guard let element = slots[id]?.element, let w = engine.windows[id] else { continue }
            if slots[id]?.lastRequested == frame { continue }
            let from = slots[id]?.lastRequested
            slots[id]?.lastRequested = frame
            slots[id]?.expected = frame
            slots[id]?.inFlight += 1
            // Strategy (a): on an active Space, only the focused window and a
            // scrolling deck's windows interpolate.
            let animate = animates && (id == engine.focused || scroll.contains(id))
            var reveal: (focus: WindowID, generation: UInt64)?
            if animate, let pending = pendingFocus, pending.covering == id, let from,
               let target = plan.frames[pending.id], Self.overlaps(from, target) {
                reveal = (pending.id, pending.generation)
                revealing = reveal
                pendingFocus = nil
            }
            let request = FrameApplier.Request(
                window: id, pid: w.pid, element: element, target: frame,
                animation: animate ? (anim.duration, anim.easing, frameInterval) : nil)
            let revealed = reveal
            applier.apply(request) { [weak self] id, requested, outcome in
                guard let self else { return }
                applied(id, requested: requested, outcome: outcome)
                if let revealed { finishReveal(revealed.focus, generation: revealed.generation, space: space) }
            }
        }
        if pendingFocus.map({ plan.frames[$0.id] != nil }) == true, let pending = pendingFocus {
            // Focus landed on this Space without a slide to wait for.
            pendingFocus = nil
            bringForward(pending.id)
        }
        if revealing == nil, active { raiseDeck(plan) }
        return (previous.subtracting(planned), planned)
    }

    /// The deferred half of `focusWindow`, once the window covering the
    /// newly focused one has slid away: skipped if focus has moved on since.
    private func finishReveal(_ id: WindowID, generation: UInt64, space: SpaceID) {
        guard generation == focusGeneration, engine.focused == id else { return }
        bringForward(id)
        // Recomputed: passes during the slide may have changed the deck.
        guard engine.snapshot.isActive(space), let key = engine.snapshot.key(for: space),
              let area = displays.with(uuid: key.display)?.visibleFrame else { return }
        raiseDeck(engine.layout(space: space, area: area))
    }

    /// Puts a scrolling deck's windows back in their deck order.
    private func raiseDeck(_ plan: SpaceLayout) {
        if !plan.behind.isEmpty {
            // A window scrolled out of view can sit in front of the tile it
            // belongs behind: it had focus before the view scrolled, or its
            // app brought all of its windows forward.
            for tile in plan.tilesToRaise(frontToBack: Self.windowsFrontToBack()) { raiseWindow(tile) }
        }
        if let raise = plan.raise { raiseWindow(raise) }
    }

    private static func overlaps(_ a: CGRect, _ b: CGRect) -> Bool {
        let common = a.intersection(b)
        return !common.isNull && common.width > 0 && common.height > 0
    }

    private func raiseWindow(_ id: WindowID) {
        guard let element = slots[id]?.element, let pid = engine.windows[id]?.pid else { return }
        applier.perform(pid: pid) { AX.raise(element) }
    }

    /// On-screen windows, front to back.
    private static func windowsFrontToBack() -> [WindowID] {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        return list.compactMap { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value }
    }

    /// `kCGWindowBounds` per window id, straight from the WindowServer: no AX
    /// round trip, so safe on main even for an unresponsive app. Same
    /// top-left global coordinates as AX frames.
    static func windowBounds(_ options: CGWindowListOption = .optionAll,
                             relativeTo window: CGWindowID = kCGNullWindowID) -> [WindowID: CGRect] {
        let list = CGWindowListCopyWindowInfo(options, window) as? [[String: Any]] ?? []
        var bounds: [WindowID: CGRect] = [:]
        for info in list {
            guard let id = (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                  let dict = info[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: dict as CFDictionary) else { continue }
            bounds[id] = rect
        }
        return bounds
    }

    static func windowBounds(of id: WindowID) -> CGRect? {
        windowBounds(.optionIncludingWindow, relativeTo: id)[id]
    }

    /// Re-reads a window's facts on its app's worker and applies them on main.
    private func refreshFacts(_ id: WindowID) {
        guard let element = slots[id]?.element, let pid = engine.windows[id]?.pid, let observer = observers[pid] else { return }
        applier.perform(pid: pid) {
            let facts = WindowDiscovery.facts(element, observer: observer)
            DispatchQueue.main.async { [weak self] in
                guard let self, slots[id] != nil else { return }
                markDirty(engine.updateFacts(id, facts))
            }
        }
    }

    private func applied(_ id: WindowID, requested: CGRect, outcome: FrameApplier.Outcome) {
        if let n = slots[id]?.inFlight { slots[id]?.inFlight = max(0, n - 1) }
        guard let slot = slots[id] else { return }
        let current = slot.lastRequested == requested
        guard let actual = outcome.actual else {
            // Unreadable (app busy launching): let the next event retry. A
            // superseded request says nothing about the window.
            if current, outcome.completed { slots[id]?.lastRequested = nil }
            Log.ax.debug("window \(id) did not accept a frame")
            return
        }
        if current {
            slots[id]?.expected = actual
            if id == focusFlash.target { focusFlash.move(to: actual) }
        }
        // Refused to shrink: remember the minimum and reflow the rest around it.
        // Only a completed, still-current request says anything about constraints.
        if outcome.completed, current,
           actual.width > requested.width + 2 || actual.height > requested.height + 2 {
            markDirty(engine.learnMinSize(id, Self.learnedMinSize(requested: requested, actual: actual)))
        }
        if slot.pendingCheck { scheduleLayout() }
    }

    /// The size to feed `Engine.learnMinSize` for a completed, still-current
    /// frame request: the actual length on the axis the window refused to
    /// shrink to (more than 2 pt over the request), or 0 for an axis it
    /// accepted. `learnMinSize` max-merges each axis independently, so a 0
    /// leaves any earlier, unrelated learnt constraint on that axis untouched
    /// instead of clamping it down (or up) to this request's length.
    static func learnedMinSize(requested: CGRect, actual: CGRect) -> CGSize {
        let refusedWidth = actual.width > requested.width + 2 ? actual.width : 0
        let refusedHeight = actual.height > requested.height + 2 ? actual.height : 0
        return CGSize(width: refusedWidth, height: refusedHeight)
    }

    /// Classifies frame changes the WM did not make. The AX read that
    /// verifies the frame runs on the app's own worker (never the main
    /// thread), so a slow app only delays its own classification.
    private func classifyExternalMoves() {
        let pending = slots.filter { $0.value.pendingCheck }.keys
        guard !pending.isEmpty else { return }
        let mouseDown = NSEvent.pressedMouseButtons & 1 != 0
        for id in pending {
            if (slots[id]?.inFlight ?? 0) > 0 { continue }
            slots[id]?.pendingCheck = false
            if mouseDown {
                drag.moved(id) // resolved on mouse-up
                continue
            }
            let (dragged, dropPoint) = drag.release(id)
            guard let element = slots[id]?.element, let pid = engine.windows[id]?.pid else { continue }
            applier.perform(pid: pid) { [weak self] in
                let current = AX.frame(element)
                DispatchQueue.main.async {
                    guard let self, let want = self.slots[id]?.expected, let current,
                          !current.approximatelyEquals(want) else { return }
                    if dragged {
                        self.userDragged(id, to: current, from: want, at: dropPoint ?? currentMouseLocation())
                    } else {
                        self.selfMoved(id, to: current)
                    }
                }
            }
        }
    }

    /// A user drag between tiles is always a swap intent (or a display move);
    /// a drag of a tile's edge resizes the layout around it.
    private func userDragged(_ id: WindowID, to current: CGRect, from want: CGRect, at point: CGPoint) {
        guard let space = engine.windows[id]?.space else {
            selfMoved(id, to: current)
            return
        }
        if DragController.isResize(current, from: want) {
            userResized(id, to: current, from: want, on: space)
            return
        }
        switch drag.dropTarget(for: id, at: point) {
        case .display?:
            // Dropped on another display: macOS reassigns the Space natively.
            let newSpace = resolveSpace(for: id, pid: engine.windows[id]?.pid ?? 0)
            markDirty(engine.setSpace(id, newSpace))
        case .swap(let target)?:
            if engine.swap(id, target, on: space) { reapply(target) }
        case nil:
            break
        }
        reapply(id)
    }

    /// Moves the boundaries under the dragged edges (`Engine.resizeTile`);
    /// an edge on no boundary falls back to the rule's `on_self_move`.
    private func userResized(_ id: WindowID, to current: CGRect, from want: CGRect, on space: SpaceID) {
        guard let key = engine.snapshot.key(for: space), let display = displays.with(uuid: key.display) else {
            selfMoved(id, to: current)
            return
        }
        let outcome = engine.resizeTile(id, from: want, to: current, area: display.visibleFrame)
        guard !outcome.dirty.isEmpty else {
            selfMoved(id, to: current)
            return
        }
        if let change = outcome.settings { configStore.schedulePersist(change) }
        reapply(id)
        markDirty(outcome.dirty)
        refreshSurfaces()
    }

    /// App (or user resize) changed a managed frame: apply the rule's `on_self_move`.
    private func selfMoved(_ id: WindowID, to current: CGRect) {
        guard let rule = engine.windows[id]?.rule else { return }
        var policy = rule.onSelfMove
        if policy == .snapBack {
            let now = Date()
            let recent = (slots[id]?.snapBackTimes ?? []).filter { now.timeIntervalSince($0) < 2 } + [now]
            slots[id]?.snapBackTimes = recent
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
            slots[id]?.expected = current
            slots[id]?.lastRequested = current
            markDirty(engine.adoptFrame(id, current))
        }
    }

    private func reapply(_ id: WindowID) {
        slots[id]?.lastRequested = nil
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
    /// When focus scrolls a deck, the window comes forward (activation and
    /// raise) once the previously focused window has slid off it.
    func focusWindow(_ id: WindowID, warp: Bool = true) {
        guard slots[id] != nil, let w = engine.windows[id], !w.hidden, !w.backgroundTab else { return }
        let previousDisplay = engine.focused.flatMap(display(of:)) ?? displays.containing(currentMouseLocation())
        let covering = engine.focused == id ? nil : engine.focused
        focusGeneration &+= 1
        let spaces = engine.focus(id)
        if spaces.isEmpty {
            pendingFocus = nil
            bringForward(id)
        } else {
            pendingFocus = (id, covering, focusGeneration)
            markDirty(spaces)
        }
        if holdDown { holdFocusFlash() }
        if warp, engine.config.cursorFollowsFocus, let target = display(of: id), target.uuid != previousDisplay?.uuid,
           let frame = slots[id]?.expected ?? Self.windowBounds(of: id) {
            CGWarpMouseCursorPosition(frame.center)
        }
        refreshSurfaces()
    }

    /// Activates `id`'s app and makes `id` its frontmost, main window.
    private func bringForward(_ id: WindowID) {
        guard let element = slots[id]?.element, let w = engine.windows[id], !w.hidden, !w.backgroundTab else { return }
        NSRunningApplication(processIdentifier: w.pid)?.activate()
        applier.perform(pid: w.pid) {
            AX.setBool(element, kAXMainAttribute, true)
            AX.raise(element)
        }
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

    /// Where the focus flash draws around `id`: its planned frame, else its
    /// live one (a floating window Ballast never placed).
    private func flashFrame(_ id: WindowID) -> CGRect? {
        guard isOnActiveSpace(id), let w = engine.windows[id], !w.hidden, !w.backgroundTab, !w.minimized else { return nil }
        return slots[id]?.expected ?? Self.windowBounds(of: id)
    }

    /// After a command moved focus.
    private func flashFocus() {
        let settings = engine.config.focusFlash
        guard settings.enabled, let id = engine.focused, let frame = flashFrame(id) else { return }
        focusFlash.flash(id, frame: frame, duration: settings.duration, fade: !reduceMotion)
    }

    private func holdFocusFlash() {
        guard let id = engine.focused, let frame = flashFrame(id) else { focusFlash.release(); return }
        focusFlash.hold(id, frame: frame)
    }

    /// The hold modifier counts alone or with shift, so `alt+shift+…`
    /// commands show the window they act on; any other modifier (`hyper`)
    /// doesn't.
    private func modifiersChanged(_ flags: NSEvent.ModifierFlags) {
        let settings = engine.config.focusFlash
        let required: NSEvent.ModifierFlags? = switch settings.hold {
        case .alt: .option
        case .ctrl: .control
        case .cmd: .command
        case .none: nil
        }
        let pressed = flags.intersection([.option, .control, .command])
        let down = status == .running && settings.enabled && required != nil && pressed == required
        guard down != holdDown else { return }
        holdDown = down
        if down { holdFocusFlash() } else { focusFlash.release() }
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
        let focusedBefore = engine.focused
        let areas = Dictionary(displays.map { ($0.uuid, $0.visibleFrame) }, uniquingKeysWith: { first, _ in first })
        let outcome = engine.perform(command, space: space, areas: areas)
        markDirty(outcome.dirty)
        if let target = outcome.focus { focusWindow(target) }
        if let message = outcome.message { Log.wm.info("\(message, privacy: .public)") }
        if let change = outcome.settings { configStore.schedulePersist(change) }
        switch outcome.action {
        case .sendToDisplay(let id, let cycle)?: send(id, toDisplay: cycle)
        case .focusDisplay(let cycle)?: focusDisplay(cycle)
        case .reload?: reloadConfig()
        case .relayout(let space)?: relayout(space)
        case .dumpState?: dumpState()
        case .close(let id)?: close(id)
        case .fullscreen(let id)?: toggleFullscreen(id)
        case .raiseFloats(let ids)?: raiseFloats(ids)
        case .rescue?: rescue()
        case nil: break
        }
        if engine.focused != focusedBefore { flashFocus() }
        refreshSurfaces()
    }

    /// Forces every tile on `space` to be re-sent (identical requests are
    /// normally skipped) and re-discovers windows before the next pass.
    private func relayout(_ space: SpaceID) {
        for id in laidOut[space] ?? [] {
            slots[id]?.lastRequested = nil
            slots[id]?.expected = nil
        }
        requestResync()
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
        guard let element = slots[id]?.element, let w = engine.windows[id],
              let frame = slots[id]?.expected ?? Self.windowBounds(of: id),
              let target = neighborDisplay(from: displays.best(for: frame), cycle) else { return }
        let destination = frame.centered(in: target.visibleFrame)
        // Only a window that's actually a member of a laid-out Space's plan
        // gets its departure cleaned up by `layout()`; setting `expected`
        // for a floating window (or one on a float-mode desktop) would
        // leave a stale entry forever, wrongly opening the moved/resized
        // gate meant only for tiled windows and poisoning the next
        // `send-to-display`'s source frame.
        if laidOut.values.contains(where: { $0.contains(id) }) { slots[id]?.expected = destination }
        slots[id]?.lastRequested = nil
        slots[id]?.inFlight += 1
        applier.apply(.init(window: id, pid: w.pid, element: element, target: destination, animation: nil)) { [weak self] id, requested, outcome in
            guard let self else { return }
            applied(id, requested: requested, outcome: outcome)
            markDirty(engine.setSpace(id, resolveSpace(for: id, pid: w.pid)))
            if engine.config.cursorFollowsFocus, let actual = outcome.actual, displays.best(for: actual)?.uuid == target.uuid {
                CGWarpMouseCursorPosition(actual.center) // cursor follows the moved window
            }
        }
    }

    /// Presses `id`'s close button: the app decides what closing means (it may ask to save).
    private func close(_ id: WindowID) {
        guard let element = slots[id]?.element, let pid = engine.windows[id]?.pid else { return }
        applier.perform(pid: pid) {
            guard let button = AX.element(element, kAXCloseButtonAttribute) else { return }
            AXUIElementPerformAction(button, kAXPressAction as CFString)
        }
    }

    private func toggleFullscreen(_ id: WindowID) {
        guard let element = slots[id]?.element, let pid = engine.windows[id]?.pid else { return }
        applier.perform(pid: pid) {
            AX.setBool(element, "AXFullScreen", !(AX.bool(element, "AXFullScreen") ?? false))
        }
    }

    /// Brings `ids` forward back to front in their current stacking, one at a
    /// time: each app's AX runs on its own worker, so the next waits for the
    /// last. A plain `AXRaise` never lifts a window above the active app's, so
    /// each window's app is activated too; focus ends on the frontmost float.
    private func raiseFloats(_ ids: [WindowID]) {
        let stacking = Self.windowsFrontToBack()
        let rank = Dictionary(stacking.enumerated().map { ($1, $0) }, uniquingKeysWith: min)
        raiseInOrder(ids.sorted { (rank[$0] ?? .max) > (rank[$1] ?? .max) }[...])
    }

    private func raiseInOrder(_ ids: ArraySlice<WindowID>) {
        guard let id = ids.first else { return }
        guard let element = slots[id]?.element, let pid = engine.windows[id]?.pid else { raiseInOrder(ids.dropFirst()); return }
        NSRunningApplication(processIdentifier: pid)?.activate()
        applier.perform(pid: pid) { [weak self] in
            AX.setBool(element, kAXMainAttribute, true)
            AX.raise(element)
            DispatchQueue.main.async { self?.raiseInOrder(ids.dropFirst()) }
        }
    }

    /// Centers every floating window on a visible Space that is mostly off
    /// the displays on the current display.
    private func rescue() {
        guard let target = currentDisplay else { return }
        let screens = displays.map(\.frame)
        let bounds = Self.windowBounds()
        for (id, w) in engine.windows where w.isManaged && !engine.isTiled(id) && !w.minimized && !w.hidden
            && !w.backgroundTab && isOnActiveSpace(id) {
            guard let frame = bounds[id], frame.isMostlyOffscreen(screens), let element = slots[id]?.element else { continue }
            applier.apply(.init(window: id, pid: w.pid, element: element, target: frame.centered(in: target.visibleFrame),
                                animation: nil)) { _, _, _ in }
        }
    }

    private func focusDisplay(_ cycle: Cycle) {
        guard let target = neighborDisplay(from: currentDisplay, cycle) else { return }
        let space = engine.snapshot.activeSpace(ofDisplay: target.uuid)
        if let space, let id = engine.spaces[space]?.focus.entries.first(where: {
            guard let w = engine.windows[$0] else { return false }
            return w.space == space && !w.hidden && !w.backgroundTab && !w.minimized
        }) {
            focusWindow(id)
        } else if engine.config.cursorFollowsFocus {
            CGWarpMouseCursorPosition(target.visibleFrame.center)
        }
    }

    // MARK: Config

    /// Hot reload. Invalid config is rejected and the previous one stays live.
    /// Live per-Space state (mode overrides, manual arrangements) is kept.
    func reloadConfig() {
        defer { NotificationCenter.default.post(name: Self.configDidChange, object: self) }
        // Before `launch()` (e.g. tests driving `loadInitialConfig`/`configStore.edit`
        // on an unlaunched manager) the config is applied but `tryStart` never runs.
        if case .invalidConfig = status { if configStore.isWatching { tryStart() }; return }
        defer { if configStore.isWatching, status != .running { tryStart() } } // e.g. `.blocked` after a settings fix
        if let config = configStore.reload() {
            markDirty(engine.applyConfig(config))
            if !config.focusFlash.enabled { focusFlash.hide() }
            if status == .running { applyBindings() }
            Log.config.info("config reloaded")
        }
        refreshSurfaces()
    }

    private func applyBindings() {
        guard !hotkeysSuspended else { return }
        hotkeyFailures = hotkeys?.setBindings(engine.config.bindings.map(\.hotkey)) ?? []
        for failure in hotkeyFailures { Log.config.error("hotkey: \(failure, privacy: .public)") }
        refreshSurfaces()
    }

    private func releaseHotkeys() {
        hotkeys?.removeAll()
        hotkeyFailures = []
    }

    /// Ballast's global hotkeys are off while this is true, so recording a new
    /// hotkey in Preferences doesn't also run the command already bound to it.
    private var hotkeysSuspended = false

    func setHotkeysSuspended(_ suspended: Bool) {
        guard suspended != hotkeysSuspended else { return }
        hotkeysSuspended = suspended
        if suspended {
            releaseHotkeys()
            refreshSurfaces()
        } else if status == .running {
            applyBindings()
        }
    }

    /// Posted after every `reloadConfig()` attempt, success or rejection.
    static let configDidChange = Notification.Name("dev.ballast.configDidChange")

    /// Posted whenever live state the menu bar or the Window Inspector shows
    /// may have changed: focus, a layout pass, a resync, a reload, the
    /// frontmost window's title.
    static let stateDidChange = Notification.Name("dev.ballast.stateDidChange")

    private func refreshSurfaces() {
        statusBar?.refresh()
        NotificationCenter.default.post(name: Self.stateDidChange, object: self)
    }

    /// The live, validated config (menu bar and Preferences read from this).
    var config: Config { engine.config }

    func spaceKey(for space: SpaceID) -> SpaceKey? {
        engine.snapshot.key(for: space)
    }

    struct DesktopInfo: Equatable {
        let key: SpaceKey
        let space: SpaceID
        let displayName: String
        let builtin: Bool
        let isActive: Bool
    }

    /// Every user (non-fullscreen) Space of every connected display, in
    /// display order (matching `displays`) then ordinal.
    var desktops: [DesktopInfo] {
        let snapshot = engine.snapshot
        var result: [DesktopInfo] = []
        for display in displays {
            guard let entry = snapshot.displays.first(where: { $0.displayUUID == display.uuid }) else { continue }
            var ordinal = 0
            for info in entry.spaces where info.kind == .user {
                ordinal += 1
                result.append(DesktopInfo(
                    key: SpaceKey(display: entry.displayUUID, ordinal: ordinal, uuid: info.uuid), space: info.id,
                    displayName: display.name, builtin: entry.builtin, isActive: entry.activeSpace == info.id))
            }
        }
        return result
    }
}

/// Everything the manager keeps per tracked window; one removal untracks it.
struct WindowSlot {
    let element: AXUIElement
    /// Frame the window should have (last requested, then last observed result).
    var expected: CGRect?
    /// Last frame sent; identical requests are not re-sent (a window that
    /// refused a size is not retried every pass).
    var lastRequested: CGRect?
    var inFlight = 0
    /// Tracked since its app's tabs were last reconciled: it may be the tab
    /// that just came in front of a tab that vanished.
    var arrived = false
    /// Its moved/resized notification still needs classifying.
    var pendingCheck = false
    var snapBackTimes: [Date] = []
    /// Where discovery found an already-open window, before Ballast moved it.
    var seed: CGRect?
}

/// Bridges `com.apple.accessibility.api` to `WindowManager` with
/// `.deliverImmediately`, which only the selector-based distributed
/// notification API can request. Ballast is an `.accessory` app that is
/// almost never active, so the default coalescing suspension behaviour would
/// otherwise hold this notification until Ballast is next activated.
private final class AXTrustObserverTarget: NSObject {
    private let handler: () -> Void

    init(_ handler: @escaping () -> Void) {
        self.handler = handler
    }

    @objc func handle(_ note: Notification) {
        handler()
    }
}
