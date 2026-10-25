#!/system/bin/sh
# common/upstream.sh - fetch upstream facts from the KernelSU source tree
#
# Contract:
#   - Only runs when the user asks. Nothing here is scheduled, and nothing
#     here runs during boot. A hiding module that beacons on a timer emits
#     exactly the traffic pattern it is trying to suppress.
#   - Requests only go to public GitHub mirrors named in known.json.
#   - No device identifier, no device state, no query string is sent.
#   - When the network is unavailable the failure is written down as a
#     failure. The packaged baseline keeps working; nothing else changes.

SELF_DIR=$(cd "$(dirname "$0")" 2>/dev/null && pwd)
[ -z "$SELF_DIR" ] && SELF_DIR="/data/adb/modules/lsposed_stealth/common"
. "$SELF_DIR/env.sh"

FETCH_TIMEOUT=8

# Scratch space lives under the module data dir rather than /tmp: it is known
# writable at this point, and it avoids handing a path to curl that the binary
# and the shell might resolve differently.
TMPD="$DATA_DIR/upstream.$(date +%s)"
mkdir -p "$TMPD" 2>/dev/null

MIRRORS=""
FILES=""

load_known() {
  [ -f "$KNOWN_JSON" ] || return 1
  MIRRORS=$(sed -n '/"mirrors"/,/]/p' "$KNOWN_JSON" 2>/dev/null | grep 'https' | awk -F'"' '{ print $2 }')
  FILES=$(sed -n '/"upstream"/,/}/p' "$KNOWN_JSON" 2>/dev/null | grep 'userspace/' | awk -F'"' '{ print $2 }')
  [ -n "$MIRRORS" ] || return 1
  [ -n "$FILES" ] || return 1
  return 0
}

# 0 = file downloaded, 1 = download failed, 3 = no downloader on device
fetch_one() {
  _fo_url="$1"; _fo_out="$2"
  rm -f "$_fo_out" 2>/dev/null
  if have curl; then
    _fo_code=$(curl -sS -m "$FETCH_TIMEOUT" -o "$_fo_out" -w '%{http_code}' "$_fo_url" 2>/dev/null)
    [ "$_fo_code" = "200" ] && [ -s "$_fo_out" ] && return 0
    return 1
  fi
  if have wget; then
    if wget -q -T "$FETCH_TIMEOUT" -O "$_fo_out" "$_fo_url" >/dev/null 2>&1 && [ -s "$_fo_out" ]; then
      return 0
    fi
    return 1
  fi
  return 3
}

# Turn a whitespace-separated list into a JSON array without emitting a
# single backslash literal, so the escaping cannot be swallowed in transit.
w2j() {
  awk 'BEGIN { q = sprintf("%c", 34); printf "[" }
       { for (i = 1; i <= NF; i++) { printf "%s%s%s%s", (n++ ? "," : ""), q, $i, q } }
       END { printf "]" }'
}

write_cache() {
  _wc_ok="$1"; _wc_src="$2"; _wc_ids="$3"; _wc_st="$4"; _wc_rs="$5"
  mkdir -p "$STATE_DIR" 2>/dev/null
  {
    echo "checked_at=$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null)"
    echo "ok=$_wc_ok"
    echo "source=$_wc_src"
    echo "feature_ids=$_wc_ids"
    echo "check_states=$_wc_st"
    echo "reason=$_wc_rs"
  } > "${UPSTREAM_CACHE}.tmp" 2>/dev/null && mv -f "${UPSTREAM_CACHE}.tmp" "$UPSTREAM_CACHE" 2>/dev/null
}

cache_get() {
  [ -f "$UPSTREAM_CACHE" ] || return 1
  _cg=$(grep -m1 "^$1=" "$UPSTREAM_CACHE" 2>/dev/null | sed -e "s/^$1=//")
  printf '%s' "$_cg"
}

emit_json() {
  _ej_ok="$1"; _ej_ts="$2"; _ej_src="$3"; _ej_ids="$4"; _ej_st="$5"; _ej_rs="$6"
  if [ "$_ej_ok" = "1" ]; then _ej_bool="true"; else _ej_bool="false"; fi
  _ej_ids_j=$(printf '%s' "$_ej_ids" | w2j)
  _ej_st_j=$(printf '%s' "$_ej_st" | w2j)
  _ej_src_e=$(printf '%s' "$_ej_src" | json_escape)
  _ej_ts_e=$(printf '%s' "$_ej_ts"  | json_escape)
  _ej_rs_e=$(printf '%s' "$_ej_rs"  | json_escape)
  printf '%s' "{\"ok\":${_ej_bool},\"checked_at\":\"${_ej_ts_e}\",\"source\":\"${_ej_src_e}\",\"feature_ids\":${_ej_ids_j},\"check_states\":${_ej_st_j},\"reason\":\"${_ej_rs_e}\"}"
}

