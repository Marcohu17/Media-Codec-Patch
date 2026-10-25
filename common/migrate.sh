#!/system/bin/sh
# common/migrate.sh - the config lifecycle: check it, fill it in, copy it out,
# put a copy back.
#
# Module code lives in /data/adb/modules/<id>; every setting and every piece of
# state lives in /data/adb/<id>. Flashing an update replaces the first and
# leaves the second alone, so a config survives by construction. This script
# makes that fact visible, fills in the keys a newer version adds, and leaves a
# way back when a version misbehaves.
#
# What it does not do: keep anything across an uninstall. Removal still clears
# the data directory, because leftovers under /data/adb are themselves a trace
# on a device like this one.
#
# Usage: migrate.sh --check | --apply | --snapshot | --restore [ts]

SELF_DIR=$(cd "$(dirname "$0")" 2>/dev/null && pwd)
[ -z "$SELF_DIR" ] && SELF_DIR="/data/adb/modules/lsposed_stealth/common"

# Was there a config before this run? Asked before env.sh is sourced, because
# --apply is about to create one and the answer would stop being true.
_pid=""
for _mp in "$SELF_DIR/../module.prop" "$SELF_DIR/module.prop"; do
  [ -f "$_mp" ] || continue
  _pid=$(grep -m1 '^id=' "$_mp" 2>/dev/null | sed -e 's/^id=//' -e 's/[[:space:]]*$//')
  [ -n "$_pid" ] && break
done

CFG_EXISTED=0
if [ -n "$_pid" ] && [ -f "/data/adb/${_pid}/config/settings.conf" ]; then
  CFG_EXISTED=1
fi

. "$SELF_DIR/env.sh"

BACKUP_DIR="$DATA_DIR/backup"
INSTALL_INFO="$CONF_DIR/install.info"
SCHEMA_NOW=1
BACKUP_KEEP=5

# Files worth keeping a copy of. settings.conf is the user's choices; the rest
# is what a scan produced, and restoring a config without it would leave the
# panel reporting a baseline that no longer matches the disk.
SNAP_FILES="config/settings.conf autoconfig/last.json autoconfig/baseline.snap state/upstream.conf state/hma.json"

# ---------- readers ----------
_conf_has() {
  [ -f "$CONF_FILE" ] || return 1
  grep -q "^$1=" "$CONF_FILE" 2>/dev/null
}

_conf_present_count() {
  # schema_version is bookkeeping, not a setting: counting it would make a
  # complete config read as "9 / 8" in the panel.
  _n=$(grep -v '^schema_version=' "$CONF_FILE" 2>/dev/null | grep -c '^[A-Za-z_][A-Za-z0-9_]*=')
  case "$_n" in ''|*[!0-9]*) _n=0 ;; esac
  printf '%s' "$_n"
}

_keys_total() {
  conf_keys | awk 'END { print NR }'
}

_missing_keys() {
  _out=""
  for _k in $(conf_keys); do
    _conf_has "$_k" || _out="$_out $_k"
  done
  printf '%s' "$_out"
}

# Keys on disk that this version no longer defines. Not an error: an older
# version may have written something since dropped. Reported so a stale entry
# can be explained instead of silently outliving its setting.
_extra_keys() {
  _out=""
  [ -f "$CONF_FILE" ] || { printf ''; return; }
  for _k in $(grep '^[A-Za-z_][A-Za-z0-9_]*=' "$CONF_FILE" 2>/dev/null | sed -e 's/=.*//' | sort -u); do
    [ "$_k" = "schema_version" ] && continue
    _known=0
    for _dk in $(conf_keys); do
      [ "$_k" = "$_dk" ] && { _known=1; break; }
    done
    [ "$_known" = "0" ] && _out="$_out $_k"
  done
  printf '%s' "$_out"
}

_mod_prop() {
  for _mp in "$COMMON_DIR/../module.prop" "$COMMON_DIR/module.prop"; do
    [ -f "$_mp" ] || continue
    _val=$(grep -m1 "^$1=" "$_mp" 2>/dev/null | sed -e "s/^$1=//" -e 's/[[:space:]]*$//')
    [ -n "$_val" ] && { printf '%s' "$_val"; return 0; }
  done
  printf ''
}

_info_get() {
  [ -f "$INSTALL_INFO" ] || { printf ''; return; }
  grep -m1 "^$1=" "$INSTALL_INFO" 2>/dev/null | sed -e "s/^$1=//"
}

