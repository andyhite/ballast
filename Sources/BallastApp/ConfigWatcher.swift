import Foundation
import os

/// Watches a config file for real content changes and invokes a callback on
/// the main thread, debounced.
///
/// The watched path may not exist yet (e.g. `~/.config/ballast` has never
/// been created), may be — or become — a symlink into an arbitrary
/// directory, and the directories along the way may be deleted and
/// recreated at any time. To stay correct across all of that, the watcher
/// maintains two independently re-armable directory watches:
///
/// - `originalChainWatcher` follows the nearest *existing* ancestor of the
///   caller-supplied path itself, so it notices missing ancestor
///   directories being created, a symlink at that path being created,
///   deleted, or retargeted, and any watched directory along the way being
///   deleted or replaced.
/// - `targetChainWatcher` follows the nearest existing ancestor of the
///   *resolved* (symlinks-followed) path, which may live in a completely
///   different directory than the original path when a symlink points
///   elsewhere — including tracking a symlink whose target does not exist
///   yet.
///
/// A third, file-level source watches the resolved file itself, so
/// in-place writes, truncation, deletion, and atomic-save renames (which
/// swap the inode under the watched path) are all noticed. Every event from
/// any of the three sources funnels through `refreshWatchers()`, which
/// re-resolves symlinks, re-arms both directory chains, re-attaches the
/// file-level source if needed, and finally schedules a single debounced
/// content check — so a burst of related events (e.g. an atomic save
/// touching both the directory and the file) never produces more than one
/// `onChange` call.
public final class ConfigWatcher {
    fileprivate static let logger = Logger(subsystem: "dev.ballast", category: "config-watcher")
    private static let debounceInterval: TimeInterval = 0.1

    /// The caller-supplied path, exactly as given (may be a symlink).
    private let originalURL: URL
    private let onChange: () -> Void

    private var originalChainWatcher: DirectoryChainWatcher?
    private var targetChainWatcher: DirectoryChainWatcher?

    /// `originalURL` with symlinks resolved as far as possible. Recomputed
    /// on every `refreshWatchers()` call so a retargeted symlink is picked
    /// up immediately.
    private var resolvedTargetPath: String = ""

    private var fileSource: DispatchSourceFileSystemObject?
    private var fileDescriptor: Int32 = -1
    /// The path `fileSource` is currently attached to, if any.
    private var watchedFilePath: String?

    private var lastContent: Data?
    private var debounceWorkItem: DispatchWorkItem?
    private var isRunning = false

    public init(url: URL, onChange: @escaping () -> Void) {
        self.originalURL = url
        self.onChange = onChange
    }

    deinit {
        stop()
    }

    /// Starts watching. Safe to call once; subsequent calls while already
    /// running are ignored.
    public func start() {
        guard !isRunning else { return }
        isRunning = true

        lastContent = try? Data(contentsOf: originalURL)

        originalChainWatcher = DirectoryChainWatcher { [weak self] in self?.refreshWatchers() }
        targetChainWatcher = DirectoryChainWatcher { [weak self] in self?.refreshWatchers() }

        refreshWatchers()
    }

    /// Records `content` as the last-seen content without invoking
    /// `onChange`. Call after writing the file yourself so the debounced
    /// content check (which will still run) sees no change and skips a
    /// redundant reload.
    public func acknowledge(content: Data) {
        lastContent = content
    }

    /// Stops watching and releases all file descriptors.
    public func stop() {
        isRunning = false
        debounceWorkItem?.cancel()
        debounceWorkItem = nil

        originalChainWatcher?.cancel()
        originalChainWatcher = nil
        targetChainWatcher?.cancel()
        targetChainWatcher = nil

        closeFileSource()
    }

    /// Re-resolves the symlink chain, re-arms both directory watches to
    /// whatever directories currently exist, re-attaches the file-level
    /// watch if its target changed or its descriptor went stale, and
    /// schedules a single debounced content check. Called from every event
    /// handler below, so it must be idempotent and cheap when nothing
    /// actually changed.
    private func refreshWatchers() {
        guard isRunning else { return }

        resolvedTargetPath = originalURL.resolvingSymlinksIncludingDangling().path

        originalChainWatcher?.rearm(leafParent: originalURL.deletingLastPathComponent().path, followSymlinks: false)
        targetChainWatcher?.rearm(leafParent: (resolvedTargetPath as NSString).deletingLastPathComponent, followSymlinks: true)
        reopenFileSourceIfNeeded()
        scheduleCheck()
    }

