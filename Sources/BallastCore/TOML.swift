import Foundation

/// A parsed TOML value. Arrays of tables (`[[a.b]]`) surface as
/// `.array([.table(...), ...])`; datetimes are stored as their raw source
/// lexeme (loosely validated, not fully RFC 3339 parsed).
public indirect enum TOMLValue: Equatable, Sendable {
    case string(String)
    case integer(Int64)
    case float(Double)
    case boolean(Bool)
    case datetime(String)
    case array([TOMLValue])
    case table(TOMLTable)
}

/// An ordered TOML table: preserves source insertion order for keys.
public struct TOMLTable: Equatable, Sendable {
    private var order: [String] = []
    private var storage: [String: TOMLValue] = [:]

    public init() {}

    /// Keys in source insertion order.
    public var keys: [String] { order }

    public subscript(key: String) -> TOMLValue? { storage[key] }

    /// Key/value pairs in source insertion order.
    public var entries: [(key: String, value: TOMLValue)] {
        order.compactMap { key in
            guard let value = storage[key] else { return nil }
            return (key, value)
        }
    }

    /// Inserts or overwrites `key`. Internal builder use only.
    mutating func set(_ key: String, _ value: TOMLValue) {
        if storage[key] == nil {
            order.append(key)
        }
        storage[key] = value
    }

    public static func == (lhs: TOMLTable, rhs: TOMLTable) -> Bool {
        lhs.order == rhs.order && lhs.storage == rhs.storage
    }
}

/// A TOML parse failure with a 1-based source position.
public struct TOMLError: Error, Equatable, CustomStringConvertible {
    public let line: Int
    public let column: Int
    public let message: String

    public init(line: Int, column: Int, message: String) {
        self.line = line
        self.column = column
        self.message = message
    }

    public var description: String { "line \(line), column \(column): \(message)" }
}

/// Zero-dependency TOML 1.0 parser producing an ordered value tree.
public enum TOML {
    /// Parses `text` as a TOML 1.0 document. Never traps; every malformed
    /// input surfaces as a thrown `TOMLError`.
    public static func parse(_ text: String) throws -> TOMLTable {
        let parser = TOMLParser(text)
        return try parser.parseDocument()
    }
}

// MARK: - Scanning

/// A bounds-checked cursor over a document's Unicode scalars with 1-based
/// line/column tracking. Every access is guarded; out-of-range reads return
/// `nil` rather than trapping.
private final class TOMLScanner {
    let scalars: [Unicode.Scalar]
    var idx: Int = 0
    var line: Int = 1
    var col: Int = 1

    init(_ text: String) {
        self.scalars = Array(text.unicodeScalars)
    }

    func peek(_ offset: Int = 0) -> Unicode.Scalar? {
        let i = idx + offset
        guard i >= 0, i < scalars.count else { return nil }
        return scalars[i]
    }

    @discardableResult
    func advance() -> Unicode.Scalar? {
        guard idx < scalars.count else { return nil }
        let c = scalars[idx]
        idx += 1
        if c == "\n" {
            line += 1
            col = 1
        } else if c != "\r" {
            col += 1
        }
        return c
    }

    var pos: (line: Int, column: Int) { (line, col) }
}

// MARK: - Document builder tree

/// Mutable, reference-typed table used only while building the top-level
/// document structure (so `[a.b]` headers and dotted keys spread across many
/// lines can reopen and extend the same table). Frozen into an immutable
/// `TOMLTable` once the document is fully parsed.
private final class TOMLBuildTable {
    var order: [String] = []
    var children: [String: TOMLBuildEntry] = [:]
    /// Set once an explicit `[table]`/`[[table]]` header has claimed this node.
    var headerDefined = false
    /// Set when this table was created implicitly via a dotted key in a
    /// key/value pair; such tables may never be reopened with a `[header]`.
    var closedForHeader = false
    /// Set for inline (`{ ... }`) tables, which are fully closed on creation.
    var isInline = false
}

private enum TOMLBuildEntry {
    case value(TOMLValue)
    case table(TOMLBuildTable)
    case arrayOfTables([TOMLBuildTable])
}

// MARK: - Parser