_count_dirs() {
  [ -d "$1" ] || { printf '0'; return; }
  ls -1 "$1" 2>/dev/null | awk 'END { print NR }'
}

_newest_dir() {
  [ -d "$1" ] || { printf ''; return; }
  ls -1 "$1" 2>/dev/null | sort | awk 'END { print }'
}

# ---------- json ----------
# Space-separated list to a JSON array of escaped strings.
_jarr() {
  _o=""
  for _v in $1; do
    _e=$(printf '%s' "$_v" | json_escape)
    _o="${_o}${_o:+,}\"${_e}\""
  done
  printf '[%s]' "$_o"
}

_jstr() { printf '%s' "$1" | json_escape; }

_jbool() { if [ "$1" = "1" ]; then printf 'true'; else printf 'false'; fi; }

# ---------- apply ----------
# Adds every key the table declares and the file lacks. Values already on disk
# are never touched, so a user's daemon_interval stays exactly what they set.
APPLIED_ADDED=""
INSTALL_RECORDED=0

_apply_keys() {
  APPLIED_ADDED=""
  mkdir -p "$CONF_DIR" 2>/dev/null || return 1

  if [ ! -f "$CONF_FILE" ]; then
    printf '%s\n' "$CONF_DEFAULTS" > "$CONF_FILE" 2>/dev/null || return 1
    # Writing the file counts as work done. Reporting "0 added" for a first
    # install would claim nothing happened right after writing eight keys.
    APPLIED_ADDED=""
    for _k in $(conf_keys); do
      APPLIED_ADDED="$APPLIED_ADDED $_k"
    done
  fi

  # Every default is a single token (key=value, no spaces), which is what makes
  # the unquoted split below safe. A default with a space would need a different
  # loop; keep the table free of them.
  for _kv in $CONF_DEFAULTS; do
    _k=${_kv%%=*}
    _conf_has "$_k" && continue
    printf '%s\n' "$_kv" >> "$CONF_FILE" 2>/dev/null || return 1
    APPLIED_ADDED="$APPLIED_ADDED $_k"
  done

  _cur=$(conf_get schema_version 0)
  if [ "$_cur" != "$SCHEMA_NOW" ]; then
    conf_set schema_version "$SCHEMA_NOW" || return 1
  fi

  # installed_at answers "when did this version land", not "when did the device
  # boot". --apply also runs at boot, so the record is only rewritten when the
  # stored version differs from the one on disk.
  _ver=$(_mod_prop version)
  _rec=$(_info_get version)
  INSTALL_RECORDED=0
  if [ "$_rec" != "$_ver" ] || [ ! -f "$INSTALL_INFO" ]; then
    {
      echo "version=$_ver"
      echo "versionCode=$(_mod_prop versionCode)"
      echo "installed_at=$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null)"
      echo "schema=$SCHEMA_NOW"
    } > "${INSTALL_INFO}.tmp" 2>/dev/null && mv -f "${INSTALL_INFO}.tmp" "$INSTALL_INFO" 2>/dev/null
    INSTALL_RECORDED=1
  fi

  return 0
}

do_apply() {
  if ! _apply_keys; then
    printf '{"mode":"apply","ok":false,"reason":"%s"}\n' "$(_jstr '配置目录写不进去')"
    return
  fi

  _total=$(_keys_total)
  if [ -n "$APPLIED_ADDED" ]; then
    _added_n=$(printf '%s' "$APPLIED_ADDED" | awk '{ print NF }')
  else
    _added_n=0
  fi

  printf '{"mode":"apply","ok":true,"created":%s,"added":%s,"added_count":%s,"keys_total":%s,"keys_present":%s,"schema":%s,"install_recorded":%s,"version":"%s"}\n' \
    "$(_jbool "$([ "$CFG_EXISTED" = "0" ] && echo 1 || echo 0)")" \
    "$(_jarr "$APPLIED_ADDED")" \
    "$_added_n" \
    "$_total" \
    "$(_conf_present_count)" \
    "$SCHEMA_NOW" \
    "$(_jbool "$INSTALL_RECORDED")" \
    "$(_jstr "$(_mod_prop version)")"
}

