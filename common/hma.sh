#!/system/bin/sh
# common/hma.sh - read-only probe of the HMA config store
#
# This script OPENS NOTHING FOR WRITING. There is no chmod, no mv, no redirect
# into any path below HMA's own directories. Reading another app's private
# storage is what an auditor does; changing it is what this module refuses to
# do, because HMA rewrites its own state on exit and a foreign write would be
# both overwritten and, in the window before that, corrupting.
#
# What it answers:
#   - where HMA keeps its state on this device
#   - what files exist there, how big, and what the first bytes look like
#   - whether HMA holds any hidden-app rule at all, read from the three files
#     that decide that: the template maps, the per-app filter counters, and
#     the run mode
#   - which registry the package list came from, so an empty result can be
#     told apart from an unloaded registry
#
# What it does NOT answer:
#   - whether HMA is actually hiding anything from the target at runtime
#   - which template is bound to which app, unless the bytes say so plainly
#
# Usage: hma.sh [probe]

SELF_DIR=$(cd "$(dirname "$0")" 2>/dev/null && pwd)
[ -z "$SELF_DIR" ] && SELF_DIR="/data/adb/modules/lsposed_stealth/common"
. "$SELF_DIR/env.sh"
. "$SELF_DIR/targets.sh"

HMA_JSON="$STATE_DIR/hma.json"

_MAX_HEAD=360          # bytes of each file kept for the report
_MAX_FILES=40          # files listed per directory
_MAX_GREP_FILES=20     # config files actually searched for package names
_MAX_GREP_BYTES=2097152

# ---------- discovery ----------
# The state dir name carries a random suffix, so it can only be found by glob.
# A pattern that matches nothing stays literal, which is why every hit is
# checked with -d before being trusted.
_hma_dirs() {
  _seen=" "
  for _hd in /data/misc/hide_my_applist_* \
             /data/data/*hidemyapplist* /data/user/0/*hidemyapplist* \
             /data/data/*HideMyApplist* /data/user/0/*HideMyApplist*; do
    [ -d "$_hd" ] || continue
    case "$_seen" in *" $_hd "*) continue ;; esac
    _seen="$_seen$_hd "
    printf '%s\n' "$_hd"
  done
}

# find without -maxdepth: toybox has it, but an unsupported flag would silently
# produce an empty listing and read as "no files here", which is a lie. head
# closing the pipe is enough of a bound.
_hma_files() {
  find "$1" -type f 2>/dev/null | head -n "$_MAX_FILES"
}

_file_size() {
  _fs=$(stat -c %s "$1" 2>/dev/null)
  case "$_fs" in
    ''|*[!0-9]*) return 1 ;;
  esac
  printf '%s' "$_fs"
}

# Strip C0 control bytes but keep newline and UTF-8 sequences, so a Chinese
# label inside the config survives into the report.
_printable_head() {
  head -c "$_MAX_HEAD" "$1" 2>/dev/null | tr -d '\000-\010\013\014\016-\037'
}

# HMA writes its config, its logs and a memory dump into the same directory.
# The dump alone can run to several hundred kilobytes, and searching it for a
# package name says nothing about the configuration while costing the most
# time in the whole probe. Only files that can carry a rule are searched.
_is_config_file() {
  case "${1##*/}" in
    *.log|*.txt|*.dat|*.bin|*.tmp|*.bak) return 1 ;;
  esac
  return 0
}

_count_hits() {
  # -a: treat the file as text, because a binary store would otherwise print
  # "binary file matches" and wc would count lines that are not hits.
  grep -a -o -F -e "$1" "$2" 2>/dev/null | wc -l | tr -d ' '
}

_target_pkgs() {
  targets_list | while IFS= read -r _tl; do
    _tp=${_tl%%|*}
    [ -n "$_tp" ] && printf '%s\n' "$_tp"
  done
}

# Top-level key of an object, as one of empty / has_entries / missing. The
# inner scan stops at the first closing brace: that is enough to tell an empty
# object from a populated one without pretending to be a JSON parser.
_obj_state() {
  _os_k="$2"
  [ -f "$1" ] || { printf 'missing'; return 0; }
  grep -q "\"${_os_k}\":" "$1" 2>/dev/null || { printf 'missing'; return 0; }
  _os_in=$(sed -n "s/.*\"${_os_k}\":{\([^}]*\)}.*/\1/p" "$1" 2>/dev/null | head -n1)
  if [ -n "$_os_in" ]; then
    printf 'has_entries'
  else
    printf 'empty'
  fi
}

