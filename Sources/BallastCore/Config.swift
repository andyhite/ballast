import CoreGraphics
import Foundation

public enum Easing: String, CaseIterable, Equatable, Sendable {
    case linear
    case easeOutCubic = "ease_out_cubic"
    case easeInOutCubic = "ease_in_out_cubic"
    case easeOutQuint = "ease_out_quint"

    /// Maps progress `t` in 0...1 to eased progress in 0...1.
    public func apply(_ t: Double) -> Double {
        let t = min(max(t.isFinite ? t : 1, 0), 1)
        switch self {
        case .linear: return t
        case .easeOutCubic: return 1 - pow(1 - t, 3)
        case .easeInOutCubic: return t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2
        case .easeOutQuint: return 1 - pow(1 - t, 5)
        }
    }
}

public struct AnimationSettings: Equatable, Sendable {
    public var enabled = true
    /// Seconds.
    public var duration = 0.18
    public var easing = Easing.easeOutCubic

    public init() {}
}

/// Fully-resolved layout settings for one (display, space).
public struct LayoutSettings: Equatable, Sendable {
    public var mode = LayoutMode.masterStack
    public var masterRatio = 0.6
    public var masterCount = 1
    public var stackSide = StackSide.right
    /// Axis for new BSP splits; `nil` = automatic (longer side).
    public var split: Axis?
    /// BSP weight-ratio clamp.
    public var bspMinRatio = 0.25
    public var bspMaxRatio = 0.75
    public var gaps = Gaps(inner: 8, outer: 8)

    public init() {}
}

/// Per-(display, space) partial override of `LayoutSettings`.
public struct LayoutOverrides: Equatable, Sendable {
    public var mode: LayoutMode?
    public var masterRatio: Double?
    public var masterCount: Int?
    public var stackSide: StackSide?
    public var split: Axis??
    public var bspMinRatio: Double?
    public var bspMaxRatio: Double?
    public var gapsInner: Double?
    public var gapsOuter: Double?

    public init() {}

    func applied(to base: LayoutSettings) -> LayoutSettings {
        var s = base
        if let mode { s.mode = mode }
        if let masterRatio { s.masterRatio = masterRatio }
        if let masterCount { s.masterCount = masterCount }
        if let stackSide { s.stackSide = stackSide }
        if let split { s.split = split }
        if let bspMinRatio { s.bspMinRatio = bspMinRatio }
        if let bspMaxRatio { s.bspMaxRatio = bspMaxRatio }
        if let gapsInner { s.gaps.inner = gapsInner }
        if let gapsOuter { s.gaps.outer = gapsOuter }
        return s
    }
}

public struct KeyBinding: Equatable, Sendable {
    public let hotkey: Hotkey
    public let command: Command
    /// Command text as written in the config (for menus/logs).
    public let commandText: String
}

public struct Config: Equatable, Sendable {
    public var animation = AnimationSettings()
    public var focusFollowsMouse = false
    /// Warp the cursor to the focused window's center when focus crosses displays.
    public var cursorFollowsFocus = true
    public var layout = LayoutSettings()
    public var spaces: [SpaceKey: LayoutOverrides] = [:]
    public var rules: [AppRule] = []
    public var bindings: [KeyBinding] = []

    public init() {}

    public func layoutSettings(for key: SpaceKey?) -> LayoutSettings {
        guard let key, let overrides = spaces[key] else { return layout }
        return overrides.applied(to: layout)
    }
}

/// All validation problems found in a config file, each prefixed with its path.
public struct ConfigError: Error, Equatable, CustomStringConvertible {
    public let messages: [String]
    public var description: String { messages.joined(separator: "\n") }
}

// MARK: - Parsing

