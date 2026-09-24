import Foundation
import Testing
@testable import BallastCore

@Suite("ConfigEditor")
struct ConfigEditorTests {

    static let example = try! String(contentsOf: URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("docs/config.example.toml"), encoding: .utf8)

    func expectSuccess<T>(_ result: Result<T, ConfigEditError>, sourceLocation: SourceLocation = #_sourceLocation) {
        if case .failure(let e) = result { Issue.record("expected success, got \(e)", sourceLocation: sourceLocation) }
    }

    // MARK: - Round trip

    @Test("no-op set of an existing value leaves the example config byte-identical")
    func noOpRoundTrip() {
        var editor = ConfigEditor(text: Self.example)
        let result = editor.set("master_ratio", .float(0.6), in: .layout)
        expectSuccess(result)
        #expect(editor.text == Self.example)
    }

    @Test("example config parses cleanly through the editor unmodified")
    func exampleValidates() {
        let editor = ConfigEditor(text: Self.example)
        switch editor.validated() {
        case .success: break
        case .failure(let e): Issue.record("expected success, got \(e)")
        }
    }

    // MARK: - Replace

    @Test("replace keeps the trailing comment and its column")
    func replaceKeepsComment() {
        let text = """
        [layout]
        master_ratio = 0.6                 # share of master
        """
        var editor = ConfigEditor(text: text)
        expectSuccess(editor.set("master_ratio", .float(0.7), in: .layout))
        #expect(editor.text.contains("master_ratio = 0.7                 # share of master"))
    }

    @Test("replace without a fitting comment column falls back to one space")
    func replaceCommentTooNarrow() {
        let text = """
        [layout]
        master_ratio = 0.6 # r
        """
        var editor = ConfigEditor(text: text)
        expectSuccess(editor.set("master_ratio", .float(0.85), in: .layout))
        #expect(editor.text == "[layout]\nmaster_ratio = 0.85 # r\n")
    }

    @Test("replace on an existing key does not disturb sibling keys")
    func replacePreservesSiblings() {
        let text = """
        [layout]
        mode = "bsp"
        master_ratio = 0.6
        master_count = 1
        """
        var editor = ConfigEditor(text: text)
        expectSuccess(editor.set("master_count", .integer(3), in: .layout))
        #expect(editor.text == "[layout]\nmode = \"bsp\"\nmaster_ratio = 0.6\nmaster_count = 3\n")
    }

    @Test("replace collapses a multi-line array value to one line")
    func replaceMultiLineValue() {
        let text = """
        [layout]
        mode = "bsp"
        # trailing marker
        """
        // Simulate a multi-line inline table under a custom section by using .settings/.animation not
        // applicable; instead verify direct multi-line scan via a synthetic bindings-like key using layout gaps.
        var editor = ConfigEditor(text: """
        [layout]
        gaps = {
            inner = 8,
            outer = 8
        }
        mode = "bsp"
        """)
        expectSuccess(editor.set("gaps", .inlineTable([ConfigField("inner", .integer(4)), ConfigField("outer", .integer(4))]), in: .layout))
        #expect(editor.text == "[layout]\ngaps = { inner = 4, outer = 4 }\nmode = \"bsp\"\n")
        _ = text
    }

    // MARK: - Insert

    @Test("set inserts a missing key after the section's last key")
    func insertIntoExistingSection() {
        let text = """
        [layout]
        mode = "bsp"
        master_count = 1
        """
        var editor = ConfigEditor(text: text)
        expectSuccess(editor.set("master_ratio", .float(0.55), in: .layout))
        #expect(editor.text == "[layout]\nmode = \"bsp\"\nmaster_count = 1\nmaster_ratio = 0.55\n")
    }

    @Test("set creates a missing [settings] section before [layout]")
    func createsSettingsSection() {
        let text = """
        [layout]
        mode = "bsp"
        """
        var editor = ConfigEditor(text: text)
        expectSuccess(editor.set("focus_follows_mouse", .bool(true), in: .settings))
        #expect(editor.text.hasPrefix("[settings]\nfocus_follows_mouse = true\n\n[layout]\n"))
    }

    @Test("set creates a missing [settings.animation] section")
    func createsAnimationSection() {
        let text = """
        [settings]
        focus_follows_mouse = false

        [layout]
        mode = "bsp"
        """
        var editor = ConfigEditor(text: text)
        expectSuccess(editor.set("duration_ms", .integer(250), in: .animation))
        #expect(editor.text.contains("[settings.animation]\nduration_ms = 250"))
        switch editor.validated() {
        case .success(let config): #expect(config.animation.duration == 0.25)
        case .failure(let e): Issue.record("expected success, got \(e)")
        }
    }

