import Testing
import BallastCore
@testable import BallastApp

/// Regression tests for the pure merge/conflict helpers backing the
/// Preferences Layout and Bindings panes. These exercise the extracted
/// static helpers directly: no live window manager, AX, hotkey
/// registration, or user config is touched.
@Suite
struct PreferencesTests {
    // MARK: Layout pane — Defaults-scope gap preservation

    /// audit4: editing one gap component in Defaults scope must not drop
    /// the other, untouched component back to zero.
    @Test
    func defaultsGapEditPreservesUntouchedComponent() {
        let fields = LayoutPane.mergedGapFields(
            scope: .defaults, inner: 10, outer: nil,
            overrideInner: nil, overrideOuter: nil,
            effectiveInner: 8, effectiveOuter: 20)
        let dict = Dictionary(uniqueKeysWithValues: fields.map { ($0.key, $0.value) })
        #expect(dict["inner"] == .float(10))
        #expect(dict["outer"] == .float(20))
    }

    @Test
    func defaultsGapEditOuterPreservesInner() {
        let fields = LayoutPane.mergedGapFields(
            scope: .defaults, inner: nil, outer: 20,
            overrideInner: nil, overrideOuter: nil,
            effectiveInner: 8, effectiveOuter: 20)
        let dict = Dictionary(uniqueKeysWithValues: fields.map { ($0.key, $0.value) })
        #expect(dict["inner"] == .float(8))
        #expect(dict["outer"] == .float(20))
    }

    /// Per-desktop scope keeps its existing override semantics: an
    /// untouched, still-inherited component stays out of the inline table.
    @Test
    func desktopScopeGapEditKeepsInheritedComponentAbsent() {
        let fields = LayoutPane.mergedGapFields(
            scope: .desktop(SpaceKey(display: "A", ordinal: 0)), inner: 10, outer: nil,
            overrideInner: nil, overrideOuter: nil,
            effectiveInner: 8, effectiveOuter: 20)
        let dict = Dictionary(uniqueKeysWithValues: fields.map { ($0.key, $0.value) })
        #expect(dict["inner"] == .float(10))
        #expect(dict["outer"] == nil)
    }

    @Test
    func desktopScopeGapEditPreservesExistingOverride() {
        let fields = LayoutPane.mergedGapFields(
            scope: .desktop(SpaceKey(display: "A", ordinal: 0)), inner: 10, outer: nil,
            overrideInner: nil, overrideOuter: 5,
            effectiveInner: 8, effectiveOuter: 5)
        let dict = Dictionary(uniqueKeysWithValues: fields.map { ($0.key, $0.value) })
        #expect(dict["inner"] == .float(10))
        #expect(dict["outer"] == .float(5))
    }

    // MARK: Bindings pane — duplicate-hotkey conflicts

    /// Parses a `[bindings]` table via the real `Config.parse` (the same
    /// path the app uses) so `KeyBinding` values are genuine, without
    /// needing an internal-only initializer from a different module.
    private func bindings(_ toml: String) throws -> [KeyBinding] {
        let config = try Config.parse("[bindings]\n\(toml)\n").get()
        return config.bindings
    }

    /// audit9: adding a binding with a hotkey already used elsewhere must
    /// be rejected, same literal spelling.
    @Test
    func addSameSpellingConflictIsRejected() throws {
        let existing = try bindings("\"alt+j\" = \"focus down\"")
        let newHotkey = try Hotkey.parse("alt+j").get()
        let conflict = BindingsPane.conflictingBinding(newHotkey, excluding: nil, in: existing)
        #expect(conflict?.commandText == "focus down")
    }

    /// Alias spelling (`hyper+r` vs `ctrl+alt+shift+cmd+r`) must still
    /// conflict, since `Hotkey` normalizes both to the same combination.
    @Test
    func addAliasSpellingConflictIsRejected() throws {
        let existing = try bindings("\"hyper+r\" = \"reload\"")
        let newHotkey = try Hotkey.parse("ctrl+alt+shift+cmd+r").get()
        let conflict = BindingsPane.conflictingBinding(newHotkey, excluding: nil, in: existing)
        #expect(conflict?.commandText == "reload")
    }

    /// Editing a binding's own entry must succeed even when its canonical
    /// spelling changes, since it is excluded via its literal key.
    @Test
    func editingOwnBindingWithCanonicalSpellingChangeSucceeds() throws {
        let existing = try bindings("\"hyper+r\" = \"reload\"")
        let sameHotkey = try Hotkey.parse("ctrl+alt+shift+cmd+r").get()
        let conflict = BindingsPane.conflictingBinding(sameHotkey, excluding: "hyper+r", in: existing)
        #expect(conflict == nil)
    }

    /// Editing a binding to a genuinely different, already-used hotkey
    /// must still be rejected.
    @Test
    func editingToAnotherBindingsHotkeyIsRejected() throws {
        let existing = try bindings("\"alt+j\" = \"focus down\"\n\"alt+k\" = \"focus up\"")
        let newHotkey = try Hotkey.parse("alt+j").get()
        let conflict = BindingsPane.conflictingBinding(newHotkey, excluding: "alt+k", in: existing)
        #expect(conflict?.commandText == "focus down")
    }
}

