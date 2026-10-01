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
            // Bare Escape cancels; modified Escape is a recordable hotkey.
            if event.keyCode == 0x35, event.modifierFlags.intersection([.control, .option, .shift, .command]).isEmpty {
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
        guard let token = Hotkey.keyName(forKeyCode: UInt32(event.keyCode)) else {
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
        return hotkey.symbols
    }
}