private final class TOMLParser {
    let scanner: TOMLScanner
    let root: TOMLBuildTable
    var current: TOMLBuildTable

    init(_ text: String) {
        self.scanner = TOMLScanner(text)
        self.root = TOMLBuildTable()
        self.current = root
    }

    // MARK: Errors

    private func err(_ message: String, at pos: (line: Int, column: Int)? = nil) -> TOMLError {
        let p = pos ?? scanner.pos
        return TOMLError(line: p.line, column: p.column, message: message)
    }

    // MARK: Top level

    func parseDocument() throws -> TOMLTable {
        while true {
            skipWhitespaceAndComments(acrossNewlines: true)
            guard let c = scanner.peek() else { break }
            if c == "[" {
                try parseHeader()
            } else {
                try parseKeyValueLine()
            }
        }
        return freeze(root)
    }

    private func parseHeader() throws {
        let startPos = scanner.pos
        scanner.advance() // consume first '['
        var isArray = false
        if scanner.peek() == "[" {
            isArray = true
            scanner.advance()
        }
        skipSpacesTabsOnly()
        let parts = try parseDottedKey()
        skipSpacesTabsOnly()
        guard scanner.peek() == "]" else {
            throw err(isArray ? "expected ']]' to close array-of-tables header" : "expected ']' to close table header")
        }
        scanner.advance()
        if isArray {
            guard scanner.peek() == "]" else {
                throw err("expected ']]' to close array-of-tables header")
            }
            scanner.advance()
        }
        skipSpacesTabsOnly()
        if let c = scanner.peek() {
            if c == "#" {
                while let cc = scanner.peek(), cc != "\n" { scanner.advance() }
            } else if c == "\n" || c == "\r" {
                // fine, consumed by outer loop
            } else {
                throw err("unexpected content after table header")
            }
        }
        guard !parts.isEmpty else { throw err("empty table header", at: startPos) }
        try applyHeader(parts, isArray: isArray, pos: startPos)
    }

    private func applyHeader(_ parts: [String], isArray: Bool, pos: (line: Int, column: Int)) throws {
        var node = root
        for part in parts.dropLast() {
            node = try step(into: node, part: part, pos: pos, creatingClosed: false)
        }
        guard let last = parts.last else { throw err("empty table header", at: pos) }

        if isArray {
            if let entry = node.children[last] {
                switch entry {
                case .arrayOfTables(let arr):
                    let t = TOMLBuildTable()
                    t.headerDefined = true
                    node.children[last] = .arrayOfTables(arr + [t])
                    current = t
                case .table:
                    throw err("'\(last)' is already defined as a table", at: pos)
                case .value:
                    throw err("'\(last)' is already defined as a value", at: pos)
                }
            } else {
                let t = TOMLBuildTable()
                t.headerDefined = true
                node.children[last] = .arrayOfTables([t])
                node.order.append(last)
                current = t
            }
        } else {
            if let entry = node.children[last] {
                switch entry {
                case .table(let t):
                    if t.isInline { throw err("cannot redefine inline table '\(last)'", at: pos) }
                    if t.headerDefined { throw err("table '\(last)' redefined", at: pos) }
                    if t.closedForHeader { throw err("table '\(last)' already defined via dotted key", at: pos) }
                    t.headerDefined = true
                    current = t
                case .arrayOfTables:
                    throw err("'\(last)' is already defined as an array of tables", at: pos)
                case .value:
                    throw err("'\(last)' is already defined as a value", at: pos)
                }
            } else {
                let t = TOMLBuildTable()
                t.headerDefined = true
                node.children[last] = .table(t)
                node.order.append(last)
                current = t
            }
        }
    }

    /// Descends into (or implicitly creates) the intermediate table named
    /// `part` under `node`, following array-of-tables to their last element.
    private func step(
        into node: TOMLBuildTable, part: String, pos: (line: Int, column: Int), creatingClosed: Bool
    ) throws -> TOMLBuildTable {
        if let entry = node.children[part] {
            switch entry {
            case .table(let t):
                if t.isInline { throw err("cannot extend inline table '\(part)'", at: pos) }
                return t
            case .arrayOfTables(let arr):
                guard let last = arr.last else {
                    throw err("cannot extend empty array of tables '\(part)'", at: pos)
                }
                return last
            case .value:
                throw err("key '\(part)' is not a table", at: pos)
            }
        }
        let t = TOMLBuildTable()
        t.closedForHeader = creatingClosed
        node.children[part] = .table(t)
        node.order.append(part)
        return t
    }

