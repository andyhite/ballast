import BallastCore
import SwiftUI

/// Master-grid/master-stack/BSP layout defaults, plus per-desktop overrides.
/// Every field carries its own "Inherit" toggle when a specific desktop is
/// selected: on means the key is absent from that desktop's `[[space]]`
/// block (it falls back to `[layout]`); off writes the field's current
/// effective value.
struct LayoutPane: View {
    @ObservedObject var model: ConfigModel
    @State private var scope: Scope = .defaults
    @State private var editError: String?

    private enum Scope: Hashable {
        case defaults
        case desktop(SpaceKey)
    }

    private var manager: WindowManager { model.manager }
    private var config: Config { model.config }
    private var editingDisabled: Bool { model.configError != nil }

    /// `nil` for `.defaults` (defaults never have an override to inherit from).
    private var overrides: LayoutOverrides? {
        guard case .desktop(let key) = scope else { return nil }
        return config.spaces[key]
    }

    private var effective: LayoutSettings {
        switch scope {
        case .defaults: config.layout
        case .desktop(let key): config.layoutSettings(for: key)
        }
    }

    var body: some View {
        Form {
            if let configError = model.configError {
                ConfigErrorBanner(message: configError)
            }

            Section {
                Picker("Editing", selection: $scope) {
                    Text("Defaults (all desktops)").tag(Scope.defaults)
                    ForEach(model.desktops, id: \.key) { desktop in
                        Text(desktopLabel(desktop)).tag(Scope.desktop(desktop.key))
                    }
                }
                .onChange(of: model.desktops) { _, desktops in
                    if case .desktop(let key) = scope, !desktops.contains(where: { $0.key == key }) {
                        scope = .defaults
                    }
                }
                if case .desktop = scope {
                    Text("Checked settings apply only to this desktop. Unchecked settings follow Defaults (all desktops).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .disabled(editingDisabled)

            Section("Master-Grid & Master-Stack") {
                fieldRow("Mode", inherited: modeInherited) {
                    Picker("", selection: Binding(
                        get: { modeSelection },
                        set: { commitMode($0) }
                    )) {
                        if case .defaults = scope {
                            Text(automaticModeLabel).tag(LayoutMode?.none)
                        }
                        ForEach(LayoutMode.allCases, id: \.self) { mode in
                            Text(modeLabel(mode)).tag(LayoutMode?.some(mode))
                        }
                    }
                    .labelsHidden()
                }
                fieldRow("Master Ratio", inherited: overrides?.masterRatio == nil) {
                    CommitSlider(
                        title: "", liveValue: effective.masterRatio, range: 0.1...0.9, step: 0.05,
                        format: { "\(Int(($0 * 100).rounded()))%" },
                        commit: { commitMasterRatio($0) }
                    )
                }
                fieldRow("Master Count", inherited: overrides?.masterCount == nil) {
                    CommitStepper(title: "", liveValue: effective.masterCount, range: 1...16) {
                        commitMasterCount($0)
                    }
                }
                fieldRow("Stack Side", inherited: overrides?.stackSide == nil) {
                    Picker("", selection: Binding(
                        get: { effective.stackSide },
                        set: { commitDesktopField("stack_side", .string($0.rawValue)) }
                    )) {
                        ForEach(StackSide.allCases, id: \.self) { side in
                            Text(side.rawValue.capitalized).tag(side)
                        }
                    }
                    .labelsHidden()
                }
                fieldRow("Stack Both Sides", inherited: overrides?.stackBothSides == nil) {
                    Toggle("", isOn: Binding(
                        get: { effective.stackBothSides },
                        set: { commitDesktopField("stack_both_sides", .bool($0)) }
                    ))
                    .labelsHidden()
                }
                fieldRow("Grid Max", inherited: overrides?.gridMax == nil) {
                    Stepper(
                        value: Binding(get: { effective.gridMax }, set: { commitDesktopField("grid_max", .integer($0)) }),
                        in: 0...16
                    ) {
                        Text(effective.gridMax == 0 ? "No limit" : "\(effective.gridMax)").monospacedDigit()
                    }
                }
                fieldRow("Grid Columns", inherited: overrides?.gridColumns == nil) {
                    Stepper(
                        value: Binding(get: { effective.gridColumns }, set: { commitDesktopField("grid_columns", .integer($0)) }),
                        in: 1...8
                    ) {
                        Text("\(effective.gridColumns)").monospacedDigit()
                    }
                }
                fieldRow("Stack Peek", inherited: overrides?.stackPeek == nil) {
                    Stepper(
                        value: Binding(get: { Int(effective.stackPeek) }, set: { commitDesktopField("stack_peek", .integer($0)) }),
                        in: 0...200, step: 2
                    ) {
                        Text("\(Int(effective.stackPeek)) pt").monospacedDigit()
                    }
                }
            }
            .disabled(editingDisabled)

            Section("BSP") {
                fieldRow("Split Direction", inherited: splitInherited) {
                    Picker("", selection: Binding(
                        get: { effective.split },
                        set: { commitDesktopField("split", $0.map { .string($0.rawValue) } ?? .string("auto")) }
                    )) {
                        Text("Auto").tag(BallastCore.Axis?.none)
                        Text("Horizontal").tag(BallastCore.Axis?.some(.horizontal))
                        Text("Vertical").tag(BallastCore.Axis?.some(.vertical))
                    }
                    .labelsHidden()
                }
                fieldRow("Arrangement", inherited: overrides?.bspShape == nil) {
                    Picker("", selection: Binding(
                        get: { effective.bspShape },
                        set: { commitDesktopField("bsp_shape", .string($0.rawValue)) }
                    )) {
                        Text("Dwindle").tag(BSPShape.dwindle)
                        Text("Balanced").tag(BSPShape.balanced)
                    }
                    .labelsHidden()
                }
            }
            .disabled(editingDisabled)

            Section("Weights") {
                weightShareRow
            }
            .disabled(editingDisabled)

            Section("Gaps") {
                fieldRow("Inner Gap", inherited: overrides?.gapsInner == nil) {
                    CommitStepper(title: "", liveValue: Int(effective.gaps.inner), range: 0...200) {
                        commitGaps(inner: Double($0), outer: nil)
                    }
                }
                fieldRow("Outer Gap", inherited: overrides?.gapsOuter == nil) {
                    CommitStepper(title: "", liveValue: Int(effective.gaps.outer), range: 0...200) {
                        commitGaps(inner: nil, outer: Double($0))
                    }
                }
            }
            .disabled(editingDisabled)

            if case .desktop(let key) = scope {
                Section {
                    Button("Remove All Overrides for This Desktop", role: .destructive) {
                        removeAllOverrides(key)
                    }
                }
                .disabled(editingDisabled || overrides == nil)
            }

            if !staleSpaces.isEmpty {
                Section("Disconnected Displays") {
                    ForEach(staleSpaces, id: \.self) { key in
                        HStack {
                            Text("Disconnected display \(shortUUID(key.display)) — Desktop \(key.ordinal)")
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button("Remove") { removeSpace(key) }
                        }
                    }
                }
                .disabled(editingDisabled)
            }

            if let editError {
                InlineErrorText(message: editError)
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    // MARK: - Rows

    @ViewBuilder
    private func fieldRow<Content: View>(_ title: String, inherited: Bool, @ViewBuilder content: () -> Content) -> some View {
        if case .desktop = scope {
            HStack {
                Toggle(title, isOn: Binding(
                    get: { !inherited },
                    set: { toggleInherit(title, inheriting: !$0) }
                ))
                .toggleStyle(.checkbox)
                .lineLimit(1)
                .fixedSize()
                .frame(minWidth: 160, alignment: .leading)
                content()
                    .disabled(inherited)
                    .opacity(inherited ? 0.55 : 1)
            }
        } else {
            HStack {
                Text(title)
                    .lineLimit(1)
                    .fixedSize()
                    .frame(minWidth: 160, alignment: .leading)
                content()
            }
        }
    }

    private var weightShareRow: some View {
        let inherited = overrides?.bspMinRatio == nil && overrides?.bspMaxRatio == nil
        let symmetric = abs(effective.bspMinRatio - (1 - effective.bspMaxRatio)) < 0.001
        return fieldRow("Weight Share Limit", inherited: inherited) {
            if symmetric {
                CommitSlider(
                    title: "", liveValue: effective.bspMaxRatio, range: 0.5...0.95, step: 0.05,
                    format: { "\(Int(($0 * 100).rounded()))% / \(Int(((1 - $0) * 100).rounded()))%" },
                    commit: { commitWeightShare(max: $0) }
                )
            } else {
                HStack {
                    Text("min \(Int((effective.bspMinRatio * 100).rounded()))% / max \(Int((effective.bspMaxRatio * 100).rounded()))%")
                        .foregroundStyle(.secondary)
                    Slider(value: Binding(
                        get: { effective.bspMaxRatio },
                        set: { commitWeightShare(max: $0) }
                    ), in: 0.5...0.95, step: 0.05)
                }
            }
        }
    }

    // MARK: - Derived data

    private var staleSpaces: [SpaceKey] {
        let connected = Set(model.desktops.map(\.key))
        return config.spaces.keys.filter { !connected.contains($0) }.sorted { $0.description < $1.description }
    }

    private var modeInherited: Bool { overrides?.mode == nil }

    /// Defaults: the `[layout]` mode, `nil` for automatic. A desktop: the
    /// mode it resolves to on its display.
    private var modeSelection: LayoutMode? {
        switch scope {
        case .defaults: config.layout.mode
        case .desktop(let key): effective.mode(builtin: model.desktops.first { $0.key == key }?.builtin ?? false)
        }
    }

    private var automaticModeLabel: String {
        let automatic = LayoutSettings()
        return "Automatic (\(modeLabel(automatic.mode(builtin: true))) on Built-in, \(modeLabel(automatic.mode(builtin: false))) on External)"
    }

    private var splitInherited: Bool { splitOverride == nil }

    /// `overrides?.split` on a `Axis??` field: `nil` at the outer level means
    /// "no override", `.some(nil)` means "overridden to auto".
    private var splitOverride: BallastCore.Axis?? {
        guard case .desktop(let key) = scope, let o = config.spaces[key] else { return nil }
        return o.split
    }

    private func desktopLabel(_ desktop: WindowManager.DesktopInfo) -> String {
        "\(desktop.displayName) — Desktop \(desktop.key.ordinal)" + (desktop.isActive ? " (active)" : "")
    }

    private func modeLabel(_ mode: LayoutMode) -> String {
        switch mode {
        case .masterGrid: "Master-Grid"
        case .masterStack: "Master-Stack"
        case .bsp: "BSP"
        case .float: "Float (Passthrough)"
        }
    }

    private func shortUUID(_ uuid: String) -> String {
        String(uuid.prefix(8))
    }

    // MARK: - Commits

    private func spaceID(for key: SpaceKey) -> SpaceID? {
        model.desktops.first(where: { $0.key == key })?.space
    }

    private func setError(_ error: ConfigEditError?) {
        editError = error?.description
    }

    private func commitMode(_ mode: LayoutMode?) {
        switch scope {
        case .defaults:
            setError(manager.editConfig { $0.set("mode", mode.map { .string($0.rawValue) }, in: .layout) })
        case .desktop(let key):
            guard let mode, let space = spaceID(for: key) else { return }
            setError(manager.setSpaceSetting("mode", .string(mode.rawValue), space: space))
        }
    }

    private func commitMasterRatio(_ value: Double) {
        switch scope {
        case .defaults:
            setError(manager.editConfig { $0.set("master_ratio", .float(value), in: .layout) })
        case .desktop(let key):
            guard let space = spaceID(for: key) else { return }
            setError(manager.setSpaceSetting("master_ratio", .float(value), space: space))
        }
    }

    private func commitMasterCount(_ value: Int) {
        switch scope {
        case .defaults:
            setError(manager.editConfig { $0.set("master_count", .integer(value), in: .layout) })
        case .desktop(let key):
            guard let space = spaceID(for: key) else { return }
            setError(manager.setSpaceSetting("master_count", .integer(value), space: space))
        }
    }

    /// Every field besides mode/master_ratio/master_count, which are covered
    /// by `setSpaceSetting` (it also clears the matching runtime override).
    private func commitDesktopField(_ key: String, _ value: ConfigValue?) {
        switch scope {
        case .defaults:
            setError(manager.editConfig { $0.set(key, value, in: .layout) })
        case .desktop(let spaceKey):
            setError(manager.editConfig { $0.set(key, value, in: .space(spaceKey)) })
        }
    }

    private func commitWeightShare(max: Double) {
        let min = 1 - max
        commitDesktopField("bsp_min_ratio", .float(min))
        commitDesktopField("bsp_max_ratio", .float(max))
    }

    private func commitGaps(inner: Double?, outer: Double?) {
        let newInner = inner ?? overrides?.gapsInner
        let newOuter = outer ?? overrides?.gapsOuter
        // Only fields that already have (or are gaining) an override belong
        // in the inline table; an untouched, still-inherited field is left
        // out entirely so it keeps falling back to `[layout]`.
        var fields: [ConfigField] = []
        if let newInner { fields.append(ConfigField("inner", .float(newInner))) }
        if let newOuter { fields.append(ConfigField("outer", .float(newOuter))) }
        commitDesktopField("gaps", fields.isEmpty ? nil : .inlineTable(fields))
    }

    private func toggleInherit(_ title: String, inheriting: Bool) {
        guard case .desktop = scope else { return }
        switch title {
        case "Mode":
            commitMode0(inheriting ? nil : modeSelection)
        case "Master Ratio":
            commitMasterRatio0(inheriting ? nil : effective.masterRatio)
        case "Master Count":
            commitMasterCount0(inheriting ? nil : effective.masterCount)
        case "Stack Side":
            commitDesktopField("stack_side", inheriting ? nil : .string(effective.stackSide.rawValue))
        case "Stack Both Sides":
            commitDesktopField("stack_both_sides", inheriting ? nil : .bool(effective.stackBothSides))
        case "Grid Max":
            commitDesktopField("grid_max", inheriting ? nil : .integer(effective.gridMax))
        case "Grid Columns":
            commitDesktopField("grid_columns", inheriting ? nil : .integer(effective.gridColumns))
        case "Stack Peek":
            commitDesktopField("stack_peek", inheriting ? nil : .integer(Int(effective.stackPeek)))
        case "Split Direction":
            commitDesktopField("split", inheriting ? nil : .string(effective.split?.rawValue ?? "auto"))
        case "Arrangement":
            commitDesktopField("bsp_shape", inheriting ? nil : .string(effective.bspShape.rawValue))
        case "Weight Share Limit":
            if inheriting {
                commitDesktopField("bsp_min_ratio", nil)
                commitDesktopField("bsp_max_ratio", nil)
            } else {
                commitDesktopField("bsp_min_ratio", .float(effective.bspMinRatio))
                commitDesktopField("bsp_max_ratio", .float(effective.bspMaxRatio))
            }
        case "Inner Gap":
            commitGapsInherit(inner: inheriting ? nil : effective.gaps.inner, clearInner: inheriting)
        case "Outer Gap":
            commitGapsInherit(outer: inheriting ? nil : effective.gaps.outer, clearOuter: inheriting)
        default:
            break
        }
    }

    /// Wrappers so `setSpaceSetting`'s `nil` (remove key) path is reachable
    /// from the inherit toggle without duplicating the scope switch above.
    private func commitMode0(_ mode: LayoutMode?) {
        guard case .desktop(let key) = scope, let space = spaceID(for: key) else { return }
        setError(manager.setSpaceSetting("mode", mode.map { .string($0.rawValue) }, space: space))
    }

    private func commitMasterRatio0(_ value: Double?) {
        guard case .desktop(let key) = scope, let space = spaceID(for: key) else { return }
        setError(manager.setSpaceSetting("master_ratio", value.map { .float($0) }, space: space))
    }

    private func commitMasterCount0(_ value: Int?) {
        guard case .desktop(let key) = scope, let space = spaceID(for: key) else { return }
        setError(manager.setSpaceSetting("master_count", value.map { .integer($0) }, space: space))
    }

    private func commitGapsInherit(inner: Double? = nil, outer: Double? = nil, clearInner: Bool = false, clearOuter: Bool = false) {
        let newInner = clearInner ? nil : (inner ?? overrides?.gapsInner)
        let newOuter = clearOuter ? nil : (outer ?? overrides?.gapsOuter)
        var fields: [ConfigField] = []
        if let newInner { fields.append(ConfigField("inner", .float(newInner))) }
        if let newOuter { fields.append(ConfigField("outer", .float(newOuter))) }
        commitDesktopField("gaps", fields.isEmpty ? nil : .inlineTable(fields))
    }

    private func removeAllOverrides(_ key: SpaceKey) {
        if let space = spaceID(for: key) {
            _ = manager.setSpaceSetting("mode", nil, space: space)
        }
        setError(manager.editConfig { $0.removeSpace(key) })
    }

    private func removeSpace(_ key: SpaceKey) {
        setError(manager.editConfig { $0.removeSpace(key) })
    }
}