extension Config {
    public static func parse(_ text: String) -> Result<Config, ConfigError> {
        let root: TOMLTable
        do {
            root = try TOML.parse(text)
        } catch let error as TOMLError {
            return .failure(ConfigError(messages: ["syntax: \(error.description)"]))
        } catch {
            return .failure(ConfigError(messages: ["syntax: \(error)"]))
        }
        let diag = Diagnostics()
        var config = Config()
        let top = Reader(root, path: "", diag: diag)
        top.allowOnly(["settings", "layout", "space", "rule", "bindings"])

        if let settings = top.table("settings") {
            settings.allowOnly(["focus_follows_mouse", "cursor_follows_focus", "animation"])
            if let v = settings.bool("focus_follows_mouse") { config.focusFollowsMouse = v }
            if let v = settings.bool("cursor_follows_focus") { config.cursorFollowsFocus = v }
            if let anim = settings.table("animation") {
                anim.allowOnly(["enabled", "duration_ms", "easing"])
                if let v = anim.bool("enabled") { config.animation.enabled = v }
                if let ms = anim.number("duration_ms") {
                    if (0...2000).contains(ms) { config.animation.duration = ms / 1000 }
                    else { anim.error("duration_ms", "must be between 0 and 2000") }
                }
                if let v: Easing = anim.enumeration("easing") { config.animation.easing = v }
            }
        }

        if let layout = top.table("layout") {
            let overrides = readLayout(layout, allowPlacement: false)
            config.layout = overrides.applied(to: LayoutSettings())
            validateClamp(config.layout, reader: layout)
        }

        for (index, space) in top.tables("space").enumerated() {
            guard let display = space.string("display"), let ordinal = space.int("ordinal") else {
                space.error("", "every [[space]] needs `display` (UUID) and `ordinal`")
                continue
            }
            if UUID(uuidString: display) == nil {
                space.error("display", "must be a display UUID (see `ballast spaces`), got '\(display)'")
            }
            if ordinal < 1 { space.error("ordinal", "must be ≥ 1") }
            let key = SpaceKey(display: display.uppercased(), ordinal: ordinal)
            if config.spaces[key] != nil {
                space.error("", "duplicate [[space]] for display \(display) ordinal \(ordinal) (entry \(index + 1))")
            }
            let overrides = readLayout(space, allowPlacement: true)
            validateClamp(overrides.applied(to: config.layout), reader: space)
            config.spaces[key] = overrides
        }

        for rule in top.tables("rule") {
            if let parsed = readRule(rule) { config.rules.append(parsed) }
        }

        if let bindings = top.table("bindings") {
            var seen: [Hotkey: String] = [:]
            for (key, value) in bindings.table.entries {
                guard case .string(let text) = value else {
                    bindings.error(key, "binding value must be a command string")
                    continue
                }
                let hotkey: Hotkey
                switch Hotkey.parse(key) {
                case .success(let h): hotkey = h
                case .failure(let e):
                    bindings.error(key, "invalid hotkey: \(e.message)")
                    continue
                }
                switch Command.parse(text) {
                case .success(let command):
                    if let previous = seen[hotkey] {
                        bindings.error(key, "same hotkey as '\(previous)'")
                        continue
                    }
                    seen[hotkey] = key
                    config.bindings.append(KeyBinding(hotkey: hotkey, command: command, commandText: text))
                case .failure(let e):
                    bindings.error(key, e.message)
                }
            }
        }

        return diag.errors.isEmpty ? .success(config) : .failure(ConfigError(messages: diag.errors))
    }

    private static let layoutKeys: Set<String> = [
        "mode", "master_ratio", "master_count", "stack_side", "split", "bsp_min_ratio", "bsp_max_ratio", "gaps",
    ]

