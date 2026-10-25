#!/system/bin/sh
# common/autoconfig.sh - move hiding-related config to the baseline
#
# What this touches, and nothing else:
#   - KernelSU feature switches, through `ksud feature set`
#   - the module's own data directory mode
#
# What this never touches:
#   - /data/adb/lspd/config/*.db        (LSPosed scope)
#   - the denylist table inside magisk.db
#   - any Zygisk exclusion list
#   - any other module's files
#
# That list is enforced by absence: there is no code path in this file that
# opens those files for writing, and `sqlq` is read-only by construction.
#
# Every action lands in exactly one of four states:
#   ok        the value now equals the baseline, read back and confirmed
#   failed    the change was attempted but could not be confirmed
#   skipped   not done on purpose, with the reason attached
#   na        the action does not apply to this device at all
#
# Usage: autoconfig.sh [--dry-run|--rollback|--status]

SELF_DIR=$(cd "$(dirname "$0")" 2>/dev/null && pwd)
[ -z "$SELF_DIR" ] && SELF_DIR="/data/adb/modules/lsposed_stealth/common"
. "$SELF_DIR/env.sh"

MODE="apply"
case "$1" in
  --dry-run)  MODE="dry-run" ;;
  --rollback) MODE="rollback" ;;
  --status)   MODE="status" ;;
  ""|--apply) MODE="apply" ;;
  *) echo "usage: autoconfig.sh [--dry-run|--rollback|--status]" >&2; exit 1 ;;
esac

mkdir -p "$AUTOCONF_DIR" 2>/dev/null

_ACTS=""

_norm_state() {
  case "$1" in
    ok|failed|skipped|na) printf '%s' "$1" ;;
    *)                    printf 'failed' ;;
  esac
}

emit_action() {
  _ai="$1"; _an="$2"; _as="$3"; _ad="$4"; _ao="$5"; _ann="$6"
  _st=$(_norm_state "$_as")
  _n=$(printf '%s' "$_an" | json_escape)
  _d=$(printf '%s' "$_ad" | json_escape)
  _o=$(printf '%s' "$_ao" | json_escape)
  _nn=$(printf '%s' "$_ann" | json_escape)
  [ -n "$_ACTS" ] && _ACTS="$_ACTS,"
  _ACTS="${_ACTS}{\"id\":\"${_ai}\",\"name\":\"${_n}\",\"state\":\"${_st}\",\"detail\":\"${_d}\",\"old\":\"${_o}\",\"new\":\"${_nn}\"}"
}

record() {
  [ "$MODE" = "dry-run" ] && return 0
  mkdir -p "$AUTOCONF_DIR" 2>/dev/null
  echo "$1|$2|$3|$4" >> "$AUTOCONF_RECORDS" 2>/dev/null
}

# ---------- helpers ----------
_mode_of() {
  _mo=$(stat -c %a "$1" 2>/dev/null)
  [ -n "$_mo" ] || return 1
  printf '%s' "$_mo"
}