    // MARK: - File-level source

    /// Re-attaches the file-level watch if it is pointed at the wrong path
    /// (the resolved symlink target changed) or its descriptor no longer
    /// refers to the file at `resolvedTargetPath` (e.g. after a delete or
    /// atomic rename).
    private func reopenFileSourceIfNeeded() {
        guard isRunning else { return }
        let path = resolvedTargetPath

        if watchedFilePath != path {
            closeFileSource()
        }

        var currentStat = stat()
        let currentExists = stat(path, &currentStat) == 0

        if fileDescriptor < 0 {
            if currentExists {
                openFileSource(at: path)
            }
            return
        }

        var openStat = stat()
        let openIsValid = fstat(fileDescriptor, &openStat) == 0

        if !currentExists || !openIsValid || openStat.st_ino != currentStat.st_ino {
            closeFileSource()
            if currentExists {
                openFileSource(at: path)
            }
        }
    }

    private func openFileSource(at path: String) {
        let descriptor = open(path, O_EVTONLY)
        guard descriptor >= 0 else {
            // File may not exist yet; the directory watchers will notice
            // when it's created.
            return
        }
        fileDescriptor = descriptor
        watchedFilePath = path

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            // `.attrib` catches metadata-only changes such as
            // `truncate(path, 0)`, which neither `.write` nor `.extend`
            // reports on their own.
            eventMask: [.write, .extend, .delete, .rename, .attrib],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            self?.refreshWatchers()
        }
        // Each source owns (and closes) exactly the descriptor it was created with.
        source.setCancelHandler { close(descriptor) }
        source.resume()
        fileSource = source
    }

    private func closeFileSource() {
        fileSource?.cancel()
        fileSource = nil
        fileDescriptor = -1
        watchedFilePath = nil
    }

    // MARK: - Debounced content check

    private func scheduleCheck() {
        debounceWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.checkForChange()
        }
        debounceWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.debounceInterval, execute: workItem)
    }

    private func checkForChange() {
        let currentContent = try? Data(contentsOf: originalURL)
        guard currentContent != lastContent else { return }
        lastContent = currentContent
        onChange()
    }
}

/// A dynamically re-armable set of directory watches that together notice
/// every filesystem change that could affect where `leafParent` resolves.
///
/// A single watch on the nearest existing ancestor is not enough when
/// `followSymlinks` is false: the original path may pass through a symlink
/// *above* its immediate parent — `$BALLAST_CONFIG` or `$XDG_CONFIG_HOME`
/// pointing into a dotfiles checkout, or `~/.config` itself symlinked
/// wholesale, are both real layouts dotfiles managers produce. `lstat`
/// only refuses to follow the *final* component of the path it's given;
/// the kernel still transparently resolves every symlink above that. So
/// naively `lstat`-ing whole candidate paths while walking upward — the
/// original approach here — lands on the resolved leaf directory without
/// ever noticing an ancestor symlink at all, and a later retarget of that
/// symlink then produces no filesystem event anyone is watching for:
/// the file it now points at can be edited forever without Ballast
/// noticing. `rearm` instead walks the path one component at a time from
/// the root, opening a watch on the *containing* directory of every
/// symlink it finds along the way (so retargeting or removing that
/// symlink is itself an event), plus the deepest existing directory
/// reached. Callers are expected to call `rearm` again from within
/// `onEvent`.
private final class DirectoryChainWatcher {
    private struct Watch {
        let path: String
        let descriptor: Int32
        let source: DispatchSourceFileSystemObject
    }

    private(set) var watchedPaths: [String] = []
    private var watches: [Watch] = []
    private let onEvent: () -> Void

    init(onEvent: @escaping () -> Void) {
        self.onEvent = onEvent
    }

