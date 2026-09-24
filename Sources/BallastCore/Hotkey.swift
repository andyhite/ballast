import Foundation

/// Modifier keys usable in a hotkey combination.
public struct HotkeyModifiers: OptionSet, Hashable, Sendable {
    public let rawValue: UInt32

    public init(rawValue: UInt32) {
        self.rawValue = rawValue
    }

    public static let command = HotkeyModifiers(rawValue: 1 << 0)
    public static let option = HotkeyModifiers(rawValue: 1 << 1)
    public static let control = HotkeyModifiers(rawValue: 1 << 2)
    public static let shift = HotkeyModifiers(rawValue: 1 << 3)
}

/// A failure parsing a hotkey spec string.
public struct HotkeyParseError: Error, Equatable, CustomStringConvertible {
    public let message: String

    public init(_ message: String) {
        self.message = message
    }

    public var description: String { message }
}

/// A parsed hotkey: a key code plus modifier keys.
///
/// Spec syntax: `+`-separated tokens, case-insensitive, whitespace trimmed
/// around each token. Exactly one token must resolve to a key; all others
/// must resolve to modifiers. Because `+` is the token separator, it cannot
/// itself be used as (or embedded in) a key name. A spec with no modifier,
/// or only `shift`, is rejected unless the key is `f1`-`f20` — bare typing
/// keys would otherwise be captured system-wide.
///
/// Modifier tokens: `cmd`/`command`/`⌘`, `alt`/`opt`/`option`/`⌥`,
/// `ctrl`/`control`/`⌃`, `shift`/`⇧`. Compound modifier tokens:
/// `hyper` (cmd+alt+ctrl+shift), `meh` (alt+ctrl+shift). Repeating a
/// modifier (including via a compound token) is harmless — modifiers are a
/// set.
///
/// Key tokens: `a`-`z`, `0`-`9`, `f1`-`f20`, `left`/`right`/`up`/`down`,
/// `return`/`enter`, `tab`, `space`, `escape`/`esc`, `delete`/`backspace`,
/// `forwarddelete`, `home`, `end`, `pageup`, `pagedown`, `minus`/`-`,
/// `equal`/`=`, `leftbracket`/`[`, `rightbracket`/`]`, `semicolon`/`;`,
/// `quote`/`'`, `comma`/`,`, `period`/`.`, `slash`/`/`, `backslash`/`\`,
/// `grave`/`` ` ``.
public struct Hotkey: Hashable, Sendable, CustomStringConvertible {
    /// macOS virtual key code (a `kVK_*` value from Carbon's HIToolbox).
    public let keyCode: UInt32
    public let modifiers: HotkeyModifiers
    /// Canonical lowercase key name (the first name listed for that key).
    public let keyName: String

    public init(keyCode: UInt32, modifiers: HotkeyModifiers, keyName: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.keyName = keyName
    }

    public var description: String {
        var parts: [String] = []
        if modifiers.contains(.control) { parts.append("ctrl") }
        if modifiers.contains(.option) { parts.append("alt") }
        if modifiers.contains(.shift) { parts.append("shift") }
        if modifiers.contains(.command) { parts.append("cmd") }
        parts.append(keyName)
        return parts.joined(separator: "+")
    }

    /// Parses a hotkey spec such as `"ctrl+alt+h"` or `"hyper+space"`.
    public static func parse(_ spec: String) -> Result<Hotkey, HotkeyParseError> {
        let trimmedSpec = spec.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedSpec.isEmpty else {
            return .failure(HotkeyParseError("empty hotkey spec"))
        }

        let rawTokens = trimmedSpec.split(separator: "+", omittingEmptySubsequences: false)
        var modifiers: HotkeyModifiers = []
        var resolvedKey: (code: UInt32, name: String)?

        for rawToken in rawTokens {
            let token = rawToken.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !token.isEmpty else {
                return .failure(HotkeyParseError("empty token in hotkey spec \"\(trimmedSpec)\""))
            }

            if let modifier = Self.modifierAliases[token] {
                modifiers.insert(modifier)
                continue
            }

            if let key = Self.keyAliases[token] {
                if resolvedKey != nil {
                    return .failure(HotkeyParseError("hotkey spec \"\(trimmedSpec)\" specifies more than one key"))
                }
                resolvedKey = key
                continue
            }

            return .failure(HotkeyParseError("unknown hotkey token \"\(token)\""))
        }

        guard let key = resolvedKey else {
            return .failure(HotkeyParseError("hotkey spec \"\(trimmedSpec)\" has no key"))
        }

        let isFunctionKey = key.name.count >= 2 && key.name.count <= 3 && key.name.hasPrefix("f")
            && key.name.dropFirst().allSatisfy(\.isNumber)
        if modifiers.subtracting(.shift).isEmpty, !isFunctionKey {
            return .failure(
                HotkeyParseError("hotkey spec \"\(trimmedSpec)\" needs a modifier other than shift"))
        }

        return .success(Hotkey(keyCode: key.code, modifiers: modifiers, keyName: key.name))
    }

