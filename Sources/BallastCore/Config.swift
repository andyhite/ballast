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

/// The modifier whose hold shows the focus border; `none` turns holding off.
public enum FocusFlashHold: String, CaseIterable, Equatable, Sendable {
    case alt
    case ctrl
    case cmd
    case none
}

/// The border that marks the focused window after a Ballast command moves
/// focus, and while the hold modifier is down.
public struct FocusFlashSettings: Equatable, Sendable {
    public var enabled = true
    /// Seconds the border stays up after a command moves focus, fade included.
    public var duration = 0.8
    public var hold = FocusFlashHold.alt

    public init() {}
}

/// How tiles are arranged in the area outside the feature (or in the whole
/// area when there is no feature).
public enum Arrangement: String, CaseIterable, Equatable, Sendable {
    /// `columns` × `rows`: a fixed grid whose last column decks its overflow.
    case fixed
    /// √n equal cells, row-major; the last row stretches.
    case adaptive
    /// Binary space partition: each window splits the previous one.
    case dwindle
    /// Binary space partition as an equal-area grid.
    case balanced
    /// Hands off: windows keep the frames they have.
    case float

    /// Human name for menus, Settings, and the Inspector.
    public var label: String {
        switch self {
        case .fixed: return "Fixed grid"
        case .adaptive: return "Adaptive grid"
        case .dwindle: return "BSP dwindle"
        case .balanced: return "BSP balanced"
        case .float: return "Float"
        }
    }

    /// Whether the arrangement is a BSP tree.
    public var isTree: Bool { self == .dwindle || self == .balanced }
}

/// Which side of the area the feature takes, if any.
public enum FeatureSide: String, CaseIterable, Equatable, Sendable {
    case off = "none"
    case left, right, top, bottom
    /// The feature in the middle, the grid split into a right and a left half.
    case center

    public var label: String {
        switch self {
        case .off: return "None"
        case .left: return "Left"
        case .right: return "Right"
        case .top: return "Top"
        case .bottom: return "Bottom"
        case .center: return "Center"
        }
    }

    /// Axis along which the feature and the grid sit side by side.
    var primaryAxis: Axis { self == .top || self == .bottom ? .vertical : .horizontal }
    /// The grid comes after the feature (right of or below it) along the primary axis.
    var gridFollows: Bool { self == .left || self == .top || self == .center }
}

/// Fully-resolved layout settings for one (display, space).
public struct LayoutSettings: Equatable, Sendable {
    public var arrange = Arrangement.fixed
    /// fixed: columns side by side (per grid half with a centered feature),
    /// filled column-major nearest the feature first.
    public var columns = 1
    /// fixed: the most tiles shown per column; past `columns * rows` tiles
    /// the last column decks and scrolls with `rows` in view. 0 = no cap.
    public var rows = 1
    public var feature = FeatureSide.off
    public var featureSize = 0.6
    public var featureCount = 1
    /// Where a window that newly opens on a float Space is put.
    public var floatPlacement = FloatPlacement.cascade
    /// Points of the previous and next deck windows left showing at either
    /// end of a scrolling deck.
    public var deckPeek = 30.0
    /// Axis for new BSP splits; `nil` = automatic (longer side).
    public var split: Axis?
    /// Weight Share Limit, for every arrangement. BSP clamps each split's first
    /// share to `[weightShareMin, weightShareMax]`; feature and fixed columns
    /// apply the same band as `maxWeightRatio`.
    public var weightShareMin = 0.25
    public var weightShareMax = 0.75
    public var gaps = Gaps(inner: 8, outer: 8)

    /// The small-screen defaults (see `defaults(small:)`).
    public init() {}

    /// Visible-frame width below which a display counts as small.
    public static let smallWidth = 1800.0

    /// Built-in defaults: a small screen shows one full-screen deck; a large
    /// one a feature on the left beside two tiles.
    public static func defaults(small: Bool) -> LayoutSettings {
        var s = LayoutSettings()
        if !small {
            s.rows = 2
            s.feature = .left
        }
        return s
    }

