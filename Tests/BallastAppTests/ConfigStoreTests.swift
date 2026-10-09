import Testing
import Foundation
@testable import BallastApp
@testable import BallastCore

/// A throwaway config file per test; `live` stands in for the engine's config,
/// reloaded through `onChange` exactly as `WindowManager.reloadConfig` does.
@MainActor
struct ConfigStoreTests {
    private static func tempConfigDir() -> (dir: URL, url: URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ballast-store-tests-\(UUID().uuidString)", isDirectory: true)
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

    @MainActor
    private final class Live {
        var config = Config()
        init(_ store: ConfigStore) {
            store.onChange = { [unowned self, unowned store] in
                if let reloaded = store.reload() { config = reloaded }
            }
        }
    }

    private static func load(_ store: ConfigStore, into live: Live) {
        if case .success(let config) = store.loadInitial() { live.config = config }
    }

    @Test
    func initialLoadClearsErrorFromEarlierRejectedStartup() throws {
        let (dir, url) = Self.tempConfigDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try "[layout\n".write(to: url, atomically: true, encoding: .utf8)
        let store = ConfigStore(url: url)
        guard case .failure = store.loadInitial() else { Issue.record("expected parse failure"); return }
        #expect(store.error != nil)

        try Self.sampleConfig.write(to: url, atomically: true, encoding: .utf8)
        guard case .success = store.loadInitial() else { Issue.record("expected success"); return }
        #expect(store.error == nil)
    }

    @Test
    func initialAbsentConfigRemainsCreatableByEdit() {
        let (dir, url) = Self.tempConfigDir() // never written
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ConfigStore(url: url)
        let live = Live(store)
        Self.load(store, into: live)
        #expect(store.loaded)
        #expect(!FileManager.default.fileExists(atPath: url.path))

        #expect(store.edit { $0.set("feature_count", .integer(2), in: .layout) } == nil)
        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(live.config.layout.featureCount == 2)
    }

    @Test
    func danglingSymlinkConfigIsCreatedAtItsTargetAndStaysALink() throws {
        let (dir, url) = Self.tempConfigDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let target = dir.appendingPathComponent("real.toml")
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: target)
        let store = ConfigStore(url: url)
        let live = Live(store)
        Self.load(store, into: live)

        #expect(store.edit { $0.set("feature_count", .integer(2), in: .layout) } == nil)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: url.path) == target.path)
        #expect(FileManager.default.fileExists(atPath: target.path))
    }

    @Test
    func starterConfigHasNoLiveBindings() throws {
        let config = try Config.parse(StatusBar.starterConfig).get()
        #expect(config.bindings.isEmpty)
    }

    @Test
    func startupConfigErrorIsRecorded() throws {
        let (dir, url) = Self.tempConfigDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try "[layout\nnope".write(to: url, atomically: true, encoding: .utf8)
        let store = ConfigStore(url: url)
        _ = store.loadInitial()
        #expect(store.error != nil)
    }

    @Test
    func loadedThenMissingConfigRefusesToRecreateStarterAndKeepsLiveConfig() throws {
        let (dir, url) = Self.tempConfigDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Self.sampleConfig.write(to: url, atomically: true, encoding: .utf8)

        let store = ConfigStore(url: url)
        let live = Live(store)
        Self.load(store, into: live)
        let liveConfig = try Config.parse(Self.sampleConfig).get()
        #expect(live.config == liveConfig)

        // The file disappears out from under the running app.
        try FileManager.default.removeItem(at: url)

        #expect(store.edit { $0.set("feature_count", .integer(2), in: .layout) } != nil)
        // Never recreated: no starter template written over the gap.
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(live.config == liveConfig)

        // A second disappearance-then-edit behaves identically (repeated deletions).
        #expect(store.edit { $0.set("feature_count", .integer(3), in: .layout) } != nil)
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(live.config == liveConfig)

        // The file reappears (e.g. dotfiles restore): edits resume normally.
        try Self.sampleConfig.write(to: url, atomically: true, encoding: .utf8)
        #expect(store.edit { $0.set("feature_count", .integer(2), in: .layout) } == nil)
        let restoredConfig = try Config.parse(String(contentsOf: url, encoding: .utf8)).get()

        var expectedConfig = liveConfig
        expectedConfig.layout.featureCount = 2
        // The reload picked up the edit (semantic equality), not just a substring of the raw text.
        #expect(restoredConfig == expectedConfig)
        #expect(live.config == expectedConfig)
        // Still the user's original rule and binding, not the starter template.
        #expect(restoredConfig.rules == liveConfig.rules)
        #expect(restoredConfig.bindings == liveConfig.bindings)
    }

    @Test
    func loadedThenMissingConfigViaSymlinkTargetAlsoRefuses() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ballast-store-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let real = dir.appendingPathComponent("real.toml")
        let link = dir.appendingPathComponent("ballast.toml")
        try Self.sampleConfig.write(to: real, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)

        let store = ConfigStore(url: link)
        let live = Live(store)
        Self.load(store, into: live)
        let liveConfig = try Config.parse(Self.sampleConfig).get()
        #expect(live.config == liveConfig)

        // The symlink's *target* disappears while the link itself stays.
        try FileManager.default.removeItem(at: real)

        #expect(store.edit { $0.set("feature_count", .integer(2), in: .layout) } != nil)
        #expect(!FileManager.default.fileExists(atPath: real.path))
        #expect(live.config == liveConfig)
    }
}
