import Foundation

/// A TOML value the editor knows how to serialize. Scalars only, plus the
/// one inline-table shape (`gaps = { inner = 8, outer = 8 }`) the config
/// format uses.
public enum ConfigValue: Equatable, Sendable {
    case string(String)
    case integer(Int)
    case float(Double)
    case bool(Bool)
    case inlineTable([ConfigField])
}

public struct ConfigField: Equatable, Sendable {
    public var key: String
    public var value: ConfigValue

    public init(_ key: String, _ value: ConfigValue) {
        self.key = key
        self.value = value
    }
}

/// A table this editor can address. `.space`/`.rule` resolve to a specific
/// `[[space]]`/`[[rule]]` block by parsing the document with `TOML.parse`.
public enum ConfigSection: Hashable, Sendable {
    case settings
    case animation
    case focusFlash
    case layout
    case space(SpaceKey)
    case rule(Int)
    case bindings
}

public struct ConfigEditError: Error, Equatable, CustomStringConvertible {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}

/// Format-preserving, line-oriented editor over a TOML config document.
/// Every mutation keeps everything it doesn't touch byte-identical: other
/// keys, comments, blank lines, and ordering.
public struct ConfigEditor: Sendable {
    public private(set) var text: String

    public init(text: String) {
        self.text = text
    }

    // MARK: - Public API

    @discardableResult
    public mutating func set(_ key: String, _ value: ConfigValue?, in section: ConfigSection) -> Result<Void, ConfigEditError> {
        var lines = splitLines(text)
        guard let blocks = try? parseBlocks(lines) else {
            return .failure(ConfigEditError("could not parse document"))
        }
        guard let target = resolveSectionRange(section, blocks: blocks, lines: lines) else {
            switch section {
            case .rule:
                return .failure(ConfigEditError("rule does not exist"))
            default:
                break
            }
            // Section missing: create it, then retry the set inside it.
            switch createSection(section, lines: &lines) {
            case .failure(let e): return .failure(e)
            case .success: break
            }
            guard let blocks2 = try? parseBlocks(lines),
                  let target2 = resolveSectionRange(section, blocks: blocks2, lines: lines) else {
                return .failure(ConfigEditError("failed to create section"))
            }
            let result = setKey(key, value, bodyStart: target2.bodyStart, bodyEnd: target2.bodyEnd, lines: &lines)
            if case .success = result { text = joinLines(lines) }
            return result
        }
        let result = setKey(key, value, bodyStart: target.bodyStart, bodyEnd: target.bodyEnd, lines: &lines)
        if case .success = result { text = joinLines(lines) }
        return result
    }

    public func value(_ key: String, in section: ConfigSection) -> ConfigValue? {
        let lines = splitLines(text)
        guard let blocks = try? parseBlocks(lines),
              let target = resolveSectionRange(section, blocks: blocks, lines: lines) else { return nil }
        guard let span = findKeyLineSpan(key, bodyStart: target.bodyStart, bodyEnd: target.bodyEnd, lines: lines) else { return nil }
        let raw = valueText(onLines: lines, span: span, key: key)
        guard let raw else { return nil }
        return parseScalarValue(raw)
    }

    @discardableResult
    public mutating func appendRule(_ fields: [ConfigField]) -> Result<Int, ConfigEditError> {
        var lines = splitLines(text)
        guard let blocks = try? parseBlocks(lines) else {
            return .failure(ConfigEditError("could not parse document"))
        }
        let ruleBlocks = blocks.filter { $0.header?.tableKind == "rule" }
        let insertAfterLine: Int
        var needsBlankBefore = false
        if let last = ruleBlocks.last {
            insertAfterLine = contentEnd(last, lines: lines)
            needsBlankBefore = true
        } else if let bindingsBlock = blocks.first(where: { $0.header?.normalizedPath == "bindings" && $0.header?.isArrayTable == false }) {
            insertAfterLine = bindingsBlock.headerLine - 1
            needsBlankBefore = false
        } else {
            insertAfterLine = lines.count
            needsBlankBefore = !lines.isEmpty && !(lines.last?.trimmingCharacters(in: .whitespaces).isEmpty ?? true)
        }
        var newLines: [String] = []
        if needsBlankBefore { newLines.append("") }
        newLines.append("[[rule]]")
        for field in fields {
            newLines.append(renderKeyValue(field.key, field.value))
        }
        if !needsBlankBefore, insertAfterLine < lines.count {
            newLines.append("")
        }
        insert(newLines, after: insertAfterLine, lines: &lines)
        text = joinLines(lines)
        let newIndex = ruleBlocks.count
        return .success(newIndex)
    }

