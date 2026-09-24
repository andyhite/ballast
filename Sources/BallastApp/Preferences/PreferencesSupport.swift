import AppKit
import BallastCore
import SwiftUI

/// Live snapshot of `WindowManager.config`/`configError`/`desktops`, refreshed
/// whenever `WindowManager.configDidChange` fires. Shared by every
/// Preferences pane so edits made in one tab show up immediately in another.
/// Also holds the selected tab and Layout scope, so the menu bar can open the
/// window straight onto one desktop's settings.
final class ConfigModel: ObservableObject {
    let manager: WindowManager
    @Published private(set) var config: Config
    @Published private(set) var configError: String?
    @Published private(set) var desktops: [WindowManager.DesktopInfo]
    @Published var tab: PreferencesTab = .general
    @Published var layoutScope: LayoutScope = .defaults

    private var token: NSObjectProtocol?

    init(manager: WindowManager) {
        self.manager = manager
        config = manager.config
        configError = manager.configError
        desktops = manager.desktops
        token = NotificationCenter.default.addObserver(
            forName: WindowManager.configDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            self?.refresh()
        }
    }

    deinit {
        if let token { NotificationCenter.default.removeObserver(token) }
    }

    func refresh() {
        config = manager.config
        configError = manager.configError
        desktops = manager.desktops
    }
}

/// Banner shown at the top of a pane while the config file on disk fails to
/// parse: the previous config stays live, but editing it further would be
/// edited blind, so panes disable their controls while this is visible.
struct ConfigErrorBanner: View {
    let message: String

    var body: some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .font(.callout)
            .foregroundStyle(.orange)
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
    }
}

/// A label + trailing control, laid out consistently across panes.
struct FormRow<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            content()
        }
    }
}

/// A labeled text field that commits on Return and when it loses focus, so
/// clicking into another field never drops an edit, and only when the text
/// changed since the last commit (tabbing through fields writes nothing).
/// `prompt` is the greyed example shown while empty.
struct CommitTextField: View {
    let title: String
    @Binding var text: String
    var prompt = ""
    let commit: () -> Void
    @FocusState private var focused: Bool
    @State private var committed: String?

    var body: some View {
        TextField(title, text: $text, prompt: Text(prompt))
            .focused($focused)
            .onSubmit(commitIfChanged)
            .onChange(of: focused) { _, isFocused in
                if isFocused { committed = text } else { commitIfChanged() }
            }
    }

    /// `committed` is the text as of focus-in or the last commit.
    private func commitIfChanged() {
        guard let committed, text != committed else { return }
        self.committed = text
        commit()
    }
}

/// A `ConfigEditError`/`LoginItemError` message rendered inline under the
/// control that produced it.
struct InlineErrorText: View {
    let message: String

    var body: some View {
        Text(message)
            .font(.caption)
            .foregroundStyle(.red)
    }
}

/// A slider that only commits (via `commit`) when the drag ends, never on
/// every intermediate tick. Shows `dragValue` while the user is actively
/// dragging so the label tracks the thumb, and reverts to `liveValue` (the
/// authoritative, possibly server-corrected value) once the drag ends.
struct CommitSlider: View {
    let title: String
    let liveValue: Double
    let range: ClosedRange<Double>
    var step: Double = 0.01
    let format: (Double) -> String
    let commit: (Double) -> Void

    @State private var dragValue: Double?

    var body: some View {
        HStack {
            Text(title)
            Slider(
                value: Binding(get: { dragValue ?? liveValue }, set: { dragValue = $0 }),
                in: range, step: step,
                onEditingChanged: { editing in
                    guard !editing, let dragValue else { return }
                    commit(dragValue)
                    self.dragValue = nil
                }
            )
            Text(format(dragValue ?? liveValue))
                .monospacedDigit()
                .lineLimit(1)
                .fixedSize()
                .frame(minWidth: 56, alignment: .trailing)
        }
    }
}

/// A stepper that commits on every discrete step (each click is already a
/// deliberate, discrete change, unlike a slider drag).
struct CommitStepper: View {
    let title: String
    let liveValue: Int
    let range: ClosedRange<Int>
    let commit: (Int) -> Void

    var body: some View {
        Stepper(
            value: Binding(get: { liveValue }, set: { commit($0) }),
            in: range
        ) {
            HStack {
                Text(title)
                Spacer()
                Text("\(liveValue)").monospacedDigit()
            }
        }
    }
}

extension Easing {
    var label: String {
        switch self {
        case .linear: "Linear"
        case .easeOutCubic: "Ease Out (Cubic)"
        case .easeInOutCubic: "Ease In/Out (Cubic)"
        case .easeOutQuint: "Ease Out (Quint)"
        }
    }
}
