#!/usr/bin/env bash
# Fails if BallastCore contains constructs that can trap at runtime:
# force unwraps, force try/cast, fatalError/precondition/assert.
# Usage: scripts/lint-core.sh
set -euo pipefail
cd "$(dirname "$0")/.."

patterns=(
  'try!'
  'as!'
  'fatalError\('
  'precondition(Failure)?\('
  '\bassert(ionFailure)?\('
  '[][:alnum:]_)}>]![][),.:;}[:space:]]'   # postfix force unwrap (not !=), e.g. x!.foo, f(x!), a[i!], opt![0], [k: v!], {$0!}
  '[][:alnum:]_)}>]!$'                      # postfix force unwrap / IUO at end of line, e.g. let v = value!, var s: Set<Int>!
)

status=0
for pattern in "${patterns[@]}"; do
  # Ignore comment-only lines. No string-literal exemption: a naive
  # quote-aware filter here previously mis-scanned across unrelated
  # quoted substrings on the same line (e.g. `case "b": fatalError("x")`
  # or `["a": try!f("x")]`) and silently swallowed real trapping
  # constructs. Flagging occurrences inside string literals is an
  # acceptable, conservative false positive; missing real ones is not.
  rc=0
  raw=$(grep -rHnE --include='*.swift' "$pattern" Sources/BallastCore) || rc=$?
  [ "$rc" -le 1 ] || { echo "lint-core: grep failed ($rc) for pattern: $pattern" >&2; exit 2; }
  if [ -n "$raw" ] && matches=$(grep -vE '^\S+:[0-9]+:\s*//' <<<"$raw"); then
    echo "trap-prone construct ($pattern):"
    echo "$matches"
    status=1
  fi
done
[ $status -eq 0 ] && echo "lint-core: OK (no trapping constructs in Sources/BallastCore)"
exit $status
