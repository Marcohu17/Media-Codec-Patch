#!/system/bin/sh
# System is fully up. Produce one report immediately so the panel is not empty
# while waiting for the first daemon tick.

case "$0" in
  */*) MODROOT=${0%/*} ;;
  *)   MODROOT="." ;;
esac
[ -d "${MODROOT}/common" ] && COMMON_DIR="${MODROOT}/common"
. "${COMMON_DIR}/env.sh"

# Move the config baseline into place first, so the audit below can already
# read its verdict instead of reporting "never run". Both switches default to
# on; setting either to 0 in the panel disables this.
if [ "$(conf_get autoconfig_enabled 1)" = "1" ] && [ "$(conf_get autoconfig_on_boot 1)" = "1" ]; then
  "${COMMON_DIR}/autoconfig.sh" >/dev/null 2>&1
  log "boot: autoconfig baseline applied"
else
  log "boot: autoconfig skipped (disabled in settings)"
fi

"${COMMON_DIR}/audit.sh" >/dev/null 2>&1
log "boot: completed, initial audit written"
