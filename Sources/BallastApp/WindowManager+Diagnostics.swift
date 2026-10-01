import AppKit
import BallastCore

extension WindowManager {
    static var stateDumpURL: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            .map { $0.appendingPathComponent("dev.ballast/state.json") }
            ?? URL(fileURLWithPath: "/tmp/ballast-state.json")
    }

    /// Writes a JSON snapshot of live state (used by the smoke test).
    func dumpState() {
        var spaces: [[String: Any]] = []
        for (id, state) in engine.spaces.sorted(by: { $0.key < $1.key }) {
            let key = engine.snapshot.key(for: id)
            let area = key.flatMap { displays.with(uuid: $0.display) }?.visibleFrame ?? .zero
            let frames = engine.layout(space: id, area: area).frames
            spaces.append([
                "space_id": id,
                "display": key?.display ?? NSNull(),
                "ordinal": key?.ordinal ?? NSNull(),
                "uuid": key?.uuid ?? NSNull(),
                "active": engine.snapshot.isActive(id),
                "arrange": engine.arrangement(for: id).rawValue,
                "layout": engine.glyph(for: id),
                "feature": engine.settings(for: id).effectiveFeature.rawValue,
                "feature_size_override": state.featureSizeOverride ?? NSNull(),
                "feature_count_override": state.featureCountOverride ?? NSNull(),
                "monocle": state.monocle,
                "manual": state.manual,
                "live_order": state.liveOrder.map { describe($0) },
                "ideal_order": state.idealOrder.map { describe($0) },
                "decks": state.decks.sorted(by: { $0.key < $1.key }).map { $0.value.map { describe($0) } },
                "frames": frames.map { ["window": describe($0.key), "x": $0.value.minX, "y": $0.value.minY,
                                        "w": $0.value.width, "h": $0.value.height] },
            ])
        }
        let root: [String: Any] = [
            "status": String(describing: status),
            "config": configStore.url.path,
            "config_error": configStore.error ?? NSNull(),
            "focused": engine.focused.map { describe($0) } ?? NSNull(),
            "reduce_motion": reduceMotion,
            "stage_manager_passthrough": engine.passthrough,
            "displays": displays.map { ["uuid": $0.uuid, "name": $0.name] },
            "spaces": spaces,
        ]
        let url = Self.stateDumpURL
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: url, options: .atomic)
        } catch {
            Log.wm.error("state dump failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func describe(_ id: WindowID) -> [String: Any] {
        let w = engine.windows[id]
        return ["id": id, "app": w?.facts.appName ?? "?", "bundle": w?.facts.bundleID ?? "?",
                "weight": w?.rule.weight ?? 1]
    }
}
