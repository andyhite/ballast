import Testing
import Foundation
import CoreGraphics
@testable import BallastApp
@testable import BallastCore

/// No AX/SkyLight permissions, no live WM, no user config: every test uses a
/// throwaway config file under a fresh temp directory and only exercises
/// pure/file-local `WindowManager` entry points (`learnedMinSize`, and an
/// unlaunched manager's config edit). `WindowManager` is a
/// main-thread-only class, so every test that touches it runs on the main actor.
@MainActor
struct WindowManagerTests {
    @Test func snapBackAdoptsAfterThreeRecentMoves() {
        let now = Date()
        let recent = [0.1, 0.2, 0.3].map { now.addingTimeInterval(-$0) }
        #expect(WindowManager.snapBack(history: recent, now: now).adopt == true)
        #expect(WindowManager.snapBack(history: Array(recent.prefix(2)), now: now).adopt == false)
    }

    @Test func snapBackDropsStaleStamps() {
        let now = Date()
        let result = WindowManager.snapBack(history: [now.addingTimeInterval(-2.5), now.addingTimeInterval(-1)], now: now)
        #expect(result.history.count == 2)
        #expect(result.history.last == now)
    }

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
    arrange = "dwindle"

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

    // MARK: audit-safety — a config load/edit on an unlaunched manager must
    // never reach `tryStart`'s AX prompt or app startup.

    @Test
    func editConfigOnUnlaunchedManagerNeverAdvancesPastStarting() {
        let (dir, url) = Self.tempConfigDir() // never written
        defer { try? FileManager.default.removeItem(at: dir) }
        let wm = WindowManager(configURL: url)
        #expect(wm.loadInitialConfig())

        let error = wm.configStore.edit { editor in
            editor.set("feature_count", .integer(2), in: .layout)
        }
        #expect(error == nil)
        // `tryStart` would move past `.starting` (to `.needsAccessibility`,
        // `.unsupported`, `.blocked`, or `.running`) the moment it runs. A
        // config edit before `launch()` must never trigger it.
        #expect(wm.status == .starting)
    }
}
