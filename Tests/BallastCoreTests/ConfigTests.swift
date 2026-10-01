import Testing
@testable import BallastCore

@Suite("Config parsing and validation")
struct ConfigTests {

    static func messages(_ text: String) -> [String] {
        switch Config.parse(text) {
        case .success: return []
        case .failure(let error): return error.messages
        }
    }

    // MARK: - Full example

    @Test("parses a full example config successfully")
    func fullExampleParses() {
        let text = """
        [settings]
        focus_follows_mouse = true
        cursor_follows_focus = false

        [settings.animation]
        enabled = true
        duration_ms = 200
        easing = "ease_out_cubic"

        [layout]
        arrange = "fixed"
        feature = "left"
        feature_size = 0.6
        feature_count = 1
        columns = 1
        rows = 2
        split = "auto"
        weight_share_min = 0.25
        weight_share_max = 0.75

        [layout.gaps]
        inner = 8
        outer = 8

        [[space]]
        display = "11111111-1111-1111-1111-111111111111"
        ordinal = 1
        arrange = "dwindle"

        [[space]]
        display = "22222222-2222-2222-2222-222222222222"
        ordinal = 2
        feature_count = 2

        [[rule]]
        app_id = "com.ghostty.app"
        weight = 10

        [[rule]]
        app_id = "com.tinyspeck.slackmacgap"
        manage = false

        [[rule]]
        app_id = "com.apple.finder"
        title_substring = "Info"
        float = true

        [[rule]]
        ax_subrole = "AXDialog"
        float = false

        [bindings]
        "cmd+j" = "focus down"
        "cmd+k" = "focus up"
        """
        let result = Config.parse(text)
        switch result {
        case .success(let config):
            #expect(config.rules.count == 4)
            #expect(config.spaces.count == 2)
            #expect(config.bindings.count == 2)
            #expect(config.focusFollowsMouse == true)
            #expect(config.animation.duration == 0.2)
        case .failure(let error):
            Issue.record("expected success, got: \(error.messages)")
        }
    }

    // MARK: - Validation errors, one class each

    @Test("unknown key is reported with its path")
    func unknownKey() {
        let msgs = Self.messages("[settings]\nbogus = true")
        #expect(msgs.contains { $0.contains("settings.bogus") && $0.contains("unknown key") })
    }

    @Test("bad display UUID is reported")
    func badUUID() {
        let msgs = Self.messages("""
        [[space]]
        display = "not-a-uuid"
        ordinal = 1
        """)
        #expect(msgs.count == 1)
        #expect(msgs[0].hasPrefix("space[1].display:"))
    }

    @Test("duplicate space entry is reported")
    func duplicateSpace() {
        let msgs = Self.messages("""
        [[space]]
        display = "11111111-1111-1111-1111-111111111111"
        ordinal = 1

        [[space]]
        display = "11111111-1111-1111-1111-111111111111"
        ordinal = 1
        """)
        #expect(msgs.contains { $0.contains("duplicate") })
    }

    @Test("rule without match fields is reported")
    func ruleWithoutMatch() {
        let msgs = Self.messages("""
        [[rule]]
        weight = 2
        """)
        #expect(msgs.count == 1)
        #expect(msgs[0].hasPrefix("rule[1]:"))
    }

    @Test("bad title regex is reported")
    func badRegex() {
        let msgs = Self.messages("""
        [[rule]]
        title_regex = "(unclosed"
        """)
        #expect(msgs.count == 1)
        #expect(msgs[0].hasPrefix("rule[1].title_regex:"))
    }

    @Test("weight <= 0 is reported")
    func nonPositiveWeight() {
        let msgs = Self.messages("""
        [[rule]]
        app_id = "com.example.app"
        weight = 0
        """)
        #expect(msgs.contains { $0.contains("weight") })
    }

    @Test("placement without float is reported")
    func placementWithoutFloat() {
        let msgs = Self.messages("""
        [[rule]]
        app_id = "com.example.app"
        placement = "center"
        """)
        #expect(msgs.contains { $0.contains("placement") && $0.contains("float") })
    }

    @Test("invalid hotkey is reported")
    func invalidHotkey() {
        let msgs = Self.messages("""
        [bindings]
        "not-a-real-hotkey!!" = "focus left"
        """)
        #expect(msgs.count == 1)
        #expect(msgs[0].hasPrefix("bindings.not-a-real-hotkey!!:"))
    }

