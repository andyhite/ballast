import Testing
@testable import BallastCore

@Suite("Hotkey parsing")
struct HotkeyTests {

    @Test("modifier aliases resolve to the same modifier")
    func modifierAliases() {
        let specs = ["cmd+a", "command+a", "\u{2318}+a"]
        for spec in specs {
            guard case .success(let hotkey) = Hotkey.parse(spec) else {
                Issue.record("expected success for \(spec)")
                continue
            }
            #expect(hotkey.modifiers == .command)
        }

        guard case .success(let opt) = Hotkey.parse("opt+a") else {
            Issue.record("expected success")
            return
        }
        #expect(opt.modifiers == .option)

        guard case .success(let ctrl) = Hotkey.parse("ctrl+a") else {
            Issue.record("expected success")
            return
        }
        #expect(ctrl.modifiers == .control)

        guard case .success(let shift) = Hotkey.parse("shift+a") else {
            Issue.record("expected success")
            return
        }
        #expect(shift.modifiers == .shift)
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

    @Test("description round-trips through parse")
    func descriptionRoundTrips() {
        guard case .success(let hotkey) = Hotkey.parse("ctrl+alt+shift+cmd+h") else {
            Issue.record("expected success")
            return
        }
        guard case .success(let reparsed) = Hotkey.parse(hotkey.description) else {
            Issue.record("expected success reparsing \(hotkey.description)")
            return
        }
        #expect(reparsed == hotkey)
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