# ---------- check ----------
do_check() {
  _missing=$(_missing_keys)
  _extra=$(_extra_keys)
  _total=$(_keys_total)
  _present=$(_conf_present_count)

  if [ "$CFG_EXISTED" = "0" ]; then
    _state="fresh"
  elif [ -n "$_missing" ]; then
    _state="missing_keys"
  else
    _state="current"
  fi

  _schema=$(conf_get schema_version 0)
  case "$_schema" in ''|*[!0-9]*) _schema=0 ;; esac

  printf '{"mode":"check","config_existed":%s,"state":"%s","keys_total":%s,"keys_present":%s,"missing":%s,"extra":%s,"schema":%s,"schema_expected":%s,"backups":%s,"last_backup":"%s","installed_version":"%s","installed_at":"%s","module_version":"%s","module_code":"%s"}\n' \
    "$(_jbool "$CFG_EXISTED")" \
    "$_state" \
    "$_total" \
    "$_present" \
    "$(_jarr "$_missing")" \
    "$(_jarr "$_extra")" \
    "$_schema" \
    "$SCHEMA_NOW" \
    "$(_count_dirs "$BACKUP_DIR")" \
    "$(_jstr "$(_newest_dir "$BACKUP_DIR")")" \
    "$(_jstr "$(_info_get version)")" \
    "$(_jstr "$(_info_get installed_at)")" \
    "$(_jstr "$(_mod_prop version)")" \
    "$(_jstr "$(_mod_prop versionCode)")"
}

# ---------- snapshot ----------
SNAP_DIR=""
SNAP_COPIED=""
SNAP_SKIPPED=""

_take_snapshot() {
  # Every variable here is prefixed on purpose. This function is called from
  # inside do_restore, and an unprefixed name would overwrite the caller's
  # locals — which is exactly how restore ended up reading the backup it had
  # just taken instead of the one it was asked for.
  _snap_label="${1:-manual}"
  SNAP_DIR=""; SNAP_COPIED=""; SNAP_SKIPPED=""

  mkdir -p "$BACKUP_DIR" 2>/dev/null || return 1

  _snap_ts=$(date '+%Y%m%d-%H%M%S' 2>/dev/null)
  case "$_snap_ts" in ''|*[!0-9-]*) _snap_ts="snapshot" ;; esac

  # Two snapshots inside one second must not land in the same directory: the
  # second is usually the pre-restore copy, which is the one you would need.
  _snap_dir="$BACKUP_DIR/$_snap_ts"
  _snap_n=1
  while [ -d "$_snap_dir" ] && [ "$_snap_n" -le 20 ]; do
    _snap_dir="$BACKUP_DIR/${_snap_ts}-$_snap_n"
    _snap_n=$((_snap_n + 1))
  done

  mkdir -p "$_snap_dir" 2>/dev/null || return 1

  for _snap_rel in $SNAP_FILES; do
    _snap_src="$DATA_DIR/$_snap_rel"
    if [ ! -f "$_snap_src" ]; then
      SNAP_SKIPPED="$SNAP_SKIPPED $_snap_rel"
      continue
    fi
    _snap_dst="$_snap_dir/$_snap_rel"
    mkdir -p "${_snap_dst%/*}" 2>/dev/null
    if cp -f "$_snap_src" "$_snap_dst" 2>/dev/null; then
      SNAP_COPIED="$SNAP_COPIED $_snap_rel"
    else
      SNAP_SKIPPED="$SNAP_SKIPPED $_snap_rel"
    fi
  done

  # Copying nothing is not a snapshot. Remove the empty directory rather than
  # leaving it to be counted, and shown, as a restore point that holds nothing.
  if [ -z "$SNAP_COPIED" ]; then
    rm -rf "$_snap_dir" 2>/dev/null
    return 1
  fi

  {
    echo "label=$_snap_label"
    echo "taken_at=$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null)"
    echo "version=$(_mod_prop version)"
    echo "schema=$SCHEMA_NOW"
    echo "files=$(printf '%s' "$SNAP_COPIED" | sed -e 's/^ //')"
  } > "$_snap_dir/meta.txt" 2>/dev/null

  SNAP_DIR="$_snap_dir"
  return 0
}