    // MARK: Key/value lines

    private func parseKeyValueLine() throws {
        let keyPos = scanner.pos
        let parts = try parseDottedKey()
        skipSpacesTabsOnly()
        guard scanner.peek() == "=" else { throw err("expected '=' after key") }
        scanner.advance()
        skipSpacesTabsOnly()
        let valuePos = scanner.pos
        guard let vc = scanner.peek(), vc != "\n", vc != "\r" else {
            throw err("expected value", at: valuePos)
        }
        let value = try parseValue()
        try assign(parts, value, into: current, pos: keyPos)
        skipSpacesTabsOnly()
        if let c = scanner.peek() {
            if c == "#" {
                while let cc = scanner.peek(), cc != "\n" { scanner.advance() }
            } else if c == "\n" || c == "\r" {
                // fine
            } else {
                throw err("unexpected content after value")
            }
        }
    }

    private func assign(
        _ parts: [String], _ value: TOMLValue, into start: TOMLBuildTable, pos: (line: Int, column: Int)
    ) throws {
        var node = start
        for part in parts.dropLast() {
            node = try step(into: node, part: part, pos: pos, creatingClosed: true)
        }
        guard let last = parts.last else { throw err("empty key", at: pos) }
        if node.children[last] != nil {
            throw err("duplicate key '\(last)'", at: pos)
        }
        node.children[last] = .value(value)
        node.order.append(last)
    }

    // MARK: Keys

    private func parseDottedKey() throws -> [String] {
        var parts = [try parseSimpleKey()]
        while true {
            skipSpacesTabsOnly()
            if scanner.peek() == "." {
                scanner.advance()
                skipSpacesTabsOnly()
                parts.append(try parseSimpleKey())
            } else {
                break
            }
        }
        return parts
    }

    private func parseSimpleKey() throws -> String {
        guard let c = scanner.peek() else { throw err("expected key") }
        if c == "\"" { return try parseBasicStringLine() }
        if c == "'" { return try parseLiteralStringLine() }
        if isBareKeyChar(c) {
            var s = ""
            while let cc = scanner.peek(), isBareKeyChar(cc) {
                s.unicodeScalars.append(cc)
                scanner.advance()
            }
            return s
        }
        throw err("invalid key character")
    }

    private func isBareKeyChar(_ c: Unicode.Scalar) -> Bool {
        (c >= "a" && c <= "z") || (c >= "A" && c <= "Z") || (c >= "0" && c <= "9") || c == "-" || c == "_"
    }

    // MARK: Whitespace / comments

    private func skipSpacesTabsOnly() {
        while let c = scanner.peek(), c == " " || c == "\t" { scanner.advance() }
    }

    private func skipWhitespaceAndComments(acrossNewlines: Bool) {
        while true {
            skipSpacesTabsOnly()
            guard let c = scanner.peek() else { break }
            if c == "#" {
                while let cc = scanner.peek(), cc != "\n" { scanner.advance() }
                continue
            }
            if acrossNewlines, c == "\n" || c == "\r" {
                scanner.advance()
                continue
            }
            break
        }
    }

    // MARK: Values

    private func parseValue() throws -> TOMLValue {
        guard let c = scanner.peek() else { throw err("expected value") }
        switch c {
        case "\"":
            if scanner.peek(1) == "\"" && scanner.peek(2) == "\"" {
                return .string(try parseMultilineBasicString())
            }
            return .string(try parseBasicStringLine())
        case "'":
            if scanner.peek(1) == "'" && scanner.peek(2) == "'" {
                return .string(try parseMultilineLiteralString())
            }
            return .string(try parseLiteralStringLine())
        case "[":
            return try parseArray()
        case "{":
            return try parseInlineTable()
        default:
            return try parseLiteralToken()
        }
    }

