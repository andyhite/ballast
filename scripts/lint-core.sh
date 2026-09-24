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
  '[][:alnum:]_)]![.,)[:space:]]'   # postfix force unwrap (not !=), e.g. x!.foo, xs.first!.count, f(x!), arr[i]!
  '[][:alnum:]_)]!$'                # postfix force unwrap at end of line, e.g. let v = value!
)

status=0
for pattern in "${patterns[@]}"; do
  # Ignore comment-only lines. No string-literal exemption: a naive
  # quote-aware filter here previously mis-scanned across unrelated
  # quoted substrings on the same line (e.g. `case "b": fatalError("x")`
  # or `["a": try!f("x")]`) and silently swallowed real trapping
  # constructs. Flagging occurrences inside string literals is an
  # acceptable, conservative false positive; missing real ones is not.
  if matches=$(grep -HnE "$pattern" Sources/BallastCore/*.swift | grep -vE '^\S+:[0-9]+:\s*//'); then
    echo "trap-prone construct ($pattern):"
    echo "$matches"
    status=1
  fi
done
[ $status -eq 0 ] && echo "lint-core: OK (no trapping constructs in Sources/BallastCore)"
exit $status