# Keeps the newest BACKUP_KEEP directories. Names are timestamps, so a plain
# sort is chronological and the oldest are the ones at the top.
_prune_snapshots() {
  [ -d "$BACKUP_DIR" ] || { printf '0'; return; }
  _cnt=$(_count_dirs "$BACKUP_DIR")
  _drop=$((_cnt - BACKUP_KEEP))
  [ "$_drop" -le 0 ] && { printf '0'; return; }
  ls -1 "$BACKUP_DIR" 2>/dev/null | sort | head -n "$_drop" | while IFS= read -r _d; do
    [ -n "$_d" ] || continue
    rm -rf "$BACKUP_DIR/$_d" 2>/dev/null
  done
  printf '%s' "$_drop"
}

do_snapshot() {
  if ! _take_snapshot "${1:-manual}"; then
    printf '{"mode":"snapshot","ok":false,"reason":"%s"}\n' \
      "$(_jstr '没有可备份的文件')"
    return
  fi

  _pruned=$(_prune_snapshots)
  _kept=$(_count_dirs "$BACKUP_DIR")

  printf '{"mode":"snapshot","ok":true,"dir":"%s","name":"%s","copied":%s,"copied_count":%s,"skipped":%s,"kept":%s,"pruned":%s}\n' \
    "$(_jstr "$SNAP_DIR")" \
    "$(_jstr "${SNAP_DIR##*/}")" \
    "$(_jarr "$SNAP_COPIED")" \
    "$(printf '%s' "$SNAP_COPIED" | awk '{ print NF }')" \
    "$(_jarr "$SNAP_SKIPPED")" \
    "$_kept" \
    "$_pruned"
}

# ---------- restore ----------
do_restore() {
  _want="$1"

  if [ -z "$_want" ]; then
    _want=$(_newest_dir "$BACKUP_DIR")
  fi

  if [ -z "$_want" ]; then
    printf '{"mode":"restore","ok":false,"reason":"%s"}\n' "$(_jstr '还没有任何快照')"
    return
  fi

  _srcdir="$BACKUP_DIR/$_want"
  if [ ! -d "$_srcdir" ]; then
    printf '{"mode":"restore","ok":false,"reason":"%s"}\n' "$(_jstr "找不到这份快照：$_want")"
    return
  fi

  # Snapshot the present before overwriting it. Restoring is a destructive
  # action, and the only thing that makes it safe is that the state being
  # replaced is also on disk afterwards.
  _pre=""
  if _take_snapshot "pre-restore"; then
    _pre=$SNAP_DIR
    _prune_snapshots >/dev/null
  fi

  _restored=""; _skipped=""; _failed=""
  for _rel in $SNAP_FILES; do
    _src="$_srcdir/$_rel"
    if [ ! -f "$_src" ]; then
      _skipped="$_skipped $_rel"
      continue
    fi
    _dst="$DATA_DIR/$_rel"
    mkdir -p "${_dst%/*}" 2>/dev/null
    if cp -f "$_src" "$_dst" 2>/dev/null; then
      _restored="$_restored $_rel"
    else
      _failed="$_failed $_rel"
    fi
  done

  if [ -z "$_restored" ]; then
    printf '{"mode":"restore","ok":false,"name":"%s","pre_snapshot":"%s","reason":"%s"}\n' \
      "$(_jstr "$_want")" \
      "$(_jstr "$_pre")" \
      "$(_jstr '这份快照里没有能写回的文件')"
    return
  fi

  # A snapshot taken by an older version will not carry the keys this one needs.
  # Backfill after writing, and say which ones were added, so the restored file
  # is not silently half-complete.
  _added=""
  if _apply_keys; then
    _added="$APPLIED_ADDED"
  fi

  printf '{"mode":"restore","ok":true,"name":"%s","dir":"%s","restored":%s,"restored_count":%s,"skipped":%s,"failed":%s,"backfilled":%s,"pre_snapshot":"%s"}\n' \
    "$(_jstr "$_want")" \
    "$(_jstr "$_srcdir")" \
    "$(_jarr "$_restored")" \
    "$(printf '%s' "$_restored" | awk '{ print NF }')" \
    "$(_jarr "$_skipped")" \
    "$(_jarr "$_failed")" \
    "$(_jarr "$_added")" \
    "$(_jstr "$_pre")"
}

usage() {
  echo "usage: migrate.sh --check | --apply | --snapshot | --restore [ts]" >&2
}

case "$1" in
  --check)    do_check ;;
  --apply)    do_apply ;;
  --snapshot) do_snapshot "${2:-manual}" ;;
  --restore)  do_restore "$2" ;;
  *)          usage; exit 1 ;;
esac
