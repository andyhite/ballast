import Testing
import Foundation
import CoreGraphics
@testable import BallastApp
@testable import BallastCore

/// No AX/SkyLight permissions, no live WM, no user config: every test uses a
/// throwaway config file under a fresh temp directory and only exercises
/// pure/file-local `WindowManager` entry points (`loadInitialConfig`,
/// `editConfig`, `WindowManager.learnedMinSize`). `WindowManager` is a
/// main-thread-only class, so every test that touches it runs on the main actor.
@MainActor
struct WindowManagerTests {
    /// A fresh temp directory plus the config path inside it. Callers must
    /// `defer` the cleanup so the directory is removed on every exit path,
    /// including an early `throw` or assertion failure.
    private static func tempConfigDir() -> (dir: URL, url: URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ballast-wm-tests-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return (dir, dir.appendingPathComponent("ballast.toml"))
    }

    private static let sampleConfig = """
    [layout]
    mode = "bsp"

    [[rule]]
    app_id = "com.example.app"
    weight = 10

    [bindings]
    "cmd+j" = "focus down"
    """

    // MARK: audit5 — min-size learning only on the refused axis

    @Test
    func learnedMinSizeIsZeroOnAcceptedAxis() {
        // Width refused (actual far beyond requested), height accepted
        // (within the 2pt tolerance): the accepted axis must contribute 0,
        // not the requested/actual length, so it never becomes a floor.
        let requested = CGRect(x: 0, y: 0, width: 400, height: 850)
        let actual = CGRect(x: 0, y: 0, width: 600, height: 850)
        let size = WindowManager.learnedMinSize(requested: requested, actual: actual)
        #expect(size.width == 600)
        #expect(size.height == 0)
    }

    @Test
    func learnedMinSizeHeightOnlyRefusalLeavesWidthZero() {
        let requested = CGRect(x: 0, y: 0, width: 400, height: 300)
        let actual = CGRect(x: 0, y: 0, width: 400, height: 500)
        let size = WindowManager.learnedMinSize(requested: requested, actual: actual)
        #expect(size.width == 0)
        #expect(size.height == 500)
    }

    @Test
    func acceptedAxisNeverClobbersAnEarlierLearntConstraint() throws {
        // Simulates the reported failure: a window already learnt a tall
        // minHeight from an earlier width-only refusal. A later, unrelated
        // height-only refusal (this one accepting width) must not reset
        // width's learnt minimum back down via the max-merge, and must not
        // touch the width axis at all.
        var engine = Engine(config: try Config.parse(Self.sampleConfig).get())
        let id: WindowID = 1
        _ = engine.addWindow(id, pid: 1, facts: WindowFacts(bundleID: "com.example.app"), space: nil)

        // First: width refused at 776, height accepted.
        let firstRequested = CGRect(x: 0, y: 0, width: 400, height: 850)
        let firstActual = CGRect(x: 0, y: 0, width: 776, height: 850)
        _ = engine.learnMinSize(id, WindowManager.learnedMinSize(requested: firstRequested, actual: firstActual))
        #expect(engine.windows[id]?.minSize.width == 776)
        #expect(engine.windows[id]?.minSize.height == 0)

        // Second: height refused at 500, width accepted at a *smaller*
        // width than the learnt 776 minimum (as the engine would now
        // request, honoring the learnt width floor).
        let secondRequested = CGRect(x: 0, y: 0, width: 776, height: 300)
        let secondActual = CGRect(x: 0, y: 0, width: 776, height: 500)
        _ = engine.learnMinSize(id, WindowManager.learnedMinSize(requested: secondRequested, actual: secondActual))

        // The earlier width constraint survives untouched; only height grew.
        #expect(engine.windows[id]?.minSize.width == 776)
        #expect(engine.windows[id]?.minSize.height == 500)
    }

    // MARK: audit8 — config disappearing must not recreate the starter

    @Test
    func initialAbsentConfigRemainsCreatableByEdit() {
        let (dir, url) = Self.tempConfigDir() // never written
        defer { try? FileManager.default.removeItem(at: dir) }
        let wm = WindowManager(configURL: url)
        #expect(wm.loadInitialConfig())
        #expect(!FileManager.default.fileExists(atPath: url.path))

        let error = wm.editConfig { editor in
            editor.set("master_count", .integer(2), in: .layout)
        }
        #expect(error == nil)
        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(wm.config.layout.masterCount == 2)
    }