_protected_list() {
  for _pl in /data/adb/lspd/config/*.db /data/adb/magisk.db \
             /data/misc/hide_my_applist_*/status.json \
             /data/adb/boot-completed.d/*; do
    [ -f "$_pl" ] && printf '%s\n' "$_pl"
  done
  for _pl in /data/adb/modules/*/module.prop /data/adb/modules_update/*/module.prop; do
    [ -f "$_pl" ] || continue
    case "$_pl" in
      *"/$MODID/module.prop") continue ;;
    esac
    printf '%s\n' "$_pl"
  done
}

_snapshot() {
  _sn_out="$1"
  : > "$_sn_out" 2>/dev/null
  _protected_list > "$AUTOCONF_DIR/.plist" 2>/dev/null
  while IFS= read -r _sp; do
    [ -n "$_sp" ] || continue
    _sh=$(hash_file "$_sp" 2>/dev/null)
    [ -n "$_sh" ] || _sh="unhashable"
    echo "$_sh  $_sp" >> "$_sn_out" 2>/dev/null
  done < "$AUTOCONF_DIR/.plist"
  rm -f "$AUTOCONF_DIR/.plist" 2>/dev/null
}

# ---------- action: KernelSU feature switch ----------
# check first, then set, then read back. A feature the kernel does not have is
# not a failure: it simply does not exist on this device.
_feature_action() {
  _fai="$1"; _faf="$2"; _fan="$3"; _faw="$4"

  _ck=$(feature_check "$_faf" 2>/dev/null)
  if [ -z "$_ck" ]; then
    emit_action "$_fai" "$_fan" "skipped" \
      "读不到 ${_faf} 的状态：设备上没有 ksud，或这个版本的 ksud 没有 feature 子命令。没有这一层信息就不动它。" "" ""
    return
  fi

  case " $_ck " in
    *" unsupported "*)
      emit_action "$_fai" "$_fan" "na" \
        "内核不支持 ${_faf}（check 返回 ${_ck}）。这一项在本机不存在，不需要设置。" "" ""
      return ;;
    *" forced "*)
      _cur=$(feature_get "$_faf" 2>/dev/null)
      [ -n "$_cur" ] || _cur="?"
      emit_action "$_fai" "$_fan" "skipped" \
        "${_faf} 被内核锁定为强制值（当前 ${_cur}），用户空间改不动。要改只能换内核。" "$_cur" "$_cur"
      return ;;
    *" managed "*)
      _cur=$(feature_get "$_faf" 2>/dev/null)
      [ -n "$_cur" ] || _cur="?"
      emit_action "$_fai" "$_fan" "skipped" \
        "${_faf} 正被别的模块管理（check 返回 ${_ck}）。本模块不去覆盖别人的配置。" "$_cur" "$_cur"
      return ;;
  esac

  _old=$(feature_get "$_faf" 2>/dev/null)
  [ -n "$_old" ] || _old="?"

  if [ "$_old" = "$_faw" ]; then
    emit_action "$_fai" "$_fan" "ok" \
      "已经是基线值 ${_faw}，没有改动。" "$_old" "$_old"
    return
  fi

  if [ "$MODE" = "dry-run" ]; then
    emit_action "$_fai" "$_fan" "skipped" \
      "预览：当前 ${_old}，计划改为 ${_faw}。没有写入，需要点「执行」才会生效。" "$_old" "$_faw"
    return
  fi

  feature_set "$_faf" "$_faw" 2>/dev/null
  _new=$(feature_get "$_faf" 2>/dev/null)
  [ -n "$_new" ] || _new="?"

  if [ "$_new" = "$_faw" ]; then
    record feature "$_faf" "$_old" "$_faw"
    emit_action "$_fai" "$_fan" "ok" \
      "已从 ${_old} 改为 ${_new}，读回确认。" "$_old" "$_new"
  else
    emit_action "$_fai" "$_fan" "failed" \
      "set 已发出，但读回是 ${_new}（期望 ${_faw}）。没有记成成功。" "$_old" "$_new"
  fi
}

# ---------- action: private state dir ----------
_action_private_state() {
  if [ ! -d "$DATA_DIR" ]; then
    emit_action "private_state" "本模块数据目录权限" "failed" \
      "找不到 ${DATA_DIR}，无法收紧权限。" "" ""
    return
  fi

  _pm=$(_mode_of "$DATA_DIR" 2>/dev/null)
  if [ -z "$_pm" ]; then
    emit_action "private_state" "本模块数据目录权限" "failed" \
      "设备的 stat 读不出权限位（不支持 -c 参数），无法确认当前模式。" "" ""
    return
  fi

  if [ "$_pm" = "700" ]; then
    emit_action "private_state" "本模块数据目录权限" "ok" \
      "${DATA_DIR} 已经是 0700。" "$_pm" "$_pm"
    return
  fi

  if [ "$MODE" = "dry-run" ]; then
    emit_action "private_state" "本模块数据目录权限" "skipped" \
      "预览：当前 ${_pm}，计划改为 700。没有改动。" "$_pm" "700"
    return
  fi

  chmod 0700 "$DATA_DIR" 2>/dev/null
  _pn=$(_mode_of "$DATA_DIR" 2>/dev/null)
  if [ "$_pn" = "700" ]; then
    record chmod "$DATA_DIR" "$_pm" "700"
    emit_action "private_state" "本模块数据目录权限" "ok" \
      "已从 ${_pm} 改为 ${_pn}，读回确认。" "$_pm" "$_pn"
  else
    emit_action "private_state" "本模块数据目录权限" "failed" \
      "chmod 已发出，但读回是 ${_pn}（期望 700）。" "$_pm" "${_pn:-?}"
  fi
}

# ---------- actions that are deliberately not automatic ----------
_action_denylist_guard() {
  emit_action "denylist_guard" "Magisk denylist" "na" \
    "本模块没有任何写 denylist 的代码路径。这一项不存在需要自动化的动作。" "" ""
}

_action_zygisk_exclusion() {
  if [ "$INJ_HMA" = "1" ]; then
    emit_action "zygisk_exclusion" "Zygisk 排除名单" "skipped" \
      "检测到 HMA-OSS 一类注入族模块（${INJ_MODULES}）。它靠 zygisk 注入来隐藏应用，把目标加入排除名单会同时掐掉它的隐藏。这一项保持不动。" "" ""
    return
  fi
  if [ "$INJ_ZYGISK" = "1" ]; then
    emit_action "zygisk_exclusion" "Zygisk 排除名单" "skipped" \
      "检测到 zygisk 实现（${INJ_MODULES}），但排除名单存在 magisk.db 里。本模块不写那张表，需要你在 Zygisk 管理界面手动设置。" "" ""
    return
  fi
  emit_action "zygisk_exclusion" "Zygisk 排除名单" "na" \
    "设备上没有 zygisk 实现，不存在排除名单这一层。" "" ""
}

_action_selinux_hide() {
  _ck=$(feature_check "selinux_hide" 2>/dev/null)
  if [ -z "$_ck" ]; then
    emit_action "selinux_hide" "SELinux 上下文隐藏" "skipped" \
      "读不到 selinux_hide 的状态，无法判断这台设备能不能用。不做改动。" "" ""
    return
  fi
  case " $_ck " in
    *" unsupported "*)
      emit_action "selinux_hide" "SELinux 上下文隐藏" "na" \
        "内核不支持 selinux_hide（check 返回 ${_ck}）。" "" "" ;;
    *)
      _cur=$(feature_get "selinux_hide" 2>/dev/null)
      [ -n "$_cur" ] || _cur="?"
      emit_action "selinux_hide" "SELinux 上下文隐藏" "skipped" \
        "内核支持这一项（check 返回 ${_ck}，当前值 ${_cur}），但它会改 SELinux 上下文，可能影响其他模块的行为。是否开启交给你判断。" "$_cur" "$_cur" ;;
  esac
}

# ---------- does anything reach the app process at all? ----------
# Turning this on makes the kernel unmount module paths for every app that is
# not explicitly granted root. It applies system-wide, so it does not fight
# with an injection-based hider: HMA still injects through zygote either way.
_action_mount_isolation() {
  _feature_action "mount_isolation" "kernel_umount" "内核模块卸载隔离" "1"
}

main_apply() {
  detect_injection_family

  _snap_before=""
  if has_hash; then
    _snap_before="$AUTOCONF_DIR/before.snap"
    _snapshot "$_snap_before"
  fi

  _action_mount_isolation
  _feature_action "su_logging" "sulog" "SU 日志开关" "0"
  _action_private_state
  _action_denylist_guard
  _action_zygisk_exclusion
  _action_selinux_hide

  # ---------- integrity ----------
  if ! has_hash; then
    emit_action "integrity_guard" "受保护文件未被改动" "failed" \
      "设备上既没有 sha256sum 也没有 md5sum，拍不了快照。无法证明这些文件没被碰过，所以不报告通过。" "" ""
  elif [ -z "$_snap_before" ] || [ ! -f "$_snap_before" ]; then
    emit_action "integrity_guard" "受保护文件未被改动" "failed" \
      "执行前的快照没写成，无法比对。" "" ""
  else
    _snap_after="$AUTOCONF_DIR/after.snap"
    _snapshot "$_snap_after"
    _cnt=$(grep -c . "$_snap_before" 2>/dev/null)
    [ -n "$_cnt" ] || _cnt=0
    if [ "$_cnt" = "0" ]; then
      emit_action "integrity_guard" "受保护文件未被改动" "skipped" \
        "一个受保护文件都没找到（没有 LSPosed 配置库、没有 magisk.db、没有 HMA 状态文件）。快照是空的，这一项什么都没验证到。" "" ""
    elif diff -q "$_snap_before" "$_snap_after" >/dev/null 2>&1; then
      emit_action "integrity_guard" "受保护文件未被改动" "ok" \
        "执行前后对 ${_cnt} 个受保护文件做了 ${HASHER} 快照，逐字节一致。" "" ""
    else
      _df=$(diff "$_snap_before" "$_snap_after" 2>/dev/null | grep -E '^[<>]' | head -3)
      emit_action "integrity_guard" "受保护文件未被改动" "failed" \
        "执行前后快照不一致，说明有受保护文件在这期间被改动：$(printf '%s' "$_df" | json_escape)" "" ""
    fi
  fi
}

# ---------- rollback ----------
main_rollback() {
  if [ ! -f "$AUTOCONF_RECORDS" ]; then
    emit_action "rollback" "回滚" "na" \
      "没有找到 ${AUTOCONF_RECORDS}，这台设备上还没有执行过自动配置，没有可回滚的改动。" "" ""
    return
  fi

  _n_lines=$(grep -c . "$AUTOCONF_RECORDS" 2>/dev/null)
  [ -n "$_n_lines" ] || _n_lines=0

  if [ "$_n_lines" = "0" ]; then
    emit_action "rollback" "回滚" "na" \
      "记录文件是空的，没有可回滚的改动。" "" ""
    return
  fi

  _tmp="$AUTOCONF_DIR/.rollback"
  awk '{ a[NR] = $0 } END { for (i = NR; i >= 1; i--) print a[i] }' "$AUTOCONF_RECORDS" > "$_tmp" 2>/dev/null

  _done=0
  _fail=0
  while IFS='|' read -r _rk _rkey _rold _rnew; do
    [ -n "$_rk" ] || continue
    case "$_rk" in
      feature)
        case "$_rold" in ''|'?') 
          _fail=$((_fail + 1))
          continue ;;
        esac
        feature_set "$_rkey" "$_rold" 2>/dev/null
        _now=$(feature_get "$_rkey" 2>/dev/null)
        if [ "$_now" = "$_rold" ]; then
          _done=$((_done + 1))
        else
          _fail=$((_fail + 1))
        fi
        ;;
      chmod)
        [ -d "$_rkey" ] || { _fail=$((_fail + 1)); continue; }
        case "$_rold" in ''|'?') _fail=$((_fail + 1)); continue ;; esac
        chmod "$_rold" "$_rkey" 2>/dev/null
        _now=$(_mode_of "$_rkey" 2>/dev/null)
        if [ "$_now" = "$_rold" ]; then
          _done=$((_done + 1))
        else
          _fail=$((_fail + 1))
        fi
        ;;
    esac
  done < "$_tmp"

  rm -f "$_tmp" 2>/dev/null

  if [ "$_fail" = "0" ]; then
    emit_action "rollback" "回滚" "ok" \
      "按 ${AUTOCONF_RECORDS} 逆序写回了 ${_done} 个改动，每一个都读回确认。" "" ""
    mv -f "$AUTOCONF_RECORDS" "$AUTOCONF_RECORDS.done" 2>/dev/null
  else
    emit_action "rollback" "回滚" "failed" \
      "写回成功 ${_done} 个，失败 ${_fail} 个。记录文件保留，可以再试一次，失败项多半是当前内核状态已经变了。" "" ""
  fi
}

# ---------- output ----------
emit_report() {
  _ts=$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null)
  [ -z "$_ts" ] && _ts="unknown"

  _ok=0; _failed=0; _skipped=0; _na=0
  _failed=$(printf '%s' "$_ACTS" | grep -o '"state":"failed"' | wc -l | tr -d ' ')
  _skipped=$(printf '%s' "$_ACTS" | grep -o '"state":"skipped"' | wc -l | tr -d ' ')
  _na=$(printf '%s' "$_ACTS" | grep -o '"state":"na"' | wc -l | tr -d ' ')
  _ok=$(printf '%s' "$_ACTS" | grep -o '"state":"ok"' | wc -l | tr -d ' ')

  if [ "$INJ_HMA" = "1" ]; then _hma="true"; else _hma="false"; fi
  if [ "$INJ_ZYGISK" = "1" ]; then _zy="true"; else _zy="false"; fi
  if [ -n "$KSUD" ]; then _kd="true"; else _kd="false"; fi
  if has_hash; then _hh="true"; else _hh="false"; fi
  _hm_e=$(printf '%s' "$INJ_MODULES" | json_escape)

  _json="{\"generated_at\":\"${_ts}\",\"mode\":\"${MODE}\""
  _json="${_json},\"environment\":{\"ksud\":${_kd},\"hasher\":${_hh},\"hma\":${_hma},\"zygisk\":${_zy},\"injection_modules\":\"${_hm_e}\"}"
  _json="${_json},\"summary\":{\"ok\":${_ok},\"failed\":${_failed},\"skipped\":${_skipped},\"na\":${_na}}"
  _json="${_json},\"actions\":[${_ACTS}]}"

  if [ "$MODE" != "dry-run" ] && [ "$MODE" != "status" ]; then
    printf '%s' "$_json" > "${AUTOCONF_FILE}.tmp" 2>/dev/null \
      && mv -f "${AUTOCONF_FILE}.tmp" "$AUTOCONF_FILE" 2>/dev/null
    logline "$AUTOCONF_LOG" "${MODE} ok=${_ok} failed=${_failed} skipped=${_skipped} na=${_na}"
  fi

  printf '%s' "$_json"
}

main_status() {
  if [ -f "$AUTOCONF_FILE" ]; then
    printf '%s' "$(cat "$AUTOCONF_FILE" 2>/dev/null)"
    return
  fi
  _ts=$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null)
  printf '%s' "{\"generated_at\":\"${_ts}\",\"mode\":\"status\",\"environment\":{\"ksud\":false,\"hasher\":false,\"hma\":false,\"zygisk\":false,\"injection_modules\":\"\"},\"summary\":{\"ok\":0,\"failed\":0,\"skipped\":0,\"na\":0},\"actions\":[]}"
}

case "$MODE" in
  status)   main_status ;;
  rollback) main_rollback; emit_report ;;
  dry-run)  main_apply;   emit_report ;;
  apply)    main_apply;   emit_report ;;
esac
