#!/usr/bin/env bash
# Live smoke test against a running Ballast instance. See docs/SMOKE_TEST.md.
# Requires: jq, a running `ballast run`, two displays, the Space overrides from
# docs/SMOKE_TEST.md in the config. Steps that need a human (Mission Control
# drag, Reduce Motion toggle, eyeballing animation) pause with a prompt.
set -uo pipefail
cd "$(dirname "$0")/.."

BALLAST=${BALLAST:-.build/debug/ballast}
CONFIG=""
STATE="$HOME/Library/Caches/dev.ballast/state.json"
HEAVY=${SMOKE_HEAVY_APP:-com.apple.Safari}   # non-terminal app; needs a weight > 1 rule in your config
LIGHT=${SMOKE_LIGHT_APP:-com.apple.TextEdit}
if [ "$HEAVY" = "${__CFBundleIdentifier:-}" ]; then
  echo "SMOKE_HEAVY_APP ($HEAVY) is the terminal running this script; quitting it would kill the test. Set SMOKE_HEAVY_APP to a different app."
  exit 2
fi
pass=0; fail=0

ok()   { echo "  ✓ $*"; pass=$((pass + 1)); }
bad()  { echo "  ✗ $*"; fail=$((fail + 1)); }
step() { printf '\n== %s\n' "$*"; }
pause(){
  read -r -p "  → $* [enter] " _
  local n=3
  while [ "$n" -gt 0 ]; do
    printf '\r  starting in %ds — click/focus the target window now...   ' "$n"
    sleep 1
    n=$((n - 1))
  done
  printf '\r%*s\r' 60 ''
}
dump() { rm -f "$STATE"; "$BALLAST" send dump-state; for _ in $(seq 40); do [ -s "$STATE" ] && break; sleep 0.05; done; cat "$STATE"; }
active_spaces() { dump | jq -c '[.spaces[] | select(.active and .ordinal != null)]'; }

CONFIG_BACKUP=""
restore_config() {
  [ -n "$CONFIG_BACKUP" ] && [ -f "$CONFIG_BACKUP" ] || return 0
  # Wait for any in-flight ~0.3s settings persistence to land before we
  # overwrite the config, instead of guessing a fixed delay: poll dump-state
  # until every Space's transient feature_size/feature_count override has
  # cleared, capped so a stuck/dead Ballast can't hang the restore.
  local waited=0
  while [ "$waited" -lt 20 ]; do
    dump 2>/dev/null | jq -e '[.spaces[]? | select(.feature_size_override != null or .feature_count_override != null)] | length == 0' >/dev/null 2>&1 && break
    sleep 0.05
    waited=$((waited + 1))
  done
  if cat "$CONFIG_BACKUP" > "$CONFIG"; then
    rm -f "$CONFIG_BACKUP"
    CONFIG_BACKUP=""
  else
    echo "  ✗ FATAL: failed to restore $CONFIG from backup; original preserved at $CONFIG_BACKUP — restore it manually" >&2
    exit 1
  fi
}
on_signal() {
  code=$1
  restore_config
  trap - EXIT INT TERM
  exit "$code"
}
trap restore_config EXIT
trap 'on_signal 130' INT
trap 'on_signal 143' TERM

rm -f "$STATE"; "$BALLAST" send dump-state; sleep 0.5
[ -s "$STATE" ] || { echo "no state dump at $STATE — start Ballast first: $BALLAST run"; exit 2; }
command -v jq >/dev/null || { echo "jq is required"; exit 2; }
dump | jq -e '.status == "running"' >/dev/null || { echo "Ballast is not in the running state:"; jq .status "$STATE"; exit 2; }
CONFIG=$(jq -r '.config' "$STATE")
[ -f "$CONFIG" ] || { echo "no config at $CONFIG"; exit 2; }

# Back up the entire config before any command below can mutate it, and abort
# without touching the file at all if the backup can't be made. restore_config
# (armed via the EXIT/INT/TERM traps above) puts the original bytes back after
# every setting-mutating command in every step, not just step 1.
if tmp_backup=$(mktemp "${TMPDIR:-/tmp}/ballast-smoke-config.XXXXXX") && cat "$CONFIG" > "$tmp_backup"; then
  CONFIG_BACKUP=$tmp_backup   # arm the restore only once the copy is complete
else
  echo "could not create a private backup of $CONFIG; aborting without touching it" >&2
  rm -f "${tmp_backup:-}" 2>/dev/null
  exit 2
fi

