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
        mode = "master_stack"
        master_ratio = 0.6
        master_count = 1
        stack_side = "right"
        split = "auto"
        bsp_min_ratio = 0.25
        bsp_max_ratio = 0.75

        [layout.gaps]
        inner = 8
        outer = 8

        [[space]]
        display = "11111111-1111-1111-1111-111111111111"
        ordinal = 1
        mode = "bsp"

        [[space]]
        display = "22222222-2222-2222-2222-222222222222"
        ordinal = 2
        master_count = 2

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

    @Test("bsp_min_ratio greater than bsp_max_ratio is reported")
    func minRatioExceedsMaxRatio() {
        let msgs = Self.messages("""
        [layout]
        bsp_min_ratio = 0.8
        bsp_max_ratio = 0.2
        """)
        #expect(msgs.contains { $0.contains("bsp_min_ratio") && $0.contains("bsp_max_ratio") })
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
        let resolved = config.layoutSettings(for: key)
        #expect(resolved.gaps.inner == 12)
        #expect(resolved.gaps.outer == 8)
    }

    // MARK: - Boundary accept/reject pairs

    @Test("master_ratio accepts values strictly inside (0.05, 0.95)")
    func masterRatioBoundaries() {
        #expect(!Self.messages("[layout]\nmaster_ratio = 0.05").isEmpty)
        #expect(Self.messages("[layout]\nmaster_ratio = 0.06").isEmpty)
        #expect(Self.messages("[layout]\nmaster_ratio = 0.94").isEmpty)
        #expect(!Self.messages("[layout]\nmaster_ratio = 0.95").isEmpty)
    }

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

    @Test("gaps accept values within 0...200")
    func gapsBoundaries() {
        let ok = Self.messages("[layout.gaps]\ninner = 200")
        #expect(ok.isEmpty)
        let bad = Self.messages("[layout.gaps]\ninner = 201")
        #expect(bad.contains { $0.contains("inner") })
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
        mode = "bogus"

        [[rule]]
        weight = -1
        """)
        #expect(msgs.contains { $0.hasPrefix("space[1].display:") })
        #expect(msgs.contains { $0.hasPrefix("space[1].mode:") })
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
}
