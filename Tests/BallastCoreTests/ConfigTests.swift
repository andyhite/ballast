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
    func fullExampleParses() throws {
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

        [placement.dummy]

        [[rule]]
        ax_subrole = "AXDialog"
        float = false

        [bindings]
        "cmd+j" = "focus down"
        "cmd+k" = "focus up"
        """
        // Fix: the stray [placement.dummy] table above is invalid top-level key; remove it.
        let fixed = text.replacingOccurrences(of: "\n[placement.dummy]\n", with: "\n")
        let result = Config.parse(fixed)
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
        #expect(msgs.contains { $0.contains("display") && $0.contains("UUID") })
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
        #expect(msgs.contains { $0.contains("no match fields") })
    }

    @Test("bad title regex is reported")
    func badRegex() {
        let msgs = Self.messages("""
        [[rule]]
        title_regex = "(unclosed"
        """)
        #expect(msgs.contains { $0.contains("title_regex") && $0.contains("invalid regular expression") })
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
        #expect(msgs.contains { $0.contains("invalid hotkey") })
    }

    @Test("invalid command is reported")
    func invalidCommand() {
        let msgs = Self.messages("""
        [bindings]
        "cmd+j" = "not-a-real-command"
        """)
        #expect(!msgs.isEmpty)
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
