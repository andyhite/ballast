# Ballast — technical design

Ballast is a tiling window manager for macOS that lays out windows per
**(display, native macOS Space)**. It is a *reactor*: macOS owns Spaces
(creating them, switching between them, deciding which Space a window is on).
Ballast watches those native changes and lays out whatever is on each
(display, Space) using that pair's layout mode. It never writes Space state
and runs with SIP fully enabled.

## 1. Language and runtime: Swift + AppKit + AXUIElement

| | Swift + AppKit | Rust + objc2 (Rift's approach) |
|---|---|---|
| AX / AppKit / Carbon / CoreGraphics | Native; the SDK headers are the API | Needs hand-written or generated bindings; every `AXValue`, `CFArray`, and `NSScreen` crossing takes FFI glue |
| Private SkyLight reads | `dlsym` + `@convention(c)` casts | `dlsym` + `extern "C"` — equal |
| Main run loop, `AXObserver` sources, `NSStatusItem` | First-class | Works, but through `objc2` wrappers and manual run-loop plumbing |
| Recovering from a bug in the layout code | **Not possible in-process.** A Swift trap (force-unwrap of `nil`, out-of-bounds index, integer overflow) ends the process | `catch_unwind` can turn a panic in the layout code into a logged error |
| Build and distribution | SwiftPM, one binary, an optional `.app` wrapper | Cargo plus bundling; similar effort |

**Decision: Swift.** Every hot path in this WM is an AX, AppKit, or
CoreGraphics call. Swift calls them with no binding layer, so no code sits
between the WM and the APIs whose timing we care about (AX round-trips, the
display refresh rate, `NSWorkspace` notifications). The performance and
animation requirements are limited by AX IPC latency, not by the language,
so Rust's speed buys nothing measurable here.

Rust's real advantage is panic isolation. Swift has no equivalent, so Ballast
uses these mitigations instead (§2.2, §2.3):

1. The layout core is total by construction: it never traps on bad input.
2. Tree mutations are value-semantic: no half-built tree can ever be seen
   (the Rift crash class).
3. Property-based fuzz tests check this.
4. `launchd` `KeepAlive` restarts the process as a last resort.

## 2. Process architecture

One process with three layers. Only plain values cross between layers.

```mermaid
flowchart LR
  subgraph Observation [main thread]
    AXO[AXObserver per app<br/>+ Dock Exposé events]
    WS[NSWorkspace / screen-param<br/>notifications]
    SL[SpaceProvider<br/>SkyLight, read-only]
  end
  subgraph Core [BallastCore — pure values, no I/O]
    E[Engine<br/>windows, SpaceStates,<br/>rules, weights, BSP, MS]
  end
  subgraph Mutation [per-app serial queues]
    FA[FrameApplier<br/>1 queue per pid]
  end
  AXO --> WM[WindowManager<br/>coalescing, ≤1 pass/frame]
  WS --> WM
  SL --> WM
  WM -- events --> E
  E -- dirty SpaceIDs,<br/>frame plans --> WM
  WM -- frame requests --> FA
  FA -- actual frames --> WM
```

- **Observation** (`Sources/BallastApp/AX/AppObserver.swift`, the
  `WindowManager` notification handlers, `PrivateAPI/SkyLight.swift`).
  Everything is push-based: `AXObserver` notifications (window
  created/destroyed/moved/resized/(de)miniaturized/title-changed, focused and
  main window changed), `NSWorkspace` notifications (app
  launched/terminated/activated, active Space changed, wake, Reduce Motion
  changed), screen-parameter changes, and Dock's Mission Control (Exposé)
  enter/exit AX notifications. There are **no polling loops**. Two bounded,
  one-shot retries exist: attaching to an app that is not yet AX-ready at
  launch (≤8 tries with backoff), and re-reading the Accessibility trust
  flag 0.5 s after the system says it changed.
- **Core** (`Sources/BallastCore`, Foundation only). The `Engine` is a
  value-type state machine. It takes normalized events (`addWindow`,
  `removeWindow`, `setSpace`, `focus`, `applyConfig`, `updateSnapshot`,
  `perform(command)`, …) and returns dirty Space ids and frame plans. It has
  no clocks, no I/O, and no AX types, so the whole placement policy is
  unit-testable and fuzzable.
- **Mutation** (`AX/FrameApplier.swift`). One serial `DispatchQueue` per
  application. It receives `(element, target frame, optional animation)`,
  performs the AX writes, reads back the resulting frame, and posts it to the
  main thread. It never reads or writes engine state.

### 2.1 Isolation between computation and mutation

- The mutation path consumes only `[WindowID: CGRect]` plans. Bad layout
  output (NaN, negative sizes) cannot happen, because all geometry is clamped
  and rounded in the core. Even if it did, it would produce a refused AX write,
  not corrupted state.
- AX failures (a dead app, a timeout, a refused size) come back as values
  (`actual == nil`, or an `actual` that differs from the request). The core
  turns them into events (learn a minimum size, keep the frame it observed).
  They never throw into the core.
- Every AX element gets a 1 s messaging timeout. A hung app blocks only its
  own queue, and each read on the main thread is bounded by that timeout.

### 2.2 The Rift crash class, and why it can't happen here

Rift's `promote_to_master` crash came from an event handler that observed a
tree node in the middle of a mutation, detached but not yet re-attached, and
then called `.unwrap()` on it. Ballast removes that class of bug by
construction:

- `BSPNode` is an immutable `indirect enum`. Insert, remove, swap, resize and
  every other mutation build a **new tree** and return it whole, or return a
  `BSPError`. No code can observe an intermediate state, and no mutation
  events are emitted mid-change.
- Engine entry points are total. Unknown ids, duplicate adds, removals of
  missing windows, swaps with self, commands with no focused window, zero or
  empty areas, and snapshots that delete the Space you are on all end in a
  no-op or a message, never a trap. Tree and member drift is repaired, not
  asserted (`recomputeIdeal` rebuilds the tree if its leaves diverge from the
  members).
- The core contains no `!`, `try!`, `fatalError`, or `precondition`.
  `scripts/lint-core.sh` greps for these constructs; unchecked indexing on
  untrusted positions is covered by code review and the fuzz tests below,
  not by the lint script.
- `Tests/BallastCoreTests/FuzzTests.swift` replays thousands of seeded random
  interleavings of add, remove, re-parent (setSpace), snapshot changes that
  delete Spaces or unplug displays, config reloads, and every command. After
  **every** step it checks the structural invariants: tree leaves equal the
  Space's members equal its ideal order equal its manual order, and every
  tiled window belongs to exactly one Space.

### 2.3 What Swift cannot give us

A bug that does trap (for example, one in AppKit glue) still ends the process.
The platform layer keeps force casts to one idiom (`as! AXUIElement` right
after a `CFGetTypeID` check). The documented deployment is a LaunchAgent with
`KeepAlive` (`scripts/dev.ballast.plist`), so a crash costs about one second
of unmanaged windows. It never takes the desktop session down, because Ballast
has no injected code in Dock or WindowServer to take down with it.

## 3. Model

### 3.1 Identity

| Purpose | Key | Why |
|---|---|---|
| Config addressing | `SpaceKey(display UUID, ordinal)` | Stable across reboots, **if** "Displays have separate Spaces" is ON and "Automatically rearrange Spaces" is OFF. Otherwise Ballast refuses to manage windows (`! SET` in the menu bar) and `ballast doctor` flags the setting. The ordinal counts only *user* desktops, so full-screening an app never shifts it. |
| Live state | `SpaceID` (SkyLight managed id) | Stable for the session and follows the *physical* Space. If you delete Desktop 2, Desktop 3 becomes ordinal 2 but keeps its live state (manual arrangement, mode override), and config lookups use its new ordinal. The dead Space's state is dropped (`Engine.updateSnapshot`). |
| Displays | `CGDisplayCreateUUIDFromDisplayID` | Persistent across reconnects. It matches SkyLight's "Display Identifier". Ordinals of displays are never used. |
| Windows | `CGWindowID` (via `_AXUIElementGetWindow`) | Stable for the window's lifetime. |

### 3.2 Per-Space state: live arrangement vs. weight-computed ideal

Each `SpaceState` holds:

- `idealOrder`: `WeightResolver.rank(members)`, recomputed on every
  *structural* change (a window joins or leaves, a weight changes, a config
  reload). Pure focus changes do not recompute it; otherwise two equal-weight
  windows would swap every time you clicked one.
- `manual` + `manualOrder`: the live master-stack order after a user
  swap/promote/drag/adopt, or a BSP resize/balance. While `manual` is set,
  the ideal keeps updating in the background but is **not applied**.
  Newcomers join the stack at their weight rank and never displace a
  manually placed master.
- `tree`: the live BSP tree. It always exists, so switching modes never
  loses structure. New windows split the focused leaf. Split ratios come
  from weights unless a split carries a manual ratio (from resize or balance).
  With `bsp_shape = "balanced"`, a Space that is not manual instead rebuilds
  its tree as the balanced ideal on every structural change: the rank order
  is cut where the running weight sum is closest to half the total, each
  side recursively, giving an equal-area grid (four equal-weight windows are
  quarters) whichever window had focus.
- `modeOverride`, `monocle`, `masterRatioOverride`, `masterCountOverride`,
  and `frameOverrides` (adopted frames). The three overrides are transient:
  a setting command applies one instantly, then the platform layer writes it
  to that desktop's `[[space]]` block in the config file (debounced ~300ms
  so a held grow/shrink key writes once, not per step) and clears the
  override, so the config is the source of truth again. If the write fails
  (invalid resulting config, unwritable file) the override is left in place
  as the effective, unsaved value and the user is notified.
