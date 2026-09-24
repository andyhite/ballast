import AppKit
import BallastCore

/// `ballast [run|doctor|spaces|check-config|send|help] [--config PATH]`
public enum BallastCLI {
    /// Distributed notification carrying a command string to the running instance.
    public static let commandNotification = Notification.Name("dev.ballast.command")

    public static func main(_ arguments: [String]) -> Int32 {
        var args = arguments
        var configOverride: String?
        if let i = args.firstIndex(of: "--config") {
            guard args.indices.contains(i + 1) else { return fail("--config needs a path") }
            configOverride = args[i + 1]
            args.removeSubrange(i...(i + 1))
        }
        let configURL = configOverride.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) } ?? defaultConfigURL()
        let verb = args.first ?? "run"
        let rest = Array(args.dropFirst())

        switch verb {
        case "run": return run(configURL: configURL)
        case "doctor": return doctor()
        case "spaces": return spaces(configURL: configURL)
        case "check-config":
            return checkConfig(rest.first.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) } ?? configURL)
        case "send": return send(rest.joined(separator: " "))
        case "help", "-h", "--help": print(usage(configURL)); return 0
        default: return fail("unknown subcommand '\(verb)'\n\n\(usage(configURL))")
        }
    }

    static func defaultConfigURL() -> URL {
        let env = ProcessInfo.processInfo.environment
        if let explicit = env["BALLAST_CONFIG"], !explicit.isEmpty { return URL(fileURLWithPath: explicit) }
        let base = env["XDG_CONFIG_HOME"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config")
        return base.appendingPathComponent("ballast/config.toml")
    }

    // MARK: Subcommands

    private static var manager: WindowManager?

    private static func run(configURL: URL) -> Int32 {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let wm = WindowManager(configURL: configURL)
        manager = wm
        wm.launch()
        app.run()
        return 0
    }

    private static func doctor() -> Int32 {
        let report = Doctor.run()
        print(report.render())
        return report.canManage && report.accessibilityGranted ? 0 : 1
    }

    private static func spaces(configURL: URL) -> Int32 {
        let provider: SkyLightSpaceProvider
        switch SkyLightSpaceProvider.make() {
        case .success(let p): provider = p
        case .failure(let missing): return fail("unsupported macOS: \(missing)")
        }
        guard let snapshot = provider.snapshot() else { return fail("SkyLight returned no Space data") }
        let config = (try? String(contentsOf: configURL, encoding: .utf8)).flatMap { try? Config.parse($0).get() }
        let displays = DisplayInfo.current()
        for display in snapshot.displays {
            let name = displays.with(uuid: display.displayUUID)?.name ?? "unknown display"
            print("\(name)  display = \"\(display.displayUUID)\"")
            var ordinal = 0
            for space in display.spaces {
                let active = space.id == display.activeSpace ? "*" : " "
                if space.kind == .user {
                    ordinal += 1
                    let key = SpaceKey(display: display.displayUUID, ordinal: ordinal)
                    let mode = config.map { " mode=\($0.layoutSettings(for: key).mode.rawValue)\($0.spaces[key] != nil ? " (override)" : "")" } ?? ""
                    print("  \(active) ordinal = \(ordinal)   space id \(space.id)\(mode)")
                } else {
                    print("  \(active) (fullscreen/other Space, id \(space.id) — ignored)")
                }
            }
        }
        if config == nil { print("\n(no valid config at \(configURL.path); modes not shown)") }
        return 0
    }

    private static func checkConfig(_ url: URL) -> Int32 {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return fail("cannot read \(url.path)") }
        switch Config.parse(text) {
        case .success(let config):
            print("OK \(url.path): \(config.spaces.count) space overrides, \(config.rules.count) rules, \(config.bindings.count) bindings")
            return 0
        case .failure(let error):
            return fail("\(url.path) is invalid:\n\(error.description)")
        }
    }

    private static func send(_ text: String) -> Int32 {
        if case .failure(let error) = Command.parse(text) {
            return fail("\(error.message)\ncommands:\n  " + Command.reference.joined(separator: "\n  "))
        }
        DistributedNotificationCenter.default().postNotificationName(
            commandNotification, object: text, userInfo: nil, deliverImmediately: true)
        return 0
    }

    private static func usage(_ configURL: URL) -> String {
        """
        ballast — tiling window manager for native macOS Spaces

        usage:
          ballast [run]                start the window manager (menu bar app)
          ballast doctor               check permissions, Spaces settings, private API availability
          ballast spaces               list display UUIDs and Space ordinals for [[space]] config
          ballast check-config [PATH]  validate a config file without applying it
          ballast send <command>       send a command to the running instance
          --config PATH                config file (default: \(configURL.path))

        commands:
          \(Command.reference.joined(separator: "\n  "))
        """
    }

    private static func fail(_ message: String) -> Int32 {
        FileHandle.standardError.write(Data("ballast: \(message)\n".utf8))
        return 1
    }
}
