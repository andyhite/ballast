import AppKit
import SwiftUI
import BallastCore

/// Editor for `[[rule]]` entries. List order is file order, which is also
/// the tiebreak order the resolver uses: the matching rule with the most
/// match fields wins; if two rules tie on specificity, the earlier one wins.
struct RulesPane: View {
    private let manager: WindowManager
    @StateObject private var model: ConfigModel
    @State private var selection: Int?
    @State private var showingAddSheet = false
    @State private var errorMessage: String?

    init(manager: WindowManager) {
        self.manager = manager
        self._model = StateObject(wrappedValue: ConfigModel(manager: manager))
    }

    private var rules: [AppRule] { model.config.rules }

    var body: some View {
        VStack(spacing: 0) {
            if let configError = model.configError {
                ConfigErrorBanner(message: configError)
            }
            HSplitView {
                list
                detail
            }
            if let errorMessage {
                InlineErrorText(message: errorMessage)
                    .padding(8)
            }
            Text("The matching rule with the most match fields wins; ties go to the earlier rule in this list.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
        }
        .disabled(model.configError != nil)
        .sheet(isPresented: $showingAddSheet) {
            AddRuleSheet { fields in
                addRule(fields)
            }
        }
    }

    private var list: some View {
        VStack(spacing: 0) {
            List(selection: $selection) {
                ForEach(Array(rules.enumerated()), id: \.offset) { index, rule in
                    RuleRow(rule: rule).tag(index)
                }
            }
            .listStyle(.inset)
            HStack {
                Button {
                    showingAddSheet = true
                } label: {
                    Image(systemName: "plus")
                }
                Button {
                    deleteSelected()
                } label: {
                    Image(systemName: "minus")
                }
                .disabled(selection == nil)
                Divider().frame(height: 16)
                Button {
                    move(by: -1)
                } label: {
                    Image(systemName: "arrow.up")
                }
                .disabled(!canMove(by: -1))
                Button {
                    move(by: 1)
                } label: {
                    Image(systemName: "arrow.down")
                }
                .disabled(!canMove(by: 1))
                Spacer()
            }
            .buttonStyle(.borderless)
            .padding(6)
        }
        .frame(minWidth: 260, idealWidth: 300)
    }

    @ViewBuilder
    private var detail: some View {
        if let selection, rules.indices.contains(selection) {
            RuleDetailEditor(manager: manager, index: selection, rule: rules[selection])
                .id(selection)
                .frame(minWidth: 380)
        } else {
            VStack {
                Spacer()
                Text("Select a rule, or add one.")
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .frame(minWidth: 380, maxHeight: .infinity)
        }
    }

    private func canMove(by delta: Int) -> Bool {
        guard let selection else { return false }
        let target = selection + delta
        return rules.indices.contains(target)
    }

    private func move(by delta: Int) {
        guard let selection, canMove(by: delta) else { return }
        let target = selection + delta
        if let error = manager.editConfig({ editor in editor.moveRule(from: selection, to: target) }) {
            errorMessage = error.description
        } else {
            errorMessage = nil
            self.selection = target
        }
    }

    private func deleteSelected() {
        guard let selection else { return }
        if let error = manager.editConfig({ editor in editor.removeRule(at: selection) }) {
            errorMessage = error.description
        } else {
            errorMessage = nil
            self.selection = nil
        }
    }

    private func addRule(_ fields: [ConfigField]) {
        var newIndex: Int?
        let error = manager.editConfig { editor in
            editor.appendRule(fields).map { index in
                newIndex = index
                return ()
            }
        }
        if let error {
            errorMessage = error.description
        } else {
            errorMessage = nil
            selection = newIndex
        }
    }
}

private struct RuleRow: View {
    let rule: AppRule

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(matchSummary).font(.body)
            Text(actionSummary)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    private var matchSummary: String {
        var parts: [String] = []
        let m = rule.match
        if let v = m.appID { parts.append("app_id: \(v)") }
        if let v = m.appName { parts.append("app_name: \(v)") }
        if let v = m.titleRegex { parts.append("title_regex: \(v.source)") }
        if let v = m.titleSubstring { parts.append("title_substring: \(v)") }
        if let v = m.axRole { parts.append("ax_role: \(v)") }
        if let v = m.axSubrole { parts.append("ax_subrole: \(v)") }
        return parts.isEmpty ? "(no match fields)" : parts.joined(separator: ", ")
    }

    private var actionSummary: String {
        var parts: [String] = []
        let a = rule.actions
        if let w = a.weight { parts.append("weight \(w.formatted())") }
        if a.manage == false { parts.append("unmanaged") }
        if a.float == true { parts.append("float") }
        if let p = a.placement {
            switch p {
            case .center: parts.append("placement: center")
            case .mouse: parts.append("placement: mouse")
            case .rect: parts.append("placement: custom")
            }
        }
        if a.size != nil { parts.append("sized") }
        if a.sticky == true { parts.append("sticky") }
        if let move = a.onSelfMove { parts.append("on-move: \(move.rawValue)") }
        return parts.isEmpty ? "default actions" : parts.joined(separator: ", ")
    }
}

/// Tri-state control for optional booleans that fall back to a default when unset.
private enum TriState: String, CaseIterable, Identifiable {
    case inherit = "Default"
    case yes = "Yes"
    case no = "No"
    var id: String { rawValue }

    init(_ value: Bool?) {
        switch value {
        case .none: self = .inherit
        case .some(true): self = .yes
        case .some(false): self = .no
        }
    }

    var value: Bool? {
        switch self {
        case .inherit: return nil
        case .yes: return true
        case .no: return false
        }
    }
}

private enum PlacementKind: String, CaseIterable, Identifiable {
    case none = "Default", center = "Center", mouse = "Mouse", custom = "Custom"
    var id: String { rawValue }
}

private struct RuleDetailEditor: View {
    let manager: WindowManager
    let index: Int

    @State private var appID: String
    @State private var appName: String
    @State private var titleRegex: String
    @State private var titleSubstring: String
    @State private var axRole: String
    @State private var axSubrole: String

    @State private var weightText: String
    @State private var manage: TriState
    @State private var float: TriState
    @State private var sticky: TriState
    @State private var onSelfMove: SelfMovePolicy?

    @State private var placementKind: PlacementKind
    @State private var placementX: String
    @State private var placementY: String
    @State private var placementW: String
    @State private var placementH: String

    @State private var hasSize: Bool
    @State private var sizeW: String
    @State private var sizeH: String

    @State private var errorMessage: String?

    init(manager: WindowManager, index: Int, rule: AppRule) {
        self.manager = manager
        self.index = index
        _appID = State(initialValue: rule.match.appID ?? "")
        _appName = State(initialValue: rule.match.appName ?? "")
        _titleRegex = State(initialValue: rule.match.titleRegex?.source ?? "")
        _titleSubstring = State(initialValue: rule.match.titleSubstring ?? "")
        _axRole = State(initialValue: rule.match.axRole ?? "")
        _axSubrole = State(initialValue: rule.match.axSubrole ?? "")

        _weightText = State(initialValue: rule.actions.weight.map { $0 == $0.rounded() ? String(Int($0)) : String($0) } ?? "")
        _manage = State(initialValue: TriState(rule.actions.manage))
        _float = State(initialValue: TriState(rule.actions.float))
        _sticky = State(initialValue: TriState(rule.actions.sticky))
        _onSelfMove = State(initialValue: rule.actions.onSelfMove)

        switch rule.actions.placement {
        case .none:
            _placementKind = State(initialValue: .none)
            _placementX = State(initialValue: "")
            _placementY = State(initialValue: "")
            _placementW = State(initialValue: "")
            _placementH = State(initialValue: "")
        case .center:
            _placementKind = State(initialValue: .center)
            _placementX = State(initialValue: "")
            _placementY = State(initialValue: "")
            _placementW = State(initialValue: "")
            _placementH = State(initialValue: "")
        case .mouse:
            _placementKind = State(initialValue: .mouse)
            _placementX = State(initialValue: "")
            _placementY = State(initialValue: "")
            _placementW = State(initialValue: "")
            _placementH = State(initialValue: "")
        case .rect(let x, let y, let w, let h):
            _placementKind = State(initialValue: .custom)
            _placementX = State(initialValue: String(x))
            _placementY = State(initialValue: String(y))
            _placementW = State(initialValue: String(w))
            _placementH = State(initialValue: String(h))
        }

        _hasSize = State(initialValue: rule.actions.size != nil)
        _sizeW = State(initialValue: rule.actions.size.map { String(Double($0.width)) } ?? "")
        _sizeH = State(initialValue: rule.actions.size.map { String(Double($0.height)) } ?? "")
    }

    var body: some View {
        Form {
            Section("Match") {
                CommitTextField(title: "App ID", text: $appID, prompt: "com.example.app", commit: commitAppID)
                CommitTextField(title: "App Name", text: $appName, prompt: "substring, any case", commit: commitAppName)
                CommitTextField(title: "Title Regex", text: $titleRegex, prompt: "regular expression", commit: commitTitleRegex)
                CommitTextField(title: "Title Substring", text: $titleSubstring, prompt: "substring, any case",
                                commit: commitTitleSubstring)
                CommitTextField(title: "AX Role", text: $axRole, prompt: "AXWindow", commit: commitAXRole)
                CommitTextField(title: "AX Subrole", text: $axSubrole, prompt: "AXDialog", commit: commitAXSubrole)
            }
            Section("Actions") {
                CommitTextField(title: "Weight", text: $weightText, prompt: "1 (default), up to 1000", commit: commitWeight)
                FormRow(title: "Manage") {
                    Picker("", selection: $manage) {
                        ForEach(TriState.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .labelsHidden()
                    .onChange(of: manage) { _, _ in commitManage() }
                }
                FormRow(title: "Float") {
                    Picker("", selection: $float) {
                        ForEach(TriState.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .labelsHidden()
                    .onChange(of: float) { _, _ in commitFloat() }
                }
                FormRow(title: "Sticky") {
                    Picker("", selection: $sticky) {
                        ForEach(TriState.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .labelsHidden()
                    .onChange(of: sticky) { _, _ in commitSticky() }
                }
                FormRow(title: "On Self-Move") {
                    Picker("", selection: $onSelfMove) {
                        Text("Default").tag(SelfMovePolicy?.none)
                        Text("Snap Back").tag(SelfMovePolicy?.some(.snapBack))
                        Text("Adopt").tag(SelfMovePolicy?.some(.adopt))
                    }
                    .labelsHidden()
                    .onChange(of: onSelfMove) { _, _ in commitOnSelfMove() }
                }
                FormRow(title: "Placement") {
                    Picker("", selection: $placementKind) {
                        ForEach(PlacementKind.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .labelsHidden()
                    .onChange(of: placementKind) { _, _ in commitPlacement() }
                }
                if placementKind == .custom {
                    FormRow(title: "X / Y / W / H") {
                        HStack {
                            CommitTextField(title: "X", text: $placementX, prompt: "x", commit: commitPlacement).labelsHidden()
                            CommitTextField(title: "Y", text: $placementY, prompt: "y", commit: commitPlacement).labelsHidden()
                            CommitTextField(title: "W", text: $placementW, prompt: "w", commit: commitPlacement).labelsHidden()
                            CommitTextField(title: "H", text: $placementH, prompt: "h", commit: commitPlacement).labelsHidden()
                        }
                    }
                }
                FormRow(title: "Size") {
                    Toggle("Custom size", isOn: $hasSize)
                        .labelsHidden()
                        .onChange(of: hasSize) { _, newValue in
                            if !newValue { commitSize() }
                        }
                }
                if hasSize {
                    FormRow(title: "W / H") {
                        HStack {
                            CommitTextField(title: "W", text: $sizeW, prompt: "w", commit: commitSize).labelsHidden()
                            CommitTextField(title: "H", text: $sizeH, prompt: "h", commit: commitSize).labelsHidden()
                        }
                    }
                }
            }
            if let errorMessage {
                InlineErrorText(message: errorMessage)
            }
        }
        .formStyle(.grouped)
    }

    private func fraction(_ text: String) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, let value = Double(trimmed) else { return nil }
        return value
    }

    private func commit(_ key: String, _ value: ConfigValue?) {
        if let error = manager.editConfig({ editor in editor.set(key, value, in: .rule(index)) }) {
            errorMessage = error.description
        } else {
            errorMessage = nil
        }
    }

    private func commitAppID() { commit("app_id", appID.isEmpty ? nil : .string(appID)) }
    private func commitAppName() { commit("app_name", appName.isEmpty ? nil : .string(appName)) }
    private func commitTitleSubstring() { commit("title_substring", titleSubstring.isEmpty ? nil : .string(titleSubstring)) }
    private func commitAXRole() { commit("ax_role", axRole.isEmpty ? nil : .string(axRole)) }
    private func commitAXSubrole() { commit("ax_subrole", axSubrole.isEmpty ? nil : .string(axSubrole)) }

    private func commitTitleRegex() {
        guard !titleRegex.isEmpty else {
            commit("title_regex", nil)
            return
        }
        do {
            _ = try NSRegularExpression(pattern: titleRegex)
            commit("title_regex", .string(titleRegex))
        } catch {
            errorMessage = "Invalid regular expression."
        }
    }

    private func commitWeight() {
        let trimmed = weightText.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            commit("weight", nil)
            return
        }
        guard let value = Double(trimmed), value > 0, value <= 1000 else {
            errorMessage = "Weight must be a number greater than 0 and at most 1000."
            return
        }
        commit("weight", value == value.rounded() ? .integer(Int(value)) : .float(value))
    }

    private func commitManage() { commit("manage", manage.value.map(ConfigValue.bool)) }
    private func commitFloat() { commit("float", float.value.map(ConfigValue.bool)) }
    private func commitSticky() { commit("sticky", sticky.value.map(ConfigValue.bool)) }
    private func commitOnSelfMove() { commit("on_self_move", onSelfMove.map { .string($0.rawValue) }) }

    private func commitPlacement() {
        switch placementKind {
        case .none:
            commit("placement", nil)
        case .center:
            commit("placement", .string("center"))
        case .mouse:
            commit("placement", .string("mouse"))
        case .custom:
            guard let x = fraction(placementX), let y = fraction(placementY),
                  let w = fraction(placementW), let h = fraction(placementH) else {
                errorMessage = "Enter x, y, w, h as numbers (display fractions 0…1)."
                return
            }
            commit("placement", .inlineTable([
                ConfigField("x", .float(x)), ConfigField("y", .float(y)),
                ConfigField("w", .float(w)), ConfigField("h", .float(h)),
            ]))
        }
    }

    private func commitSize() {
        guard hasSize else {
            commit("size", nil)
            return
        }
        guard let w = fraction(sizeW), let h = fraction(sizeH) else {
            errorMessage = "Enter w and h as numbers (display fractions, 0…1)."
            return
        }
        commit("size", .inlineTable([ConfigField("w", .float(w)), ConfigField("h", .float(h))]))
    }
}

/// Sheet for creating a new `[[rule]]`. Picking a running app pre-fills
/// `app_id`; the free-form fields cover everything else a first match needs.
private struct AddRuleSheet: View {
    @Environment(\.dismiss) private var dismiss
    let onAdd: ([ConfigField]) -> Void

    @State private var appID = ""
    @State private var appName = ""
    @State private var runningApps: [NSRunningApplication] = []
    @State private var selectedApp: NSRunningApplication?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New Rule").font(.headline)

            Text("Running Apps")
                .font(.subheadline)
            List(runningApps, id: \.processIdentifier, selection: $selectedApp) { app in
                HStack {
                    if let icon = app.icon {
                        Image(nsImage: icon).resizable().frame(width: 16, height: 16)
                    }
                    Text(app.localizedName ?? app.bundleIdentifier ?? "Unknown")
                    Spacer()
                    Text(app.bundleIdentifier ?? "").font(.caption).foregroundStyle(.secondary)
                }
                .tag(Optional(app))
            }
            .frame(minHeight: 160)
            .onChange(of: selectedApp) { _, newValue in
                if let bundleID = newValue?.bundleIdentifier { appID = bundleID }
            }

            Divider()

            Form {
                TextField("App ID", text: $appID, prompt: Text("com.example.app"))
                TextField("App Name", text: $appName, prompt: Text("optional substring match"))
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Add") {
                    var fields: [ConfigField] = []
                    if !appID.isEmpty { fields.append(ConfigField("app_id", .string(appID))) }
                    if !appName.isEmpty { fields.append(ConfigField("app_name", .string(appName))) }
                    onAdd(fields)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(appID.isEmpty && appName.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 420)
        .onAppear {
            runningApps = NSWorkspace.shared.runningApplications
                .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != nil }
                .sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") }
        }
    }
}
