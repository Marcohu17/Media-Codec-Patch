#!/system/bin/sh
# common/scrub.sh - quarantine-style cleanup
#
# Nothing is deleted on the first pass. Every target is moved into
# $QUAR_DIR/<timestamp>/ and recorded in a manifest, so a restore is always
# possible. Only entries older than scrub_keep_days are reclaimed.

SELF_DIR=$(cd "$(dirname "$0")" 2>/dev/null && pwd)
[ -z "$SELF_DIR" ] && SELF_DIR="/data/adb/modules/lsposed_stealth/common"
. "$SELF_DIR/env.sh"

DRY=0
case "$1" in
  --dry-run) DRY=1 ;;
  --restore) SHIFT_TARGET="$2" ;;
esac

_stamp() { date '+%Y%m%d-%H%M%S' 2>/dev/null; }

# ---------- move helper ----------
_QDIR=""
_MANIFEST=""

_qinit() {
  _QDIR="$QUAR_DIR/$1"
  _MANIFEST="$QDIR/manifest.txt"
  if [ "$DRY" = "1" ]; then
    return 0
  fi
  mkdir -p "$_QDIR" 2>/dev/null
  : > "$_MANIFEST"
}

# qmove <path> <bucket>
qmove() {
  _src="$1"; _bucket="$2"; _name="$3"

  if [ ! -e "$_src" ]; then
    return 1
  fi

  if [ "$DRY" = "1" ]; then
    echo "[dry-run] would move ${_src}"
    return 0
  fi

  mkdir -p "${_QDIR}/${_bucket}" 2>/dev/null
  _dst="${_QDIR}/${_bucket}/${_name}"

  # avoid clobbering when two sources share a basename
  if [ -e "$_dst" ]; then
    _dst="${_dst}.$$"
  fi

  if mv "$_src" "$_dst" 2>/dev/null; then
    printf '%s|%s\n' "$_src" "$_dst" >> "$_MANIFEST"
    echo "moved ${_src}"
    return 0
  fi
  return 1
}

# ---------- individual buckets ----------
_scrub_lspd_log() {
  for _d in /data/adb/lspd/log /data/adb/lspd/log_old; do
    [ -d "$_d" ] || continue
    for _f in "$_d"/*; do
      [ -f "$_f" ] || continue
      qmove "$_f" "lspd_log" "$(basename "$_f")" >/dev/null
    done
  done
}

_scrub_dropbox() {
  [ -d /data/system/dropbox ] || return 0
  # Filename-level match only. Reading every record body would be slow and is
  # not worth it for what this bucket is meant to catch.
  for _pat in '*lspd*' '*LSPosed*' '*zygisk*' '*Zygisk*' '*kernelsu*' '*KernelSU*'; do
    for _f in /data/system/dropbox/$_pat; do
      [ -f "$_f" ] || continue
      qmove "$_f" "dropbox" "$(basename "$_f")" >/dev/null
    done
  done
}

_scrub_localtmp() {
  [ -d /data/local/tmp ] || return 0
  for _pat in '*lsposed*' '*LSPosed*' '*zygisk*' '*Zygisk*' '*ksu*' '*KernelSU*' '*magisk*' '*Magisk*'; do
    for _f in /data/local/tmp/$_pat; do
      [ -e "$_f" ] || continue
      # never touch an active module install directory mid-flash
      case "$_f" in */modules_update) continue ;; esac
      qmove "$_f" "local_tmp" "$(basename "$_f")" >/dev/null
    done
  done
}

_scrub_manager_cache() {
  for _d in /data/data/org.lsposed.manager/cache /data/user_de/0/org.lsposed.manager/cache; do
    [ -d "$_d" ] || continue
    for _f in "$_d"/*; do
      [ -e "$_f" ] || continue
      qmove "$_f" "manager_cache" "$(basename "$_f")" >/dev/null
    done
  done
}

# ---------- retention ----------
scrub_gc() {
  _days=$(conf_get scrub_keep_days 7)
  case "$_days" in ''|*[!0-9]*) _days=7 ;; esac
  [ "$DRY" = "1" ] && { echo "[dry-run] would reclaim quarantine older than ${_days} days"; return 0; }

  _n=0
  for _d in "$QUAR_DIR"/*; do
    [ -d "$_d" ] || continue
    case "$(basename "$_d")" in
      *[!0-9-]*) continue ;;
    esac
    if find "$_d" -maxdepth 0 -mtime +"$_days" >/dev/null 2>&1; then
      if [ -z "$(find "$_d" -maxdepth 0 -mtime -"$_days" 2>/dev/null)" ]; then
        rm -rf "$_d" 2>/dev/null && _n=$((_n + 1))
      fi
    fi
  done
  echo "reclaimed ${_n} expired quarantine batch(es)"
}

# ---------- restore ----------
scrub_restore() {
  _batch="$1"

  if [ -z "$_batch" ]; then
    # newest batch by name
    _batch=$(ls -1 "$QUAR_DIR" 2>/dev/null | grep -E '^[0-9]{8}-[0-9]{6}$' | sort | tail -n 1)
  fi

  if [ -z "$_batch" ]; then
    echo "no quarantine batch found"
    return 1
  fi

  _m="$QUAR_DIR/$_batch/manifest.txt"
  if [ ! -f "$_m" ]; then
    echo "manifest missing for batch ${_batch}"
    return 1
  fi

  _n=0
  # reverse order so nested paths come back the way they left
  tac "$_m" 2>/dev/null | while IFS='|' read -r _src _dst; do
    [ -n "$_src" ] || continue
    [ -e "$_dst" ] || continue
    mkdir -p "$(dirname "$_src")" 2>/dev/null
    if mv "$_dst" "$_src" 2>/dev/null; then
      echo "restored ${_src}"
    fi
  done

  echo "restore of ${_batch} requested"
}

# ---------- main ----------
scrub_main() {
  if [ "$SCRUB_ENABLED" = "0" ]; then
    echo "scrub disabled by config"
    return 0
  fi

  _s=$(_stamp)
  [ -z "$_s" ] && _s="batch-$$"
  _qinit "$_s"

  _scrub_lspd_log
  _scrub_dropbox
  _scrub_localtmp
  _scrub_manager_cache
  scrub_gc

  if [ "$DRY" = "1" ]; then
    echo "dry run complete, nothing changed"
    return 0
  fi

  _cnt=$(wc -l < "$_MANIFEST" 2>/dev/null | tr -d ' ')
  [ -z "$_cnt" ] && _cnt=0

  if [ "$_cnt" = "0" ]; then
    # nothing was moved, drop the empty batch so the UI stays readable
    rm -rf "$_QDIR" 2>/dev/null
    echo "nothing to clean"
  else
    echo "quarantined ${_cnt} item(s) into ${_QDIR}"
  fi

  log_scrub "scrub batch=${_s} moved=${_cnt} dry=${DRY}"
}

SCRUB_ENABLED=$(conf_get scrub_enabled 1)

case "$1" in
  --restore) scrub_restore "$2" ;;
  --gc)      scrub_gc ;;
  *)         scrub_main ;;
esac
