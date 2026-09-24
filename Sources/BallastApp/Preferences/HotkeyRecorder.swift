import AppKit
import SwiftUI
import BallastCore

/// Captures one hotkey combination via a local `NSEvent` monitor and turns
/// it into a spec string `Hotkey.parse` accepts (e.g. `"alt+shift+h"`).
///
/// Key identity is resolved from the raw virtual key code rather than the
/// event's typed characters, so the recorder never depends on the current
/// keyboard layout producing a particular character. The binding sheet that
/// hosts it pauses Ballast's global hotkeys, so a bound combination is
/// captured here instead of running its command.
struct HotkeyRecorder: View {
    @Binding var spec: String
    var onCapture: ((String) -> Void)?

    @State private var isRecording = false
    @State private var monitor: Any?
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button(action: toggleRecording) {
                Text(isRecording ? "Press keys… (Esc to cancel)" : Self.glyphDisplay(for: spec))
                    .frame(minWidth: 140, alignment: .leading)
                    .foregroundStyle(isRecording ? .secondary : .primary)
                    .monospaced()
            }
            .buttonStyle(.bordered)
            if let errorMessage {
                Text(errorMessage).font(.caption).foregroundStyle(.red)
            }
        }
        .onDisappear { stopRecording() }
    }

    private func toggleRecording() {
        if isRecording { stopRecording() } else { startRecording() }
    }

    private func startRecording() {
        errorMessage = nil
        isRecording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { event in
            if event.keyCode == 0x35 { // escape cancels
                stopRecording()
                return nil
            }
            handle(event)
            return nil
        }
    }

    private func stopRecording() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        isRecording = false
    }

    private func handle(_ event: NSEvent) {
        guard let token = Self.keyToken(for: UInt32(event.keyCode)) else {
            errorMessage = "That key can't be used in a hotkey."
            return
        }
        var parts: [String] = []
        let flags = event.modifierFlags
        if flags.contains(.control) { parts.append("ctrl") }
        if flags.contains(.option) { parts.append("alt") }
        if flags.contains(.shift) { parts.append("shift") }
        if flags.contains(.command) { parts.append("cmd") }
        parts.append(token)
        let candidate = parts.joined(separator: "+")

        switch Hotkey.parse(candidate) {
        case .success:
            spec = candidate
            errorMessage = nil
            stopRecording()
            onCapture?(candidate)
        case .failure(let error):
            errorMessage = error.message
        }
    }

    /// Human-readable form of a spec string using ⌃⌥⇧⌘ glyphs, e.g.
    /// `"alt+shift+h"` → `"⌥⇧H"`. Falls back to the raw spec if it doesn't parse.
    static func glyphDisplay(for spec: String) -> String {
        guard !spec.isEmpty else { return "Click to record" }
        guard case .success(let hotkey) = Hotkey.parse(spec) else { return spec }
        var glyph = ""
        if hotkey.modifiers.contains(.control) { glyph += "\u{2303}" }
        if hotkey.modifiers.contains(.option) { glyph += "\u{2325}" }
        if hotkey.modifiers.contains(.shift) { glyph += "\u{21E7}" }
        if hotkey.modifiers.contains(.command) { glyph += "\u{2318}" }
        glyph += keySymbols[hotkey.keyName] ?? hotkey.keyName.uppercased()
        return glyph
    }

    private static let keySymbols: [String: String] = [
        "left": "\u{2190}", "right": "\u{2192}", "up": "\u{2191}", "down": "\u{2193}",
        "return": "\u{23CE}", "tab": "\u{21E5}", "space": "Space", "escape": "\u{238B}",
        "delete": "\u{232B}", "forwarddelete": "\u{2326}", "home": "\u{2196}", "end": "\u{2198}",
        "pageup": "\u{21DE}", "pagedown": "\u{21DF}", "minus": "-", "equal": "=",
        "leftbracket": "[", "rightbracket": "]", "semicolon": ";", "quote": "'",
        "comma": ",", "period": ".", "slash": "/", "backslash": "\\", "grave": "`",
    ]

    /// Reverse of `Hotkey`'s private key-code table, restricted to the same
    /// virtual key codes it accepts so every captured spec round-trips
    /// through `Hotkey.parse`.
    private static func keyToken(for keyCode: UInt32) -> String? {
        keyCodeTokens[keyCode]
    }

    private static let keyCodeTokens: [UInt32: String] = {
        var table: [UInt32: String] = [:]
        let letters: [(String, UInt32)] = [
            ("a", 0x00), ("b", 0x0B), ("c", 0x08), ("d", 0x02), ("e", 0x0E),
            ("f", 0x03), ("g", 0x05), ("h", 0x04), ("i", 0x22), ("j", 0x26),
            ("k", 0x28), ("l", 0x25), ("m", 0x2E), ("n", 0x2D), ("o", 0x1F),
            ("p", 0x23), ("q", 0x0C), ("r", 0x0F), ("s", 0x01), ("t", 0x11),
            ("u", 0x20), ("v", 0x09), ("w", 0x0D), ("x", 0x07), ("y", 0x10),
            ("z", 0x06),
        ]
        for (name, code) in letters { table[code] = name }

        let digits: [(String, UInt32)] = [
            ("0", 0x1D), ("1", 0x12), ("2", 0x13), ("3", 0x14), ("4", 0x15),
            ("5", 0x17), ("6", 0x16), ("7", 0x1A), ("8", 0x1C), ("9", 0x19),
        ]
        for (name, code) in digits { table[code] = name }

        let functionKeys: [(String, UInt32)] = [
            ("f1", 0x7A), ("f2", 0x78), ("f3", 0x63), ("f4", 0x76),
            ("f5", 0x60), ("f6", 0x61), ("f7", 0x62), ("f8", 0x64),
            ("f9", 0x65), ("f10", 0x6D), ("f11", 0x67), ("f12", 0x6F),
            ("f13", 0x69), ("f14", 0x6B), ("f15", 0x71), ("f16", 0x6A),
            ("f17", 0x40), ("f18", 0x4F), ("f19", 0x50), ("f20", 0x5A),
        ]
        for (name, code) in functionKeys { table[code] = name }

        table[0x7B] = "left"
        table[0x7C] = "right"
        table[0x7E] = "up"
        table[0x7D] = "down"
        table[0x24] = "return"
        table[0x30] = "tab"
        table[0x31] = "space"
        table[0x35] = "escape"
        table[0x33] = "delete"
        table[0x75] = "forwarddelete"
        table[0x73] = "home"
        table[0x77] = "end"
        table[0x74] = "pageup"
        table[0x79] = "pagedown"
        table[0x1B] = "minus"
        table[0x18] = "equal"
        table[0x21] = "leftbracket"
        table[0x1E] = "rightbracket"
        table[0x29] = "semicolon"
        table[0x27] = "quote"
        table[0x2B] = "comma"
        table[0x2F] = "period"
        table[0x2C] = "slash"
        table[0x2A] = "backslash"
        table[0x32] = "grave"
        return table
    }()
}
