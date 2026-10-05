import AppKit
import BallastCore
import Darwin

/// `ballast [run|doctor|spaces|check-config|send|login-item|help] [--config PATH]`
@MainActor
public enum BallastCLI {
    public static func main(_ arguments: [String], env: [String: String] = ProcessInfo.processInfo.environment) -> Int32 {
        var args: [String] = []
        var configOverride: String?
        var i = 0
        while i < arguments.count {
            let arg = arguments[i]
            if arg == "--config" {
                guard i + 1 < arguments.count else { return fail("--config needs a path") }
                configOverride = arguments[i + 1]
                i += 2
                continue
            }
            if arg.hasPrefix("--config=") {
                configOverride = String(arg.dropFirst("--config=".count))
                if configOverride?.isEmpty == true { return fail("--config needs a path") }
            } else {
                args.append(arg)
            }
            i += 1
        }
        let configURL = configOverride.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
            ?? defaultConfigURL(env: env)
        let verb = args.first ?? "run"
        let rest = Array(args.dropFirst())
        func noArgs(_ body: () -> Int32) -> Int32 {
            rest.isEmpty ? body() : fail("'\(verb)' takes no arguments\n\n\(usage(configURL))")
        }

        switch verb {
        case "run": return noArgs { run(configURL: configURL) }
        case "doctor": return noArgs { doctor() }
        case "spaces": return noArgs { spaces(configURL: configURL) }
        case "check-config":
            guard rest.count <= 1 else { return fail("check-config takes at most one PATH\n\n\(usage(configURL))") }
            return checkConfig(rest.first.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) } ?? configURL)
        case "send": return send(rest.joined(separator: " "))
        case "login-item":
            guard rest.count <= 1 else { return fail("login-item takes on, off or status\n\n\(usage(configURL))") }
            return loginItem(rest.first ?? "status")
        case "help", "-h", "--help": print(usage(configURL)); return 0
        default: return fail("unknown subcommand '\(verb)'\n\n\(usage(configURL))")
        }
    }

    static func defaultConfigURL(env: [String: String] = ProcessInfo.processInfo.environment) -> URL {
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
    private static var commandSocket: CommandSocket?
    private static var lockFileDescriptor: Int32 = -1

    static var lockDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches/dev.ballast")
    }

    private static var lockPath: String { lockDirectory.appendingPathComponent("run.lock").path }

    /// Takes an exclusive, non-blocking flock on a well-known cache file so
    /// only one `ballast run` can manage windows at a time. The descriptor
    /// is kept open for the life of the process; the lock releases when the
    /// process exits.
    private static func acquireSingleInstanceLock() -> Bool {
        try? FileManager.default.createDirectory(
            at: lockDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let fd = open(lockPath, O_CREAT | O_RDWR, 0o600)
        // Cannot even attempt the lock (full disk, missing/unmounted cache
        // directory, permission denied): treat as lock-held rather than
        // silently allowing a second instance to manage windows.
        guard fd >= 0 else { return false }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            return false
        }
        lockFileDescriptor = fd
        return true
    }

    /// `true` when some process holds the run lock: a shared lock cannot be
    /// taken while the instance's exclusive one is held.
    private static func instanceIsRunning() -> Bool {
        let fd = open(lockPath, O_RDONLY)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        return flock(fd, LOCK_SH | LOCK_NB) != 0
    }

    private static func run(configURL: URL) -> Int32 {
        guard acquireSingleInstanceLock() else {
            // Exit 0: launchd's `KeepAlive.SuccessfulExit = false` (see
            // scripts/dev.ballast.plist) restarts only on a non-zero exit.
            // Another instance already managing windows, or a lock file
            // that could not be opened, is not a crash to loop-restart on.
            FileHandle.standardError.write(Data("another Ballast instance is running (or its lock file could not be opened)\n".utf8))
            return 0
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let wm = WindowManager(configURL: configURL)
        manager = wm
        wm.launch()
        let socket = CommandSocket(path: CommandSocket.defaultPath) { wm.handleCommand($0) }
        if !socket.start() {
            FileHandle.standardError.write(Data("ballast: command socket unavailable; `ballast send` won't work\n".utf8))
        }
        commandSocket = socket
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { commandSocket?.stop() }
        }
        app.run()
        return 0
    }

    private static func doctor() -> Int32 {
        let report = Doctor.run(cli: true)
        print(report.render())
        return report.canManage ? 0 : 1
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
                    let key = SpaceKey(display: display.displayUUID, ordinal: ordinal, uuid: space.uuid)
                    let layout = config.map {
                        " layout=\($0.layoutSettings(for: key, small: display.small).glyph)\($0.address(for: key) != nil ? " (override)" : "")"
                    } ?? ""
                    let uuid = space.uuid.isEmpty ? "" : "   uuid = \"\(space.uuid)\""
                    print("  \(active) ordinal = \(ordinal)\(uuid)   space id \(space.id)\(layout)")
                } else {
                    print("  \(active) (fullscreen/other Space, id \(space.id) — ignored)")
                }
            }
        }
        if config == nil { print("\n(no valid config at \(configURL.path); layouts not shown)") }
        return 0
    }

    private static func checkConfig(_ url: URL) -> Int32 {
        let text: String
        do { text = try String(contentsOf: url, encoding: .utf8) } catch {
            return fail("cannot read \(url.path): \(error.localizedDescription)")
        }
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
        guard instanceIsRunning() else { return fail("no running Ballast instance (start it with `ballast run` or open Ballast.app)") }
        switch CommandSocket.send(text, path: CommandSocket.defaultPath) {
        case .failure(let e): return fail("cannot reach the running Ballast: \(e)")
        case .success(let reply):
            if reply == "ok" { return 0 }
            if reply.hasPrefix("ok: ") { print(reply.dropFirst(4)); return 0 }
            if reply.hasPrefix("error: ") { return fail(String(reply.dropFirst(7))) }
            return fail("unexpected reply: \(reply)")
        }
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
          ballast spaces               list display UUIDs plus Space UUIDs and ordinals for [[space]] config
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
