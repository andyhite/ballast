import AppKit
import SwiftUI
import BallastCore

/// Editor for the `[bindings]` table: hotkey spec (quoted TOML key) →
/// command text (string value). Editing a binding needs the literal key
/// text as written in the file (not just the parsed `Hotkey`, whose
/// canonical description may differ from a shorthand like `"hyper+r"`), so
/// each `KeyBinding.hotkeyText` (from `Config.parse`) is used for edits
/// instead of `Hotkey.description`.
struct BindingsPane: View {
    private let manager: WindowManager
    @StateObject private var model: ConfigModel
    @State private var selection: Hotkey?
    @State private var showingAddSheet = false
    @State private var editingBinding: BindingRow?
    @State private var errorMessage: String?

    init(manager: WindowManager) {
        self.manager = manager
        self._model = StateObject(wrappedValue: ConfigModel(manager: manager))
    }

    private var rows: [BindingRow] {
        model.config.bindings.map { binding in
            BindingRow(hotkey: binding.hotkey, commandText: binding.commandText, literalKey: binding.hotkeyText)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            if let configError = model.configError {
                ConfigErrorBanner(message: configError)
            }
            Table(rows, selection: $selection) {
                TableColumn("Hotkey") { row in
                    Text(HotkeyRecorder.glyphDisplay(for: row.literalKey))
                        .monospaced()
                }
                .width(120)
                TableColumn("Command") { row in
                    Text(row.commandText)
                }
            }
            if let errorMessage {
                InlineErrorText(message: errorMessage).padding(8)
            }
            HStack {
                Button {
                    showingAddSheet = true
                } label: {
                    Image(systemName: "plus")
                }
                Button {
                    editSelected()
                } label: {
                    Image(systemName: "pencil")
                }
                .disabled(selection == nil)
                Button {
                    deleteSelected()
                } label: {
                    Image(systemName: "minus")
                }
                .disabled(selection == nil)
                Spacer()
            }
            .buttonStyle(.borderless)
            .padding(8)
            Text("Ballast's hotkeys are paused while the binding editor is open.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
        }
        .disabled(model.configError != nil)
        .sheet(isPresented: $showingAddSheet) {
            BindingEditSheet(existing: nil) { spec, commandText, previousLiteralKey in
                commitBinding(spec: spec, commandText: commandText, previousLiteralKey: previousLiteralKey)
            }
            .onAppear { manager.setHotkeysSuspended(true) }
            .onDisappear { manager.setHotkeysSuspended(false) }
        }
        .sheet(item: $editingBinding) { row in
            BindingEditSheet(existing: row) { spec, commandText, previousLiteralKey in
                commitBinding(spec: spec, commandText: commandText, previousLiteralKey: previousLiteralKey)
            }
            .onAppear { manager.setHotkeysSuspended(true) }
            .onDisappear { manager.setHotkeysSuspended(false) }
        }
    }

    private func editSelected() {
        guard let selection, let row = rows.first(where: { $0.hotkey == selection }) else { return }
        editingBinding = row
    }

    private func deleteSelected() {
        guard let selection, let row = rows.first(where: { $0.hotkey == selection }) else { return }
        if let error = manager.editConfig({ editor in editor.set(row.literalKey, nil, in: .bindings) }) {
            errorMessage = error.description
        } else {
            errorMessage = nil
            self.selection = nil
        }
    }

    private func commitBinding(spec: String, commandText: String, previousLiteralKey: String?) {
        let error = manager.editConfig { editor -> Result<Void, ConfigEditError> in
            if let previousLiteralKey, previousLiteralKey != spec {
                switch editor.set(previousLiteralKey, nil, in: .bindings) {
                case .failure(let e): return .failure(e)
                case .success: break
                }
            }
            return editor.set(spec, .string(commandText), in: .bindings)
        }
        if let error {
            errorMessage = error.description
        } else {
            errorMessage = nil
            selection = Hotkey.parse(spec).value
        }
    }

}

private struct BindingRow: Identifiable, Equatable {
    let hotkey: Hotkey
    let commandText: String
    let literalKey: String
    var id: Hotkey { hotkey }
}

private extension Result {
    var value: Success? {
        if case .success(let value) = self { return value }
        return nil
    }
}

/// Add/edit sheet for one binding. Editing passes the row being replaced so
/// the caller can remove its literal key if the hotkey changes.
private struct BindingEditSheet: View {
    @Environment(\.dismiss) private var dismiss
    let existing: BindingRow?
    let onCommit: (_ spec: String, _ commandText: String, _ previousLiteralKey: String?) -> Void

    @State private var spec: String
    @State private var commandText: String
    @State private var showSuggestions = false
    @State private var errorMessage: String?

    init(existing: BindingRow?, onCommit: @escaping (String, String, String?) -> Void) {
        self.existing = existing
        self.onCommit = onCommit
        _spec = State(initialValue: existing?.literalKey ?? "")
        _commandText = State(initialValue: existing?.commandText ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(existing == nil ? "New Binding" : "Edit Binding").font(.headline)

            FormRow(title: "Hotkey") { HotkeyRecorder(spec: $spec, onCapture: nil) }

            FormRow(title: "Command") {
                VStack(alignment: .leading, spacing: 4) {
                    TextField("focus left", text: $commandText)
                        .onTapGesture { showSuggestions = true }
                    if showSuggestions {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 0) {
                                ForEach(Command.reference, id: \.self) { suggestion in
                                    Text(suggestion)
                                        .font(.caption)
                                        .padding(.vertical, 2)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .contentShape(Rectangle())
                                        .onTapGesture {
                                            commandText = suggestion
                                            showSuggestions = false
                                        }
                                }
                            }
                        }
                        .frame(maxHeight: 120)
                    }
                }
            }

            if let errorMessage {
                InlineErrorText(message: errorMessage)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button(existing == nil ? "Add" : "Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(spec.isEmpty || commandText.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    private func save() {
        guard case .success = Hotkey.parse(spec) else {
            errorMessage = "Record a valid hotkey first."
            return
        }
        switch Command.parse(commandText) {
        case .failure(let error):
            errorMessage = error.description
        case .success:
            onCommit(spec, commandText, existing?.literalKey)
            dismiss()
        }
    }
}