    @Test("invalid command is reported")
    func invalidCommand() {
        let msgs = Self.messages("""
        [bindings]
        "cmd+j" = "not-a-real-command"
        """)
        #expect(msgs.count == 1)
        #expect(msgs[0].hasPrefix("bindings.cmd+j:"))
    }

    @Test("duplicate hotkey is reported")
    func duplicateHotkey() {
        let msgs = Self.messages("""
        [bindings]
        "cmd+j" = "focus left"
        "cmd+shift+j" = "focus right"
        """)
        #expect(msgs.isEmpty) // sanity: distinct hotkeys are fine

        let dup = Self.messages("""
        [bindings]
        "cmd+j" = "focus left"
        "CMD+J" = "focus right"
        """)
        #expect(dup.contains { $0.contains("same hotkey") })
    }

    @Test("weight_share_min greater than weight_share_max is reported")
    func minRatioExceedsMaxRatio() {
        let msgs = Self.messages("""
        [layout]
        weight_share_min = 0.8
        weight_share_max = 0.2
        """)
        #expect(msgs.contains { $0.contains("weight_share_min") && $0.contains("weight_share_max") })
    }

    @Test("TOML syntax error is reported")
    func syntaxError() {
        let msgs = Self.messages("this is not = = valid toml [[[")
        #expect(msgs.contains { $0.contains("syntax") })
    }

    // MARK: - Per-space overrides

    @Test("partial gaps override resolves through layoutSettings with an uppercased key")
    func partialGapsOverrideResolves() {
        let lower = "33333333-3333-3333-3333-333333333333"
        let text = """
        [[space]]
        display = "\(lower)"
        ordinal = 1

        [space.gaps]
        inner = 12
        """
        guard case .success(let config) = Config.parse(text) else {
            Issue.record("expected parse success")
            return
        }
        let key = SpaceKey(display: lower.uppercased(), ordinal: 1)
        let resolved = config.layoutSettings(for: key, small: false)
        #expect(resolved.gaps.inner == 12)
        #expect(resolved.gaps.outer == 8)
    }

    @Test("a uuid-addressed [[space]] applies to the desktop with that Space UUID wherever it sits, and beats a positional entry")
    func uuidOverrideResolves() {
        let uuid = "06577405-6B31-4676-9725-A2F69D4232F4"
        let display = "640D0BA8-EB6C-4108-AA7B-E641F7C1826E"
        let text = """
        [[space]]
        uuid = "\(uuid.lowercased())"
        arrange = "dwindle"

        [[space]]
        display = "\(display)"
        ordinal = 2
        arrange = "float"
        """
        guard case .success(let config) = Config.parse(text) else {
            Issue.record("expected parse success")
            return
        }
        // Same desktop at ordinal 1 or 2: the uuid entry follows it.
        for ordinal in [1, 2] {
            let key = SpaceKey(display: display, ordinal: ordinal, uuid: uuid)
            #expect(config.layoutSettings(for: key, small: false).arrange == .dwindle)
        }
        // A different desktop at ordinal 2 falls back to the positional entry.
        let other = SpaceKey(display: display, ordinal: 2, uuid: "14D29016-BD95-4F5B-BC31-42DE47A40144")
        #expect(config.layoutSettings(for: other, small: false).arrange == .float)
        // A desktop with no uuid reported still resolves positionally.
        #expect(config.layoutSettings(for: SpaceKey(display: display, ordinal: 2), small: false).arrange == .float)
    }

    @Test("[[space]] must use uuid alone or display + ordinal, and uuid must be well-formed and unique")
    func uuidSpaceValidation() {
        let uuid = "06577405-6B31-4676-9725-A2F69D4232F4"
        let display = "640D0BA8-EB6C-4108-AA7B-E641F7C1826E"
        #expect(Self.messages("[[space]]\nuuid = \"\(uuid)\"\narrange = \"dwindle\"").isEmpty)
        #expect(!Self.messages("[[space]]\nuuid = \"\(uuid)\"\nordinal = 1\narrange = \"dwindle\"").isEmpty)
        #expect(!Self.messages("[[space]]\nuuid = \"\(uuid)\"\ndisplay = \"\(display)\"\narrange = \"dwindle\"").isEmpty)
        #expect(!Self.messages("[[space]]\nuuid = \"not-a-uuid\"\narrange = \"dwindle\"").isEmpty)
        #expect(!Self.messages("[[space]]\nuuid = \"\(uuid)\"\n\n[[space]]\nuuid = \"\(uuid.lowercased())\"").isEmpty)
        #expect(!Self.messages("[[space]]\narrange = \"dwindle\"").isEmpty)
    }

