#!/system/bin/sh
# common/daemon.sh - background loop
#
# Started detached by service.sh. Re-reads the interval every tick so a change
# from the panel takes effect without a reboot. Exits when the module is
# disabled or removed.

MODROOT=${0%/*}
[ -d "${MODROOT}/../common" ] && MODROOT="${MODROOT}/.."
[ -d "${MODROOT}/common" ] && COMMON_DIR="${MODROOT}/common"
. "${COMMON_DIR}/env.sh"

_pid=$$
echo "$_pid" > "$STATE_DIR/daemon.pid" 2>/dev/null
log "daemon: started pid=${_pid}"

while true; do
  if [ -f "${MODDIR}/disable" ] || [ -f "${MODDIR}/remove" ]; then
    log "daemon: module disabled or removed, exiting"
    break
  fi

  _iv=$(conf_get daemon_interval 300)
  case "$_iv" in ''|*[!0-9]*) _iv=300 ;; esac
  [ "$_iv" -lt 60 ] && _iv=60

  "$COMMON_DIR/audit.sh" >/dev/null 2>&1
  "$COMMON_DIR/scrub.sh" >/dev/null 2>&1

  _mode=$(conf_get mute_mode gentle)
  if [ "$_mode" != "off" ]; then
    "$COMMON_DIR/mute.sh" >/dev/null 2>&1
  fi

  _now=$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null)
  printf '%s pid=%s interval=%s' "$_now" "$_pid" "$_iv" > "$STATE_DIR/heartbeat" 2>/dev/null

  sleep "$_iv"
done

rm -f "$STATE_DIR/daemon.pid" 2>/dev/null
log "daemon: exited pid=${_pid}"
