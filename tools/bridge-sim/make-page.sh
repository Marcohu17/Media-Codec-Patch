#!/usr/bin/env bash
# tools/bridge-sim/make-page.sh
#
# Regenerates index.html from the real webroot/index.html with the two edits
# the simulation needs: the stylesheet points back at webroot/, and sim.js is
# loaded before the real app.js.
#
# This page used to be a hand copy of the panel. That copy drifted the moment a
# card was added: the new card simply was not there, and a test against it would
# have passed while showing the user something different from the module.
# Treat index.html here as a build product, same as app-fast.js, and regenerate
# it after touching webroot/index.html.
set -eu

here=$(cd "$(dirname "$0")" && pwd)
src="$here/../../webroot/index.html"
out="$here/index.html"

[ -f "$src" ] || { echo "missing $src" >&2; exit 1; }

sed \
  -e 's#href="style.css"#href="../../webroot/style.css"#' \
  -e 's#<script src="app.js"></script>#<script src="sim.js"></script><script src="../../webroot/app.js"></script>#' \
  "$src" > "$out"

# Fail loudly if a rewrite stops matching, rather than shipping a page that is
# missing its stub and silently tests nothing.
grep -q 'href="../../webroot/style.css"' "$out" || { echo 'stylesheet rewrite did not apply' >&2; exit 1; }
grep -q 'src="sim.js"' "$out" || { echo 'bridge script rewrite did not apply' >&2; exit 1; }
grep -q 'src="../../webroot/app.js"' "$out" || { echo 'app script rewrite did not apply' >&2; exit 1; }

echo "wrote $out"
