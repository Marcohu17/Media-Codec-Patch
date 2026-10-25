#!/system/bin/sh
# Runs early in boot, before zygote starts. Keep this short: anything slow here
# delays the whole boot.

case "$0" in
  */*) MODROOT=${0%/*} ;;
  *)   MODROOT="." ;;
esac
[ -d "${MODROOT}/common" ] && COMMON_DIR="${MODROOT}/common"
. "${COMMON_DIR}/env.sh"

mkdir -p "$STATE_DIR" "$CONF_DIR" "$QUAR_DIR" 2>/dev/null

# Keys this version adds have to be on disk before anything reads them. A
# failure here is not fatal: every key also has a default in code, so a broken
# migration degrades to those defaults instead of holding up the boot.
if [ -f "$COMMON_DIR/migrate.sh" ]; then
  sh "$COMMON_DIR/migrate.sh" --apply >/dev/null 2>&1 || \
    log "boot: config migration failed, defaults in use"
fi

# Clear any immutable flag a previous aggressive run may have left behind.
# Booting with a locked log dir would make LSPosed fail silently all session.
if [ "$(conf_get mute_mode gentle)" != "aggressive" ]; then
  for _d in /data/adb/lspd/log /data/adb/lspd/log_old; do
    [ -d "$_d" ] && chattr -i "$_d" 2>/dev/null
  done
fi

# Optional property guard. Off by default: rewriting build properties can change
# how other apps behave, and it does not defeat kernel-level checks.
if [ "$(conf_get prop_guard 0)" = "1" ]; then
  if [ -n "$RESETPROP" ]; then
    rp ro.debuggable 0
    rp ro.secure 1
    rp ro.build.tags release-keys
    rp ro.boot.flash.locked 1
    log "boot: prop guard applied"
  else
    log "boot: prop guard requested but resetprop is unavailable"
  fi
fi

log "boot: post-fs-data done (module=${MODID})"