    // MARK: - Boundary accept/reject pairs

    @Test("rule weight accepts values within (0, 1000]")
    func weightBoundaries() {
        let ok = Self.messages("[[rule]]\napp_id = \"a\"\nweight = 1000")
        #expect(ok.isEmpty)
        let bad = Self.messages("[[rule]]\napp_id = \"a\"\nweight = 1000.5")
        #expect(bad.contains { $0.contains("weight") })
    }

    @Test("animation duration_ms accepts values within 0...2000")
    func durationBoundaries() {
        let ok = Self.messages("[settings.animation]\nduration_ms = 2000")
        #expect(ok.isEmpty)
        let bad = Self.messages("[settings.animation]\nduration_ms = 2001")
        #expect(bad.contains { $0.contains("duration_ms") })
    }

    @Test("focus_flash parses its keys and bounds duration_ms to 100...5000")
    func focusFlash() {
        switch Config.parse("[settings.focus_flash]\nenabled = false\nduration_ms = 1500\nhold = \"ctrl\"") {
        case .success(let config):
            #expect(config.focusFlash.enabled == false)
            #expect(config.focusFlash.duration == 1.5)
            #expect(config.focusFlash.hold == .ctrl)
        case .failure(let error):
            Issue.record("expected success, got: \(error.messages)")
        }
        #expect(Self.messages("[settings.focus_flash]\nduration_ms = 100").isEmpty)
        #expect(Self.messages("[settings.focus_flash]\nduration_ms = 5000").isEmpty)
        #expect(Self.messages("[settings.focus_flash]\nduration_ms = 99").contains { $0.contains("duration_ms") })
        #expect(Self.messages("[settings.focus_flash]\nduration_ms = 5001").contains { $0.contains("duration_ms") })
        #expect(Self.messages("[settings.focus_flash]\nhold = \"shift\"").contains { $0.contains("hold") })
    }

    @Test("gaps accept values within 0...200")
    func gapsBoundaries() {
        let ok = Self.messages("[layout.gaps]\ninner = 200")
        #expect(ok.isEmpty)
        let bad = Self.messages("[layout.gaps]\ninner = 201")
        #expect(bad.contains { $0.contains("inner") })
    }

    @Test("feature_size accepts values strictly inside (0.05, 0.95), in [layout] and [[space]]")
    func featureSizeBoundaries() {
        #expect(!Self.messages("[layout]\nfeature_size = 0.05").isEmpty)
        #expect(Self.messages("[layout]\nfeature_size = 0.06").isEmpty)
        #expect(Self.messages("[layout]\nfeature_size = 0.94").isEmpty)
        #expect(!Self.messages("[layout]\nfeature_size = 0.95").isEmpty)
        #expect(Self.messages(Self.space("feature_size = 0.95")).contains { $0.hasPrefix("space[1].feature_size:") })
    }

    /// One positional [[space]] table holding `body`.
    static func space(_ body: String) -> String {
        "[[space]]\ndisplay = \"11111111-1111-1111-1111-111111111111\"\nordinal = 1\n" + body
    }

    @Test("integer keys accept their documented range, with path-qualified errors, in [layout] and [[space]]")
    func integerKeyRanges() {
        let ranges: [(key: String, lo: Int, hi: Int)] = [
            ("columns", 1, 8), ("rows", 0, 16), ("feature_count", 1, 16), ("deck_peek", 0, 200),
        ]
        for (key, lo, hi) in ranges {
            #expect(Self.messages("[layout]\n\(key) = \(lo)").isEmpty, "\(key) = \(lo)")
            #expect(Self.messages("[layout]\n\(key) = \(hi)").isEmpty, "\(key) = \(hi)")
            #expect(Self.messages(Self.space("\(key) = \(hi)")).isEmpty, "space \(key) = \(hi)")
            #expect(Self.messages("[layout]\n\(key) = \(lo - 1)").contains { $0.hasPrefix("layout.\(key):") }, "\(key) = \(lo - 1)")
            #expect(Self.messages("[layout]\n\(key) = \(hi + 1)").contains { $0.hasPrefix("layout.\(key):") }, "\(key) = \(hi + 1)")
            #expect(Self.messages(Self.space("\(key) = \(hi + 1)")).contains { $0.hasPrefix("space[1].\(key):") })
        }
        #expect(Self.messages("[layout]\ncolumns = 9") == ["layout.columns: must be within 1…8"])
    }

