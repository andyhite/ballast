import AppKit
import BallastCore

/// Always-present menu bar item: `<ordinal> · <mode glyph>[ Z]` for the
/// current display's active Space; red with a reason whenever something is
/// wrong (permission, config, unsupported OS, blocking system setting).
final class StatusBar: NSObject, NSMenuDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private unowned let manager: WindowManager

    init(manager: WindowManager) {
        self.manager = manager
        super.init()
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        refresh()
    }

    // MARK: Title

    func refresh() {
        let (text, isError) = title()
        let color: NSColor = isError ? .systemRed : .labelColor
        item.button?.attributedTitle = NSAttributedString(string: text, attributes: [
            .foregroundColor: color,
            .font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .medium),
        ])
    }

    private func title() -> (String, Bool) {
        switch manager.status {
        case .starting: return ("…", false)
        case .needsAccessibility: return ("! AX", true)
        case .invalidConfig: return ("! CFG", true)
        case .unsupported: return ("! OS", true)
        case .blocked: return ("! SET", true)
        case .running: break
        }
        let engine = manager.engine
        guard let display = manager.currentDisplay,
              let space = engine.snapshot.activeSpace(ofDisplay: display.uuid) else { return ("–", manager.configError != nil) }
        let ordinal = engine.snapshot.key(for: space).map { String($0.ordinal) } ?? "FS"
        let monocle = engine.spaces[space]?.monocle == true ? " Z" : ""
        let prefix = manager.configError != nil ? "! " : ""
        return ("\(prefix)\(ordinal) · \(engine.mode(for: space).glyph)\(monocle)", manager.configError != nil)
    }


    // MARK: Menu
    //
    // Top level: this desktop (header, Adjust Desktop ▸ with the layout mode,
    // Monocle, Reset), the focused app ▸, then Settings…, Tools ▸, Quit.
    // Global settings and `[layout]` defaults live only in the Settings window.

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let configOK = manager.configError == nil

        for line in problemLines() { menu.addItem(Self.info(line, color: .systemRed)) }
        if let note = manager.configNote { menu.addItem(Self.info(note)) }
        if !configOK {
            menu.addItem(Self.info("Config file has errors — settings won't be saved until it's fixed", color: .systemRed))
        }

        if manager.status == .running, let space = manager.currentSpace {
            if menu.numberOfItems > 0 { menu.addItem(.separator()) }
            addDesktopSection(to: menu, space: space, enabled: configOK)
            if let appItem = focusedAppMenuItem(enabled: configOK) {
                menu.addItem(.separator())
                menu.addItem(appItem)
            }
        }
        if menu.numberOfItems > 0 { menu.addItem(.separator()) }

        let settings = action("Settings…") { [unowned self] in PreferencesWindow.show(manager: manager) }
        settings.keyEquivalent = ","
        menu.addItem(settings)
        menu.addItem(toolsMenuItem())
        menu.addItem(.separator())
        let quit = action("Quit Ballast") { NSApp.terminate(nil) }
        quit.keyEquivalent = "q"
        menu.addItem(quit)
    }

    private func toolsMenuItem() -> NSMenuItem {
        let menu = NSMenu(title: "Tools")
        menu.addItem(action("Reload Config") { [unowned self] in manager.reloadConfig() })
        menu.addItem(action("Open Config File") { [unowned self] in openConfig() })
        menu.addItem(.separator())
        menu.addItem(action("Window Inspector…") { [unowned self] in InspectorWindow.show(manager: manager) })
        menu.addItem(action("Run Doctor…") { Self.showDoctor() })
        return submenuItem("Tools", menu)
    }

    // MARK: This desktop

    /// The desktop the menu edits: `space` for live state and runtime
    /// overrides, `key` for its `[[space]]` block in the config.
    private struct Desktop {
        let space: SpaceID
        let key: SpaceKey
    }

    private func modeLabel(_ mode: LayoutMode) -> String {
        switch mode {
        case .masterGrid: return "Master-Grid"
        case .masterStack: return "Master-Stack"
        case .bsp: return "BSP"
        case .float: return "Floating"
        }
    }

    private func near(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 0.005 }

    private func addDesktopSection(to menu: NSMenu, space: SpaceID, enabled: Bool) {
        let engine = manager.engine
        let key = manager.spaceKey(for: space)
        let display = manager.currentDisplay?.name ?? "display"
        let desktopName = key.map { "Desktop \($0.ordinal)" } ?? "Fullscreen Space"
        menu.addItem(.sectionHeader(title: "\(desktopName) on \(display)"))
        if engine.passthrough { menu.addItem(Self.info("Stage Manager on: every Space is passthrough", color: .systemOrange)) }

        if let key {
            menu.addItem(adjustDesktopMenuItem(Desktop(space: space, key: key), enabled: enabled))
        }

        menu.addItem(choiceItem("Monocle", checked: engine.spaces[space]?.monocle == true) { [unowned self] in
            manager.perform(.monocle)
        })
        let manual = engine.spaces[space]?.manual == true
        menu.addItem(action(manual ? "Reset Arrangement (manually arranged)" : "Reset Arrangement") { [unowned self] in
            manager.perform(.reset)
        })
        menu.addItem(action("Re-layout Desktop") { [unowned self] in
            manager.perform(.relayout)
        })
    }

    /// The layout mode, then only the settings that mode uses, then a way
    /// back to the defaults and a deep link to this desktop in the Settings
    /// window.
    private func adjustDesktopMenuItem(_ desktop: Desktop, enabled: Bool) -> NSMenuItem {
        let menu = NSMenu(title: "Adjust Desktop")
        let engine = manager.engine
        let space = desktop.space
        let current = engine.mode(for: space)
        let overrides = manager.config.spaces[desktop.key]
        let live = engine.spaces[space]

        // Picking the default mode drops the override rather than pinning
        // the desktop to today's default.
        let defaultMode = manager.config.layout.mode(builtin: engine.snapshot.isBuiltin(display: desktop.key.display))
        for mode in LayoutMode.allCases {
            let isDefault = mode == defaultMode
            let label = isDefault ? "\(modeLabel(mode)) (default)" : modeLabel(mode)
            menu.addItem(choiceItem(label, checked: current == mode, enabled: enabled) { [unowned self] in
                manager.perform(.layout(isDefault ? .configDefault : .set(mode)))
            })
        }
        menu.addItem(.separator())

        let effective = engine.settings(for: space)
        if current == .bsp {
            menu.addItem(bspArrangementItem(desktop, effective: effective, isInherited: overrides?.bspShape == nil, enabled: enabled))
            menu.addItem(splitDirectionItem(desktop, effective: effective, override: overrides?.split, enabled: enabled))
        } else if current.hasMaster {
            let ratioOverridden = overrides?.masterRatio != nil || live?.masterRatioOverride != nil
            let countOverridden = overrides?.masterCount != nil || live?.masterCountOverride != nil
            let ratioValue = live?.masterRatioOverride ?? effective.masterRatio
            let countValue = live?.masterCountOverride ?? effective.masterCount
            menu.addItem(masterSizeItem(desktop, current: ratioValue, isInherited: !ratioOverridden, enabled: enabled))
            menu.addItem(masterCountItem(desktop, current: countValue, isInherited: !countOverridden, enabled: enabled))
            menu.addItem(stackSideItem(desktop, effective: effective, isInherited: overrides?.stackSide == nil, enabled: enabled))
            menu.addItem(stackBothSidesItem(desktop, current: effective.stackBothSides, isInherited: overrides?.stackBothSides == nil, enabled: enabled))
            if current == .masterGrid {
                menu.addItem(gridMaxItem(desktop, current: effective.gridMax, isInherited: overrides?.gridMax == nil, enabled: enabled))
                menu.addItem(gridColumnsItem(desktop, current: effective.gridColumns, isInherited: overrides?.gridColumns == nil, enabled: enabled))
            }
            if current == .masterStack || effective.gridMax > 0 {
                menu.addItem(stackPeekItem(desktop, current: effective.stackPeek, isInherited: overrides?.stackPeek == nil, enabled: enabled))
            }
        }
        if current != .float {
            menu.addItem(weightShareLimitItem(desktop, effective: effective,
                isInherited: overrides?.bspMaxRatio == nil && overrides?.bspMinRatio == nil, enabled: enabled))
        }
        menu.addItem(gapItem(desktop, title: "Inner Gap", isOuter: false, current: effective.gaps.inner, enabled: enabled))
        menu.addItem(gapItem(desktop, title: "Outer Gap", isOuter: true, current: effective.gaps.outer, enabled: enabled))
        menu.addItem(.separator())

        menu.addItem(action("Remove Desktop Overrides", enabled: enabled) { [unowned self] in
            write(desktop, "mode", nil)
            if let error = manager.editConfig({ $0.removeSpace(desktop.key) }) { writeError(error) }
        })
        menu.addItem(action("More in Settings…") { [unowned self] in
            PreferencesWindow.show(manager: manager, desktop: desktop.key)
        })
        return submenuItem("Adjust Desktop", menu)
    }

    // MARK: Focused app

    private func focusedAppMenuItem(enabled: Bool) -> NSMenuItem? {
        let engine = manager.engine
        guard let focusedID = engine.focused, let window = engine.windows[focusedID] else { return nil }
        let appName = window.facts.appName ?? "Unknown App"
        let menu = NSMenu(title: appName)
        if let bundleID = window.facts.bundleID {
            addAppRuleItems(to: menu, bundleID: bundleID, window: window, enabled: enabled)
        } else {
            menu.addItem(Self.info("No bundle identifier — can't create an app rule for this window"))
        }
        menu.addItem(.separator())
        menu.addItem(action("Inspect Window…") { [unowned self] in InspectorWindow.show(manager: manager) })

        let top = submenuItem(appName, menu)
        if let icon = NSRunningApplication(processIdentifier: window.pid)?.icon?.copy() as? NSImage {
            icon.size = NSSize(width: 16, height: 16)
            top.image = icon
        }
        return top
    }

    private func addAppRuleItems(to menu: NSMenu, bundleID: String, window: WindowRecord, enabled: Bool) {
        let ruleIndex = manager.config.rules.firstIndex { rule in
            rule.match.appID?.caseInsensitiveCompare(bundleID) == .orderedSame &&
                rule.match.appName == nil && rule.match.titleRegex == nil && rule.match.titleSubstring == nil &&
                rule.match.axRole == nil && rule.match.axSubrole == nil
        }
        if let ruleIndex, window.rule.ruleIndex != ruleIndex {
            menu.addItem(Self.info("A more specific rule currently sets this window's weight", color: .systemOrange))
        }

        let weightMenu = NSMenu(title: "Weight")
        for w in [1, 2, 3, 5, 8, 13] {
            let item = action(w == 1 ? "1 (default)" : "\(w)", enabled: enabled) { [unowned self] in
                setRuleField(bundleID: bundleID, ruleIndex: ruleIndex, key: "weight", value: w == 1 ? nil : .integer(w))
            }
            item.state = near(window.rule.weight, Double(w)) ? .on : .off
            weightMenu.addItem(item)
        }
        let weightTop = submenuItem("Weight", weightMenu)
        weightTop.isEnabled = enabled
        menu.addItem(weightTop)

        // Each "(default)" entry removes the key from the app rule.
        let actions = ruleIndex.map { manager.config.rules[$0].actions }
        // `manage = true` is the default spelled out; show it as the default.
        let manage: Bool? = actions?.manage == false ? false : nil
        menu.addItem(ruleChoiceSubmenu("Manage", bundleID: bundleID, ruleIndex: ruleIndex, key: "manage", current: manage,
            options: [("Always (default)", nil), ("Never", false)], enabled: enabled))
        menu.addItem(ruleChoiceSubmenu("Float", bundleID: bundleID, ruleIndex: ruleIndex, key: "float", current: actions?.float,
            options: [("Automatic (default)", nil), ("Always", true), ("Never", false)], enabled: enabled))
    }

    /// A radio submenu over one Bool rule key; `nil` means the key is absent.
    private func ruleChoiceSubmenu(_ title: String, bundleID: String, ruleIndex: Int?, key: String, current: Bool?,
                                   options: [(label: String, value: Bool?)], enabled: Bool) -> NSMenuItem {
        let sub = NSMenu(title: title)
        for option in options {
            sub.addItem(choiceItem(option.label, checked: current == option.value, enabled: enabled) { [unowned self] in
                setRuleField(bundleID: bundleID, ruleIndex: ruleIndex, key: key, value: option.value.map { .bool($0) })
            })
        }
        let top = submenuItem(title, sub)
        top.isEnabled = enabled
        return top
    }

    private func setRuleField(bundleID: String, ruleIndex: Int?, key: String, value: ConfigValue?) {
        let error = manager.editConfig { editor -> Result<Void, ConfigEditError> in
            if let ruleIndex {
                return editor.set(key, value, in: .rule(ruleIndex))
            }
            guard let value else { return .success(()) }
            return editor.appendRule([ConfigField("app_id", .string(bundleID)), ConfigField(key, value)]).map { _ in () }
        }
        if let error { writeError(error) }
    }

    // MARK: Data-driven option submenus

    private struct SettingOption {
        let label: String
        let value: ConfigValue
        let checked: Bool
    }

    /// `[layout]`: what a desktop setting falls back to without an override.
    private var defaults: LayoutSettings { manager.config.layout }

    private func choiceItem(_ title: String, checked: Bool, enabled: Bool = true, _ handler: @escaping () -> Void) -> NSMenuItem {
        let item = action(title, enabled: enabled, handler)
        item.state = checked ? .on : .off
        return item
    }

    private func submenuItem(_ title: String, _ submenu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = submenu
        return item
    }

    private func optionSubmenu(
        _ title: String,
        defaultLabel: String,
        isInherited: Bool,
        enabled: Bool,
        options: [SettingOption],
        onDefault: @escaping () -> Void,
        onSelect: @escaping (ConfigValue) -> Void
    ) -> NSMenuItem {
        let sub = NSMenu(title: title)
        let defaultItem = action(defaultLabel, enabled: enabled, onDefault)
        defaultItem.state = isInherited ? .on : .off
        sub.addItem(defaultItem)
        sub.addItem(.separator())
        for option in options {
            let item = action(option.label, enabled: enabled) { onSelect(option.value) }
            item.state = (!isInherited && option.checked) ? .on : .off
            sub.addItem(item)
        }
        let top = submenuItem(title, sub)
        top.isEnabled = enabled
        return top
    }

    /// A submenu whose `Default (…)` entry removes `key` from the desktop's
    /// `[[space]]` block and whose options write it.
    private func settingSubmenu(_ desktop: Desktop, _ title: String, key: String, defaultLabel: String,
                                isInherited: Bool, enabled: Bool, options: [SettingOption]) -> NSMenuItem {
        optionSubmenu(title, defaultLabel: "Default (\(defaultLabel))", isInherited: isInherited, enabled: enabled, options: options,
            onDefault: { [unowned self] in write(desktop, key, nil) },
            onSelect: { [unowned self] value in write(desktop, key, value) })
    }

    private func masterSizeItem(_ desktop: Desktop, current: Double, isInherited: Bool, enabled: Bool) -> NSMenuItem {
        let options = [50, 55, 60, 65, 70, 75, 80].map { p -> SettingOption in
            SettingOption(label: "\(p)%", value: .float(Double(p) / 100), checked: near(current, Double(p) / 100))
        }
        return settingSubmenu(desktop, "Master Size", key: "master_ratio", defaultLabel: "\(Int((defaults.masterRatio * 100).rounded()))%",
            isInherited: isInherited, enabled: enabled, options: options)
    }

    private func masterCountItem(_ desktop: Desktop, current: Int, isInherited: Bool, enabled: Bool) -> NSMenuItem {
        let options = (1...4).map { n -> SettingOption in
            SettingOption(label: "\(n)", value: .integer(n), checked: current == n)
        }
        return settingSubmenu(desktop, "Master Count", key: "master_count", defaultLabel: "\(defaults.masterCount)",
            isInherited: isInherited, enabled: enabled, options: options)
    }

    private func stackSideItem(_ desktop: Desktop, effective: LayoutSettings, isInherited: Bool, enabled: Bool) -> NSMenuItem {
        let sides: [(StackSide, String)] = [(.right, "Right"), (.left, "Left"), (.bottom, "Bottom"), (.top, "Top")]
        let options = sides.map { side, label in
            SettingOption(label: label, value: .string(side.rawValue), checked: effective.stackSide == side)
        }
        return settingSubmenu(desktop, "Stack Side", key: "stack_side", defaultLabel: defaults.stackSide.rawValue.capitalized,
            isInherited: isInherited, enabled: enabled, options: options)
    }

    private func gridMaxItem(_ desktop: Desktop, current: Int, isInherited: Bool, enabled: Bool) -> NSMenuItem {
        let options = [0, 2, 3, 4, 5].map { n -> SettingOption in
            SettingOption(label: n == 0 ? "No Limit" : "\(n)", value: .integer(n), checked: current == n)
        }
        return settingSubmenu(desktop, "Grid Max", key: "grid_max", defaultLabel: defaults.gridMax == 0 ? "No Limit" : "\(defaults.gridMax)",
            isInherited: isInherited, enabled: enabled, options: options)
    }

    private func gridColumnsItem(_ desktop: Desktop, current: Int, isInherited: Bool, enabled: Bool) -> NSMenuItem {
        let options = (1...4).map { n -> SettingOption in
            SettingOption(label: "\(n)", value: .integer(n), checked: current == n)
        }
        return settingSubmenu(desktop, "Grid Columns", key: "grid_columns", defaultLabel: "\(defaults.gridColumns)",
            isInherited: isInherited, enabled: enabled, options: options)
    }

    private func stackBothSidesItem(_ desktop: Desktop, current: Bool, isInherited: Bool, enabled: Bool) -> NSMenuItem {
        let options = [
            SettingOption(label: "On", value: .bool(true), checked: current),
            SettingOption(label: "Off", value: .bool(false), checked: !current),
        ]
        return settingSubmenu(desktop, "Stack on Both Sides", key: "stack_both_sides", defaultLabel: defaults.stackBothSides ? "On" : "Off",
            isInherited: isInherited, enabled: enabled, options: options)
    }

    private func stackPeekItem(_ desktop: Desktop, current: Double, isInherited: Bool, enabled: Bool) -> NSMenuItem {
        let options = [0, 16, 24, 30, 40].map { pt -> SettingOption in
            SettingOption(label: "\(pt) pt", value: .integer(pt), checked: near(current, Double(pt)))
        }
        return settingSubmenu(desktop, "Stack Peek", key: "stack_peek", defaultLabel: "\(Int(defaults.stackPeek)) pt",
            isInherited: isInherited, enabled: enabled, options: options)
    }

    private func bspArrangementItem(_ desktop: Desktop, effective: LayoutSettings, isInherited: Bool, enabled: Bool) -> NSMenuItem {
        let shapes: [(BSPShape, String)] = [(.dwindle, "Dwindle"), (.balanced, "Balanced")]
        let options = shapes.map { shape, label in
            SettingOption(label: label, value: .string(shape.rawValue), checked: effective.bspShape == shape)
        }
        return settingSubmenu(desktop, "Arrangement", key: "bsp_shape", defaultLabel: defaults.bspShape.rawValue.capitalized,
            isInherited: isInherited, enabled: enabled, options: options)
    }

    /// `override`: nil = not overridden (inherit); `.some(nil)` = automatic; `.some(.some(axis))` = pinned axis.
    private func splitDirectionItem(_ desktop: Desktop, effective: LayoutSettings, override: Axis??, enabled: Bool) -> NSMenuItem {
        let resolved: Axis? = override ?? effective.split
        let options = [
            SettingOption(label: "Automatic", value: .string("auto"), checked: resolved == nil),
            SettingOption(label: "Side by Side", value: .string("horizontal"), checked: resolved == .horizontal),
            SettingOption(label: "Stacked", value: .string("vertical"), checked: resolved == .vertical),
        ]
        let defaultLabel = defaults.split.map { $0 == .horizontal ? "Side by Side" : "Stacked" } ?? "Automatic"
        return settingSubmenu(desktop, "Split Direction", key: "split", defaultLabel: defaultLabel,
            isInherited: override == nil, enabled: enabled, options: options)
    }

    private func weightShareLimitItem(_ desktop: Desktop, effective: LayoutSettings, isInherited: Bool, enabled: Bool) -> NSMenuItem {
        let options = [60, 67, 75, 80, 90].map { p -> SettingOption in
            SettingOption(label: "Max \(p)%", value: .float(Double(p) / 100), checked: near(effective.bspMaxRatio, Double(p) / 100))
        }
        return optionSubmenu("Weight Share Limit", defaultLabel: "Default (Max \(Int((defaults.bspMaxRatio * 100).rounded()))%)",
            isInherited: isInherited, enabled: enabled, options: options,
            onDefault: { [unowned self] in writePair(desktop, ("bsp_max_ratio", nil), ("bsp_min_ratio", nil)) },
            onSelect: { [unowned self] value in
                guard case .float(let v) = value else { return }
                writePair(desktop, ("bsp_max_ratio", .float(v)), ("bsp_min_ratio", .float(1 - v)))
            })
    }

    private func gapItem(_ desktop: Desktop, title: String, isOuter: Bool, current: Double, enabled: Bool) -> NSMenuItem {
        let overrides = manager.config.spaces[desktop.key]
        let overrideValue = isOuter ? overrides?.gapsOuter : overrides?.gapsInner
        let defaultValue = isOuter ? defaults.gaps.outer : defaults.gaps.inner
        let options = [0, 4, 8, 12, 16, 24].map { pt -> SettingOption in
            SettingOption(label: "\(pt) pt", value: .integer(pt), checked: near(current, Double(pt)))
        }
        return optionSubmenu(title, defaultLabel: "Default (\(Int(defaultValue)) pt)", isInherited: overrideValue == nil, enabled: enabled, options: options,
            onDefault: { [unowned self] in writeGaps(desktop, isOuter: isOuter, newValue: nil) },
            onSelect: { [unowned self] value in
                guard case .integer(let pt) = value else { return }
                writeGaps(desktop, isOuter: isOuter, newValue: Double(pt))
            })
    }

    // MARK: Config writes

    private func write(_ desktop: Desktop, _ key: String, _ value: ConfigValue?) {
        if let error = manager.setSpaceSetting(key, value, space: desktop.space) { writeError(error) }
    }

    private func writePair(_ desktop: Desktop, _ a: (String, ConfigValue?), _ b: (String, ConfigValue?)) {
        let section = ConfigSection.space(desktop.key)
        let error = manager.editConfig { editor -> Result<Void, ConfigEditError> in
            if case .failure(let e) = editor.set(a.0, a.1, in: section) { return .failure(e) }
            return editor.set(b.0, b.1, in: section)
        }
        if let error { writeError(error) }
    }

    /// Sets (or, with `newValue == nil`, removes) one gap component, keeping
    /// the other component's override as is.
    private func writeGaps(_ desktop: Desktop, isOuter: Bool, newValue: Double?) {
        let overrides = manager.config.spaces[desktop.key]
        let inner = isOuter ? overrides?.gapsInner : newValue
        let outer = isOuter ? newValue : overrides?.gapsOuter
        var fields: [ConfigField] = []
        if let inner { fields.append(ConfigField("inner", .integer(Int(inner)))) }
        if let outer { fields.append(ConfigField("outer", .integer(Int(outer)))) }
        write(desktop, "gaps", fields.isEmpty ? nil : .inlineTable(fields))
    }

    private func writeError(_ error: ConfigEditError) {
        Log.config.error("menu setting write failed: \(error.description, privacy: .public)")
    }


    private func problemLines() -> [String] {
        var lines: [String] = []
        switch manager.status {
        case .needsAccessibility:
            lines.append("Accessibility permission required:")
            lines.append("System Settings → Privacy & Security → Accessibility")
        case .invalidConfig(let message):
            lines.append("Config invalid — not managing until fixed:")
            lines += message.split(separator: "\n").prefix(5).map(String.init)
        case .unsupported(let message), .blocked(let message):
            lines.append(message)
        case .starting, .running:
            break
        }
        if let error = manager.configError {
            lines.append("Config rejected — previous config still live:")
            lines += error.split(separator: "\n").prefix(5).map(String.init)
        }
        return lines
    }

    private func openConfig() {
        let url = manager.configURL
        if !FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? Self.starterConfig.write(to: url, atomically: true, encoding: .utf8)
            manager.configFileCreated()
        }
        NSWorkspace.shared.open(url)
    }



    private static var doctorWindowController: NSWindowController?

    static func showDoctor() {
        let report = Doctor.run()
        let alert = NSAlert()
        alert.messageText = report.canManage && report.accessibilityGranted ? "Ballast doctor: all good" : "Ballast doctor found problems"
        alert.informativeText = report.render()
        alert.alertStyle = report.canManage ? .informational : .warning
        let okButton = alert.addButton(withTitle: "OK")

        let window = alert.window
        let controller = NSWindowController(window: window)
        doctorWindowController = controller

        okButton.target = controller
        okButton.action = #selector(NSWindowController.close)

        NSApp.activate()
        controller.showWindow(nil)
        window.orderFrontRegardless()
    }

    static let starterConfig = """
    # Ballast config. Full reference: docs/config.example.toml in the Ballast repo.
    # `ballast spaces` lists display UUIDs and Space ordinals for [[space]] entries.

    [layout]
    # No `mode`: master_stack on a built-in display, master_grid on external ones.
    master_ratio = 0.6

    [bindings]
    "alt+h" = "focus left"
    "alt+l" = "focus right"
    "alt+j" = "focus down"
    "alt+k" = "focus up"
    "alt+return" = "promote"
    "alt+r" = "reset"
    "alt+m" = "monocle"

    """

    // MARK: Helpers

    private static func info(_ text: String, color: NSColor? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: text, action: nil, keyEquivalent: "")
        item.isEnabled = false
        if let color {
            item.attributedTitle = NSAttributedString(string: text, attributes: [.foregroundColor: color])
        }
        return item
    }

    private func action(_ title: String, enabled: Bool = true, _ handler: @escaping () -> Void) -> NSMenuItem {
        let item = ClosureMenuItem(title: title, handler: handler)
        item.isEnabled = enabled
        return item
    }
}

private final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) {
        handler = {}
        super.init(coder: coder)
    }

    @objc private func fire() { handler() }
}
