import AppKit
import ApplicationServices
import BallastCore
import SwiftUI

/// Single reusable "Window Inspector" panel: shows why the currently
/// focused window floats or tiles, its Space/display and a couple of
/// one-click rule shortcuts. A non-activating panel so opening or reading it
/// never steals focus from the inspected window.
enum InspectorWindow {
    private static var panel: NSPanel?
    private static var model: InspectorModel?
    private static var delegate: InspectorPanelDelegate?

    static func show(manager: WindowManager) {
        if let panel, let model {
            model.startObserving()
            model.refresh()
            panel.orderFrontRegardless()
            return
        }

        let model = InspectorModel(manager: manager)
        Self.model = model

        let hosting = NSHostingView(rootView: InspectorContentView(model: model))
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 560),
            styleMask: [.titled, .closable, .resizable, .utilityWindow, .nonactivatingPanel],
            backing: .buffered, defer: false)
        panel.title = "Window Inspector"
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = hosting
        panel.minSize = NSSize(width: 320, height: 360)
        panel.setContentSize(NSSize(width: 420, height: 560))
        panel.center()

        let delegate = InspectorPanelDelegate(model: model)
        panel.delegate = delegate
        Self.delegate = delegate
        Self.panel = panel

        model.startObserving()
        model.refresh()
        // Shown without becoming key: typing keeps going to the inspected app.
        panel.orderFrontRegardless()
    }
}

/// Stops the model's observers while the panel is closed; restarted by
/// `InspectorWindow.show`.
private final class InspectorPanelDelegate: NSObject, NSWindowDelegate {
    private let model: InspectorModel
    init(model: InspectorModel) { self.model = model }
    func windowWillClose(_ notification: Notification) { model.stopObserving() }
}

private struct InspectorContentView: View {
    @ObservedObject var model: InspectorModel

    var body: some View {
        InspectorView(
            snapshot: model.snapshot,
            editError: model.editError,
            onCopy: { model.copyToPasteboard() },
            onFloatTitled: { model.floatTitled() },
            onAlwaysFloat: { model.setAlwaysFloat(true) },
            onAlwaysTile: { model.setAlwaysFloat(false) }
        )
    }
}

// MARK: - Model

/// Raw, thread-agnostic AX reads for the focused window, gathered on the
/// target app's serial worker before hopping back to the main thread to
/// merge with engine state.
private struct RawWindowFacts {
    let title: String?
    let role: String?
    let subrole: String?
    let modal: Bool?
    let resizable: Bool?
    let closeButtonPresent: Bool
    let closeEnabled: Bool?
    let fullScreenButton: Bool?
    let nativeFullScreen: Bool
    let frame: CGRect?
}

/// How the inspected window's Space was resolved.
private enum SpaceResolution {
    case space(SpaceID)
    /// More than one Space claims the window (sticky).
    case sticky
    case unknown
}

/// Refreshes `snapshot` for the frontmost app's focused window, coalesced to
/// at most one refresh per main run-loop turn, and only while observing
/// (i.e. while the panel is visible).
final class InspectorModel: ObservableObject {
    @Published private(set) var snapshot = InspectorSnapshot.empty
    @Published var editError: String?

    let manager: WindowManager
    private var tokens: [(NotificationCenter, NSObjectProtocol)] = []
    private var refreshScheduled = false
    /// The last app inspected; kept when the frontmost app becomes Ballast
    /// itself (e.g. clicking into the panel), so the panel keeps showing the
    /// window the user was actually looking at.
    private var lastTargetPID: pid_t?

    init(manager: WindowManager) {
        self.manager = manager
    }

