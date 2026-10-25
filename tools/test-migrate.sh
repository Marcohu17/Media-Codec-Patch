#!/usr/bin/env bash
# tools/test-migrate.sh - exercise common/migrate.sh against a fake data tree
#
# migrate.sh has four subcommands and the interesting ones only make sense in
# sequence: snapshot, then change something, then restore. sandbox.sh runs one
# command per fresh tree, so this script builds one tree and drives it through
# the whole lifecycle instead.
#
# Nothing outside the temporary directory is touched. Output is a line per
# assertion plus the raw JSON of every call, so a failure can be read without
# re-running anything.
#
# Usage: bash tools/test-migrate.sh [--keep]

set -u

SRC=$(cd "$(dirname "$0")/.." && pwd)
KEEP=0
[ "${1:-}" = "--keep" ] && KEEP=1

SB=$(mktemp -d 2>/dev/null) || { echo "mktemp failed" >&2; exit 2; }
MODROOT="$SB/data/adb/modules/lsposed_stealth"
DATA="$SB/data/adb/lsposed_stealth"
CONF="$DATA/config/settings.conf"

mkdir -p "$MODROOT"
cp -r "$SRC/common" "$MODROOT/" || exit 2
cp "$SRC/module.prop" "$MODROOT/" 2>/dev/null

# Redirect every absolute Android path into the sandbox, exactly as
# sandbox.sh does, so the scripts under test run unmodified.
for f in "$MODROOT"/common/*.sh; do
  [ -f "$f" ] || continue
  sed -i \
    -e "s#/data/adb#$SB/data/adb#g" \
    -e "s#/data/local/tmp#$SB/data/local/tmp#g" \
    -e "s#/data/misc#$SB/data/misc#g" \
    "$f"
done

MIG="$MODROOT/common/migrate.sh"

pass=0
fail=0

# Command substitution must capture the JSON and nothing else, so the trace line
# goes to stderr and only the raw result goes to stdout.
run() {
  _r=$(sh "$MIG" "$@" 2>&1)
  echo "JSON $* -> $_r" >&2
  printf '%s' "$_r"
}

expect() { # expect <label> <needle> <haystack>
  case "$3" in
    *"$2"*) echo "PASS $1"; pass=$((pass + 1)) ;;
    *)
      echo "FAIL $1"
      echo "  want: $2"
      echo "  got : $3"
      fail=$((fail + 1))
      ;;
  esac
}

# ---------- 1. fresh install ----------
r=$(run --check)
expect "fresh: state"            '"state":"fresh"' "$r"
expect "fresh: no config yet"    '"config_existed":false' "$r"
expect "fresh: zero present"     '"keys_present":0' "$r"
expect "fresh: names a key"      '"missing":["daemon_enabled"' "$r"

[ -f "$CONF" ] && { echo "FAIL fresh: check wrote the config"; fail=$((fail + 1)); } || {
  echo "PASS fresh: check wrote nothing"; pass=$((pass + 1));
}

r=$(run --apply)
expect "fresh: apply created"    '"created":true' "$r"
expect "fresh: added 8"          '"added_count":8' "$r"
expect "fresh: apply recorded"   '"install_recorded":true' "$r"
expect "fresh: version written"  '"version":"v1.2.2"' "$r"
expect "apply: schema stamped"   'schema_version=1' "$(cat "$CONF")"

r=$(run --check)
expect "fresh: now current"      '"state":"current"' "$r"
expect "fresh: eight of eight"   '"keys_present":8' "$r"
expect "fresh: install known"    '"installed_version":"v1.2.2"' "$r"

r=$(run --apply)
expect "second apply: no record" '"install_recorded":false' "$r"
expect "second apply: no adds"   '"added_count":0' "$r"

# ---------- 2. older install, some keys absent ----------
rm -rf "$DATA"
mkdir -p "$DATA/config"
printf 'daemon_enabled=1\ndaemon_interval=120\n' > "$CONF"

r=$(run --check)
expect "partial: missing keys"   '"state":"missing_keys"' "$r"
expect "partial: counts present" '"keys_present":2' "$r"
expect "partial: names a key"    '"missing":["scrub_enabled"' "$r"

r=$(run --apply)
expect "partial: added 6"        '"added_count":6' "$r"
expect "partial: created false"  '"created":false' "$r"

_iv=$(grep '^daemon_interval=' "$CONF" | sed 's/^daemon_interval=//')
expect "partial: kept 120"       "120" "$_iv"

r=$(run --check)
expect "partial: current now"    '"state":"current"' "$r"

# ---------- 3. stale key left behind ----------
cp "$CONF" "$CONF.bak"
printf 'stale_key=1\n' >> "$CONF"

r=$(run --check)
expect "extra: still current"    '"state":"current"' "$r"
expect "extra: reported"         '"extra":["stale_key"]' "$r"
cp "$CONF.bak" "$CONF"
rm -f "$CONF.bak"

# ---------- 4. unreadable config ----------
printf '###\nnot a key value line\n' > "$CONF"

r=$(run --check)
expect "broken: seen as missing" '"state":"missing_keys"' "$r"
expect "broken: zero present"    '"keys_present":0' "$r"

r=$(run --apply)
expect "broken: refilled"        '"added_count":8' "$r"

r=$(run --check)
expect "broken: current after"   '"state":"current"' "$r"

# ---------- 5. snapshot ----------
mkdir -p "$DATA/state" "$DATA/autoconfig"
printf 'ok=1\nchecked_at=2026-10-25 19:00:00\n' > "$DATA/state/upstream.conf"
printf '{"mode":"apply"}\n' > "$DATA/autoconfig/last.json"

r=$(run --snapshot)
expect "snapshot: ok"            '"ok":true' "$r"
expect "snapshot: three files"   '"copied_count":3' "$r"
expect "snapshot: kept 1"        '"kept":1' "$r"
expect "snapshot: names conf"    'config/settings.conf' "$r"
expect "snapshot: skips absent"  '"skipped":["autoconfig/baseline.snap"' "$r"

SNAP_A=$(printf '%s' "$r" | sed -n 's/.*"name":"\([^"]*\)".*/\1/p' | head -n1)
[ -n "$SNAP_A" ] && echo "PASS snapshot: parsed name" && pass=$((pass + 1)) || {
  echo "FAIL snapshot: parsed name"; fail=$((fail + 1));
}

