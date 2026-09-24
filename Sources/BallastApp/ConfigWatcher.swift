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

        resolvedTargetPath = originalURL.resolvingSymlinksInPath().path

        originalChainWatcher?.rearm(leafParent: originalURL.deletingLastPathComponent().path)
        targetChainWatcher?.rearm(leafParent: (resolvedTargetPath as NSString).deletingLastPathComponent)
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

/// A single, dynamically re-armable directory watch that always tracks the
/// nearest existing ancestor of a target directory path. When the target
/// directory (or one of its missing ancestors) is created, `rearm` advances
/// the watch deeper; when the currently-watched directory itself is deleted
/// or replaced, `rearm` steps back up to whatever ancestor still exists.
/// Callers are expected to call `rearm` again from within `onEvent`.
private final class DirectoryChainWatcher {
    private(set) var watchedPath: String?
    private var source: DispatchSourceFileSystemObject?
    private var descriptor: Int32 = -1
    private let onEvent: () -> Void

    init(onEvent: @escaping () -> Void) {
        self.onEvent = onEvent
    }

    /// Re-arms the watch on the nearest existing ancestor of `leafParent`
    /// (the directory that should eventually contain the file we care
    /// about). No-ops if already watching that exact directory.
    func rearm(leafParent: String) {
        let desired = Self.nearestExistingDirectory(at: leafParent)
        guard desired != watchedPath else { return }

        cancel()

        let fd = open(desired, O_EVTONLY)
        guard fd >= 0 else {
            ConfigWatcher.logger.error("failed to open directory \(desired, privacy: .public) for watching")
            return
        }
        descriptor = fd
        watchedPath = desired

        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .delete, .rename, .attrib],
            queue: .main
        )
        src.setEventHandler { [weak self] in
            self?.onEvent()
        }
        src.setCancelHandler { close(fd) }
        src.resume()
        source = src
    }

    func cancel() {
        source?.cancel()
        source = nil
        descriptor = -1
        watchedPath = nil
    }

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