    func startObserving() {
        guard tokens.isEmpty else { return }
        let center = NotificationCenter.default
        let workspace = NSWorkspace.shared.notificationCenter
        tokens.append((center, center.addObserver(forName: WindowManager.stateDidChange, object: manager, queue: .main) { [weak self] _ in
            self?.scheduleRefresh()
        }))
        tokens.append((center, center.addObserver(forName: WindowManager.configDidChange, object: manager, queue: .main) { [weak self] _ in
            self?.scheduleRefresh()
        }))
        tokens.append((workspace, workspace.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            self?.scheduleRefresh()
        }))
    }

    func stopObserving() {
        for (center, token) in tokens { center.removeObserver(token) }
        tokens.removeAll()
    }

    private func scheduleRefresh() {
        guard !refreshScheduled else { return }
        refreshScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.refreshScheduled = false
            self.refresh()
        }
    }

    func refresh() {
        editError = nil
        var target = NSWorkspace.shared.frontmostApplication
        if target?.processIdentifier == getpid() {
            target = lastTargetPID.flatMap { NSRunningApplication(processIdentifier: $0) }
        }
        guard let app = target else {
            snapshot = .empty
            return
        }
        let pid = app.processIdentifier
        lastTargetPID = pid
        let bundleID = app.bundleIdentifier
        let appName = app.localizedName

        let axApp: AXUIElement
        if let observer = manager.observers[pid] {
            axApp = observer.app
        } else {
            axApp = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(axApp, AX.messagingTimeout)
        }

        // A hung target app only blocks its own worker, never the panel.
        manager.applier.perform(pid: pid) { [weak self] in
            guard let focused = AX.element(axApp, kAXFocusedWindowAttribute) else {
                DispatchQueue.main.async { self?.mergeNoFocus(pid: pid, bundleID: bundleID, appName: appName) }
                return
            }
            let closeButton = AX.element(focused, "AXCloseButton")
            let closeEnabled = closeButton.flatMap { AX.bool($0, kAXEnabledAttribute) }
            // A sheet attached to the window removes AXFullScreenButton, same as a disabled close button.
            let fullScreenButton: Bool? = (closeEnabled == true) ? (AX.element(focused, "AXFullScreenButton") != nil) : nil
            let raw = RawWindowFacts(
                title: AX.string(focused, kAXTitleAttribute),
                role: AX.string(focused, kAXRoleAttribute),
                subrole: AX.string(focused, kAXSubroleAttribute),
                modal: AX.bool(focused, "AXModal"),
                resizable: AX.isSettable(focused, kAXSizeAttribute),
                closeButtonPresent: closeButton != nil,
                closeEnabled: closeEnabled,
                fullScreenButton: fullScreenButton,
                nativeFullScreen: AX.bool(focused, "AXFullScreen") == true,
                frame: AX.frame(focused))
            DispatchQueue.main.async {
                self?.merge(pid: pid, bundleID: bundleID, appName: appName, element: focused, raw: raw)
            }
        }
    }

    // MARK: Merge (main thread: reads engine/config/provider)

    private func mergeNoFocus(pid: pid_t, bundleID: String?, appName: String?) {
        let appSection = InspectorSnapshot.Section(title: "App", rows: [
            .init(label: "Name", value: appName ?? "—"),
            .init(label: "Bundle ID", value: bundleID ?? "—"),
            .init(label: "PID", value: String(pid)),
        ])
        snapshot = InspectorSnapshot(
            sections: [appSection], emptyMessage: "No focused window",
            windowTitle: nil, bundleID: bundleID, appName: appName, canEditRule: false)
    }

    private func merge(pid: pid_t, bundleID: String?, appName: String?, element: AXUIElement, raw: RawWindowFacts) {
        let engine = manager.engine
        let windowID = manager.provider?.windowID(for: element)
        let record = windowID.flatMap { engine.windows[$0] }
        let facts = record?.facts ?? WindowFacts(
            bundleID: bundleID, appName: appName, title: raw.title, role: raw.role, subrole: raw.subrole,
            modal: raw.modal, resizable: raw.resizable, fullScreen: raw.fullScreenButton)

        var sections: [InspectorSnapshot.Section] = []
        sections.append(InspectorSnapshot.Section(title: "App", rows: [
            .init(label: "Name", value: appName ?? "—"),
            .init(label: "Bundle ID", value: bundleID ?? "—"),
            .init(label: "PID", value: String(pid)),
        ]))
        sections.append(InspectorSnapshot.Section(title: "Window", rows: [
            .init(label: "Window ID", value: windowID.map(String.init) ?? "unknown"),
            .init(label: "Title", value: raw.title ?? "—"),
            .init(label: "Role", value: raw.role ?? "—"),
            .init(label: "Subrole", value: raw.subrole ?? "—"),
            .init(label: "Modal", value: describe(raw.modal)),
            .init(label: "Resizable", value: describe(raw.resizable)),
            .init(label: "Full-screen button", value: describe(raw.fullScreenButton, yes: "present", no: "absent")),
            .init(label: "Close button", value: raw.closeButtonPresent ? describe(raw.closeEnabled, yes: "enabled", no: "disabled") : "none"),
            .init(label: "Frame", value: describeFrame(raw.frame)),
        ]))
        sections.append(InspectorSnapshot.Section(title: "Ballast", rows: ballastRows(record: record, facts: facts, role: raw.role, nativeFullScreen: raw.nativeFullScreen)))
        sections.append(InspectorSnapshot.Section(title: "Layout", rows: layoutRows(record: record)))

        let resolution = resolveSpace(record: record, windowID: windowID)
        sections.append(InspectorSnapshot.Section(title: "Space", rows: spaceRows(resolution)))
        sections.append(InspectorSnapshot.Section(title: "Display", rows: displayRows(resolution, frame: raw.frame)))

        snapshot = InspectorSnapshot(
            sections: sections, emptyMessage: nil, windowTitle: raw.title,
            bundleID: bundleID, appName: appName, canEditRule: manager.configError == nil && bundleID != nil)
    }

    private func ballastRows(record: WindowRecord?, facts: WindowFacts, role: String?, nativeFullScreen: Bool) -> [InspectorSnapshot.Row] {
        [
            .init(label: "Status", value: ballastStatus(record: record, role: role, nativeFullScreen: nativeFullScreen)),
            .init(label: "Weight", value: record.map { String(format: "%.2f", $0.rule.weight) } ?? "—"),
            .init(label: "Rule", value: record?.rule.ruleIndex.map(describeRule) ?? "none"),
            .init(label: "Float reason", value: facts.floatReason?.description ?? "none — tiles by default"),
        ]
    }

    /// Mirrors `WindowRecord.isFloating`'s precedence: the runtime `float`
    /// toggle, then the winning rule, then the default `floatReason`.
    private func ballastStatus(record: WindowRecord?, role: String?, nativeFullScreen: Bool) -> String {
        guard let record else {
            if let role, role != "AXWindow" { return "Not tracked — role isn't AXWindow" }
            if nativeFullScreen { return "Not tracked — native full screen" }
            if manager.status != .running { return "Not tracked — Ballast isn't running" }
            return "Not tracked"
        }
        if record.minimized { return "Minimized" }
        if record.hidden { return "Hidden (app hidden)" }
        if !record.isManaged {
            return record.rule.ruleIndex.map { "Not managed — rule #\($0 + 1)" } ?? "Not managed"
        }
        let reason = record.facts.floatReason
        if record.isFloating {
            if record.floatOverride == true { return "Floating — toggled with `float`" }
            if let idx = record.rule.ruleIndex, manager.config.rules.indices.contains(idx) {
                let actions = manager.config.rules[idx].actions
                if actions.float == true || actions.sticky == true { return "Floating — rule #\(idx + 1)" }
            }
            return reason.map { "Floating — default: \($0.description)" } ?? "Floating"
        }
        guard let space = record.space, manager.engine.isTiled(record.id) else {
            return record.space == nil ? "Not tiled — not on a desktop Ballast knows" : "Not tiled — full-screen Space"
        }
        if manager.engine.mode(for: space) == .float { return "Not tiled — desktop in float mode" }
        guard let reason else { return "Tiled" }
        return record.floatOverride == false
            ? "Tiled — toggled with `float` (default: \(reason.description))"
            : "Tiled — rule overrides default: \(reason.description)"
    }

    private func describeRule(_ index: Int) -> String {
        guard manager.config.rules.indices.contains(index) else { return "#\(index + 1)" }
        return "#\(index + 1): \(describeMatch(manager.config.rules[index].match))"
    }

    private func describeMatch(_ match: RuleMatch) -> String {
        var parts: [String] = []
        if let v = match.appID { parts.append("app_id = \(v)") }
        if let v = match.appName { parts.append("app_name = \(v)") }
        if let v = match.titleRegex { parts.append("title_regex = \(v.source)") }
        if let v = match.titleSubstring { parts.append("title_substring = \(v)") }
        if let v = match.axRole { parts.append("ax_role = \(v)") }
        if let v = match.axSubrole { parts.append("ax_subrole = \(v)") }
        return parts.isEmpty ? "(matches all windows)" : parts.joined(separator: ", ")
    }

    private func layoutRows(record: WindowRecord?) -> [InspectorSnapshot.Row] {
        guard let record, let space = record.space else {
            return [.init(label: "Position", value: "—")]
        }
        let engine = manager.engine
        let mode = engine.mode(for: space)
        let state = engine.spaces[space]
        return [
            .init(label: "Mode", value: modeDescription(space: space, mode: mode)),
            .init(label: "Monocle", value: (state?.monocle ?? false) ? "yes" : "no"),
            .init(label: "Manual", value: (state?.manual ?? false) ? "yes" : "no"),
            .init(label: "Position", value: positionDescription(space: space, windowID: record.id, mode: mode, state: state)),
        ]
    }

    /// Notes when the mode comes from the display (no override, no config
    /// `mode` for this desktop or in `[layout]`).
    private func modeDescription(space: SpaceID, mode: LayoutMode) -> String {
        let engine = manager.engine
        guard !engine.passthrough, engine.spaces[space]?.modeOverride == nil, let key = engine.snapshot.key(for: space),
              manager.config.layoutSettings(for: key).mode == nil else { return mode.rawValue }
        return "\(mode.rawValue) (automatic: \(engine.snapshot.isBuiltin(display: key.display) ? "built-in" : "external") display)"
    }

    private func positionDescription(space: SpaceID, windowID: WindowID, mode: LayoutMode, state: SpaceState?) -> String {
        if mode == .bsp { return "BSP tile" }
        guard mode.hasMaster, let state else { return "—" }
        let order = state.liveOrder
        guard let index = order.firstIndex(of: windowID) else { return "—" }
        let settings = manager.engine.settings(for: space)
        let masterCount = max(1, state.masterCountOverride ?? settings.masterCount)
        if index < masterCount { return "master" }
        let stackIndex = index - masterCount
        let stackCount = order.count - masterCount
        guard let display = displayInfo(for: space) else {
            return "stack \(stackIndex + 1) of \(stackCount)"
        }
        let layout = manager.engine.layout(space: space, area: display.visibleFrame)
        let viewState: String
        if let strip = layout.covered[windowID] {
            viewState = strip.width > 0 && strip.height > 0 ? "peeking" : "tucked away"
        } else {
            viewState = "in view"
        }
        return "stack \(stackIndex + 1) of \(stackCount) — \(viewState)"
    }

    private func resolveSpace(record: WindowRecord?, windowID: WindowID?) -> SpaceResolution {
        if let record, let space = record.space { return .space(space) }
        guard let windowID, let provider = manager.provider else { return .unknown }
        let spaces = provider.spaces(forWindow: windowID)
        if spaces.count == 1 { return .space(spaces[0]) }
        if spaces.count > 1 { return .sticky }
        return .unknown
    }

    private func spaceRows(_ resolution: SpaceResolution) -> [InspectorSnapshot.Row] {
        switch resolution {
        case .unknown:
            return [.init(label: "Space", value: "unknown")]
        case .sticky:
            return [.init(label: "Space", value: "all Spaces (sticky)")]
        case .space(let space):
            let snapshot = manager.engine.snapshot
            let info = snapshot.displays.flatMap(\.spaces).first { $0.id == space }
            let ordinal = snapshot.key(for: space)?.ordinal
            return [
                .init(label: "Space ID", value: String(space)),
                .init(label: "Space UUID", value: info?.uuid ?? "—"),
                .init(label: "Kind", value: describeKind(info?.kind)),
                .init(label: "Desktop", value: ordinal.map { "#\($0)" } ?? "—"),
                .init(label: "Active", value: snapshot.isActive(space) ? "yes" : "no"),
            ]
        }
    }

    private func describeKind(_ kind: SpaceKind?) -> String {
        switch kind {
        case .none: return "—"
        case .user: return "user"
        case .fullscreen: return "fullscreen"
        case .other(let raw): return "other (\(raw))"
        }
    }

    private func displayRows(_ resolution: SpaceResolution, frame: CGRect?) -> [InspectorSnapshot.Row] {
        let display: DisplayInfo?
        if case .space(let space) = resolution {
            display = displayInfo(for: space)
        } else {
            display = frame.flatMap { manager.displays.best(for: $0) }
        }
        guard let display else { return [.init(label: "Display", value: "unknown")] }
        return [
            .init(label: "Name", value: display.name),
            .init(label: "UUID", value: display.uuid),
            .init(label: "Display ID", value: String(display.id)),
            .init(label: "Built-in", value: display.builtin ? "yes" : "no"),
            .init(label: "Frame", value: describeFrame(display.frame)),
            .init(label: "Visible frame", value: describeFrame(display.visibleFrame)),
        ]
    }

    private func displayUUID(for space: SpaceID) -> String? {
        manager.engine.snapshot.displays.first { $0.spaces.contains { $0.id == space } }?.displayUUID
    }

    private func displayInfo(for space: SpaceID) -> DisplayInfo? {
        displayUUID(for: space).flatMap { manager.displays.with(uuid: $0) }
    }

    // MARK: Footer actions

    func copyToPasteboard() {
        var lines: [String] = []
        for section in snapshot.sections {
            for row in section.rows {
                lines.append("\(section.title) › \(row.label): \(row.value)")
            }
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(lines.joined(separator: "\n"), forType: .string)
    }

    func floatTitled() {
        guard let bundleID = snapshot.bundleID, let title = snapshot.windowTitle, !title.isEmpty else { return }
        let error = manager.editConfig { editor in
            editor.appendRule([
                ConfigField("app_id", .string(bundleID)),
                ConfigField("title_substring", .string(title)),
                ConfigField("float", .bool(true)),
            ]).map { _ in () }
        }
        editError = error?.description
    }

    func setAlwaysFloat(_ float: Bool) {
        guard let bundleID = snapshot.bundleID else { return }
        let existingIndex = appOnlyRuleIndex(bundleID: bundleID)
        let error = manager.editConfig { editor -> Result<Void, ConfigEditError> in
            if let existingIndex {
                return editor.set("float", .bool(float), in: .rule(existingIndex))
            }
            return editor.appendRule([
                ConfigField("app_id", .string(bundleID)),
                ConfigField("float", .bool(float)),
            ]).map { _ in () }
        }
        editError = error?.description
    }

    private func appOnlyRuleIndex(bundleID: String) -> Int? {
        manager.config.rules.firstIndex { rule in
            let match = rule.match
            guard let appID = match.appID else { return false }
            return appID.caseInsensitiveCompare(bundleID) == .orderedSame
                && match.appName == nil && match.titleRegex == nil && match.titleSubstring == nil
                && match.axRole == nil && match.axSubrole == nil
        }
    }
}

