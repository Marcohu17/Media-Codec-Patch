#!/usr/bin/env bash
# tools/bridge-sim/make-fast.sh
#
# Regenerates app-fast.js from the real webroot/app.js with the command
# timeouts shrunk to about a second, so the watchdog path can be exercised in
# a test without waiting a minute.
#
# app-fast.js is a build product: never edit it by hand, and regenerate it
# after touching app.js or the two files quietly drift apart.
set -eu

here=$(cd "$(dirname "$0")" && pwd)
src="$here/../../webroot/app.js"
out="$here/app-fast.js"

[ -f "$src" ] || { echo "missing $src" >&2; exit 1; }

sed \
  -e 's/TIMEOUT_SCAN = 60000/TIMEOUT_SCAN = 1200/' \
  -e 's/TIMEOUT_NET = 45000/TIMEOUT_NET = 900/' \
  -e 's/TIMEOUT_DEF = 20000/TIMEOUT_DEF = 800/' \
  "$src" > "$out"

# Fail loudly if the rewrite ever stops matching, rather than shipping a test
# that silently runs with production timeouts.
grep -q 'TIMEOUT_SCAN = 1200' "$out" || { echo 'timeout rewrite did not apply' >&2; exit 1; }

echo "wrote $out"
