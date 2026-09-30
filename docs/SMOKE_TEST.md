# Smoke test

This test checks the live behaviors that unit tests can't reach. It needs
about 5 minutes. Everything runs on your real desktop, so windows **will**
move.

## Setup (once)

1. Build and check the environment:
   ```sh
   swift build
   .build/debug/ballast doctor        # every line must be ✓
   .build/debug/ballast spaces        # note each display UUID and its desktop ordinals
   ```
2. Set up at least two desktops on each of two displays in Mission Control.
3. Write `~/.config/ballast/config.toml`. Start from
   `docs/config.example.toml` and replace the `[[space]]` UUIDs with yours.
   It must contain all of the following:
   - A `[[space]]` override that makes the **active** desktop of display A
     `arrange = "dwindle"`, while the active desktop of display B stays
     `arrange = "fixed"` with a feature. That gives two Spaces on two
     displays with different arrangements.
   - A second desktop on one display with an arrangement different from its
     neighbor's. This is the drag target in step 3.
   - A heavy rule and a light app. The example gives Ghostty `weight = 10`;
     add or reuse a weight > 1 rule for a non-terminal app if you use the
     default `SMOKE_HEAVY_APP` (`com.apple.Safari`). Override the apps with
     `SMOKE_HEAVY_APP` / `SMOKE_LIGHT_APP` (bundle ids). The heavy app must
     not be the terminal you run the script from — the script refuses to
     start if it is. The light app defaults to TextEdit.
   ```sh
   .build/debug/ballast check-config
   ```
4. Start the WM in its own terminal tab. Accessibility is granted to the
   terminal app when you run it from there; the `.app` from
   `scripts/build-app.sh` gets its own grant.
   ```sh
   .build/debug/ballast run
   ```
   The menu bar shows `<ordinal> · F·1×2` (or whichever glyph your config gives) or `<ordinal> · D`.

## Run

```sh
scripts/smoke-test.sh
```

The script checks everything it can by reading
`~/Library/Caches/dev.ballast/state.json` (produced by
`ballast send dump-state`). It pauses at each step that needs a human; after
you press enter it counts down a few seconds so you can click back onto the
target window before the next command fires — you never need to re-focus
between the commands that follow one pause. Before touching anything, the
script backs up your entire config to a private temp file (created fresh
each run, so it never overwrites a backup of your own); if the backup can't
be made it aborts without touching the config at all. From then on the
original bytes are restored — via traps on normal exit, Ctrl-C, and `kill`
— covering every setting-mutating command in every step, not just step 1's
own reload check. Before overwriting the file, the restore polls
`dump-state` (up to 20 checks, with 50 ms between checks) until every Space's transient setting
override has cleared, instead of guessing a fixed delay for in-flight
settings persistence to land. A symlinked config stays a
symlink, and if the restore itself ever fails it exits 1 and the script
leaves the backup in place and prints where it is instead of deleting it.

| # | What the script does | What you do / expect |
|---|---|---|
| 1 | Checks that the active Spaces on the two displays have different layouts (the menu-bar glyph). Sends `feature-size 0.05` plus a `promote` on the first display; the size change is persisted to that desktop's `[[space]]` block and its transient override cleared. Only if that Space is actually manual with the override cleared does it touch the config to trigger a hot reload, then restore it exactly; otherwise it fails that check and skips the reload without further mutating the config. Runs `reset` afterwards either way — the config file itself is put back to its exact original bytes by the exit/signal restore, not by this. | Focus a window (2+ tiled windows on a Space with a feature) on the named FIRST display when the countdown starts. **Expect:** the Space becomes manual and the override clears before the config is touched, then the layouts, settings and the manual arrangement survive the reload. |
| 2 | Resets the Space, launches the light app, then launches the heavy app. | Focus a Space with a feature and quit the heavy app first. **Expect:** the heavy app slides into the feature slot on its own, and the light app moves to the grid. The Space is still not manual. |
| 3 | Diffs Space membership before and after your Mission Control drag. | In Mission Control, drag a tiled window onto another desktop thumbnail whose arrangement differs, then exit. **Expect:** the window is reported on its new Space, laid out with that Space's arrangement (for example it joins the BSP tree), and the source Space closes the gap. |
| 4 | Toggles monocle on and off. Checks that every tiled window has the one deck-slot size while monocle is on, that the desktop keeps its layout, and that the arrangement is restored exactly afterwards. Swaps with Reduce Motion on, then off. | **Expect:** a `⤢` after the layout glyph in the menu bar, and "Exit Monocle" in the menu, while monocle is on. With Reduce Motion **on**, swaps snap instantly. With it **off**, the focused window glides (~180 ms) and the others snap. |