private func describe(_ value: Bool?, yes: String = "yes", no: String = "no") -> String {
    switch value {
    case .some(true): return yes
    case .some(false): return no
    case .none: return "unknown"
    }
}

private func describeFrame(_ frame: CGRect?) -> String {
    guard let frame else { return "—" }
    return "(\(Int(frame.origin.x.rounded())), \(Int(frame.origin.y.rounded()))) \(Int(frame.width.rounded()))×\(Int(frame.height.rounded()))"
}

// MARK: - View

/// Plain-data snapshot the Inspector renders; lets `InspectorView` be
/// rendered offscreen from a fixture, independent of `WindowManager`.
struct InspectorSnapshot {
    struct Row: Identifiable {
        let label: String
        let value: String
        /// Labels are unique within a section; stable ids keep SwiftUI from
        /// rebuilding every row (and dropping a text selection) per refresh.
        var id: String { label }
    }

    struct Section: Identifiable {
        let title: String
        let rows: [Row]
        var id: String { title }
    }

    var sections: [Section]
    var emptyMessage: String?
    var windowTitle: String?
    var bundleID: String?
    var appName: String?
    var canEditRule: Bool

    init(sections: [Section], emptyMessage: String?, windowTitle: String?, bundleID: String?, appName: String?, canEditRule: Bool) {
        self.sections = sections
        self.emptyMessage = emptyMessage
        self.windowTitle = windowTitle
        self.bundleID = bundleID
        self.appName = appName
        self.canEditRule = canEditRule
    }

