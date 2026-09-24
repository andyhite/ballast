import AppKit
import BallastCore
import Darwin

/// `ballast [run|doctor|spaces|check-config|send|login-item|help] [--config PATH]`
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
        case "login-item": return loginItem(rest.first ?? "status")
        case "help", "-h", "--help": print(usage(configURL)); return 0
        default: return fail("unknown subcommand '\(verb)'\n\n\(usage(configURL))")
        }
    }

    static func defaultConfigURL() -> URL {
        let env = ProcessInfo.processInfo.environment
        if let explicit = env["BALLAST_CONFIG"], !explicit.isEmpty {
            return URL(fileURLWithPath: (explicit as NSString).expandingTildeInPath)
        }
        let base = env["XDG_CONFIG_HOME"].flatMap { raw -> URL? in
            let expanded = (raw as NSString).expandingTildeInPath
            guard !expanded.isEmpty, expanded.hasPrefix("/") else { return nil }
            return URL(fileURLWithPath: expanded)
        } ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config")
        return base.appendingPathComponent("ballast/config.toml")
    }

    // MARK: Subcommands

    private static var manager: WindowManager?
    private static var lockFileDescriptor: Int32 = -1

    /// Takes an exclusive, non-blocking flock on a well-known cache file so
    /// only one `ballast run` can manage windows at a time. The descriptor
    /// is kept open for the life of the process; the lock releases when the
    /// process exits.
    private static func acquireSingleInstanceLock() -> Bool {
        let cacheDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/dev.ballast")
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        let lockPath = cacheDir.appendingPathComponent("run.lock").path
        let fd = open(lockPath, O_CREAT | O_RDWR, 0o644)
        guard fd >= 0 else { return true }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            return false
        }
        lockFileDescriptor = fd
        return true
    }

    private static func run(configURL: URL) -> Int32 {
        guard acquireSingleInstanceLock() else {
            FileHandle.standardError.write(Data("another Ballast instance is running\n".utf8))
            return 0
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let wm = WindowManager(configURL: configURL)
        manager = wm
        wm.launch()
        app.run()
        return 0
    }

    private static func doctor() -> Int32 {
        let report = Doctor.run(context: .cli)
        print(report.render())
        return report.canManage && report.accessibilityGranted ? 0 : 1
    }

    private static func spaces(configURL: URL) -> Int32 {
        let provider: any SpaceProvider
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
                    let mode = config.map { " mode=\($0.layoutSettings(for: key).mode(builtin: display.builtin).rawValue)\($0.spaces[key] != nil ? " (override)" : "")" } ?? ""
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

    private static func loginItem(_ action: String) -> Int32 {
        // SMAppService finds the agent through Bundle.main, which is wrong when
        // this runs through the PATH symlink: re-exec the binary inside the app.
        if LoginItem.unavailableReason != nil, let exe = Bundle.main.executableURL {
            let real = exe.resolvingSymlinksInPath()
            if real.path != exe.path, real.deletingLastPathComponent().path.hasSuffix(".app/Contents/MacOS") {
                let argv = ([real.path] + CommandLine.arguments.dropFirst()).map { strdup($0) } + [nil]
                execv(real.path, argv)
                return fail("cannot run \(real.path): \(String(cString: strerror(errno)))")
            }
        }
        let enable: Bool
        switch action {
        case "status":
            if let reason = LoginItem.unavailableReason { return fail(reason) }
            print("start at login: \(LoginItem.describe(LoginItem.status))")
            return 0
        case "on": enable = true
        case "off": enable = false
        default: return fail("login-item takes on, off or status")
        }
        do { try LoginItem.setEnabled(enable) } catch { return fail("\(error)") }
        print("start at login: \(LoginItem.describe(LoginItem.status))")
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
          ballast login-item [on|off|status]  start at login (launchd; restarts Ballast after a crash)
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