    private func parseArray() throws -> TOMLValue {
        scanner.advance() // '['
        var items: [TOMLValue] = []
        skipWhitespaceAndComments(acrossNewlines: true)
        if scanner.peek() == "]" {
            scanner.advance()
            return .array(items)
        }
        while true {
            let v = try parseValue()
            items.append(v)
            skipWhitespaceAndComments(acrossNewlines: true)
            guard let c = scanner.peek() else { throw err("unterminated array") }
            if c == "," {
                scanner.advance()
                skipWhitespaceAndComments(acrossNewlines: true)
                if scanner.peek() == "]" {
                    scanner.advance()
                    return .array(items)
                }
                continue
            } else if c == "]" {
                scanner.advance()
                return .array(items)
            } else {
                throw err("expected ',' or ']' in array")
            }
        }
    }

    private func parseInlineTable() throws -> TOMLValue {
        scanner.advance() // '{'
        let node = TOMLBuildTable()
        node.isInline = true
        node.headerDefined = true
        skipSpacesTabsOnly()
        if scanner.peek() == "}" {
            scanner.advance()
            return .table(freeze(node))
        }
        while true {
            skipSpacesTabsOnly()
            if let c = scanner.peek(), c == "\n" || c == "\r" {
                throw err("newline not allowed in inline table")
            }
            let keyPos = scanner.pos
            let parts = try parseDottedKey()
            skipSpacesTabsOnly()
            guard scanner.peek() == "=" else { throw err("expected '=' after key") }
            scanner.advance()
            skipSpacesTabsOnly()
            guard let vc = scanner.peek(), vc != "\n", vc != "\r" else { throw err("expected value") }
            let value = try parseValue()
            try assign(parts, value, into: node, pos: keyPos)
            skipSpacesTabsOnly()
            guard let c = scanner.peek() else { throw err("unterminated inline table") }
            if c == "\n" || c == "\r" { throw err("newline not allowed in inline table") }
            if c == "," {
                scanner.advance()
                skipSpacesTabsOnly()
                if let cc = scanner.peek(), cc == "\n" || cc == "\r" {
                    throw err("newline not allowed in inline table")
                }
                if scanner.peek() == "}" {
                    throw err("trailing comma not allowed in inline table")
                }
                continue
            } else if c == "}" {
                scanner.advance()
                return .table(freeze(node))
            } else {
                throw err("expected ',' or '}' in inline table")
            }
        }
    }

    // MARK: Strings

    private func parseBasicStringLine() throws -> String {
        let startPos = scanner.pos
        scanner.advance() // opening quote
        var result = ""
        while true {
            guard let c = scanner.peek() else { throw err("unterminated string", at: startPos) }
            if c == "\"" {
                scanner.advance()
                return result
            }
            if c == "\n" || c == "\r" {
                throw err("unterminated string (newline in single-line string)", at: startPos)
            }
            if c == "\\" {
                scanner.advance()
                try appendEscape(to: &result, startPos: startPos)
                continue
            }
            result.unicodeScalars.append(c)
            scanner.advance()
        }
    }

    private func parseLiteralStringLine() throws -> String {
        let startPos = scanner.pos
        scanner.advance() // opening quote
        var result = ""
        while true {
            guard let c = scanner.peek() else { throw err("unterminated string", at: startPos) }
            if c == "'" {
                scanner.advance()
                return result
            }
            if c == "\n" || c == "\r" {
                throw err("unterminated string (newline in single-line string)", at: startPos)
            }
            result.unicodeScalars.append(c)
            scanner.advance()
        }
    }