# ---------------------------------------------------------------------------
step "1. Two Spaces on two displays keep independent layouts across a config reload"
before=$(active_spaces)
count=$(jq 'length' <<<"$before")
displays=$(jq '[.[].display] | unique | length' <<<"$before")
if [ "$count" -ge 2 ] && [ "$displays" -ge 2 ]; then ok "active Spaces on $displays displays"; else bad "need active Spaces on two displays (got $count on $displays)"; fi
layouts=$(jq -r '[.[].layout] | unique | length' <<<"$before")
[ "$layouts" -ge 2 ] && ok "active Spaces use different layouts: $(jq -r '[.[] | "\(.ordinal)@\(.display[0:8])=\(.layout)"] | join(", ")' <<<"$before")" \
                    || bad "active Spaces share one layout; add the [[space]] overrides from docs/SMOKE_TEST.md"

first_display=$(jq -r '.[0].display' <<<"$before")
first_name=$(jq -r --arg d "$first_display" '[.displays[] | select((.uuid | ascii_upcase) == ($d | ascii_upcase)) | .name][0] // $d' "$STATE")
pause "Focus a window on display '$first_name' (its active Space needs 2+ tiled windows)"
# A feature-size change is the one runtime setting a command can make; it must
# be persisted to the desktop's [[space]] block and its transient override cleared.
"$BALLAST" send feature-size 0.05; sleep 0.6
"$BALLAST" send promote; sleep 0.3
pre=$(active_spaces)
target_id=$(jq -r --arg d "$first_display" '[.[] | select(.display == $d)][0].space_id' <<<"$pre")
target_manual=$(jq -r --argjson id "$target_id" '[.[] | select(.space_id == $id)][0].manual' <<<"$pre")
target_layout=$(jq -r --argjson id "$target_id" '[.[] | select(.space_id == $id)][0].layout' <<<"$pre")
target_override=$(jq -r --argjson id "$target_id" '[.[] | select(.space_id == $id)][0].feature_size_override' <<<"$pre")
if [ "$target_manual" = "true" ] && { [ -z "$target_override" ] || [ "$target_override" = "null" ]; }; then
  ok "Space $target_id ($target_layout) is manual, feature_size was persisted, and the transient override cleared"

  printf '\n# smoke-test touch %s\n' "$(date +%s)" >> "$CONFIG"
  sleep 1.0
  post=$(active_spaces)

  target_same=$(jq -n --argjson a "$pre" --argjson b "$post" --argjson id "$target_id" \
    '(($a[] | select(.space_id == $id)) | {arrange, layout, feature, feature_size_override, manual, order: [.live_order[].id]}) ==
     (($b[] | select(.space_id == $id)) | {arrange, layout, feature, feature_size_override, manual, order: [.live_order[].id]})')
  layouts_same=$(jq -n --argjson a "$pre" --argjson b "$post" \
    '[$a[] | {space_id, arrange, layout, feature_size_override}] == [$b[] | {space_id, arrange, layout, feature_size_override}]')
  if [ "$target_same" = "true" ] && [ "$layouts_same" = "true" ]; then
    ok "layouts/overrides unchanged and the manual arrangement on Space $target_id is preserved by reload"
  else
    bad "state changed across reload"; diff <(jq -S . <<<"$pre") <(jq -S . <<<"$post")
  fi
  dump | jq -e '.config_error == null' >/dev/null && ok "reload accepted (no config error)" || bad "config error: $(jq -r .config_error "$STATE")"
else
  bad "Space $target_id never reached manual with feature_size persisted and its transient override cleared (feature-size + promote); skipping reload check without further mutating the config (is a feature on this Space?)"
fi
"$BALLAST" send reset; sleep 0.3   # put the Space back to its weight-default arrangement (the config file itself is restored to its exact original bytes by the EXIT/INT/TERM trap, not by this line)

# ---------------------------------------------------------------------------
step "2. Weight-based feature reassignment when a heavier app launches"
pause "Focus a window on a fixed or adaptive Space with a feature, quit $HEAVY if it is running, then press enter"
"$BALLAST" send reset
open -b "$LIGHT"; sleep 1.5
space=$(dump | jq -c --arg b "$LIGHT" '[.spaces[] | select(.active and (.arrange == "fixed" or .arrange == "adaptive") and .feature != "none" and any(.live_order[]; .bundle == $b))][0]')
if [ "$space" = "null" ]; then bad "$LIGHT did not land on an active fixed/adaptive Space with a feature"; else
  sid=$(jq '.space_id' <<<"$space")
  ok "$LIGHT tiled on Space $sid (feature: $(jq -r '.live_order[0].app' <<<"$space"))"
  open -b "$HEAVY"; sleep 2
  after=$(dump | jq -c --argjson s "$sid" '.spaces[] | select(.space_id == $s)')
  featured=$(jq -r '.live_order[0].bundle' <<<"$after")
  [ "$featured" = "$HEAVY" ] && ok "$HEAVY (weight $(jq '.live_order[0].weight' <<<"$after")) took the feature slot without any command" \
                            || bad "feature is $featured, expected $HEAVY (is its rule weight > the others?)"
  jq -e '.manual == false' <<<"$after" >/dev/null && ok "Space is not in manual mode (pure weight placement)" || bad "Space unexpectedly manual"
fi

# ---------------------------------------------------------------------------
step "3. Window dragged to another Space in Mission Control adopts that Space's layout"
snapshot=$(dump)
pause "Open Mission Control, drag one tiled window onto a DIFFERENT desktop thumbnail of the same display whose layout differs (e.g. a dwindle Space), exit Mission Control, switch to that desktop, then press enter"
sleep 0.5
moved=$(dump | jq -c --argjson old "$snapshot" '
  [.spaces[] as $s | $s.live_order[] | {id, app, space: $s.space_id, layout: $s.layout}] as $now
  | [$old.spaces[] as $s | $s.live_order[] | {id, space: $s.space_id}] as $was
  | [$now[] | . as $n | select(any($was[]; .id == $n.id and .space != $n.space))]')
if [ "$(jq 'length' <<<"$moved")" -ge 1 ]; then
  jq -r '.[] | "  ✓ \(.app) (\(.id)) now on Space \(.space) laid out as \(.layout)"' <<<"$moved"; pass=$((pass + 1))
  sid=$(jq '.[0].space' <<<"$moved"); wid=$(jq '.[0].id' <<<"$moved")
  dump | jq -e --argjson s "$sid" --argjson w "$wid" '.spaces[] | select(.space_id == $s) | any(.frames[]; .window.id == $w)' >/dev/null \
    && ok "arrived window has a computed frame on its new Space" || bad "arrived window has no frame on its new Space"
else
  bad "no window changed Space (did you drag a *tiled* window and exit Mission Control?)"
fi

# ---------------------------------------------------------------------------
step "4. Monocle toggle + Reduce Motion"
pause "Focus a window on a Space with 2+ tiled windows, then press enter"
before=$(dump | jq -c '[.spaces[] | select(.active)]')
"$BALLAST" send monocle; sleep 0.5
mono=$(dump | jq -c '[.spaces[] | select(.active and .monocle)][0]')
if [ "$mono" != "null" ]; then
  ok "monocle on for Space $(jq '.space_id' <<<"$mono")"
  jq -e '[.frames[] | [.w, .h]] | unique | length == 1' <<<"$mono" >/dev/null && ok "every tiled window has the one deck slot size" || bad "monocle deck frames differ in size"
  jq -e --argjson s "$(jq '.space_id' <<<"$mono")" --argjson b "$before" '.layout == ($b[] | select(.space_id == $s) | .layout)' <<<"$mono" >/dev/null \
    && ok "monocle keeps the desktop's layout" || bad "monocle changed the layout"
  pause "Menu bar should show the layout glyph followed by ⤢, and the menu should read Exit Monocle. Check it, then press enter"
  "$BALLAST" send monocle; sleep 0.5
  sid=$(jq '.space_id' <<<"$mono")
  restored=$(jq -n --argjson a "$before" --argjson b "$(dump | jq -c '[.spaces[] | select(.active)]')" --argjson s "$sid" \
    'def geo: [.frames[] | {id: .window.id, x, y, w, h}] | sort_by(.id);
     ($a[] | select(.space_id == $s) | geo) == ($b[] | select(.space_id == $s) | geo)')
  [ "$restored" = "true" ] && ok "untoggle restored the previous arrangement exactly" || bad "arrangement changed after monocle round-trip"
else
  bad "monocle did not turn on (is a window focused on an active tiled Space?)"
fi
pause "Turn ON System Settings → Accessibility → Display → Reduce motion, then press enter"
dump | jq -e '.reduce_motion == true' >/dev/null && ok "Ballast sees Reduce Motion" || bad "Ballast did not pick up Reduce Motion"
"$BALLAST" send swap right; sleep 0.3; "$BALLAST" send swap left
pause "The focused window should have SNAPPED (no glide) twice. Turn Reduce motion back OFF, then press enter"
dump | jq -e '.reduce_motion == false' >/dev/null && ok "Reduce Motion off again" || bad "Reduce Motion still reported on"
"$BALLAST" send swap right; sleep 0.3; "$BALLAST" send swap left
pause "This time the focused window should GLIDE (~180 ms). Press enter"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
