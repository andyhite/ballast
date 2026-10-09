import Foundation
import BallastCore

/// The config file: reading, text-preserving edits, the file watcher, and the
/// debounced write-back of settings changed by commands. It never touches the
/// live `Engine`; the owner applies what it loads through `onChange`,
/// `address` and `clearOverrides`. Main thread only.
@MainActor
final class ConfigStore {
    struct LoadError: Error { let message: String }

    let url: URL
    /// Latest reload error; the previous config stays live while set.
    private(set) var error: String?
    private(set) var note: String?
    private(set) var loaded = false
    /// True once a real config file was successfully read from disk at
    /// least once (built-in defaults for a file that never existed do not
    /// count). Once true, a later disappearance must never cause `edit`
    /// to recreate the starter template and silently drop the live config.
    private var everLoadedFromDisk = false
    private var watcher: ConfigWatcher?
    /// Settings changed by commands (hotkeys, `ballast send …`, menu),
    /// merged per-Space and flushed to the config file after a short
    /// debounce, so a held grow/shrink key does not write on every step.
    private var pending: [SpaceID: SettingsChange] = [:]
    private var flushWorkItem: DispatchWorkItem?

    /// The file changed on disk or was just written by `edit`: reload it.
    var onChange: () -> Void = {}
    /// The config address of a Space; nil when it has no stable one (fullscreen, or removed).
    var address: (SpaceID) -> SpaceAddress? = { _ in nil }
    /// Drops a Space's runtime overrides once their value is persisted.
    var clearOverrides: (SpaceID, _ featureSize: Bool, _ featureCount: Bool) -> Void = { _, _, _ in }

    init(url: URL) {
        self.url = url
    }

    /// The watcher only exists once `startWatching()` has run (`launch()`).
    var isWatching: Bool { watcher != nil }

    func startWatching() {
        watcher = ConfigWatcher(url: url) { [weak self] in self?.onChange() }
        watcher?.start()
    }

    func read() -> Result<Config, LoadError> {
        let text: String
        do { text = try String(contentsOf: url, encoding: .utf8) } catch {
            return .failure(.init(message: "cannot read \(url.path): \(error.localizedDescription)"))
        }
        return Config.parse(text).mapError { LoadError(message: $0.description) }
    }

    /// First load: built-in defaults for a file that never existed, else the parsed file.
    func loadInitial() -> Result<Config, LoadError> {
        guard FileManager.default.fileExists(atPath: url.path) else {
            error = nil
            note = "No config file; using built-in defaults"
            loaded = true
            return .success(Config())
        }
        let result = read()
        if case .failure(let f) = result { error = f.message }
        if case .success = result {
            error = nil
            note = nil
            loaded = true
            everLoadedFromDisk = true
        }
        return result
    }

    /// Re-reads the file; nil when it is missing or invalid (`error` says why
    /// and the caller keeps its previous config).
    func reload() -> Config? {
        guard FileManager.default.fileExists(atPath: url.path) else {
            error = "Config file missing at \(url.path); keeping the current config"
            return nil
        }
        switch read() {
        case .success(let config):
            error = nil
            note = nil
            everLoadedFromDisk = true
            return config
        case .failure(let failure):
            error = failure.message
            Log.config.error("rejected config: \(failure.message, privacy: .public)")
            Notifier.post(title: "Ballast config rejected", body: failure.message)
            return nil
        }
    }

    /// The config file (or its directory) was just created by us: re-arm the
    /// watcher, which could not watch a missing directory, and load it.
    private func fileCreated() {
        watcher?.stop()
        watcher?.start()
        onChange()
    }