    private func parseMultilineBasicString() throws -> String {
        let startPos = scanner.pos
        scanner.advance(); scanner.advance(); scanner.advance() // """
        trimLeadingNewline()
        var result = ""
        while true {
            guard let c = scanner.peek() else { throw err("unterminated multi-line string", at: startPos) }
            if c == "\\" {
                scanner.advance()
                if let e = scanner.peek(), e == " " || e == "\t" || e == "\n" || e == "\r" {
                    while let ws = scanner.peek(), ws == " " || ws == "\t" || ws == "\n" || ws == "\r" {
                        scanner.advance()
                    }
                    continue
                }
                try appendEscape(to: &result, startPos: startPos)
                continue
            }
            if c == "\"" {
                var count = 0
                while scanner.peek(count) == "\"" { count += 1 }
                if count >= 3 {
                    let literalCount = min(count - 3, 2)
                    for _ in 0..<literalCount {
                        result.unicodeScalars.append("\"")
                        scanner.advance()
                    }
                    scanner.advance(); scanner.advance(); scanner.advance()
                    return result
                } else {
                    for _ in 0..<count {
                        result.unicodeScalars.append("\"")
                        scanner.advance()
                    }
                    continue
                }
            }
            if c == "\r" && scanner.peek(1) == "\n" {
                result.unicodeScalars.append("\n")
                scanner.advance(); scanner.advance()
                continue
            }
            result.unicodeScalars.append(c)
            scanner.advance()
        }
    }

    private func parseMultilineLiteralString() throws -> String {
        let startPos = scanner.pos
        scanner.advance(); scanner.advance(); scanner.advance() // '''
        trimLeadingNewline()
        var result = ""
        while true {
            guard let c = scanner.peek() else { throw err("unterminated multi-line string", at: startPos) }
            if c == "'" {
                var count = 0
                while scanner.peek(count) == "'" { count += 1 }
                if count >= 3 {
                    let literalCount = min(count - 3, 2)
                    for _ in 0..<literalCount {
                        result.unicodeScalars.append("'")
                        scanner.advance()
                    }
                    scanner.advance(); scanner.advance(); scanner.advance()
                    return result
                } else {
                    for _ in 0..<count {
                        result.unicodeScalars.append("'")
                        scanner.advance()
                    }
                    continue
                }
            }
            if c == "\r" && scanner.peek(1) == "\n" {
                result.unicodeScalars.append("\n")
                scanner.advance(); scanner.advance()
                continue
            }
            result.unicodeScalars.append(c)
            scanner.advance()
        }
    }

    private func trimLeadingNewline() {
        if scanner.peek() == "\r" && scanner.peek(1) == "\n" {
            scanner.advance(); scanner.advance()
        } else if scanner.peek() == "\n" {
            scanner.advance()
        }
    }

    private func appendEscape(to result: inout String, startPos: (line: Int, column: Int)) throws {
        guard let e = scanner.peek() else { throw err("unterminated string", at: startPos) }
        switch e {
        case "b": result.append("\u{08}"); scanner.advance()
        case "t": result.append("\t"); scanner.advance()
        case "n": result.append("\n"); scanner.advance()
        case "f": result.append("\u{0C}"); scanner.advance()
        case "r": result.append("\r"); scanner.advance()
        case "\"": result.append("\""); scanner.advance()
        case "\\": result.append("\\"); scanner.advance()
        case "u":
            scanner.advance()
            let v = try readHex(count: 4)
            try appendScalar(v, to: &result)
        case "U":
            scanner.advance()
            let v = try readHex(count: 8)
            try appendScalar(v, to: &result)
        default:
            throw err("invalid escape sequence '\\\(e)'")
        }
    }

    private func readHex(count: Int) throws -> UInt32 {
        var v: UInt32 = 0
        for _ in 0..<count {
            guard let c = scanner.peek(), let d = hexDigitValue(c) else {
                throw err("invalid unicode escape")
            }
            v = v &* 16 &+ UInt32(d)
            scanner.advance()
        }
        return v
    }

    private func hexDigitValue(_ c: Unicode.Scalar) -> Int? {
        switch c {
        case "0"..."9": return Int(c.value - Unicode.Scalar("0").value)
        case "a"..."f": return Int(c.value - Unicode.Scalar("a").value) + 10
        case "A"..."F": return Int(c.value - Unicode.Scalar("A").value) + 10
        default: return nil
        }
    }

    private func appendScalar(_ v: UInt32, to result: inout String) throws {
        guard let scalar = Unicode.Scalar(v) else { throw err("invalid unicode scalar value") }
        result.unicodeScalars.append(scalar)
    }

