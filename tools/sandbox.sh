#!/usr/bin/env bash
# tools/sandbox.sh - run the module's shell logic against a fake Android tree
#
# Copies common/ into a temporary directory, rewrites every /data path so it
# points inside that directory, then runs one script from it. Nothing outside
# the sandbox is touched, and no real device path is created.
#
# Usage:
#   bash tools/sandbox.sh upstream.sh --check
#   bash tools/sandbox.sh --with-hma audit.sh
#   bash tools/sandbox.sh --hma-empty hma.sh probe
#   bash tools/sandbox.sh --no-hash autoconfig.sh --status
#   bash tools/sandbox.sh --keep autoconfig.sh
#
# This only proves the shell logic runs and degrades correctly. It cannot prove
# anything about a real device: no ksud, no sqlite3, no pm, no pidof here.

set -u

SRC=$(cd "$(dirname "$0")/.." && pwd)

WITH_HMA=0
HMA_STORE=0
HMA_EMPTY=0
NO_HASH=0
KEEP=0
FAKE_KSUD=0

while [ $# -gt 0 ]; do
  case "$1" in
    --with-hma) WITH_HMA=1; shift ;;
    --hma-store) HMA_STORE=1; shift ;;
    --hma-empty) HMA_EMPTY=1; shift ;;
    --no-hash)  NO_HASH=1;  shift ;;
    --keep)     KEEP=1;     shift ;;
    --fake-ksud) FAKE_KSUD=1; shift ;;
    *)          break ;;
  esac
done

if [ $# -lt 1 ]; then
  echo "usage: sandbox.sh [--with-hma] [--no-hash] [--keep] <script.sh> [args...]" >&2
  exit 2
fi

SCRIPT="$1"; shift

SB=$(mktemp -d 2>/dev/null) || { echo "mktemp failed" >&2; exit 2; }
MODROOT="$SB/data/adb/modules/lsposed_stealth"

mkdir -p "$MODROOT"
cp -r "$SRC/common"   "$MODROOT/" || exit 2
cp    "$SRC/module.prop" "$MODROOT/" 2>/dev/null

# Redirect every absolute Android path into the sandbox.
for f in "$MODROOT"/common/*.sh; do
  [ -f "$f" ] || continue
  sed -i \
    -e "s#/data/adb#${SB}/data/adb#g" \
    -e "s#/data/local/tmp#${SB}/data/local/tmp#g" \
    -e "s#/data/misc#${SB}/data/misc#g" \
    "$f"
done
sed -i "s#/data/adb#${SB}/data/adb#g" "$MODROOT/module.prop" 2>/dev/null

if [ "$WITH_HMA" = "1" ]; then
  mkdir -p "$SB/data/adb/modules/hma_oss_zygisk"
  printf 'id=hma_oss_zygisk\nname=Hide My Applist OSS\nversion=v1\n' \
    > "$SB/data/adb/modules/hma_oss_zygisk/module.prop"
  mkdir -p "$SB/data/misc/hide_my_applist_1620000000"
  printf '{"enabled":true}\n' > "$SB/data/misc/hide_my_applist_1620000000/status.json"
fi

# A store shaped the way HMA actually writes it. Three files decide the
# verdict: config.json (configVersion + templates + settingsTemplates),
# filter_count.json (the per-app counters) and status.json (workMode). The
# logs and the memory dump sit beside them, and the dump is the file a probe
# must not waste time searching.
if [ "$HMA_STORE" = "1" ] || [ "$HMA_EMPTY" = "1" ]; then
  mkdir -p "$SB/data/adb/modules/hma_oss_zygisk"
  printf 'id=hma_oss_zygisk\nname=Hide My Applist OSS\nversion=v1\n' \
    > "$SB/data/adb/modules/hma_oss_zygisk/module.prop"
  _hs="$SB/data/misc/hide_my_applist_1620000000"
  mkdir -p "$_hs/log"
  printf '{"workMode":1,"managerUid":10351}\n' > "$_hs/status.json"
  printf '{"cache":{"custom_rom":["com.android.overlay"],"detector_apps":[],"root_apps":["com.sukisu.ultra"]}}\n' \
    > "$_hs/preset_cache_v2.json"
  printf '[ INFO] Config loaded\n[ INFO] Filter counts loaded\n' > "$_hs/log/runtime.log"
  printf 'bin\x01ary\x02com.tencent.mm\x7f\n' > "$_hs/log/blob.dat"

  if [ "$HMA_STORE" = "1" ]; then
    printf '{"configVersion":93,"templates":{"tpl_wx":{"com.tencent.mm":"微信隐藏模板"}},"settingsTemplates":{}}\n' \
      > "$_hs/config.json"
    printf '{"filterCounts":{"com.tencent.mm":7}}\n' > "$_hs/filter_count.json"
  else
    printf '{"configVersion":93,"templates":{},"settingsTemplates":{},"defaultConfig":null}\n' \
      > "$_hs/config.json"
    printf '{"filterCounts":{}}\n' > "$_hs/filter_count.json"
  fi
fi

# A stand-in for ksud so the feature code path can be exercised end to end.
# It answers the exact shapes the real binary does: feature check prints one
# token per line, feature get prints a "Value: <n>" line, feature set persists.
# Values default to 0 and are stored in a plain file inside the sandbox.
if [ "$FAKE_KSUD" = "1" ]; then
  mkdir -p "$SB/data/adb/ksu/bin"
  cat > "$SB/data/adb/ksu/bin/ksud" <<'KSUDEOF'
#!/bin/sh
STATE="__SB__/data/adb/ksu/feature.state"
case "$1" in
  feature)
    case "$2" in
      check)
        case "$3" in
          kernel_umount|sulog|selinux_hide|adb_root|su_compat|shell_su_adb_only)
            echo supported ;;
          *)
            echo unsupported ;;
        esac
        ;;
      get)
        mkdir -p "$(dirname "$STATE")" 2>/dev/null
        V=$(grep -m1 "^$3=" "$STATE" 2>/dev/null | sed -e "s/^$3=//")
        echo "Feature: $3"
        echo "Value: ${V:-0}"
        ;;
      set)
        mkdir -p "$(dirname "$STATE")" 2>/dev/null
        touch "$STATE" 2>/dev/null
        grep -v "^$3=" "$STATE" > "$STATE.tmp" 2>/dev/null
        echo "$3=$4" >> "$STATE.tmp"
        mv -f "$STATE.tmp" "$STATE" 2>/dev/null
        ;;
    esac
    ;;
esac
exit 0
KSUDEOF
  sed -i "s#__SB__#${SB}#g" "$SB/data/adb/ksu/bin/ksud"
  chmod +x "$SB/data/adb/ksu/bin/ksud"
fi

if [ "$NO_HASH" = "1" ]; then
  printf 'HASHER=""\n' >> "$MODROOT/common/env.sh"
fi

echo "sandbox: $SB" >&2
echo "running: $SCRIPT $*" >&2
echo "--------" >&2

bash "$MODROOT/common/$SCRIPT" "$@"
_rc=$?

echo "--------" >&2
echo "exit: $_rc" >&2

if [ "$KEEP" = "1" ]; then
  echo "kept: $SB" >&2
else
  rm -rf "$SB"
fi

exit $_rc