    @Test("set creates [settings.focus_flash] after the last [settings.*] table")
    func createsFocusFlashSection() {
        let text = """
        [settings]
        focus_follows_mouse = false

        [settings.animation]
        enabled = true

        [layout]
        mode = "bsp"
        """
        var editor = ConfigEditor(text: text)
        expectSuccess(editor.set("hold", .string("none"), in: .focusFlash))
        #expect(editor.text.contains("[settings.animation]\nenabled = true\n\n[settings.focus_flash]\nhold = \"none\"\n\n[layout]"))
        switch editor.validated() {
        case .success(let config): #expect(config.focusFlash.hold == FocusFlashHold.none)
        case .failure(let e): Issue.record("expected success, got \(e)")
        }
    }

    // MARK: - Remove

    @Test("set with nil value removes the key line")
    func removeKey() {
        let text = """
        [layout]
        mode = "bsp"
        master_count = 2
        """
        var editor = ConfigEditor(text: text)
        expectSuccess(editor.set("master_count", nil, in: .layout))
        #expect(editor.text == "[layout]\nmode = \"bsp\"\n")
    }

    @Test("removing an absent key is a no-op")
    func removeAbsentKey() {
        let text = "[layout]\nmode = \"bsp\"\n"
        var editor = ConfigEditor(text: text)
        expectSuccess(editor.set("master_count", nil, in: .layout))
        #expect(editor.text == text)
    }

    @Test("removing a key removes an orphaned aligned comment-continuation line")
    func removeKeyRemovesAlignedContinuation() {
        let text = "[layout]\nmode = \"bsp\"          # first\n"
            + String(repeating: " ", count: 22) + "# second\nmaster_count = 1\n"
        var editor = ConfigEditor(text: text)
        expectSuccess(editor.set("mode", nil, in: .layout))
        #expect(editor.text == "[layout]\nmaster_count = 1\n")
    }

    // MARK: - Read value

    @Test("value reads back an existing scalar")
    func valueReadsScalar() {
        let editor = ConfigEditor(text: "[layout]\nmaster_ratio = 0.6\n")
        #expect(editor.value("master_ratio", in: .layout) == .float(0.6))
    }

    @Test("value returns nil for a missing key")
    func valueMissingKey() {
        let editor = ConfigEditor(text: "[layout]\nmode = \"bsp\"\n")
        #expect(editor.value("master_ratio", in: .layout) == nil)
    }

    // MARK: - Spaces

