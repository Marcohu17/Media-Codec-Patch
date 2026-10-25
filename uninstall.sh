#!/system/bin/sh
# Module uninstall. Puts quarantined items back before erasing our own data.

case "$0" in
  */*) MODROOT=${0%/*} ;;
  *)   MODROOT="." ;;
esac
[ -d "${MODROOT}/common" ] && COMMON_DIR="${MODROOT}/common"
. "${COMMON_DIR}/env.sh"

# 1. unlock anything we may have locked
for _d in /data/adb/lspd/log /data/adb/lspd/log_old; do
  [ -d "$_d" ] && chattr -i "$_d" 2>/dev/null
done

# 2. stop the loop
if [ -f "$STATE_DIR/daemon.pid" ]; then
  _p=$(cat "$STATE_DIR/daemon.pid" 2>/dev/null | tr -d ' \r\n')
  [ -n "$_p" ] && kill "$_p" 2>/dev/null
fi

# 3. restore every quarantine batch, newest first
if [ -d "$QUAR_DIR" ]; then
  for _b in $(ls -1 "$QUAR_DIR" 2>/dev/null | sort -r); do
    [ -f "$QUAR_DIR/$_b/manifest.txt" ] || continue
    "${COMMON_DIR}/scrub.sh" --restore "$_b" >/dev/null 2>&1
  done
fi

# 4. drop our own data last
rm -rf "/data/adb/${MODID}" 2>/dev/null