    // MARK: audit-safety — a config load/edit on an unlaunched manager must
    // never reach `tryStart`'s AX prompt or app startup.

    @Test
    func editConfigOnUnlaunchedManagerNeverAdvancesPastStarting() {
        let (dir, url) = Self.tempConfigDir() // never written
        defer { try? FileManager.default.removeItem(at: dir) }
        let wm = WindowManager(configURL: url)
        #expect(wm.loadInitialConfig())

        let error = wm.editConfig { editor in
            editor.set("master_count", .integer(2), in: .layout)
        }
        #expect(error == nil)
        // `tryStart` would move past `.starting` (to `.needsAccessibility`,
        // `.unsupported`, `.blocked`, or `.running`) the moment it runs. A
        // config edit before `launch()` must never trigger it.
        #expect(wm.status == .starting)
    }

    @Test
    func loadedThenMissingConfigRefusesToRecreateStarterAndKeepsLiveConfig() throws {
        let (dir, url) = Self.tempConfigDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Self.sampleConfig.write(to: url, atomically: true, encoding: .utf8)

        let wm = WindowManager(configURL: url)
        #expect(wm.loadInitialConfig())
        let liveConfig = try Config.parse(Self.sampleConfig).get()
        #expect(wm.config == liveConfig)

        // The file disappears out from under the running app.
        try FileManager.default.removeItem(at: url)
        #expect(!FileManager.default.fileExists(atPath: url.path))

        let error = wm.editConfig { editor in
            editor.set("master_count", .integer(2), in: .layout)
        }
        #expect(error != nil)
        // Never recreated: no starter template written over the gap.
        #expect(!FileManager.default.fileExists(atPath: url.path))
        // Live, in-memory config (rules/bindings, and everything else) untouched.
        #expect(wm.config == liveConfig)

        // A second disappearance-then-edit behaves identically (repeated deletions).
        let secondError = wm.editConfig { editor in
            editor.set("master_count", .integer(3), in: .layout)
        }
        #expect(secondError != nil)
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(wm.config == liveConfig)

        // The file reappears (e.g. dotfiles restore): edits resume normally.
        try Self.sampleConfig.write(to: url, atomically: true, encoding: .utf8)
        let restoredError = wm.editConfig { editor in
            editor.set("master_count", .integer(2), in: .layout)
        }
        #expect(restoredError == nil)
        #expect(FileManager.default.fileExists(atPath: url.path))
        let restoredText = try String(contentsOf: url, encoding: .utf8)
        let restoredConfig = try Config.parse(restoredText).get()

        var expectedConfig = liveConfig
        expectedConfig.layout.masterCount = 2
        // The reload picked up the edit (semantic equality: layout, every
        // rule's match/actions, and every binding's hotkey/command), not
        // just "some rules/bindings exist" or a substring of the raw text.
        #expect(restoredConfig == expectedConfig)
        #expect(wm.config == expectedConfig)
        // Still the user's original rule and binding, not the starter template.
        #expect(restoredConfig.rules == liveConfig.rules)
        #expect(restoredConfig.bindings == liveConfig.bindings)
    }

    @Test
    func loadedThenMissingConfigViaSymlinkTargetAlsoRefuses() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ballast-wm-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let real = dir.appendingPathComponent("real.toml")
        let link = dir.appendingPathComponent("ballast.toml")
        try Self.sampleConfig.write(to: real, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)

        let wm = WindowManager(configURL: link)
        #expect(wm.loadInitialConfig())
        let liveConfig = try Config.parse(Self.sampleConfig).get()
        #expect(wm.config == liveConfig)

        // The symlink's *target* disappears while the link itself stays.
        try FileManager.default.removeItem(at: real)

        let error = wm.editConfig { editor in
            editor.set("master_count", .integer(2), in: .layout)
        }
        #expect(error != nil)
        #expect(!FileManager.default.fileExists(atPath: real.path))
        // Live, in-memory config untouched by the refused edit.
        #expect(wm.config == liveConfig)
    }
}
