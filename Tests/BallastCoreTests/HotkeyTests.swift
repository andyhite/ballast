import Testing
@testable import BallastCore

@Suite("Hotkey parsing")
struct HotkeyTests {

    @Test("modifier aliases resolve to the same modifier")
    func modifierAliases() {
        let commandSpecs = ["cmd+a", "command+a", "\u{2318}+a"]
        for spec in commandSpecs {
            guard case .success(let hotkey) = Hotkey.parse(spec) else {
                Issue.record("expected success for \(spec)")
                continue
            }
            #expect(hotkey.modifiers == .command)
        }

        let optionSpecs = ["alt+a", "opt+a", "option+a", "\u{2325}+a"]
        for spec in optionSpecs {
            guard case .success(let hotkey) = Hotkey.parse(spec) else {
                Issue.record("expected success for \(spec)")
                continue
            }
            #expect(hotkey.modifiers == .option)
        }

        let controlSpecs = ["ctrl+a", "control+a", "\u{2303}+a"]
        for spec in controlSpecs {
            guard case .success(let hotkey) = Hotkey.parse(spec) else {
                Issue.record("expected success for \(spec)")
                continue
            }
            #expect(hotkey.modifiers == .control)
        }

        let shiftSpecs = ["cmd+shift+a", "cmd+\u{21E7}+a"]
        for spec in shiftSpecs {
            guard case .success(let hotkey) = Hotkey.parse(spec) else {
                Issue.record("expected success for \(spec)")
                continue
            }
            #expect(hotkey.modifiers == [.command, .shift])
        }
    }

    @Test("hyper and meh compound modifiers")
    func compoundModifiers() {
        guard case .success(let hyper) = Hotkey.parse("hyper+h") else {
            Issue.record("expected success")
            return
        }
        #expect(hyper.modifiers == [.command, .option, .control, .shift])

        guard case .success(let meh) = Hotkey.parse("meh+h") else {
            Issue.record("expected success")
            return
        }
        #expect(meh.modifiers == [.option, .control, .shift])
    }

    @Test("duplicate modifiers are idempotent")
    func duplicateModifiers() {
        guard case .success(let hotkey) = Hotkey.parse("cmd+cmd+a") else {
            Issue.record("expected success")
            return
        }
        #expect(hotkey.modifiers == .command)
    }

    @Test("key codes for a representative set", arguments: [
        ("a", UInt32(0)),
        ("h", UInt32(4)),
        ("return", UInt32(36)),
        ("enter", UInt32(36)),
        ("left", UInt32(123)),
        ("f1", UInt32(122)),
        ("1", UInt32(18)),
        ("-", UInt32(27)),
        ("minus", UInt32(27)),
    ])
    func keyCodes(name: String, expectedCode: UInt32) {
        guard case .success(let hotkey) = Hotkey.parse("cmd+\(name)") else {
            Issue.record("expected success for \(name)")
            return
        }
        #expect(hotkey.keyCode == expectedCode)
    }

    @Test("canonical description orders modifiers ctrl, alt, shift, cmd")
    func canonicalDescription() {
        guard case .success(let hotkey) = Hotkey.parse("cmd+shift+alt+ctrl+h") else {
            Issue.record("expected success")
            return
        }
        #expect(hotkey.description == "ctrl+alt+shift+cmd+h")
    }

    @Test("description round-trips through parse", arguments: [
        "a", "b", "c", "d", "e", "f", "g", "h", "i", "j", "k", "l", "m", "n", "o", "p", "q", "r",
        "s", "t", "u", "v", "w", "x", "y", "z",
        "0", "1", "2", "3", "4", "5", "6", "7", "8", "9",
        "f1", "f2", "f3", "f4", "f5", "f6", "f7", "f8", "f9", "f10",
        "f11", "f12", "f13", "f14", "f15", "f16", "f17", "f18", "f19", "f20",
        "left", "right", "up", "down", "return", "tab", "space", "escape",
        "delete", "forwarddelete", "home", "end", "pageup", "pagedown",
        "minus", "equal", "leftbracket", "rightbracket", "semicolon", "quote",
        "comma", "period", "slash", "backslash", "grave",
    ])
    func descriptionRoundTrips(keyName: String) {
        guard case .success(let hotkey) = Hotkey.parse("ctrl+alt+shift+cmd+\(keyName)") else {
            Issue.record("expected success for \(keyName)")
            return
        }
        guard case .success(let reparsed) = Hotkey.parse(hotkey.description) else {
            Issue.record("expected success reparsing \(hotkey.description)")
            return
        }
        #expect(reparsed == hotkey)
        #expect(hotkey.keyName == keyName)
    }

