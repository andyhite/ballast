import BallastCore
import SwiftUI

/// Which settings the Layout pane edits: the `[layout]` defaults or one
/// desktop's `[[space]]` overrides.
enum LayoutScope: Hashable {
    case defaults
    case desktop(SpaceKey)
}

/// Arrangement, feature, and deck defaults, plus per-desktop overrides.
/// Every field carries its own "Inherit" toggle when a specific desktop is
/// selected: on means the key is absent from that desktop's `[[space]]`
/// block (it falls back to `[layout]`); off writes the field's current
/// effective value.
struct LayoutPane: View {
    @ObservedObject var model: ConfigModel
    @State private var editError: String?

    private var scope: LayoutScope { model.layoutScope }

    private var manager: WindowManager { model.manager }
    private var config: Config { model.config }
    private var editingDisabled: Bool { model.configError != nil }

    /// `nil` for `.defaults` (defaults never have an override to inherit from).
    private var overrides: LayoutOverrides? {
        guard case .desktop(let key) = scope else { return nil }
        return config.overrides(for: key)
    }

    private var effective: LayoutSettings {
        switch scope {
        case .defaults: config.layoutDefaults(small: false)
        case .desktop(let key):
            config.layoutSettings(for: key, small: manager.engine.snapshot.isSmall(display: key.display))
        }
    }