    @Test("enum keys accept every case and report unknown values with the path")
    func enumKeys() {
        for arrange in ["fixed", "adaptive", "dwindle", "balanced", "float"] {
            #expect(Self.messages("[layout]\narrange = \"\(arrange)\"").isEmpty, "\(arrange)")
        }
        for feature in ["none", "left", "right", "top", "bottom", "center"] {
            #expect(Self.messages("[layout]\nfeature = \"\(feature)\"").isEmpty, "\(feature)")
        }
        for split in ["auto", "horizontal", "vertical"] {
            #expect(Self.messages("[layout]\nsplit = \"\(split)\"").isEmpty, "\(split)")
        }
        #expect(Self.messages("[layout]\narrange = \"grid\"").contains { $0.hasPrefix("layout.arrange:") && $0.contains("unknown value 'grid'") })
        #expect(Self.messages("[layout]\nfeature = \"off\"").contains { $0.hasPrefix("layout.feature:") && $0.contains("unknown value 'off'") })
        #expect(Self.messages(Self.space("arrange = \"x\"")).contains { $0.hasPrefix("space[1].arrange:") && $0.contains("unknown value 'x'") })
        #expect(Self.messages(Self.space("feature = \"x\"")).contains { $0.hasPrefix("space[1].feature:") && $0.contains("unknown value 'x'") })
        #expect(Self.messages("[layout]\nbogus_key = 1").contains { $0.hasPrefix("layout.bogus_key:") && $0.contains("unknown key") })
        #expect(Self.messages(Self.space("bogus_key = 1")).contains { $0.hasPrefix("space[1].bogus_key:") && $0.contains("unknown key") })
    }

    @Test("every renamed or removed key fails in [layout] and [[space]] with its replacement")
    func legacyKeysAreErrors() {
        let cases: [(key: String, value: String, message: String)] = [
            ("master_ratio", "0.5", "renamed to feature_size"),
            ("master_count", "2", "renamed to feature_count"),
            ("grid_columns", "2", "renamed to columns"),
            ("grid_max", "2", "renamed to rows"),
            ("stack_peek", "12", "renamed to deck_peek"),
            ("bsp_min_ratio", "0.25", "renamed to weight_share_min"),
            ("bsp_max_ratio", "0.75", "renamed to weight_share_max"),
            ("stack_side", "\"left\"", "removed; use feature (the opposite side)"),
            ("stack_both_sides", "true", "removed; use feature = \"center\""),
            ("bsp_shape", "\"dwindle\"", "removed; use arrange = \"dwindle\" | \"balanced\""),
            ("mode", "\"bsp\"", "removed; use arrange and feature"),
        ]
        for (key, value, message) in cases {
            #expect(Self.messages("[layout]\n\(key) = \(value)") == ["layout.\(key): \(message)"], "[layout] \(key)")
            #expect(Self.messages(Self.space("\(key) = \(value)")) == ["space[1].\(key): \(message)"], "[[space]] \(key)")
        }
    }

    @Test("renamed and removed commands fail in bindings naming the replacement")
    func legacyBindingCommand() {
        #expect(Self.messages("[bindings]\n\"hyper+m\" = \"focus-master\"").contains { $0.contains("(renamed to 'focus-feature')") })
    }