    @Test("key alias canonicalizes to the same hotkey", arguments: [
        ("cmd+enter", "cmd+return"),
        ("cmd+esc", "cmd+escape"),
        ("cmd+backspace", "cmd+delete"),
        ("cmd+-", "cmd+minus"),
    ])
    func aliasCanonicalization(alias: String, canonical: String) {
        guard case .success(let aliasHotkey) = Hotkey.parse(alias) else {
            Issue.record("expected success for \(alias)")
            return
        }
        guard case .success(let canonicalHotkey) = Hotkey.parse(canonical) else {
            Issue.record("expected success for \(canonical)")
            return
        }
        #expect(aliasHotkey == canonicalHotkey)
    }

    @Test("empty spec is an error")
    func emptySpec() {
        guard case .failure(let error) = Hotkey.parse("") else {
            Issue.record("expected failure")
            return
        }
        #expect(error.description.contains("empty"))

        guard case .failure(let whitespaceError) = Hotkey.parse("   ") else {
            Issue.record("expected failure")
            return
        }
        #expect(whitespaceError.description.contains("empty"))
    }

    @Test("spec with no key is an error")
    func noKey() {
        guard case .failure(let error) = Hotkey.parse("cmd+shift") else {
            Issue.record("expected failure")
            return
        }
        #expect(error.description.contains("no key"))
    }

    @Test("spec with two keys is an error")
    func twoKeys() {
        guard case .failure(let error) = Hotkey.parse("cmd+a+b") else {
            Issue.record("expected failure")
            return
        }
        #expect(error.description.contains("more than one key"))
    }
    @Test("empty token in spec is an error", arguments: ["cmd+", "+a", "cmd++"])
    func emptyToken(spec: String) {
        guard case .failure(let error) = Hotkey.parse(spec) else {
            Issue.record("expected failure for \(spec)")
            return
        }
        #expect(error.description.contains("empty token"))
    }

    @Test("two aliases of the same key is an error")
    func twoKeyAliases() {
        guard case .failure(let error) = Hotkey.parse("return+enter") else {
            Issue.record("expected failure")
            return
        }
        #expect(error.description.contains("more than one key"))
    }

    @Test("bare typing keys without a modifier are rejected", arguments: ["a", "return", "space"])
    func bareKeyRejected(spec: String) {
        guard case .failure(let error) = Hotkey.parse(spec) else {
            Issue.record("expected failure for \(spec)")
            return
        }
        #expect(error.description.contains("modifier"))
    }

    @Test("shift-only typing keys are rejected", arguments: ["shift+a"])
    func shiftOnlyKeyRejected(spec: String) {
        guard case .failure(let error) = Hotkey.parse(spec) else {
            Issue.record("expected failure for \(spec)")
            return
        }
        #expect(error.description.contains("modifier"))
    }

    @Test("bare and shift-only function keys are accepted", arguments: ["f5", "shift+f5"])
    func bareFunctionKeyAccepted(spec: String) {
        guard case .success = Hotkey.parse(spec) else {
            Issue.record("expected success for \(spec)")
            return
        }
    }


    @Test("unknown token is named in the error message")
    func unknownToken() {
        guard case .failure(let error) = Hotkey.parse("cmd+bogus") else {
            Issue.record("expected failure")
            return
        }
        #expect(error.description.contains("bogus"))
    }

    @Test("whitespace around tokens is trimmed")
    func whitespaceTrimmed() {
        guard case .success(let hotkey) = Hotkey.parse("  cmd  +  h  ") else {
            Issue.record("expected success")
            return
        }
        #expect(hotkey.modifiers == .command)
        #expect(hotkey.keyName == "h")
    }

    @Test("case insensitivity")
    func caseInsensitivity() {
        guard case .success(let hotkey) = Hotkey.parse("CMD+SHIFT+H") else {
            Issue.record("expected success")
            return
        }
        #expect(hotkey.modifiers == [.command, .shift])
        #expect(hotkey.keyName == "h")
    }
}

@Suite("Rule matching")
struct RuleMatchingTests {
    @Test("app_id matches case-insensitively")
    func appIDCaseInsensitive() {
        let rule = RuleMatch(appID: "com.apple.safari")
        let facts = WindowFacts(bundleID: "com.apple.Safari")
        #expect(rule.matches(facts))
    }

    @Test("app_id does not match a different bundle id")
    func appIDMismatch() {
        let rule = RuleMatch(appID: "com.apple.safari")
        let facts = WindowFacts(bundleID: "com.apple.finder")
        #expect(!rule.matches(facts))
    }
}
