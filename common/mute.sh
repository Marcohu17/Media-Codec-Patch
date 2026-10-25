#!/system/bin/sh
# common/mute.sh - LSPosed log suppression
#
# gentle      : truncate log files once the directory grows past a threshold.
# aggressive  : try to make the log directory immutable so writes fail.
#               Not every Android filesystem supports chattr, so the fallback
#               is reported instead of silently pretending it worked.

SELF_DIR=$(cd "$(dirname "$0")" 2>/dev/null && pwd)
[ -z "$SELF_DIR" ] && SELF_DIR="/data/adb/modules/lsposed_stealth/common"
. "$SELF_DIR/env.sh"

LSPD_LOG_DIRS="/data/adb/lspd/log /data/adb/lspd/log_old"

_dir_size_kb() {
  _d="$1"
  [ -d "$_d" ] || { echo 0; return; }
  _sum=0
  for _f in "$_d"/*; do
    [ -f "$_f" ] || continue
    _sz=$(stat -c %s "$_f" 2>/dev/null)
    case "$_sz" in ''|*[!0-9]*) _sz=0 ;; esac
    _sum=$((_sum + _sz))
  done
  echo $((_sum / 1024))
}

# ---------- gentle ----------
mute_gentle() {
  _limit=$(conf_get mute_size_kb 256)
  case "$_limit" in ''|*[!0-9]*) _limit=256 ;; esac

  _changed=0
  for _d in $LSPD_LOG_DIRS; do
    [ -d "$_d" ] || continue
    _kb=$(_dir_size_kb "$_d")
    if [ "$_kb" -le "$_limit" ]; then
      continue
    fi

    # oldest first, truncate in place so open file handles stay valid
    ls -1t "$_d" 2>/dev/null | tail -n +2 | while read -r _name; do
      [ -n "$_name" ] || continue
      [ -f "$_d/$_name" ] || continue
      : > "$_d/$_name" 2>/dev/null
    done
    _changed=1
    log_mute "gentle: truncated ${_d} (was ${_kb}KB, limit ${_limit}KB)"
  done

  if [ "$_changed" = "0" ]; then
    log_mute "gentle: all log dirs under ${_limit}KB, nothing to truncate"
  fi
  echo "gentle mode applied (limit ${_limit}KB)"
}

# ---------- aggressive ----------
mute_aggressive() {
  _applied=0
  _failed=""

  for _d in $LSPD_LOG_DIRS; do
    [ -d "$_d" ] || continue
    if chattr +i "$_d" 2>/dev/null; then
      _applied=$((_applied + 1))
      log_mute "aggressive: chattr +i applied to ${_d}"
    else
      _failed="${_failed} ${_d}"
      log_mute "aggressive: chattr +i unsupported on ${_d}, falling back"
    fi
  done

  if [ "$_applied" = "0" ]; then
    mute_gentle
    log_mute "aggressive: not supported on this filesystem, degraded to gentle"
    echo "aggressive not supported here, degraded to gentle mode"
    return 0
  fi

  echo "aggressive mode applied on ${_applied} dir(s)"
  [ -n "$_failed" ] && echo "not applied on:${_failed}"
}

# ---------- release ----------
mute_release() {
  _n=0
  for _d in $LSPD_LOG_DIRS; do
    [ -d "$_d" ] || continue
    if chattr -i "$_d" 2>/dev/null; then
      _n=$((_n + 1))
    fi
  done
  log_mute "release: cleared immutable flag on ${_n} dir(s)"
  echo "released ${_n} dir(s)"
}

_mode=$(conf_get mute_mode gentle)
case "$1" in
  --release) mute_release ;;
  --gentle)  mute_gentle ;;
  --aggressive) mute_aggressive ;;
  *)
    case "$_mode" in
      aggressive) mute_aggressive ;;
      off)        echo "mute disabled" ;;
      *)          mute_gentle ;;
    esac
    ;;
esac