    /// The feature side the layout uses: BSP has one tree and no halves, so
    /// a centered feature sits on the left there. `.off` for float.
    public var effectiveFeature: FeatureSide {
        switch arrange {
        case .float: return .off
        case .dwindle, .balanced: return feature == .center ? .left : feature
        case .fixed, .adaptive: return feature
        }
    }

    public var hasFeature: Bool { effectiveFeature != .off }

    /// Tiles shown at once per grid column before it decks; `nil` = all.
    public var deckLimit: Int? { arrange == .fixed && rows > 0 ? rows : nil }

    /// Grid columns per side (1 outside `fixed`).
    public var gridColumns: Int { arrange == .fixed ? max(columns, 1) : 1 }

    /// Menu-bar glyph: `F·` when a feature is on, then `C×R` (`∞` for no row cap),
    /// `A`, `D`, `B`; `⋯` for float.
    public var glyph: String {
        let body: String
        switch arrange {
        case .fixed: body = "\(columns)×\(rows == 0 ? "∞" : String(rows))"
        case .adaptive: body = "A"
        case .dwindle: body = "D"
        case .balanced: body = "B"
        case .float: return "⋯"
        }
        return hasFeature ? "F·\(body)" : body
    }

    /// Human description for menus and the Inspector, e.g. "Fixed 1×2 with left feature".
    public var summary: String {
        var text: String
        switch arrange {
        case .fixed: text = "Fixed grid \(columns)×\(rows == 0 ? "∞" : String(rows))"
        case .adaptive: text = Arrangement.adaptive.label
        case .dwindle: text = Arrangement.dwindle.label
        case .balanced: text = Arrangement.balanced.label
        case .float: return "Float"
        }
        if hasFeature {
            let side = effectiveFeature
            text += side == .center ? " with centered feature" : " with \(side.rawValue) feature"
        }
        return text
    }

    /// The Weight Share Limit as a feature/column factor: no window's weight
    /// counts for more than this many times the lightest in its region, so two
    /// windows split a region at most 75/25 by default, like the two sides of
    /// a BSP split.
    public var maxWeightRatio: Double {
        let lo = min(weightShareMin, weightShareMax), hi = max(weightShareMin, weightShareMax)
        return lo > 0 ? hi / lo : .infinity
    }
}

public enum FloatPlacement: String, CaseIterable, Equatable, Sendable {
    case cascade
    case none
}

/// Partial override of `LayoutSettings`: what a `[layout]` or `[[space]]`
/// table sets.
public struct LayoutOverrides: Equatable, Sendable {
    public var arrange: Arrangement?
    public var columns: Int?
    public var rows: Int?
    public var feature: FeatureSide?
    public var featureSize: Double?
    public var featureCount: Int?
    public var floatPlacement: FloatPlacement?
    public var deckPeek: Double?
    public var split: Axis??
    public var weightShareMin: Double?
    public var weightShareMax: Double?
    public var gapsInner: Double?
    public var gapsOuter: Double?

    public init() {}

    public func applied(to base: LayoutSettings) -> LayoutSettings {
        var s = base
        if let arrange { s.arrange = arrange }
        if let columns { s.columns = columns }
        if let rows { s.rows = rows }
        if let feature { s.feature = feature }
        if let featureSize { s.featureSize = featureSize }
        if let featureCount { s.featureCount = featureCount }
        if let floatPlacement { s.floatPlacement = floatPlacement }
        if let deckPeek { s.deckPeek = deckPeek }
        if let split { s.split = split }
        if let weightShareMin { s.weightShareMin = weightShareMin }
        if let weightShareMax { s.weightShareMax = weightShareMax }
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
    /// The binding's key exactly as written in the file (e.g. `"hyper+r"`),
    /// for tools that need to edit the literal TOML key.
    public let hotkeyText: String
}

public struct Config: Equatable, Sendable {
    public var animation = AnimationSettings()
    public var focusFlash = FocusFlashSettings()
    public var focusFollowsMouse = false
    /// Warp the cursor to the focused window's center when focus crosses displays.
    public var cursorFollowsFocus = true
    /// What `[layout]` sets; built-in defaults fill the rest (see `layoutDefaults(small:)`).
    public var layout = LayoutOverrides()
    /// Per-desktop overrides, keyed by how the config file addresses the desktop.
    public var spaces: [SpaceAddress: LayoutOverrides] = [:]
    public var rules: [AppRule] = []
    public var bindings: [KeyBinding] = []

