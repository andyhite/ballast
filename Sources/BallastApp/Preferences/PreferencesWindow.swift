import AppKit
import BallastCore
import ServiceManagement
import SwiftUI

/// Single reusable "Ballast Settings" window: General, Layout, Rules,
/// Keyboard. The menu bar only covers the current desktop and focused app;
/// every global setting and the `[layout]` defaults live here. Ballast is an
/// `.accessory` app (no Dock icon, no menu bar menu bar item beyond the
/// status item), so this window has to activate itself explicitly.
enum PreferencesWindow {
    private static var controller: NSWindowController?
    private static var model: ConfigModel?

    /// `desktop`: open the Layout tab with that desktop's overrides selected.
    static func show(manager: WindowManager, desktop: SpaceKey? = nil) {
        let model = model ?? ConfigModel(manager: manager)
        Self.model = model
        if let desktop {
            // Desktops only refresh on config changes; make sure the one we
            // point the picker at is listed.
            model.refresh()
            model.tab = .layout
            model.layoutScope = .desktop(desktop)
        }

        if let controller {
            NSApp.activate(ignoringOtherApps: true)
            controller.window?.makeKeyAndOrderFront(nil)
            return
        }

        let root = PreferencesRootView(model: model)
        let hosting = NSHostingController(rootView: root)
        let window = NSWindow(contentViewController: hosting)
        window.title = "Ballast Settings"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.minSize = NSSize(width: 720, height: 520)
        window.setContentSize(NSSize(width: 780, height: 560))
        window.isReleasedWhenClosed = false
        window.center()

        let newController = NSWindowController(window: window)
        controller = newController

        NSApp.activate(ignoringOtherApps: true)
        newController.showWindow(nil)
        window.makeKeyAndOrderFront(nil)
    }
}

enum PreferencesTab: Hashable {
    case general, layout, rules, keyboard
}

private struct PreferencesRootView: View {
    @ObservedObject var model: ConfigModel

    var body: some View {
        TabView(selection: $model.tab) {
            GeneralPane(model: model)
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(PreferencesTab.general)
            LayoutPane(model: model)
                .tabItem { Label("Layout", systemImage: "rectangle.split.3x1") }
                .tag(PreferencesTab.layout)
            RulesPane(manager: model.manager)
                .tabItem { Label("Rules", systemImage: "list.bullet.rectangle") }
                .tag(PreferencesTab.rules)
            BindingsPane(manager: model.manager)
                .tabItem { Label("Keyboard", systemImage: "keyboard") }
                .tag(PreferencesTab.keyboard)
        }
        .padding()
        .frame(minWidth: 720, minHeight: 520)
    }
}

/// Focus/cursor behaviour, move animation, "Start at Login", and the config
/// file's location.
struct GeneralPane: View {
    @ObservedObject var model: ConfigModel
    @State private var loginItemError: String?
    @State private var editError: String?
    @State private var loginItemStatus = LoginItem.status
    /// Bumped when a toggle change is cancelled, so the switch redraws from
    /// `loginItemStatus` instead of keeping the flipped state.
    @State private var loginToggleID = 0

    private var manager: WindowManager { model.manager }
    private var config: Config { model.config }
    private var editingDisabled: Bool { model.configError != nil }

