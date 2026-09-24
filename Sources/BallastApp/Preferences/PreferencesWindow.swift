import AppKit
import BallastCore
import ServiceManagement
import SwiftUI

/// Single reusable "Ballast Settings" window covering everything the menu
/// bar's quick toggles don't: General, Layout, Rules, Keyboard. Ballast is an
/// `.accessory` app (no Dock icon, no menu bar menu bar item beyond the
/// status item), so this window has to activate itself explicitly.
enum PreferencesWindow {
    private static var controller: NSWindowController?

    static func show(manager: WindowManager) {
        if let controller {
            NSApp.activate(ignoringOtherApps: true)
            controller.window?.makeKeyAndOrderFront(nil)
            return
        }

        let model = ConfigModel(manager: manager)
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

private struct PreferencesRootView: View {
    @ObservedObject var model: ConfigModel

    var body: some View {
        TabView {
            GeneralPane(model: model)
                .tabItem { Label("General", systemImage: "gearshape") }
            LayoutPane(model: model)
                .tabItem { Label("Layout", systemImage: "rectangle.split.3x1") }
            RulesPane(manager: model.manager)
                .tabItem { Label("Rules", systemImage: "list.bullet.rectangle") }
            BindingsPane(manager: model.manager)
                .tabItem { Label("Keyboard", systemImage: "keyboard") }
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
                .disabled(LoginItem.unavailableReason != nil)
                if let reason = LoginItem.unavailableReason {
                    Text(reason).font(.caption).foregroundStyle(.secondary)
                } else if let loginItemError {
                    InlineErrorText(message: loginItemError)
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
        do {
            try LoginItem.setEnabled(enabled)
            loginItemError = nil
        } catch {
            loginItemError = error.localizedDescription
        }
        loginItemStatus = LoginItem.status
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