    static let empty = InspectorSnapshot(
        sections: [], emptyMessage: "No focused window",
        windowTitle: nil, bundleID: nil, appName: nil, canEditRule: false)
}

/// Compact, read-only view of an `InspectorSnapshot` plus a couple of
/// one-click rule shortcuts. Pure function of its inputs, so it can be
/// previewed or rendered offscreen without a live `WindowManager`.
struct InspectorView: View {
    let snapshot: InspectorSnapshot
    var editError: String?
    var onCopy: () -> Void = {}
    var onFloatTitled: () -> Void = {}
    var onAlwaysFloat: () -> Void = {}
    var onAlwaysTile: () -> Void = {}

    var body: some View {
        VStack(spacing: 0) {
            Form {
                ForEach(snapshot.sections) { section in
                    Section(section.title) {
                        ForEach(section.rows) { row in
                            LabeledContent(row.label) {
                                Text(row.value)
                                    .font(.system(.body, design: .monospaced))
                                    .textSelection(.enabled)
                            }
                        }
                    }
                }
                if let message = snapshot.emptyMessage {
                    Section {
                        Text(message).foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.grouped)

            Divider()

            HStack {
                if let editError {
                    Text(editError).foregroundStyle(.red).font(.caption)
                }
                Spacer()
                Button("Copy", action: onCopy)
                if snapshot.canEditRule, let bundleID = snapshot.bundleID {
                    Menu("Rule") {
                        if let title = snapshot.windowTitle, !title.isEmpty {
                            Button("Float Windows Titled “\(title)”", action: onFloatTitled)
                        }
                        Button("Always Float \(snapshot.appName ?? bundleID)", action: onAlwaysFloat)
                        Button("Always Tile \(snapshot.appName ?? bundleID)", action: onAlwaysTile)
                    }
                }
            }
            .padding(12)
        }
    }
}
