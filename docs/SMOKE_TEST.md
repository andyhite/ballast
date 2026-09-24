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
     `bsp`, while the active desktop of display B stays `master_stack`. That
     gives two Spaces on two displays with different modes.
   - A second desktop on one display with a mode different from its
     neighbor's. This is the drag target in step 3.
   - A heavy rule and a light app. The example gives Ghostty `weight = 10`.
     Override the apps with `SMOKE_HEAVY_APP` / `SMOKE_LIGHT_APP` (bundle ids).
     The light app defaults to TextEdit.
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
| 1 | Checks that the active Spaces on the two displays have different modes. Applies an explicit `layout` override (whichever of `bsp`/`master_stack` isn't already that Space's mode) plus two swaps on the first display. Only if that Space is actually manual with the override set does it back up and touch the config to trigger a hot reload, then restore it exactly; otherwise it fails that check and skips the reload without ever touching your config. | Focus a window on the FIRST display when the countdown starts. **Expect:** the Space becomes manual with the explicit override before the config is touched, then `modes/overrides unchanged and the manual arrangement on Space … is preserved by reload`. This is the Rift regression. |
| 2 | Resets the Space, launches the light app, then launches the heavy app. | Focus a `master_stack` Space and quit the heavy app first. **Expect:** the heavy app slides into the master slot on its own, and the light app moves to the stack. The Space is still not manual. |
| 3 | Diffs Space membership before and after your Mission Control drag. | In Mission Control, drag a tiled window onto another desktop thumbnail whose mode differs, then exit. **Expect:** the window is reported on its new Space, laid out in that Space's mode (for example it joins the BSP tree), and the source Space closes the gap. |
| 4 | Toggles monocle on and off. Checks that every frame is identical while monocle is on and that the arrangement is restored exactly afterwards. Swaps with Reduce Motion on, then off. | **Expect:** a `Z` suffix in the menu bar while monocle is on. With Reduce Motion **on**, swaps snap instantly. With it **off**, the focused window glides (~180 ms) and the others snap. |

The script ends with `N passed, 0 failed`.

## Extra manual checks (optional, about 1 minute each)

- **Invalid config:** save a typo (for example `mode = "spiral"`). The menu
  bar turns red (`! 2 · MS`), a notification names the path and error, and
  layouts keep working with the previous config. Fix the typo and the red
  clears.
- **Reset:** swap two windows (`ballast send swap left`), open a heavier app
  (it must *not* take the master slot, because the Space is manual), then run
  `ballast send reset`. The heavy app becomes master.
- **Close fallback:** focus A, then B, then C on one Space and close C.
  Focus returns to B, not to whatever AppKit picks.
- **Display move:** `ballast send send-to-display next` moves the focused
  window to the other display, the cursor follows it, and the window is tiled
  there.