    private static func readLayout(_ r: Reader, allowPlacement: Bool) -> LayoutOverrides {
        r.allowOnly(allowPlacement ? layoutKeys.union(["display", "ordinal"]) : layoutKeys)
        var o = LayoutOverrides()
        o.mode = r.enumeration("mode")
        if let v = r.number("master_ratio") {
            if v > 0.05 && v < 0.95 { o.masterRatio = v } else { r.error("master_ratio", "must be within 0.05…0.95") }
        }
        if let v = r.int("master_count") {
            if (1...16).contains(v) { o.masterCount = v } else { r.error("master_count", "must be within 1…16") }
        }
        o.stackSide = r.enumeration("stack_side")
        if let v = r.string("split") {
            switch v {
            case "auto": o.split = .some(nil)
            case "horizontal": o.split = .some(.horizontal)
            case "vertical": o.split = .some(.vertical)
            default: r.error("split", "expected auto|horizontal|vertical, got '\(v)'")
            }
        }
        for (key, apply) in [("bsp_min_ratio", { (v: Double) in o.bspMinRatio = v }),
                             ("bsp_max_ratio", { (v: Double) in o.bspMaxRatio = v })] {
            if let v = r.number(key) {
                if v > 0 && v < 1 { apply(v) } else { r.error(key, "must be within (0, 1)") }
            }
        }
        if let gaps = r.table("gaps") {
            gaps.allowOnly(["inner", "outer"])
            for (key, apply) in [("inner", { (v: Double) in o.gapsInner = v }),
                                 ("outer", { (v: Double) in o.gapsOuter = v })] {
                if let v = gaps.number(key) {
                    if (0...200).contains(v) { apply(v) } else { gaps.error(key, "must be within 0…200") }
                }
            }
        }
        return o
    }

    private static func validateClamp(_ s: LayoutSettings, reader: Reader) {
        if s.bspMinRatio > s.bspMaxRatio {
            reader.error("bsp_min_ratio", "must not exceed bsp_max_ratio")
        }
    }

    private static func readRule(_ r: Reader) -> AppRule? {
        let matchKeys: Set<String> = ["app_id", "app_name", "title_regex", "title_substring", "ax_role", "ax_subrole"]
        let actionKeys: Set<String> = ["weight", "manage", "float", "placement", "size", "sticky", "on_self_move"]
        r.allowOnly(matchKeys.union(actionKeys))
        let before = r.diag.errors.count
        var match = RuleMatch()
        match.appID = r.nonEmptyString("app_id")
        match.appName = r.nonEmptyString("app_name")
        match.titleSubstring = r.nonEmptyString("title_substring")
        match.axRole = r.nonEmptyString("ax_role")
        match.axSubrole = r.nonEmptyString("ax_subrole")
        if let pattern = r.nonEmptyString("title_regex") {
            do { match.titleRegex = try TitlePattern(pattern) } catch {
                r.error("title_regex", "invalid regular expression '\(pattern)'")
            }
        }
        if match.specificity == 0 && r.diag.errors.count == before {
            r.error("", "rule has no match fields (app_id, app_name, title_regex, title_substring, ax_role, ax_subrole)")
        }

        var actions = RuleActions()
        if let w = r.number("weight") {
            if w > 0 && w <= 1000 { actions.weight = w } else { r.error("weight", "must be within (0, 1000]") }
        }
        actions.manage = r.bool("manage")
        actions.float = r.bool("float")
        actions.sticky = r.bool("sticky")
        actions.onSelfMove = r.enumeration("on_self_move")
        if let value = r.table.entries.first(where: { $0.key == "placement" })?.value {
            switch value {
            case .string("center"): actions.placement = .center
            case .string("mouse"): actions.placement = .mouse
            case .table(let t):
                let pr = Reader(t, path: r.childPath("placement"), diag: r.diag)
                pr.allowOnly(["x", "y", "w", "h"])
                if let x = pr.fraction("x"), let y = pr.fraction("y"), let w = pr.fraction("w"), let h = pr.fraction("h") {
                    if w > 0 && h > 0 { actions.placement = .rect(x: x, y: y, w: w, h: h) }
                    else { pr.error("", "w and h must be > 0") }
                } else {
                    pr.error("", "needs x, y, w, h as display fractions (0…1)")
                }
            default:
                r.error("placement", "expected \"center\", \"mouse\" or { x, y, w, h }")
            }
        }
        if let size = r.table("size") {
            size.allowOnly(["w", "h"])
            if let w = size.fraction("w"), let h = size.fraction("h"), w > 0, h > 0 {
                actions.size = CGSize(width: w, height: h)
            } else {
                size.error("", "needs w and h as display fractions in (0, 1]")
            }
        }
        if actions.manage == false && (actions.float != nil || actions.placement != nil || actions.weight != nil) {
            r.error("manage", "a `manage = false` rule cannot also set weight/float/placement")
        }
        if (actions.placement != nil || actions.size != nil) && actions.float != true {
            r.error("placement", "placement/size only apply to floating windows; add `float = true`")
        }
        return r.diag.errors.count == before ? AppRule(match: match, actions: actions) : nil
    }
}