_obj_inner() {
  _oi_k="$2"
  [ -f "$1" ] || return 0
  sed -n "s/.*\"${_oi_k}\":{\([^}]*\)}.*/\1/p" "$1" 2>/dev/null | head -n1
}

# ---------- main ----------
main_probe() {
  _ts=$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null)
  [ -z "$_ts" ] && _ts="?"

  # targets.sh is loaded by sourcing it. When that source fails the function
  # simply does not exist, every lookup below yields nothing, and the report
  # reads exactly like "HMA has no rule for this app". The fallback keeps the
  # probe useful; the two recorded fields make the difference visible instead
  # of guessed at on the next run.
  if command -v targets_list >/dev/null 2>&1; then
    _tl_defined=true
  else
    _tl_defined=false
  fi

  _tlen=0
  [ -n "$TARGETS" ] && _tlen=${#TARGETS}

  _pkgs=$(_target_pkgs)
  if [ -z "$_pkgs" ]; then
    _pkgs="com.tencent.mm com.tencent.mobileqq"
    _pkgs_src="fallback"
  else
    _pkgs_src="targets.sh"
  fi

  _dirs_json=""
  _n_dirs=0
  _n_files=0
  _n_grep=0
  _unreadable=0
  _hit_mm=0
  _hit_qq=0

  _cfg_ver=""
  _wm=""
  _tpl_state="missing"
  _stpl_state="missing"
  _filter_state="missing"
  _filter_inner=""

  _all=$(_hma_dirs)
  while IFS= read -r _d; do
    [ -n "$_d" ] || continue
    [ -d "$_d" ] || continue

    _n_dirs=$((_n_dirs + 1))
    [ -r "$_d" ] || _unreadable=$((_unreadable + 1))

    _entries=$(ls -1 "$_d" 2>/dev/null | wc -l | tr -d ' ')
    case "$_entries" in ''|*[!0-9]*) _entries=0 ;; esac

    # Read by name, not by glob. These three decide what HMA is doing; the
    # logs beside them do not, whatever package names they happen to contain.
    if [ "$_tpl_state" = "missing" ] && [ -f "$_d/config.json" ]; then
      _cfg_ver=$(sed -n 's/.*"configVersion":\([0-9][0-9]*\).*/\1/p' "$_d/config.json" 2>/dev/null | head -n1)
      _tpl_state=$(_obj_state "$_d/config.json" templates)
      _stpl_state=$(_obj_state "$_d/config.json" settingsTemplates)
    fi

    if [ "$_filter_state" = "missing" ] && [ -f "$_d/filter_count.json" ]; then
      _filter_state=$(_obj_state "$_d/filter_count.json" filterCounts)
      _filter_inner=$(_obj_inner "$_d/filter_count.json" filterCounts)
    fi

    if [ -z "$_wm" ] && [ -f "$_d/status.json" ]; then
      _wm=$(sed -n 's/.*"workMode":\([0-9][0-9]*\).*/\1/p' "$_d/status.json" 2>/dev/null | head -n1)
    fi

    _files_json=""
    _fl=$(_hma_files "$_d")
    while IFS= read -r _f; do
      [ -n "$_f" ] || continue
      [ -f "$_f" ] || continue

      _n_files=$((_n_files + 1))

      _sz=$(_file_size "$_f" 2>/dev/null)
      [ -n "$_sz" ] || _sz=-1

      _hh=""
      if [ "$_sz" -ge 0 ] && [ "$_sz" -le "$_MAX_GREP_BYTES" ]; then
        _hh=$(_printable_head "$_f")
      fi

      _hits_json=""
      if [ "$_n_grep" -lt "$_MAX_GREP_FILES" ] && [ "$_sz" -ge 0 ] && _is_config_file "$_f"; then
        _n_grep=$((_n_grep + 1))
        for _pk in $_pkgs; do
          _hc=$(_count_hits "$_pk" "$_f")
          case "$_hc" in ''|*[!0-9]*) _hc=0 ;; esac
          case "$_pk" in
            com.tencent.mm)       _hit_mm=$((_hit_mm + _hc)) ;;
            com.tencent.mobileqq) _hit_qq=$((_hit_qq + _hc)) ;;
          esac
          [ -n "$_hits_json" ] && _hits_json="$_hits_json,"
          _hits_json="${_hits_json}\"${_pk}\":${_hc}"
        done
      fi

      _fn=$(basename "$_f" 2>/dev/null)
      _fn_e=$(printf '%s' "$_fn" | json_escape)
      _fp_e=$(printf '%s' "$_f"  | json_escape)
      _hh_e=$(printf '%s' "$_hh" | json_escape)

      [ -n "$_files_json" ] && _files_json="$_files_json,"
      _files_json="${_files_json}{\"name\":\"${_fn_e}\",\"path\":\"${_fp_e}\",\"size\":${_sz},\"head\":\"${_hh_e}\",\"hits\":{${_hits_json}}}"
    done <<EOF