    // MARK: Booleans / numbers / datetimes

    private func gatherToken() -> String {
        var s = ""
        while let c = scanner.peek(), !isTokenTerminator(c) {
            s.unicodeScalars.append(c)
            scanner.advance()
        }
        return s
    }

    private func isTokenTerminator(_ c: Unicode.Scalar) -> Bool {
        c == " " || c == "\t" || c == "\n" || c == "\r" || c == "," || c == "]" || c == "}" || c == "#"
    }

    private func parseLiteralToken() throws -> TOMLValue {
        let startPos = scanner.pos
        let token1 = gatherToken()
        guard !token1.isEmpty else { throw err("expected value", at: startPos) }
        if token1 == "true" { return .boolean(true) }
        if token1 == "false" { return .boolean(false) }

        let chars1 = Array(token1.unicodeScalars)
        if looksLikeDate(chars1) {
            if scanner.peek() == " ", let n = scanner.peek(1), isDigitScalar(n) {
                let save = (scanner.idx, scanner.line, scanner.col)
                scanner.advance() // space
                let token2 = gatherToken()
                let chars2 = Array(token2.unicodeScalars)
                if looksLikeTimeStart(chars2) {
                    return .datetime(token1 + " " + token2)
                }
                scanner.idx = save.0
                scanner.line = save.1
                scanner.col = save.2
            }
            return .datetime(token1)
        }
        if isDateTimeToken(chars1) {
            return .datetime(token1)
        }
        if let n = parseNumber(token1) {
            return n
        }
        throw err("invalid value '\(token1)'", at: startPos)
    }
}

// MARK: - Freestanding helpers

private func isDigitScalar(_ c: Unicode.Scalar) -> Bool { c >= "0" && c <= "9" }

private func looksLikeDate(_ s: [Unicode.Scalar]) -> Bool {
    guard s.count == 10 else { return false }
    return isDigitScalar(s[0]) && isDigitScalar(s[1]) && isDigitScalar(s[2]) && isDigitScalar(s[3])
        && s[4] == "-" && isDigitScalar(s[5]) && isDigitScalar(s[6])
        && s[7] == "-" && isDigitScalar(s[8]) && isDigitScalar(s[9])
}

private func looksLikeTimeStart(_ s: [Unicode.Scalar]) -> Bool {
    guard s.count >= 8 else { return false }
    return isDigitScalar(s[0]) && isDigitScalar(s[1]) && s[2] == ":"
        && isDigitScalar(s[3]) && isDigitScalar(s[4]) && s[5] == ":"
        && isDigitScalar(s[6]) && isDigitScalar(s[7])
}

/// Loose datetime/date/time detector: any token starting with a digit that
/// contains a colon, or a dash not in the sign position, and otherwise only
/// characters legal in RFC 3339-ish lexemes.
private func isDateTimeToken(_ chars: [Unicode.Scalar]) -> Bool {
    guard let first = chars.first, isDigitScalar(first) else { return false }
    var sawColon = false
    var sawInnerDash = false
    for (i, c) in chars.enumerated() {
        switch c {
        case "0"..."9": continue
        case ":": sawColon = true
        case "-": if i > 0 { sawInnerDash = true }
        case ".", "T", "t", "Z", "z", "+": continue
        default: return false
        }
    }
    return sawColon || sawInnerDash
}

private func isValidUnderscoreGrouping(_ s: String) -> Bool {
    let chars = Array(s)
    for (i, c) in chars.enumerated() where c == "_" {
        guard i > 0, i < chars.count - 1 else { return false }
        guard chars[i - 1].isNumber, chars[i + 1].isNumber else { return false }
    }
    return true
}

/// Validates digits (and `_` grouping) for a radix-prefixed integer body.
/// Every character must be a valid digit for `radix`; underscores must sit
/// strictly between two valid digits. This rejects stray `+`/`-` signs,
/// which TOML disallows after `0x`/`0o`/`0b` prefixes.
private func isValidRadixDigits(_ s: String, radix: Int) -> Bool {
    let chars = Array(s)
    guard !chars.isEmpty else { return false }
    func isDigit(_ c: Character) -> Bool {
        switch radix {
        case 16: return c.isHexDigit
        case 8: return ("0"..."7").contains(c)
        case 2: return c == "0" || c == "1"
        default: return false
        }
    }
    for (i, c) in chars.enumerated() {
        if c == "_" {
            guard i > 0, i < chars.count - 1 else { return false }
            guard isDigit(chars[i - 1]), isDigit(chars[i + 1]) else { return false }
        } else {
            guard isDigit(c) else { return false }
        }
    }
    return true
}

