#!/system/bin/sh
# common/conf.sh - read and write the flat config, used by the WebUI.

SELF_DIR=$(cd "$(dirname "$0")" 2>/dev/null && pwd)
[ -z "$SELF_DIR" ] && SELF_DIR="/data/adb/modules/lsposed_stealth/common"
. "$SELF_DIR/env.sh"

case "$1" in
  get)
    # Effective values, not the raw file. Right after a flash settings.conf may
    # not exist yet — migrate.sh --apply writes it at install — and the panel
    # should still show what the module is going to do instead of nothing.
    # conf_get takes the fallback as an argument, so it has to be handed the
    # table's own default rather than an empty string.
    for _pair in $CONF_DEFAULTS; do
      _k=${_pair%%=*}
      printf '%s=%s\n' "$_k" "$(conf_get "$_k" "${_pair#*=}")"
    done
    ;;
  set)
    [ -n "$2" ] || { echo "usage: conf.sh set <key> <value>" >&2; exit 1; }
    conf_set "$2" "$3"
    echo "ok"
    ;;
  # setm k=v k=v ... : several keys in one shell. The panel used to call set
  # six times, which queued six root shells behind a single button press.
  setm)
    shift
    [ $# -gt 0 ] || { echo "usage: conf.sh setm <key=value> ..." >&2; exit 1; }
    for _kv in "$@"; do
      _k=${_kv%%=*}
      _v=${_kv#*=}
      [ -n "$_k" ] || continue
      conf_set "$_k" "$_v"
    done
    echo "ok"
    ;;
  *)
    echo "usage: conf.sh get | conf.sh set <key> <value> | conf.sh setm <key=value> ..." >&2
    exit 1
    ;;
esac
