import Testing
import Foundation
@testable import BallastApp

/// Real filesystem events in a temp directory; every wait is bounded.
@MainActor
struct ConfigWatcherTests {
    private final class Counter { var count = 0 }

    private static func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ballast-watcher-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.resolvingSymlinksInPath()
    }

    private func write(_ text: String, to url: URL) throws {
        try Data(text.utf8).write(to: url, options: .atomic)
    }

    /// Lets the main queue run until `condition` holds; false on timeout.
    private func wait(timeout: TimeInterval = 3, until condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return condition()
    }

    private func settle(_ seconds: TimeInterval = 0.5) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    @Test func atomicRenameSaveFiresOnce() async throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("ballast.toml")
        try write("one", to: url)
        let counter = Counter()
        let watcher = ConfigWatcher(url: url) { counter.count += 1 }
        watcher.start()
        defer { watcher.stop() }

        let staged = dir.appendingPathComponent("staged")
        try Data("two".utf8).write(to: staged)
        #expect(rename(staged.path, url.path) == 0)

        #expect(await wait { counter.count >= 1 })
        await settle()
        #expect(counter.count == 1)
    }

    @Test func acknowledgedOwnWriteDoesNotFire() async throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("ballast.toml")
        try write("one", to: url)
        let counter = Counter()
        let watcher = ConfigWatcher(url: url) { counter.count += 1 }
        watcher.start()
        defer { watcher.stop() }

        let data = Data("two".utf8)
        try data.write(to: url, options: .atomic)
        watcher.acknowledge(content: data)
        await settle()
        #expect(counter.count == 0)

        // Still alive: a later external change fires.
        try write("three", to: url)
        #expect(await wait { counter.count == 1 })
    }

    @Test func retargetedAncestorSymlinkIsNoticed() async throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fm = FileManager.default
        for name in ["real1", "real2"] {
            try fm.createDirectory(at: dir.appendingPathComponent("\(name)/ballast"), withIntermediateDirectories: true)
            try write(name, to: dir.appendingPathComponent("\(name)/ballast/config.toml"))
        }
        let link = dir.appendingPathComponent("link")
        try fm.createSymbolicLink(at: link, withDestinationURL: dir.appendingPathComponent("real1"))
        let counter = Counter()
        let watcher = ConfigWatcher(url: link.appendingPathComponent("ballast/config.toml")) { counter.count += 1 }
        watcher.start()
        defer { watcher.stop() }

        try fm.removeItem(at: link)
        try fm.createSymbolicLink(at: link, withDestinationURL: dir.appendingPathComponent("real2"))
        #expect(await wait { counter.count == 1 })

        // The new target is now the one being watched.
        try write("edited", to: dir.appendingPathComponent("real2/ballast/config.toml"))
        #expect(await wait { counter.count == 2 })
    }

    @Test func deletedAndRecreatedDirectoryRearms() async throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fm = FileManager.default
        let sub = dir.appendingPathComponent("sub")
        try fm.createDirectory(at: sub, withIntermediateDirectories: true)
        let url = sub.appendingPathComponent("config.toml")
        try write("one", to: url)
        let counter = Counter()
        let watcher = ConfigWatcher(url: url) { counter.count += 1 }
        watcher.start()
        defer { watcher.stop() }

        try fm.removeItem(at: sub)
        #expect(await wait { counter.count == 1 })

        try fm.createDirectory(at: sub, withIntermediateDirectories: true)
        try write("two", to: url)
        #expect(await wait { counter.count == 2 })

        // And the recreated file is itself watched.
        try write("three", to: url)
        #expect(await wait { counter.count == 3 })
    }
}
