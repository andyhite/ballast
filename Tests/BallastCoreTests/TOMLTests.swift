import Testing
@testable import BallastCore

@Suite("TOML parsing")
struct TOMLTests {

    // MARK: - Value types

    @Test("basic strings support escapes")
    func basicString() throws {
        let t = try TOML.parse(#"s = "hello\nworld""#)
        #expect(t["s"] == .string("hello\nworld"))
    }

    @Test("literal strings are raw")
    func literalString() throws {
        let t = try TOML.parse(#"s = 'C:\temp'"#)
        #expect(t["s"] == .string("C:\\temp"))
    }

    @Test("unicode escapes decode to the correct scalars")
    func unicodeEscapes() throws {
        let t = try TOML.parse(#"s = "\u00e9\U0001F600""#)
        #expect(t["s"] == .string("\u{00e9}\u{1F600}"))
    }

    @Test("integers: decimal, signed, underscored")
    func integers() throws {
        let t = try TOML.parse("a = 42\nb = -17\nc = +9\nd = 1_000_000")
        #expect(t["a"] == .integer(42))
        #expect(t["b"] == .integer(-17))
        #expect(t["c"] == .integer(9))
        #expect(t["d"] == .integer(1_000_000))
    }

    @Test("integers: hex, octal, binary")
    func radixIntegers() throws {
        let t = try TOML.parse("hex = 0xFF\noct = 0o17\nbin = 0b1010")
        #expect(t["hex"] == .integer(255))
        #expect(t["oct"] == .integer(15))
        #expect(t["bin"] == .integer(10))
    }

    @Test("integers: hex/octal/binary underscores use radix-aware grouping")
    func radixIntegerUnderscores() throws {
        let t = try TOML.parse("a = 0xdead_beef\nb = 0xFF_FF\nc = 0x1_A")
        #expect(t["a"] == .integer(0xdead_beef))
        #expect(t["b"] == .integer(0xFF_FF))
        #expect(t["c"] == .integer(0x1A))
    }

    @Test("integers: signs are rejected after a radix prefix")
    func radixIntegerSignRejected() throws {
        #expect(throws: (any Error).self) { try TOML.parse("a = 0x-1") }
        #expect(throws: (any Error).self) { try TOML.parse("a = 0o+7") }
        #expect(throws: (any Error).self) { try TOML.parse("a = 0b-1") }
    }

    @Test("integers: Int64.min parses losslessly, overflow is rejected")
    func integerBoundaries() throws {
        let t = try TOML.parse("a = -9223372036854775808")
        #expect(t["a"] == .integer(Int64.min))
        #expect(throws: (any Error).self) { try TOML.parse("a = -9223372036854775809") }
        #expect(throws: (any Error).self) { try TOML.parse("a = 9223372036854775808") }
    }

    @Test("floats: fraction, exponent, sign")
    func floats() throws {
        let t = try TOML.parse("a = 3.14\nb = 1e10\nc = -0.5\nd = +2.5e-3")
        #expect(t["a"] == .float(3.14))
        #expect(t["b"] == .float(1e10))
        #expect(t["c"] == .float(-0.5))
        #expect(t["d"] == .float(2.5e-3))
    }

    @Test("floats: missing fraction/exponent digits are rejected")
    func invalidFloatGrammar() throws {
        #expect(throws: (any Error).self) { try TOML.parse("a = 7.") }
        #expect(throws: (any Error).self) { try TOML.parse("a = 3.e+20") }
    }

    @Test("floats: inf and nan")
    func specialFloats() throws {
        let t = try TOML.parse("a = inf\nb = -inf\nc = nan")
        #expect(t["a"] == .float(.infinity))
        #expect(t["b"] == .float(-.infinity))
        guard case .float(let d)? = t["c"] else {
            Issue.record("expected float nan")
            return
        }
        #expect(d.isNaN)
    }

    @Test("booleans")
    func booleans() throws {
        let t = try TOML.parse("a = true\nb = false")
        #expect(t["a"] == .boolean(true))
        #expect(t["b"] == .boolean(false))
    }

    @Test("datetimes: offset, local date, local time, space separator")
    func datetimes() throws {
        let t = try TOML.parse(
            "a = 1979-05-27T07:32:00Z\nb = 1979-05-27\nc = 07:32:00\nd = 1979-05-27 07:32:00Z"
        )
        guard case .datetime(let a)? = t["a"], case .datetime(let b)? = t["b"],
              case .datetime(let c)? = t["c"], case .datetime(let d)? = t["d"]
        else {
            Issue.record("expected datetime values")
            return
        }
        #expect(a == "1979-05-27T07:32:00Z")
        #expect(b == "1979-05-27")
        #expect(c == "07:32:00")
        #expect(d == "1979-05-27 07:32:00Z")
    }

    // MARK: - Tables

    @Test("nested dotted table headers")
    func nestedTableHeaders() throws {
        let t = try TOML.parse("[a.b.c]\nx = 1")
        guard case .table(let a)? = t["a"], case .table(let b)? = a["b"], case .table(let c)? = b["c"] else {
            Issue.record("expected nested tables")
            return
        }
        #expect(c["x"] == .integer(1))
    }

    @Test("dotted keys in a key/value assignment build nested tables")
    func dottedKeysInAssignment() throws {
        let t = try TOML.parse("a.b.c = 1\na.b.d = 2")
        guard case .table(let a)? = t["a"], case .table(let b)? = a["b"] else {
            Issue.record("expected nested tables")
            return
        }
        #expect(b["c"] == .integer(1))
        #expect(b["d"] == .integer(2))
    }

    @Test("array of tables preserves declaration order")
    func arrayOfTablesOrder() throws {
        let t = try TOML.parse("[[fruits]]\nname = \"apple\"\n[[fruits]]\nname = \"banana\"")
        guard case .array(let arr)? = t["fruits"], arr.count == 2,
              case .table(let f0) = arr[0], case .table(let f1) = arr[1]
        else {
            Issue.record("expected array of two tables")
            return
        }
        #expect(f0["name"] == .string("apple"))
        #expect(f1["name"] == .string("banana"))
    }

    @Test("sub-tables and nested arrays attach to the latest array-of-tables element")
    func nestedArrayOfTables() throws {
        let text = """
        [[fruits]]
        name = "apple"
        [fruits.physical]
        color = "red"
        [[fruits.varieties]]
        name = "red delicious"
        """
        let t = try TOML.parse(text)
        guard case .array(let arr)? = t["fruits"], arr.count == 1, case .table(let fruit) = arr[0] else {
            Issue.record("expected fruits array")
            return
        }
        guard case .table(let physical)? = fruit["physical"] else {
            Issue.record("expected physical subtable")
            return
        }
        #expect(physical["color"] == .string("red"))
        guard case .array(let varieties)? = fruit["varieties"], varieties.count == 1,
              case .table(let v0) = varieties[0]
        else {
            Issue.record("expected varieties array")
            return
        }
        #expect(v0["name"] == .string("red delicious"))
    }

    @Test("inline tables")
    func inlineTable() throws {
        let t = try TOML.parse("point = { x = 1, y = 2 }")
        guard case .table(let point)? = t["point"] else {
            Issue.record("expected inline table")
            return
        }
        #expect(point["x"] == .integer(1))
        #expect(point["y"] == .integer(2))
        #expect(point.keys == ["x", "y"])
    }

    @Test("keys and entries preserve insertion order")
    func insertionOrder() throws {
        let t = try TOML.parse("z = 1\na = 2\nm = 3")
        #expect(t.keys == ["z", "a", "m"])
        #expect(t.entries.map(\.key) == ["z", "a", "m"])
    }

    // MARK: - Arrays

    @Test("multi-line arrays allow comments and a trailing comma")
    func multilineArray() throws {
        let text = "a = [\n  1,\n  2, # comment\n  3,\n]"
        let t = try TOML.parse(text)
        #expect(t["a"] == .array([.integer(1), .integer(2), .integer(3)]))
    }

    @Test("arrays may mix value types")
    func mixedTypeArray() throws {
        let t = try TOML.parse(#"a = [1, "two", 3.0, true]"#)
        #expect(t["a"] == .array([.integer(1), .string("two"), .float(3.0), .boolean(true)]))
    }

    // MARK: - Multi-line strings

    @Test("multi-line basic string trims the opening newline")
    func multilineBasicString() throws {
        let t = try TOML.parse("s = \"\"\"\nHello\nWorld\"\"\"")
        #expect(t["s"] == .string("Hello\nWorld"))
    }

    @Test("multi-line basic string trims line-ending backslashes")
    func multilineBasicStringLineContinuation() throws {
        let t = try TOML.parse("s = \"\"\"\\\n  Hello \\\n  World\"\"\"")
        #expect(t["s"] == .string("Hello World"))
    }

    @Test("multi-line literal string keeps content verbatim")
    func multilineLiteralString() throws {
        let t = try TOML.parse("s = '''\nHello\nWorld'''")
        #expect(t["s"] == .string("Hello\nWorld"))
    }

    // MARK: - Errors

    @Test("duplicate key is an error at the redefinition line")
    func duplicateKey() {
        do {
            _ = try TOML.parse("a = 1\na = 2")
            Issue.record("expected throw")
        } catch let e as TOMLError {
            #expect(e.line == 2)
        } catch {
            Issue.record("wrong error type")
        }
    }

    @Test("redefining a table is an error")
    func redefiningTable() {
        do {
            _ = try TOML.parse("[a]\nx = 1\n[a]\ny = 2")
            Issue.record("expected throw")
        } catch let e as TOMLError {
            #expect(e.line == 3)
        } catch {
            Issue.record("wrong error type")
        }
    }

    @Test("defining a key through an inline table after the fact is an error")
    func keyThroughInlineTableAfterTheFact() {
        do {
            _ = try TOML.parse("a = { b = 1 }\na.c = 2")
            Issue.record("expected throw")
        } catch let e as TOMLError {
            #expect(e.line == 2)
        } catch {
            Issue.record("wrong error type")
        }
    }

    @Test("unterminated string is an error")
    func unterminatedString() {
        do {
            _ = try TOML.parse("s = \"abc")
            Issue.record("expected throw")
        } catch let e as TOMLError {
            #expect(e.line == 1)
        } catch {
            Issue.record("wrong error type")
        }
    }

    @Test("invalid escape sequence is an error")
    func invalidEscape() {
        do {
            _ = try TOML.parse(#"s = "abc\qdef""#)
            Issue.record("expected throw")
        } catch let e as TOMLError {
            #expect(e.line == 1)
        } catch {
            Issue.record("wrong error type")
        }
    }

    @Test("leading zero in a number is an error")
    func badNumberLeadingZero() {
        do {
            _ = try TOML.parse("n = 0123")
            Issue.record("expected throw")
        } catch let e as TOMLError {
            #expect(e.line == 1)
        } catch {
            Issue.record("wrong error type")
        }
    }

    @Test("garbage after a value is an error")
    func garbageAfterValue() {
        do {
            _ = try TOML.parse("n = 1 2")
            Issue.record("expected throw")
        } catch let e as TOMLError {
            #expect(e.line == 1)
        } catch {
            Issue.record("wrong error type")
        }
    }

    @Test("newline inside an inline table is an error")
    func newlineInsideInlineTable() {
        do {
            _ = try TOML.parse("a = { b = 1,\nc = 2 }")
            Issue.record("expected throw")
        } catch let e as TOMLError {
            #expect(e.line == 1)
        } catch {
            Issue.record("wrong error type")
        }
    }

    @Test("error description formats as line, column, message")
    func errorDescriptionFormat() {
        let e = TOMLError(line: 3, column: 5, message: "boom")
        #expect(e.description == "line 3, column 5: boom")
    }

    // MARK: - Fuzz: parser never traps

    private struct SplitMix64 {
        var state: UInt64
        mutating func next() -> UInt64 {
            state = state &+ 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    @Test("random TOML-ish garbage never traps the parser")
    func garbageInputNeverTraps() {
        let charset: [Character] = Array("abcdefABCDEF0123456789 \t\n\"'[]{}=,.#-_:+TZ\\\r")
        var rng = SplitMix64(state: 0xDEAD_BEEF_CAFE_BABE)
        var threw = 0
        var succeeded = 0
        for _ in 0..<2000 {
            let len = Int(rng.next() % 80)
            var s = ""
            for _ in 0..<len {
                let idx = Int(rng.next() % UInt64(charset.count))
                s.append(charset[idx])
            }
            do {
                _ = try TOML.parse(s)
                succeeded += 1
            } catch is TOMLError {
                threw += 1
            } catch {
                Issue.record("unexpected error type: \(error)")
            }
        }
        #expect(succeeded + threw == 2000)
    }
}