    @discardableResult
    public mutating func removeRule(at index: Int) -> Result<Void, ConfigEditError> {
        var lines = splitLines(text)
        guard let blocks = try? parseBlocks(lines) else {
            return .failure(ConfigEditError("could not parse document"))
        }
        let ruleBlocks = blocks.filter { $0.header?.tableKind == "rule" }
        guard index >= 0, index < ruleBlocks.count else {
            return .failure(ConfigEditError("rule index \(index) out of range"))
        }
        let block = ruleBlocks[index]
        let (start, end) = blockRangeWithLeadingComment(block, allBlocks: blocks, lines: lines)
        removeLineRange(start...end, lines: &lines)
        text = joinLines(lines)
        return .success(())
    }

    @discardableResult
    public mutating func moveRule(from: Int, to: Int) -> Result<Void, ConfigEditError> {
        let lines = splitLines(text)
        guard let blocks = try? parseBlocks(lines) else {
            return .failure(ConfigEditError("could not parse document"))
        }
        let ruleBlocks = blocks.filter { $0.header?.tableKind == "rule" }
        guard from >= 0, from < ruleBlocks.count, to >= 0, to < ruleBlocks.count else {
            return .failure(ConfigEditError("rule index out of range"))
        }
        if from == to { return .success(()) }

        let fromBlock = ruleBlocks[from]
        let (fromStart, fromEnd) = blockRangeWithLeadingComment(fromBlock, allBlocks: blocks, lines: lines)
        let movedLines = Array(lines[(fromStart - 1)...(fromEnd - 1)])

        // Remove the moved block first, tracking line-number shift.
        var working = lines
        removeLineRange(fromStart...fromEnd, lines: &working)
        let removedCount = fromEnd - fromStart + 1

        guard let blocks2 = try? parseBlocks(working) else {
            return .failure(ConfigEditError("failed to move rule"))
        }
        let ruleBlocks2 = blocks2.filter { $0.header?.tableKind == "rule" }
        // Determine insertion point in the post-removal document.
        let insertAfterLine: Int
        if to >= ruleBlocks2.count {
            // Insert after the (new) last rule.
            if let last = ruleBlocks2.last {
                insertAfterLine = contentEnd(last, lines: working)
            } else {
                insertAfterLine = working.count
            }
        } else {
            // Insert before rule `to` in the post-removal doc.
            let target = ruleBlocks2[to]
            let (targetStart, _) = blockRangeWithLeadingComment(target, allBlocks: blocks2, lines: working)
            insertAfterLine = targetStart - 1
        }
        var newLines = movedLines
        // Drop trailing blank line artifacts from moved block? keep as-is (only header+fields, comment lines).
        _ = removedCount
        insert(newLines, after: insertAfterLine, lines: &working)
        text = joinLines(working)
        newLines = []
        return .success(())
    }

    @discardableResult
    public mutating func removeSpace(_ key: SpaceKey) -> Result<Void, ConfigEditError> {
        var lines = splitLines(text)
        guard let blocks = try? parseBlocks(lines) else {
            return .failure(ConfigEditError("could not parse document"))
        }
        guard let block = findSpaceBlock(key, blocks: blocks, lines: lines) else {
            return .success(())
        }
        let (start, end) = blockRangeWithLeadingComment(block, allBlocks: blocks, lines: lines)
        removeLineRange(start...end, lines: &lines)
        text = joinLines(lines)
        return .success(())
    }

    public func validated() -> Result<Config, ConfigError> {
        Config.parse(text)
    }

    // MARK: - Line model

    private func splitLines(_ text: String) -> [String] {
        if text.isEmpty { return [] }
        var lines = text.components(separatedBy: "\n")
        // Preserve a trailing newline as an implicit property, not a phantom
        // empty final element, unless the source really ends with a blank line.
        if lines.last == "" { lines.removeLast() }
        return lines
    }

    private func joinLines(_ lines: [String]) -> String {
        lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n"
    }

    // MARK: - Block model (1-based line numbers throughout)

    private struct HeaderInfo {
        let path: [String]
        let isArrayTable: Bool
        var normalizedPath: String { path.joined(separator: ".") }
        var tableKind: String { path.first ?? "" }
    }

    private struct Block {
        let header: HeaderInfo?
        let headerLine: Int // 1-based line of the header, 0 if this is the preamble (no header)
        let bodyStart: Int // first line of key/values (headerLine + 1)
        let bodyEnd: Int // last line before the next header (inclusive), or lines.count
        var endLine: Int { bodyEnd }
    }

