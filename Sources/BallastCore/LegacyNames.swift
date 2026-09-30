import Foundation

/// Names that no longer exist. They are never accepted; parsing reports them
/// with the replacement so a stale config or binding fails with a fix in hand.
enum LegacyNames {
    /// Config key → replacement key.
    static let renamedKeys: [String: String] = [
        "master_ratio": "feature_size",
        "main_ratio": "feature_size",
        "master_count": "feature_count",
        "main_count": "feature_count",
        "grid_columns": "columns",
        "stack_columns": "columns",
        "grid_max": "rows",
        "stack_max": "rows",
        "stack_peek": "deck_peek",
        "bsp_min_ratio": "weight_share_min",
        "bsp_max_ratio": "weight_share_max",
    ]
    /// Config key → what to do instead.
    static let removedKeys: [String: String] = [
        "stack_side": "use feature (the opposite side)",
        "stack_both_sides": "use feature = \"center\"",
        "bsp_shape": "use arrange = \"dwindle\" | \"balanced\"",
        "mode": "use arrange and feature",
        "mode_by_count": "",
    ]
    /// Command (verb, or "verb argument") → replacement command.
    static let renamedCommands: [String: String] = [
        "master-ratio": "feature-size",
        "main-ratio": "feature-size",
        "master-count": "feature-count",
        "main-count": "feature-count",
        "focus-master": "focus-feature",
        "focus-main": "focus-feature",
        "focus master": "focus feature",
        "focus main": "focus feature",
        "group": "deck",
        "ungroup": "undeck",
    ]
    /// Command → what to do instead.
    static let removedCommands: [String: String] = [
        "layout": "set arrange in the menu, Settings, or config",
    ]

    static func keyMessage(_ key: String) -> String? {
        if let new = renamedKeys[key] { return "renamed to \(new)" }
        if let hint = removedKeys[key] { return hint.isEmpty ? "removed" : "removed; \(hint)" }
        return nil
    }

    /// Why `name` (a verb, or "verb argument") is not a command, when it used to be.
    static func commandMessage(_ name: String) -> String? {
        if let new = renamedCommands[name] { return "unknown command '\(name)' (renamed to '\(new)')" }
        if let hint = removedCommands[name] { return "unknown command '\(name)' (removed; \(hint))" }
        return nil
    }
}