    /// Re-arms the watch set for `leafParent` (the directory that should
    /// eventually contain the file we care about). No-ops if every watch
    /// is already open on exactly the desired set of directories.
    func rearm(leafParent: String, followSymlinks: Bool) {
        let desired = followSymlinks
            ? [Self.nearestExistingDirectory(at: leafParent)]
            : Self.symlinkAwareChain(leafParent: leafParent)
        if desired == watchedPaths, Self.allStillValid(watches) { return }

        cancel()
        for path in desired {
            let fd = open(path, O_EVTONLY)
            guard fd >= 0 else {
                ConfigWatcher.logger.error("failed to open directory \(path, privacy: .public) for watching")
                continue
            }
            let src = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: fd,
                eventMask: [.write, .delete, .rename, .attrib],
                queue: .main
            )
            src.setEventHandler { [weak self] in self?.onEvent() }
            src.setCancelHandler { close(fd) }
            src.resume()
            watches.append(Watch(path: path, descriptor: fd, source: src))
        }
        watchedPaths = watches.map(\.path)
    }

    func cancel() {
        for watch in watches { watch.source.cancel() }
        watches = []
        watchedPaths = []
    }

    /// Every currently-open watch still refers, by inode, to the directory
    /// it was opened for — nothing along the chain was deleted, replaced,
    /// or retargeted since the last `rearm`.
    private static func allStillValid(_ watches: [Watch]) -> Bool {
        watches.allSatisfy { watch in
            var openStat = stat(), currentStat = stat()
            guard fstat(watch.descriptor, &openStat) == 0, stat(watch.path, &currentStat) == 0 else { return false }
            return openStat.st_dev == currentStat.st_dev && openStat.st_ino == currentStat.st_ino
        }
    }

    /// Walks `leafParent` one path component at a time from the root,
    /// `lstat`-ing each individual component in isolation (never a
    /// multi-component string, which the kernel would silently resolve
    /// through any symlink above the final one). Returns, root-to-leaf:
    /// the containing directory of every symlink component found, plus
    /// the deepest existing directory reached — the fully resolved
    /// `leafParent` itself when every component exists and none is a
    /// symlink, or the nearest existing ancestor when a component is
    /// missing.
    private static func symlinkAwareChain(leafParent: String) -> [String] {
        let standardized = (leafParent as NSString).standardizingPath
        let components = standardized.split(separator: "/").map(String.init)
        var chain: [String] = []
        var soFar = "/"
        for component in components {
            let candidate = soFar == "/" ? "/\(component)" : "\(soFar)/\(component)"
            var st = stat()
            guard lstat(candidate, &st) == 0 else {
                chain.append(soFar) // missing: watch the deepest existing ancestor for its creation
                return Self.deduped(chain)
            }
            if (st.st_mode & S_IFMT) == S_IFLNK {
                chain.append(soFar) // symlink component: watch its container for a retarget/removal
            }
            soFar = candidate
        }
        chain.append(soFar) // fully resolved: also watch the leaf directory itself
        return Self.deduped(chain)
    }

    private static func deduped(_ paths: [String]) -> [String] {
        var seen = Set<String>()
        return paths.filter { seen.insert($0).inserted }
    }

    /// Walks upward from `path` looking for the nearest existing
    /// directory, following symlinks throughout. Used only for the
    /// already-resolved target path, which has no further symlinks left
    /// to discover.
    private static func nearestExistingDirectory(at path: String) -> String {
        var candidate = (path as NSString).standardizingPath
        while true {
            var st = stat()
            if stat(candidate, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR {
                return candidate
            }
            let parent = (candidate as NSString).deletingLastPathComponent
            if parent.isEmpty || parent == candidate {
                return "/"
            }
            candidate = parent
        }
    }
}

extension URL {
    /// `resolvingSymlinksInPath()`, but also follows a final symlink whose target is missing (≤ 8 hops).
    func resolvingSymlinksIncludingDangling() -> URL {
        var url = standardizedFileURL
        for _ in 0..<8 {
            guard let dest = try? FileManager.default.destinationOfSymbolicLink(atPath: url.path) else { break }
            url = URL(fileURLWithPath: dest, relativeTo: url.deletingLastPathComponent()).standardizedFileURL
        }
        return url.resolvingSymlinksInPath()
    }
}