    var body: some View {
        Form {
            if let configError = model.configError {
                ConfigErrorBanner(message: configError)
            }

            Section("Focus") {
                Toggle("Focus follows mouse", isOn: Binding(
                    get: { config.focusFollowsMouse },
                    set: { commit("focus_follows_mouse", .bool($0)) }
                ))
                Toggle("Cursor follows focus", isOn: Binding(
                    get: { config.cursorFollowsFocus },
                    set: { commit("cursor_follows_focus", .bool($0)) }
                ))
            }
            .disabled(editingDisabled)

            Section("Window Animation") {
                Toggle("Animate window moves", isOn: Binding(
                    get: { config.animation.enabled },
                    set: { commit("enabled", .bool($0), in: .animation) }
                ))
                CommitSlider(
                    title: "Duration",
                    liveValue: config.animation.duration * 1000,
                    range: 0...2000,
                    step: 10,
                    format: { "\(Int($0.rounded())) ms" },
                    commit: { commit("duration_ms", .integer(Int($0.rounded())), in: .animation) }
                )
                Picker("Easing", selection: Binding(
                    get: { config.animation.easing },
                    set: { commit("easing", .string($0.rawValue), in: .animation) }
                )) {
                    ForEach(Easing.allCases, id: \.self) { easing in
                        Text(easing.label).tag(easing)
                    }
                }
            }
            .disabled(editingDisabled)

            Section("Focus Border") {
                Toggle("Flash the focused window's border", isOn: Binding(
                    get: { config.focusFlash.enabled },
                    set: { commit("enabled", .bool($0), in: .focusFlash) }
                ))
                CommitSlider(
                    title: "Duration",
                    liveValue: config.focusFlash.duration * 1000,
                    range: 100...5000,
                    step: 50,
                    format: { "\(Int($0.rounded())) ms" },
                    commit: { commit("duration_ms", .integer(Int($0.rounded())), in: .focusFlash) }
                )
                .disabled(!config.focusFlash.enabled)
                Picker("Show while holding", selection: Binding(
                    get: { config.focusFlash.hold },
                    set: { commit("hold", .string($0.rawValue), in: .focusFlash) }
                )) {
                    ForEach(FocusFlashHold.allCases, id: \.self) { hold in
                        Text(hold.label).tag(hold)
                    }
                }
                .disabled(!config.focusFlash.enabled)
                Text("A Ballast command that moves focus flashes the border, then fades it out. Holding the key shows it until you let go.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .disabled(editingDisabled)

            Section("Login") {
                Toggle("Start at Login", isOn: Binding(
                    get: { loginItemStatus == .enabled },
                    set: { setLoginItem($0) }
                ))
                .id(loginToggleID)
                .disabled(LoginItem.unavailableReason != nil)
                if let reason = LoginItem.unavailableReason {
                    Text(reason).font(.caption).foregroundStyle(.secondary)
                } else if let loginItemError {
                    InlineErrorText(message: loginItemError)
                } else if loginItemStatus == .requiresApproval {
                    HStack {
                        Text("Waiting for approval in System Settings → General → Login Items.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button("Open Login Items") { SMAppService.openSystemSettingsLoginItems() }
                    }
                }
            }

            Section("Config File") {
                Text(manager.configURL.path)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack {
                    Button("Open Config File") { NSWorkspace.shared.open(manager.configURL) }
                    Button("Reveal in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([manager.configURL])
                    }
                }
            }

            if let editError {
                InlineErrorText(message: editError)
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private func commit(_ key: String, _ value: ConfigValue?, in section: ConfigSection = .settings) {
        if let error = manager.editConfig({ $0.set(key, value, in: section) }) {
            editError = error.description
        } else {
            editError = nil
        }
    }

    private func setLoginItem(_ enabled: Bool) {
        if !enabled, loginItemStatus == .enabled {
            // Unregistering boots the LaunchAgent out, and with it this
            // process (the agent is what's running us while it is enabled).
            let alert = NSAlert()
            alert.messageText = "Turn off Start at Login?"
            alert.informativeText = "Ballast quits now. Open it from Applications whenever you want it back."
            alert.addButton(withTitle: "Turn Off and Quit")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else {
                loginToggleID += 1
                return
            }
        }
        do {
            // Enabling makes launchd start a second copy right away; it loses
            // the single-instance lock and exits, so this one keeps running.
            try LoginItem.setEnabled(enabled)
            loginItemError = nil
        } catch {
            loginItemError = error.localizedDescription
        }
        loginItemStatus = LoginItem.status
        if enabled, loginItemStatus == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
    }
}

private extension FocusFlashHold {
    var label: String {
        switch self {
        case .alt: "Option (⌥)"
        case .ctrl: "Control (⌃)"
        case .cmd: "Command (⌘)"
        case .none: "Nothing"
        }
    }
}
