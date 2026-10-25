#!/system/bin/sh
# Late-start stage. Detaches the audit loop and returns immediately.

case "$0" in
  */*) MODROOT=${0%/*} ;;
  *)   MODROOT="." ;;
esac
[ -d "${MODROOT}/common" ] && COMMON_DIR="${MODROOT}/common"
. "${COMMON_DIR}/env.sh"

if [ "$(conf_get daemon_enabled 1)" = "0" ]; then
  log "service: daemon disabled by config"
  exit 0
fi

if [ -f "$STATE_DIR/daemon.pid" ]; then
  _old=$(cat "$STATE_DIR/daemon.pid" 2>/dev/null | tr -d ' \n')
  if [ -n "$_old" ] && kill -0 "$_old" 2>/dev/null; then
    log "service: daemon already running pid=${_old}"
    exit 0
  fi
fi

chmod 0755 "${COMMON_DIR}/daemon.sh" "${COMMON_DIR}"/*.sh 2>/dev/null

if command -v setsid >/dev/null 2>&1; then
  setsid "${COMMON_DIR}/daemon.sh" </dev/null >/dev/null 2>&1 &
else
  "${COMMON_DIR}/daemon.sh" </dev/null >/dev/null 2>&1 &
fi

log "service: daemon launched"
exit 0