    var body: some View {
        Form {
            if let configError = model.configError {
                ConfigErrorBanner(message: configError)
            }

            Section {
                Picker("Editing", selection: $model.layoutScope) {
                    Text("Defaults (all desktops)").tag(LayoutScope.defaults)
                    ForEach(model.desktops, id: \.key) { desktop in
                        Text(desktopLabel(desktop)).tag(LayoutScope.desktop(desktop.key))
                    }
                }
                .onChange(of: model.desktops) { _, desktops in
                    if case .desktop(let key) = scope, !desktops.contains(where: { $0.key == key }) {
                        model.layoutScope = .defaults
                    }
                }
                if case .desktop = scope {
                    Text("Checked settings apply only to this desktop. Unchecked settings follow Defaults (all desktops).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("A setting you change here applies to every screen. One left unset follows the built-in default for its screen: small (visible width under \(Int(LayoutSettings.smallWidth)) pt, every MacBook) or large.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .disabled(editingDisabled)

            Section("Arrangement & feature") {
                fieldRow("Arrangement", inherited: overrides?.arrange == nil,
                         builtin: builtin(config.layout.arrange != nil) { $0.arrange.label }) {
                    Picker("Arrangement", selection: Binding(
                        get: { effective.arrange },
                        set: { commitDesktopField("arrange", .string($0.rawValue)) }
                    )) {
                        ForEach(Arrangement.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    .labelsHidden()
                }
                fieldRow("Feature", inherited: overrides?.feature == nil,
                         builtin: builtin(config.layout.feature != nil) { $0.feature.label }) {
                    Picker("Feature", selection: Binding(
                        get: { effective.feature },
                        set: { commitDesktopField("feature", .string($0.rawValue)) }
                    )) {
                        ForEach(FeatureSide.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    .labelsHidden()
                }
                fieldRow("Feature Size", inherited: overrides?.featureSize == nil,
                         builtin: builtin(config.layout.featureSize != nil) { "\(Int(($0.featureSize * 100).rounded()))%" }) {
                    CommitSlider(
                        title: "", accessibilityName: "Feature Size", liveValue: effective.featureSize, range: 0.1...0.9, step: 0.05,
                        format: { "\(Int(($0 * 100).rounded()))%" },
                        commit: { commitFeatureSize($0) }
                    )
                }
                fieldRow("Feature Count", inherited: overrides?.featureCount == nil,
                         builtin: builtin(config.layout.featureCount != nil) { "\($0.featureCount)" }) {
                    CommitStepper(title: "", accessibilityName: "Feature Count", liveValue: effective.featureCount, range: 1...16) {
                        commitFeatureCount($0)
                    }
                }
                fieldRow("Columns", inherited: overrides?.columns == nil,
                         builtin: builtin(config.layout.columns != nil) { "\($0.columns)" }) {
                    Stepper(
                        value: Binding(get: { effective.columns }, set: { commitDesktopField("columns", .integer($0)) }),
                        in: 1...8
                    ) {
                        Text("\(effective.columns)").monospacedDigit()
                    }
                }
                fieldRow("Rows", inherited: overrides?.rows == nil,
                         builtin: builtin(config.layout.rows != nil) { $0.rows == 0 ? "no cap" : "\($0.rows)" }) {
                    Stepper(
                        value: Binding(get: { effective.rows }, set: { commitDesktopField("rows", .integer($0)) }),
                        in: 0...16
                    ) {
                        Text(effective.rows == 0 ? "No cap" : "\(effective.rows)").monospacedDigit()
                    }
                }
                fieldRow("Deck Peek", inherited: overrides?.deckPeek == nil,
                         builtin: builtin(config.layout.deckPeek != nil) { "\(Int($0.deckPeek)) pt" }) {
                    Stepper(
                        value: Binding(get: { Int(effective.deckPeek) }, set: { commitDesktopField("deck_peek", .integer($0)) }),
                        in: 0...200, step: 2
                    ) {
                        Text("\(Int(effective.deckPeek)) pt").monospacedDigit()
                    }
                }
            }
            .disabled(editingDisabled)

            Section("Float") {
                fieldRow("New Windows", inherited: overrides?.floatPlacement == nil) {
                    Picker("New Windows", selection: Binding(
                        get: { effective.floatPlacement },
                        set: { commitDesktopField("float_placement", .string($0.rawValue)) }
                    )) {
                        Text("Cascade").tag(FloatPlacement.cascade)
                        Text("Leave where they open").tag(FloatPlacement.none)
                    }
                    .labelsHidden()
                }
            }
            .disabled(editingDisabled)

            Section("BSP") {
                fieldRow("Split Direction", inherited: splitInherited) {
                    Picker("Split Direction", selection: Binding(
                        get: { effective.split },
                        set: { commitDesktopField("split", $0.map { .string($0.rawValue) } ?? .string("auto")) }
                    )) {
                        Text("Auto").tag(BallastCore.Axis?.none)
                        Text("Horizontal").tag(BallastCore.Axis?.some(.horizontal))
                        Text("Vertical").tag(BallastCore.Axis?.some(.vertical))
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
                    CommitStepper(title: "", accessibilityName: "Inner Gap", liveValue: Int(effective.gaps.inner), range: 0...200) {
                        commitGaps(inner: Double($0), outer: nil)
                    }
                }
                fieldRow("Outer Gap", inherited: overrides?.gapsOuter == nil) {
                    CommitStepper(title: "", accessibilityName: "Outer Gap", liveValue: Int(effective.gaps.outer), range: 0...200) {
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
                Section("Disconnected Desktops") {
                    ForEach(staleSpaces, id: \.self) { address in
                        HStack {
                            Text(staleLabel(address))
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button("Remove") { removeSpace(address) }
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

    /// In the Defaults scope, what a key `[layout]` does not set falls back to:
    /// the built-in default of each screen class.
    private func builtin(_ isSet: Bool, _ value: (LayoutSettings) -> String) -> String? {
        guard case .defaults = scope, !isSet else { return nil }
        let small = value(.defaults(small: true)), large = value(.defaults(small: false))
        return small == large
            ? "Not set — built-in default: \(small)"
            : "Not set — built-in default: small screen \(small), large screen \(large)"
    }

    @ViewBuilder
    private func fieldRow<Content: View>(_ title: String, inherited: Bool, builtin: String? = nil,
                                         @ViewBuilder content: () -> Content) -> some View {
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
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(title)
                        .lineLimit(1)
                        .fixedSize()
                        .frame(minWidth: 160, alignment: .leading)
                    content()
                }
                if let builtin {
                    Text(builtin)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }


    private var weightShareRow: some View {
        let inherited = overrides?.weightShareMin == nil && overrides?.weightShareMax == nil
        let symmetric = abs(effective.weightShareMin - (1 - effective.weightShareMax)) < 0.001
        return fieldRow("Weight Share Limit", inherited: inherited) {
            CommitSlider(
                title: "", accessibilityName: "Weight Share Limit", liveValue: effective.weightShareMax, range: 0.5...0.95, step: 0.05,
                format: symmetric
                    ? { "\(Int(($0 * 100).rounded()))% / \(Int(((1 - $0) * 100).rounded()))%" }
                    : { "max \(Int(($0 * 100).rounded()))% (min \(Int((effective.weightShareMin * 100).rounded()))%)" },
                commit: { commitWeightShare(max: $0) }
            )
        }
    }

    // MARK: - Derived data

    /// Config entries that match none of the connected desktops.
    private var staleSpaces: [SpaceAddress] {
        let connected = Set(model.desktops.flatMap(\.key.addresses))
        return config.spaces.keys.filter { !connected.contains($0) }.sorted()
    }

    private func staleLabel(_ address: SpaceAddress) -> String {
        switch address {
        case .uuid(let uuid): "Missing desktop \(shortUUID(uuid))"
        case .position(let display, let ordinal): "Disconnected display \(shortUUID(display)) — Desktop \(ordinal)"
        }
    }


    private var splitInherited: Bool { splitOverride == nil }

    /// `overrides?.split` on a `Axis??` field: `nil` at the outer level means
    /// "no override", `.some(nil)` means "overridden to auto".
    private var splitOverride: BallastCore.Axis?? {
        guard case .desktop(let key) = scope, let o = config.overrides(for: key) else { return nil }
        return o.split
    }

    private func desktopLabel(_ desktop: WindowManager.DesktopInfo) -> String {
        "\(desktop.displayName) — Desktop \(desktop.key.ordinal)" + (desktop.isActive ? " (active)" : "")
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

    private func commitFeatureSize(_ value: Double) {
        switch scope {
        case .defaults:
            setError(manager.configStore.edit { $0.set("feature_size", .float(value), in: .layout) })
        case .desktop(let key):
            guard let space = spaceID(for: key) else { return }
            setError(manager.configStore.setSpaceSetting("feature_size", .float(value), space: space))
        }
    }

    private func commitFeatureCount(_ value: Int) {
        switch scope {
        case .defaults:
            setError(manager.configStore.edit { $0.set("feature_count", .integer(value), in: .layout) })
        case .desktop(let key):
            guard let space = spaceID(for: key) else { return }
            setError(manager.configStore.setSpaceSetting("feature_count", .integer(value), space: space))
        }
    }

    /// Every field besides feature_size/feature_count, which are covered
    /// by `setSpaceSetting` (it also clears the matching runtime override).
    private func commitDesktopField(_ key: String, _ value: ConfigValue?) {
        switch scope {
        case .defaults:
            setError(manager.configStore.edit { $0.set(key, value, in: .layout) })
        case .desktop(let spaceKey):
            let address = config.writeAddress(for: spaceKey)
            setError(manager.configStore.edit { $0.set(key, value, in: .space(address)) })
        }
    }

    private func commitWeightShare(max: Double) { commitWeightPair(min: 1 - max, max: max) }

    /// Both limits in one transaction: validation rejects min > max, so
    /// writing them one at a time can fail against the other's old value.
    private func commitWeightPair(min: Double?, max: Double?) {
        let section: ConfigSection
        switch scope {
        case .defaults: section = .layout
        case .desktop(let key): section = .space(config.writeAddress(for: key))
        }
        setError(manager.configStore.edit { editor in
            if case .failure(let error) = editor.set("weight_share_min", min.map { .float($0) }, in: section) { return .failure(error) }
            return editor.set("weight_share_max", max.map { .float($0) }, in: section)
        })
    }

    /// Pure merge used by `commitGaps`/`commitGapsInherit`: an untouched
    /// component keeps falling back to whatever it currently resolves to
    /// so it is neither lost nor reset when the inline table is rewritten.
    /// `.desktop` scope falls back to the existing override (`nil` keeps
    /// inheriting from `[layout]`); `.defaults` scope has no override to
    /// fall back to, so it must use the current effective (`[layout]`)
    /// value instead.
    static func mergedGapFields(
        scope: LayoutScope, inner: Double?, outer: Double?,
        overrideInner: Double?, overrideOuter: Double?,
        effectiveInner: Double, effectiveOuter: Double
    ) -> [ConfigField] {
        let fallbackInner: Double?
        let fallbackOuter: Double?
        switch scope {
        case .defaults:
            fallbackInner = effectiveInner
            fallbackOuter = effectiveOuter
        case .desktop:
            fallbackInner = overrideInner
            fallbackOuter = overrideOuter
        }
        let newInner = inner ?? fallbackInner
        let newOuter = outer ?? fallbackOuter
        // Only fields that already have (or are gaining) an override belong
        // in the inline table; an untouched, still-inherited field is left
        // out entirely so it keeps falling back to `[layout]`.
        var fields: [ConfigField] = []
        if let newInner { fields.append(ConfigField("inner", .float(newInner))) }
        if let newOuter { fields.append(ConfigField("outer", .float(newOuter))) }
        return fields
    }

    private func commitGaps(inner: Double?, outer: Double?) {
        let fields = Self.mergedGapFields(
            scope: scope, inner: inner, outer: outer,
            overrideInner: overrides?.gapsInner, overrideOuter: overrides?.gapsOuter,
            effectiveInner: effective.gaps.inner, effectiveOuter: effective.gaps.outer)
        commitDesktopField("gaps", fields.isEmpty ? nil : .inlineTable(fields))
    }

    private func toggleInherit(_ title: String, inheriting: Bool) {
        guard case .desktop = scope else { return }
        switch title {
        case "Arrangement":
            commitDesktopField("arrange", inheriting ? nil : .string(effective.arrange.rawValue))
        case "Feature":
            commitDesktopField("feature", inheriting ? nil : .string(effective.feature.rawValue))
        case "New Windows":
            commitDesktopField("float_placement", inheriting ? nil : .string(effective.floatPlacement.rawValue))
        case "Feature Size":
            commitFeatureSize0(inheriting ? nil : effective.featureSize)
        case "Feature Count":
            commitFeatureCount0(inheriting ? nil : effective.featureCount)
        case "Columns":
            commitDesktopField("columns", inheriting ? nil : .integer(effective.columns))
        case "Rows":
            commitDesktopField("rows", inheriting ? nil : .integer(effective.rows))
        case "Deck Peek":
            commitDesktopField("deck_peek", inheriting ? nil : .integer(Int(effective.deckPeek)))
        case "Split Direction":
            commitDesktopField("split", inheriting ? nil : .string(effective.split?.rawValue ?? "auto"))
        case "Weight Share Limit":
            commitWeightPair(min: inheriting ? nil : effective.weightShareMin, max: inheriting ? nil : effective.weightShareMax)
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
    private func commitFeatureSize0(_ value: Double?) {
        guard case .desktop(let key) = scope, let space = spaceID(for: key) else { return }
        setError(manager.configStore.setSpaceSetting("feature_size", value.map { .float($0) }, space: space))
    }

    private func commitFeatureCount0(_ value: Int?) {
        guard case .desktop(let key) = scope, let space = spaceID(for: key) else { return }
        setError(manager.configStore.setSpaceSetting("feature_count", value.map { .integer($0) }, space: space))
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
            _ = manager.configStore.setSpaceSetting("feature_size", nil, space: space)
            _ = manager.configStore.setSpaceSetting("feature_count", nil, space: space)
        }
        setError(manager.configStore.edit { $0.removeSpaces(for: key) })
    }

    private func removeSpace(_ address: SpaceAddress) {
        setError(manager.configStore.edit { $0.removeSpace(address) })
    }
}