expect "snapshot: meta written"  'label=manual' "$(cat "$DATA/backup/$SNAP_A/meta.txt" 2>/dev/null)"
expect "snapshot: meta version"  'version=v1.2.2' "$(cat "$DATA/backup/$SNAP_A/meta.txt" 2>/dev/null)"

# ---------- 6. restore ----------
sh "$MODROOT/common/conf.sh" set mute_mode off >/dev/null 2>&1
_m=$(grep '^mute_mode=' "$CONF" | sed 's/^mute_mode=//')
expect "restore: setup changed"  'off' "$_m"

r=$(run --restore "$SNAP_A")
expect "restore: ok"             '"ok":true' "$r"
expect "restore: back to gentle" 'mute_mode=gentle' "$(cat "$CONF")"
expect "restore: pre snapshot"   '"pre_snapshot":"' "$r"

_b=$(ls -1 "$DATA/backup" 2>/dev/null | wc -l | tr -d ' ')
expect "restore: pre kept too"   '2' "$_b"

r=$(run --restore)
expect "restore: defaults newest" '"ok":true' "$r"

# ---------- 7. restore from a snapshot that predates this version ----------
rm -rf "$DATA/backup"
mkdir -p "$DATA/backup/20200101-000000/config"
printf 'daemon_enabled=1\n' > "$DATA/backup/20200101-000000/config/settings.conf"

r=$(run --restore 20200101-000000)
expect "old snapshot: ok"        '"ok":true' "$r"
expect "old snapshot: backfilled" '"backfilled":["' "$r"
expect "old snapshot: seven keys" '"scrub_enabled' "$r"

r=$(run --check)
expect "old snapshot: current"   '"state":"current"' "$r"

# ---------- 8. missing snapshot ----------
r=$(run --restore 20991231-999999)
expect "no such snapshot: false" '"ok":false' "$r"
expect "no such snapshot: reason" '找不到这份快照' "$r"

# ---------- 9. retention ----------
rm -rf "$DATA/backup"
for _i in 1 2 3 4 5 6 7; do
  mkdir -p "$DATA/backup/2026010${_i}-000000/config"
  printf 'daemon_enabled=1\n' > "$DATA/backup/2026010${_i}-000000/config/settings.conf"
done

r=$(run --snapshot)
_c=$(ls -1 "$DATA/backup" 2>/dev/null | wc -l | tr -d ' ')
expect "retention: capped at 5"  '5' "$_c"
expect "retention: pruned 3"     '"pruned":3' "$r"

# ---------- summary ----------
echo "--------"
echo "pass=$pass fail=$fail"

if [ "$KEEP" = "1" ]; then
  echo "kept: $SB" >&2
else
  rm -rf "$SB"
fi

[ "$fail" -eq 0 ] || exit 1