/// Validates the TOML float grammar on an already underscore-stripped,
/// sign-stripped numeric body: `(0|[1-9][0-9]*)(\.[0-9]+)?([eE][+-]?[0-9]+)?`.
/// This rejects malformed literals like `7.` (missing fraction digits) and
/// `3.e+20` (dot with no digit before the exponent).
private func isValidFloatLiteral(_ cleaned: String) -> Bool {
    let pattern = #"^(0|[1-9][0-9]*)(\.[0-9]+)?([eE][+-]?[0-9]+)?$"#
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return false }
    let range = NSRange(cleaned.startIndex..., in: cleaned)
    guard let match = regex.firstMatch(in: cleaned, range: range) else { return false }
    return match.range == range
}

/// Parses a bare numeric/inf/nan token (sign already part of `raw`, no
/// surrounding whitespace). Returns `nil` on any malformed input rather than
/// trapping.
private func parseNumber(_ raw: String) -> TOMLValue? {
    guard !raw.isEmpty else { return nil }
    var s = raw
    var negative = false
    var hadSign = false
    if s.hasPrefix("+") {
        s.removeFirst()
        hadSign = true
    } else if s.hasPrefix("-") {
        s.removeFirst()
        negative = true
        hadSign = true
    }
    guard !s.isEmpty else { return nil }

    if s == "inf" { return .float(negative ? -Double.infinity : Double.infinity) }
    if s == "nan" { return .float(Double.nan) }

    if s.hasPrefix("0x") || s.hasPrefix("0o") || s.hasPrefix("0b") {
        guard !hadSign else { return nil }
        let radixChar = s[s.index(s.startIndex, offsetBy: 1)]
        let digitsPart = String(s.dropFirst(2))
        let radix: Int
        switch radixChar {
        case "x": radix = 16
        case "o": radix = 8
        case "b": radix = 2
        default: return nil
        }
        guard isValidRadixDigits(digitsPart, radix: radix) else { return nil }
        let cleaned = digitsPart.replacingOccurrences(of: "_", with: "")
        guard !cleaned.isEmpty else { return nil }
        guard let v = Int64(cleaned, radix: radix) else { return nil }
        return .integer(v)
    }

    let isFloat = s.contains(".") || s.contains("e") || s.contains("E")
    guard isValidUnderscoreGrouping(s) else { return nil }
    let cleaned = s.replacingOccurrences(of: "_", with: "")
    guard !cleaned.isEmpty else { return nil }

    if isFloat {
        guard isValidFloatLiteral(cleaned) else { return nil }
        guard let d = Double(cleaned) else { return nil }
        return .float(negative ? -d : d)
    } else {
        guard cleaned.allSatisfy({ $0.isNumber }) else { return nil }
        if cleaned.count > 1 && cleaned.first == "0" { return nil }
        guard let magnitude = UInt64(cleaned) else { return nil }
        if negative {
            if magnitude == UInt64(Int64.max) + 1 { return .integer(Int64.min) }
            guard let v = Int64(exactly: magnitude) else { return nil }
            return .integer(-v)
        }
        guard let v = Int64(exactly: magnitude) else { return nil }
        return .integer(v)
    }
}

// MARK: - Freezing

private func freeze(_ node: TOMLBuildTable) -> TOMLTable {
    var table = TOMLTable()
    for key in node.order {
        guard let entry = node.children[key] else { continue }
        switch entry {
        case .value(let v):
            table.set(key, v)
        case .table(let t):
            table.set(key, .table(freeze(t)))
        case .arrayOfTables(let arr):
            table.set(key, .array(arr.map { .table(freeze($0)) }))
        }
    }
    return table
}