    /// Modifier token aliases, including compound tokens `hyper` and `meh`.
    private static let modifierAliases: [String: HotkeyModifiers] = [
        "cmd": .command, "command": .command, "\u{2318}": .command,
        "alt": .option, "opt": .option, "option": .option, "\u{2325}": .option,
        "ctrl": .control, "control": .control, "\u{2303}": .control,
        "shift": .shift, "\u{21E7}": .shift,
        "hyper": [.command, .option, .control, .shift],
        "meh": [.option, .control, .shift],
    ]

    /// Key name aliases to (virtual key code, canonical name).
    private static let keyAliases: [String: (code: UInt32, name: String)] = {
        var table: [String: (code: UInt32, name: String)] = [:]

        let letters: [(String, UInt32)] = [
            ("a", 0x00), ("b", 0x0B), ("c", 0x08), ("d", 0x02), ("e", 0x0E),
            ("f", 0x03), ("g", 0x05), ("h", 0x04), ("i", 0x22), ("j", 0x26),
            ("k", 0x28), ("l", 0x25), ("m", 0x2E), ("n", 0x2D), ("o", 0x1F),
            ("p", 0x23), ("q", 0x0C), ("r", 0x0F), ("s", 0x01), ("t", 0x11),
            ("u", 0x20), ("v", 0x09), ("w", 0x0D), ("x", 0x07), ("y", 0x10),
            ("z", 0x06),
        ]
        for (name, code) in letters {
            table[name] = (code, name)
        }

        let digits: [(String, UInt32)] = [
            ("0", 0x1D), ("1", 0x12), ("2", 0x13), ("3", 0x14), ("4", 0x15),
            ("5", 0x17), ("6", 0x16), ("7", 0x1A), ("8", 0x1C), ("9", 0x19),
        ]
        for (name, code) in digits {
            table[name] = (code, name)
        }

        let functionKeys: [(String, UInt32)] = [
            ("f1", 0x7A), ("f2", 0x78), ("f3", 0x63), ("f4", 0x76),
            ("f5", 0x60), ("f6", 0x61), ("f7", 0x62), ("f8", 0x64),
            ("f9", 0x65), ("f10", 0x6D), ("f11", 0x67), ("f12", 0x6F),
            ("f13", 0x69), ("f14", 0x6B), ("f15", 0x71), ("f16", 0x6A),
            ("f17", 0x40), ("f18", 0x4F), ("f19", 0x50), ("f20", 0x5A),
        ]
        for (name, code) in functionKeys {
            table[name] = (code, name)
        }

        table["left"] = (0x7B, "left")
        table["right"] = (0x7C, "right")
        table["up"] = (0x7E, "up")
        table["down"] = (0x7D, "down")
        table["return"] = (0x24, "return")
        table["enter"] = (0x24, "return")
        table["tab"] = (0x30, "tab")
        table["space"] = (0x31, "space")
        table["escape"] = (0x35, "escape")
        table["esc"] = (0x35, "escape")
        table["delete"] = (0x33, "delete")
        table["backspace"] = (0x33, "delete")
        table["forwarddelete"] = (0x75, "forwarddelete")
        table["home"] = (0x73, "home")
        table["end"] = (0x77, "end")
        table["pageup"] = (0x74, "pageup")
        table["pagedown"] = (0x79, "pagedown")
        table["minus"] = (0x1B, "minus")
        table["-"] = (0x1B, "minus")
        table["equal"] = (0x18, "equal")
        table["="] = (0x18, "equal")
        table["leftbracket"] = (0x21, "leftbracket")
        table["["] = (0x21, "leftbracket")
        table["rightbracket"] = (0x1E, "rightbracket")
        table["]"] = (0x1E, "rightbracket")
        table["semicolon"] = (0x29, "semicolon")
        table[";"] = (0x29, "semicolon")
        table["quote"] = (0x27, "quote")
        table["'"] = (0x27, "quote")
        table["comma"] = (0x2B, "comma")
        table[","] = (0x2B, "comma")
        table["period"] = (0x2F, "period")
        table["."] = (0x2F, "period")
        table["slash"] = (0x2C, "slash")
        table["/"] = (0x2C, "slash")
        table["backslash"] = (0x2A, "backslash")
        table["\\"] = (0x2A, "backslash")
        table["grave"] = (0x32, "grave")
        table["`"] = (0x32, "grave")

        return table
    }()
}
