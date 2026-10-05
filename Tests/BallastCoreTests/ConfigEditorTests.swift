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
        let result = editor.set("feature_size", .float(0.6), in: .layout)
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
        feature_size = 0.6               # share of feature
        """
        var editor = ConfigEditor(text: text)
        expectSuccess(editor.set("feature_size", .float(0.7), in: .layout))
        #expect(editor.text.contains("feature_size = 0.7               # share of feature"))
    }

    @Test("replace without a fitting comment column falls back to one space")
    func replaceCommentTooNarrow() {
        let text = """
        [layout]
        feature_size = 0.6 # r
        """
        var editor = ConfigEditor(text: text)
        expectSuccess(editor.set("feature_size", .float(0.85), in: .layout))
        #expect(editor.text == "[layout]\nfeature_size = 0.85 # r\n")
    }

    @Test("replace on an existing key does not disturb sibling keys")
    func replacePreservesSiblings() {
        let text = """
        [layout]
        arrange = "dwindle"
        feature_size = 0.6
        feature_count = 1
        """
        var editor = ConfigEditor(text: text)
        expectSuccess(editor.set("feature_count", .integer(3), in: .layout))
        #expect(editor.text == "[layout]\narrange = \"dwindle\"\nfeature_size = 0.6\nfeature_count = 3\n")
    }

    @Test("replace collapses a multi-line array value to one line")
    func replaceMultiLineValue() {
        var editor = ConfigEditor(text: """
        [layout]
        tags = [
            1,
            2
        ]
        arrange = "dwindle"
        """)
        expectSuccess(editor.set("tags", .integer(4), in: .layout))
        #expect(editor.text == "[layout]\ntags = 4\narrange = \"dwindle\"\n")
    }

    // MARK: - Insert

    @Test("set inserts a missing key after the section's last key")
    func insertIntoExistingSection() {
        let text = """
        [layout]
        arrange = "dwindle"
        feature_count = 1
        """
        var editor = ConfigEditor(text: text)
        expectSuccess(editor.set("feature_size", .float(0.55), in: .layout))
        #expect(editor.text == "[layout]\narrange = \"dwindle\"\nfeature_count = 1\nfeature_size = 0.55\n")
    }

    @Test("set creates a missing [settings] section before [layout]")
    func createsSettingsSection() {
        let text = """
        [layout]
        arrange = "dwindle"
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
        arrange = "dwindle"
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
        arrange = "dwindle"
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
        arrange = "dwindle"
        feature_count = 2
        """
        var editor = ConfigEditor(text: text)
        expectSuccess(editor.set("feature_count", nil, in: .layout))
        #expect(editor.text == "[layout]\narrange = \"dwindle\"\n")
    }

    @Test("removing an absent key is a no-op")
    func removeAbsentKey() {
        let text = "[layout]\narrange = \"dwindle\"\n"
        var editor = ConfigEditor(text: text)
        expectSuccess(editor.set("feature_count", nil, in: .layout))
        #expect(editor.text == text)
    }

    @Test("removing a key removes an orphaned aligned comment-continuation line")
    func removeKeyRemovesAlignedContinuation() {
        let text = "[layout]\narrange = \"dwindle\"          # first\n"
            + String(repeating: " ", count: 29) + "# second\nfeature_count = 1\n"
        var editor = ConfigEditor(text: text)
        expectSuccess(editor.set("arrange", nil, in: .layout))
        #expect(editor.text == "[layout]\nfeature_count = 1\n")
    }

    // MARK: - Spaces

    @Test("set on a missing space creates its [[space]] block after the last one")
    func createsSpaceBlock() {
        var editor = ConfigEditor(text: Self.example)
        let key = SpaceAddress.position(display: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA", ordinal: 5)
        expectSuccess(editor.set("arrange", .string("float"), in: .space(key)))
        switch editor.validated() {
        case .success(let config):
            #expect(config.spaces[key]?.arrange == .float)
        case .failure(let e):
            Issue.record("expected success, got \(e)")
        }
    }

    @Test("removeSpace deletes the whole block and space reverts to layout defaults")
    func removeSpaceBlock() {
        var editor = ConfigEditor(text: Self.example)
        let key = SpaceAddress.uuid("06577405-6B31-4676-9725-A2F69D4232F4")
        func hasKey(_ text: String) -> Bool? {
            if case .success(let config) = Config.parse(text) { return config.spaces[key] != nil }
            return nil
        }
        #expect(hasKey(editor.text) == true)
        expectSuccess(editor.removeSpace(key))
        #expect(editor.text != Self.example)
        #expect(hasKey(editor.text) == false)
    }

    @Test("removeSpace on an absent space is a no-op")
    func removeAbsentSpace() {
        var editor = ConfigEditor(text: Self.example)
        let key = SpaceAddress.position(display: "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF", ordinal: 9)
        expectSuccess(editor.removeSpace(key))
        #expect(editor.text == Self.example)
    }

    @Test("editing a uuid-addressed desktop creates and updates a uuid-only [[space]] block")
    func uuidSpaceBlockRoundTrips() {
        let uuid = SpaceAddress.uuid("06577405-6B31-4676-9725-A2F69D4232F4")
        var editor = ConfigEditor(text: "[layout]\narrange = \"dwindle\"\n")
        expectSuccess(editor.set("arrange", .string("float"), in: .space(uuid)))
        expectSuccess(editor.set("feature_size", .float(0.6), in: .space(uuid)))
        #expect(editor.text.contains("uuid = \"06577405-6B31-4676-9725-A2F69D4232F4\""))
        #expect(!editor.text.contains("ordinal"))
        #expect(editor.text.components(separatedBy: "[[space]]").count == 2) // one block
        switch editor.validated() {
        case .success(let config):
            #expect(config.spaces[uuid]?.arrange == .float)
            #expect(config.spaces[uuid]?.featureSize == 0.6)
        case .failure(let e):
            Issue.record("expected success, got \(e)")
        }
    }

    @Test("removeSpaces(for:) drops both the uuid and the positional entry of a desktop, and no other")
    func removeSpacesForKeyDropsEveryAddress() {
        let display = "11111111-1111-1111-1111-111111111111"
        let uuid = "06577405-6B31-4676-9725-A2F69D4232F4"
        let text = """
        [[space]]
        uuid = "\(uuid)"
        arrange = "dwindle"

        [[space]]
        display = "\(display)"
        ordinal = 1
        arrange = "float"

        [[space]]
        display = "\(display)"
        ordinal = 2
        arrange = "float"
        """
        var editor = ConfigEditor(text: text)
        expectSuccess(editor.removeSpaces(for: SpaceKey(display: display, ordinal: 1, uuid: uuid)))
        switch editor.validated() {
        case .success(let config):
            #expect(Set(config.spaces.keys) == [.position(display: display, ordinal: 2)])
        case .failure(let e):
            Issue.record("expected success, got \(e)")
        }
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
        let text = "[layout]\narrange = \"dwindle\"\n"
        var editor = ConfigEditor(text: text)
        expectSuccess(editor.set("alt+h", .string("focus left"), in: .bindings))
        #expect(editor.text == "[layout]\narrange = \"dwindle\"\n\n[bindings]\n\"alt+h\" = \"focus left\"\n")
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
        arrange = "dwindle"

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
        var editor = ConfigEditor(text: "[layout]\nfeature_size = 0.6\n")
        expectSuccess(editor.set("feature_size", .float(0.65), in: .layout))
        #expect(editor.text == "[layout]\nfeature_size = 0.65\n")
    }

    @Test("whole-number floats render with a decimal point")
    func floatFormattingWhole() {
        var editor = ConfigEditor(text: "[layout]\nweight_share_max = 0.75\n")
        expectSuccess(editor.set("weight_share_max", .float(1.0), in: .layout))
        #expect(editor.text == "[layout]\nweight_share_max = 1.0\n")
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

    // MARK: - Nested child tables (`[rule.size]`, `[rule.placement]`, `[space.gaps]`)

    static let ruleWithChildTables = """
    [[rule]]
    app_id = "com.first.app"
    float = true
    [rule.size]
    w = 0.5
    h = 0.5

    [[rule]]
    app_id = "com.second.app"
    float = true
    [rule.placement]
    x = 0.1
    y = 0.1
    w = 0.3
    h = 0.3
    """

    @Test("removeRule on a rule with a [rule.size] child leaves an earlier rule's own child table intact and removes the target's")
    func removeRuleWithChildTablesPreservesSiblingChild() {
        var editor = ConfigEditor(text: Self.ruleWithChildTables)
        expectSuccess(editor.removeRule(at: 1))
        switch editor.validated() {
        case .success(let config):
            #expect(config.rules.count == 1)
            #expect(config.rules.first?.match.appID == "com.first.app")
            #expect(config.rules.first?.actions.size?.width == 0.5)
        case .failure(let e):
            Issue.record("expected success, got \(e)")
        }
        #expect(!editor.text.contains("[rule.placement]"))
        #expect(editor.text.contains("[rule.size]"))
    }

    @Test("[rule.size]/[rule.placement] child tables are not counted as their own [[rule]] entries")
    func childTablesDoNotInflateRuleCount() {
        var editor = ConfigEditor(text: Self.ruleWithChildTables)
        switch editor.validated() {
        case .success(let config):
            #expect(config.rules.count == 2)
        case .failure(let e):
            Issue.record("expected success, got \(e)")
        }
        switch editor.set("weight", .float(3), in: .rule(2)) {
        case .success: Issue.record("expected out-of-range failure for the child table miscounted as a rule")
        case .failure: break
        }
    }

    @Test("appendRule after a rule with a child table keeps the child table with its own rule")
    func appendRuleAfterChildTablePreservesOwnership() {
        var editor = ConfigEditor(text: Self.ruleWithChildTables)
        let result = editor.appendRule([ConfigField("app_id", .string("com.third.app"))])
        guard case .success(2) = result else { Issue.record("expected index 2"); return }
        switch editor.validated() {
        case .success(let config):
            #expect(config.rules.count == 3)
            #expect(config.rules[1].actions.placement != nil)
            #expect(config.rules.last?.match.appID == "com.third.app")
        case .failure(let e):
            Issue.record("expected success, got \(e)")
        }
    }

    @Test("moveRule moves a rule's [rule.size] child table along with it")
    func moveRuleCarriesChildTable() {
        var editor = ConfigEditor(text: Self.ruleWithChildTables)
        expectSuccess(editor.moveRule(from: 0, to: 1))
        switch editor.validated() {
        case .success(let config):
            #expect(config.rules.count == 2)
            #expect(config.rules[0].match.appID == "com.second.app")
            #expect(config.rules[0].actions.placement != nil)
            #expect(config.rules[1].match.appID == "com.first.app")
            #expect(config.rules[1].actions.size?.width == 0.5)
        case .failure(let e):
            Issue.record("expected success, got \(e)")
        }
    }

    @Test("adding a new space after one with a [space.gaps] child table preserves that child table")
    func addSpaceAfterOnePreservesGapsChildTable() {
        let text = """
        [[space]]
        display = "11111111-1111-1111-1111-111111111111"
        ordinal = 1

        [space.gaps]
        inner = 12
        """
        var editor = ConfigEditor(text: text)
        let key2 = SpaceAddress.position(display: "22222222-2222-2222-2222-222222222222", ordinal: 2)
        expectSuccess(editor.set("arrange", .string("float"), in: .space(key2)))
        switch editor.validated() {
        case .success(let config):
            let key1 = SpaceAddress.position(display: "11111111-1111-1111-1111-111111111111", ordinal: 1)
            #expect(config.spaces[key1]?.gapsInner == 12)
            #expect(config.spaces[key2]?.arrange == .float)
        case .failure(let e):
            Issue.record("expected success, got \(e)")
        }
        #expect(editor.text.contains("[space.gaps]\ninner = 12"))
    }

    @Test("removing a missing key from a [[space]] that doesn't exist yet is a byte-identical no-op")
    func removeMissingKeyFromAbsentSpaceIsNoOp() {
        let text = "[layout]\narrange = \"dwindle\"\n"
        var editor = ConfigEditor(text: text)
        let key = SpaceAddress.position(display: "33333333-3333-3333-3333-333333333333", ordinal: 3)
        expectSuccess(editor.set("arrange", nil, in: .space(key)))
        #expect(editor.text == text)
        #expect(!editor.text.contains("[[space]]"))
    }

    @Test("removing a key written as the space's own child table removes that table, leaving the sibling's")
    func removeKeyWrittenAsChildTable() {
        let text = """
        [[space]]
        display = "11111111-1111-1111-1111-111111111111"
        ordinal = 1
        arrange = "dwindle"

        [space.gaps]
        inner = 3

        [[space]]
        display = "22222222-2222-2222-2222-222222222222"
        ordinal = 2

        [space.gaps]
        inner = 5
        """
        var editor = ConfigEditor(text: text)
        let key1 = SpaceAddress.position(display: "11111111-1111-1111-1111-111111111111", ordinal: 1)
        let key2 = SpaceAddress.position(display: "22222222-2222-2222-2222-222222222222", ordinal: 2)
        expectSuccess(editor.set("gaps", nil, in: .space(key1)))
        switch editor.validated() {
        case .success(let config):
            #expect(config.spaces[key1]?.gapsInner == nil)
            #expect(config.spaces[key1]?.arrange == .dwindle)
            #expect(config.spaces[key2]?.gapsInner == 5)
        case .failure(let e):
            Issue.record("expected success, got \(e)")
        }
    }

    @Test("setting a key written as a child table replaces the table with the inline value")
    func setKeyWrittenAsChildTable() {
        let text = """
        [layout]
        arrange = "dwindle"

        [layout.gaps]
        inner = 4
        outer = 6
        """
        var editor = ConfigEditor(text: text)
        expectSuccess(editor.set("gaps", .inlineTable([ConfigField("inner", .integer(10))]), in: .layout))
        switch editor.validated() {
        case .success(let config):
            #expect(config.layout.gapsInner == 10)
            #expect(config.layout.gapsOuter == nil)
        case .failure(let e):
            Issue.record("expected success, got \(e)")
        }
        #expect(!editor.text.contains("[layout.gaps]"))
    }

    @Test("removeSpace on one of two spaces removes its own [space.gaps] and leaves the sibling's [space.gaps] intact")
    func removeSpaceWithChildTablePreservesSiblingChild() {
        let text = """
        [[space]]
        display = "11111111-1111-1111-1111-111111111111"
        ordinal = 1

        [space.gaps]
        inner = 4

        [[space]]
        display = "22222222-2222-2222-2222-222222222222"
        ordinal = 2

        [space.gaps]
        inner = 20
        """
        var editor = ConfigEditor(text: text)
        let removed = SpaceAddress.position(display: "11111111-1111-1111-1111-111111111111", ordinal: 1)
        let kept = SpaceAddress.position(display: "22222222-2222-2222-2222-222222222222", ordinal: 2)
        expectSuccess(editor.removeSpace(removed))
        switch editor.validated() {
        case .success(let config):
            #expect(config.spaces[removed] == nil)
            #expect(config.spaces[kept]?.gapsInner == 20)
        case .failure(let e):
            Issue.record("expected success, got \(e)")
        }
        let occurrences = editor.text.components(separatedBy: "[space.gaps]").count - 1
        #expect(occurrences == 1)
        #expect(editor.text.contains("[space.gaps]\ninner = 20"))
    }

    @Test("set on a rule's own field leaves its trailing [rule.size] child table untouched")
    func setRuleFieldLeavesChildTableIntact() {
        var editor = ConfigEditor(text: Self.ruleWithChildTables)
        expectSuccess(editor.set("app_id", .string("com.first.renamed"), in: .rule(0)))
        switch editor.validated() {
        case .success(let config):
            #expect(config.rules[0].match.appID == "com.first.renamed")
            #expect(config.rules[0].actions.size?.width == 0.5)
            #expect(config.rules[0].actions.size?.height == 0.5)
            #expect(config.rules.count == 2)
        case .failure(let e):
            Issue.record("expected success, got \(e)")
        }
        #expect(editor.text.contains("[rule.size]\nw = 0.5\nh = 0.5"))
    }

    @Test("set inserting a new field on a rule with a trailing child table lands before the child header, not inside it")
    func setInsertsNewRuleFieldBeforeChildTable() {
        var editor = ConfigEditor(text: Self.ruleWithChildTables)
        expectSuccess(editor.set("weight", .float(2.5), in: .rule(0)))
        switch editor.validated() {
        case .success(let config):
            #expect(config.rules[0].match.appID == "com.first.app")
            #expect(config.rules[0].actions.size?.width == 0.5)
            #expect(config.rules.count == 2)
        case .failure(let e):
            Issue.record("expected success, got \(e)")
        }
        #expect(editor.text.contains("weight = 2.5\n[rule.size]"))
    }

    @Test("removing a missing key from a section that doesn't exist yet is a byte-identical no-op")
    func removeMissingKeyFromAbsentSectionIsNoOp() {
        let text = "[layout]\narrange = \"dwindle\"\n"
        var editor = ConfigEditor(text: text)
        expectSuccess(editor.set("duration_ms", nil, in: .animation))
        #expect(editor.text == text)
        #expect(!editor.text.contains("[settings.animation]"))
    }

    // MARK: - CRLF

    static let crlfExample = example.replacingOccurrences(of: "\n", with: "\r\n")

    /// True when every line break in `s` is CRLF.
    static func isPureCRLF(_ s: String) -> Bool {
        !s.replacingOccurrences(of: "\r\n", with: "").contains("\n")
    }

    @Test("removeSpace on a CRLF document finds the last [[space]] and keeps CRLF endings")
    func crlfRemoveSpace() {
        let key = SpaceAddress.position(display: "6D147BFB-7E3C-4CCD-9825-F1A5A059052D", ordinal: 5)
        var lf = ConfigEditor(text: Self.example)
        var crlf = ConfigEditor(text: Self.crlfExample)
        expectSuccess(lf.removeSpace(key))
        expectSuccess(crlf.removeSpace(key))
        #expect(crlf.text != Self.crlfExample)
        #expect(Self.isPureCRLF(crlf.text))
        #expect(crlf.text == lf.text.replacingOccurrences(of: "\n", with: "\r\n"))
        if case .success(let config) = crlf.validated() { #expect(config.spaces[key] == nil) }
        else { Issue.record("CRLF result no longer validates") }
    }

    @Test("set on an existing [[space]] in a CRLF document edits it instead of appending a duplicate")
    func crlfSetExistingSpace() {
        let key = SpaceAddress.position(display: "6D147BFB-7E3C-4CCD-9825-F1A5A059052D", ordinal: 5)
        var editor = ConfigEditor(text: Self.crlfExample)
        expectSuccess(editor.set("arrange", .string("dwindle"), in: .space(key)))
        #expect(Self.isPureCRLF(editor.text))
        #expect(editor.text.components(separatedBy: "[[space]]").count == Self.example.components(separatedBy: "[[space]]").count)
        switch editor.validated() {
        case .success(let config): #expect(config.spaces[key]?.arrange == .dwindle)
        case .failure(let e): Issue.record("expected success, got \(e)")
        }
    }

    @Test("a no-op set on a CRLF document is byte-identical")
    func crlfNoOp() {
        var editor = ConfigEditor(text: Self.crlfExample)
        expectSuccess(editor.set("feature_size", .float(0.6), in: .layout))
        #expect(editor.text == Self.crlfExample)
    }

    // MARK: - Insertion next to comments

    @Test("a new [[space]] goes above the comments attached to [bindings], and removing it keeps them")
    func createSpaceAboveBindingsComments() {
        let text = "# top\n\n# About bindings\n[bindings]\n\"alt+h\" = \"focus left\"\n"
        let uuid = SpaceAddress.uuid("06577405-6B31-4676-9725-A2F69D4232F4")
        var editor = ConfigEditor(text: text)
        expectSuccess(editor.set("arrange", .string("float"), in: .space(uuid)))
        #expect(editor.text.contains("\n# About bindings\n[bindings]"))
        #expect(editor.text.range(of: "[[space]]")!.lowerBound < editor.text.range(of: "# About bindings")!.lowerBound)
        expectSuccess(editor.removeSpace(uuid))
        #expect(editor.text == text)
    }

    @Test("a first appended rule goes above the comments attached to [bindings], and removing it keeps them")
    func appendRuleAboveBindingsComments() {
        let text = "# About bindings\n[bindings]\n\"alt+h\" = \"focus left\"\n"
        var editor = ConfigEditor(text: text)
        expectSuccess(editor.appendRule([ConfigField("app_id", .string("com.a")), ConfigField("float", .bool(true))]))
        #expect(editor.text.hasPrefix("[[rule]]\n"))
        #expect(editor.text.contains("\n# About bindings\n[bindings]"))
        expectSuccess(editor.removeRule(at: 0))
        #expect(editor.text == text)
    }

    @Test("a new top-of-file section goes after the file's header comment")
    func firstSectionKeepsHeaderComment() {
        var editor = ConfigEditor(text: "# Ballast config\n# more\n\n[layout]\narrange = \"dwindle\"\n")
        expectSuccess(editor.set("focus_follows_mouse", .bool(true), in: .settings))
        #expect(editor.text == "# Ballast config\n# more\n\n[settings]\nfocus_follows_mouse = true\n\n[layout]\narrange = \"dwindle\"\n")
    }

    @Test("a comment attached directly to the first table stays with it")
    func firstSectionKeepsAttachedComment() {
        var editor = ConfigEditor(text: "# about layout\n[layout]\narrange = \"dwindle\"\n")
        expectSuccess(editor.set("focus_follows_mouse", .bool(true), in: .settings))
        #expect(editor.text == "[settings]\nfocus_follows_mouse = true\n\n# about layout\n[layout]\narrange = \"dwindle\"\n")
    }

    // MARK: - Refusals

    @Test("a [rule.size] that doesn't follow its [[rule]] refuses the edit instead of re-parenting it")
    func nonAdjacentChildTableRefused() {
        let text = "[[rule]]\napp_id = \"com.a\"\nfloat = true\n\n[bindings]\n\n[rule.size]\nw = 0.5\nh = 0.5\n"
        var editor = ConfigEditor(text: text)
        let result = editor.appendRule([ConfigField("app_id", .string("com.b")), ConfigField("float", .bool(true))])
        #expect(result == .failure(ConfigEditError("could not parse document")))
        #expect(editor.text == text)
    }

    @Test("removeSpace fails when a [[space]] body can't be parsed")
    func removeSpaceUnreadableBody() {
        let text = "[[space]]\nuuid = \n"
        var editor = ConfigEditor(text: text)
        if case .success = editor.removeSpace(.uuid("06577405-6B31-4676-9725-A2F69D4232F4")) {
            Issue.record("expected failure")
        }
        #expect(editor.text == text)
    }

    @Test("a header-looking line inside a multi-line string is not a block boundary")
    func headerInsideMultilineString() {
        let text = "[[rule]]\napp_id = \"com.a\"\ntitle_regex = '''\n[Ss]ettings'''\nfloat = true\n"
        var editor = ConfigEditor(text: text)
        expectSuccess(editor.set("float", .bool(false), in: .rule(0)))
        #expect(editor.text.contains("title_regex = '''\n[Ss]ettings'''\n"))
        guard case .success(let config) = editor.validated() else { Issue.record("expected valid"); return }
        #expect(config.rules.count == 1)
        #expect(config.rules[0].match.titleRegex != nil)
        #expect(config.rules[0].actions.float == false)
    }

    @Test("dotted keys are replaced or removed as a whole")
    func dottedKeysReplaced() {
        let uuid = "06577405-6B31-4676-9725-A2F69D4232F4"
        let text = "[[space]]\nuuid = \"\(uuid)\"\ngaps.inner = 4\n"
        var removed = ConfigEditor(text: text)
        expectSuccess(removed.set("gaps", nil, in: .space(.uuid(uuid))))
        #expect(removed.text == "[[space]]\nuuid = \"\(uuid)\"\n")
        var replaced = ConfigEditor(text: text)
        expectSuccess(replaced.set("gaps", .inlineTable([ConfigField("inner", .float(10))]), in: .space(.uuid(uuid))))
        guard case .success(let config) = replaced.validated() else { Issue.record("expected valid"); return }
        #expect(config.spaces[.uuid(uuid)]?.gapsInner == 10)
    }

    @Test("creating [settings.animation] next to an inline/dotted animation fails clearly")
    func animationDottedRefused() {
        var editor = ConfigEditor(text: "[settings]\nanimation.enabled = false\n")
        guard case .failure(let error) = editor.set("duration_ms", .integer(100), in: .animation) else { Issue.record("expected failure"); return }
        #expect(error == ConfigEditError("[settings] already sets animation as an inline table or dotted keys; edit that entry in the config file"))
    }

    @Test("removing a rule from the example config leaves no double blank line")
    func removeRuleNoTripleNewline() {
        var editor = ConfigEditor(text: Self.example)
        expectSuccess(editor.removeRule(at: 2))
        #expect(!editor.text.contains("\n\n\n"))
    }

    @Test("removing a key drops every aligned continuation comment")
    func removeKeyDropsAllContinuations() {
        let pad = String(repeating: " ", count: 13)
        let text = "[[rule]]\napp_id = \"com.a\"\nweight = 5   # one\n\(pad)# two\n\(pad)# three\nfloat = true\n"
        var editor = ConfigEditor(text: text)
        expectSuccess(editor.set("weight", nil, in: .rule(0)))
        #expect(editor.text == "[[rule]]\napp_id = \"com.a\"\nfloat = true\n")
    }

    // MARK: - Escaping

    @Test("strings with control characters round-trip through the editor and TOML.parse")
    func escapesControlCharacters() throws {
        let s = "a\r\nb\rc\u{1}d\u{7F}e\"f\\g\th\ni é😀"
        var editor = ConfigEditor(text: "")
        expectSuccess(editor.appendRule([ConfigField("title_substring", .string(s))]))
        let parsed = try TOML.parse(editor.text)
        guard case .array(let rules)? = parsed["rule"], case .table(let rule)? = rules.first else {
            Issue.record("rule missing"); return
        }
        #expect(rule["title_substring"] == .string(s))
    }

    // MARK: - renameKey

    @Test("renameKey rewrites the key in place and keeps the trailing comment")
    func renameKeyInPlace() {
        let text = "[bindings]\n\"alt+h\" = \"focus left\"   # west\n\"alt+j\" = \"focus down\"\n"
        var editor = ConfigEditor(text: text)
        expectSuccess(editor.renameKey("alt+h", to: "alt+a", value: .string("focus down"), in: .bindings))
        #expect(editor.text == "[bindings]\n\"alt+a\" = \"focus down\"   # west\n\"alt+j\" = \"focus down\"\n")
    }

    @Test("renameKey with an absent old key inserts the new key")
    func renameKeyAbsentInserts() {
        var editor = ConfigEditor(text: "[bindings]\n\"alt+h\" = \"focus left\"\n")
        expectSuccess(editor.renameKey("alt+x", to: "alt+j", value: .string("focus down"), in: .bindings))
        #expect(editor.text == "[bindings]\n\"alt+h\" = \"focus left\"\n\"alt+j\" = \"focus down\"\n")
    }

    @Test("renameKey to the same key just sets the value")
    func renameKeySameKeySets() {
        var editor = ConfigEditor(text: "[bindings]\n\"alt+h\" = \"focus left\" # c\n")
        expectSuccess(editor.renameKey("alt+h", to: "alt+h", value: .string("focus right"), in: .bindings))
        #expect(editor.text == "[bindings]\n\"alt+h\" = \"focus right\" # c\n")
    }

}