    @Test("new commands parse to their cases")
    func commandVerbs() {
        #expect(Command.parse("deck left") == .success(.deck(.left)))
        #expect(Command.parse("deck down") == .success(.deck(.down)))
        #expect(Command.parse("undeck") == .success(.undeck))
        #expect(Command.parse("feature-size +0.1") == .success(.featureSize(0.1)))
        #expect(Command.parse("feature-size -0.05") == .success(.featureSize(-0.05)))
        #expect(Command.parse("feature-count 1") == .success(.featureCount(1)))
        #expect(Command.parse("feature-count -1") == .success(.featureCount(-1)))
        #expect(Command.parse("focus-feature") == .success(.focusFeature))
        #expect(Command.parse("focus feature") == .success(.focusFeature))
        #expect(Command.parse("focus left") == .success(.focus(.left)))
        #expect(Command.parse("deck") != .success(.deck(.left)))
        #expect(Command.parse("feature-count 1.5") != .success(.featureCount(1)))
        #expect(Command.parse("feature-size") != .success(.featureSize(0)))
    }

    @Test("every legacy command fails naming its replacement")
    func legacyCommands() {
        func error(_ text: String) -> String? {
            if case .failure(let e) = Command.parse(text) { return e.description }
            return nil
        }
        let renamed: [(old: String, name: String, new: String)] = [
            ("master-ratio +0.1", "master-ratio", "feature-size"),
            ("master-count 1", "master-count", "feature-count"),
            ("focus-master", "focus-master", "focus-feature"),
            ("focus master", "focus master", "focus feature"),
        ]
        for (old, name, new) in renamed {
            #expect(error(old)?.contains("unknown command '\(name)' (renamed to '\(new)')") == true, "\(old): \(error(old) ?? "parsed")")
        }
        for text in ["layout main_tile", "layout grid", "layout"] {
            #expect(error(text)?.contains("unknown command 'layout' (removed; set arrange in the menu, Settings, or config)") == true, "\(text)")
        }
    }

    @Test("glyph and summary describe the arrangement and feature")
    func glyphAndSummary() {
        func settings(_ arrange: Arrangement, feature: FeatureSide = .off, columns: Int = 1, rows: Int = 1) -> LayoutSettings {
            var s = LayoutSettings()
            s.arrange = arrange; s.feature = feature; s.columns = columns; s.rows = rows
            return s
        }
        let table: [(LayoutSettings, glyph: String, summary: String)] = [
            (LayoutSettings(), "1×1", "Fixed grid 1×1"),
            (settings(.fixed, feature: .left, rows: 2), "F·1×2", "Fixed grid 1×2 with left feature"),
            (settings(.fixed, columns: 2, rows: 3), "2×3", "Fixed grid 2×3"),
            (settings(.fixed, columns: 1, rows: 0), "1×∞", "Fixed grid 1×∞"),
            (settings(.fixed, feature: .center, rows: 0), "F·1×∞", "Fixed grid 1×∞ with centered feature"),
            (settings(.adaptive), "A", "Adaptive grid"),
            (settings(.adaptive, feature: .right), "F·A", "Adaptive grid with right feature"),
            (settings(.dwindle), "D", "BSP dwindle"),
            (settings(.dwindle, feature: .top), "F·D", "BSP dwindle with top feature"),
            (settings(.balanced), "B", "BSP balanced"),
            (settings(.balanced, feature: .bottom), "F·B", "BSP balanced with bottom feature"),
            (settings(.float, feature: .left), "⋯", "Float"),
        ]
        for (s, glyph, summary) in table {
            #expect(s.glyph == glyph, "\(summary)")
            #expect(s.summary == summary)
        }
        // BSP has no halves: a centered feature reads as left.
        let bsp = settings(.dwindle, feature: .center)
        #expect(bsp.glyph == "F·D" && bsp.summary == "BSP dwindle with left feature")
    }

    @Test("built-in defaults depend on the screen size")
    func screenSizeDefaults() {
        let small = LayoutSettings.defaults(small: true)
        #expect(small == LayoutSettings())
        #expect(small.arrange == .fixed && small.columns == 1 && small.rows == 1 && small.feature == .off)
        let large = LayoutSettings.defaults(small: false)
        #expect(large.arrange == .fixed && large.columns == 1 && large.rows == 2)
        #expect(large.feature == .left && large.featureSize == 0.6 && large.featureCount == 1)
        #expect(small.glyph == "1×1" && large.glyph == "F·1×2")
        guard case .success(let empty) = Config.parse("") else { Issue.record("empty config must parse"); return }
        #expect(empty.layoutSettings(for: nil, small: true) == small)
        #expect(empty.layoutSettings(for: nil, small: false) == large)
    }

