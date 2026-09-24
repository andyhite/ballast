#!/usr/bin/env bash
# Installs (or updates) build/Ballast.app into /Applications, turns on
# Start at Login (SMAppService LaunchAgent bundled in the app), and links the
# `ballast` CLI onto PATH.
#
# Usage: scripts/build-app.sh && scripts/install.sh
#        scripts/install.sh --uninstall
#
#   BIN_DIR=/usr/local/bin (default)  where the `ballast` CLI symlink goes
#
# Updates keep the user's Start at Login choice. The agent is unregistered
# before the bundle is replaced and registered again after: launchd can't
# relaunch an agent whose bundle was swapped underneath it (EX_CONFIG).
set -euo pipefail
cd "$(dirname "$0")/.."

app_dest=/Applications/Ballast.app
exe=$app_dest/Contents/MacOS/ballast
bin_dir=${BIN_DIR:-/usr/local/bin}
lock=~/Library/Caches/dev.ballast/run.lock  # held by every running `ballast run`

# Pid of the running Ballast, if any (from its single-instance lock).
running_pid() { [ -e "$lock" ] && lsof -t "$lock" 2>/dev/null | head -1 || true; }
agent_pid() { launchctl print "gui/$(id -u)/dev.ballast" 2>/dev/null | awk '/^\tpid = /{print $3; exit}'; }
login_item_on() { [ -x "$exe" ] && "$exe" login-item status 2>/dev/null | grep -q ': on$'; }

# Unregistering stops the agent; wait until launchd has dropped the job and
# the process has released the lock.
stop_login_item() {
  "$exe" login-item off >/dev/null
  for _ in $(seq 50); do
    if [ -z "$(running_pid)" ] && ! launchctl print "gui/$(id -u)/dev.ballast" >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.1
  done
  echo "Ballast (pid $(running_pid)) did not stop" >&2
  exit 1
}

# Registering right after the bundle was swapped can leave launchd unable to
# spawn the new binary (EX_CONFIG, retried every 2 s forever). Confirm the
# agent is running; if not, unregister, let launchd settle, and register again.
start_login_item() {
  "$exe" login-item on
  for attempt in 1 2; do
    for _ in $(seq 50); do
      [ -n "$(agent_pid)" ] && return 0
      sleep 0.1
    done
    [ "$attempt" = 2 ] && break
    echo "launchd couldn't start Ballast; registering it again" >&2
    stop_login_item
    sleep 2
    "$exe" login-item on
  done
  echo "Ballast didn't start. Details: launchctl print gui/$(id -u)/dev.ballast" >&2
  exit 1
}

# Anything running that launchd won't stop for us would keep the old binary
# (or, for a dev build, fight the new one over every window).
refuse_if_foreign_instance() {
  local pid
  pid=$(running_pid)
  if [ -n "$pid" ] && [ "$pid" != "$(agent_pid)" ]; then
    echo "Ballast is running outside Start at Login (pid $pid: $(ps -o command= -p "$pid"))." >&2
    echo "Quit it first (menu > Quit Ballast, or Ctrl-C the terminal running it)." >&2
    exit 1
  fi
}

if [ "${1:-}" = "--uninstall" ]; then
  refuse_if_foreign_instance
  [ -x "$exe" ] && stop_login_item
  [ "$(readlink "$bin_dir/ballast" 2>/dev/null)" = "$exe" ] && rm -f "$bin_dir/ballast"
  rm -rf "$app_dest"
  echo "uninstalled (config in ~/.config/ballast and the Accessibility entry are left alone)"
  exit 0
fi

[ -d build/Ballast.app ] || { echo "build/Ballast.app missing: run scripts/build-app.sh first" >&2; exit 1; }
refuse_if_foreign_instance

first_install=true
start_at_login=true
if [ -d "$app_dest" ]; then
  first_install=false
  if login_item_on; then stop_login_item; else start_at_login=false; fi
fi

rm -rf "$app_dest"
ditto build/Ballast.app "$app_dest"
echo "installed $app_dest"

if $start_at_login; then
  start_login_item
else
  echo "Start at Login is off (your choice): open $app_dest to run it"
fi

if [ -w "$bin_dir" ]; then
  ln -sf "$exe" "$bin_dir/ballast"
  echo "linked $bin_dir/ballast"
else
  echo "$bin_dir is not writable; link the CLI yourself:"
  echo "  sudo ln -sf $exe $bin_dir/ballast"
fi

if $first_install; then
  cat <<EOF

First install: Ballast asks for Accessibility on launch. Approve it in
System Settings > Privacy & Security > Accessibility; Ballast starts managing
without a restart. With a certificate signature (scripts/build-app.sh default)
the grant survives later rebuilds; with SIGN_ID=- it does not.
EOF
fi