The script ends with `N passed, 0 failed`.

## Extra manual checks (optional, about 1 minute each)

- **Invalid config:** save a typo (for example `arrange = "spiral"`). The menu
  bar turns red (`! 2 · F·1×2`), a notification names the path and error, and
  layouts keep working with the previous config. Fix the typo and the red
  clears.
- **Reset:** promote a window to the feature (`ballast send promote`), open a
  heavier app (it must *not* take the feature slot, because the Space is
  manual), then run `ballast send reset`. The heavy app becomes featured.
- **Decks:** with three tiled windows, focus one and run
  `ballast send deck left` (or another direction that has a neighbor).
  **Expect:** it and the neighbor share one tile; the focused one fills it
  and the other peeks at its edge. `ballast send focus up` (or `down`) moves
  focus to the other window and the view follows. Close the focused window:
  the deck dissolves and the neighbor fills the tile alone.
  `ballast send deck left` again, then `ballast send undeck`: the window
  comes back as its own tile right after the deck. Deck once more, then
  `ballast send reset`: every window is a tile again.
- **Weighted column:** on a `fixed` Space with a feature that isn't manual (run
  `ballast send reset`), with a heavier featured window such as Ghostty at
  weight 10 and three weight-1 tiles, focus a tile and pick
  the app's submenu (its name, with its icon) → **Weight** → **2** in the menu. It moves to the top
  of the grid and becomes twice as tall as each of the other two. Pick
  **5** instead and it stops at three times their height, the default
  Weight Share Limit (Max 75%). Set it back to **1 (default)** and the
  column evens out.
- **Fixed, 1×1:** set a Space to `arrange = "fixed"`, `columns = 1`, `rows = 1`,
  `feature = "none"` and open 3+ windows, then focus the middle one.
  **Expect:** only that window fills the area; the previous window shows a
  `deck_peek`-wide strip of its title bar above it, and the next one shows a
  strip of its bottom edge below. `focus down` scrolls the deck to bring the
  next window into view; `focus up` scrolls back. At the first window nothing
  peeks above it and it reaches the top; at the last, it reaches the bottom.
- **Overflow deck:** on a `fixed` Space with `columns = 1`, `rows = 2`, a
  feature, and 3+ other windows, focus the bottom tile, then click the title
  strip peeking above the top tile. **Expect:** the clicked window scrolls
  into view, both tiles in view show in full, and the window that lost focus
  shows only its peek strip below them. Focus the feature afterwards: nothing
  changes.
- **New window in view:** on the same Space with 3+ other windows, focus the
  bottom tile and press ⌘N in its app. **Expect:** the new window appears at
  the top of the grid, in view and focused, with the next window's edge
  peeking below. Focus the feature afterwards: the deck doesn't scroll.
- **Fixed columns:** on a `fixed` Space with `columns = 3`, `rows = 2` and a
  feature, open 8 windows besides the featured one. **Expect:** the grid
  splits into 3 side-by-side columns, filled nearest the feature first (the
  two columns closest to it hold 2 windows each, the last holds the rest and
  scrolls with `deck_peek`); with only 3 grid windows total, each column
  holds one and none scroll.
- **Top feature:** on a `fixed` Space with `feature = "top"`, `columns = 1`,
  `rows = 2` and 3 windows. **Expect:** the feature fills a strip across the
  top and the other two windows are stacked one above the other below it,
  each full width. With `columns = 2`, `rows = 1` they sit side by side
  instead (columns are always vertical lines, whatever side the feature is on).