    @Test("a [layout] key beats the built-in default on both screen sizes and leaves the rest at the size default")
    func layoutBeatsDefaults() {
        guard case .success(let config) = Config.parse("[layout]\nrows = 3\nfeature = \"right\"\nfeature_size = 0.4") else {
            Issue.record("expected parse success")
            return
        }
        for small in [true, false] {
            let s = config.layoutSettings(for: nil, small: small)
            #expect(s.rows == 3 && s.feature == .right && s.featureSize == 0.4, "small=\(small)")
            #expect(s.columns == 1 && s.featureCount == 1 && s.arrange == .fixed, "small=\(small)")
            #expect(s == config.layoutDefaults(small: small))
        }
        // Only `arrange` set: feature and rows still come from the screen size.
        guard case .success(let only) = Config.parse("[layout]\narrange = \"dwindle\"") else {
            Issue.record("expected parse success")
            return
        }
        #expect(only.layoutSettings(for: nil, small: true).feature == .off)
        #expect(only.layoutSettings(for: nil, small: false).feature == .left)
        #expect(only.layoutSettings(for: nil, small: false).rows == 2)
        #expect(only.layoutSettings(for: nil, small: true).rows == 1)
        // An explicit feature = "none" beats the large-screen default.
        guard case .success(let none) = Config.parse("[layout]\nfeature = \"none\"") else {
            Issue.record("expected parse success")
            return
        }
        #expect(none.layoutSettings(for: nil, small: false).feature == .off)
    }

    @Test("[[space]] beats [layout] beats the built-in default, key by key")
    func spacePrecedence() {
        let display = "44444444-4444-4444-4444-444444444444"
        let text = """
        [layout]
        columns = 3
        rows = 4
        deck_peek = 10

        [[space]]
        display = "\(display)"
        ordinal = 1
        rows = 0
        arrange = "adaptive"
        feature_count = 2
        """
        guard case .success(let config) = Config.parse(text) else {
            Issue.record("expected parse success")
            return
        }
        let key = SpaceKey(display: display, ordinal: 1)
        for small in [true, false] {
            let s = config.layoutSettings(for: key, small: small)
            #expect(s.rows == 0 && s.arrange == .adaptive && s.featureCount == 2, "small=\(small)")
            #expect(s.columns == 3 && s.deckPeek == 10, "small=\(small)")
            // A desktop the file doesn't mention gets [layout] only.
            let other = config.layoutSettings(for: SpaceKey(display: display, ordinal: 2), small: small)
            #expect(other.rows == 4 && other.arrange == .fixed && other.featureCount == 1 && other.columns == 3)
        }
        #expect(config.layoutSettings(for: key, small: true).feature == .off)
        #expect(config.layoutSettings(for: key, small: false).feature == .left)
    }

    @Test("a BSP desktop reads a centered feature as left")
    func bspCenteredFeature() {
        guard case .success(let config) = Config.parse("[layout]\narrange = \"balanced\"\nfeature = \"center\"") else {
            Issue.record("expected parse success")
            return
        }
        let s = config.layoutSettings(for: nil, small: false)
        #expect(s.feature == .center && s.effectiveFeature == .left && s.hasFeature)
    }


    @Test("placement/size fractions accept values within 0...1")
    func fractionBoundaries() {
        let ok = Self.messages("""
        [[rule]]
        app_id = "a"
        float = true
        [rule.size]
        w = 1
        h = 1
        """)
        #expect(ok.isEmpty)
        let bad = Self.messages("""
        [[rule]]
        app_id = "a"
        float = true
        [rule.size]
        w = 1.01
        h = 1
        """)
        #expect(bad.contains { $0.contains("size") })
    }

    @Test("placement rect extending past the display is rejected")
    func placementRectOutOfBounds() {
        let msgs = Self.messages("""
        [[rule]]
        app_id = "a"
        float = true
        [rule.placement]
        x = 0.8
        y = 0
        w = 0.5
        h = 0.3
        """)
        #expect(msgs.contains { $0.hasPrefix("rule[1].placement:") })
    }

    // MARK: - manage = false conflicts