    /// Reads the config file, applies `change`, validates the result, and —
    /// only if that succeeds — writes it atomically to the symlink-resolved
    /// path and reloads. On any failure nothing is written, a notification is
    /// posted, and the error is returned.
    ///
    /// If the file does not exist, this falls back to the starter template —
    /// but only when no real config was ever successfully loaded from disk.
    /// Once one has been, a later disappearance (moved/renamed, briefly
    /// absent during a dotfiles restore, …) must fail the edit instead of
    /// silently recreating a starter over the user's config; the owner
    /// already keeps the live, in-memory config running in that case, and
    /// the edit can be retried once the file reappears.
    @discardableResult
    func edit(_ change: (inout ConfigEditor) -> Result<Void, ConfigEditError>) -> ConfigEditError? {
        let resolvedURL = url.resolvingSymlinksIncludingDangling()
        let missing = !FileManager.default.fileExists(atPath: resolvedURL.path)
        if missing, everLoadedFromDisk {
            let editError = ConfigEditError("Config file missing at \(resolvedURL.path); not recreating it")
            Notifier.post(title: "Ballast couldn't save the change", body: editError.description)
            return editError
        }
        let text: String
        if missing {
            text = StatusBar.starterConfig
        } else {
            do { text = try String(contentsOf: resolvedURL, encoding: .utf8) } catch {
                let editError = ConfigEditError("cannot read \(resolvedURL.path): \(error.localizedDescription)")
                Notifier.post(title: "Ballast couldn't save the change", body: editError.description)
                return editError
            }
        }
        var editor = ConfigEditor(text: text)
        if case .failure(let error) = change(&editor) {
            Notifier.post(title: "Ballast couldn't save the change", body: error.description)
            return error
        }
        if case .failure(let error) = editor.validated() {
            let editError = ConfigEditError(error.description)
            Notifier.post(title: "Ballast couldn't save the change", body: editError.description)
            return editError
        }
        let data = Data(editor.text.utf8)
        do {
            if missing {
                try FileManager.default.createDirectory(at: resolvedURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            } else {
                // Re-read immediately before writing: an external editor (or
                // another Ballast command's debounced settings flush) may
                // have changed the file after this edit's initial read
                // above. Overwriting that unseen change would silently
                // drop it; fail the edit instead so the caller can reload
                // and retry. This narrows, rather than eliminates, the
                // race — a write landing between this check and the write
                // just below is still possible — but closes the window
                // that was previously open for this whole function's
                // read-edit-validate duration.
                let onDisk = try? String(contentsOf: resolvedURL, encoding: .utf8)
                guard onDisk == text else {
                    let editError = ConfigEditError(
                        "Config file changed on disk since this edit started; not overwriting it. Reload and retry.")
                    Notifier.post(title: "Ballast couldn't save the change", body: editError.description)
                    return editError
                }
            }
            try data.write(to: resolvedURL, options: .atomic)
        } catch {
            let editError = ConfigEditError("cannot write \(resolvedURL.path): \(error.localizedDescription)")
            Notifier.post(title: "Ballast couldn't save the change", body: editError.description)
            return editError
        }
        // Our own write would otherwise trigger a second, redundant reload
        // once the watcher's debounced content check runs.
        watcher?.acknowledge(content: data)
        if missing {
            fileCreated()
        } else {
            onChange()
        }
        return nil
    }

    /// Writes a per-desktop setting (`nil` removes it, so the desktop
    /// inherits `[layout]`) into that desktop's `[[space]]` block, and, on
    /// success, drops any runtime override of the same setting.
    @discardableResult
    func setSpaceSetting(_ key: String, _ value: ConfigValue?, space: SpaceID) -> ConfigEditError? {
        guard let address = address(space) else {
            return ConfigEditError("This desktop has no stable config address (fullscreen or unknown).")
        }
        if let error = edit({ $0.set(key, value, in: .space(address)) }) { return error }
        switch key {
        case "feature_size": clearOverrides(space, true, false)
        case "feature_count": clearOverrides(space, false, true)
        default: break
        }
        return nil
    }

    /// The one "Remove Desktop Overrides" path: drops the `[[space]]` blocks and any pending or runtime overrides.
    @discardableResult
    func removeDesktopOverrides(_ key: SpaceKey, space: SpaceID?) -> ConfigEditError? {
        if let error = edit({ $0.removeSpaces(for: key) }) { return error }
        if let space { pending[space] = nil; clearOverrides(space, true, true) }
        return nil
    }

    /// Merges a command's setting change into the pending queue for its
    /// Space (later fields win) and (re)starts the debounce timer.
    func schedulePersist(_ change: SettingsChange) {
        var merged = pending[change.space] ?? SettingsChange(space: change.space)
        if let size = change.featureSize { merged.featureSize = size }
        if let count = change.featureCount { merged.featureCount = count }
        pending[change.space] = merged
        flushWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in self?.flushPendingSettings() }
        flushWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: workItem)
    }

    /// Writes every pending Space's changes to the config in one edit per
    /// Space, then drops the runtime overrides that are now persisted. A
    /// Space without a stable config address (fullscreen, or since removed)
    /// is skipped: its runtime override stays the effective, unsaved value.
    func flushPendingSettings() {
        flushWorkItem = nil
        let flushing = pending
        pending.removeAll()
        for (space, change) in flushing {
            guard let address = address(space) else { continue }
            let error = edit { editor in
                if let size = change.featureSize,
                   case .failure(let e) = editor.set("feature_size", .float(size), in: .space(address)) {
                    return .failure(e)
                }
                if let count = change.featureCount,
                   case .failure(let e) = editor.set("feature_count", .integer(count), in: .space(address)) {
                    return .failure(e)
                }
                return .success(())
            }
            guard error == nil else { continue } // notification already posted; runtime override stays effective
            clearOverrides(space, change.featureSize != nil, change.featureCount != nil)
        }
    }
}
