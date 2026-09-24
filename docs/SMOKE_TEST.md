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
     `bsp`, while the active desktop of display B stays `master_grid`. That
     gives two Spaces on two displays with different modes.
   - A second desktop on one display with a mode different from its
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
   The menu bar shows `<ordinal> · MS` or `<ordinal> · BSP`.

## Run

```sh
scripts/smoke-test.sh
```

The script checks everything it can by reading
`~/Library/Caches/dev.ballast/state.json` (produced by
`ballast send dump-state`). It pauses at each step that needs a human; after
you press enter it counts down a few seconds so you can click back onto the
target window before the next command fires — you never need to re-focus
between the commands that follow one pause. The config it edits for step 1 is
backed up to a private temp file (created fresh each run, so it never
overwrites a backup of your own) only after the manual-override check below
passes; it is always restored on exit, Ctrl-C, or `kill`. A symlinked config
stays a symlink, and if the restore itself ever fails the script leaves the
backup in place and prints where it is instead of deleting it.

| # | What the script does | What you do / expect |
|---|---|---|
| 1 | Checks that the active Spaces on the two displays have different modes. Applies an explicit `layout` override (whichever of `bsp`/`master_grid` isn't already that Space's mode) plus a `promote` on the first display. Only if that Space is actually manual with the override set does it back up and touch the config to trigger a hot reload, then restore it exactly; otherwise it fails that check and skips the reload without ever touching your config. Restores `layout default` + `reset` afterwards either way. | Focus a window (2+ tiled windows on its Space) on the named FIRST display when the countdown starts. **Expect:** the Space becomes manual with the explicit override before the config is touched, then `modes/overrides unchanged and the manual arrangeme…
| 2 | Resets the Space, launches the light app, then launches the heavy app. | Focus a `master_grid` Space and quit the heavy app first. **Expect:** the heavy app slides into the master slot on its own, and the light app moves to the stack. The Space is still not manual. |
| 3 | Diffs Space membership before and after your Mission Control drag. | In Mission Control, drag a tiled window onto another desktop thumbnail whose mode differs, then exit. **Expect:** the window is reported on its new Space, laid out in that Space's mode (for example it joins the BSP tree), and the source Space closes the gap. |
| 4 | Toggles monocle on and off. Checks that every frame is identical while monocle is on and that the arrangement is restored exactly afterwards. Swaps with Reduce Motion on, then off. | **Expect:** a `Z` suffix in the menu bar while monocle is on. With Reduce Motion **on**, swaps snap instantly. With it **off**, the focused window glides (~180 ms) and the others snap. |

The script ends with `N passed, 0 failed`.

## Extra manual checks (optional, about 1 minute each)

- **Invalid config:** save a typo (for example `mode = "spiral"`). The menu
  bar turns red (`! 2 · MS`), a notification names the path and error, and
  layouts keep working with the previous config. Fix the typo and the red
  clears.
- **Reset:** promote a window to master (`ballast send promote`), open a
  heavier app (it must *not* take the master slot, because the Space is
  manual), then run `ballast send reset`. The heavy app becomes master.
- **Weighted stack:** on a `master_grid` Space that isn't manual (run
  `ballast send reset`), with a heavier master such as Ghostty at weight 10
  and three weight-1 stack windows, focus a stack window and pick
  **Focused App: …** → **Weight** → **2** in the menu. It moves to the top
  of the stack and becomes twice as tall as each of the other two. Pick
  **5** instead and it stops at three times their height, the default
  Weight Share Limit (Max 75%). Set it back to **1 (default)** and the
  stack evens out.
- **Scrolling stack:** set a Space to `master_stack` with one master and 3+
  other windows, then focus a stack window in the middle of the stack.
  **Expect:** only that window fills the stack region; the previous window
  in stack order shows a `stack_peek`-wide strip of its title bar above it
  (or to its side, per `stack_side`), and the next one shows a strip of its
  bottom edge below. `focus down` (or `focus right` for `stack_side = top`/`bottom`)
  scrolls the deck to bring the next window into view; `focus up`/`left`
  scrolls back. At the first stack window nothing peeks above it and it
  reaches the top of the stack region; at the last, it reaches the bottom.
- **Deck order:** on a `master_grid` Space with `grid_max = 2` and 3+ stack
  windows, focus the bottom tile, then click the title strip peeking above
  the top tile. **Expect:** the clicked window scrolls into view, both
  tiles in view show in full, and the window that lost focus shows only its
  peek strip below them. Focus the master afterwards: nothing changes.
- **Grid columns:** on a `master_grid` Space with `grid_columns = 3` and
  `grid_max = 2`, open 8 windows (plus the master). **Expect:** the stack
  splits into 3 side-by-side columns, filled nearest the master first (the
  two columns closest to the master hold 3 windows each, the outermost
  holds the rest and scrolls with `stack_peek`); with only 3 stack windows
  total, each column holds one and none scroll.
- **Stack both sides:** on a `master_stack` Space with `stack_both_sides =
  true` and 4+ other windows, focus a stack window. **Expect:** a
  one-window stack shows on `stack_side`'s side and another on the
  opposite side (left+right, or top+bottom if `stack_side` is `top`/
  `bottom`), the master keeps `master_ratio` of the space, and the two
  stacks split the remainder evenly; the earlier half of the stack order is
  on `stack_side`'s side, the rest on the opposite side.
- **Mode by display:** with no `mode` in `[layout]` and the laptop lid
  open, `ballast spaces` shows `mode=master_stack` for the built-in
  display's desktops that don't set their own mode, and `mode=master_grid`
  for an external display's.
- **Dialogs float:** open an app's Settings window and an "About" window.
  **Expect:** both float over the tiled windows, and **Window Inspector…**
  shows the reason, e.g. `Floating — default: no full-screen button`.
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
- **Drag preview:** drag a tile by its title bar over another tile. A
  translucent accent-colored zone exactly covers the window you'd swap
  with, under the dragged window (which stays untinted), and follows the
  cursor from tile to tile; over a gap or the window's own tile it
  disappears, and over the other display it shows the tile the window would
  get there. Release: the two windows trade places. Dragging a tile's edge
  (a resize) shows no zone.