- `focus`: this Space's focus history (MRU).

`reset` discards order, tree shape, and adopted frames — the *arrangement*
only. It rebuilds the BSP tree as the ideal tree in rank order: dwindle
by default (the heaviest window gets the largest, top-left tile), or the
balanced grid for `bsp_shape = "balanced"`. It **keeps** the layout mode,
monocle, master ratio and master count, because those are now config
settings, not arrangement (`layout default` still drops the mode override
by writing `mode` out of the config).

`applyConfig` re-resolves rules and recomputes ideals. It never touches the
overrides listed above. This is the direct fix for Rift's
reload-resets-layout bug, and it is covered by tests. A changed `split` is
applied to the existing BSP tree of every Space that is *not* manual (shape
and ratios kept, split directions rewritten), so config edits show up without
a `reset`; manually arranged Spaces keep their split directions until `reset`.

### 3.2.1 Config write-back

Nothing is runtime-only: every setting the user changes from the menu bar, a
setting command (`layout …`, `master-ratio`, `master-count`, master-stack
`grow`/`shrink`/`balance`), or the Preferences window is written to
`~/.config/ballast/config.toml` so it survives restarts. Sources:

- **Menu bar / Preferences**: call `WindowManager.editConfig` or
  `setSpaceSetting` directly, synchronously, on the edit.