// MARK: - Typed TOML reading with path-qualified diagnostics

final class Diagnostics {
    var errors: [String] = []
}

struct Reader {
    let table: TOMLTable
    let path: String
    let diag: Diagnostics

    init(_ table: TOMLTable, path: String, diag: Diagnostics) {
        self.table = table
        self.path = path
        self.diag = diag
    }

    func childPath(_ key: String) -> String {
        key.isEmpty ? path : (path.isEmpty ? key : "\(path).\(key)")
    }

    func error(_ key: String, _ message: String) {
        let where_ = childPath(key)
        diag.errors.append(where_.isEmpty ? message : "\(where_): \(message)")
    }

    func allowOnly(_ keys: Set<String>) {
        for key in table.keys where !keys.contains(key) {
            error(key, "unknown key")
        }
    }

    private func typeError(_ key: String, _ expected: String) {
        error(key, "expected \(expected)")
    }

    func string(_ key: String) -> String? {
        guard let value = table[key] else { return nil }
        guard case .string(let s) = value else { typeError(key, "a string"); return nil }
        return s
    }

    func nonEmptyString(_ key: String) -> String? {
        guard let s = string(key) else { return nil }
        if s.isEmpty { error(key, "must not be empty"); return nil }
        return s
    }

    func bool(_ key: String) -> Bool? {
        guard let value = table[key] else { return nil }
        guard case .boolean(let b) = value else { typeError(key, "true or false"); return nil }
        return b
    }

    func number(_ key: String) -> Double? {
        switch table[key] {
        case nil: return nil
        case .integer(let i)?: return Double(i)
        case .float(let f)? where f.isFinite: return f
        default: typeError(key, "a finite number"); return nil
        }
    }

    func fraction(_ key: String) -> Double? {
        guard let v = number(key) else { return nil }
        guard (0...1).contains(v) else { error(key, "must be a display fraction within 0…1"); return nil }
        return v
    }

    func int(_ key: String) -> Int? {
        guard let value = table[key] else { return nil }
        guard case .integer(let i) = value, let v = Int(exactly: i) else { typeError(key, "an integer"); return nil }
        return v
    }

    func enumeration<T: RawRepresentable>(_ key: String) -> T? where T.RawValue == String {
        guard let s = string(key) else { return nil }
        guard let v = T(rawValue: s) else {
            error(key, "unknown value '\(s)'")
            return nil
        }
        return v
    }

    func table(_ key: String) -> Reader? {
        guard let value = table[key] else { return nil }
        guard case .table(let t) = value else { typeError(key, "a table"); return nil }
        return Reader(t, path: childPath(key), diag: diag)
    }

    /// `[[key]]` array of tables (absent = empty).
    func tables(_ key: String) -> [Reader] {
        guard let value = table[key] else { return [] }
        guard case .array(let items) = value else { typeError(key, "an array of tables ([[\(key)]])"); return [] }
        var readers: [Reader] = []
        for (i, item) in items.enumerated() {
            guard case .table(let t) = item else {
                error("\(key)[\(i + 1)]", "expected a table")
                continue
            }
            readers.append(Reader(t, path: "\(childPath(key))[\(i + 1)]", diag: diag))
        }
        return readers
    }
}