    @Test("set on a missing space creates its [[space]] block after the last one")
    func createsSpaceBlock() {
        var editor = ConfigEditor(text: Self.example)
        let key = SpaceKey(display: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA", ordinal: 5)
        expectSuccess(editor.set("mode", .string("float"), in: .space(key)))
        switch editor.validated() {
        case .success(let config):
            #expect(config.spaces[key]?.mode == .float)
        case .failure(let e):
            Issue.record("expected success, got \(e)")
        }
    }

    @Test("removeSpace deletes the whole block and space reverts to layout defaults")
    func removeSpaceBlock() {
        var editor = ConfigEditor(text: Self.example)
        let key = SpaceKey(display: "640D0BA8-EB6C-4108-AA7B-E641F7C1826E", ordinal: 1)
        expectSuccess(editor.removeSpace(key))
        switch editor.validated() {
        case .success(let config):
            #expect(config.spaces[key] == nil)
        case .failure(let e):
            Issue.record("expected success, got \(e)")
        }
    }

    @Test("removeSpace on an absent space is a no-op")
    func removeAbsentSpace() {
        var editor = ConfigEditor(text: Self.example)
        let key = SpaceKey(display: "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF", ordinal: 9)
        expectSuccess(editor.removeSpace(key))
        #expect(editor.text == Self.example)
    }

    // MARK: - Bindings

    @Test("set on bindings quotes the hotkey key")
    func bindingsQuotesKey() {
        let text = "[bindings]\n\"alt+h\" = \"focus left\"\n"
        var editor = ConfigEditor(text: text)
        expectSuccess(editor.set("alt+j", .string("focus down"), in: .bindings))
        #expect(editor.text == "[bindings]\n\"alt+h\" = \"focus left\"\n\"alt+j\" = \"focus down\"\n")
    }

    @Test("set creates a missing [bindings] section")
    func createsBindingsSection() {
        let text = "[layout]\nmode = \"bsp\"\n"
        var editor = ConfigEditor(text: text)
        expectSuccess(editor.set("alt+h", .string("focus left"), in: .bindings))
        #expect(editor.text == "[layout]\nmode = \"bsp\"\n\n[bindings]\n\"alt+h\" = \"focus left\"\n")
    }

    // MARK: - Rules

    @Test("appendRule adds after the last rule and appears in Config.parse order")
    func appendRuleOrder() {
        var editor = ConfigEditor(text: Self.example)
        let index = editor.appendRule([ConfigField("app_id", .string("com.example.new")), ConfigField("weight", .float(2))])
        guard case .success(let newIndex) = index else { Issue.record("expected success"); return }
        switch editor.validated() {
        case .success(let config):
            #expect(newIndex == config.rules.count - 1)
            #expect(config.rules.last?.match.appID == "com.example.new")
        case .failure(let e):
            Issue.record("expected success, got \(e)")
        }
    }

    @Test("appendRule on a document with no rules inserts before [bindings]")
    func appendRuleNoExistingRules() {
        let text = """
        [layout]
        mode = "bsp"

        [bindings]
        "alt+h" = "focus left"
        """
        var editor = ConfigEditor(text: text)
        let result = editor.appendRule([ConfigField("app_id", .string("com.example.app"))])
        guard case .success(0) = result else { Issue.record("expected index 0"); return }
        switch editor.validated() {
        case .success(let config):
            #expect(config.rules.count == 1)
            #expect(config.rules.first?.match.appID == "com.example.app")
        case .failure(let e):
            Issue.record("expected success, got \(e)")
        }
    }

    @Test("removeRule removes the target block and preserves order of the rest")
    func removeRulePreservesOrder() {
        var editor = ConfigEditor(text: Self.example)
        let before: [String?]
        switch Config.parse(Self.example) {
        case .success(let c): before = c.rules.map { $0.match.appID }
        case .failure: before = []
        }
        expectSuccess(editor.removeRule(at: 1))
        switch editor.validated() {
        case .success(let config):
            let after = config.rules.map { $0.match.appID }
            var expected = before
            expected.remove(at: 1)
            #expect(after == expected)
        case .failure(let e):
            Issue.record("expected success, got \(e)")
        }
    }

    @Test("removeRule with an out-of-range index fails clearly")
    func removeRuleOutOfRange() {
        var editor = ConfigEditor(text: Self.example)
        switch editor.removeRule(at: 999) {
        case .success: Issue.record("expected failure")
        case .failure: break
        }
    }

    @Test("moveRule reorders rules and every rule still parses")
    func moveRulePreservesContent() {
        var editor = ConfigEditor(text: Self.example)
        let before: [String?]
        switch Config.parse(Self.example) {
        case .success(let c): before = c.rules.map { $0.match.appID ?? $0.match.appName }
        case .failure: before = []
        }
        expectSuccess(editor.moveRule(from: 0, to: before.count - 1))
        switch editor.validated() {
        case .success(let config):
            var expected = before
            let moved = expected.remove(at: 0)
            expected.append(moved)
            let after = config.rules.map { $0.match.appID ?? $0.match.appName }
            #expect(after == expected)
            #expect(config.rules.count == before.count)
        case .failure(let e):
            Issue.record("expected success, got \(e)")
        }
    }

    // MARK: - Float formatting

    @Test("float formatting avoids trailing binary noise")
    func floatFormatting() {
        var editor = ConfigEditor(text: "[layout]\nmaster_ratio = 0.6\n")
        expectSuccess(editor.set("master_ratio", .float(0.65), in: .layout))
        #expect(editor.text == "[layout]\nmaster_ratio = 0.65\n")
    }

    @Test("whole-number floats render with a decimal point")
    func floatFormattingWhole() {
        var editor = ConfigEditor(text: "[layout]\nbsp_max_ratio = 0.75\n")
        expectSuccess(editor.set("bsp_max_ratio", .float(1.0), in: .layout))
        #expect(editor.text == "[layout]\nbsp_max_ratio = 1.0\n")
    }

    // MARK: - Error cases

    @Test("appendRule then removeRule at the appended index round-trips rule count")
    func appendThenRemove() {
        var editor = ConfigEditor(text: Self.example)
        guard case .success(let index) = editor.appendRule([ConfigField("app_name", .string("Test"))]) else {
            Issue.record("expected success"); return
        }
        expectSuccess(editor.removeRule(at: index))
        #expect(editor.text == Self.example)
    }

    @Test("set in .rule at an out-of-range index fails")
    func setRuleOutOfRange() {
        var editor = ConfigEditor(text: Self.example)
        switch editor.set("weight", .float(5), in: .rule(999)) {
        case .success: Issue.record("expected failure")
        case .failure: break
        }
    }
}