- **Setting commands** (hotkeys, `ballast send …`, the menu's own layout
  items — all funnel through `Engine.perform`): `CommandOutcome.settings`
  carries what changed; `WindowManager` merges it per-Space and flushes
  after a ~300ms debounce.

`WindowManager.editConfig` resolves `configURL`'s symlinks first (so a
dotfiles-managed symlink is edited in place, never replaced by a plain
file), reads the current text (the built-in starter template if the file
doesn't exist yet), applies the requested change with `ConfigEditor` — a
text-preserving TOML editor that keeps comments and formatting — validates
the result with `Config.parse`, and only then writes it atomically and
reloads. On any failure (parse/validation error, unwritable file) nothing is
written, a notification explains why, and the in-memory runtime override
stays the effective value until the next successful edit. The write informs
`ConfigWatcher` of its own content so the file-watcher's hot reload doesn't
fire a second, redundant reload.

**Surfaces.** The menu bar covers the current desktop's layout settings
(each submenu has a `Default (…)` entry that removes the desktop's override),
the `[layout]` defaults, global settings, and the focused app's `app_id`
rule. The Settings window (`Preferences/`, SwiftUI in an `NSWindow`) covers
everything: General, Layout (defaults and every connected desktop, where a
checked setting is a per-desktop override), Rules (ordered list plus a full
editor), and Keyboard (a hotkey recorder that captures key codes, so
recording doesn't depend on the keyboard layout). Text fields commit on
Return or when focus leaves, and only when the text changed. Sliders commit
when the drag ends. While the binding editor is open,
`WindowManager.setHotkeysSuspended` unregisters Ballast's global hotkeys,
so a combination that is already bound is recorded instead of running its
command.

### 3.3 Weights

`WeightResolver.rank` sorts by:

1. weight, descending;
2. focus recency on that Space (focused windows before never-focused ones);
3. creation order, ascending;
4. window id (a total order, so the result is deterministic).

It is a pure function of `(windows, weights, focus history, creation order)`.

- **Master-stack**: masters are `liveOrder.prefix(masterCount)`. When the
  Space isn't manual, a weight-10 window launching next to a weight-1 master
  takes the master slot on the same layout pass.
- **BSP**: each split's ratio is `sum(first subtree weights) / sum(both)`,
  clamped to `[bsp_min_ratio, bsp_max_ratio]`. A manual ratio wins. Learned
  AX minimum sizes are honored on top of this (see §4).
  Grow/shrink uses the configured BSP ratio bounds; master-stack uses the
  same ratio bounds as configuration validation, so neither command reverses
  direction at a valid starting ratio.

## 4. Performance

- **Coalescing.** Every event marks Spaces dirty and schedules one pass,
  `1 / NSScreen.maximumFramesPerSecond` later. All events in that frame share
  the pass. Passes run on the main thread, so two passes never overlap.
- **Parallel, per-app mutation.** `FrameApplier` keeps one serial queue per
  pid. Electron and Java apps only delay their own windows.
- **Ordering.** If a window is shrinking, the size is set before the
  position. If it is growing, the position is set first. After the final
  write, the frame is read back once, and the origin is corrected if the
  WindowServer nudged it.
- **`AXEnhancedUserInterface = false`** is written to every app element on
  first contact.
- **No repeated requests.** A request equal to the last request for that
  window is not re-sent. If a window refuses a size, the actual frame is
  recorded. If it refused to *shrink*, the engine learns a minimum size and
  reflows the siblings around it (`learnMinSize`, honored by both layouts). It
  is never retried every pass.
- **Idle cost is zero**: there are no timers, no polling, and no animation
  when nothing is changing.

## 5. Animation decision: strategy (a)

**Chosen: (a).** Only the **focused** window on an **active** Space
interpolates its AX frame on its app's worker. Frames are paced by deadline at
the display refresh interval, so a slow AX round-trip drops frames instead of
stretching the animation. Every other window gets its final frame in one shot.
Each animation frame is scheduled separately on the serial queue rather than
sleeping on it. Sibling-window requests and focus operations can run between
frames.

Why not (b), yabai-style proxy windows animated with `SLSSetWindowTransform`?

- It adds private *write* APIs: window capture, transforms, and
  proxy-window ordering.
- Those APIs misbehave across macOS releases, and can leave orphaned proxy
  windows on screen if a pass is interrupted.
- It violates the "read-only SkyLight" boundary that makes §6 defensible.

(a) is SIP-safe, public API only, and keeps the eye on the window you are
working in.

Animation is skipped in each of these cases:

- **Reduce Motion is on.** `NSWorkspace.accessibilityDisplayShouldReduceMotion`
  is re-read whenever the system reports a display-options change.
- `animation.enabled = false`, or `duration_ms = 0`.
- The window is on an inactive Space or display.
- The Space is in monocle mode.

A newer request for the same window cancels an in-flight animation at its
next frame (per-window generation counter).

## 6. Private SkyLight API: scope and isolation

> **Warning.** These are undocumented private functions. Apple can change or
> remove any of them in any macOS release, including point updates, without
> notice. Ballast is tested on macOS 14–26.

- **One file**: `Sources/BallastApp/PrivateAPI/SkyLight.swift`. No other file
  references a private symbol.
- **One protocol**: `SpaceProvider` (`snapshot()`, `windowIDs(onSpace:)`,
  `spaces(forWindow:)`, `windowID(for:)`). The engine only ever sees the plain
  `SpaceSnapshot` value.
- **Read-only symbols**: `SLSMainConnectionID`,
  `SLSCopyManagedDisplaySpaces`, `SLSCopySpacesForWindows`,
  `SLSCopyWindowsWithOptionsAndTags`, and HIServices' `_AXUIElementGetWindow`.
  Nothing moves windows between Spaces, and nothing is injected into Dock.
- **Resolved once at startup** (`SkyLightSpaceProvider.make()` via
  `dlopen`/`dlsym`). If any symbol is missing, the app enters an
  `unsupported` state: a red `! OS` in the menu bar, a notification, and no
  management. `ballast doctor` lists each symbol's resolution status and
  checks that the returned data is sane: UUID display identifiers, and at
  least one user Space per display.

## 7. Spaces, displays and edge cases

| Situation | Handling |
|---|---|
| Space switch (swipe, `ctrl+N`, Mission Control) | `activeSpaceDidChange` triggers a full resync: new snapshot, discovery of windows that just became visible, and membership reconciliation. Newly active Spaces are laid out. |
| Window dragged to another Space in Mission Control | Dock posts `AXExposeExit` when Mission Control closes. Ballast then runs a full resync: a fresh snapshot (which also picks up desktops added, removed or reordered in Mission Control) and membership reconciliation (`SLSCopyWindowsWithOptionsAndTags` per Space). Both Spaces are reflowed, and the arrival is laid out using its new Space's mode. The Dock observer is re-attached whenever Dock relaunches. |
| Dock "Assign To Desktop" | When an app launches, its `com.apple.spaces` `app-bindings` entry is resolved to a `SpaceID`. The app's first windows are assigned there immediately, so their layout is computed for the Space macOS will put them on, not reflowed afterwards. |
| Space deleted | The snapshot no longer contains it, so its state is dropped. macOS moves the orphaned windows to an adjacent Space, and reconciliation reflows that Space. |
| Display unplugged or replugged, sleep/wake | `didChangeScreenParameters` / `didWake` trigger a full resync. Config overrides for the returning display re-apply by UUID. |
| Native fullscreen | Windows with `AXFullScreen` are skipped. Windows on a fullscreen-type Space are never tiled. |
| Stage Manager on | `engine.passthrough`: every Space renders as floating, and the menu says so. |
| Window moved to another display (command or drag) | A plain AX move into the target display's visible frame. macOS reassigns the Space, Ballast reconciles, and the cursor follows. |
| Moving between Spaces on one display | Not a WM function (a non-goal). |

**Discovery caveat.** For many apps, `kAXWindowsAttribute` returns only
windows on the *current* Space. Windows on Spaces you haven't visited since
launch are discovered on the first visit. This is also why an
app-moved-its-own-window check happens only for windows Ballast already
tracks.

## 8. Window-state policy

- **Focus history per Space.** When the focused window closes, focus goes to
  the most recent *older* entry in that Space's history. This still holds if
  AppKit has already focused something else: a focus loss within 0.5 s
  before the close counts.
- **Hidden applications.** Hidden windows release their tiles and are
  excluded from focus targets without being marked minimized. Unhiding an
  application restores its eligible windows to their Spaces.
- **Monocle and floating windows.** Focusing a floating window does not
  raise a tiled monocle window over it.
- **Cursor warp.** Only for WM-initiated focus that crosses a display
  (`cursor_follows_focus`). A user's own click never warps the cursor.
- **Focus follows mouse (optional).** A mouse-moved global monitor, throttled
  to about 16 Hz, hit-tests the AX window under the cursor on a background
  queue, with at most one test in flight. A beachballing app under the
  cursor therefore never stalls the main thread.
- **External frame changes.** A moved or resized notification that Ballast
  didn't cause is classified at the next pass:
  - If the mouse is down, it is a user drag and waits for mouse-up. If the
    window was dropped over another tile it becomes a **swap**. If it was
    dropped on another display, the window moves there. Otherwise it snaps
    back.
  - Otherwise the rule's `on_self_move` applies. `snap_back` re-applies the
    frame. `adopt` records the window's own frame as a manual override for
    that Space.
  - A snap-back loop guard (more than 3 within 2 s) switches to adopting, so
    a grid-snapping terminal can't cause an endless fight.
- **Sticky.** Pinning another app's window to every Space requires writing
  its collection behavior. That write is SIP-gated, so it is out of scope.
  `sticky = true` is therefore **best effort**: the window floats and never
  takes a tile on any Space. Windows that are already all-Spaces (SkyLight
  reports more than one Space) are left untiled.

## 9. Config

See `docs/config.example.toml`. It is TOML, with a zero-dependency TOML 1.0
parser in `BallastCore/TOML.swift`.

**Validation.** Unknown keys, bad values, bad UUIDs, duplicate `[[space]]`
entries, bad regexes, invalid hotkeys, invalid commands, and duplicate
hotkeys are all errors, each reported with its path (`rule[3].weight: …`).

**Hot reload.** `ConfigWatcher` watches the file and directory chains for
both the configured path and its resolved symlink target. It handles atomic
saves, missing or replaced directories, symlink retargeting, and truncation.
It compares file contents and debounces notifications. An invalid file is
rejected: the old config stays live, and the menu bar shows `! …` in red with
the errors in the menu, plus a notification.
An invalid file at startup means Ballast doesn't manage windows until the
file is fixed. It never silently falls back to defaults.

## 10. Commands and IPC

Hotkeys (Carbon `RegisterEventHotKey`, which needs no event tap) and the menu
both call `WindowManager.perform(Command)`. `ballast send <command>` posts a
distributed notification to the running instance. It is fire-and-forget, the
same trust level as any local user process, and not a scripting API.
`dump-state` writes `~/Library/Caches/dev.ballast/state.json`; the smoke test
uses it.

## 11. Testing

`swift test` runs these suites:

- TOML parser
- hotkeys
- config validation
- weight resolution and tiebreaks
- BSP subtree-weight ratios and clamping
- master-stack geometry
- engine behavior:
  - continuous weight-driven master
  - manual override persistence and reset
  - reload keeps live state
  - focus fallback on close
  - Space deletion and ordinal shift
- invariant fuzzing (engine and BSP)

The platform glue is covered by the manual smoke test in `docs/SMOKE_TEST.md`.

## 12. Build and install

```sh
scripts/build-app.sh      # release build → build/Ballast.app: icon, bundled LaunchAgent, signed
scripts/install.sh        # /Applications, Start at Login on, `ballast` CLI symlink
scripts/install.sh --uninstall
```

- **Bundle.** `Contents/MacOS/ballast` (the same binary serves the app and
  the CLI), `Contents/Resources/AppIcon.icns` generated from
  `assets/AppIcon.png` (1024 px, Apple icon grid), and
  `Contents/Library/LaunchAgents/dev.ballast.plist` from
  `scripts/dev.ballast.plist`. `LSUIElement` keeps it out of the Dock and the
  app switcher; the icon shows in Finder, Login Items, Accessibility settings,
  alerts and notifications.
- **Signing.** Accessibility permission is keyed to the app's designated
  requirement. `build-app.sh` signs with the `Ballast Dev` self-signed
  code-signing certificate by default (`SIGN_ID` overrides), so the
  requirement is "bundle id `dev.ballast.Ballast` + that certificate" and the
  grant survives rebuilds. The certificate does not need to be trusted.
  `SIGN_ID=-` signs ad-hoc: the requirement becomes a per-build hash and every
  rebuild loses the grant.
- **Start at Login and crash restart.** The bundled LaunchAgent is registered
  with `SMAppService` (`LoginItem.swift`), from the menu's "Start at Login"
  toggle or `ballast login-item on|off|status`. launchd starts Ballast at
  login and restarts it after a crash (`KeepAlive` on non-zero exit), but not
  after Quit. Unregistering stops the agent, so turning the toggle off quits
  Ballast; the menu asks first. Nothing is copied into `~/Library`.
- **Updates.** launchd can't relaunch an agent whose bundle was replaced
  underneath it (exit 78, `EX_CONFIG`), so `install.sh` unregisters the agent,
  waits until launchd has dropped the job, replaces the bundle and registers
  it again. Registering too soon after the swap has also produced the same
  `EX_CONFIG` respawn loop, so the script then waits up to 5 s for the agent
  to be running and, if it isn't, unregisters, waits 2 s and registers once
  more before giving up with an error. A user who turned Start at Login off
  keeps it off.
- **One instance.** `ballast run` holds a lock on
  `~/Library/Caches/dev.ballast/run.lock`. `install.sh` uses that lock to
  find a running Ballast and refuses to continue when it isn't the login
  agent (a dev `ballast run`, or a copy opened from Finder).
- **Distribution** (not set up). The Mac App Store is ruled out: its sandbox
  forbids controlling other apps' windows and private SkyLight calls. Shipping
  to other Macs needs a Developer ID certificate, hardened runtime
  (`codesign --options runtime --timestamp`), `xcrun notarytool submit` and
  `xcrun stapler staple`. No entitlements are needed.