    public init() {}

    /// The `[[space]]` entry that applies to `key`: its Space UUID entry if
    /// there is one, else its display + ordinal entry.
    public func address(for key: SpaceKey) -> SpaceAddress? {
        key.addresses.first { spaces[$0] != nil }
    }

    /// Where to read and write `key`'s overrides: the entry that already
    /// applies, else the most stable address for a new one.
    public func writeAddress(for key: SpaceKey) -> SpaceAddress {
        address(for: key) ?? key.preferredAddress
    }

    public func overrides(for key: SpaceKey?) -> LayoutOverrides? {
        key.flatMap { address(for: $0) }.flatMap { spaces[$0] }
    }

    /// Settings for `key` on a display that is `small` or large: the built-in
    /// defaults, then `[layout]`, then the desktop's `[[space]]`.
    public func layoutSettings(for key: SpaceKey?, small: Bool) -> LayoutSettings {
        let base = layoutDefaults(small: small)
        return overrides(for: key)?.applied(to: base) ?? base
    }

    /// What a desktop without its own `[[space]]` uses: built-in defaults for
    /// the screen size under the keys `[layout]` sets.
    public func layoutDefaults(small: Bool) -> LayoutSettings {
        layout.applied(to: LayoutSettings.defaults(small: small))
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
            settings.allowOnly(["focus_follows_mouse", "cursor_follows_focus", "animation", "focus_flash"])
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
            if let flash = settings.table("focus_flash") {
                flash.allowOnly(["enabled", "duration_ms", "hold"])
                if let v = flash.bool("enabled") { config.focusFlash.enabled = v }
                if let ms = flash.number("duration_ms") {
                    if (100...5000).contains(ms) { config.focusFlash.duration = ms / 1000 }
                    else { flash.error("duration_ms", "must be between 100 and 5000") }
                }
                if let v: FocusFlashHold = flash.enumeration("hold") { config.focusFlash.hold = v }
            }
        }

        if let layout = top.table("layout") {
            let overrides = readLayout(layout, allowPlacement: false)
            config.layout = overrides
            validateClamp(overrides.applied(to: LayoutSettings()), overrides: overrides, reader: layout)
        }