    @Test("manage = false with size is reported at manage, not placement")
    func manageFalseWithSize() {
        let msgs = Self.messages("""
        [[rule]]
        app_id = "a"
        manage = false
        [rule.size]
        w = 0.5
        h = 0.5
        """)
        #expect(msgs.count == 1)
        #expect(msgs[0].hasPrefix("rule[1].manage:"))
    }

    // MARK: - Multiple errors in one pass

    @Test("multiple independent errors are all reported in one pass")
    func multipleErrorsInOnePass() {
        let msgs = Self.messages("""
        [[space]]
        ordinal = 1
        arrange = "bogus"

        [[rule]]
        weight = -1
        """)
        #expect(msgs.contains { $0.hasPrefix("space[1].display:") })
        #expect(msgs.contains { $0.hasPrefix("space[1].arrange:") })
        #expect(msgs.contains { $0.hasPrefix("rule[1].weight:") })
        #expect(msgs.contains { $0.hasPrefix("rule[1]:") })
    }


    // MARK: - Rule specificity

    @Test("most specific rule wins")
    func mostSpecificRuleWins() {
        let text = """
        [[rule]]
        app_id = "com.example.app"
        weight = 2

        [[rule]]
        app_id = "com.example.app"
        title_substring = "Special"
        weight = 5
        """
        guard case .success(let config) = Config.parse(text) else {
            Issue.record("expected parse success")
            return
        }
        let facts = WindowFacts(bundleID: "com.example.app", title: "Special Window")
        let resolved = RuleResolver.resolve(facts, rules: config.rules)
        #expect(resolved.weight == 5)
        #expect(resolved.ruleIndex == 1)
    }

    @Test("ties in specificity go to the earlier rule")
    func tiesGoToEarlierRule() {
        let text = """
        [[rule]]
        app_id = "com.example.app"
        weight = 2

        [[rule]]
        app_id = "com.example.app"
        weight = 9
        """
        guard case .success(let config) = Config.parse(text) else {
            Issue.record("expected parse success")
            return
        }
        let facts = WindowFacts(bundleID: "com.example.app")
        let resolved = RuleResolver.resolve(facts, rules: config.rules)
        #expect(resolved.weight == 2)
        #expect(resolved.ruleIndex == 0)
    }

    @Test("a clamp violation names the key the table set, with per-key wording")
    func clampNamesTheSetKey() {
        let uuid = "06577405-6B31-4676-9725-A2F69D4232F4"
        let layoutMin = Self.messages("[layout]\nweight_share_min = 0.95\n")
        #expect(layoutMin.count == 1 && layoutMin[0].hasPrefix("layout.weight_share_min: must not exceed weight_share_max ("))
        let layoutMax = Self.messages("[layout]\nweight_share_max = 0.01\n")
        #expect(layoutMax.count == 1 && layoutMax[0].hasPrefix("layout.weight_share_max: must not be below weight_share_min ("))
        let spaceMin = Self.messages("[[space]]\nuuid = \"\(uuid)\"\nweight_share_min = 0.95\n")
        #expect(spaceMin.count == 1 && spaceMin[0].hasPrefix("space[1].weight_share_min: must not exceed weight_share_max ("))
        let spaceMax = Self.messages("[[space]]\nuuid = \"\(uuid)\"\nweight_share_max = 0.01\n")
        #expect(spaceMax.count == 1 && spaceMax[0].hasPrefix("space[1].weight_share_max: must not be below weight_share_min ("))
    }

    @Test("feature_size nan and inf are rejected")
    func featureSizeNonFinite() {
        for v in ["nan", "inf", "-inf"] {
            #expect(Self.messages("[layout]\nfeature_size = \(v)\n").count == 1, "\(v)")
        }
    }

    @Test("weight_share bounds 0 and 1 are rejected")
    func weightShareBounds() {
        for key in ["weight_share_min", "weight_share_max"] {
            for v in ["0", "1"] {
                #expect(Self.messages("[layout]\n\(key) = \(v)\n") == ["layout.\(key): must be within (0, 1)"], "\(key) = \(v)")
            }
        }
    }

    @Test("a [[space]] ordinal of 0 is rejected")
    func ordinalZero() {
        let msgs = Self.messages("[[space]]\ndisplay = \"6D147BFB-7E3C-4CCD-9825-F1A5A059052D\"\nordinal = 0\n")
        #expect(msgs == ["space[1].ordinal: must be ≥ 1"])
    }

}