- **Adaptive:** on an `arrange = "adaptive"` Space with `feature = "none"`,
  open 5 windows. **Expect:** on a landscape display, 3 columns in the first
  row and 2 in the second (the second row's windows each half the width); on
  a portrait display, 3 rows. With `feature = "left"`, the first window takes
  the feature area and the other 4 tile in the rest. `grow`, `shrink` and
  `balance` resize the feature; with `feature = "none"` they change nothing
  and the notification says so.
- **BSP + feature:** on a `dwindle` Space with `feature = "left"`, open 4
  windows. **Expect:** the first takes the feature area and the other three
  dwindle in the rest. `grow` resizes the BSP splits and
  `feature-size +0.1` resizes the feature. Switch to `balanced`: the other
  three become an equal-area grid beside the feature.
- **Center feature:** on a `fixed` Space with `feature = "center"` and 4+
  other windows. **Expect:** the feature fills the middle, the grid is split
  into a right and a left half, the right half holding the first half of the
  tiles (rounded up); with one other window, only the right half is used.
  `focus-feature` moves focus to the feature and back.
- **Screen-size defaults:** with no `arrange`, `columns`, `rows` or `feature`
  in `[layout]` or the desktop's `[[space]]`, a laptop's built-in display (under
  1800 pt wide) shows one full-screen deck (`1×1` in the menu bar), and an
  external display 1800 pt or wider shows `F·1×2` with a feature on the left.
  Setting `rows = 3` in `[layout]` applies to both.
- **Monocle:** on a `fixed` Space with a feature and 3+ other windows, run
  `ballast send monocle`. **Expect:** every window is one full-area deck (the
  focused one in front, neighbors peeking), the menu bar shows a `⤢` after the
  layout glyph, and the menu item reads "Exit Monocle". Run `monocle` again:
  the arrangement comes back exactly.
- **Float cascade:** set a desktop to `arrange = "float"` and open three new windows
  of one app. **Expect:** each lands 28 pt down and right of the previous one; close
  the middle one and open another: it takes the freed slot. With
  `float_placement = "none"`, or under Stage Manager, windows stay where the app opens them.
- **Dialogs float:** open an app's Settings window and an "About" window.
  **Expect:** both float over the tiled windows, and **Window Inspector…**
  shows the reason, e.g. `Floating — default: no full-screen button`.
- **File panels float:** in TextEdit, choose File → Open…. **Expect:** the
  Open panel floats where TextEdit put it, the tiled windows don't reflow,
  and **Window Inspector…** shows `Floating — default: open/save panel`.
- **Close fallback:** focus A, then B, then C on one Space and close C.
  Focus returns to B, not to whatever AppKit picks.
- **Focus flash:** press `alt+l`. An accent-colored border flashes around
  the newly focused window and fades out after about 0.8 s. Hold `alt` alone
  and the border stays on the focused window, then disappears as soon as you
  let go. Hold `alt`, press `l`, then let go: the border moves to the new
  window and fades out on its own, even if you keep holding `alt` for a few
  seconds first. Clicking another window shows no border.
- **Display move:** `ballast send send-to-display next` moves the focused
  window to the other display, the cursor follows it, and the window is tiled
  there.
- **Focus across displays:** with tiled windows on two side-by-side displays,
  focus the rightmost window on the left display and run `ballast send focus
  right`. The leftmost aligned window on the right display gains focus. Run
  `ballast send focus left` to return. With `cursor_follows_focus = true`, the
  cursor follows both jumps.
- **Drag preview:** drag a tile by its title bar over another tile. A
  translucent accent-colored zone exactly covers the window you'd swap
  with, under the dragged window (which stays untinted), and follows the
  cursor from tile to tile; over a gap or the window's own tile it
  disappears, and over the other display it shows the tile the window would
  get there. Release: the two windows trade places. Dragging a tile's edge
  (a resize) shows no zone.