    /// Splits the document into blocks at table headers. Each block's body
    /// spans from just after its header to just before the next header.
    private func parseBlocks(_ lines: [String]) throws -> [Block] {
        var blocks: [Block] = []
        var currentHeader: HeaderInfo?
        var currentHeaderLine = 0
        var bodyStart = 1
        var i = 0
        while i < lines.count {
            let lineNo = i + 1
            if let header = parseHeaderLine(lines[i]) {
                blocks.append(Block(header: currentHeader, headerLine: currentHeaderLine, bodyStart: bodyStart, bodyEnd: lineNo - 1))
                currentHeader = header
                currentHeaderLine = lineNo
                bodyStart = lineNo + 1
            }
            i += 1
        }
        blocks.append(Block(header: currentHeader, headerLine: currentHeaderLine, bodyStart: bodyStart, bodyEnd: lines.count))
        return blocks
    }

    /// Parses a `[x.y]` / `[[x.y]]` header line, tolerating leading
    /// whitespace and a trailing comment. Returns nil for anything else.
    private func parseHeaderLine(_ line: String) -> HeaderInfo? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("[") else { return nil }
        var isArray = false
        var body = trimmed
        if body.hasPrefix("[[") {
            isArray = true
            body.removeFirst(2)
        } else {
            body.removeFirst(1)
        }
        // Find the matching closing bracket(s), ignoring anything inside quotes.
        guard let closeInfo = findHeaderClose(body, isArray: isArray) else { return nil }
        let inner = String(body[body.startIndex..<closeInfo])
        let parts = splitDottedKey(inner)
        guard !parts.isEmpty else { return nil }
        return HeaderInfo(path: parts, isArrayTable: isArray)
    }

    private func findHeaderClose(_ body: String, isArray: Bool) -> String.Index? {
        var inSingle = false
        var inDouble = false
        var idx = body.startIndex
        while idx < body.endIndex {
            let c = body[idx]
            if inSingle {
                if c == "'" { inSingle = false }
            } else if inDouble {
                if c == "\\" {
                    idx = body.index(after: idx)
                    if idx >= body.endIndex { break }
                } else if c == "\"" { inDouble = false }
            } else {
                if c == "'" { inSingle = true }
                else if c == "\"" { inDouble = true }
                else if c == "]" { return idx }
            }
            idx = body.index(after: idx)
        }
        return nil
    }

    /// Splits a dotted key path (`a.b."c.d"`) into components, honoring
    /// quoted segments. Malformed input yields an empty result.
    private func splitDottedKey(_ s: String) -> [String] {
        var parts: [String] = []
        var current = ""
        var inSingle = false
        var inDouble = false
        var idx = s.startIndex
        while idx < s.endIndex {
            let c = s[idx]
            if inSingle {
                if c == "'" { inSingle = false } else { current.append(c) }
            } else if inDouble {
                if c == "\\" {
                    idx = s.index(after: idx)
                    if idx < s.endIndex { current.append(s[idx]) }
                } else if c == "\"" { inDouble = false } else { current.append(c) }
            } else if c == "'" {
                inSingle = true
            } else if c == "\"" {
                inDouble = true
            } else if c == "." {
                parts.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            } else {
                current.append(c)
            }
            idx = s.index(after: idx)
        }
        parts.append(current.trimmingCharacters(in: .whitespaces))
        return parts.filter { !$0.isEmpty }
    }

    // MARK: - Section resolution

    private struct SectionRange {
        let bodyStart: Int
        let bodyEnd: Int
    }

    private func resolveSectionRange(_ section: ConfigSection, blocks: [Block], lines: [String]) -> SectionRange? {
        switch section {
        case .settings:
            return blocks.first { $0.header?.normalizedPath == "settings" && $0.header?.isArrayTable == false }
                .map { SectionRange(bodyStart: $0.bodyStart, bodyEnd: $0.bodyEnd) }
        case .animation:
            return blocks.first { $0.header?.normalizedPath == "settings.animation" && $0.header?.isArrayTable == false }
                .map { SectionRange(bodyStart: $0.bodyStart, bodyEnd: $0.bodyEnd) }
        case .focusFlash:
            return blocks.first { $0.header?.normalizedPath == "settings.focus_flash" && $0.header?.isArrayTable == false }
                .map { SectionRange(bodyStart: $0.bodyStart, bodyEnd: $0.bodyEnd) }
        case .layout:
            return blocks.first { $0.header?.normalizedPath == "layout" && $0.header?.isArrayTable == false }
                .map { SectionRange(bodyStart: $0.bodyStart, bodyEnd: $0.bodyEnd) }
        case .bindings:
            return blocks.first { $0.header?.normalizedPath == "bindings" && $0.header?.isArrayTable == false }
                .map { SectionRange(bodyStart: $0.bodyStart, bodyEnd: $0.bodyEnd) }
        case .space(let key):
            guard let block = findSpaceBlock(key, blocks: blocks, lines: lines) else { return nil }
            return SectionRange(bodyStart: block.bodyStart, bodyEnd: block.bodyEnd)
        case .rule(let index):
            let ruleBlocks = blocks.filter { $0.header?.tableKind == "rule" }
            guard index >= 0, index < ruleBlocks.count else { return nil }
            let block = ruleBlocks[index]
            return SectionRange(bodyStart: block.bodyStart, bodyEnd: block.bodyEnd)
        }
    }

    private func findSpaceBlock(_ key: SpaceKey, blocks: [Block], lines: [String]) -> Block? {
        let spaceBlocks = blocks.filter { $0.header?.tableKind == "space" && $0.header?.isArrayTable == true }
        for block in spaceBlocks {
            let bodyText = lines[(block.bodyStart - 1)..<max(block.bodyStart - 1, min(block.bodyEnd, lines.count))].joined(separator: "\n")
            guard let t = try? TOML.parse(bodyText) else { continue }
            guard case .string(let display)? = t["display"] else { continue }
            let ordinal: Int?
            switch t["ordinal"] {
            case .integer(let i)?: ordinal = Int(i)
            default: ordinal = nil
            }
            guard let ordinal else { continue }
            if display.uppercased() == key.display.uppercased() && ordinal == key.ordinal {
                return block
            }
        }
        return nil
    }

    // MARK: - Section creation

    private mutating func createSection(_ section: ConfigSection, lines: inout [String]) -> Result<Void, ConfigEditError> {
        switch section {
        case .rule:
            return .failure(ConfigEditError("rule section is not creatable; use appendRule"))
        case .settings:
            insertSectionHeader("[settings]", before: firstLineIndex(lines), lines: &lines)
            return .success(())
        case .animation, .focusFlash:
            // A [settings.*] subtable goes right after the last existing one, else after [settings].
            let header = section == .animation ? "[settings.animation]" : "[settings.focus_flash]"
            guard let blocks = try? parseBlocks(lines) else { return .failure(ConfigEditError("could not parse document")) }
            if let anchor = lastSettingsBlock(blocks) {
                insertBlockAfter(anchor, header: header, blocks: blocks, lines: &lines)
            } else {
                // Create [settings] first, then the subtable right after.
                insertSectionHeader("[settings]", before: firstLineIndex(lines), lines: &lines)
                guard let blocks2 = try? parseBlocks(lines), let anchor2 = lastSettingsBlock(blocks2) else {
                    return .failure(ConfigEditError("failed to create \(header)"))
                }
                insertBlockAfter(anchor2, header: header, blocks: blocks2, lines: &lines)
            }
            return .success(())
        case .layout:
            guard let blocks = try? parseBlocks(lines) else { return .failure(ConfigEditError("could not parse document")) }
            if let anchor = lastSettingsBlock(blocks) {
                insertBlockAfter(anchor, header: "[layout]", blocks: blocks, lines: &lines)
            } else {
                insertSectionHeader("[layout]", before: firstLineIndex(lines), lines: &lines)
            }
            return .success(())
        case .bindings:
            var newLines: [String] = []
            if !lines.isEmpty { newLines.append("") }
            newLines.append("[bindings]")
            insert(newLines, after: lines.count, lines: &lines)
            return .success(())
        case .space(let key):
            guard let blocks = try? parseBlocks(lines) else { return .failure(ConfigEditError("could not parse document")) }
            let spaceBlocks = blocks.filter { $0.header?.tableKind == "space" && $0.header?.isArrayTable == true }
            var body = ["[[space]]", "display = \(renderScalar(.string(key.display.uppercased())))", "ordinal = \(key.ordinal)"]
            if let last = spaceBlocks.last {
                var newLines: [String] = ["", body.removeFirst()]
                newLines.append(contentsOf: body)
                insert(newLines, after: contentEnd(last, lines: lines), lines: &lines)
            } else if let ruleBlocks = firstRuleHeaderLine(blocks) {
                var newLines = body
                newLines.append("")
                insert(newLines, after: ruleBlocks - 1, lines: &lines)
            } else if let bindingsBlock = blocks.first(where: { $0.header?.normalizedPath == "bindings" && $0.header?.isArrayTable == false }) {
                var newLines = body
                newLines.append("")
                insert(newLines, after: bindingsBlock.headerLine - 1, lines: &lines)
            } else {
                var newLines: [String] = []
                if !lines.isEmpty { newLines.append("") }
                newLines.append(contentsOf: body)
                insert(newLines, after: lines.count, lines: &lines)
            }
            return .success(())
        }
    }

    private func firstRuleHeaderLine(_ blocks: [Block]) -> Int? {
        blocks.first { $0.header?.tableKind == "rule" }?.headerLine
    }

    /// The last `[settings]` or `[settings.*]` table in the document.
    private func lastSettingsBlock(_ blocks: [Block]) -> Block? {
        blocks.last { block in
            guard let header = block.header, !header.isArrayTable else { return false }
            return header.normalizedPath == "settings" || header.normalizedPath.hasPrefix("settings.")
        }
    }

    private func firstLineIndex(_ lines: [String]) -> Int { 1 }

    private mutating func insertSectionHeader(_ header: String, before lineIndex: Int, lines: inout [String]) {
        var newLines = [header]
        if !lines.isEmpty { newLines.append("") }
        insert(newLines, after: 0, lines: &lines)
    }

    private mutating func insertBlockAfter(_ block: Block, header: String, blocks: [Block], lines: inout [String]) {
        var newLines: [String] = ["", header]
        insert(newLines, after: contentEnd(block, lines: lines), lines: &lines)
        newLines = []
    }

    // MARK: - Line insertion / removal primitives (1-based, `after` = 0 means at start)

    private func insert(_ newLines: [String], after lineNo: Int, lines: inout [String]) {
        let idx = max(0, min(lineNo, lines.count))
        lines.insert(contentsOf: newLines, at: idx)
    }

    private func removeLineRange(_ range: ClosedRange<Int>, lines: inout [String]) {
        let lower = max(0, range.lowerBound - 1)
        let upper = min(lines.count, range.upperBound)
        guard lower < upper else { return }
        lines.removeSubrange(lower..<upper)
    }

    // MARK: - Key/value editing

    private struct KeySpan {
        let keyLineIndex: Int // 1-based line the key= starts on
        let valueEndLineIndex: Int // 1-based last line of the value (may equal keyLineIndex)
        let commentColumn: Int? // column (0-based) of trailing `#` on valueEndLineIndex, if any
        let indent: String
    }

    private mutating func setKey(_ key: String, _ value: ConfigValue?, bodyStart: Int, bodyEnd: Int, lines: inout [String]) -> Result<Void, ConfigEditError> {
        if let span = findKeyLineSpan(key, bodyStart: bodyStart, bodyEnd: bodyEnd, lines: lines) {
            if let value {
                replaceValue(key, value, span: span, lines: &lines)
            } else {
                removeKeyLines(span, lines: &lines)
            }
            return .success(())
        } else {
            guard let value else { return .success(()) } // removing an absent key is a no-op
            insertKey(key, value, bodyStart: bodyStart, bodyEnd: bodyEnd, lines: &lines)
            return .success(())
        }
    }

    /// Scans the body for a top-level `key =` line, correctly skipping over
    /// multi-line values (arrays, inline tables spanning lines, multi-line
    /// strings) that belong to *other* keys, using bracket/string-state
    /// tracking rather than regex.
    private func findKeyLineSpan(_ key: String, bodyStart: Int, bodyEnd: Int, lines: [String]) -> KeySpan? {
        var i = bodyStart
        while i <= bodyEnd, i <= lines.count {
            let line = lines[i - 1]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") {
                i += 1
                continue
            }
            guard let (foundKey, indent, afterEquals) = parseKeyLine(line) else {
                i += 1
                continue
            }
            let valueEnd = scanValueExtent(startLine: i, afterEquals: afterEquals, lines: lines, bodyEnd: bodyEnd)
            if foundKey == key {
                let commentCol = trailingCommentColumn(lines[valueEnd - 1])
                return KeySpan(keyLineIndex: i, valueEndLineIndex: valueEnd, commentColumn: commentCol, indent: indent)
            }
            i = valueEnd + 1
        }
        return nil
    }

    /// Parses a `key = ...` line start (bare/basic/literal key), returning
    /// the decoded key, its leading indent, and the column right after `=`.
    private func parseKeyLine(_ line: String) -> (key: String, indent: String, afterEquals: String.Index)? {
        var idx = line.startIndex
        let indentStart = idx
        while idx < line.endIndex, line[idx] == " " || line[idx] == "\t" { idx = line.index(after: idx) }
        let indent = String(line[indentStart..<idx])
        guard idx < line.endIndex else { return nil }
        var key = ""
        if line[idx] == "\"" || line[idx] == "'" {
            let quote = line[idx]
            idx = line.index(after: idx)
            while idx < line.endIndex, line[idx] != quote {
                if quote == "\"" && line[idx] == "\\" {
                    key.append(line[idx])
                    idx = line.index(after: idx)
                    if idx >= line.endIndex { return nil }
                }
                key.append(line[idx])
                idx = line.index(after: idx)
            }
            guard idx < line.endIndex else { return nil }
            idx = line.index(after: idx) // past closing quote
            if quote == "\"" { key = unescapeBasicString(key) }
        } else {
            guard isBareKeyStart(line[idx]) else { return nil }
            let start = idx
            while idx < line.endIndex, isBareKeyChar(line[idx]) { idx = line.index(after: idx) }
            key = String(line[start..<idx])
        }
        while idx < line.endIndex, line[idx] == " " || line[idx] == "\t" { idx = line.index(after: idx) }
        guard idx < line.endIndex, line[idx] == "=" else { return nil }
        idx = line.index(after: idx)
        return (key, indent, idx)
    }

    private func isBareKeyStart(_ c: Character) -> Bool {
        c.isLetter || c.isNumber || c == "_" || c == "-"
    }
    private func isBareKeyChar(_ c: Character) -> Bool { isBareKeyStart(c) }

    /// Scans forward from the start of a value (right after `=` on
    /// `startLine`) tracking bracket depth and string state across lines,
    /// returning the 1-based line the value's last token ends on.
    private func scanValueExtent(startLine: Int, afterEquals: String.Index, lines: [String], bodyEnd: Int) -> Int {
        var depth = 0
        var inSingle = false
        var inDouble = false
        var inTripleSingle = false
        var inTripleDouble = false
        var line = startLine
        var idx = afterEquals
        var sawValueContent = false

        func currentLine() -> String { line <= lines.count ? lines[line - 1] : "" }

        while true {
            let text = currentLine()
            if idx > text.endIndex { idx = text.endIndex }
            while idx < text.endIndex {
                let c = text[idx]
                if inTripleSingle {
                    if c == "'" && matchesTriple(text, idx, "'") {
                        inTripleSingle = false
                        idx = text.index(idx, offsetBy: 3, limitedBy: text.endIndex) ?? text.endIndex
                        continue
                    }
                } else if inTripleDouble {
                    if c == "\\" {
                        idx = text.index(after: idx)
                        if idx >= text.endIndex { break }
                    } else if c == "\"" && matchesTriple(text, idx, "\"") {
                        inTripleDouble = false
                        idx = text.index(idx, offsetBy: 3, limitedBy: text.endIndex) ?? text.endIndex
                        continue
                    }
                } else if inSingle {
                    if c == "'" { inSingle = false }
                } else if inDouble {
                    if c == "\\" {
                        idx = text.index(after: idx)
                        if idx >= text.endIndex { break }
                    } else if c == "\"" { inDouble = false }
                } else {
                    if c == "#" { idx = text.endIndex; break }
                    if c == "'" {
                        if matchesTriple(text, idx, "'") { inTripleSingle = true; sawValueContent = true; idx = text.index(idx, offsetBy: 2, limitedBy: text.endIndex) ?? text.endIndex }
                        else { inSingle = true; sawValueContent = true }
                    } else if c == "\"" {
                        if matchesTriple(text, idx, "\"") { inTripleDouble = true; sawValueContent = true; idx = text.index(idx, offsetBy: 2, limitedBy: text.endIndex) ?? text.endIndex }
                        else { inDouble = true; sawValueContent = true }
                    } else if c == "[" || c == "{" {
                        depth += 1
                        sawValueContent = true
                    } else if c == "]" || c == "}" {
                        depth -= 1
                        sawValueContent = true
                    } else if !c.isWhitespace {
                        sawValueContent = true
                    }
                }
                idx = text.index(after: idx)
            }
            let stillOpen = depth > 0 || inSingle || inDouble || inTripleSingle || inTripleDouble
            if !stillOpen { return line }
            if line >= bodyEnd || line >= lines.count { return line }
            line += 1
            idx = lines[line - 1].startIndex
            _ = sawValueContent
        }
    }

    private func matchesTriple(_ text: String, _ idx: String.Index, _ ch: Character) -> Bool {
        guard let i1 = text.index(idx, offsetBy: 1, limitedBy: text.endIndex),
              let i2 = text.index(idx, offsetBy: 2, limitedBy: text.endIndex),
              i1 < text.endIndex, i2 < text.endIndex else { return false }
        return text[i1] == ch && text[i2] == ch
    }

    private func unescapeBasicString(_ s: String) -> String {
        var result = ""
        var idx = s.startIndex
        while idx < s.endIndex {
            if s[idx] == "\\" {
                idx = s.index(after: idx)
                if idx >= s.endIndex { break }
                switch s[idx] {
                case "n": result.append("\n")
                case "t": result.append("\t")
                case "\"": result.append("\"")
                case "\\": result.append("\\")
                default: result.append(s[idx])
                }
            } else {
                result.append(s[idx])
            }
            idx = s.index(after: idx)
        }
        return result
    }

    private func trailingCommentColumn(_ line: String) -> Int? {
        var inSingle = false
        var inDouble = false
        var col = 0
        var idx = line.startIndex
        while idx < line.endIndex {
            let c = line[idx]
            if inSingle {
                if c == "'" { inSingle = false }
            } else if inDouble {
                if c == "\\" { idx = line.index(after: idx); col += 1; if idx >= line.endIndex { break } }
                else if c == "\"" { inDouble = false }
            } else if c == "'" {
                inSingle = true
            } else if c == "\"" {
                inDouble = true
            } else if c == "#" {
                return col
            }
            idx = line.index(after: idx)
            col += 1
        }
        return nil
    }

    /// Extracts the raw value substring (post `=`, pre trailing comment) for
    /// a span that may run across multiple lines; multi-line values return
    /// nil (only single-line scalars/inline-tables are representable).
    private func valueText(onLines lines: [String], span: KeySpan, key: String) -> String? {
        guard span.keyLineIndex == span.valueEndLineIndex else { return nil }
        let line = lines[span.keyLineIndex - 1]
        guard let (_, _, afterEquals) = parseKeyLine(line) else { return nil }
        var end = line.endIndex
        if let col = span.commentColumn {
            end = line.index(line.startIndex, offsetBy: col, limitedBy: line.endIndex) ?? line.endIndex
        }
        guard afterEquals <= end else { return nil }
        return String(line[afterEquals..<end]).trimmingCharacters(in: .whitespaces)
    }

    private func parseScalarValue(_ raw: String) -> ConfigValue? {
        guard let table = try? TOML.parse("v = \(raw)") else { return nil }
        guard let v = table["v"] else { return nil }
        return toConfigValue(v)
    }

    private func toConfigValue(_ v: TOMLValue) -> ConfigValue? {
        switch v {
        case .string(let s): return .string(s)
        case .integer(let i): return .integer(Int(i))
        case .float(let f): return .float(f)
        case .boolean(let b): return .bool(b)
        case .table(let t):
            var fields: [ConfigField] = []
            for (k, val) in t.entries {
                guard let cv = toConfigValue(val) else { return nil }
                fields.append(ConfigField(k, cv))
            }
            return .inlineTable(fields)
        default:
            return nil
        }
    }

    private mutating func replaceValue(_ key: String, _ value: ConfigValue, span: KeySpan, lines: inout [String]) {
        let rendered = renderScalar(value)
        let comment = extractCommentSuffix(lines[span.valueEndLineIndex - 1])
        let newLine = "\(span.indent)\(quotedKeyIfNeeded(key)) = \(rendered)"
        var finalLine = newLine
        if let comment {
            if let col = span.commentColumn, col > newLine.count {
                finalLine = newLine + String(repeating: " ", count: col - newLine.count) + comment
            } else {
                finalLine = newLine + " " + comment
            }
        }
        // Replace the whole span (possibly multi-line) with the single new line.
        lines[span.keyLineIndex - 1] = finalLine
        if span.valueEndLineIndex > span.keyLineIndex {
            lines.removeSubrange(span.keyLineIndex..<span.valueEndLineIndex)
        }
    }

    private func extractCommentSuffix(_ line: String) -> String? {
        guard let col = trailingCommentColumn(line) else { return nil }
        let idx = line.index(line.startIndex, offsetBy: col, limitedBy: line.endIndex) ?? line.endIndex
        return String(line[idx...])
    }

    private mutating func removeKeyLines(_ span: KeySpan, lines: inout [String]) {
        var upperInclusive = span.valueEndLineIndex
        // Check for a following orphaned comment-continuation line aligned
        // to the same comment column, e.g. a wrapped trailing comment.
        if let col = span.commentColumn, upperInclusive < lines.count {
            let next = lines[upperInclusive]
            let trimmed = next.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("#") {
                let leading = next.prefix { $0 == " " || $0 == "\t" }
                if leading.count == col {
                    upperInclusive += 1
                }
            }
        }
        lines.removeSubrange((span.keyLineIndex - 1)..<upperInclusive)
    }

    private mutating func insertKey(_ key: String, _ value: ConfigValue, bodyStart: Int, bodyEnd: Int, lines: inout [String]) {
        // Find the last non-blank, non-comment key/value line in the body to
        // insert after; falls back to right after the header (bodyStart-1)
        // if the body has no key lines yet.
        var lastContentLine = bodyStart - 1
        var i = bodyStart
        var indent = ""
        while i <= bodyEnd, i <= lines.count {
            let line = lines[i - 1]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") {
                i += 1
                continue
            }
            if let (_, ind, afterEquals) = parseKeyLine(line) {
                indent = ind
                let valueEnd = scanValueExtent(startLine: i, afterEquals: afterEquals, lines: lines, bodyEnd: bodyEnd)
                lastContentLine = valueEnd
                i = valueEnd + 1
            } else {
                i += 1
            }
        }
        let newLine = "\(indent)\(quotedKeyIfNeeded(key)) = \(renderScalar(value))"
        insert([newLine], after: lastContentLine, lines: &lines)
    }

    // MARK: - Block range with leading comment (for remove/move)

    /// The block's content, trimmed of trailing blank lines and trailing
    /// comment-only lines (which belong to whatever header follows, not to
    /// this block) — the correct anchor for both "insert after this block"
    /// and "remove this block" boundaries.
    private func contentEnd(_ block: Block, lines: [String]) -> Int {
        var end = block.bodyEnd
        while end >= block.headerLine, end <= lines.count {
            let trimmed = lines[end - 1].trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") {
                end -= 1
            } else {
                break
            }
        }
        if end < block.headerLine { end = block.headerLine }
        return end
    }

    private func blockRangeWithLeadingComment(_ block: Block, allBlocks: [Block], lines: [String]) -> (start: Int, end: Int) {
        var start = block.headerLine
        var probe = block.headerLine - 1
        while probe >= 1 {
            let trimmed = lines[probe - 1].trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("#") {
                start = probe
                probe -= 1
            } else {
                break
            }
        }
        let end = contentEnd(block, lines: lines)
        // No leading comment was attached: if a blank line precedes the
        // block and a blank line also follows it, fold the leading blank
        // into the removal so two separators don't collapse into one after
        // removal (the trailing blank alone still separates the neighbors).
        if start == block.headerLine, start > 1, end < lines.count,
           lines[start - 2].trimmingCharacters(in: .whitespaces).isEmpty,
           lines[end].trimmingCharacters(in: .whitespaces).isEmpty {
            start -= 1
        }
        return (start, end)
    }

    // MARK: - Rendering

    private func quotedKeyIfNeeded(_ key: String) -> String {
        let isBare = !key.isEmpty && key.allSatisfy { isBareKeyChar($0) }
        if isBare { return key }
        return "\"\(escapeBasicString(key))\""
    }

    private func renderKeyValue(_ key: String, _ value: ConfigValue) -> String {
        "\(quotedKeyIfNeeded(key)) = \(renderScalar(value))"
    }

    private func renderScalar(_ value: ConfigValue) -> String {
        switch value {
        case .string(let s): return "\"\(escapeBasicString(s))\""
        case .integer(let i): return String(i)
        case .float(let f): return renderFloat(f)
        case .bool(let b): return b ? "true" : "false"
        case .inlineTable(let fields):
            let inner = fields.map { renderKeyValue($0.key, $0.value) }.joined(separator: ", ")
            return "{ \(inner) }"
        }
    }

    private func renderFloat(_ f: Double) -> String {
        if f == f.rounded(), f.isFinite, abs(f) < 1e15 {
            return String(format: "%.1f", f)
        }
        // Shortest round-trip representation.
        var s = String(f)
        if let d = Double(s), d == f {
            return s
        }
        s = String(format: "%.17g", f)
        return s
    }

    private func escapeBasicString(_ s: String) -> String {
        var out = ""
        for c in s {
            switch c {
            case "\\": out += "\\\\"
            case "\"": out += "\\\""
            case "\n": out += "\\n"
            case "\t": out += "\\t"
            default: out.append(c)
            }
        }
        return out
    }
}
