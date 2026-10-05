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

/// A table this editor can address. `.space` resolves to the `[[space]]`
/// entry matching its address (parsed with `TOML.parse`); `.rule(n)` is the
/// nth `[[rule]]` header, counted without parsing.
public enum ConfigSection: Hashable, Sendable {
    case settings
    case animation
    case focusFlash
    case layout
    case space(SpaceAddress)
    case rule(Int)
    case bindings
}

fileprivate extension ConfigSection {
    /// Header path of the plain table sections; nil for `[[space]]`/`[[rule]]` entries.
    var tablePath: [String]? {
        switch self {
        case .settings: return ["settings"]
        case .animation: return ["settings", "animation"]
        case .focusFlash: return ["settings", "focus_flash"]
        case .layout: return ["layout"]
        case .bindings: return ["bindings"]
        case .space, .rule: return nil
        }
    }
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
        guard case (var lines, var blocks)? = parsedDocument() else { return .failure(Self.parseFailure) }
        // A key written as its own child table (`[layout.gaps]`,
        // `[space.gaps]`) is replaced as a whole: drop that table, then
        // write the key inline like any other (or leave it removed).
        let droppedChild = childTable(key, of: section, blocks: blocks, lines: lines)
        if let child = droppedChild {
            let range = blockRangeWithLeadingComment(child, lines: lines)
            removeLineRange(range.start...range.end, lines: &lines)
            blocks = parseBlocks(lines)
        }
        guard let target = resolveSectionRange(section, blocks: blocks, lines: lines) else {
            switch section {
            case .rule:
                return .failure(ConfigEditError("rule does not exist"))
            default:
                break
            }
            guard let value else {
                // Removing a key from a section that doesn't exist yet is a
                // no-op; creating it just to leave it empty would be a
                // phantom section, not byte-identical with "nothing to do".
                if droppedChild != nil { text = joinLines(lines) }
                return .success(())
            }
            if section == .animation || section == .focusFlash {
                let name = section == .animation ? "animation" : "focus_flash"
                if let settings = blocks.first(where: { $0.header?.path == ["settings"] && $0.header?.isArrayTable == false }),
                   !findKeySpans(bodyStart: settings.bodyStart, bodyEnd: settings.bodyEnd, lines: lines, where: { $0.first == name }).isEmpty {
                    return .failure(ConfigEditError("[settings] already sets \(name) as an inline table or dotted keys; edit that entry in the config file"))
                }
            }
            // Section missing: create it, then retry the set inside it.
            switch createSection(section, lines: &lines) {
            case .failure(let e): return .failure(e)
            case .success: break
            }
            let blocks2 = parseBlocks(lines)
            guard let target2 = resolveSectionRange(section, blocks: blocks2, lines: lines) else {
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

    /// Renames `oldKey` to `newKey` in place (same line, trailing comment kept)
    /// and sets its value; inserts `newKey` if `oldKey` is absent.
    @discardableResult
    public mutating func renameKey(_ oldKey: String, to newKey: String, value: ConfigValue, in section: ConfigSection) -> Result<Void, ConfigEditError> {
        guard oldKey != newKey, case (var lines, let blocks)? = parsedDocument(),
              let target = resolveSectionRange(section, blocks: blocks, lines: lines),
              let span = findKeyLineSpan(oldKey, bodyStart: target.bodyStart, bodyEnd: target.bodyEnd, lines: lines)
        else { return set(newKey, value, in: section) }
        replaceValue(newKey, value, span: span, lines: &lines)
        text = joinLines(lines)
        return .success(())
    }

    @discardableResult
    public mutating func appendRule(_ fields: [ConfigField]) -> Result<Int, ConfigEditError> {
        guard case (var lines, let blocks)? = parsedDocument() else { return .failure(Self.parseFailure) }
        let ruleBlocks = entries("rule", in: blocks)
        let insertAfterLine: Int
        var needsBlankBefore = false
        if let last = ruleBlocks.last {
            insertAfterLine = entryContentEnd(last, allBlocks: blocks, lines: lines)
            needsBlankBefore = true
        } else if let bindingsBlock = blocks.first(where: { $0.header?.normalizedPath == "bindings" && $0.header?.isArrayTable == false }) {
            insertAfterLine = leadingCommentStart(bindingsBlock.headerLine, lines: lines) - 1
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
        guard case (var lines, let blocks)? = parsedDocument() else { return .failure(Self.parseFailure) }
        let ruleBlocks = entries("rule", in: blocks)
        guard index >= 0, index < ruleBlocks.count else {
            return .failure(ConfigEditError("rule index \(index) out of range"))
        }
        let block = ruleBlocks[index]
        let (start, end) = entryRangeWithLeadingComment(block, allBlocks: blocks, lines: lines)
        removeLineRange(start...end, lines: &lines)
        text = joinLines(lines)
        return .success(())
    }

    @discardableResult
    public mutating func moveRule(from: Int, to: Int) -> Result<Void, ConfigEditError> {
        guard let (lines, blocks) = parsedDocument() else { return .failure(Self.parseFailure) }
        let ruleBlocks = entries("rule", in: blocks)
        guard from >= 0, from < ruleBlocks.count, to >= 0, to < ruleBlocks.count else {
            return .failure(ConfigEditError("rule index out of range"))
        }
        if from == to { return .success(()) }

        let fromBlock = ruleBlocks[from]
        let (fromStart, fromEnd) = entryRangeWithLeadingComment(fromBlock, allBlocks: blocks, lines: lines)
        let movedLines = Array(lines[(fromStart - 1)...(fromEnd - 1)])

        // Remove the moved block first, then re-insert it at the target.
        var working = lines
        removeLineRange(fromStart...fromEnd, lines: &working)

        let blocks2 = parseBlocks(working)
        let ruleBlocks2 = entries("rule", in: blocks2)
        // Determine insertion point in the post-removal document.
        let insertAfterLine: Int
        if to >= ruleBlocks2.count {
            // Insert after the (new) last rule.
            if let last = ruleBlocks2.last {
                insertAfterLine = entryContentEnd(last, allBlocks: blocks2, lines: working)
            } else {
                insertAfterLine = working.count
            }
        } else {
            // Insert before rule `to` in the post-removal doc.
            let target = ruleBlocks2[to]
            let (targetStart, _) = entryRangeWithLeadingComment(target, allBlocks: blocks2, lines: working)
            insertAfterLine = targetStart - 1
        }
        insert(movedLines, after: insertAfterLine, lines: &working)
        text = joinLines(working)
        return .success(())
    }

    @discardableResult
    public mutating func removeSpace(_ address: SpaceAddress) -> Result<Void, ConfigEditError> {
        guard case (var lines, let blocks)? = parsedDocument() else { return .failure(Self.parseFailure) }
        guard let block = findSpaceBlock(address, blocks: blocks, lines: lines) else {
            // A [[space]] whose body can't be parsed might be the one asked for.
            let unreadable = entries("space", in: blocks).contains { spaceBody($0, lines: lines) == nil }
            return unreadable ? .failure(ConfigEditError("could not read a [[space]] entry")) : .success(())
        }
        let (start, end) = entryRangeWithLeadingComment(block, allBlocks: blocks, lines: lines)
        removeLineRange(start...end, lines: &lines)
        text = joinLines(lines)
        return .success(())
    }

    /// Removes every `[[space]]` entry that addresses `key`, whether by Space
    /// UUID or by display + ordinal.
    @discardableResult
    public mutating func removeSpaces(for key: SpaceKey) -> Result<Void, ConfigEditError> {
        for address in key.addresses {
            if case .failure(let error) = removeSpace(address) { return .failure(error) }
        }
        return .success(())
    }

    public func validated() -> Result<Config, ConfigError> {
        Config.parse(text)
    }

    // MARK: - Line model

    private static let parseFailure = ConfigEditError("could not parse document")

    /// nil when a `[rule.x]`/`[space.x]` child table doesn't directly follow
    /// its entry or a sibling child: TOML would attach it to whichever entry
    /// precedes it, and the editor's line-range model can't move it safely.
    private func parsedDocument() -> (lines: [String], blocks: [Block])? {
        let lines = splitLines(text)
        let blocks = parseBlocks(lines)
        for (i, block) in blocks.enumerated() {
            guard let h = block.header, !h.isArrayTable, h.path.count > 1,
                  h.tableKind == "rule" || h.tableKind == "space" else { continue }
            guard i > 0, let prev = blocks[i - 1].header, prev.tableKind == h.tableKind,
                  prev.isArrayTable || prev.path.count > 1 else { return nil }
        }
        return (lines, blocks)
    }

    /// Lines without terminators. CRLF is stripped here and restored by
    /// `joinLines`, so every scan below sees plain text.
    private func splitLines(_ text: String) -> [String] {
        if text.isEmpty { return [] }
        var lines = text.components(separatedBy: "\n").map { $0.hasSuffix("\r") ? String($0.dropLast()) : $0 }
        // Preserve a trailing newline as an implicit property, not a phantom
        // empty final element, unless the source really ends with a blank line.
        if lines.last == "" { lines.removeLast() }
        return lines
    }

    private func joinLines(_ lines: [String]) -> String {
        let eol = text.contains("\r\n") ? "\r\n" : "\n"
        return lines.isEmpty ? "" : lines.joined(separator: eol) + eol
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
    }

    /// Splits the document into blocks at table headers. Each block's body
    /// spans from just after its header to just before the next header.
    private func parseBlocks(_ lines: [String]) -> [Block] {
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
                i += 1
            } else if let (_, _, afterEquals) = parseKeyLine(lines[i]) {
                // Skip the whole value: a multi-line string can hold `[x]` lines.
                i = max(scanValueExtent(startLine: lineNo, afterEquals: afterEquals, lines: lines, bodyEnd: lines.count), lineNo)
            } else {
                i += 1
            }
        }
        blocks.append(Block(header: currentHeader, headerLine: currentHeaderLine, bodyStart: bodyStart, bodyEnd: lines.count))
        return blocks
    }

    private func entries(_ kind: String, in blocks: [Block]) -> [Block] {
        blocks.filter { $0.header?.tableKind == kind && $0.header?.isArrayTable == true }
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
        if let path = section.tablePath {
            return blocks.first { $0.header?.path == path && $0.header?.isArrayTable == false }
                .map { SectionRange(bodyStart: $0.bodyStart, bodyEnd: $0.bodyEnd) }
        }
        switch section {
        case .settings, .animation, .focusFlash, .layout, .bindings:
            return nil
        case .space(let address):
            guard let block = findSpaceBlock(address, blocks: blocks, lines: lines) else { return nil }
            return SectionRange(bodyStart: block.bodyStart, bodyEnd: block.bodyEnd)
        case .rule(let index):
            let ruleBlocks = entries("rule", in: blocks)
            guard index >= 0, index < ruleBlocks.count else { return nil }
            let block = ruleBlocks[index]
            return SectionRange(bodyStart: block.bodyStart, bodyEnd: block.bodyEnd)
        }
    }

    /// The non-array table that spells `key` of `section` as a table of its
    /// own (`[layout.gaps]`, or a `[[space]]` entry's `[space.gaps]`).
    private func childTable(_ key: String, of section: ConfigSection, blocks: [Block], lines: [String]) -> Block? {
        func table(_ path: [String], in candidates: [Block]) -> Block? {
            candidates.first { $0.header?.isArrayTable == false && $0.header?.path == path }
        }
        func owned(by entry: Block) -> [Block] {
            let end = ownedBodyEnd(for: entry, allBlocks: blocks)
            return blocks.filter { $0.headerLine > entry.headerLine && $0.headerLine <= end }
        }
        if let path = section.tablePath { return table(path + [key], in: blocks) }
        switch section {
        case .settings, .animation, .focusFlash, .layout, .bindings: return nil
        case .space(let address):
            guard let entry = findSpaceBlock(address, blocks: blocks, lines: lines) else { return nil }
            return table(["space", key], in: owned(by: entry))
        case .rule(let index):
            let ruleBlocks = entries("rule", in: blocks)
            guard index >= 0, index < ruleBlocks.count else { return nil }
            return table(["rule", key], in: owned(by: ruleBlocks[index]))
        }
    }

    private func spaceBody(_ block: Block, lines: [String]) -> TOMLTable? {
        try? TOML.parse(lines[(block.bodyStart - 1)..<max(block.bodyStart - 1, min(block.bodyEnd, lines.count))].joined(separator: "\n"))
    }

    private func findSpaceBlock(_ address: SpaceAddress, blocks: [Block], lines: [String]) -> Block? {
        let spaceBlocks = entries("space", in: blocks)
        for block in spaceBlocks {
            guard let t = spaceBody(block, lines: lines) else { continue }
            switch address {
            case .uuid(let uuid):
                guard case .string(let value)? = t["uuid"], value.uppercased() == uuid.uppercased() else { continue }
                return block
            case .position(let display, let ordinal):
                guard case .string(let value)? = t["display"], case .integer(let i)? = t["ordinal"] else { continue }
                if value.uppercased() == display.uppercased() && Int(i) == ordinal { return block }
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
            insertSectionHeader("[settings]", lines: &lines)
            return .success(())
        case .animation, .focusFlash:
            // A [settings.*] subtable goes right after the last existing one, else after [settings].
            let header = "[" + (section.tablePath ?? []).joined(separator: ".") + "]"
            if let anchor = lastSettingsBlock(parseBlocks(lines)) {
                insertBlockAfter(anchor, header: header, lines: &lines)
            } else {
                // Create [settings] first, then the subtable right after.
                insertSectionHeader("[settings]", lines: &lines)
                guard let anchor2 = lastSettingsBlock(parseBlocks(lines)) else {
                    return .failure(ConfigEditError("failed to create \(header)"))
                }
                insertBlockAfter(anchor2, header: header, lines: &lines)
            }
            return .success(())
        case .layout:
            if let anchor = lastSettingsBlock(parseBlocks(lines)) {
                insertBlockAfter(anchor, header: "[layout]", lines: &lines)
            } else {
                insertSectionHeader("[layout]", lines: &lines)
            }
            return .success(())
        case .bindings:
            var newLines: [String] = []
            if !lines.isEmpty { newLines.append("") }
            newLines.append("[bindings]")
            insert(newLines, after: lines.count, lines: &lines)
            return .success(())
        case .space(let address):
            let blocks = parseBlocks(lines)
            let spaceBlocks = entries("space", in: blocks)
            var body = ["[[space]]"]
            switch address {
            case .uuid(let uuid):
                body.append("uuid = \(renderScalar(.string(uuid.uppercased())))")
            case .position(let display, let ordinal):
                body.append("display = \(renderScalar(.string(display.uppercased())))")
                body.append("ordinal = \(ordinal)")
            }
            if let last = spaceBlocks.last {
                insert([""] + body, after: entryContentEnd(last, allBlocks: blocks, lines: lines), lines: &lines)
            } else if let header = firstRuleHeaderLine(blocks)
                        ?? blocks.first(where: { $0.header?.normalizedPath == "bindings" && $0.header?.isArrayTable == false })?.headerLine {
                // Above the target header's attached comments, not between them and it.
                insert(body + [""], after: leadingCommentStart(header, lines: lines) - 1, lines: &lines)
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

    /// Inserts a new top-level section at the top of the file, after a leading
    /// file-header comment block (one separated from the first table by a blank
    /// line). Comments attached directly to the first table stay with it.
    private mutating func insertSectionHeader(_ header: String, lines: inout [String]) {
        var run = 0
        while run < lines.count, lines[run].trimmingCharacters(in: .whitespaces).hasPrefix("#") { run += 1 }
        var at = 0
        var newLines = [header]
        if run > 0, run == lines.count || lines[run].trimmingCharacters(in: .whitespaces).isEmpty {
            at = run == lines.count ? run : run + 1
            if run == lines.count { newLines.insert("", at: 0) }
        }
        if at < lines.count { newLines.append("") }
        insert(newLines, after: at, lines: &lines)
    }

    private mutating func insertBlockAfter(_ block: Block, header: String, lines: inout [String]) {
        insert(["", header], after: contentEnd(block, lines: lines), lines: &lines)
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
        // Dotted keys under `key` (`gaps.inner = 4`) are replaced as a whole,
        // like a child table.
        var bodyEnd = bodyEnd
        for dotted in findDottedKeySpans(key, bodyStart: bodyStart, bodyEnd: bodyEnd, lines: lines).reversed() {
            let before = lines.count
            removeKeyLines(dotted, lines: &lines)
            bodyEnd -= before - lines.count
        }
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
        findKeySpans(bodyStart: bodyStart, bodyEnd: bodyEnd, lines: lines) { $0 == [key] }.first
    }

    /// Spans of dotted-key lines under `key` (`key.sub = ...`).
    private func findDottedKeySpans(_ key: String, bodyStart: Int, bodyEnd: Int, lines: [String]) -> [KeySpan] {
        findKeySpans(bodyStart: bodyStart, bodyEnd: bodyEnd, lines: lines) { $0.count > 1 && $0[0] == key }
    }

    private func findKeySpans(bodyStart: Int, bodyEnd: Int, lines: [String], where matches: ([String]) -> Bool) -> [KeySpan] {
        var spans: [KeySpan] = []
        var i = bodyStart
        while i <= bodyEnd, i <= lines.count {
            let line = lines[i - 1]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") {
                i += 1
                continue
            }
            guard let (path, indent, afterEquals) = parseKeyLine(line) else {
                i += 1
                continue
            }
            let valueEnd = scanValueExtent(startLine: i, afterEquals: afterEquals, lines: lines, bodyEnd: bodyEnd)
            if matches(path) {
                let commentCol = trailingCommentColumn(lines[valueEnd - 1])
                spans.append(KeySpan(keyLineIndex: i, valueEndLineIndex: valueEnd, commentColumn: commentCol, indent: indent))
            }
            i = valueEnd + 1
        }
        return spans
    }

    /// Parses a `key = ...` line start (bare/basic/literal key), returning
    /// the decoded key, its leading indent, and the column right after `=`.
    private func parseKeyLine(_ line: String) -> (path: [String], indent: String, afterEquals: String.Index)? {
        var idx = line.startIndex
        func skipSpace() {
            while idx < line.endIndex, line[idx] == " " || line[idx] == "\t" { idx = line.index(after: idx) }
        }
        func segment() -> String? {
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
                return quote == "\"" ? unescapeBasicString(key) : key
            }
            guard isBareKeyStart(line[idx]) else { return nil }
            let start = idx
            while idx < line.endIndex, isBareKeyChar(line[idx]) { idx = line.index(after: idx) }
            return String(line[start..<idx])
        }
        skipSpace()
        let indent = String(line[line.startIndex..<idx])
        var path: [String] = []
        while true {
            guard let seg = segment() else { return nil }
            path.append(seg)
            skipSpace()
            guard idx < line.endIndex else { return nil }
            guard line[idx] == "." else { break }
            idx = line.index(after: idx)
            skipSpace()
        }
        guard line[idx] == "=" else { return nil }
        idx = line.index(after: idx)
        return (path, indent, idx)
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
                        if matchesTriple(text, idx, "'") { inTripleSingle = true; idx = text.index(idx, offsetBy: 2, limitedBy: text.endIndex) ?? text.endIndex }
                        else { inSingle = true }
                    } else if c == "\"" {
                        if matchesTriple(text, idx, "\"") { inTripleDouble = true; idx = text.index(idx, offsetBy: 2, limitedBy: text.endIndex) ?? text.endIndex }
                        else { inDouble = true }
                    } else if c == "[" || c == "{" {
                        depth += 1
                    } else if c == "]" || c == "}" {
                        depth -= 1
                    }
                }
                idx = text.index(after: idx)
            }
            let stillOpen = depth > 0 || inSingle || inDouble || inTripleSingle || inTripleDouble
            if !stillOpen { return line }
            if line >= bodyEnd || line >= lines.count { return line }
            line += 1
            idx = lines[line - 1].startIndex
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
        // Also drop every following orphaned comment-continuation line
        // aligned to the same comment column (a wrapped trailing comment).
        if let col = span.commentColumn {
            while upperInclusive < lines.count {
                let next = lines[upperInclusive]
                guard next.trimmingCharacters(in: .whitespaces).hasPrefix("#"),
                      next.prefix(while: { $0 == " " || $0 == "\t" }).count == col else { break }
                upperInclusive += 1
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

    /// First line of the contiguous `#` comment run directly above `headerLine`
    /// (the comments attached to that header); `headerLine` itself if none.
    private func leadingCommentStart(_ headerLine: Int, lines: [String]) -> Int {
        var start = headerLine
        while start > 1, lines[start - 2].trimmingCharacters(in: .whitespaces).hasPrefix("#") {
            start -= 1
        }
        return start
    }

    private func blockRangeWithLeadingComment(_ block: Block, lines: [String]) -> (start: Int, end: Int) {
        var start = leadingCommentStart(block.headerLine, lines: lines)
        var end = contentEnd(block, lines: lines)
        let blankAfter = end < lines.count && lines[end].trimmingCharacters(in: .whitespaces).isEmpty
        // No leading comment was attached: if a blank line precedes the
        // block and a blank line also follows it, fold the leading blank
        // into the removal so two separators don't collapse into one after
        // removal (the trailing blank alone still separates the neighbors).
        // At the top of the file there is no leading separator, so the
        // trailing blank goes instead of becoming a stray first line.
        if blankAfter {
            if start == 1 {
                end += 1
            } else if lines[start - 2].trimmingCharacters(in: .whitespaces).isEmpty {
                start -= 1
            }
        }
        return (start, end)
    }

    // MARK: - Array-table entry ownership (nested child tables)

    /// `[[rule]]`/`[[space]]` entries can be followed by non-array child
    /// tables that belong to them (`[rule.size]`, `[rule.placement]`,
    /// `[space.gaps]`, ...). Those child blocks must move, get removed, and
    /// get skipped over as a unit with their owning entry rather than being
    /// orphaned or miscounted as sibling `[[rule]]`/`[[space]]` entries.
    private func ownedBodyEnd(for entryBlock: Block, allBlocks: [Block]) -> Int {
        guard let kind = entryBlock.header?.tableKind,
              let idx = allBlocks.firstIndex(where: { $0.headerLine == entryBlock.headerLine }) else {
            return entryBlock.bodyEnd
        }
        var end = entryBlock.bodyEnd
        var i = idx + 1
        while i < allBlocks.count {
            let candidate = allBlocks[i]
            guard let header = candidate.header,
                  header.isArrayTable == false,
                  header.path.count > 1,
                  header.path.first == kind else { break }
            end = candidate.bodyEnd
            i += 1
        }
        return end
    }

    /// `contentEnd`, but extended through any owned child tables.
    private func entryContentEnd(_ entryBlock: Block, allBlocks: [Block], lines: [String]) -> Int {
        let extended = Block(header: entryBlock.header, headerLine: entryBlock.headerLine, bodyStart: entryBlock.bodyStart, bodyEnd: ownedBodyEnd(for: entryBlock, allBlocks: allBlocks))
        return contentEnd(extended, lines: lines)
    }

    /// `blockRangeWithLeadingComment`, but extended through any owned child
    /// tables so remove/move take the whole entry with it.
    private func entryRangeWithLeadingComment(_ entryBlock: Block, allBlocks: [Block], lines: [String]) -> (start: Int, end: Int) {
        let extended = Block(header: entryBlock.header, headerLine: entryBlock.headerLine, bodyStart: entryBlock.bodyStart, bodyEnd: ownedBodyEnd(for: entryBlock, allBlocks: allBlocks))
        return blockRangeWithLeadingComment(extended, lines: lines)
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
        for u in s.unicodeScalars {
            switch u {
            case "\\": out += "\\\\"
            case "\"": out += "\\\""
            case "\n": out += "\\n"
            case "\t": out += "\\t"
            case "\r": out += "\\r"
            default:
                if u.value < 0x20 || u.value == 0x7F {
                    out += String(format: "\\u%04X", u.value)
                } else {
                    out.unicodeScalars.append(u)
                }
            }
        }
        return out
    }
}