do_check() {
  _ts=$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null)

  if ! load_known; then
    _rs="包内基线 ${KNOWN_JSON} 缺失或读不出镜像列表，无法发起核对。"
    write_cache 0 "" "" "" "$_rs"
    logline "$UPSTREAM_LOG" "check failed: baseline unreadable"
    emit_json 0 "$_ts" "" "" "" "$_rs"
    return
  fi

  if ! have curl && ! have wget; then
    _rs="设备上既没有 curl 也没有 wget，无法联网核对。本地功能不受影响。"
    write_cache 0 "" "" "" "$_rs"
    logline "$UPSTREAM_LOG" "check failed: no downloader"
    emit_json 0 "$_ts" "" "" "" "$_rs"
    return
  fi

  _id_url=""
  for _f in $FILES; do
    case "$_f" in
      *feature_id.rs) _id_url="$_f" ;;
      *feature.rs)    _fs_url="$_f" ;;
    esac
  done

  _tried=""
  for _m in $MIRRORS; do
    _host=$(printf '%s' "$_m" | sed -e 's#^https://##' -e 's#/.*$##')
    _tried="${_tried}${_tried:+, }${_host}"
    _base=$(printf '%s' "$_m" | sed -e 's#/*$##')

    if ! fetch_one "${_base}/${_id_url}" "$TMPD/feature_id.rs"; then continue; fi
    if ! fetch_one "${_base}/${_fs_url}" "$TMPD/feature.rs"; then continue; fi

    _ids=$(awk -F'"' '/Self::/ { if ($2 ~ /^[a-z_]+$/) print $2 }' "$TMPD/feature_id.rs" 2>/dev/null | sort -u)
    _states=$(awk -F'"' '/println!/ { if ($2 ~ /^[a-z]+$/) print $2 }' "$TMPD/feature.rs" 2>/dev/null | sort -u)

    _states=$(printf '%s' "$_states" | grep -E '^(supported|unsupported|managed|forced)$')

    if [ -z "$_ids" ] || [ -z "$_states" ]; then
      continue
    fi

    _ids_line=$(printf '%s' "$_ids" | tr '\n' ' ' | sed -e 's/[[:space:]]*$//')
    _st_line=$(printf '%s' "$_states" | tr '\n' ' ' | sed -e 's/[[:space:]]*$//')

    write_cache 1 "$_host" "$_ids_line" "$_st_line" ""
    logline "$UPSTREAM_LOG" "check ok via ${_host}: ${_ids_line}"
    emit_json 1 "$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null)" "$_host" "$_ids_line" "$_st_line" ""
    return
  done

  _rs="镜像全部不可达或内容解析不出预期结构（尝试过：${_tried}）。包内基线继续生效，功能不受影响。"
  write_cache 0 "" "" "" "$_rs"
  logline "$UPSTREAM_LOG" "check failed: all mirrors. tried=${_tried}"
  emit_json 0 "$_ts" "" "" "" "$_rs"
}

do_show() {
  if [ ! -f "$UPSTREAM_CACHE" ]; then
    emit_json 0 "" "" "" "" "还没有核对过上游。点「核对上游」才会联网。"
    return
  fi
  _ok=$(cache_get ok)
  [ "$_ok" = "1" ] || _ok=0
  emit_json "$_ok" "$(cache_get checked_at)" "$(cache_get source)" "$(cache_get feature_ids)" "$(cache_get check_states)" "$(cache_get reason)"
}

do_clear() {
  rm -f "$UPSTREAM_CACHE" 2>/dev/null
  logline "$UPSTREAM_LOG" "cache cleared"
  emit_json 0 "" "" "" "" "缓存已清除，下次核对会重新联网。"
}

usage() {
  echo "usage: upstream.sh [--check|--show|--clear]"
}

case "$1" in
  --check) do_check ;;
  --show)  do_show ;;
  --clear) do_clear ;;
  *)       usage; exit 1 ;;
esac

rm -rf "$TMPD" 2>/dev/null