$_fl
EOF

    _de=$(printf '%s' "$_d" | json_escape)
    [ -n "$_dirs_json" ] && _dirs_json="$_dirs_json,"
    _dirs_json="${_dirs_json}{\"path\":\"${_de}\",\"entries\":${_entries},\"files\":[${_files_json}]}"
  done <<EOF
$_all
EOF

  _tg_json=""
  for _pk in $_pkgs; do
    _hv=0
    case "$_pk" in
      com.tencent.mm)       _hv=$_hit_mm ;;
      com.tencent.mobileqq) _hv=$_hit_qq ;;
    esac
    [ -n "$_tg_json" ] && _tg_json="$_tg_json,"
    _tg_json="${_tg_json}\"${_pk}\":${_hv}"
  done

  # The verdict is about configuration, not about grep counts. A store with no
  # template map and no filter counter holds no rule; that is a fact and gets
  # its own word, rather than being folded into "unknown" alongside every
  # genuine failure to read the store.
  if [ "$_n_dirs" -eq 0 ]; then
    _found=false
    _verdict="unknown"
    _note="没有找到 HMA 的状态目录。要么设备上没装 HMA，要么它的存储位置不在这几条已知路径里。探不到不等于没有，这一项按未确认处理。"
  elif [ "$_n_files" -eq 0 ]; then
    _found=true
    _verdict="unknown"
    _note="找到了 HMA 的目录，但里面没有可读的文件。可能是权限不够，也可能配置还没生成过。"
  elif [ "$_filter_state" = "has_entries" ]; then
    _found=true
    _verdict="configured"
    _note="HMA 的过滤计数里已有条目，说明至少有一条隐藏规则在生效。计数对应哪个应用，要看下面的内容。"
  elif [ "$_filter_state" = "empty" ] && [ "$_tpl_state" = "empty" ]; then
    _found=true
    _verdict="empty"
    _note="HMA 在运行，但隐藏模板和过滤计数都是空的，说明还没有配置任何规则。这不是探测失败，是它确实还没被配置过。"
  else
    _found=true
    _verdict="unknown"
    _note="只读探测完成。命中次数只说明包名在这个存储里出现过，不代表 HMA 当前对它启用了隐藏。"
  fi
  _note_e=$(printf '%s' "$_note" | json_escape)
  _filter_e=$(printf '%s' "$_filter_inner" | json_escape)

  _json="{\"generated_at\":\"${_ts}\",\"found\":${_found},\"verdict\":\"${_verdict}\",\"dirs\":[${_dirs_json}],\"targets\":{${_tg_json}},\"targets_source\":\"${_pkgs_src}\",\"targets_list_defined\":${_tl_defined},\"targets_registry_length\":${_tlen},\"templates_state\":\"${_tpl_state}\",\"settings_templates_state\":\"${_stpl_state}\",\"filter_counts_state\":\"${_filter_state}\",\"filter_count_entries\":\"${_filter_e}\",\"config_version\":\"${_cfg_ver}\",\"work_mode\":\"${_wm}\",\"files_scanned\":${_n_files},\"unreadable_dirs\":${_unreadable},\"note\":\"${_note_e}\"}"

  mkdir -p "$STATE_DIR" 2>/dev/null
  printf '%s' "$_json" > "$HMA_JSON" 2>/dev/null
  printf '%s' "$_json"
}

case "${1:-probe}" in
  probe|"") main_probe ;;
  *) echo "usage: hma.sh [probe]" >&2; exit 1 ;;
esac