        for (index, space) in top.tables("space").enumerated() {
            var address: SpaceAddress?
            if space.table["uuid"] != nil {
                let uuid = space.string("uuid")
                if space.table["display"] != nil || space.table["ordinal"] != nil {
                    space.error("uuid", "`uuid` already names the desktop; remove `display` and `ordinal`")
                } else if let uuid {
                    if UUID(uuidString: uuid) == nil {
                        space.error("uuid", "must be a Space UUID (see `ballast spaces`), got '\(uuid)'")
                    } else {
                        address = .uuid(uuid.uppercased())
                    }
                }
            } else {
                let display = space.string("display")
                let ordinal = space.int("ordinal")
                if space.table["display"] == nil {
                    space.error("display", "every [[space]] needs `uuid`, or `display` (UUID) and `ordinal`")
                }
                if space.table["ordinal"] == nil {
                    space.error("ordinal", "every [[space]] needs `uuid`, or `display` (UUID) and `ordinal`")
                }
                if let display {
                    if UUID(uuidString: display) == nil {
                        space.error("display", "must be a display UUID (see `ballast spaces`), got '\(display)'")
                    }
                }
                if let ordinal, ordinal < 1 { space.error("ordinal", "must be ≥ 1") }
                if let display, let ordinal {
                    address = .position(display: display.uppercased(), ordinal: ordinal)
                }
            }
            guard let address else {
                _ = readLayout(space, allowPlacement: true)
                continue
            }
            if config.spaces[address] != nil {
                space.error("", "duplicate [[space]] for \(address) (entry \(index + 1))")
            }
            let overrides = readLayout(space, allowPlacement: true)
            if overrides.weightShareMin != nil || overrides.weightShareMax != nil {
                validateClamp(overrides.applied(to: config.layout.applied(to: LayoutSettings())), overrides: overrides, reader: space)
            }
            config.spaces[address] = overrides
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
                    config.bindings.append(KeyBinding(hotkey: hotkey, command: command, commandText: text, hotkeyText: key))
                case .failure(let e):
                    bindings.error(key, e.message)
                }
            }
        }

        return diag.errors.isEmpty ? .success(config) : .failure(ConfigError(messages: diag.errors))
    }

    private static let layoutKeys: Set<String> = [
        "arrange", "columns", "rows", "feature", "feature_size", "feature_count", "deck_peek", "float_placement",
        "split", "weight_share_min", "weight_share_max", "gaps",
    ]

    private static func readLayout(_ r: Reader, allowPlacement: Bool) -> LayoutOverrides {
        r.allowOnly(allowPlacement ? layoutKeys.union(["display", "ordinal", "uuid"]) : layoutKeys)
        var o = LayoutOverrides()
        o.arrange = r.enumeration("arrange")
        o.feature = r.enumeration("feature")
        o.floatPlacement = r.enumeration("float_placement")
        if let v = r.int("columns") {
            if (1...8).contains(v) { o.columns = v } else { r.error("columns", "must be within 1…8") }
        }
        if let v = r.int("rows") {
            if (0...16).contains(v) { o.rows = v } else { r.error("rows", "must be within 0…16 (0 = no cap)") }
        }
        if let v = r.number("feature_size") {
            if v > 0.05 && v < 0.95 { o.featureSize = v }
            else { r.error("feature_size", "must be strictly between 0.05 and 0.95") }
        }
        if let v = r.int("feature_count") {
            if (1...16).contains(v) { o.featureCount = v } else { r.error("feature_count", "must be within 1…16") }
        }
        if let v = r.number("deck_peek") {
            if (0...200).contains(v) { o.deckPeek = v } else { r.error("deck_peek", "must be within 0…200") }
        }
        if let v = r.string("split") {
            switch v {
            case "auto": o.split = .some(nil)
            case "horizontal": o.split = .some(.horizontal)
            case "vertical": o.split = .some(.vertical)
            default: r.error("split", "expected auto|horizontal|vertical, got '\(v)'")
            }
        }
        for (key, apply) in [("weight_share_min", { (v: Double) in o.weightShareMin = v }),
                             ("weight_share_max", { (v: Double) in o.weightShareMax = v })] {
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

    /// Reports on the key the table actually set (min wins if both are), so the
    /// message never names a key the user didn't write.
    private static func validateClamp(_ s: LayoutSettings, overrides: LayoutOverrides, reader: Reader) {
        guard s.weightShareMin > s.weightShareMax else { return }
        if overrides.weightShareMin != nil {
            reader.error("weight_share_min", "must not exceed weight_share_max (\(s.weightShareMax))")
        } else {
            reader.error("weight_share_max", "must not be below weight_share_min (\(s.weightShareMin))")
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
                let beforeRect = pr.diag.errors.count
                let x = pr.fraction("x")
                let y = pr.fraction("y")
                let w = pr.fraction("w")
                let h = pr.fraction("h")
                if let x, let y, let w, let h {
                    if w > 0 && h > 0 && x + w <= 1 && y + h <= 1 {
                        actions.placement = .rect(x: x, y: y, w: w, h: h)
                    } else if w <= 0 || h <= 0 {
                        pr.error("", "w and h must be > 0")
                    } else {
                        pr.error("", "x + w and y + h must be ≤ 1 (rect must fit within the display)")
                    }
                } else if pr.diag.errors.count == beforeRect {
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
        let manageConflict = actions.manage == false
            && (actions.float != nil || actions.placement != nil || actions.weight != nil
                || actions.size != nil || actions.sticky != nil || actions.onSelfMove != nil)
        if manageConflict {
            r.error("manage", "a `manage = false` rule cannot also set weight/float/placement/size/sticky/on_self_move")
        }
        if !manageConflict && (actions.placement != nil || actions.size != nil) && actions.float != true {
            let key = actions.placement != nil ? "placement" : "size"
            r.error(key, "placement/size only apply to floating windows; add `float = true`")
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
            error(key, LegacyNames.keyMessage(key) ?? "unknown key")
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
