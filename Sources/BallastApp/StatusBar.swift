import AppKit
import BallastCore
import ServiceManagement

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

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let engine = manager.engine
        let space = manager.currentSpace
        let configOK = manager.configError == nil

        for line in problemLines() { menu.addItem(Self.info(line, color: .systemRed)) }
        if let note = manager.configNote { menu.addItem(Self.info(note)) }
        if !configOK {
            menu.addItem(Self.info("Config file has errors — settings won't be saved until it's fixed", color: .systemRed))
        }

        if manager.status == .running, let space {
            let display = manager.currentDisplay?.name ?? "display"
            let key = manager.spaceKey(for: space)
            let desktop = key.map { "Desktop \($0.ordinal)" } ?? "Fullscreen Space"
            menu.addItem(Self.info("\(desktop) on \(display)"))
            if engine.passthrough { menu.addItem(Self.info("Stage Manager on: every Space is passthrough", color: .systemOrange)) }
            menu.addItem(.separator())

            if let key {
                addDesktopSettingItems(to: menu, space: space, key: key, enabled: configOK)
                menu.addItem(.separator())
            }

            let monocle = choiceItem("Monocle", checked: engine.spaces[space]?.monocle == true) { [unowned self] in
                manager.perform(.monocle)
            }
            menu.addItem(monocle)
            let manual = engine.spaces[space]?.manual == true
            menu.addItem(action(manual ? "Reset to Weight Default (manual layout)" : "Reset to Weight Default") { [unowned self] in
                manager.perform(.reset)
            })
            menu.addItem(.separator())

            menu.addItem(allDesktopsMenuItem(enabled: configOK))
            menu.addItem(globalSettingsMenuItem(enabled: configOK))
            if let focusedItem = focusedAppMenuItem(enabled: configOK) { menu.addItem(focusedItem) }
            menu.addItem(.separator())
        }

        let prefs = action("Preferences…") { [unowned self] in PreferencesWindow.show(manager: manager) }
        prefs.keyEquivalent = ","
        menu.addItem(prefs)
        menu.addItem(action("Reload Config") { [unowned self] in manager.reloadConfig() })
        menu.addItem(action("Open Config File") { [unowned self] in openConfig() })
        menu.addItem(action("Run Doctor…") { Self.showDoctor() })
        if let login = loginItemMenuItem() { menu.addItem(login) }
        menu.addItem(.separator())
        menu.addItem(action("Quit Ballast") { NSApp.terminate(nil) })
    }

    // MARK: Settings menu — desktop

    private enum SettingScope {
        case desktop(SpaceID, SpaceKey)
        case global
    }

    private func modeLabel(_ mode: LayoutMode) -> String {
        switch mode {
        case .masterStack: return "Master-Stack"
        case .bsp: return "BSP"
        case .float: return "Floating"
        }
    }

    private func near(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 0.005 }

    private func addDesktopSettingItems(to menu: NSMenu, space: SpaceID, key: SpaceKey, enabled: Bool) {
        let engine = manager.engine
        let current = engine.mode(for: space)
        for mode in [LayoutMode.masterStack, .bsp, .float] {
            let label = mode == .float ? "Floating (passthrough)" : modeLabel(mode)
            menu.addItem(choiceItem(label, checked: current == mode, enabled: enabled) { [unowned self] in
                manager.perform(.layout(.set(mode)))
            })
        }
        let followsDefault = engine.spaces[space]?.modeOverride == nil && manager.config.spaces[key]?.mode == nil
        menu.addItem(choiceItem("Use Default (\(modeLabel(manager.config.layout.mode)))", checked: followsDefault, enabled: enabled) { [unowned self] in
            manager.perform(.layout(.configDefault))
        })
        menu.addItem(.separator())

        let effective = engine.settings(for: space)
        let overrides = manager.config.spaces[key]
        let scope = SettingScope.desktop(space, key)
        let baseline = manager.config.layout

        if current == .bsp {
            menu.addItem(bspArrangementItem(scope: scope, baseline: baseline, effective: effective, isInherited: overrides?.bspShape == nil, enabled: enabled))
            menu.addItem(splitDirectionItem(scope: scope, baseline: baseline, effective: effective, override: overrides?.split, enabled: enabled))
            menu.addItem(weightShareLimitItem(scope: scope, baseline: baseline, effective: effective,
                isInherited: overrides?.bspMaxRatio == nil && overrides?.bspMinRatio == nil, enabled: enabled))
        } else if current == .masterStack {
            let ratioOverridden = overrides?.masterRatio != nil || engine.spaces[space]?.masterRatioOverride != nil
            let countOverridden = overrides?.masterCount != nil || engine.spaces[space]?.masterCountOverride != nil
            let ratioValue = engine.spaces[space]?.masterRatioOverride ?? effective.masterRatio
            let countValue = engine.spaces[space]?.masterCountOverride ?? effective.masterCount
            menu.addItem(masterSizeItem(scope: scope, baseline: baseline, current: ratioValue, isInherited: !ratioOverridden, enabled: enabled))
            menu.addItem(masterCountItem(scope: scope, baseline: baseline, current: countValue, isInherited: !countOverridden, enabled: enabled))
            menu.addItem(stackSideItem(scope: scope, baseline: baseline, effective: effective, isInherited: overrides?.stackSide == nil, enabled: enabled))
        }
        menu.addItem(gapItem(scope: scope, title: "Inner Gap", isOuter: false, current: effective.gaps.inner, baseline: baseline, editorSnapshot: nil, enabled: enabled))
        menu.addItem(gapItem(scope: scope, title: "Outer Gap", isOuter: true, current: effective.gaps.outer, baseline: baseline, editorSnapshot: nil, enabled: enabled))
        menu.addItem(.separator())
        menu.addItem(action("Remove Desktop Overrides", enabled: enabled) { [unowned self] in
            write(scope, "mode", nil)
            if let error = manager.editConfig({ $0.removeSpace(key) }) { writeError(error) }
        })
    }

    // MARK: Settings menu — all desktops

    private func allDesktopsMenuItem(enabled: Bool) -> NSMenuItem {
        let top = NSMenuItem(title: "All Desktops", action: nil, keyEquivalent: "")
        top.isEnabled = enabled
        let menu = NSMenu(title: "All Desktops")
        let editorSnapshot = rawConfigEditor()
        let scope = SettingScope.global
        let layout = manager.config.layout
        let modeIsSet = isKeySet(editorSnapshot, "mode", in: .layout)
        for mode in [LayoutMode.masterStack, .bsp, .float] {
            let label = mode == .float ? "Floating (passthrough)" : modeLabel(mode)
            let checked = modeIsSet && layout.mode == mode
            menu.addItem(choiceItem(label, checked: checked, enabled: enabled) { [unowned self] in
                write(scope, "mode", .string(mode.rawValue))
            })
        }
        menu.addItem(choiceItem("Default (\(modeLabel(LayoutSettings().mode)))", checked: !modeIsSet, enabled: enabled) { [unowned self] in
            write(scope, "mode", nil)
        })
        menu.addItem(.separator())

        menu.addItem(Self.info("Master-Stack"))
        menu.addItem(masterSizeItem(scope: scope, baseline: LayoutSettings(), current: layout.masterRatio,
            isInherited: !isKeySet(editorSnapshot, "master_ratio", in: .layout), enabled: enabled))
        menu.addItem(masterCountItem(scope: scope, baseline: LayoutSettings(), current: layout.masterCount,
            isInherited: !isKeySet(editorSnapshot, "master_count", in: .layout), enabled: enabled))
        menu.addItem(stackSideItem(scope: scope, baseline: LayoutSettings(), effective: layout,
            isInherited: !isKeySet(editorSnapshot, "stack_side", in: .layout), enabled: enabled))
        menu.addItem(.separator())
        menu.addItem(Self.info("BSP"))
        menu.addItem(bspArrangementItem(scope: scope, baseline: LayoutSettings(), effective: layout,
            isInherited: !isKeySet(editorSnapshot, "bsp_shape", in: .layout), enabled: enabled))
        menu.addItem(splitDirectionItem(scope: scope, baseline: LayoutSettings(), effective: layout,
            override: isKeySet(editorSnapshot, "split", in: .layout) ? .some(layout.split) : nil, enabled: enabled))
        menu.addItem(weightShareLimitItem(scope: scope, baseline: LayoutSettings(), effective: layout,
            isInherited: !isKeySet(editorSnapshot, "bsp_max_ratio", in: .layout) && !isKeySet(editorSnapshot, "bsp_min_ratio", in: .layout),
            enabled: enabled))
        menu.addItem(.separator())
        menu.addItem(gapItem(scope: scope, title: "Inner Gap", isOuter: false, current: layout.gaps.inner, baseline: LayoutSettings(), editorSnapshot: editorSnapshot, enabled: enabled))
        menu.addItem(gapItem(scope: scope, title: "Outer Gap", isOuter: true, current: layout.gaps.outer, baseline: LayoutSettings(), editorSnapshot: editorSnapshot, enabled: enabled))
        top.submenu = menu
        return top
    }

    // MARK: Settings menu — global settings

    private func globalSettingsMenuItem(enabled: Bool) -> NSMenuItem {
        let top = NSMenuItem(title: "Settings", action: nil, keyEquivalent: "")
        top.isEnabled = enabled
        let menu = NSMenu(title: "Settings")
        let config = manager.config

        menu.addItem(choiceItem("Focus Follows Mouse", checked: config.focusFollowsMouse, enabled: enabled) { [unowned self] in
            writeSection(.settings, "focus_follows_mouse", .bool(!config.focusFollowsMouse))
        })
        menu.addItem(choiceItem("Cursor Follows Focus", checked: config.cursorFollowsFocus, enabled: enabled) { [unowned self] in
            writeSection(.settings, "cursor_follows_focus", .bool(!config.cursorFollowsFocus))
        })
        menu.addItem(.separator())
        menu.addItem(choiceItem("Animate Windows", checked: config.animation.enabled, enabled: enabled) { [unowned self] in
            writeSection(.animation, "enabled", .bool(!config.animation.enabled))
        })
        menu.addItem(animationSpeedItem(config: config, enabled: enabled))
        menu.addItem(animationCurveItem(config: config, enabled: enabled))
        top.submenu = menu
        return top
    }

    private func animationSpeedItem(config: Config, enabled: Bool) -> NSMenuItem {
        let top = NSMenuItem(title: "Animation Speed", action: nil, keyEquivalent: "")
        let menu = NSMenu(title: "Animation Speed")
        let currentMs = Int((config.animation.duration * 1000).rounded())
        for (label, ms) in [("Fast (120 ms)", 120), ("Normal (180 ms)", 180), ("Slow (300 ms)", 300)] {
            let item = action(label, enabled: enabled) { [unowned self] in writeSection(.animation, "duration_ms", .integer(ms)) }
            item.state = currentMs == ms ? .on : .off
            menu.addItem(item)
        }
        top.submenu = menu
        top.isEnabled = enabled
        return top
    }

    private func animationCurveItem(config: Config, enabled: Bool) -> NSMenuItem {
        let top = NSMenuItem(title: "Animation Curve", action: nil, keyEquivalent: "")
        let menu = NSMenu(title: "Animation Curve")
        let labels: [(Easing, String)] = [
            (.linear, "Linear"), (.easeOutCubic, "Ease Out"), (.easeInOutCubic, "Ease In-Out"), (.easeOutQuint, "Ease Out Strong"),
        ]
        for (easing, label) in labels {
            let item = action(label, enabled: enabled) { [unowned self] in writeSection(.animation, "easing", .string(easing.rawValue)) }
            item.state = config.animation.easing == easing ? .on : .off
            menu.addItem(item)
        }
        top.submenu = menu
        top.isEnabled = enabled
        return top
    }

    // MARK: Settings menu — focused app

    private func focusedAppMenuItem(enabled: Bool) -> NSMenuItem? {
        let engine = manager.engine
        guard let focusedID = engine.focused, let window = engine.windows[focusedID] else { return nil }
        let appName = window.facts.appName ?? "Unknown App"
        let top = NSMenuItem(title: "Focused App: \(appName)", action: nil, keyEquivalent: "")
        let menu = NSMenu(title: "Focused App")
        guard let bundleID = window.facts.bundleID else {
            menu.addItem(Self.info("No bundle identifier — can't create an app rule for this window"))
            top.submenu = menu
            top.isEnabled = false
            return top
        }
        top.isEnabled = enabled
        let ruleIndex = manager.config.rules.firstIndex { rule in
            rule.match.appID?.caseInsensitiveCompare(bundleID) == .orderedSame &&
                rule.match.appName == nil && rule.match.titleRegex == nil && rule.match.titleSubstring == nil &&
                rule.match.axRole == nil && rule.match.axSubrole == nil
        }
        if let ruleIndex, window.rule.ruleIndex != ruleIndex {
            menu.addItem(Self.info("A more specific rule currently sets this window's weight", color: .systemOrange))
        }

        let weightTop = NSMenuItem(title: "Weight", action: nil, keyEquivalent: "")
        let weightMenu = NSMenu(title: "Weight")
        for w in [1.0, 2.0, 3.0, 5.0, 10.0] {
            let item = action(w == 1 ? "1 (default)" : "\(Int(w))", enabled: enabled) { [unowned self] in
                setRuleField(bundleID: bundleID, ruleIndex: ruleIndex, key: "weight", value: w == 1 ? nil : .integer(Int(w)))
            }
            item.state = near(window.rule.weight, w) ? .on : .off
            weightMenu.addItem(item)
        }
        weightTop.submenu = weightMenu
        weightTop.isEnabled = enabled
        menu.addItem(weightTop)

        menu.addItem(choiceItem("Don't Tile", checked: window.rule.manage == false, enabled: enabled) { [unowned self] in
            setRuleField(bundleID: bundleID, ruleIndex: ruleIndex, key: "manage", value: window.rule.manage == false ? nil : .bool(false))
        })
        menu.addItem(choiceItem("Always Float", checked: window.rule.float == true, enabled: enabled) { [unowned self] in
            setRuleField(bundleID: bundleID, ruleIndex: ruleIndex, key: "float", value: window.rule.float == true ? nil : .bool(true))
        })
        if let ruleIndex {
            menu.addItem(.separator())
            menu.addItem(action("Remove App Rule", enabled: enabled) { [unowned self] in
                if let error = manager.editConfig({ $0.removeRule(at: ruleIndex) }) { writeError(error) }
            })
        }
        top.submenu = menu
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

    private func choiceItem(_ title: String, checked: Bool, enabled: Bool = true, _ handler: @escaping () -> Void) -> NSMenuItem {
        let item = action(title, enabled: enabled, handler)
        item.state = checked ? .on : .off
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
        let top = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        top.isEnabled = enabled
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
        top.submenu = sub
        return top
    }

    private func masterSizeItem(scope: SettingScope, baseline: LayoutSettings, current: Double, isInherited: Bool, enabled: Bool) -> NSMenuItem {
        let options = [50, 55, 60, 65, 70, 75, 80].map { p -> SettingOption in
            SettingOption(label: "\(p)%", value: .float(Double(p) / 100), checked: near(current, Double(p) / 100))
        }
        return optionSubmenu("Master Size", defaultLabel: "Default (\(Int((baseline.masterRatio * 100).rounded()))%)",
            isInherited: isInherited, enabled: enabled, options: options,
            onDefault: { [unowned self] in write(scope, "master_ratio", nil) },
            onSelect: { [unowned self] value in write(scope, "master_ratio", value) })
    }

    private func masterCountItem(scope: SettingScope, baseline: LayoutSettings, current: Int, isInherited: Bool, enabled: Bool) -> NSMenuItem {
        let options = (1...4).map { n -> SettingOption in
            SettingOption(label: "\(n)", value: .integer(n), checked: current == n)
        }
        return optionSubmenu("Masters", defaultLabel: "Default (\(baseline.masterCount))",
            isInherited: isInherited, enabled: enabled, options: options,
            onDefault: { [unowned self] in write(scope, "master_count", nil) },
            onSelect: { [unowned self] value in write(scope, "master_count", value) })
    }

    private func stackSideItem(scope: SettingScope, baseline: LayoutSettings, effective: LayoutSettings, isInherited: Bool, enabled: Bool) -> NSMenuItem {
        let sides: [(StackSide, String)] = [(.right, "Right"), (.left, "Left"), (.bottom, "Bottom"), (.top, "Top")]
        let options = sides.map { side, label in
            SettingOption(label: label, value: .string(side.rawValue), checked: effective.stackSide == side)
        }
        return optionSubmenu("Stack Side", defaultLabel: "Default (\(baseline.stackSide.rawValue.capitalized))",
            isInherited: isInherited, enabled: enabled, options: options,
            onDefault: { [unowned self] in write(scope, "stack_side", nil) },
            onSelect: { [unowned self] value in write(scope, "stack_side", value) })
    }

    private func bspArrangementItem(scope: SettingScope, baseline: LayoutSettings, effective: LayoutSettings, isInherited: Bool, enabled: Bool) -> NSMenuItem {
        let shapes: [(BSPShape, String)] = [(.dwindle, "Dwindle"), (.balanced, "Balanced")]
        let options = shapes.map { shape, label in
            SettingOption(label: label, value: .string(shape.rawValue), checked: effective.bspShape == shape)
        }
        return optionSubmenu("Arrangement", defaultLabel: "Default (\(baseline.bspShape.rawValue.capitalized))",
            isInherited: isInherited, enabled: enabled, options: options,
            onDefault: { [unowned self] in write(scope, "bsp_shape", nil) },
            onSelect: { [unowned self] value in write(scope, "bsp_shape", value) })
    }

    /// `override`: nil = not overridden (inherit); `.some(nil)` = automatic; `.some(.some(axis))` = pinned axis.
    private func splitDirectionItem(scope: SettingScope, baseline: LayoutSettings, effective: LayoutSettings, override: Axis??, enabled: Bool) -> NSMenuItem {
        let isInherited = override == nil
        let resolved: Axis? = override ?? effective.split
        let options = [
            SettingOption(label: "Automatic", value: .string("auto"), checked: resolved == nil),
            SettingOption(label: "Side by Side", value: .string("horizontal"), checked: resolved == .horizontal),
            SettingOption(label: "Stacked", value: .string("vertical"), checked: resolved == .vertical),
        ]
        let baselineLabel = baseline.split.map { $0 == .horizontal ? "Side by Side" : "Stacked" } ?? "Automatic"
        return optionSubmenu("Split Direction", defaultLabel: "Default (\(baselineLabel))",
            isInherited: isInherited, enabled: enabled, options: options,
            onDefault: { [unowned self] in write(scope, "split", nil) },
            onSelect: { [unowned self] value in write(scope, "split", value) })
    }

    private func weightShareLimitItem(scope: SettingScope, baseline: LayoutSettings, effective: LayoutSettings, isInherited: Bool, enabled: Bool) -> NSMenuItem {
        let options = [60, 67, 75, 80, 90].map { p -> SettingOption in
            SettingOption(label: "Max \(p)%", value: .float(Double(p) / 100), checked: near(effective.bspMaxRatio, Double(p) / 100))
        }
        return optionSubmenu("Weight Share Limit", defaultLabel: "Default (Max \(Int((baseline.bspMaxRatio * 100).rounded()))%)",
            isInherited: isInherited, enabled: enabled, options: options,
            onDefault: { [unowned self] in writePair(scope, ("bsp_max_ratio", nil), ("bsp_min_ratio", nil)) },
            onSelect: { [unowned self] value in
                guard case .float(let v) = value else { return }
                writePair(scope, ("bsp_max_ratio", .float(v)), ("bsp_min_ratio", .float(1 - v)))
            })
    }

    private func gapItem(scope: SettingScope, title: String, isOuter: Bool, current: Double, baseline: LayoutSettings, editorSnapshot: ConfigEditor?, enabled: Bool) -> NSMenuItem {
        let overrideValue: Double?
        switch scope {
        case .desktop(_, let key):
            let overrides = manager.config.spaces[key]
            overrideValue = isOuter ? overrides?.gapsOuter : overrides?.gapsInner
        case .global:
            let comps = currentGapComponents(editorSnapshot, section: .layout)
            overrideValue = isOuter ? comps.outer : comps.inner
        }
        let isInherited = overrideValue == nil
        let baseValue = isOuter ? baseline.gaps.outer : baseline.gaps.inner
        let options = [0, 4, 8, 12, 16, 24].map { pt -> SettingOption in
            SettingOption(label: "\(pt) pt", value: .integer(pt), checked: near(current, Double(pt)))
        }
        return optionSubmenu(title, defaultLabel: "Default (\(Int(baseValue)) pt)", isInherited: isInherited, enabled: enabled, options: options,
            onDefault: { [unowned self] in writeGaps(scope, editorSnapshot: editorSnapshot, isOuter: isOuter, newValue: .some(nil)) },
            onSelect: { [unowned self] value in
                guard case .integer(let pt) = value else { return }
                writeGaps(scope, editorSnapshot: editorSnapshot, isOuter: isOuter, newValue: .some(Double(pt)))
            })
    }

    // MARK: Config writes

    private func write(_ scope: SettingScope, _ key: String, _ value: ConfigValue?) {
        switch scope {
        case .desktop(let space, _):
            if let error = manager.setSpaceSetting(key, value, space: space) { writeError(error) }
        case .global:
            writeSection(.layout, key, value)
        }
    }

    private func writeSection(_ section: ConfigSection, _ key: String, _ value: ConfigValue?) {
        if let error = manager.editConfig({ $0.set(key, value, in: section) }) { writeError(error) }
    }

    private func writePair(_ scope: SettingScope, _ a: (String, ConfigValue?), _ b: (String, ConfigValue?)) {
        let section: ConfigSection
        switch scope {
        case .desktop(_, let key): section = .space(key)
        case .global: section = .layout
        }
        let error = manager.editConfig { editor -> Result<Void, ConfigEditError> in
            if case .failure(let e) = editor.set(a.0, a.1, in: section) { return .failure(e) }
            return editor.set(b.0, b.1, in: section)
        }
        if let error { writeError(error) }
    }

    /// `newValue`: nil = leave this component unchanged; `.some(nil)` = remove it; `.some(.some(v))` = set it.
    private func writeGaps(_ scope: SettingScope, editorSnapshot: ConfigEditor?, isOuter: Bool, newValue: Double??) {
        var inner: Double?
        var outer: Double?
        switch scope {
        case .desktop(_, let key):
            let overrides = manager.config.spaces[key]
            inner = overrides?.gapsInner
            outer = overrides?.gapsOuter
        case .global:
            let comps = currentGapComponents(editorSnapshot, section: .layout)
            inner = comps.inner
            outer = comps.outer
        }
        if let newValue { if isOuter { outer = newValue } else { inner = newValue } }
        var fields: [ConfigField] = []
        if let inner { fields.append(ConfigField("inner", .integer(Int(inner)))) }
        if let outer { fields.append(ConfigField("outer", .integer(Int(outer)))) }
        write(scope, "gaps", fields.isEmpty ? nil : .inlineTable(fields))
    }

    private func writeError(_ error: ConfigEditError) {
        Log.config.error("menu setting write failed: \(error.description, privacy: .public)")
    }

    private func rawConfigEditor() -> ConfigEditor? {
        guard let text = try? String(contentsOf: manager.configURL, encoding: .utf8) else { return nil }
        return ConfigEditor(text: text)
    }

    private func isKeySet(_ editorSnapshot: ConfigEditor?, _ key: String, in section: ConfigSection) -> Bool {
        editorSnapshot?.value(key, in: section) != nil
    }

    private func currentGapComponents(_ editorSnapshot: ConfigEditor?, section: ConfigSection) -> (inner: Double?, outer: Double?) {
        guard case .inlineTable(let fields)? = editorSnapshot?.value("gaps", in: section) else { return (nil, nil) }
        func find(_ key: String) -> Double? {
            for field in fields where field.key == key {
                switch field.value {
                case .integer(let i): return Double(i)
                case .float(let d): return d
                default: return nil
                }
            }
            return nil
        }
        return (find("inner"), find("outer"))
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

    /// Nil outside `Ballast.app` (e.g. `.build/debug/ballast run`), where
    /// `SMAppService` can't find the bundled LaunchAgent.
    private func loginItemMenuItem() -> NSMenuItem? {
        guard LoginItem.unavailableReason == nil else { return nil }
        let status = LoginItem.status
        let title = status == .requiresApproval ? "Start at Login (needs approval…)" : "Start at Login"
        let item = action(title) { Self.toggleLoginItem() }
        item.state = status == .enabled ? .on : status == .requiresApproval ? .mixed : .off
        return item
    }

    private static func toggleLoginItem() {
        switch LoginItem.status {
        case .requiresApproval:
            SMAppService.openSystemSettingsLoginItems()
        case .enabled:
            // Unregistering boots the LaunchAgent out, and with it this
            // process (the agent is what's running us while it is enabled).
            let alert = NSAlert()
            alert.messageText = "Turn off Start at Login?"
            alert.informativeText = "Ballast quits now. Open it from Applications whenever you want it back."
            alert.addButton(withTitle: "Turn Off and Quit")
            alert.addButton(withTitle: "Cancel")
            NSApp.activate()
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            setLoginItem(false)
        default:
            // launchd also starts a second copy right away; it loses the
            // single-instance lock and exits cleanly, so this one keeps running.
            setLoginItem(true)
            if LoginItem.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
        }
    }

    private static func setLoginItem(_ enabled: Bool) {
        do { try LoginItem.setEnabled(enabled) } catch {
            let alert = NSAlert()
            alert.messageText = "Couldn't change Start at Login"
            alert.informativeText = String(describing: error)
            NSApp.activate()
            alert.runModal()
        }
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
    mode = "master_stack"
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
