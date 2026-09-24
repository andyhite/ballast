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

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let engine = manager.engine
        let space = manager.currentSpace

        for line in problemLines() { menu.addItem(Self.info(line, color: .systemRed)) }
        if let note = manager.configNote { menu.addItem(Self.info(note)) }

        if manager.status == .running, let space {
            let display = manager.currentDisplay?.name ?? "display"
            let desktop = engine.snapshot.key(for: space).map { "Desktop \($0.ordinal)" } ?? "Fullscreen Space"
            menu.addItem(Self.info("\(desktop) on \(display)"))
            if engine.passthrough { menu.addItem(Self.info("Stage Manager on: every Space is passthrough", color: .systemOrange)) }
            menu.addItem(.separator())
            let current = engine.mode(for: space)
            for (mode, label) in [(LayoutMode.masterStack, "Master-Stack"), (.bsp, "BSP"), (.float, "Floating (passthrough)")] {
                let item = action(label) { [unowned self] in manager.perform(.layout(.set(mode))) }
                item.state = current == mode ? .on : .off
                menu.addItem(item)
            }
            let followsConfig = engine.spaces[space]?.modeOverride == nil
            let defaultItem = action("Use Config Default") { [unowned self] in manager.perform(.layout(.configDefault)) }
            defaultItem.state = followsConfig ? .on : .off
            menu.addItem(defaultItem)
            menu.addItem(.separator())
            let monocle = action("Monocle") { [unowned self] in manager.perform(.monocle) }
            monocle.state = engine.spaces[space]?.monocle == true ? .on : .off
            menu.addItem(monocle)
            let manual = engine.spaces[space]?.manual == true
            menu.addItem(action(manual ? "Reset to Weight Default (manual layout)" : "Reset to Weight Default") { [unowned self] in
                manager.perform(.reset)
            })
        }
        menu.addItem(.separator())
        menu.addItem(action("Reload Config") { [unowned self] in manager.reloadConfig() })
        menu.addItem(action("Open Config File") { [unowned self] in openConfig() })
        menu.addItem(action("Run Doctor…") { Self.showDoctor() })
        menu.addItem(.separator())
        menu.addItem(action("Quit Ballast") { NSApp.terminate(nil) })
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

    static func showDoctor() {
        let report = Doctor.run()
        let alert = NSAlert()
        alert.messageText = report.canManage && report.accessibilityGranted ? "Ballast doctor: all good" : "Ballast doctor found problems"
        alert.informativeText = report.render()
        alert.alertStyle = report.canManage ? .informational : .warning
        NSApp.activate()
        alert.runModal()
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

    private func action(_ title: String, _ handler: @escaping () -> Void) -> NSMenuItem {
        ClosureMenuItem(title: title, handler: handler)
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
